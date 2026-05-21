-- Verifies the LSP integration: a patched client.notify rewrites didOpen /
-- didChange payloads so the server only ever sees the masked python view of
-- the buffer, and the diagnostic safety-net filter still drops anything that
-- somehow lands on a markdown row.

local Notebook = require("mercury.notebook")
local Lsp = require("mercury.lsp")

local function make_nb()
  -- Same fixture as before so the diag filter cases are unchanged.
  local buf = vim.api.nvim_create_buf(false, true)
  -- Give the buffer a real filename so vim.uri_from_bufnr produces a usable
  -- uri that the patch can resolve back via vim.uri_to_bufnr.
  local name = vim.fn.tempname() .. ".ipynb"
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# %% id=aaaa1111",
    "x = 1",
    "# %% id=bbbb2222 [markdown]",
    "some prose",
    "more prose",
    "# %% id=cccc3333",
    "y = 2",
  })
  local nb = Notebook.attach(buf); nb:rescan()
  return buf, nb
end

local function diag(line, msg)
  return {
    range = { start = { line = line, character = 0 },
              ["end"] = { line = line, character = 1 } },
    message = msg, severity = 1,
  }
end

-- Stand-in for an LSP client. Captures notify() calls so we can assert on
-- what would have hit the wire.
local function fake_client()
  local c = { sent = {} }
  function c.notify(self, method, params)
    table.insert(self.sent, { method = method, params = params })
    return true
  end
  return c
end

