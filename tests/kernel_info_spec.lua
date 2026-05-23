-- Pin two related contracts:
--   (1) Kernel:info() returns a human-readable list of lines describing the
--       currently-bound kernel (selector, mode, bridge state). Powers the
--       new `:NotebookKernelInfo` command.
--   (2) The lualine `kernel` component shortens absolute python paths via
--       `Discover.short_label` so the statusline doesn't get crowded — and
--       leaves registered kernelspec names alone.

local Kernel = require("mercury.kernel")
local Notebook = require("mercury.notebook")

describe("Kernel:info", function()
  local function _make_kernel(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=kinfobuf", "print('x')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb, { kernel = opts })
    nb:set_kernel(k)
    return k, buf
  end

  it("reports the default-fallback when no selector is set", function()
    local k, buf = _make_kernel({ mode = "local" })
    local info = k:info()
    local joined = table.concat(info, "\n")
    assert.matches("mode: local", joined)
    assert.matches("python3 %(default fallback%)", joined)
    assert.matches("bridge: not started", joined)
    Notebook.detach(buf)
  end)

  it("reports the python selector when configured", function()
    local k, buf = _make_kernel({
      mode = "local", python = "/work/proj/.venv/bin/python",
    })
    local info = k:info()
    local joined = table.concat(info, "\n")
    assert.matches("python: /work/proj/.venv/bin/python", joined)
    Notebook.detach(buf)
  end)

  it("reports the spec_path selector when configured", function()
    local k, buf = _make_kernel({
      mode = "local", spec_path = "/opt/kernels/myenv",
    })
    local info = k:info()
    local joined = table.concat(info, "\n")
    assert.matches("spec_path: /opt/kernels/myenv", joined)
    Notebook.detach(buf)
  end)

  it("reports kernelspec name when only name is configured", function()
    local k, buf = _make_kernel({ mode = "local", name = "python3" })
    local info = k:info()
    local joined = table.concat(info, "\n")
    assert.matches("kernelspec: python3", joined)
    -- And it doesn't add the "(default fallback)" suffix when name is set.
    assert.is_nil(joined:match("default fallback"))
    Notebook.detach(buf)
  end)

  it("reports existing-mode connection file", function()
    local k, buf = _make_kernel({
      mode = "existing", connection_file = "/tmp/kernel-xyz.json",
    })
    local info = k:info()
    local joined = table.concat(info, "\n")
    assert.matches("mode: existing", joined)
    assert.matches("connection_file: /tmp/kernel%-xyz.json", joined)
    Notebook.detach(buf)
  end)

  it("includes queue length when cells are queued", function()
    local k, buf = _make_kernel({ mode = "local", name = "python3" })
    k.queue = { { cell_id = "a", code = "" }, { cell_id = "b", code = "" } }
    local info = k:info()
    assert.matches("queue length: 2", table.concat(info, "\n"))
    Notebook.detach(buf)
  end)
end)

describe("lualine.kernel formatting", function()
  it("renders the kernel glyph + name when a notebook is attached", function()
    local Lual = require("mercury.lualine")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=lualkern", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    vim.b[buf].mercury_kernel_name = "python3"
    local s = Lual.kernel()
    assert.matches("python3", s)
    assert.matches("⎈", s)
    Notebook.detach(buf)
  end)

  it("shortens absolute python paths via Discover.short_label", function()
    local Lual = require("mercury.lualine")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=lualpypy", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    vim.b[buf].mercury_kernel_name = "/work/myproj/.venv/bin/python"
    local s = Lual.kernel()
    -- Short label format from Discover.short_label: ".venv (myproj)"
    assert.matches("%.venv", s)
    assert.matches("myproj", s)
    -- And the full path is NOT in the lualine (would crowd the statusline).
    assert.is_nil(s:match("/work/myproj/%.venv/bin/python"))
    Notebook.detach(buf)
  end)

  it("returns empty string for non-mercury buffers", function()
    local Lual = require("mercury.lualine")
    -- Create a plain buffer that's NOT attached to mercury.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    -- Just to be safe, make sure nothing's attached.
    Notebook.detach(buf)
    assert.equals("", Lual.kernel())
  end)
end)
