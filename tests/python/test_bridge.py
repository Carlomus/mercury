"""Unit tests for python/bridge.py.

Most of the bridge talks to a live Jupyter kernel and is hard to exercise
without infrastructure, but the restart-abort path is critical correctness
glue and small enough to test in isolation with stubs.

Run with:    make test-python
Or:         python3 -m unittest discover -s tests/python -t .
"""

import os
import sys
import threading
import time
import unittest
from queue import Empty

# Allow `import bridge` regardless of CWD by injecting the bridge's
# directory onto sys.path. tests/python -> ../../lua/mercury/python after
# the canonical-plugin reorg.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(
    0,
    os.path.normpath(os.path.join(_HERE, "..", "..", "lua", "mercury", "python")),
)

import bridge  # noqa: E402


class _StubKC:
    """Minimal stand-in for jupyter_client.BlockingKernelClient.

    Just enough surface area for Bridge._execute to enter the wait loop and
    stay there. We never produce a parent-matching shell reply, so the
    restart-seq check is the only thing that can let _execute return — which
    is exactly what we want to verify.
    """
    def __init__(self):
        self.parent_id = "fake-parent"

    def execute(self, code, **kwargs):
        return self.parent_id

    def get_shell_msg(self, timeout=0.2):
        # Mirror jupyter_client's behavior: block up to `timeout` then raise
        # Empty. _execute's wait loop catches Empty and continues.
        time.sleep(timeout)
        raise Empty()


class _StubKM:
    """KernelManager stub. Bridge.is_alive() consults this in local mode."""
    def is_alive(self):
        return True


class RestartSeqAbort(unittest.TestCase):
    """Regression test for the worker-stuck-on-restart bug.

    Pre-fix: when restart fired while a cell was running, the worker thread
    sat in `get_shell_msg(timeout=0.2)` waiting for a reply with the *old*
    parent_id — which the brand-new kernel had never heard of. is_alive()
    was True (new kernel was fine), so it never bailed via kernel_dead.
    Every subsequent execute queued into task_q and was never read.

    Post-fix: _execute captures _restart_seq at entry and re-checks it inside
    its wait loops; on advance, it abandons the parent_id and returns.
    """

    def test_execute_aborts_when_restart_seq_advances(self):
        b = bridge.Bridge()
        b.kc = _StubKC()
        b.km = _StubKM()
        b.current_cell_id = "cell-A"

        # Drive _execute on a thread so we can observe it getting stuck and
        # then unstuck.
        t = threading.Thread(target=b._execute, args=("cell-A", "x=1"))
        t.start()

        # Wait until _execute has registered its parent_id. At that point we
        # know it's inside the shell-message wait loop.
        deadline = time.time() + 1.0
        while time.time() < deadline:
            if "fake-parent" in b.parent_to_cell:
                break
            time.sleep(0.01)
        self.assertIn("fake-parent", b.parent_to_cell,
                      "_execute never reached the wait loop within 1s")
        self.assertTrue(t.is_alive(), "_execute should still be in wait loop")

        # Simulate a restart by advancing the epoch. The in-flight _execute
        # must notice on its next iteration (within get_shell_msg's 0.2s
        # timeout) and bail.
        b._restart_seq += 1
        t.join(timeout=2.0)
        self.assertFalse(
            t.is_alive(),
            "_execute did not return after _restart_seq advanced — this would "
            "jam task_q indefinitely on every subsequent execute"
        )
        self.assertIsNone(b.current_cell_id,
                          "current_cell_id should be cleared on restart-abort")
        self.assertNotIn("fake-parent", b.parent_to_cell,
                         "parent_to_cell entry should be cleaned up on abort")


class RestartDrainsTaskQueue(unittest.TestCase):
    """restart() must drain orphan tasks from task_q.

    Pre-fix: if lua had sent an execute message that the worker hadn't yet
    popped before restart fired, the task would run on the *new* kernel even
    though lua had cleared its own queue on `"restarted"` — surprising the
    user with output for a cell they thought they'd cancelled.
    """

    def test_restart_drains_pending_tasks(self):
        b = bridge.Bridge()
        # Don't actually try to restart a real kernel — just exercise the
        # drain path. We force the else-branch by leaving km and kc both
        # None; restart() will jprint a kernel_error to stdout but the drain
        # happens before any of that.
        b.task_q.put(("c1", "code1"))
        b.task_q.put(("c2", "code2"))
        self.assertEqual(b.task_q.qsize(), 2)

        # Redirect stdout so the kernel_error JSON doesn't pollute test output.
        import io
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            b.restart()
        finally:
            sys.stdout = old_stdout

        self.assertEqual(b.task_q.qsize(), 0,
                         "restart() must drain orphan tasks so they don't "
                         "run on the new kernel")


