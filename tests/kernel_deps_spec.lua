-- Mercury must fail fast (with a clear, actionable message) when the bridge's
-- python dependencies are missing, and — controlled by config — optionally
-- prompt to install them. This file pins both contracts.

local Util = require("mercury.util")
local Cfg = require("mercury.config")
local Kernel = require("mercury.kernel")
local Notebook = require("mercury.notebook")

describe("util.check_kernel_deps", function()
  before_each(function() Util.invalidate_dep_cache() end)

  it("returns ok=true when the modules import successfully", function()
    -- Stub a python wrapper that prints NOTHING (no module names → none missing).
    local tmp = vim.fn.tempname() .. ".sh"
    local f = io.open(tmp, "w")
    f:write("#!/bin/sh\nexit 0\n")
    f:close()
    os.execute("chmod +x " .. tmp)
    local res = Util.check_kernel_deps(tmp)
    assert.is_true(res.ok)
    assert.equals(0, #res.missing)
    os.remove(tmp)
  end)

  it("returns missing modules when the python prints their names", function()
    Util.invalidate_dep_cache()
    -- A shell wrapper that emits the two module names on stdout — emulating
    -- what the real probe does when imports fail.
    local tmp = vim.fn.tempname() .. ".sh"
    local f = io.open(tmp, "w")
    f:write("#!/bin/sh\necho jupyter_client\necho ipykernel\nexit 0\n")
    f:close()
    os.execute("chmod +x " .. tmp)
    local res = Util.check_kernel_deps(tmp)
    assert.is_false(res.ok)
    assert.equals(2, #res.missing)
    assert.equals("jupyter_client", res.missing[1])
    assert.equals("ipykernel", res.missing[2])
    os.remove(tmp)
  end)

  it("caches its result per python path until invalidated", function()
    Util.invalidate_dep_cache()
    local tmp = vim.fn.tempname() .. ".sh"
    local count_file = vim.fn.tempname() .. ".count"
    local f = io.open(tmp, "w")
    -- Each invocation appends a tick to a sidecar file; we count those.
    f:write("#!/bin/sh\necho x >> " .. count_file .. "\nexit 0\n")
    f:close()
    os.execute("chmod +x " .. tmp)

    Util.check_kernel_deps(tmp)
    Util.check_kernel_deps(tmp)
    Util.check_kernel_deps(tmp)

    local cf = io.open(count_file, "r")
    local data = cf:read("*a"); cf:close()
    -- Cache hit on calls 2+3 — only one actual subprocess.
    local ticks = 0
    for _ in data:gmatch("x") do ticks = ticks + 1 end
    assert.equals(1, ticks)

    Util.invalidate_dep_cache(tmp)
    Util.check_kernel_deps(tmp)
    local cf2 = io.open(count_file, "r")
    local data2 = cf2:read("*a"); cf2:close()
    local ticks2 = 0
    for _ in data2:gmatch("x") do ticks2 = ticks2 + 1 end
    assert.equals(2, ticks2)
    os.remove(tmp); os.remove(count_file)
  end)

  it("returns ok=false with all modules missing when python is not invokable", function()
    Util.invalidate_dep_cache()
    local res = Util.check_kernel_deps("/no/such/python/binary/exists/here")
    assert.is_false(res.ok)
    assert.is_true(#res.missing >= 2)
  end)

  it("rejects nil/empty python", function()
    assert.is_false(Util.check_kernel_deps(nil).ok)
    assert.is_false(Util.check_kernel_deps("").ok)
  end)
end)

describe("config.kernel.auto_install", function()
  it("defaults to \"ask\"", function()
    Cfg.setup({})
    assert.equals("ask", Cfg.get().kernel.auto_install)
  end)

  it("accepts boolean true/false", function()
    Cfg.setup({ kernel = { auto_install = true } })
    assert.is_true(Cfg.get().kernel.auto_install)
    Cfg.setup({ kernel = { auto_install = false } })
    assert.is_false(Cfg.get().kernel.auto_install)
  end)

  it("accepts the literal \"ask\" string", function()
    Cfg.setup({ kernel = { auto_install = "ask" } })
    assert.equals("ask", Cfg.get().kernel.auto_install)
  end)
end)

describe("kernel pre-launch dep check", function()
  -- Capture vim.notify so we can assert what the user actually sees without
  -- needing a popup queue.
  local notifies
  local orig_notify
  before_each(function()
    notifies = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notifies, msg) end
    Util.invalidate_dep_cache()
  end)
  after_each(function() vim.notify = orig_notify end)

  local function _notif_contains(s)
    for _, m in ipairs(notifies) do
      if tostring(m):find(s, 1, true) then return true end
    end
    return false
  end

  it("with auto_install=false, refuses to launch and notifies the user", function()
    -- Stub a "python" that reports both modules missing.
    local stub = vim.fn.tempname() .. ".sh"
    local f = io.open(stub, "w")
    f:write("#!/bin/sh\necho jupyter_client\necho ipykernel\nexit 0\n")
    f:close()
    os.execute("chmod +x " .. stub)

    Cfg.setup({
      python = stub,
      kernel = { auto_install = false },
    })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=depsfail", "print('x')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)

    local ok = kernel:_ensure_deps_or_offer_install()
    assert.is_false(ok)
    -- Util.notify defers via vim.schedule, so drain pending callbacks before
    -- inspecting `notifies`. A short wait_for is enough — the schedule fires
    -- on the next tick.
    vim.wait(100, function() return #notifies > 0 end)
    assert.is_true(_notif_contains("jupyter_client"))
    assert.is_true(_notif_contains("ipykernel"))
    assert.is_true(_notif_contains("pip install"))

    -- And no bridge job was created.
    assert.is_nil(kernel.job_id)

    Notebook.detach(buf)
    os.remove(stub)
  end)

  it("with auto_install=true, kicks off install and reports it asynchronously", function()
    -- Stub python: first call reports both modules missing (the probe);
    -- subsequent `python -m pip install ...` invocations succeed (exit 0).
    -- We don't actually install anything — we just observe Mercury's flow.
    local stub = vim.fn.tempname() .. ".sh"
    local marker = vim.fn.tempname() .. ".install"
    local f = io.open(stub, "w")
    f:write("#!/bin/sh\n")
    f:write("if [ \"$1\" = \"-m\" ] && [ \"$2\" = \"pip\" ]; then\n")
    f:write("  echo installed > " .. marker .. "\n")
    f:write("  exit 0\n")
    f:write("fi\n")
    f:write("echo jupyter_client\necho ipykernel\nexit 0\n")
    f:close()
    os.execute("chmod +x " .. stub)

    Cfg.setup({
      python = stub,
      kernel = { auto_install = true },
    })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=depsauto", "print('x')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)

    local ok = kernel:_ensure_deps_or_offer_install()
    -- First call must NOT block: it returns false (deps missing, install
    -- started); the user re-triggers execute() after the install completes.
    assert.is_false(ok)
    assert.is_true(kernel._install_pending)
    -- Wait for the install subprocess to finish.
    local deadline = vim.loop.hrtime() + 5e9
    while vim.loop.hrtime() < deadline do
      vim.wait(20, function() return false end)
      if not kernel._install_pending then break end
    end
    assert.is_false(kernel._install_pending,
      "install should complete in well under 5s for our stub")
    -- The pip stub wrote to the marker file.
    assert.is_truthy(vim.loop.fs_stat(marker),
      "install_kernel_deps did not invoke our pip stub")

    Notebook.detach(buf)
    os.remove(stub); os.remove(marker)
  end)
end)
