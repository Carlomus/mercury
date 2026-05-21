-- Exercises Kernel:_handle_msg state transitions for the lifecycle messages
-- that can otherwise leave the queue / running state stuck:
--   - restarted: clears running + queue, marks current cell killed
--   - kernel_dead: same, plus a user-facing error notification
--   - kernels_listed: invokes the registered callback exactly once

local Kernel = require("mercury.kernel")

local function fake_notebook()
  local nb = {
    outputs = {},
    -- Kernel:_handle_msg looks up cells.kind to decide whether to apply an
    -- iopub frame (SPEC invariants 19, 20). Tests in this file create cells
    -- implicitly via ensure_output(id) — mirror them here as code cells so
    -- the lifecycle-message handlers see a complete notebook view.
    cells = {},
  }
  nb.ensure_output = function(self, id)
    if not self.outputs[id] then
      self.outputs[id] = { items = {}, status = "idle" }
    end
    local found = false
    for _, c in ipairs(self.cells) do
      if c.id == id then found = true; break end
    end
    if not found then
      self.cells[#self.cells + 1] = { id = id, kind = "code" }
    end
    return self.outputs[id]
  end
  nb.clear_all_outputs = function(self) self.outputs = {} end
  return nb
end

describe("kernel lifecycle messages", function()
  it("Kernel:restart cancels in-flight cells synchronously, before any reply", function()
    -- The fix here: Kernel:restart used to just send {type=restart} and wait
    -- for the bridge's `restarted` event to clear running+queue. In that
    -- window, _pump's `if self.running then return` guard refused to run
    -- any new cell the user queued, and when `restarted` finally arrived
    -- _cancel_in_flight then wiped the freshly-queued cell too. By cancelling
    -- synchronously up-front, the user can re-enqueue immediately after
    -- restart without races; the eventual `restarted` is a no-op for state.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    -- Pretend the bridge is up. The fake chan id makes chansend fail under
    -- the hood, but _send pcalls it; we don't need the message to actually
    -- reach a real bridge to verify the *local* state mutation order.
    k.chan = 999999
    k.running = { cell_id = "running", started_at = 0 }
    k.queue = {
      { cell_id = "q1", code = "x" },
      { cell_id = "q2", code = "y" },
    }
    nb:ensure_output("running").status = "running"
    nb:ensure_output("q1").status = "queued"
    nb:ensure_output("q2").status = "queued"

    k:restart()

    assert.is_nil(k.running,
      "Kernel:restart must clear self.running synchronously so the next "
      .. ":NotebookExec is not refused by _pump's guard")
    assert.equals(0, #k.queue,
      "Kernel:restart must clear the queue synchronously")
    assert.equals("killed", nb.outputs["running"].status)
    assert.equals("killed", nb.outputs["q1"].status)
    assert.equals("killed", nb.outputs["q2"].status)
  end)

  it("Kernel:restart{ clear = true } also wipes cached outputs", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.chan = 999999
    nb:ensure_output("old").items = { { type = "stream", text = "previously" } }
    nb:ensure_output("old").status = "ok"

    k:restart({ clear = true })

    -- clear_all_outputs wipes nb.outputs entirely; the previous "old" entry
    -- is gone, not just status-flipped.
    assert.is_nil(rawget(nb.outputs, "old"))
  end)

  it("restarted message clears running, queue, and marks cell killed", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "abc", started_at = 0 }
    k.queue = { { cell_id = "next", code = "x" } }
    -- Seed a "running" output we can verify gets killed.
    nb:ensure_output("abc").status = "running"

    k:_handle_msg({ type = "restarted" })

    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
    assert.equals("killed", nb.outputs["abc"].status)
  end)

  it("kernel_dead message clears state even with nothing running", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.queue = { { cell_id = "x" }, { cell_id = "y" } }
    -- No `running`. kernel_dead should still clear the queue cleanly.
    k:_handle_msg({ type = "kernel_dead", error = "boom" })

    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
  end)

  it("kernel_dead during execution marks the running cell as killed", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "active", started_at = 0 }
    nb:ensure_output("active").status = "running"

    k:_handle_msg({ type = "kernel_dead", error = "boom" })

    assert.equals("killed", nb.outputs["active"].status)
    assert.is_nil(k.running)
  end)

  it("kernels_listed fires the registered callback exactly once", function()
    local k = Kernel.new(fake_notebook())
    local calls = 0
    local got
    k._on_list = function(kernels) calls = calls + 1; got = kernels end

    k:_handle_msg({ type = "kernels_listed",
                    kernels = { { name = "python3", display_name = "P3" } } })
    assert.equals(1, calls)
    assert.equals("python3", got[1].name)
    -- After firing, the callback is consumed; a second message must NOT
    -- re-invoke a stale handler.
    k:_handle_msg({ type = "kernels_listed", kernels = {} })
    assert.equals(1, calls)
  end)

  it("interrupted with no queued cells just clears the running one", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "i", started_at = 0 }
    nb:ensure_output("i").status = "running"

    k:_handle_msg({ type = "interrupted" })

    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
    assert.equals("killed", nb.outputs["i"].status)
  end)

  it("execute_done sets ok status and pumps the queue", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    -- Simulate that we already sent the first execute and are waiting.
    k.running = { cell_id = "first", started_at = 0 }
    nb:ensure_output("first").status = "running"
    -- Stub _pump so we can observe it firing without needing a real channel.
    local pumped = 0
    k._pump = function() pumped = pumped + 1 end

    k:_handle_msg({ type = "execute_done", cell_id = "first",
                    exec_count = 5, ms = 100 })

    assert.is_nil(k.running)
    assert.equals(1, pumped)
    assert.equals("ok", nb.outputs["first"].status)
    assert.equals(5, nb.outputs["first"].exec_count)
    assert.equals(100, nb.outputs["first"].ms)
  end)

  it("execute_done preserves error status if an error item already arrived", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "bad", started_at = 0 }
    local out = nb:ensure_output("bad")
    out.status = "error"
    k._pump = function() end

    k:_handle_msg({ type = "execute_done", cell_id = "bad",
                    exec_count = 6, ms = 50 })

    assert.equals("error", nb.outputs["bad"].status)
  end)

  it("interrupted cancels only the running cell, queue continues (Jupyter semantics)", function()
    -- Jupyter's interrupt SIGINTs the kernel, stopping the running cell with
    -- KeyboardInterrupt. Queued cells continue to execute after the current
    -- one finishes — they are NOT cancelled. Use restart/stop to drop the
    -- queue.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "active", started_at = 0 }
    k.queue = { { cell_id = "q1" }, { cell_id = "q2" } }
    nb:ensure_output("active").status = "running"
    nb:ensure_output("q1").status = "queued"
    nb:ensure_output("q2").status = "queued"

    k:_handle_msg({ type = "interrupted" })

    assert.equals("killed", nb.outputs["active"].status)
    assert.is_nil(k.running)
    -- Queue must survive interrupt — the next cell pumps once the
    -- interrupted cell's execute_done arrives.
    assert.equals(2, #k.queue)
    assert.equals("q1", k.queue[1].cell_id)
    assert.equals("queued", nb.outputs["q1"].status)
    assert.equals("queued", nb.outputs["q2"].status)
  end)

  it("restart does not resurrect killed pills on cells whose outputs were cleared", function()
    -- :NotebookKernelRestartClear sequence:
    --   1. lua sends `restart` to bridge
    --   2. lua calls clear_all_outputs() — wipes self.outputs
    --   3. bridge emits "restarted"
    --   4. lua _cancel_in_flight("killed") runs
    -- Without the "only update existing entries" guard in step 4, ensure_output
    -- would synthesize a fresh entry for each previously-running/queued cell
    -- and stamp it "killed" — defeating the clear.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "r", started_at = 0 }
    k.queue = { { cell_id = "q" } }
    -- Simulate the clear that NotebookKernelRestartClear performs.
    nb.outputs = {}

    k:_handle_msg({ type = "restarted" })

    -- No phantom entries should have been created for either cell.
    assert.is_nil(nb.outputs["r"])
    assert.is_nil(nb.outputs["q"])
    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
  end)

  it("execute_done preserves 'killed' status set by interrupted handler", function()
    -- Race: `interrupted` arrives before the kernel's iopub error message,
    -- so out.status is already "killed" when execute_done lands. Without
    -- the preserve-killed guard, execute_done downgrades to "ok", losing
    -- the user-visible signal that the cell was interrupted.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "x", started_at = 0 }
    nb:ensure_output("x").status = "killed"
    k._pump = function() end

    k:_handle_msg({ type = "execute_done", cell_id = "x",
                    exec_count = 9, ms = 12 })

    assert.equals("killed", nb.outputs["x"].status)
  end)

  it("restarted marks BOTH running and queued cells as killed", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "active", started_at = 0 }
    k.queue = { { cell_id = "q1" } }
    nb:ensure_output("active").status = "running"
    nb:ensure_output("q1").status = "queued"

    k:_handle_msg({ type = "restarted" })

    assert.equals("killed", nb.outputs["active"].status)
    assert.equals("killed", nb.outputs["q1"].status)
    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
  end)

  it("kernel_dead marks BOTH running and queued cells as killed", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "active", started_at = 0 }
    k.queue = { { cell_id = "q1" } }
    nb:ensure_output("active").status = "running"
    nb:ensure_output("q1").status = "queued"

    k:_handle_msg({ type = "kernel_dead", error = "boom" })

    assert.equals("killed", nb.outputs["active"].status)
    assert.equals("killed", nb.outputs["q1"].status)
  end)

  it("interrupted does NOT downgrade an already-error status to killed", function()
    -- Race: iopub `error` arrives first, sets out.status = "error". Then
    -- `interrupted` lands. The user must still see the error pill — the
    -- traceback is the load-bearing signal. SPEC invariant 10 (extended).
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "boom", started_at = 0 }
    nb:ensure_output("boom").status = "error"

    k:_handle_msg({ type = "interrupted" })

    assert.equals("error", nb.outputs["boom"].status)
  end)

  it("kernel_dead does NOT downgrade an already-error status to killed", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "boom", started_at = 0 }
    nb:ensure_output("boom").status = "error"

    k:_handle_msg({ type = "kernel_dead", error = "rip" })

    assert.equals("error", nb.outputs["boom"].status)
  end)

  it("update_display_data updates items across cells (H3: cross-cell display)", function()
    -- Jupyter Lab and VS Code update displays across cells. Cell A registers
    -- a display_id; cell B's update_display(...) refreshes the display in
    -- cell A. Pre-fix, _apply_item only searched the cell whose iopub
    -- parent_id matched — so a cross-cell update was silently dropped onto
    -- the emitting cell as a new display_data.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    -- Cell A: had a display_data registered earlier.
    local out_a = nb:ensure_output("cellA")
    out_a.items = {
      { type = "display_data", data = { ["text/plain"] = "v1" },
        _display_id = "shared", metadata = {} },
    }
    -- Cell B: now running; its update_display_data targets cellA's display.
    local out_b = nb:ensure_output("cellB")

    k:_apply_item(out_b, { type = "update_display_data",
      data = { ["text/plain"] = "v2" },
      transient = { display_id = "shared" } })

    -- Cell A's item was updated in place.
    assert.equals("v2", out_a.items[1].data["text/plain"])
    -- Cell B did NOT get a stray display_data appended.
    assert.equals(0, #out_b.items)
  end)

  it("update_display_data updates ALL items with matching display_id", function()
    -- IPython.display.update_display(...) updates every bound item, not
    -- just the first.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    local out = nb:ensure_output("x")
    out.items = {
      { type = "display_data", data = { ["text/plain"] = "v1" },
        _display_id = "shared" },
      { type = "display_data", data = { ["text/plain"] = "between" } },
      { type = "display_data", data = { ["text/plain"] = "v1" },
        _display_id = "shared" },
    }

    k:_apply_item(out, { type = "update_display_data",
      data = { ["text/plain"] = "v2" },
      transient = { display_id = "shared" } })

    assert.equals("v2", out.items[1].data["text/plain"])
    assert.equals("between", out.items[2].data["text/plain"])
    assert.equals("v2", out.items[3].data["text/plain"])
    -- Must not have appended.
    assert.equals(3, #out.items)
  end)

  it("execute() refuses to queue a cell that's already running", function()
    -- Without dedup, a rapid double-<S-CR> would push a second task; when the
    -- first run finishes and the second pops, _pump's `out.items = {}` would
    -- wipe the live output from the first run that the user is watching.
    local Notebook = require("mercury.notebook")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=dupe0001", "print('x')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb)
    nb:set_kernel(k)
    k._ensure_started = function() return true end
    k._send = function() return true end
    -- First execute: queued + pumped to running.
    k:execute(nb.cells[1])
    assert.is_not_nil(k.running)
    assert.equals("dupe0001", k.running.cell_id)
    assert.equals(0, #k.queue)
    -- Second execute on the same cell while running: no-op.
    k:execute(nb.cells[1])
    assert.equals(0, #k.queue)
    -- Send another distinct queued one, then re-execute that one — also a no-op.
    k.queue = { { cell_id = "dupe0001", code = "x" } }
    k.running = nil
    k:execute(nb.cells[1])
    assert.equals(1, #k.queue)   -- did not double up
    Notebook.detach(buf)
  end)

  it("_ensure_started refuses while _stopping is true", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k._stopping = true
    assert.is_false(k:_ensure_started())
  end)

  it("clear_output(wait=True) at end of cell wipes prior output", function()
    -- tqdm idiom: clear progress bar before exiting the loop. If we left
    -- _pending_clear set after execute_done, the previous run's items would
    -- survive into the next execute — confusing.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "tqdm", started_at = 0 }
    local out = nb:ensure_output("tqdm")
    out.status = "running"
    out.items = { { type = "stream", text = "progress: 100%" } }
    k._pump = function() end

    -- Deferred clear, no subsequent item.
    k:_apply_item(out, { type = "clear_output", wait = true })
    assert.is_true(out._pending_clear)
    assert.equals(1, #out.items)   -- still pending

    -- Cell finishes.
    k:_handle_msg({ type = "execute_done", cell_id = "tqdm",
                    exec_count = 1, ms = 5 })
    assert.equals(0, #out.items)
    assert.is_nil(out._pending_clear)
    assert.equals("ok", out.status)
  end)

  it("Kernel:interrupt sends interrupt message when bridge is running", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.chan = 999999
    local sent
    k._send = function(self, payload) sent = payload; return true end
    k:interrupt()
    assert.is_not_nil(sent)
    assert.equals("interrupt", sent.type)
  end)

  it("Kernel:interrupt notifies when bridge is not running", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    -- No chan set.
    local notifications = {}
    local Util = require("mercury.util")
    local orig = Util.notify
    Util.notify = function(msg, level)
      notifications[#notifications + 1] = msg
    end
    k:interrupt()
    Util.notify = orig
    assert.is_true(#notifications > 0)
    assert.matches("not running", notifications[1])
  end)

  it("Kernel:restart notifies when bridge is not running", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    local notifications = {}
    local Util = require("mercury.util")
    local orig = Util.notify
    Util.notify = function(msg) notifications[#notifications + 1] = msg end
    k:restart()
    Util.notify = orig
    assert.is_true(#notifications > 0)
    assert.matches("not running", notifications[1])
  end)

  it("_send returns false and notifies on chansend raising", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.chan = -1  -- invalid channel id
    -- chansend with -1 raises E900 (invalid channel id).
    local notifications = {}
    local Util = require("mercury.util")
    local orig = Util.notify
    Util.notify = function(msg) notifications[#notifications + 1] = msg end
    local ok = k:_send({ type = "execute", cell_id = "x", code = "1" })
    Util.notify = orig
    assert.is_false(ok)
    assert.is_true(#notifications > 0)
    assert.matches("failed to send", notifications[1])
  end)

  it("_send returns false when self.chan is nil (bridge not started)", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    -- chan is nil by default.
    assert.is_false(k:_send({ type = "execute" }))
  end)

  it("_apply_item clear_output with wait=false synchronously wipes items", function()
    -- The synchronous-clear branch (no _pending_clear flag). Pre-fix tests
    -- only exercised wait=true; the sync branch was the dead-test branch.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    local out = nb:ensure_output("c")
    out.items = { { type = "stream", text = "before" } }
    out._pending_clear = true  -- pretend a prior deferred-clear was pending
    k:_apply_item(out, { type = "clear_output", wait = false })
    assert.equals(0, #out.items)
    assert.is_nil(out._pending_clear)
  end)

  it("_apply_item consumes _pending_clear before inserting the next item (tqdm pattern)", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    local out = nb:ensure_output("tqdm")
    out.items = { { type = "stream", text = "progress: 50%" } }
    -- User code calls clear_output(wait=True); then emits the next progress frame.
    k:_apply_item(out, { type = "clear_output", wait = true })
    assert.is_true(out._pending_clear)
    -- The prior items survive UNTIL the next item arrives.
    assert.equals(1, #out.items)
    -- Now the next frame arrives.
    k:_apply_item(out, { type = "stream", name = "stdout", text = "progress: 75%" })
    -- The pending clear was consumed BEFORE inserting the new item.
    assert.equals(1, #out.items)
    assert.equals("progress: 75%", out.items[1].text)
    assert.is_nil(out._pending_clear)
  end)

  it("_apply_item coalesces consecutive same-name stream items", function()
    -- Multiple stream chunks with same name should concatenate into one.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    local out = nb:ensure_output("c")
    k:_apply_item(out, { type = "stream", name = "stdout", text = "ab" })
    k:_apply_item(out, { type = "stream", name = "stdout", text = "cd" })
    assert.equals(1, #out.items)
    assert.equals("abcd", out.items[1].text)
  end)

  it("_apply_item does NOT coalesce stream items with different names", function()
    -- stdout and stderr stay as separate entries.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    local out = nb:ensure_output("c")
    k:_apply_item(out, { type = "stream", name = "stdout", text = "out" })
    k:_apply_item(out, { type = "stream", name = "stderr", text = "err" })
    assert.equals(2, #out.items)
  end)

  it("_apply_item with unknown type falls through to raw insertion", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    local out = nb:ensure_output("c")
    k:_apply_item(out, { type = "foobar_future", data = "x" })
    assert.equals(1, #out.items)
    assert.equals("foobar_future", out.items[1].type)
  end)

  it("execute is a no-op on non-code cells", function()
    local Notebook = require("mercury.notebook")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=mdcell01 [markdown]", "prose",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb)
    nb:set_kernel(k)
    -- Stub bridge so a happy path could run.
    k._ensure_started = function() return true end
    k._send = function() return true end
    k:execute(nb.cells[1])  -- markdown cell
    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
    Notebook.detach(buf)
  end)

  it("list_kernels queues multiple callbacks without losing any (post-fix)", function()
    -- Pre-fix: two concurrent list_kernels calls overwrote each other's
    -- callback. Post-fix: callbacks are queued in arrival order.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k._ensure_started = function() return true end
    local sent_count = 0
    k._send = function() sent_count = sent_count + 1; return true end
    local r1, r2
    k:list_kernels(function(ks) r1 = ks end)
    -- Second call while first is in flight: queued, no second wire send.
    k:list_kernels(function(ks) r2 = ks end)
    assert.equals(1, sent_count)
    -- Bridge eventually replies.
    k:_handle_msg({ type = "kernels_listed", kernels = { { name = "python3" } } })
    assert.is_not_nil(r1)
    assert.is_not_nil(r2)
    assert.equals("python3", r1[1].name)
    assert.equals("python3", r2[1].name)
  end)

  it("unknown _handle_msg type emits a once-per-type warning (protocol drift detection)", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    local notifications = {}
    local Util = require("mercury.util")
    local orig = Util.notify
    Util.notify = function(msg) notifications[#notifications + 1] = msg end
    k:_handle_msg({ type = "from_the_future" })
    -- Once.
    assert.equals(1, #notifications)
    assert.matches("unrecognized", notifications[1])
    -- Calling again with the same typ is rate-limited (no second notify).
    k:_handle_msg({ type = "from_the_future" })
    assert.equals(1, #notifications)
    -- But a DIFFERENT unknown type does notify again.
    k:_handle_msg({ type = "different_future" })
    assert.equals(2, #notifications)
    Util.notify = orig
  end)

  it("_pump rolls back running state when _send fails (H2: stuck-running guard)", function()
    -- _send can fail two ways: (1) pcall on chansend raises (invalid channel
    -- id), or (2) chansend returns 0 (closed channel). Pre-fix, _pump
    -- ignored _send's return value and set self.running before sending.
    -- If the send failed, no execute_done would ever arrive — _pump's
    -- `if self.running then return end` guard would block every future
    -- execute and the only recovery was :NotebookKernelStop.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.chan = 999999  -- fake invalid channel
    -- Simulate _send failure by setting chan to nil right before the test
    -- pumps. _send returns false because self.chan is nil.
    k.queue = { { cell_id = "c1", code = "x" } }
    -- Force _send to fail.
    k._send = function() return false end
    k:_pump()
    -- self.running must be rolled back so the next execute can proceed.
    assert.is_nil(k.running)
    assert.equals("killed", nb.outputs["c1"].status)
  end)

  it("_pump succeeds normally when _send succeeds", function()
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.chan = 999999
    k.queue = { { cell_id = "c1", code = "x" } }
    k._send = function() return true end
    k:_pump()
    -- Now running, waiting for execute_done.
    assert.is_not_nil(k.running)
    assert.equals("c1", k.running.cell_id)
    assert.equals("running", nb.outputs["c1"].status)
  end)

  it("restarted handler does NOT re-cancel cells queued during the restart window (H1 race)", function()
    -- The bridge processes stdin sequentially. If the user presses <S-CR>
    -- between Kernel:restart sending {type=restart} and the bridge emitting
    -- `restarted`, the new execute_request sits in the bridge's stdin buffer
    -- and is processed AFTER restarted comes back. Pre-fix: the restarted
    -- handler ran _cancel_in_flight unconditionally, killing the queued cell
    -- before the new kernel even saw it. The user saw "killed" while the
    -- code still executed on the kernel with side effects.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.chan = 999999
    k.running = { cell_id = "old", started_at = 0 }
    k.queue = { { cell_id = "queued_during_restart", code = "new" } }
    nb:ensure_output("old").status = "running"

    -- Trigger restart. This synchronously cancels in-flight (clearing the
    -- pre-restart cells) and sets _restart_pending. The user's hypothetical
    -- new keystroke would have been processed by execute() AFTER the cancel
    -- — simulate that here by re-queuing a fresh cell.
    k:restart()
    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
    assert.is_true(k._restart_pending)
    -- User queues a new cell during the restart window.
    k.queue = { { cell_id = "fresh", code = "f()" } }
    nb:ensure_output("fresh").status = "queued"

    -- Bridge eventually replies `restarted`. The handler must NOT cancel
    -- the freshly queued cell.
    k:_handle_msg({ type = "restarted" })

    assert.is_false(k._restart_pending)
    assert.equals(1, #k.queue)
    assert.equals("fresh", k.queue[1].cell_id)
    assert.equals("queued", nb.outputs["fresh"].status)
  end)

  it("restarted handler cancels in-flight cells when not user-initiated", function()
    -- Defensive path: if the bridge ever spontaneously emitted `restarted`
    -- without us asking (no synchronous _cancel_in_flight has run), we must
    -- still cancel — the old kernel is gone and its parent_id-tagged
    -- pending replies will never arrive.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k._restart_pending = false   -- spontaneous restart
    k.running = { cell_id = "running_when_killed", started_at = 0 }
    k.queue = { { cell_id = "q1" } }
    nb:ensure_output("running_when_killed").status = "running"
    nb:ensure_output("q1").status = "queued"

    k:_handle_msg({ type = "restarted" })

    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
    assert.equals("killed", nb.outputs["running_when_killed"].status)
    assert.equals("killed", nb.outputs["q1"].status)
  end)

  it("unexpected bridge exit cancels in-flight cells and resets state", function()
    -- The crash path of the on_exit callback. SPEC cancellation table row 5:
    -- "Bridge exits unexpectedly (on_exit without _expected_exit)" — must
    -- mark both running and queue as killed and clear state so the next
    -- execute can respawn the bridge cleanly. Without this _pump's
    -- `if self.running then return end` guard would block every future
    -- execute forever.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.job_id = 42
    k.chan = 42
    k.json_buf = "leftover"
    k._expected_exit = false
    k.running = { cell_id = "live", started_at = 0 }
    k.queue = { { cell_id = "q1" } }
    nb:ensure_output("live").status = "running"
    nb:ensure_output("q1").status = "queued"

    k:_handle_exit(42)

    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
    assert.is_nil(k.job_id)
    assert.is_nil(k.chan)
    assert.equals("", k.json_buf)
    assert.is_false(k._expected_exit)
    assert.is_false(k._stopping)
    assert.equals("killed", nb.outputs["live"].status)
    assert.equals("killed", nb.outputs["q1"].status)
  end)

  it("expected bridge exit (Kernel:stop) consumes _expected_exit without notifying", function()
    -- The clean shutdown path: Kernel:stop set _expected_exit=true and called
    -- jobstop. on_exit fires later. We must NOT _cancel_in_flight again
    -- (stop() already did) and must NOT show a "kernel bridge exited
    -- unexpectedly" warning. Crucially _expected_exit must be cleared so a
    -- subsequent real crash isn't masked.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.job_id = 42
    k.chan = 42
    k._expected_exit = true
    -- running/queue were already cleared by stop(); on_exit must not flip
    -- a stray output that happens to be "killed" back to anything else.
    nb:ensure_output("alreadydone").status = "killed"

    k:_handle_exit(42)

    assert.is_nil(k.job_id)
    assert.is_false(k._expected_exit)
    -- Pre-existing killed status is untouched (sticky terminal).
    assert.equals("killed", nb.outputs["alreadydone"].status)
  end)

  it("stale on_exit for an old job_id is ignored", function()
    -- After stop+respawn, the OLD job's on_exit may still fire later. We
    -- must NOT clear self.job_id (it now points at the NEW bridge) or we'd
    -- silently break every subsequent execute.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.job_id = 999  -- the NEW bridge
    k.chan = 999
    k._expected_exit = true  -- still expected from a prior stop()
    k.running = { cell_id = "newly_queued", started_at = 0 }

    k:_handle_exit(42)  -- stale callback for an old job_id

    -- New job state is preserved.
    assert.equals(999, k.job_id)
    assert.equals(999, k.chan)
    assert.is_true(k._expected_exit)
    -- Running cell is untouched.
    assert.is_not_nil(k.running)
  end)

  it("kernel_error with kind=no_kernelspec triggers the picker (H11)", function()
    -- When the bridge can't find the requested kernelspec/python, it sends
    -- kernel_error{kind="no_kernelspec", available={...}}. The Lua side must
    -- cancel in-flight cells AND prompt the user to pick a different kernel.
    -- Pre-fix this branch existed but was untested; a regression that
    -- forgot to call _prompt_select_kernel (or routed it through a stub)
    -- would silently drop the user into a dead bridge.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "live", started_at = 0 }
    nb:ensure_output("live").status = "running"
    local prompted_with
    k._prompt_select_kernel = function(self, available)
      prompted_with = available
    end

    k:_handle_msg({
      type = "kernel_error", kind = "no_kernelspec",
      error = "no such kernelspec",
      available = { { name = "python3", display_name = "Python 3" } },
    })

    assert.is_nil(k.running)
    assert.equals("killed", nb.outputs["live"].status)
    assert.is_table(prompted_with)
    assert.equals("python3", prompted_with[1].name)
  end)

  it("kernel_error with kind=missing_module surfaces as ERROR (H11)", function()
    -- jupyter_client or ipykernel not importable in the resolved python.
    -- This is a hard error (user must install the module); we mark it
    -- ERROR-level so it isn't lost in the WARN noise floor.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "live", started_at = 0 }
    nb:ensure_output("live").status = "running"
    local notifications = {}
    local Util = require("mercury.util")
    local orig = Util.notify
    Util.notify = function(msg, level)
      notifications[#notifications + 1] = { msg = msg, level = level }
    end

    k:_handle_msg({
      type = "kernel_error", kind = "missing_module",
      error = "module 'jupyter_client' not found in /usr/bin/python",
    })
    Util.notify = orig

    assert.is_nil(k.running)
    assert.equals("killed", nb.outputs["live"].status)
    -- The fatal-error notify is ERROR level, not WARN.
    local found_error = false
    for _, n in ipairs(notifications) do
      if n.level == vim.log.levels.ERROR and n.msg:find("missing_module") or
         (n.level == vim.log.levels.ERROR and n.msg:find("jupyter_client")) then
        found_error = true
      end
    end
    assert.is_true(found_error)
  end)

  it("kernel_error with kind=unsupported does NOT clobber running/queue", function()
    -- The bridge emits this kind when a request can't be served by the
    -- current transport (e.g., interrupt in existing-kernel mode). The cell
    -- is still executing on whatever kernel we're connected to, so treating
    -- it like kernel_dead would falsely mark a live cell as killed.
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "live", started_at = 0 }
    k.queue = { { cell_id = "q1" } }
    nb:ensure_output("live").status = "running"

    k:_handle_msg({ type = "kernel_error", kind = "unsupported",
                    error = "interrupt not supported here" })

    -- Running cell is untouched; queue is untouched.
    assert.is_not_nil(k.running)
    assert.equals("live", k.running.cell_id)
    assert.equals(1, #k.queue)
    assert.equals("running", nb.outputs["live"].status)
  end)
end)
