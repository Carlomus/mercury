-- Verifies that Kernel:stop sends a graceful "shutdown" before yanking the
-- channel — without this, the bridge subprocess may exit via SIGTERM before
-- python's finally block runs km.shutdown_kernel(), leaking the kernel
-- subprocess on every notebook close.

local Kernel = require("mercury.kernel")

describe("kernel graceful shutdown", function()
  it("sends shutdown before chanclose / jobstop", function()
    local k = Kernel.new({})
    -- Pretend a bridge is connected.
    k.job_id = 4242
    k.chan = 4242

    local order = {}
    -- Capture _send payloads.
    k._send = function(self, payload) order[#order + 1] = payload end
    -- Avoid touching real jobs.
    local orig_chanclose = vim.fn.chanclose
    local orig_jobstop = vim.fn.jobstop
    local orig_jobwait = vim.fn.jobwait
    vim.fn.chanclose = function() order[#order + 1] = "chanclose"; return 0 end
    vim.fn.jobstop = function() order[#order + 1] = "jobstop"; return 0 end
    vim.fn.jobwait = function() order[#order + 1] = "jobwait"; return { 0 } end

    k:stop()

    vim.fn.chanclose = orig_chanclose
    vim.fn.jobstop = orig_jobstop
    vim.fn.jobwait = orig_jobwait

    -- shutdown must precede the forceful teardown.
    assert.is_table(order[1])
    assert.equals("shutdown", order[1].type)
    -- jobwait next (bounded), then chanclose, then jobstop.
    assert.equals("jobwait", order[2])
    assert.equals("chanclose", order[3])
    assert.equals("jobstop", order[4])
  end)

  it("resets state regardless of whether shutdown delivery succeeds", function()
    local k = Kernel.new({})
    k.job_id = 1; k.chan = 1
    k.queue = { { cell_id = "x" } }
    k.running = { cell_id = "y" }
    -- _send raises — stop must still tear down state.
    k._send = function() error("boom") end
    local orig_chanclose = vim.fn.chanclose
    local orig_jobstop = vim.fn.jobstop
    local orig_jobwait = vim.fn.jobwait
    vim.fn.chanclose = function() end
    vim.fn.jobstop = function() end
    vim.fn.jobwait = function() return { 0 } end

    k:stop()

    vim.fn.chanclose = orig_chanclose
    vim.fn.jobstop = orig_jobstop
    vim.fn.jobwait = orig_jobwait

    assert.is_nil(k.job_id)
    assert.is_nil(k.chan)
    assert.equals(0, #k.queue)
    assert.is_nil(k.running)
  end)

  it("_expected_exit_for survives the synchronous tail of stop() for a late on_exit", function()
    -- on_exit fires asynchronously (libuv schedules it after the process
    -- exits), so the order is:
    --   1. stop() runs synchronously, clears _stopping at the end,
    --   2. event loop ticks, on_exit fires.
    -- If on_exit consulted `_stopping` to decide whether the exit was
    -- intentional, by the time it ran the flag would already be false and
    -- a legitimate :NotebookKernelStop would emit a spurious
    -- "bridge exited unexpectedly" warning. The fix is the separate
    -- `_expected_exit_for` flag, which is pinned to the SPECIFIC job_id
    -- stop() observed (so a new job spawned after stop() can't consume the
    -- old stop()'s signal — SPEC § Graceful shutdown).
    local k = Kernel.new({ outputs = {} })
    k.job_id = 7; k.chan = 7
    k._send = function() end
    local orig_chanclose = vim.fn.chanclose
    local orig_jobstop = vim.fn.jobstop
    local orig_jobwait = vim.fn.jobwait
    vim.fn.chanclose = function() end
    vim.fn.jobstop = function() end
    vim.fn.jobwait = function() return { 0 } end

    k:stop()

    vim.fn.chanclose = orig_chanclose
    vim.fn.jobstop = orig_jobstop
    vim.fn.jobwait = orig_jobwait

    -- After stop() returns: _stopping was cleared (so the next execute can
    -- respawn — Invariant 13), but _expected_exit_for is still set to the
    -- specific job_id, waiting for the asynchronous on_exit to consume it.
    assert.is_false(k._stopping == true)
    assert.equals(7, k._expected_exit_for)
  end)

  it("marks running + queued cells as killed so no stale pills linger", function()
    -- Reproduces the bug found while auditing for "stuck state": Kernel:stop
    -- (called by :NotebookKernelStop and :NotebookKernelSelect) cleared
    -- self.running and self.queue but left the cells' output.status frozen
    -- at "running" / "queued", so the UI showed a permanent pill on cells
    -- whose kernel was gone.
    local outputs = {}
    local nb = {
      outputs = outputs,
      ensure_output = function(self, id)
        if not self.outputs[id] then self.outputs[id] = { items = {}, status = "idle" } end
        return self.outputs[id]
      end,
    }
    local k = Kernel.new(nb)
    k.job_id = 1; k.chan = 1
    k.running = { cell_id = "active" }
    k.queue = { { cell_id = "q1" }, { cell_id = "q2" } }
    nb:ensure_output("active").status = "running"
    nb:ensure_output("q1").status = "queued"
    nb:ensure_output("q2").status = "queued"

    -- Stub out the IPC primitives so we don't touch a real job.
    k._send = function() end
    local orig_chanclose = vim.fn.chanclose
    local orig_jobstop = vim.fn.jobstop
    local orig_jobwait = vim.fn.jobwait
    vim.fn.chanclose = function() end
    vim.fn.jobstop = function() end
    vim.fn.jobwait = function() return { 0 } end

    k:stop()

    vim.fn.chanclose = orig_chanclose
    vim.fn.jobstop = orig_jobstop
    vim.fn.jobwait = orig_jobwait

    assert.equals("killed", nb.outputs["active"].status)
    assert.equals("killed", nb.outputs["q1"].status)
    assert.equals("killed", nb.outputs["q2"].status)
    assert.is_nil(k.running)
    assert.equals(0, #k.queue)
  end)
end)
