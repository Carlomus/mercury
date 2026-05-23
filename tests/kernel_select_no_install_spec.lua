-- Pin: :NotebookKernelSelect's underlying `list_kernels` must NOT trigger
-- the deps install prompt — the kernel picker is the user's recovery path
-- when their current python is missing deps, and the picker can populate
-- from discovered pythons + manual entry alone.

local Util = require("mercury.util")
local Cfg = require("mercury.config")
local Kernel = require("mercury.kernel")
local Notebook = require("mercury.notebook")

describe("list_kernels with missing deps", function()
  local notifies
  local orig_notify
  before_each(function()
    notifies = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notifies, msg) end
    Util.invalidate_dep_cache()
  end)
  after_each(function() vim.notify = orig_notify end)

  it("returns empty list without firing install prompt when deps are missing", function()
    -- Stub a "python" that reports both modules missing.
    local stub = vim.fn.tempname() .. ".sh"
    local f = io.open(stub, "w")
    f:write("#!/bin/sh\necho jupyter_client\necho ipykernel\nexit 0\n")
    f:close()
    os.execute("chmod +x " .. stub)

    Cfg.setup({
      python = stub,
      kernel = { auto_install = "ask" },
    })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=kselectx", "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)

    local got
    kernel:list_kernels(function(kernels) got = kernels end)
    vim.wait(200, function() return got ~= nil end)

    assert.is_not_nil(got, "callback must fire")
    assert.equals(0, #got)
    -- No install/prompt notify fired.
    for _, m in ipairs(notifies) do
      assert.is_nil(tostring(m):match("missing python module"),
        "no install error should fire from the picker path")
      assert.is_nil(tostring(m):match("installing"),
        "no install-progress notify should fire from the picker path")
    end
    -- And no bridge subprocess was spawned (the short-circuit happens
    -- before _ensure_started's jobstart).
    assert.is_nil(kernel.job_id)
    -- And install_pending was never set — the picker MUST NOT start a
    -- background install side-effect just by opening.
    assert.is_falsy(kernel._install_pending)

    Notebook.detach(buf)
    os.remove(stub)
  end)
end)
