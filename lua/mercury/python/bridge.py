"""Mercury Jupyter bridge.

JSONL protocol over stdio. Supports two transports:
  - local kernelspec (default)
  - existing connection file
"""

from __future__ import annotations

import json
import sys
import threading
import time
from queue import Empty, Queue
from typing import Any, Dict, Optional


_write_lock = threading.Lock()


def jprint(obj: Dict[str, Any]) -> None:
    with _write_lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False, default=_jsonable) + "\n")
        sys.stdout.flush()


def _jsonable(o):
    try:
        return str(o)
    except Exception:
        return None


# ----------------------------------------------------------------------
# Kernel acquisition strategies
# ----------------------------------------------------------------------

class NoUsableKernel(Exception):
    def __init__(self, requested: Optional[str] = None, available: list = None,
                 detail: Optional[str] = None):
        self.requested = requested
        self.available = available or []
        self.detail = detail
        super().__init__(self._message())

    def _message(self) -> str:
        # `detail` is verbatim — used for path-validation errors from
        # _make_local_km_from_python / _from_spec_path whose messages would
        # be misleading if wrapped in "kernelspec '...' not found".
        if self.detail:
            return self.detail
        if not self.available:
            return (
                "no Jupyter kernelspecs are installed. "
                f"Install one with: {sys.executable} -m pip install ipykernel "
                f"&& {sys.executable} -m ipykernel install --user --name python3"
            )
        names = ", ".join(k["name"] for k in self.available)
        if self.requested:
            return f"kernelspec '{self.requested}' not found. Available: {names}"
        return f"no default 'python3' kernelspec; available: {names}"


def _list_kernelspecs() -> list:
    try:
        from jupyter_client.kernelspec import KernelSpecManager
        specs = KernelSpecManager().get_all_specs()
    except Exception:
        return []
    out = []
    for name, spec in specs.items():
        s = spec.get("spec", {})
        out.append({
            "name": name,
            "display_name": s.get("display_name", name),
            "language": s.get("language", ""),
        })
    return out


def _make_local_km(opts: Dict[str, Any]):
    """Return a started KernelManager from a local-mode kernel opts dict.

    Three mutually-exclusive selectors are accepted, checked in priority
    order:
      python:    absolute path to a python executable; the bridge writes a
                 synthesized kernelspec to a temp dir and uses that. This is
                 the "just point at a venv" mode.
      spec_path: absolute path to an existing kernelspec *directory* (the
                 one containing kernel.json). Useful for kernels that aren't
                 registered via `jupyter kernelspec install`.
      name:      registered kernelspec name. Default fallback is "python3".

    Raises NoUsableKernel — with the list of installed kernelspecs — when
    the requested selector can't be resolved.
    """
    python_path = opts.get("python")
    spec_path = opts.get("spec_path")
    if python_path:
        return _make_local_km_from_python(python_path)
    if spec_path:
        return _make_local_km_from_spec_path(spec_path)

    from jupyter_client import KernelManager
    from jupyter_client.kernelspec import KernelSpecManager, NoSuchKernel

    requested = opts.get("name")
    name = requested or "python3"
    try:
        KernelSpecManager().get_kernel_spec(name)
    except NoSuchKernel:
        raise NoUsableKernel(name if requested else None, _list_kernelspecs())

    km = KernelManager(kernel_name=name)
    km.start_kernel()
    return km


def _short_python_label(python_path: str) -> str:
    """e.g. /foo/bar/.venv/bin/python -> '.venv (bar)'"""
    import os
    parent = os.path.dirname(os.path.dirname(python_path))
    base = os.path.basename(parent)
    if base in (".venv", "venv", "env"):
        proj = os.path.basename(os.path.dirname(parent)) or base
        return f"{base} ({proj})"
    return python_path


