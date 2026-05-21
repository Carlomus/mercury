-- mercury.markdown.update sets per-cell markdown TS regions on the
-- python parser so prose without `#` prefixes still highlights. The
-- function is called by rescan via pcall, so a regression here would
-- silently fail and ONLY surface as missing markdown highlights —
-- impossible to catch in CI without an explicit test.

local Markdown = require("mercury.markdown")
local Notebook = require("mercury.notebook")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  -- We need a python filetype for the python TS parser to exist.
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".ipynb")
  vim.bo[buf].filetype = "python"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("mercury.markdown.update", function()
  it("does not raise on a buffer with no markdown cells", function()
    local buf = make_buf({
      "# %% id=mdt00001",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    assert.has_no.errors(function() Markdown.update(buf, nb.cells) end)
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not raise on an empty cells list", function()
    local buf = make_buf({ "x" })
    assert.has_no.errors(function() Markdown.update(buf, {}) end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not raise on a markdown-only buffer", function()
    local buf = make_buf({
      "# %% id=mdt00002 [markdown]",
      "# A title",
      "paragraph",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    assert.has_no.errors(function() Markdown.update(buf, nb.cells) end)
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not raise on a mixed buffer (code + markdown)", function()
    local buf = make_buf({
      "# %% id=mix00001",
      "x = 1",
      "# %% id=mix00002 [markdown]",
      "# Section",
      "prose",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    assert.has_no.errors(function() Markdown.update(buf, nb.cells) end)
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not raise when markdown cell has empty body (body_end < body_start)", function()
    -- An empty markdown cell: separator only, no content. Should be
    -- skipped (no region added) but not raise.
    local buf = make_buf({
      "# %% id=mtempty1 [markdown]",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    assert.has_no.errors(function() Markdown.update(buf, nb.cells) end)
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not re-set regions when the cache key matches", function()
    -- A second call with the same cells layout should be a fast no-op
    -- (no parser:set_included_regions call). We can't easily spy on the
    -- internal TS call, but we can verify the cache key path doesn't
    -- raise on repeated invocations.
    local buf = make_buf({
      "# %% id=mt000003 [markdown]",
      "para",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    Markdown.update(buf, nb.cells)
    -- Second call: cache hit.
    assert.has_no.errors(function() Markdown.update(buf, nb.cells) end)
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("mercury.markdown._forget", function()
  it("is idempotent on an unknown buffer", function()
    assert.has_no.errors(function() Markdown._forget(99999) end)
  end)
end)