describe("lsp diagnostic filter (safety net)", function()
  it("drops diagnostics in markdown cells, keeps code-cell diagnostics", function()
    local buf, nb = make_nb()
    local kept = Lsp.filter_diagnostics(nb, {
      diag(1, "code A: ok"),
      diag(3, "md cell: dropped"),
      diag(4, "md cell: dropped"),
      diag(6, "code C: ok"),
    })
    assert.equals(2, #kept)
    assert.equals("code A: ok", kept[1].message)
    assert.equals("code C: ok", kept[2].message)
    Notebook.detach(buf)
  end)

  it("keeps diagnostics past EOF (no cell match) and on code headers", function()
    local buf, nb = make_nb()
    assert.equals(1, #Lsp.filter_diagnostics(nb, { diag(9999, "past EOF") }))
    assert.equals(1, #Lsp.filter_diagnostics(nb, { diag(0, "on code header") }))
    Notebook.detach(buf)
  end)

  it("drops diagnostics on markdown-cell header rows", function()
    local buf, nb = make_nb()
    assert.equals(0, #Lsp.filter_diagnostics(nb, { diag(2, "on md header") }))
    Notebook.detach(buf)
  end)

  it("drops diagnostics spanning code into markdown (H14)", function()
    -- A multi-line diagnostic whose range starts in a code cell but ends
    -- inside the following markdown cell must be dropped. Pre-fix, the
    -- filter only checked start.line, so the diagnostic survived and
    -- rendered partially on top of prose.
    local buf, nb = make_nb()
    -- Span: starts on the last code line, ends inside the markdown body.
    local span = {
      range = { start = { line = 1, character = 0 },
                ["end"] = { line = 3, character = 0 } },
      message = "spans code->markdown", severity = 1,
    }
    local kept = Lsp.filter_diagnostics(nb, { span })
    assert.equals(0, #kept)
    Notebook.detach(buf)
  end)

  it("keeps diagnostics on raw cells (raw is not masked from the LSP)", function()
    -- SPEC: raw cells are left visible to the LSP as ordinary python text;
    -- the safety-net filter must not drop diagnostics that land inside one.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".ipynb")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=code0001",
      "x = 1",
      "# %% id=rawr0001 [raw]",
      "not python",
      "still not python",
      "# %% id=code0002",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local kept = Lsp.filter_diagnostics(nb, {
      diag(1, "code: keep"),
      diag(3, "raw body: keep"),
      diag(4, "raw body: keep"),
      diag(6, "code: keep"),
    })
    assert.equals(4, #kept)
    Notebook.detach(buf)
  end)
end)

describe("lsp client.notify patching", function()
  before_each(function() require("mercury.config").setup() end)

  it("rewrites didOpen text to the masked view for a mercury buffer", function()
    local buf, nb = make_nb()
    local uri = vim.uri_from_bufnr(buf)
    local params = {
      textDocument = { uri = uri, languageId = "python", version = 1,
                       text = "RAW THAT NVIM AUTO-SENT" },
    }
    Lsp._rewrite_did_open(params)
    -- The masked text must reflect the buffer's masked view, not the raw
    -- payload nvim handed us.
    assert.matches("# some prose", params.textDocument.text)
    assert.matches("# more prose", params.textDocument.text)
    -- Code-cell lines must be unchanged (no extra "# " prefix).
    assert.matches("x = 1", params.textDocument.text)
    assert.is_nil(params.textDocument.text:match("# x = 1"))
    Notebook.detach(buf)
  end)

  it("replaces didChange contentChanges with a single masked full document", function()
    local buf, nb = make_nb()
    local uri = vim.uri_from_bufnr(buf)
    local params = {
      textDocument = { uri = uri, version = 2 },
      contentChanges = {
        -- Pretend nvim computed two incremental ranges; we should overwrite
        -- them with one full-document entry so we never have to mask a range.
        { range = { start = { line = 3, character = 0 },
                    ["end"] = { line = 3, character = 5 } },
          text = "wrong" },
        { range = { start = { line = 4, character = 0 },
                    ["end"] = { line = 4, character = 3 } },
          text = "also wrong" },
      },
    }
    Lsp._rewrite_did_change(params)
    assert.equals(1, #params.contentChanges)
    assert.is_nil(params.contentChanges[1].range)
    assert.matches("# some prose", params.contentChanges[1].text)
    Notebook.detach(buf)
  end)

  it("does NOT rewrite payloads for non-mercury buffers", function()
    local raw_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(raw_buf, vim.fn.tempname() .. ".py")
    vim.api.nvim_buf_set_lines(raw_buf, 0, -1, false, { "print('hi')" })
    local uri = vim.uri_from_bufnr(raw_buf)
    local params = { textDocument = { uri = uri, languageId = "python",
                                      version = 1, text = "print('hi')" } }
    Lsp._rewrite_did_open(params)
    assert.equals("print('hi')", params.textDocument.text)
    vim.api.nvim_buf_delete(raw_buf, { force = true })
  end)

  it("patch_client is idempotent — applying twice does not re-wrap", function()
    local c = fake_client()
    Lsp.patch_client(c)
    local once = c.notify
    Lsp.patch_client(c)
    assert.equals(once, c.notify)
  end)

  it("patched notify forwards non-text-sync methods unchanged", function()
    local c = fake_client()
    Lsp.patch_client(c)
    c:notify("textDocument/hover", { position = { line = 0, character = 0 } })
    assert.equals(1, #c.sent)
    assert.equals("textDocument/hover", c.sent[1].method)
    assert.same({ position = { line = 0, character = 0 } }, c.sent[1].params)
  end)

  it("patched notify rewrites didOpen end-to-end for a mercury buffer", function()
    local buf, nb = make_nb()
    local c = fake_client()
    Lsp.patch_client(c)
    c:notify("textDocument/didOpen", {
      textDocument = { uri = vim.uri_from_bufnr(buf),
                       languageId = "python", version = 1, text = "stale" },
    })
    assert.equals(1, #c.sent)
    local text = c.sent[1].params.textDocument.text
    assert.matches("# some prose", text)
    assert.matches("y = 2", text)
    Notebook.detach(buf)
  end)

  it("mask_markdown_cells toggling takes effect without re-patching", function()
    -- Regression: a previous version checked the flag once at patch time,
    -- which meant flipping it required restarting the LSP server. Now the
    -- wrapper reads config on every notify, so toggling is live.
    local buf, nb = make_nb()
    local c = fake_client()
    Lsp.patch_client(c)
    -- First call with masking on -> text is rewritten.
    c:notify("textDocument/didOpen", {
      textDocument = { uri = vim.uri_from_bufnr(buf),
                       languageId = "python", version = 1, text = "raw" },
    })
    assert.matches("# some prose", c.sent[1].params.textDocument.text)
    -- Flip the flag and call again on the SAME client -> raw passes through.
    require("mercury.config").setup({ lsp = { mask_markdown_cells = false } })
    c:notify("textDocument/didOpen", {
      textDocument = { uri = vim.uri_from_bufnr(buf),
                       languageId = "python", version = 2, text = "raw two" },
    })
    assert.equals("raw two", c.sent[2].params.textDocument.text)
    require("mercury.config").setup()
    Notebook.detach(buf)
  end)

  it("patch_client is a no-op on a nil client", function()
    assert.has_no.errors(function() Lsp.patch_client(nil) end)
  end)

  it("respects mask_markdown_cells = false at call time (no rewrite)", function()
    -- The patch is always installed (so toggling the flag back on doesn't
    -- require an LSP restart), but at call time it forwards the payload
    -- verbatim when masking is disabled.
    local buf, nb = make_nb()
    require("mercury.config").setup({ lsp = { mask_markdown_cells = false } })
    local c = fake_client()
    Lsp.patch_client(c)
    c:notify("textDocument/didOpen", {
      textDocument = { uri = vim.uri_from_bufnr(buf),
                       languageId = "python", version = 1,
                       text = "RAW NOT MASKED" },
    })
    assert.equals("RAW NOT MASKED", c.sent[1].params.textDocument.text)
    require("mercury.config").setup()  -- restore defaults
    Notebook.detach(buf)
  end)
end)

describe("lsp reset_server_view", function()
  before_each(function() require("mercury.config").setup() end)

  it("sends didClose + didOpen with a bumped version", function()
    local buf, nb = make_nb()
    local c = fake_client()
    Lsp.patch_client(c)
    Lsp.reset_server_view(c, buf)
    -- didClose first, then didOpen.
    assert.equals(2, #c.sent)
    assert.equals("textDocument/didClose", c.sent[1].method)
    assert.equals("textDocument/didOpen", c.sent[2].method)
    -- didOpen carries the masked text (via the patched notify).
    assert.matches("# some prose", c.sent[2].params.textDocument.text)
    -- Calling again must bump the version (some servers ignore re-opens at
    -- the same version).
    local v1 = c.sent[2].params.textDocument.version
    Lsp.reset_server_view(c, buf)
    local v2 = c.sent[4].params.textDocument.version
    assert.is_true(v2 > v1)
    Notebook.detach(buf)
  end)

  it("is a no-op on a nil client", function()
    assert.has_no.errors(function() Lsp.reset_server_view(nil, 1) end)
  end)

  it("is a no-op on an invalid buffer", function()
    local c = fake_client()
    assert.has_no.errors(function() Lsp.reset_server_view(c, 99999) end)
    -- No messages sent for an invalid buffer.
    assert.equals(0, #c.sent)
  end)

  it("sends the actual buffer text (not empty) when masking is disabled", function()
    -- Regression: reset_server_view used to pass text="" and rely on the
    -- patched notify to fill it in. With masking disabled the patched notify
    -- forwards the empty string verbatim, leaving the server with a blank
    -- document and all diagnostics broken.
    local buf, nb = make_nb()
    require("mercury.config").setup({ lsp = { mask_markdown_cells = false } })
    local c = fake_client()
    Lsp.patch_client(c)
    Lsp.reset_server_view(c, buf)
    local open = c.sent[2]
    assert.equals("textDocument/didOpen", open.method)
    -- Real lines must be present.
    assert.matches("x = 1", open.params.textDocument.text)
    -- Markdown lines are NOT masked when the flag is off, so prose appears verbatim.
    assert.matches("some prose", open.params.textDocument.text)
    assert.is_nil(open.params.textDocument.text:match("# some prose"))
    require("mercury.config").setup()
    Notebook.detach(buf)
  end)
end)