def _make_local_km_from_python(python_path: str):
    """Synthesize an ad-hoc kernelspec for a python executable and start it.

    We write a tiny kernel.json to a temp directory and tell KernelSpecManager
    to look there; jupyter_client treats it indistinguishably from a kernel
    installed via `jupyter kernelspec install`. ipykernel must be importable
    in `python_path`'s environment for the launcher to come up.
    """
    import os, tempfile, json
    from jupyter_client import KernelManager
    from jupyter_client.kernelspec import KernelSpecManager

    if not os.path.isabs(python_path):
        raise NoUsableKernel(detail=f"python path must be absolute: {python_path}")
    if not os.path.isfile(python_path) or not os.access(python_path, os.X_OK):
        raise NoUsableKernel(detail=f"python not executable: {python_path}")

    tmpdir = tempfile.mkdtemp(prefix="mercury_kernel_")
    spec_name = "mercury_synth"
    spec_dir = os.path.join(tmpdir, spec_name)
    os.makedirs(spec_dir)
    spec = {
        "argv": [python_path, "-m", "ipykernel_launcher",
                 "-f", "{connection_file}"],
        "display_name": f"Python ({_short_python_label(python_path)})",
        "language": "python",
    }
    with open(os.path.join(spec_dir, "kernel.json"), "w") as f:
        json.dump(spec, f)

    ksm = KernelSpecManager()
    # Prepend so our synthesized spec shadows any "mercury_synth" left over
    # from a previous session that we'd otherwise pick up.
    ksm.kernel_dirs = [tmpdir] + list(ksm.kernel_dirs)
    km = KernelManager(kernel_name=spec_name, kernel_spec_manager=ksm)
    km.start_kernel()
    # Attach for cleanup by Bridge.close(). We can't remove tmpdir here
    # because km.restart_kernel() may re-read kernel.json from it; the
    # tmpdir's lifetime is tied to the KernelManager's.
    km._mercury_tmpdir = tmpdir
    return km


def _make_local_km_from_spec_path(spec_path: str):
    """Use an existing on-disk kernelspec directory (containing kernel.json)."""
    import os
    from jupyter_client import KernelManager
    from jupyter_client.kernelspec import KernelSpecManager

    spec_path = os.path.abspath(spec_path)
    if not os.path.isfile(os.path.join(spec_path, "kernel.json")):
        raise NoUsableKernel(detail=f"no kernel.json at {spec_path}")

    parent = os.path.dirname(spec_path)
    name = os.path.basename(spec_path)
    ksm = KernelSpecManager()
    ksm.kernel_dirs = [parent] + list(ksm.kernel_dirs)
    km = KernelManager(kernel_name=name, kernel_spec_manager=ksm)
    km.start_kernel()
    return km


def _make_existing_kc(connection_file: str):
    from jupyter_client import BlockingKernelClient

    kc = BlockingKernelClient()
    kc.load_connection_file(connection_file)
    kc.start_channels()
    return kc


# NOTE: A remote-server transport (mode="server") was prototyped but not
# implemented — the Jupyter Server REST API does not expose kernel ZMQ ports,
# so it needs WebSocket proxying of /api/kernels/<id>/channels. Use
# mode="existing" with a connection_file for remote kernels in the meantime.


# ----------------------------------------------------------------------
# Bridge
# ----------------------------------------------------------------------

