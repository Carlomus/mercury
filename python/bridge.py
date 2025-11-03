"""
Jupyter kernel bridge for Neovim.
"""

import sys
import json
import time
import threading
from queue import Empty, Queue
from typing import Optional

from jupyter_client import KernelManager

_write_lock = threading.Lock()


def jprint(obj):
    with _write_lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()


class Bridge:
    def __init__(self):
        self.kmanager: Optional[KernelManager] = None
        self.kclient = None
        self.task_q: Queue = Queue()
        self.worker: Optional[threading.Thread] = None
        self.stop_event = threading.Event()
        self.current_cell_id: Optional[str] = None

    def start_kernel(self):
        """
        Start an ipykernel with the SAME interpreter as this bridge.
        """
        try:
            self.kmanager = KernelManager(
                kernel_cmd=[
                    sys.executable,
                    "-m",
                    "ipykernel",
                    "-f",
                    "{connection_file}",
                ]
            )
            self.kmanager.start_kernel()
            self.kclient = self.kmanager.client()
            self.kclient.start_channels()
            self.kclient.wait_for_ready(timeout=30)

        except ModuleNotFoundError as e:
            if getattr(e, "name", "") == "ipykernel":
                jprint(
                    {
                        "type": "kernel_error",
                        "error": (
                            f"ipykernel is not installed in {sys.executable}. "
                            f"Install with: '{sys.executable} -m pip install -U ipykernel'"
                        ),
                    }
                )
            else:
                jprint({"type": "kernel_error", "error": f"{type(e).__name__}: {e}"})
            raise
        except Exception as e:
            jprint({"type": "kernel_error", "error": f"{type(e).__name__}: {e}"})
            raise

        self.worker = threading.Thread(target=self._worker_loop, daemon=True)
        self.worker.start()

    def restart_kernel(self):
        """
        Clean restart while keeping the same kernel_cmd.
        """
        try:
            try:
                if self.kclient:
                    self.kclient.stop_channels()
            except Exception:
                pass
            if self.kmanager:
                self.kmanager.restart_kernel(now=True)
            else:
                self.start_kernel()
                jprint({"type": "restarted"})
                return

            self.kclient = self.kmanager.client()
            self.kclient.start_channels()
            self.kclient.wait_for_ready(timeout=30)
            jprint({"type": "restarted"})
        except Exception as e:
            jprint({"type": "kernel_error", "error": f"{type(e).__name__}: {e}"})

    def is_alive(self) -> bool:
        return bool(self.kmanager and self.kmanager.is_alive())

    def _worker_loop(self):
        while not self.stop_event.is_set():
            try:
                task = self.task_q.get(timeout=0.1)
            except Empty:
                continue
            if task is None:
                break
            cell_id, code = task
            try:
                self._drain_execute(cell_id, code)
            finally:
                self.current_cell_id = None

    def _drain_execute(self, cell_id: str, code: str):
        """
        Run one execute request and drain IOPub incrementally.

        Emits:
          - {"type":"execute_start","cell_id":...}
          - {"type":"output","cell_id":...,"item":{iopub message content}}
          - {"type":"execute_done","cell_id":...,"exec_count":N,"ms":MS}
        """
        self.current_cell_id = cell_id
        jprint({"type": "execute_start", "cell_id": cell_id})
        started = time.time()

        try:
            parent_id = self.kclient.execute(
                code, stop_on_error=False, allow_stdin=False
            )
        except Exception as e:
            jprint(
                {
                    "type": "execute_done",
                    "cell_id": cell_id,
                    "exec_count": None,
                    "ms": 0,
                    "outputs": [
                        {
                            "type": "error",
                            "ename": type(e).__name__,
                            "evalue": str(e),
                            "traceback": [],
                        }
                    ],
                }
            )
            return

        exec_count = None
        while True:
            if not self.is_alive():
                jprint({"type": "kernel_dead"})
                return
            try:
                rep = self.kclient.get_shell_msg(timeout=0.1)
            except Empty:
                continue
            except Exception:
                continue
            if rep.get("parent_header", {}).get("msg_id") != parent_id:
                continue
            if rep.get("header", {}).get("msg_type") == "execute_reply":
                exec_count = rep.get("content", {}).get("execution_count")
                break

        # Drain IOPub until we see status: idle for this parent.
        while True:
            if not self.is_alive():
                jprint({"type": "kernel_dead"})
                return
            try:
                msg = self.kclient.get_iopub_msg(timeout=0.1)
            except Empty:
                continue
            except Exception:
                continue

            if msg.get("parent_header", {}).get("msg_id") != parent_id:
                continue

            mtype = msg["header"]["msg_type"]
            content = msg["content"]

            if mtype in (
                "stream",
                "display_data",
                "execute_result",
                "error",
                "clear_output",
                "update_display_data",
            ):
                if mtype == "stream" and isinstance(content.get("text"), list):
                    content["text"] = "".join(content["text"])
                item = {"type": mtype, **content}
                jprint({"type": "output", "cell_id": cell_id, "item": item})

            elif mtype == "status" and content.get("execution_state") == "idle":
                ms = int((time.time() - started) * 1000)
                jprint(
                    {
                        "type": "execute_done",
                        "cell_id": cell_id,
                        "exec_count": exec_count,
                        "ms": ms,
                    }
                )
                return

    def execute_async(self, cell_id: str, code: str):
        """
        Queue the task; the single worker consumes sequentially.
        """
        self.task_q.put((cell_id, code))

    def interrupt(self):
        try:
            if self.kmanager:
                self.kmanager.interrupt_kernel()
        finally:
            jprint({"type": "interrupted", "cell_id": self.current_cell_id})

    def close(self):
        try:
            self.stop_event.set()
            self.task_q.put(None)
            if self.worker:
                self.worker.join(timeout=2)
        except Exception:
            pass

        # Shutdown channels and kernel
        try:
            if self.kclient:
                self.kclient.stop_channels()
        except Exception:
            pass
        try:
            if self.kmanager and self.kmanager.is_alive():
                self.kmanager.shutdown_kernel(now=True)
        except Exception:
            pass


if __name__ == "__main__":
    bridge = Bridge()
    try:
        bridge.start_kernel()
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception:
                continue

            typ = req.get("type")
            if typ == "execute":
                bridge.execute_async(req.get("cell_id"), req.get("code", ""))
            elif typ == "interrupt":
                bridge.interrupt()
            elif typ == "restart":
                bridge.restart_kernel()
            else:
                pass
    finally:
        bridge.close()
