local Cfg = require("mercury.config")
local Kernel = require("mercury.kernel")
local Notebook = require("mercury.notebook")

local function fake_bridge_script()
  -- A tiny Python that reads JSONL on stdin and replies with scripted msgs.
  return [[
import sys, json, time
def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    try: req = json.loads(line)
    except: continue
    t = req.get("type")
    if t == "init":
        out({"type": "ready"})
    elif t == "execute":
        cid = req["cell_id"]; code = req["code"]
        out({"type": "execute_start", "cell_id": cid})
        out({"type": "output", "cell_id": cid, "item":
             {"type": "stream", "name": "stdout", "text": "hi\n"}})
        out({"type": "execute_done", "cell_id": cid, "exec_count": 1, "ms": 5})
    elif t == "list_kernels":
        out({"type": "kernels_listed", "kernels":
             [{"name":"python3","display_name":"Python 3","language":"python"}]})
    elif t == "shutdown":
        break
]]
end

describe("kernel client", function()
  it("queues an execute and applies the streaming output", function()
    local tmp = vim.fn.tempname() .. ".py"
    local f = io.open(tmp, "w"); f:write(fake_bridge_script()); f:close()

    Cfg.setup({ bridge_cmd = { "python3", "-u", tmp } })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=aaaa1111", "print('hi')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)

    kernel:execute(nb.cells[1])
    -- Wait for execute_done.
    local deadline = vim.loop.hrtime() + 5e9
    while vim.loop.hrtime() < deadline do
      vim.wait(50, function() return false end)
      local out = nb.outputs["aaaa1111"]
      if out and out.status == "ok" then break end
    end
    local out = nb.outputs["aaaa1111"]
    assert.is_not_nil(out)
    assert.equals("ok", out.status)
    assert.equals(1, out.exec_count)
    assert.equals("stream", out.items[1].type)
    assert.equals("hi\n", out.items[1].text)

    kernel:stop()
    Notebook.detach(buf)
  end)

  it("drops iopub output frames for a cell that has been deleted", function()
    -- SPEC invariant 19. The kernel keeps emitting output until execute_done
    -- even if the cell is deleted mid-execution. Without the _live_code_cell
    -- guard in _handle_msg, every chunk would resurrect nb.outputs[cell.id]
    -- via ensure_output — a transient memory leak that gets re-GC'd only on
    -- the next TextChanged, and renders nothing visible (the renderer
    -- iterates nb.cells, not nb.outputs), but it's the kind of "harmless"
    -- inconsistency that tends to compound into a real bug eventually.
    local buf = vim.api.nvim_create_buf(false, true)
    -- Empty notebook; "ghost00x" is not in nb.cells.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %% id=existing", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)
    kernel:_handle_msg({
      type = "output", cell_id = "ghost00x",
      item = { type = "stream", name = "stdout", text = "leaked\n" },
    })
    assert.is_nil(nb.outputs["ghost00x"])
    Notebook.detach(buf)
  end)

  it("drops iopub output frames for a cell converted to markdown", function()
    -- A user editing the separator text directly to convert a running cell
    -- to markdown bypasses set_kind's busy-guard. The defense-in-depth
    -- guard in _handle_msg must catch this so output doesn't render below
    -- prose. SPEC invariants 19 + 20.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false,
      { "# %% id=mdcell12 [markdown]", "# hi" })
    local nb = Notebook.attach(buf); nb:rescan()
    assert.equals("markdown", nb.cells[1].kind)
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)
    kernel:_handle_msg({
      type = "output", cell_id = "mdcell12",
      item = { type = "stream", name = "stdout", text = "leaked\n" },
    })
    assert.is_nil(nb.outputs["mdcell12"])
    Notebook.detach(buf)
  end)

  it("execute_done still advances the queue when the cell vanished", function()
    -- A deleted-mid-execution cell still gets an execute_done from the
    -- kernel. The output mutation is skipped, but self.running must be
    -- cleared and _pump must run so the next queued cell starts. Otherwise
    -- deleting a running cell would jam the queue forever. SPEC 19.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false,
      { "# %% id=alive001", "y = 2" })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)
    kernel.running = { cell_id = "ghost001", started_at = 0 }
    kernel.queue = { { cell_id = "alive001", code = "y = 2" } }
    -- No bridge attached; _pump will try to chansend and pcall it. Stub
    -- _send so we can observe the pump without a real bridge.
    local sent = {}
    kernel._send = function(self, payload) sent[#sent + 1] = payload; return true end
    kernel:_handle_msg({
      type = "execute_done", cell_id = "ghost001",
      exec_count = 7, ms = 1,
    })
    -- running cleared, queue popped, execute payload sent for alive001.
    assert.is_not_nil(kernel.running)
    assert.equals("alive001", kernel.running.cell_id)
    assert.equals(0, #kernel.queue)
    local saw_execute = false
    for _, p in ipairs(sent) do
      if p.type == "execute" and p.cell_id == "alive001" then
        saw_execute = true; break
      end
    end
    assert.is_true(saw_execute)
    Notebook.detach(buf)
  end)

  it("_emit_line does not propagate a handler error", function()
    -- A malformed iopub frame from a non-standard kernel could trigger a nil
    -- deref inside _handle_msg. Letting that error escape would surface as
    -- a noisy nvim error from on_stdout and (depending on the host's
    -- error-handling) could cause subsequent chunks to be silently dropped.
    -- _emit_line wraps the handler in pcall so the channel keeps pumping.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %% id=alive001", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)
    -- Stub _handle_msg to raise on the next call.
    local stub_called = false
    kernel._handle_msg = function() stub_called = true; error("boom") end
    -- Feed a syntactically-valid JSON message; _emit_line should pcall
    -- _handle_msg and return without raising.
    local ok = pcall(function()
      kernel:_emit_line('{"type":"output","cell_id":"alive001","item":{}}')
    end)
    assert.is_true(ok)
    assert.is_true(stub_called)
    Notebook.detach(buf)
  end)

  it("lists kernels via the bridge", function()
    local tmp = vim.fn.tempname() .. ".py"
    local f = io.open(tmp, "w"); f:write(fake_bridge_script()); f:close()
    Cfg.setup({ bridge_cmd = { "python3", "-u", tmp } })
    local buf = vim.api.nvim_create_buf(false, true)
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    local got
    kernel:list_kernels(function(k) got = k end)
    local deadline = vim.loop.hrtime() + 5e9
    while vim.loop.hrtime() < deadline do
      vim.wait(50, function() return false end)
      if got then break end
    end
    assert.is_table(got)
    assert.equals("python3", got[1].name)
    kernel:stop()
    Notebook.detach(buf)
  end)
end)