class Bridge:
    def __init__(self) -> None:
        self.km = None
        self.kc = None
        self.task_q: "Queue[Optional[tuple]]" = Queue()
        self.worker: Optional[threading.Thread] = None
        self.iopub_thread: Optional[threading.Thread] = None
        self.stop_event = threading.Event()
        self.current_cell_id: Optional[str] = None
        self.parent_to_cell: Dict[str, str] = {}
        self._idle_seen: Dict[str, bool] = {}
        self._lock = threading.Lock()
        self.kernel_opts: Dict[str, Any] = {"mode": "local"}
        # Restart epoch — incremented on every restart. _execute captures the
        # value at entry and checks it inside its wait loops; if the counter
        # advances mid-execute, the kernel was restarted under us and the
        # parent_id we're waiting on no longer means anything on the new
        # kernel. Without this check, the worker thread would spin forever
        # on `get_shell_msg` for a reply that can't arrive, jamming all
        # subsequent executes in task_q.
        self._restart_seq: int = 0

    # -- lifecycle -----------------------------------------------------

    def init(self, opts: Dict[str, Any]) -> None:
        self.kernel_opts = opts or {"mode": "local"}
        self._start()

    def _start(self) -> bool:
        try:
            mode = (self.kernel_opts or {}).get("mode", "local")
            if mode == "existing":
                cf = self.kernel_opts.get("connection_file")
                if not cf:
                    raise ValueError("kernel.mode=existing requires connection_file")
                self.kc = _make_existing_kc(cf)
                self.km = None
            elif mode == "server":
                raise NotImplementedError(
                    "kernel.mode='server' is not implemented. "
                    "Use kernel.mode='existing' with a connection_file."
                )
            else:
                self.km = _make_local_km(self.kernel_opts)
                self.kc = self.km.client()
                self.kc.start_channels()

            self.kc.wait_for_ready(timeout=30)
        except NoUsableKernel as e:
            jprint({
                "type": "kernel_error",
                "kind": "no_kernelspec",
                "error": str(e),
                "requested": e.requested,
                "available": e.available,
            })
            return False
        except ModuleNotFoundError as e:
            jprint({
                "type": "kernel_error",
                "kind": "missing_module",
                "error": (
                    f"Missing python module: {e.name}. "
                    f"Install in {sys.executable}: pip install jupyter_client ipykernel"
                ),
            })
            return False
        except Exception as e:
            jprint({"type": "kernel_error",
                    "error": f"{type(e).__name__}: {e}"})
            return False

        # Threads reference self.kc dynamically; only spawn on first start so
        # restarts don't leak threads or fight over the new client.
        if self.worker is None or not self.worker.is_alive():
            self.worker = threading.Thread(target=self._worker_loop, daemon=True)
            self.worker.start()
        if self.iopub_thread is None or not self.iopub_thread.is_alive():
            self.iopub_thread = threading.Thread(target=self._iopub_loop, daemon=True)
            self.iopub_thread.start()
        return True

    def is_alive(self) -> bool:
        if self.km is not None:
            return bool(self.km.is_alive())
        return self.kc is not None and self.kc.is_alive()

    def restart(self) -> None:
        # Bump the epoch first so any in-flight _execute notices on its next
        # loop iteration and bails out cleanly instead of waiting for shell
        # messages from the soon-to-be-dead kernel.
        self._restart_seq += 1
        # Drain orphan tasks. Lua clears its own queue on "restarted"; any
        # task still sitting in task_q was sent before restart and would run
        # unexpectedly on the new kernel, surprising the user with fresh
        # outputs they didn't ask for.
        while True:
            try:
                self.task_q.get_nowait()
            except Empty:
                break
        try:
            if self.km is not None:
                # Local mode: tear down the old client, restart the kernel
                # subprocess via the KernelManager, attach a fresh client.
                # restart_kernel(now=True) sends SIGKILL and respawns, so
                # all Python state in the kernel is gone — variables, imports,
                # everything cleared. That's what the user expects from "restart".
                if self.kc is not None:
                    try: self.kc.stop_channels()
                    except Exception: pass
                self.km.restart_kernel(now=True)
                self.kc = self.km.client()
                self.kc.start_channels()
                self.kc.wait_for_ready(timeout=30)
            elif self.kc is not None:
                # Existing-kernel mode: we don't own the process. Send the
                # standard Jupyter shutdown_request(restart=True); whatever
                # supervisor launched the kernel (typically jupyter server's
                # KernelManager) is responsible for relaunching it on the
                # same ports. wait_for_ready then blocks on heartbeat until
                # the new kernel attaches. If nothing relaunches the kernel,
                # wait_for_ready times out and we surface an error rather
                # than silently leaving the user with a dead connection.
                try:
                    self.kc.shutdown(restart=True)
                except Exception as e:
                    jprint({"type": "kernel_error",
                            "error": f"restart request failed: "
                                     f"{type(e).__name__}: {e}"})
                    return
                try:
                    self.kc.wait_for_ready(timeout=30)
                except Exception:
                    jprint({"type": "kernel_error",
                            "error": "kernel did not come back within 30s after "
                                     "restart — the kernel must be supervised by "
                                     "an upstream manager (e.g. jupyter server) "
                                     "to be restartable in existing-kernel mode."})
                    return
            else:
                jprint({"type": "kernel_error",
                        "error": "no kernel client; nothing to restart"})
                return
            with self._lock:
                self.parent_to_cell.clear()
                self._idle_seen.clear()
            jprint({"type": "restarted"})
        except Exception as e:
            jprint({"type": "kernel_error", "error": f"{type(e).__name__}: {e}"})

    # -- worker --------------------------------------------------------

    def _worker_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                task = self.task_q.get(timeout=0.1)
            except Empty:
                continue
            if task is None:
                break
            cell_id, code = task
            self.current_cell_id = cell_id
            jprint({"type": "execute_start", "cell_id": cell_id})
            # Catch any exception so the worker thread survives. A bug in
            # _execute that propagates up would otherwise kill the thread
            # and silently jam every subsequent execute in task_q.
            try:
                self._execute(cell_id, code)
            except Exception as e:
                jprint({
                    "type": "execute_done",
                    "cell_id": cell_id,
                    "exec_count": None, "ms": 0,
                    "outputs": [{
                        "type": "error",
                        "ename": type(e).__name__,
                        "evalue": str(e),
                        "traceback": [],
                    }],
                })
                self.current_cell_id = None

    def _execute(self, cell_id: str, code: str) -> None:
        # Capture the restart epoch at entry. If it changes while we're
        # waiting on shell/iopub messages, the kernel was restarted under us
        # and our parent_id is meaningless on the new kernel — bail silently
        # so subsequent cells can run on the fresh kernel.
        my_seq = self._restart_seq
        started = time.time()
        # Hold the lock through BOTH kc.execute and the parent_to_cell write
        # so iopub_loop can't observe parent_to_cell mid-update. Without this,
        # a kernel that emits its first iopub frame within microseconds of
        # receiving execute_request would have that frame silently dropped
        # because parent_to_cell.get(parent_id) returns None.
        try:
            with self._lock:
                parent_id = self.kc.execute(
                    code, stop_on_error=False, allow_stdin=False)
                self.parent_to_cell[parent_id] = cell_id
        except Exception as e:
            # If a restart fired between worker_loop popping our task and us
            # reaching kc.execute, the old kc is torn down and this raises.
            # That's not an error to surface — lua already discarded this
            # cell from its running state on the "restarted" message.
            if self._restart_seq != my_seq:
                self.current_cell_id = None
                return
            jprint({
                "type": "execute_done",
                "cell_id": cell_id,
                "exec_count": None, "ms": 0,
                "outputs": [{
                    "type": "error",
                    "ename": type(e).__name__, "evalue": str(e),
                    "traceback": [],
                }],
            })
            self.current_cell_id = None
            return

        exec_count = None
        # No hard deadline: long-running cells are legitimate. The user can
        # interrupt explicitly; kernel-dead is detected below.
        while not self.stop_event.is_set():
            if self._restart_seq != my_seq:
                self._forget(parent_id)
                self.current_cell_id = None
                return
            if not self.is_alive():
                jprint({"type": "kernel_dead"})
                self._forget(parent_id)
                self.current_cell_id = None
                return
            try:
                rep = self.kc.get_shell_msg(timeout=0.2)
            except Empty:
                continue
            except Exception:
                continue
            if rep.get("parent_header", {}).get("msg_id") != parent_id:
                continue
            if rep.get("header", {}).get("msg_type") == "execute_reply":
                exec_count = rep.get("content", {}).get("execution_count")
                break

        # Wait for IOPub idle for our parent.
        while not self.stop_event.is_set():
            if self._restart_seq != my_seq:
                self._forget(parent_id)
                self.current_cell_id = None
                return
            if not self.is_alive():
                jprint({"type": "kernel_dead"})
                self._forget(parent_id)
                self.current_cell_id = None
                return
            with self._lock:
                seen = self._idle_seen.get(parent_id, False)
            if seen:
                break
            time.sleep(0.05)

        ms = int((time.time() - started) * 1000)
        jprint({"type": "execute_done", "cell_id": cell_id,
                "exec_count": exec_count, "ms": ms})
        self._forget(parent_id)
        self.current_cell_id = None

    def _forget(self, parent_id: str) -> None:
        with self._lock:
            self.parent_to_cell.pop(parent_id, None)
            self._idle_seen.pop(parent_id, None)

    # -- IOPub ---------------------------------------------------------

    def _iopub_loop(self) -> None:
        while not self.stop_event.is_set():
            if self.kc is None or not self.is_alive():
                time.sleep(0.05)
                continue
            try:
                msg = self.kc.get_iopub_msg(timeout=0.1)
            except Empty:
                continue
            except Exception:
                continue
            # Per-message parsing is wrapped so a malformed iopub message
            # can't kill the thread — that would leave the kernel "alive"
            # but mute, with no observable error.
            try:
                self._handle_iopub_msg(msg)
            except Exception as e:
                jprint({"type": "kernel_error",
                        "error": f"iopub parse: {type(e).__name__}: {e}"})

    def _handle_iopub_msg(self, msg) -> None:
        """Handle one iopub frame. Extracted so tests can drive it directly
        without spinning the iopub thread or owning a real kernel client.
        """
        parent_id = msg.get("parent_header", {}).get("msg_id")
        header = msg.get("header") or {}
        mtype = header.get("msg_type")
        content = msg.get("content") or {}
        if not mtype:
            return
        with self._lock:
            cell_id = self.parent_to_cell.get(parent_id)

        if mtype in ("stream", "display_data", "execute_result",
                     "error", "clear_output", "update_display_data"):
            if cell_id is None:
                return
            if mtype == "stream" and isinstance(content.get("text"), list):
                content["text"] = "".join(content["text"])
            item = {"type": mtype, **content}
            jprint({"type": "output", "cell_id": cell_id, "item": item})
        elif mtype == "status":
            # Only record idle for a parent we know about. A late idle frame
            # arriving after _forget already cleaned up parent_to_cell would
            # otherwise leak into _idle_seen forever (a small but real memory
            # leak over many thousands of executes).
            if (content.get("execution_state") == "idle"
                    and parent_id
                    and cell_id is not None):
                with self._lock:
                    self._idle_seen[parent_id] = True

    # -- requests ------------------------------------------------------

    def execute_async(self, cell_id: str, code: str) -> None:
        if self.kc is None:
            jprint({"type": "execute_done", "cell_id": cell_id,
                    "exec_count": None, "ms": 0,
                    "outputs": [{
                        "type": "error",
                        "ename": "NoKernel",
                        "evalue": "no kernel is running; pick one with :NotebookKernelSelect",
                        "traceback": [],
                    }]})
            return
        self.task_q.put((cell_id, code))

    def interrupt(self) -> None:
        # Interrupt is signal-based and only works on a locally-owned
        # kernel subprocess. In mode="existing" we don't own the process
        # (a jupyter server / external supervisor does), so there's nothing
        # to SIGINT. Reject explicitly with kind="unsupported" so the Lua
        # side surfaces a WARN without clobbering running/queue state.
        # SPEC Invariant 26.
        if self.km is None:
            jprint({
                "type": "kernel_error",
                "kind": "unsupported",
                "error": "interrupt is not supported in mode='existing' "
                         "(signal-based; requires owning the kernel process)",
            })
            return
        try:
            self.km.interrupt_kernel()
        except Exception as e:
            jprint({"type": "kernel_error",
                    "error": f"interrupt failed: {type(e).__name__}: {e}"})
            return
        jprint({"type": "interrupted", "cell_id": self.current_cell_id})

    def list_kernels(self) -> None:
        try:
            from jupyter_client.kernelspec import KernelSpecManager
            specs = KernelSpecManager().get_all_specs()
            out = []
            for name, spec in specs.items():
                s = spec.get("spec", {})
                out.append({
                    "name": name,
                    "display_name": s.get("display_name", name),
                    "language": s.get("language", ""),
                })
            jprint({"type": "kernels_listed", "kernels": out})
        except Exception as e:
            jprint({"type": "kernels_listed", "kernels": [],
                    "error": f"{type(e).__name__}: {e}"})

    def close(self) -> None:
        self.stop_event.set()
        try:
            self.task_q.put(None)
            if self.worker:
                self.worker.join(timeout=2)
        except Exception:
            pass
        try:
            if self.kc:
                self.kc.stop_channels()
        except Exception:
            pass
        try:
            if self.km and self.km.is_alive():
                self.km.shutdown_kernel(now=True)
        except Exception:
            pass
        # Reap the synthesized-kernelspec tmpdir, if any. Created by
        # _make_local_km_from_python; only present when the user picked a
        # python path as the kernel selector.
        try:
            tmpdir = getattr(self.km, "_mercury_tmpdir", None) if self.km else None
            if tmpdir:
                import shutil
                shutil.rmtree(tmpdir, ignore_errors=True)
        except Exception:
            pass


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

def main() -> None:
    bridge = Bridge()
    inited = False
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception:
                continue

            typ = req.get("type")
            if typ == "init":
                bridge.init(req.get("kernel") or {})
                inited = True
            elif not inited:
                # Lazy auto-init for backwards compat with simple clients.
                bridge.init({"mode": "local"})
                inited = True

            if typ == "execute":
                bridge.execute_async(req.get("cell_id"), req.get("code", ""))
            elif typ == "interrupt":
                bridge.interrupt()
            elif typ == "restart":
                bridge.restart()
            elif typ == "list_kernels":
                bridge.list_kernels()
            elif typ == "shutdown":
                break
    finally:
        bridge.close()


if __name__ == "__main__":
    main()
