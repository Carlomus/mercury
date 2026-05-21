-- Verifies that the LSP-facing view comment-masks markdown cells while
-- leaving code-cell lines untouched, and that line counts (the invariant the
-- whole identity-mapping strategy depends on) are preserved.

local View = require("mercury.lsp_view")
local Notebook = require("mercury.notebook")
local Notebook = require("mercury.notebook")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("lsp_view masking", function()
  it("masks markdown-cell body lines with a # prefix, leaves code untouched", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222 [markdown]",
      "some prose",
      "more prose",
      "# %% id=cccc3333",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local masked = View.mask_lines(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false), nb.cells)
    assert.same({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222 [markdown]",
      "# some prose",
      "# more prose",
      "# %% id=cccc3333",
      "y = 2",
    }, masked)
    Notebook.detach(buf)
  end)

  it("preserves line count exactly (identity-position invariant)", function()
    local lines = {
      "# %% id=aaaa1111", "x = 1",
      "# %% id=bbbb2222 [markdown]", "a", "b", "c",
      "# %% id=cccc3333", "y = 2",
    }
    local buf = make_buf(lines)
    local nb = Notebook.attach(buf); nb:rescan()
    local masked = View.mask_lines(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false), nb.cells)
    assert.equals(#lines, #masked)
    Notebook.detach(buf)
  end)

  it("preserves code-cell column positions (identity on those lines)", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "def foo(): return 1",
      "# %% id=bbbb2222 [markdown]",
      "calls foo",
      "# %% id=cccc3333",
      "foo()",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local masked = View.mask_lines(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false), nb.cells)
    -- The "foo" symbol must be at the same column in both views, otherwise
    -- goto-def positions would point at the wrong character.
    assert.equals("def foo(): return 1", masked[2])
    assert.equals("foo()", masked[6])
    Notebook.detach(buf)
  end)

  it("handles a markdown cell at the start of the buffer", function()
    local buf = make_buf({
      "# %% id=aaaa1111 [markdown]",
      "intro line",
      "# %% id=bbbb2222",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local masked = View.mask_lines(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false), nb.cells)
    assert.equals("# intro line", masked[2])
    assert.equals("x = 1", masked[4])
    Notebook.detach(buf)
  end)

  it("leaves raw-cell body lines unmasked (raw is visible to the LSP)", function()
    -- SPEC: raw cells are not masked from the LSP — they appear as ordinary
    -- python text. Together with lsp.filter_diagnostics keeping raw-cell
    -- diagnostics, this is what makes the documented contract hold: a
    -- raw cell of bare prose will get flagged by pyright, and that signal
    -- reaches the user.
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=rawr0001 [raw]",
      "verbatim line 1",
      "verbatim line 2",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local masked = View.mask_lines(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false), nb.cells)
    assert.equals("verbatim line 1", masked[4])
    assert.equals("verbatim line 2", masked[5])
    assert.is_nil(masked[4]:match("^# "))
    Notebook.detach(buf)
  end)

  it("does not double-mask separator lines", function()
    -- The separator of a markdown cell is itself the header_row, not the
    -- body; it must not get an extra "# " prefix prepended.
    local buf = make_buf({
      "# %% id=aaaa1111 [markdown]",
      "prose",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local masked = View.mask_lines(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false), nb.cells)
    assert.equals("# %% id=aaaa1111 [markdown]", masked[1])
    assert.equals("# prose", masked[2])
    Notebook.detach(buf)
  end)

  it("masked_text(buf) returns the joined string", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222 [markdown]",
      "prose",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local s = View.masked_text(buf)
    assert.equals(
      "# %% id=aaaa1111\nx = 1\n# %% id=bbbb2222 [markdown]\n# prose", s)
    Notebook.detach(buf)
  end)

  it("mask_lines is a no-op on nil cells (defensive)", function()
    local out = View.mask_lines({ "a", "b", "c" }, nil)
    assert.same({ "a", "b", "c" }, out)
  end)

  it("mask_lines is a no-op on empty cells list", function()
    local out = View.mask_lines({ "a", "b" }, {})
    assert.same({ "a", "b" }, out)
  end)

  it("mask_lines on a buffer with only markdown cells masks every line", function()
    local buf = make_buf({
      "# %% id=mdonly01 [markdown]",
      "line1",
      "line2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local masked = View.mask_lines(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false), nb.cells)
    -- Separator stays. Body lines get '# ' prefix.
    assert.equals("# %% id=mdonly01 [markdown]", masked[1])
    assert.equals("# line1", masked[2])
    assert.equals("# line2", masked[3])
    Notebook.detach(buf)
  end)

  it("masked_text returns raw join when buffer is not a notebook", function()
    -- Fallback path: no Notebook.get(buf) → joins raw lines.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain", "lines" })
    local s = View.masked_text(buf)
    assert.equals("plain\nlines", s)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