class IopubRegistrationOrdering(unittest.TestCase):
    """parent_to_cell must be registered atomically with the kc.execute send.

    Pre-fix: kc.execute() returned, then `with self._lock` registered the
    mapping. Between those steps, an iopub_loop thread that pulled a
    frame from zmq could acquire the bridge lock first, look up
    parent_to_cell, get None, and silently drop the frame.

    Post-fix: kc.execute and the registration happen inside a single
    `with self._lock` block. Any iopub_loop trying to acquire the same
    lock to look up cell_id must wait until both have completed.

    We assert this by spying on the bridge lock state during the
    kc.execute call: the worker must already be holding the lock.
    """

    def test_bridge_lock_is_held_through_kc_execute(self):
        b = bridge.Bridge()
        observations = []
        # Captured by the get_shell_msg stub the first time it runs —
        # that's the earliest moment AFTER the kc.execute + register lock
        # block has released, but BEFORE the restart-seq abort path runs
        # _forget() and removes the entry again.
        snapshot = {}

        class LockSpyKC:
            def __init__(self, lock):
                self._lock = lock

            def execute(self, code, **kwargs):
                # If the worker is correctly holding the bridge lock,
                # non-blocking acquire returns False.
                got = self._lock.acquire(blocking=False)
                observations.append(got)
                if got:
                    self._lock.release()
                return "p1"

            def get_shell_msg(self, timeout=0.2):
                # First call: _execute has registered parent_to_cell["p1"]
                # = "c" inside the kc.execute lock block and is now waiting
                # on a shell reply. Snapshot the mapping; this proves the
                # registration landed.
                if not snapshot:
                    snapshot["parent_to_cell"] = dict(b.parent_to_cell)
                time.sleep(timeout)
                raise Empty()

        b.kc = LockSpyKC(b._lock)
        b.km = _StubKM()
        b.current_cell_id = "c"

        t = threading.Thread(target=b._execute, args=("c", "x=1"))
        t.start()
        # Wait until the worker has registered and entered the wait loop.
        deadline = time.time() + 1.0
        while time.time() < deadline:
            if snapshot:
                break
            time.sleep(0.005)
        # Bail _execute out of its shell-wait loop via the restart-seq path.
        b._restart_seq += 1
        t.join(timeout=2.0)

        self.assertFalse(t.is_alive(), "_execute should have returned")
        self.assertEqual(
            observations, [False],
            "during kc.execute, the bridge lock must be held by the worker — "
            "otherwise iopub_loop can read parent_to_cell before this cell's "
            "mapping is registered and silently drop output")
        # And the registration must already have landed by the time
        # _execute enters its wait loop.
        self.assertEqual(
            snapshot.get("parent_to_cell", {}).get("p1"), "c",
            "parent_to_cell must be populated atomically with kc.execute")


class IdleSeenLeak(unittest.TestCase):
    """A `status: idle` iopub frame whose parent_id is not in
    parent_to_cell must not write to `_idle_seen`. Without the gate, late
    idle frames (arriving after _execute's _forget cleaned up) accumulate
    indefinitely — a small but real memory leak over thousands of
    executes.
    """

    def _idle_msg(self, parent_id):
        return {
            "parent_header": {"msg_id": parent_id},
            "header": {"msg_type": "status"},
            "content": {"execution_state": "idle"},
        }

    def test_idle_for_known_parent_is_recorded(self):
        b = bridge.Bridge()
        b.parent_to_cell["p1"] = "c1"
        b._handle_iopub_msg(self._idle_msg("p1"))
        self.assertIn("p1", b._idle_seen)

    def test_idle_for_unknown_parent_is_dropped(self):
        b = bridge.Bridge()
        # parent_to_cell intentionally empty — simulates a late idle
        # frame arriving after _forget already ran.
        self.assertNotIn("p1", b.parent_to_cell)
        b._handle_iopub_msg(self._idle_msg("p1"))
        self.assertNotIn(
            "p1", b._idle_seen,
            "idle for an already-forgotten parent must not leak into "
            "_idle_seen — over many executes the dict grows without bound")

    def test_busy_status_is_ignored(self):
        # Only idle is tracked; busy/starting/etc. shouldn't touch state.
        b = bridge.Bridge()
        b.parent_to_cell["p1"] = "c1"
        msg = self._idle_msg("p1")
        msg["content"]["execution_state"] = "busy"
        b._handle_iopub_msg(msg)
        self.assertNotIn("p1", b._idle_seen)


