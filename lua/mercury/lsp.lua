-- LSP integration. Make markdown cells invisible to any attached LSP by
-- rewriting textDocument/didOpen and textDocument/didChange payloads to a
-- comment-masked view of the buffer. Strategy and rationale: see SPEC.md.

local Notebook = require("mercury.notebook")
local View = require("mercury.lsp_view")

local M = {}

-- Pure: given a notebook and a list of diagnostics, drop any whose range falls
-- inside a markdown cell. Kept as a safety net under the masking layer — if a
-- diagnostic somehow reaches us (e.g., a client that doesn't go through
-- client.notify), this stops it from showing up under prose.
function M.filter_diagnostics(nb, diagnostics)
  if not nb or not nb.cells or #nb.cells == 0 then return diagnostics end
  local function in_markdown(row)
    local cell = nb:cell_at_row(row)
    return cell and cell.kind == "markdown"
  end
  local kept = {}
  for _, d in ipairs(diagnostics or {}) do
    local start_row = (d.range and d.range.start and d.range.start.line) or 0
    local end_row = (d.range and d.range["end"] and d.range["end"].line) or start_row
    -- Drop a diagnostic whose range touches markdown at EITHER end. A
    -- multi-line diagnostic that starts in code and ends inside the
    -- following markdown cell would otherwise survive and render partially
    -- on top of prose. Raw cells are NOT dropped — SPEC documents them as
    -- visible to the LSP (treated as ordinary python text).
    if not (in_markdown(start_row) or in_markdown(end_row)) then
      kept[#kept + 1] = d
    end
  end
  return kept
end

-- ---------- masking helpers ----------

local function uri_to_mercury_buf(uri)
  if not uri or uri == "" then return nil end
  local ok, buf = pcall(vim.uri_to_bufnr, uri)
  if not ok or not buf or buf <= 0 then return nil end
  if not vim.api.nvim_buf_is_valid(buf) then return nil end
  if not Notebook.get(buf) then return nil end
  return buf
end

local function rewrite_did_open(params)
  if not (params and params.textDocument and params.textDocument.uri) then
    return params
  end
  local buf = uri_to_mercury_buf(params.textDocument.uri)
  if not buf then return params end
  params.textDocument.text = View.masked_text(buf)
  return params
end

local function rewrite_did_change(params)
  if not (params and params.textDocument and params.textDocument.uri) then
    return params
  end
  local buf = uri_to_mercury_buf(params.textDocument.uri)
  if not buf then return params end
  -- Replace whatever incremental payload nvim computed with one full-document
  -- entry. We don't try to mask sub-ranges; sending the whole masked document
  -- is always correct, and pyright accepts full sync regardless of advertised
  -- sync kind.
  params.contentChanges = { { text = View.masked_text(buf) } }
  return params
end

-- Exported for testing.
M._rewrite_did_open = rewrite_did_open
M._rewrite_did_change = rewrite_did_change

-- ---------- client patching ----------

-- Idempotent per client. Wraps client.notify so didOpen/didChange for mercury
-- buffers are rewritten before reaching the transport. The config flag is
-- checked at call time, not patch time, so toggling lsp.mask_markdown_cells
-- = false takes effect on the next notify without needing an LSP restart.
function M.patch_client(client)
  if not client or client._mercury_notify_patched then return end
  local orig = client.notify
  client.notify = function(this, method, params)
    local Cfg = require("mercury.config")
    local lsp_cfg = Cfg.get().lsp or {}
    if lsp_cfg.mask_markdown_cells ~= false then
      if method == "textDocument/didOpen" then
        params = rewrite_did_open(params)
      elseif method == "textDocument/didChange" then
        params = rewrite_did_change(params)
      end
    end
    return orig(this, method, params)
  end
  client._mercury_notify_patched = true
end

-- Reset the server's view of this buffer to the masked text. Used on attach,
-- because nvim's auto-attach has already sent didOpen with the raw text by the
-- time LspAttach fires.
function M.reset_server_view(client, buf)
  if not (client and vim.api.nvim_buf_is_valid(buf)) then return end
  local uri = vim.uri_from_bufnr(buf)
  local language_id = vim.bo[buf].filetype or "python"
  -- Bump the version explicitly; some servers ignore didOpen if the version
  -- hasn't advanced past the previous didOpen on the same uri.
  local version = (vim.b[buf].mercury_lsp_version or 0) + 1
  vim.b[buf].mercury_lsp_version = version

  -- Compute the text we want the server to see directly here, rather than
  -- relying on the patched notify to rewrite an empty placeholder. If the
  -- user has `lsp.mask_markdown_cells = false`, the patched notify wouldn't
  -- rewrite — and an empty didOpen would leave the server with a blank
  -- document. Compute it once and pass it in.
  local Cfg = require("mercury.config")
  local mask = (Cfg.get().lsp or {}).mask_markdown_cells ~= false
  local text
  if mask then
    text = View.masked_text(buf)
  else
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  pcall(client.notify, client, "textDocument/didClose", {
    textDocument = { uri = uri },
  })
  pcall(client.notify, client, "textDocument/didOpen", {
    textDocument = {
      uri = uri,
      languageId = language_id,
      version = version,
      text = text,
    },
  })
end

-- ---------- setup ----------

-- Reload-safe: file-locals get reset when the module is re-required (e.g.
-- via :Lazy reload mercury), which without this guard would stack a fresh
-- wrap over the existing one. The marker on vim.g survives module reload,
-- so the wrap happens at most once per nvim session.
local function install_diag_filter()
  if vim.g._mercury_lsp_publish_wrapped then return end
  vim.g._mercury_lsp_publish_wrapped = 1
  local key = "textDocument/publishDiagnostics"
  local prev = vim.lsp.handlers[key]
  vim.lsp.handlers[key] = function(err, result, ctx, config)
    local Cfg = require("mercury.config")
    local lsp_cfg = Cfg.get().lsp or {}
    if lsp_cfg.filter_diagnostics ~= false
        and result and type(result.diagnostics) == "table"
        and #result.diagnostics > 0 then
      local buf = uri_to_mercury_buf(result.uri)
      if buf then
        local nb = Notebook.get(buf)
        result.diagnostics = M.filter_diagnostics(nb, result.diagnostics)
      end
    end
    if prev then return prev(err, result, ctx, config) end
  end
end

-- Called once from mercury.setup(). Installs the diagnostic safety-net filter
-- and the LspAttach autocmd that patches clients and resets their view.
function M.setup()
  install_diag_filter()

  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("MercuryLsp", { clear = true }),
    callback = function(args)
      local buf = args.buf
      if not Notebook.get(buf) then return end
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client then return end
      M.patch_client(client)
      -- Schedule the reset so it lands after nvim finishes the auto-attach
      -- bookkeeping (which would otherwise race with our didClose).
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          M.reset_server_view(client, buf)
        end
      end)
    end,
  })
end

return M
