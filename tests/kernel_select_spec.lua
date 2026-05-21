-- Verifies select_kernel handles all three selector types (name / python /
-- spec_path) and that kernel_opts ends up with exactly the right field set
-- — leaving stale selectors behind would cause the bridge to pick the
-- wrong resolver.

local Kernel = require("mercury.kernel")

local function fake_notebook()
  return { meta = {}, buf = nil }
end

local function fresh_kernel()
  local k = Kernel.new(fake_notebook(),
    { kernel = { mode = "local", name = "python3" } })
  -- Stub out the bridge teardown so select_kernel doesn't try to touch real jobs.
  k.stop = function() end
  return k
end

describe("Kernel:select_kernel", function()
  it("selecting by registered name clears python / spec_path", function()
    local k = fresh_kernel()
    k.kernel_opts.python = "/old/python"   -- stale value to verify it's cleared
    k:select_kernel({ name = "myenv" })
    assert.equals("myenv", k.kernel_opts.name)
    assert.is_nil(k.kernel_opts.python)
    assert.is_nil(k.kernel_opts.spec_path)
    assert.equals("myenv", k.notebook.meta.kernelspec.name)
    -- A spec-name selection should NOT leave a mercury_kernel override
    -- behind — that would shadow the standard kernelspec on next open.
    assert.is_nil(k.notebook.meta.mercury_kernel)
  end)

  it("selecting by python path stores it and clears name", function()
    local k = fresh_kernel()
    k.kernel_opts.name = "leftover"   -- ensure we don't merge — we replace
    k:select_kernel({ python = "/abs/venv/bin/python" })
    assert.equals("/abs/venv/bin/python", k.kernel_opts.python)
    assert.is_nil(k.kernel_opts.name)
    assert.is_nil(k.kernel_opts.spec_path)
    assert.equals("/abs/venv/bin/python",
      k.notebook.meta.mercury_kernel.python)
    -- Standard kernelspec block stays present (other tools read it) with
    -- a sensible fallback name.
    assert.is_not_nil(k.notebook.meta.kernelspec)
    assert.equals("python", k.notebook.meta.kernelspec.language)
  end)

  it("selecting by spec_path stores it and clears name/python", function()
    local k = fresh_kernel()
    k:select_kernel({ spec_path = "/abs/path/to/kernel" })
    assert.equals("/abs/path/to/kernel", k.kernel_opts.spec_path)
    assert.is_nil(k.kernel_opts.name)
    assert.is_nil(k.kernel_opts.python)
    assert.equals("/abs/path/to/kernel",
      k.notebook.meta.mercury_kernel.spec_path)
  end)

  it("ignores selections with neither name nor python nor spec_path", function()
    local k = fresh_kernel()
    local before = vim.deepcopy(k.kernel_opts)
    k:select_kernel({ display_name = "noop" })
    assert.same(before, k.kernel_opts)
  end)

  it("refuses to change selector under mode=existing", function()
    local k = Kernel.new(fake_notebook(),
      { kernel = { mode = "existing", connection_file = "/cf.json" } })
    k.stop = function() end
    k:select_kernel({ python = "/abs/python" })
    assert.equals("existing", k.kernel_opts.mode)
    assert.is_nil(k.kernel_opts.python)
  end)

  it("accepts a bare string (treated as name)", function()
    local k = fresh_kernel()
    k:select_kernel("python3.12")
    assert.equals("python3.12", k.kernel_opts.name)
  end)

  it("is a no-op on nil spec", function()
    local k = fresh_kernel()
    local before = vim.deepcopy(k.kernel_opts)
    k:select_kernel(nil)
    assert.same(before, k.kernel_opts)
  end)

  it("is a no-op on empty table", function()
    local k = fresh_kernel()
    local before = vim.deepcopy(k.kernel_opts)
    k:select_kernel({})
    assert.same(before, k.kernel_opts)
  end)

  it("preserves unknown kernelspec sub-keys across select", function()
    -- Notebooks produced by other tools may stash custom fields under
    -- metadata.kernelspec (e.g., vendor-specific env, interrupt_mode). A
    -- whole-object replace would silently drop them; merge instead.
    local k = fresh_kernel()
    k.notebook.meta.kernelspec = {
      name = "python3",
      display_name = "Python 3",
      language = "python",
      env = { FOO = "bar" },
      interrupt_mode = "message",
    }
    k:select_kernel({ name = "different" })
    assert.equals("different", k.notebook.meta.kernelspec.name)
    assert.same({ FOO = "bar" }, k.notebook.meta.kernelspec.env)
    assert.equals("message", k.notebook.meta.kernelspec.interrupt_mode)
  end)
end)