class WorkerSurvivesExecuteException(unittest.TestCase):
    """The worker thread must keep running even if _execute raises.

    Pre-fix: an uncaught exception inside _execute terminated the worker
    thread. Subsequent tasks piled into task_q with nothing draining
    them — every future execute silently hung.

    Post-fix: the worker wraps _execute in try/except, emits a synthetic
    execute_done with an error item, and continues to the next task.
    """

    def test_worker_continues_after_execute_raises(self):
        import io, json

        b = bridge.Bridge()

        # Force _execute to raise on the FIRST call only. The second call
        # must still be reached — that's the regression we're guarding.
        calls = {"n": 0}
        original_execute = b._execute

        def _exploding_execute(cell_id, code):
            calls["n"] += 1
            if calls["n"] == 1:
                raise RuntimeError("boom from inside _execute")
            # Subsequent calls: just signal we got here, don't actually
            # try to talk to a kernel (kc/km are None).
            b.current_cell_id = None

        b._execute = _exploding_execute  # type: ignore[assignment]

        # Capture jprint output so we can verify the synthetic error landed.
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            worker = threading.Thread(target=b._worker_loop, daemon=True)
            worker.start()

            b.task_q.put(("c1", "code1"))   # will raise
            b.task_q.put(("c2", "code2"))   # must still run

            # Allow the worker to process both tasks.
            deadline = time.time() + 2.0
            while time.time() < deadline and calls["n"] < 2:
                time.sleep(0.02)

            # Shut the worker down cleanly.
            b.stop_event.set()
            b.task_q.put(None)
            worker.join(timeout=2.0)
            captured = sys.stdout.getvalue()
        finally:
            sys.stdout = old_stdout

        self.assertEqual(
            calls["n"], 2,
            "worker thread should have processed both tasks; if it died "
            "after the first exception, every subsequent execute would hang"
        )
        self.assertFalse(worker.is_alive(),
                         "worker should exit cleanly on stop_event + None task")

        # The error from the first task should have been reported as a
        # synthetic execute_done so the user sees what went wrong.
        msgs = [json.loads(line) for line in captured.splitlines() if line]
        error_msgs = [m for m in msgs
                      if m.get("type") == "execute_done"
                      and m.get("cell_id") == "c1"
                      and m.get("outputs")
                      and m["outputs"][0].get("type") == "error"]
        self.assertEqual(
            len(error_msgs), 1,
            "exactly one execute_done with an error output should have been "
            "emitted for the cell whose _execute raised; got: " + captured)
        self.assertIn("boom from inside _execute",
                      error_msgs[0]["outputs"][0]["evalue"])


class NoUsableKernelMessage(unittest.TestCase):
    """The exception class formats three distinct messages depending on
    which constructor args are set. Pre-fix, _make_local_km_from_python
    passed its error string as `requested`, producing a misleading
    "kernelspec '<long sentence>' not found" message.
    """
    def test_empty_available_lists_install_hint(self):
        e = bridge.NoUsableKernel(requested=None, available=[])
        msg = str(e)
        self.assertIn("no Jupyter kernelspecs", msg)
        self.assertIn("pip install ipykernel", msg)

    def test_requested_lists_available(self):
        e = bridge.NoUsableKernel(
            requested="python3.99",
            available=[{"name": "python3"}, {"name": "ir"}])
        msg = str(e)
        self.assertIn("kernelspec 'python3.99' not found", msg)
        self.assertIn("python3", msg)

    def test_default_python3_with_alternatives(self):
        e = bridge.NoUsableKernel(
            requested=None,
            available=[{"name": "ir"}])
        msg = str(e)
        self.assertIn("no default 'python3' kernelspec", msg)
        self.assertIn("ir", msg)

    def test_detail_message_passthrough(self):
        # The new `detail` arg shows verbatim, NOT wrapped in
        # "kernelspec '...' not found". Pre-fix, _make_local_km_from_python
        # passed an error sentence as `requested`, which got wrapped.
        e = bridge.NoUsableKernel(
            detail="python path must be absolute: /foo")
        self.assertEqual(str(e), "python path must be absolute: /foo")


class MakeLocalKmFromPython(unittest.TestCase):
    """Path-validation branches in _make_local_km_from_python."""

    def test_relative_path_raises_with_clear_message(self):
        with self.assertRaises(bridge.NoUsableKernel) as cm:
            bridge._make_local_km_from_python("relative/python")
        self.assertIn("must be absolute", str(cm.exception))
        # The message is verbatim, not wrapped in "kernelspec '...' not found".
        self.assertNotIn("kernelspec '", str(cm.exception))

    def test_non_existent_path_raises_with_clear_message(self):
        with self.assertRaises(bridge.NoUsableKernel) as cm:
            bridge._make_local_km_from_python("/no/such/file/python")
        self.assertIn("not executable", str(cm.exception))
        # Not wrapped.
        self.assertNotIn("kernelspec '", str(cm.exception))

    def test_non_executable_path_raises(self):
        import tempfile
        with tempfile.NamedTemporaryFile() as f:
            # File exists but is not executable.
            with self.assertRaises(bridge.NoUsableKernel) as cm:
                bridge._make_local_km_from_python(f.name)
            self.assertIn("not executable", str(cm.exception))


class MakeLocalKmFromSpecPath(unittest.TestCase):
    def test_missing_kernel_json_raises_with_clear_message(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            # Directory exists but has no kernel.json.
            with self.assertRaises(bridge.NoUsableKernel) as cm:
                bridge._make_local_km_from_spec_path(d)
            self.assertIn("no kernel.json", str(cm.exception))
            # The message is verbatim, not wrapped.
            self.assertNotIn("kernelspec '", str(cm.exception))


class ShortPythonLabel(unittest.TestCase):
    def test_venv_dotted(self):
        # /home/x/proj/.venv/bin/python -> ".venv (proj)"
        self.assertEqual(bridge._short_python_label("/home/x/proj/.venv/bin/python"),
                         ".venv (proj)")

    def test_venv_without_dot(self):
        self.assertEqual(bridge._short_python_label("/home/x/proj/venv/bin/python"),
                         "venv (proj)")

    def test_env_parent(self):
        self.assertEqual(bridge._short_python_label("/home/x/proj/env/bin/python"),
                         "env (proj)")

    def test_non_venv_returns_path(self):
        # Anything not under one of the recognized parent names is unchanged.
        self.assertEqual(bridge._short_python_label("/usr/bin/python3"),
                         "/usr/bin/python3")


class HandleIopubMsg(unittest.TestCase):
    """Bridge._handle_iopub_msg dispatch — happy paths for each msg type."""

    def _setup_bridge(self):
        b = bridge.Bridge()
        b.parent_to_cell["fake-parent"] = "cell-id"
        return b

    def _capture(self):
        """Return (capture_buf_list, cleanup)."""
        captured = []
        orig = bridge.jprint
        bridge.jprint = lambda obj: captured.append(obj)
        return captured, lambda: setattr(bridge, "jprint", orig)

    def _make_msg(self, msg_type, content):
        # msg_type lives on `header`, not at the top level, per Jupyter's
        # actual iopub frame shape.
        return {
            "header": {"msg_type": msg_type},
            "content": content,
            "parent_header": {"msg_id": "fake-parent"},
        }

    def test_stream_emits_output(self):
        b = self._setup_bridge()
        cap, cleanup = self._capture()
        try:
            b._handle_iopub_msg(self._make_msg(
                "stream", {"name": "stdout", "text": "hello"}))
        finally:
            cleanup()
        outs = [m for m in cap if m.get("type") == "output"]
        self.assertEqual(len(outs), 1)
        self.assertEqual(outs[0]["cell_id"], "cell-id")
        self.assertEqual(outs[0]["item"]["type"], "stream")

    def test_stream_with_list_text_is_joined(self):
        # Some kernels emit text as a list of strings. Normalize to a single
        # string before forwarding.
        b = self._setup_bridge()
        cap, cleanup = self._capture()
        try:
            b._handle_iopub_msg(self._make_msg(
                "stream", {"name": "stdout", "text": ["a", "b", "c"]}))
        finally:
            cleanup()
        outs = [m for m in cap if m.get("type") == "output"]
        self.assertEqual(outs[0]["item"]["text"], "abc")

    def test_display_data_emits_output(self):
        b = self._setup_bridge()
        cap, cleanup = self._capture()
        try:
            b._handle_iopub_msg(self._make_msg(
                "display_data",
                {"data": {"text/plain": "x"}, "metadata": {}}))
        finally:
            cleanup()
        outs = [m for m in cap if m.get("type") == "output"]
        self.assertEqual(outs[0]["item"]["type"], "display_data")

    def test_error_emits_output(self):
        b = self._setup_bridge()
        cap, cleanup = self._capture()
        try:
            b._handle_iopub_msg(self._make_msg(
                "error",
                {"ename": "ValueError", "evalue": "msg", "traceback": ["t"]}))
        finally:
            cleanup()
        outs = [m for m in cap if m.get("type") == "output"]
        self.assertEqual(outs[0]["item"]["type"], "error")
        self.assertEqual(outs[0]["item"]["ename"], "ValueError")

    def test_unknown_parent_is_dropped(self):
        # parent_to_cell doesn't know this parent_id → message is dropped
        # silently. Pre-fix, this could resurrect output on a cell that
        # was no longer running.
        b = bridge.Bridge()
        cap, cleanup = self._capture()
        try:
            b._handle_iopub_msg(self._make_msg(
                "stream", {"name": "stdout", "text": "ghost"}))
        finally:
            cleanup()
        # Nothing emitted (cell_id was None → drop).
        outs = [m for m in cap if m.get("type") == "output"]
        self.assertEqual(len(outs), 0)


class ListKernelspecsResilience(unittest.TestCase):
    """_list_kernelspecs returns [] when jupyter_client raises (covers the
    `except Exception: return []` defensive branch).
    """
    def test_returns_empty_on_exception(self):
        # Save and shadow jupyter_client.kernelspec.KernelSpecManager.
        import importlib.util
        spec = importlib.util.find_spec("jupyter_client.kernelspec")
        if spec is None:
            self.skipTest("jupyter_client not installed in test env")
        from jupyter_client import kernelspec as ks_mod

        class Boom:
            def get_all_specs(self):
                raise RuntimeError("simulated")

        orig = ks_mod.KernelSpecManager
        ks_mod.KernelSpecManager = Boom
        try:
            result = bridge._list_kernelspecs()
        finally:
            ks_mod.KernelSpecManager = orig
        self.assertEqual(result, [])


class InterruptInExistingMode(unittest.TestCase):
    """SPEC Invariant 26: interrupt is signal-based and requires owning the
    kernel process. In mode='existing' the bridge does NOT own the
    subprocess, so it must emit kernel_error{kind='unsupported'} instead
    of sending a control-channel interrupt_request that has nothing
    SIGINT-able on the receiving end.
    """

    def test_existing_mode_emits_unsupported_kernel_error(self):
        import io, json
        b = bridge.Bridge()
        # Simulate mode='existing': km is None but kc is set.
        b.km = None
        b.kc = object()
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            b.interrupt()
            captured = sys.stdout.getvalue()
        finally:
            sys.stdout = old_stdout
        msgs = [json.loads(line) for line in captured.splitlines() if line]
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["type"], "kernel_error")
        self.assertEqual(msgs[0]["kind"], "unsupported")
        self.assertIn("interrupt", msgs[0]["error"])

    def test_local_mode_calls_interrupt_kernel(self):
        # Sanity: in local mode the interrupt_kernel path is still taken
        # and an "interrupted" message lands. We stub km to record the call.
        import io, json
        b = bridge.Bridge()
        called = {"n": 0}

        class _StubKM:
            def interrupt_kernel(self_inner):
                called["n"] += 1

        b.km = _StubKM()
        b.kc = object()
        b.current_cell_id = "c1"
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            b.interrupt()
            captured = sys.stdout.getvalue()
        finally:
            sys.stdout = old_stdout
        self.assertEqual(called["n"], 1)
        msgs = [json.loads(line) for line in captured.splitlines() if line]
        self.assertTrue(any(m.get("type") == "interrupted" for m in msgs))


if __name__ == "__main__":
    unittest.main()
