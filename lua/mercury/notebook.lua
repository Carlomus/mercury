-- Per-buffer Notebook state. Cells are derived from real buffer text on every
-- change; outputs are kept in a side table keyed by stable cell id.

local Util = require("mercury.util")
local Ipynb = require("mercury.ipynb")

local M = {}
M.instances = {}    -- buf -> Notebook
local NS = {}       -- namespaces, lazily created

local function ns(name)
  if not NS[name] then
    NS[name] = vim.api.nvim_create_namespace("mercury_" .. name)
  end
  return NS[name]
end

M.ns = ns

local Notebook = {}
Notebook.__index = Notebook

function M.attach(buf, opts)
  opts = opts or {}
  if M.instances[buf] then return M.instances[buf] end
  local nb = setmetatable({
    buf = buf,
    cells = {},
    outputs = {},          -- id -> output state
    cell_metadata = {},    -- id -> nbformat cell metadata (preserved across rescans)
    cell_attachments = {}, -- id -> nbformat attachments (markdown cells only)
    meta = opts.meta or vim.empty_dict(),
    nbformat = opts.nbformat or 4,
    nbformat_minor = opts.nbformat_minor or 5,
    kernel = nil,
    _suppress_rescan = false,
    _path = opts.path,
    _renderer = nil,
    _on_change = nil,
  }, Notebook)
  M.instances[buf] = nb
  return nb
end

function M.get(buf) return M.instances[buf] end

-- Defense-in-depth helper used by kernel.lua to drop iopub frames for
-- cells that vanished or were converted to non-code mid-execution. SPEC
-- Invariant 19. Returns true iff `cell_id` corresponds to a cell that
-- (a) still exists in the buffer AND (b) is currently a code cell.
function M._live_code_cell(nb, cell_id)
  if not nb or not cell_id then return false end
  for _, c in ipairs(nb.cells or {}) do
    if c.id == cell_id then return c.kind == "code" end
  end
  return false
end

function M.detach(buf)
  local nb = M.instances[buf]
  if not nb then return end
  if nb._renderer and nb._renderer.clear_all then nb._renderer:clear_all() end
  if nb.kernel and nb.kernel.stop then nb.kernel:stop() end
  -- Forget the markdown injected-regions cache for this buf so a recycled
  -- bufnr can't reuse a stale `_last_key` by coincidence and skip the
  -- set_included_regions call the new buffer actually needed. SPEC H15.
  pcall(function() require("mercury.markdown")._forget(buf) end)
  -- Wipe the per-buffer augroup. Without this, a `:bd` (which fires
  -- BufWipeout → detach but does not destroy the augroup) leaves
  -- TextChanged / BufWinEnter / BufWipeout callbacks closing over a now-
  -- dead Notebook. nvim recycles bufnrs aggressively, so the next file
  -- opened against the same bufnr could inherit those autocmds. The
  -- per-buffer augroup is named `MercuryBuf_<bufnr>` by attach_buffer in
  -- init.lua. SPEC Invariant 30.
  pcall(vim.api.nvim_del_augroup_by_name, "MercuryBuf_" .. buf)
  M.instances[buf] = nil
end

function Notebook:set_renderer(r) self._renderer = r end
function Notebook:set_kernel(k) self.kernel = k end

function Notebook:lines() return vim.api.nvim_buf_get_lines(self.buf, 0, -1, false) end

-- Is this cell currently running or waiting in the kernel queue? Both
-- set_kind (refuse to convert a busy cell) and the UI (status pill rules)
-- depend on this answer. Returns false if no kernel is attached, which
-- matches the spirit of "if there's no kernel, nothing can be busy".
function Notebook:cell_is_busy(id)
  if not self.kernel or not id then return false end
  if self.kernel.running and self.kernel.running.cell_id == id then return true end
  for _, t in ipairs(self.kernel.queue or {}) do
    if t.cell_id == id then return true end
  end
  return false
end

-- Scan the buffer text for cells. Assign ids to any cell missing one. If ids
-- were assigned, the buffer is rewritten in place to make ids persistent.
function Notebook:rescan()
  -- Snapshot the cell list before the scan so we can detect id renames and
  -- migrate side-tables instead of GC'ing them. Without this, a user who edits
  -- `id=abc12345` -> `id=xyz99999` in a separator silently loses that cell's
  -- metadata / outputs / attachments on the next TextChanged.
  local prev_cells = self.cells
  local lines = self:lines()
  local result = Ipynb.scan_lines(lines)

  if result.mutated then
    self._suppress_rescan = true
    local ok, err = pcall(self._apply_id_assignments, self, lines, result.cells)
    self._suppress_rescan = false
    if not ok then error(err) end
    -- Re-derive cells from the freshly written text so rows match.
    lines = self:lines()
    result = Ipynb.scan_lines(lines)
  end

  -- Inject separators for implicit leading cells.
  local need_inject = false
  for _, c in ipairs(result.cells) do
    if c.injected_separator then need_inject = true; break end
  end
  if need_inject then
    self._suppress_rescan = true
    local ok, err = pcall(self._inject_implicit_separators, self, result.cells)
    self._suppress_rescan = false
    if not ok then error(err) end
    lines = self:lines()
    result = Ipynb.scan_lines(lines)
  end

  self.cells = result.cells

  -- Migrate side-tables for renamed ids before GC'ing the old ones.
  --
  -- A "rename" is detected when a previously-known id disappears from the
  -- new cell set entirely AND a position-matched new cell has an id we
  -- didn't see before. Conservative — only fires when the old id has *no*
  -- surviving cell, so a duplicate-paste followed by edit can't
  -- cannibalize the original.
  --
  -- We handle BOTH the equal-length case (the canonical "user retyped an
  -- id-token in a separator") AND the unequal-length case (rename happened
  -- in the same edit batch as an unrelated insert / delete elsewhere in
  -- the buffer). For the unequal case, we look for vanished old ids and,
  -- when exactly one is missing AND exactly one new id is new, treat
  -- that pairing as a rename. Multiple ambiguous vanishings are left to
  -- the GC path — preserving the conservative "if in doubt, don't migrate"
  -- contract that prevents data corruption from heuristic guessing.
  local present = {}
  for _, c in ipairs(self.cells) do present[c.id] = true end
  local function _migrate(old_id, new_id)
    if self.cell_metadata[old_id] ~= nil and self.cell_metadata[new_id] == nil then
      self.cell_metadata[new_id] = self.cell_metadata[old_id]
    end
    if self.outputs[old_id] ~= nil and self.outputs[new_id] == nil then
      self.outputs[new_id] = self.outputs[old_id]
    end
    if self.cell_attachments[old_id] ~= nil and self.cell_attachments[new_id] == nil then
      self.cell_attachments[new_id] = self.cell_attachments[old_id]
    end
    -- Migrate kernel-side pointers. Without this, a manual id rename on a
    -- running cell leaves self.kernel.running.cell_id pointing at the
    -- now-vanished old id — `_live_code_cell` then drops every iopub
    -- frame the kernel keeps emitting (silent output loss) and the
    -- running pill never clears. SPEC Invariant 4 + Invariant 47.
    if self.kernel then
      if self.kernel.running and self.kernel.running.cell_id == old_id then
        self.kernel.running.cell_id = new_id
      end
      for _, task in ipairs(self.kernel.queue or {}) do
        if task.cell_id == old_id then task.cell_id = new_id end
      end
      if self._skipped_at_save and self._skipped_at_save[old_id] then
        self._skipped_at_save[new_id] = true
        self._skipped_at_save[old_id] = nil
      end
    end
    present[new_id] = true
  end
  if prev_cells and #prev_cells == #self.cells then
    -- Position-aligned walk: same length → same positions.
    for i, new_c in ipairs(self.cells) do
      local old_c = prev_cells[i]
      if old_c and old_c.id ~= new_c.id and not present[old_c.id] then
        _migrate(old_c.id, new_c.id)
      end
    end
  elseif prev_cells then
    -- Unequal-length case: a rename happened alongside an insert/delete.
    -- Find vanished old ids (had side-table entries, not in new set) and
    -- new ids (in new set, no side-table entries). If exactly one of each,
    -- the pairing is unambiguous — migrate. Otherwise leave to GC.
    local prev_ids = {}
    for _, c in ipairs(prev_cells) do prev_ids[c.id] = true end
    local vanished = {}
    for id in pairs(prev_ids) do
      if not present[id]
          and (self.cell_metadata[id] or self.outputs[id]
               or self.cell_attachments[id]) then
        vanished[#vanished + 1] = id
      end
    end
    local newids = {}
    for id in pairs(present) do
      if not prev_ids[id]
          and self.cell_metadata[id] == nil
          and self.outputs[id] == nil
          and self.cell_attachments[id] == nil then
        newids[#newids + 1] = id
      end
    end
    if #vanished == 1 and #newids == 1 then
      _migrate(vanished[1], newids[1])
    end
  end

  -- Garbage collect side tables for cells that are truly gone.
  for id, _ in pairs(self.outputs) do
    if not present[id] then self.outputs[id] = nil end
  end
  for id, _ in pairs(self.cell_metadata) do
    if not present[id] then self.cell_metadata[id] = nil end
  end
  for id, _ in pairs(self.cell_attachments) do
    if not present[id] then self.cell_attachments[id] = nil end
  end

  -- Drop side-table entries that don't match the surviving cell's kind:
  --   - outputs for cells that are no longer code (nbformat: markdown / raw
  --     cells don't carry outputs)
  --   - attachments for cells that are no longer markdown
  -- Catches the direct-text-edit conversion path that bypasses set_kind.
  -- SPEC Invariant 20.
  local kinds = {}
  for _, c in ipairs(self.cells) do kinds[c.id] = c.kind end
  -- If the user manually edited the separator of a CURRENTLY RUNNING code
  -- cell to flip its kind (e.g., added `[markdown]`), set_kind's busy-cell
  -- refusal (SPEC Invariant 18) is bypassed — the conversion lands via
  -- the rescan path. Without an interrupt here, the kernel keeps executing
  -- the code (side effects continue) while iopub frames are silently
  -- dropped by `_live_code_cell` (Invariant 19). Send SIGINT so the kernel
  -- work stops in a user-observable way. Symmetric with delete_cell.
  if self.kernel and self.kernel.running then
    local running_id = self.kernel.running.cell_id
    if running_id and kinds[running_id] and kinds[running_id] ~= "code"
        and type(self.kernel.interrupt) == "function" then
      pcall(self.kernel.interrupt, self.kernel)
    end
  end
  for id, _ in pairs(self.outputs) do
    if kinds[id] and kinds[id] ~= "code" then self.outputs[id] = nil end
  end
  for id, _ in pairs(self.cell_attachments) do
    if kinds[id] and kinds[id] ~= "markdown" then self.cell_attachments[id] = nil end
  end
  -- Drop queued kernel tasks for cells that are gone OR no longer code. The
  -- `kinds[id] == nil` case covers full deletion (visual-select + d across
  -- a separator), which was previously short-circuited by the kind check.
  if self.kernel and self.kernel.queue then
    for i = #self.kernel.queue, 1, -1 do
      local task = self.kernel.queue[i]
      if kinds[task.cell_id] ~= "code" then
        table.remove(self.kernel.queue, i)
      end
    end
  end

  pcall(function() require("mercury.markdown").update(self.buf, self.cells) end)

  if self._on_change then self._on_change() end
end

function Notebook:_apply_id_assignments(orig_lines, cells)
  -- Rewrite header lines for two cases:
  --   (a) the separator has no id at all — splice `id=<new>` into the
  --       existing header line. Any unrecognized trailing text the user
  --       had on the line (a comment, a non-token annotation) is preserved
  --       as-is. This honors the SPEC contract that id assignment is a
  --       *splice* over the existing line, not a rebuild from tokens.
  --   (b) scan_lines flagged the cell as `dup_rewrite` because its id
  --       collided with an earlier cell (yank-and-paste of a separator).
  --       The line already has an id token but it's pointing at the wrong
  --       cell; rewrite just the id= token in place, leaving everything
  --       else around it untouched.
  --
  -- Either path preserves any text the user typed beyond the recognized
  -- token grammar. format_separator's full rebuild is reserved for paths
  -- where the entire separator is freshly generated (e.g. NewCellBelow);
  -- here we treat the buffer line as authoritative for everything except
  -- the id token.
  local new_lines = {}
  for i, ln in ipairs(orig_lines) do new_lines[i] = ln end
  for _, c in ipairs(cells) do
    if c.header_row >= 0 then
      local row = c.header_row + 1
      local cur = new_lines[row] or ""
      if c.dup_rewrite then
        -- Replace the existing id= token with the new id, leaving the
        -- rest of the header line text alone.
        local replaced, n = cur:gsub("id=[%w_%-]+", "id=" .. c.id, 1)
        if n == 0 then
          -- Defensive: dup_rewrite without an id token shouldn't be
          -- possible (scan_lines only sets it when parse_meta saw an id),
          -- but if it ever happens, fall through to the splice path below.
          replaced = cur:gsub("^(#%s*%%%%)", "%1 id=" .. c.id, 1)
        end
        new_lines[row] = replaced
      elseif not cur:match("id=[%w_%-]+") then
        -- Splice `id=<new>` immediately after the `# %%` marker, preserving
        -- everything that follows. If the line is bare `# %%`, the result
        -- is `# %% id=<new>`; if it's `# %% Cell title`, the result is
        -- `# %% id=<new> Cell title`.
        new_lines[row] = cur:gsub("^(#%s*%%%%)", "%1 id=" .. c.id, 1)
      end
    end
  end
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, new_lines)
end

function Notebook:_inject_implicit_separators(cells)
  -- The scan said "no separator at top"; insert one at line 0.
  local first = cells[1]
  if first and first.injected_separator then
    local sep = Ipynb.format_separator({ id = first.id, kind = first.kind })
    vim.api.nvim_buf_set_lines(self.buf, 0, 0, false, { sep })
  end
end

-- Cell at the given 0-indexed row, or under the cursor if row is nil.
--
-- Note: this uses a wider range than `cell_body_lines`. cell_at_row counts
-- the blank visual gap between cells as part of the *previous* cell so that
-- cursor placement works naturally; cell_body_lines strips that trailing
-- blank line so the executed code matches what the user sees in the cell.
-- The asymmetry is deliberate.
function Notebook:cell_at_row(row)
  if row == nil then row = vim.api.nvim_win_get_cursor(0)[1] - 1 end
  for i, c in ipairs(self.cells) do
    -- Cell occupies rows [header_row, next_header_row - 1] inclusive.
    local last = (self.cells[i + 1] and (self.cells[i + 1].header_row - 1)) or
      (vim.api.nvim_buf_line_count(self.buf) - 1)
    if row >= c.header_row and row <= last then return c, i end
  end
  return nil, nil
end

function Notebook:cell_index(id)
  for i, c in ipairs(self.cells) do
    if c.id == id then return i end
  end
  return nil
end

function Notebook:cell_body_lines(cell)
  if cell.body_end < cell.body_start then return {} end
  return vim.api.nvim_buf_get_lines(self.buf, cell.body_start, cell.body_end + 1, false)
end

-- Body row range (0-indexed, end inclusive). The last "real" line of a cell is
-- the row that anchors output decorations.
function Notebook:cell_anchor_row(cell)
  if cell.body_end < cell.body_start then
    return cell.header_row >= 0 and cell.header_row or 0
  end
  return cell.body_end
end

-- ---------- mutations ----------

function Notebook:_with_mutation(fn)
  -- pcall ensures we never leave _suppress_rescan stuck true on a Lua error.
  -- Without this guard, an exception inside `fn()` (e.g., nvim_buf_set_lines
  -- against an invalidated buffer mid-teardown) would silently disable all
  -- future TextChanged-driven rescans for this buffer.
  self._suppress_rescan = true
  local ok, err = pcall(fn)
  self._suppress_rescan = false
  if not ok then
    -- Still try to rescan: the buffer may be in a partially-mutated state and
    -- we want our cell list to reflect whatever did make it in. The rescan
    -- itself is pcall'd so a *second* failure (e.g., rescan inspecting a now-
    -- invalid buffer) can't mask the original `err` — propagating that error
    -- is the more useful signal for the caller. SPEC H — _with_mutation
    -- recovery must not lose the original exception.
    pcall(function() self:rescan() end)
    error(err)
  end
  self:rescan()
end

function Notebook:new_cell_below(cell)
  cell = cell or self:cell_at_row()
  if not cell then return end
  local idx = self:cell_index(cell.id)
  local insert_at = (self.cells[idx + 1] and self.cells[idx + 1].header_row) or
    vim.api.nvim_buf_line_count(self.buf)
  local id = Util.short_id()
  local sep = Ipynb.format_separator({ id = id, kind = "code" })
  self:_with_mutation(function()
    vim.api.nvim_buf_set_lines(self.buf, insert_at, insert_at, false, { "", sep, "" })
  end)
  -- Move cursor to body of new cell.
  local newc = self.cells[idx + 1]
  if newc then
    vim.api.nvim_win_set_cursor(0, { newc.body_start + 1, 0 })
  end
  return newc
end

function Notebook:new_cell_above(cell)
  cell = cell or self:cell_at_row()
  if not cell then return end
  local insert_at = math.max(cell.header_row, 0)
  local id = Util.short_id()
  local sep = Ipynb.format_separator({ id = id, kind = "code" })
  self:_with_mutation(function()
    vim.api.nvim_buf_set_lines(self.buf, insert_at, insert_at, false, { sep, "", "" })
  end)
  local newc = self:cell_at_row(insert_at)
  if newc then vim.api.nvim_win_set_cursor(0, { newc.body_start + 1, 0 }) end
  return newc
end

function Notebook:delete_cell(cell)
  cell = cell or self:cell_at_row()
  if not cell then return end
  -- If the cell is currently RUNNING, interrupt the kernel so its work
  -- actually stops instead of continuing invisibly. Jupyter SIGINT semantics:
  -- the running cell raises KeyboardInterrupt; queued cells continue. We
  -- intentionally don't try to "rewind" side effects the cell has already
  -- produced — the user accepted that by choosing delete. If the cell is
  -- merely QUEUED, the subsequent rescan drops it from kernel.queue (no
  -- kernel signal needed). Both outputs and the in-memory state are then
  -- discarded as the cell vanishes. SPEC Invariant 18 covers the
  -- conversion case; this is its delete counterpart.
  if self.kernel and self.kernel.running
      and self.kernel.running.cell_id == cell.id
      and type(self.kernel.interrupt) == "function" then
    pcall(self.kernel.interrupt, self.kernel)
  end
  local idx = self:cell_index(cell.id)
  local start_row = math.max(cell.header_row, 0)
  local end_row = (self.cells[idx + 1] and self.cells[idx + 1].header_row) or
    vim.api.nvim_buf_line_count(self.buf)
  self:_with_mutation(function()
    vim.api.nvim_buf_set_lines(self.buf, start_row, end_row, false, {})
    self.outputs[cell.id] = nil
    self.cell_attachments[cell.id] = nil
    -- cell_metadata is GC'd by rescan automatically once the id is gone, but
    -- being explicit makes the intent obvious.
    self.cell_metadata[cell.id] = nil
  end)
  if #self.cells == 0 then
    -- Always keep at least one cell.
    local id = Util.short_id()
    self:_with_mutation(function()
      vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {
        Ipynb.format_separator({ id = id, kind = "code" }), "",
      })
    end)
  end
end

function Notebook:merge_below(cell)
  cell = cell or self:cell_at_row()
  if not cell then return end
  local idx = self:cell_index(cell.id)
  local nextc = self.cells[idx + 1]
  if not nextc then return end
  -- Refuse if either cell is busy. Symmetric with set_kind (SPEC Invariant
  -- 18) and delete_cell's interrupt path: merging away a running cell
  -- would silently lose iopub frames (`_live_code_cell` drops them once
  -- the id is gone) while the kernel keeps executing the code with side
  -- effects the user can no longer observe. The conservative choice is
  -- to refuse so the user can interrupt explicitly first.
  if self:cell_is_busy(cell.id) or self:cell_is_busy(nextc.id) then
    Util.notify("cell is running/queued; cannot merge",
      vim.log.levels.INFO)
    return
  end
  -- Delete the next cell's separator line.
  local sep_row = nextc.header_row
  self:_with_mutation(function()
    vim.api.nvim_buf_set_lines(self.buf, sep_row, sep_row + 1, false, {})
    -- Output of nextc is dropped (semantics: merging code drops the cached output).
    self.outputs[nextc.id] = nil
  end)
end

function Notebook:_swap_cells(i, j)
  local a = self.cells[i]
  local b = self.cells[j]
  if not (a and b) or i + 1 ~= j then return end
  local a_lines = vim.api.nvim_buf_get_lines(self.buf, a.header_row, b.header_row, false)
  local last_row = (self.cells[j + 1] and self.cells[j + 1].header_row) or
    vim.api.nvim_buf_line_count(self.buf)
  local b_lines = vim.api.nvim_buf_get_lines(self.buf, b.header_row, last_row, false)
  self:_with_mutation(function()
    vim.api.nvim_buf_set_lines(self.buf, a.header_row, last_row, false,
      vim.list_extend(vim.list_extend({}, b_lines), a_lines))
  end)
end

function Notebook:move_up(cell)
  cell = cell or self:cell_at_row()
  if not cell then return end
  local idx = self:cell_index(cell.id)
  if idx and idx > 1 then self:_swap_cells(idx - 1, idx) end
end

function Notebook:move_down(cell)
  cell = cell or self:cell_at_row()
  if not cell then return end
  local idx = self:cell_index(cell.id)
  if idx and idx < #self.cells then self:_swap_cells(idx, idx + 1) end
end

-- code ↔ markdown ↔ raw conversion. Implements SPEC Invariant 23: a single
-- structural mutation that obeys five rules so the side-tables stay
-- coherent regardless of which kind is being entered or left.
--
--   (a) Refuse on a busy cell (Invariant 18). Converting a running cell
--       leaves stale output state and means the kernel's eventual frames
--       get silently dropped by the iopub guard while side effects (file
--       writes, mutations) already landed.
--   (b) Drop outputs[id] when leaving `code` (Invariant 20 menu-driven
--       path). nbformat: only code cells carry outputs; rendering a
--       stale `▶ Out[7]` pill below prose is incoherent.
--   (c) Drop cell_attachments[id] when leaving `markdown`. nbformat: only
--       markdown cells carry attachments; passing them through on a
--       code/raw cell would either be re-emitted by the encoder (which
--       gates emission to markdown — silent loss) or, if the encoder
--       didn't gate, would produce invalid nbformat.
--   (d) Preserve all non-tags cell_metadata fields. The separator owns
--       `tags`; everything else (`scrolled`, `collapsed`, vendor extras
--       like `vscode`, etc.) must survive the deepcopy.
--   (e) Pass `extras` through to format_separator so mercury_extras
--       (`foo=bar` tokens on the separator) round-trip across the
--       conversion. Without this, toggling code↔markdown silently drops
--       any non-tag/non-id token on the separator.
function Notebook:set_kind(cell, kind)
  cell = cell or self:cell_at_row()
  if not cell then return end
  if cell.header_row < 0 then return end
  -- (a) Refuse if the cell is busy. Matches Jupyter Lab's disabled
  -- cell-type menu while a cell is running. SPEC Invariant 18.
  if self:cell_is_busy(cell.id) then
    Util.notify("cell is running/queued; cannot change kind",
      vim.log.levels.INFO)
    return
  end
  local prev_kind = cell.kind
  -- (d) Deepcopy all existing metadata so unknown vendor fields survive.
  local md = vim.deepcopy(self.cell_metadata[cell.id] or {})
  -- (e) The separator's extras table is the source of truth for
  -- mercury_extras + tags after conversion. ALWAYS derive md.tags from
  -- extras — not only when extras.tags is present. Without the else-branch
  -- nullify, a user who removed `tags=foo,bar` from the separator and then
  -- invoked :NotebookCellToMarkdown would see the deepcopied stale tags
  -- persist in cell_metadata until the next save (to_ipynb_struct corrects
  -- them at save time, but observers between set_kind and save would read
  -- inconsistent state). Symmetric with the to_ipynb_struct contract.
  local extras = cell.meta and cell.meta.extras
  if extras and extras.tags then
    md.tags = vim.split(extras.tags, ",", { plain = true, trimempty = true })
  else
    md.tags = nil
  end
  local sep = Ipynb.format_separator({
    id = cell.id, kind = kind, metadata = md, extras = extras,
  })
  self:_with_mutation(function()
    vim.api.nvim_buf_set_lines(self.buf, cell.header_row, cell.header_row + 1, false, { sep })
    -- (b) Leaving code → outputs are invalid for the new kind.
    if prev_kind == "code" and kind ~= "code" then
      self.outputs[cell.id] = nil
    end
    -- (c) Leaving markdown → attachments are invalid for the new kind.
    if prev_kind == "markdown" and kind ~= "markdown" then
      self.cell_attachments[cell.id] = nil
    end
    -- Persist the just-merged metadata (deepcopy avoids the rescan path
    -- mutating the cached table by reference on a later set_kind).
    self.cell_metadata[cell.id] = vim.deepcopy(md)
  end)
end

-- Jump cursor to the body of the next cell after the current row. No-op at
-- the last cell.
function Notebook:goto_next_cell()
  local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, c in ipairs(self.cells) do
    if c.header_row > cur then
      local row = math.max(c.body_start, 0)
      vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
      return
    end
  end
end

-- Two-step previous: first hop to the current cell's body_start; from there,
-- hop to the previous cell's body_start. Matches markdown heading-nav muscle
-- memory and keeps a single key working at both intra- and inter-cell scope.
function Notebook:goto_prev_cell()
  local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell, idx = self:cell_at_row(cur)
  if not cell then return end
  if cur > math.max(cell.body_start, 0) then
    vim.api.nvim_win_set_cursor(0, { math.max(cell.body_start, 0) + 1, 0 })
    return
  end
  if idx and idx > 1 then
    local prev = self.cells[idx - 1]
    vim.api.nvim_win_set_cursor(0, { math.max(prev.body_start, 0) + 1, 0 })
  end
end

function Notebook:select_cell(cell)
  cell = cell or self:cell_at_row()
  if not cell then return end
  -- Empty body (header_row >= 0 but body_end < body_start): nothing to
  -- select meaningfully. A zero-width visual block confuses both the user
  -- and downstream operators (e.g. `d` would delete the separator below
  -- the empty cell). Park the cursor on the separator and bail.
  if cell.body_end < cell.body_start then
    if cell.header_row >= 0 then
      vim.api.nvim_win_set_cursor(0, { cell.header_row + 1, 0 })
    end
    return
  end
  local s = math.max(cell.body_start, 0)
  local e = math.max(s, cell.body_end)
  vim.api.nvim_win_set_cursor(0, { s + 1, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { e + 1, 0 })
end

-- ---------- cell clipboard ----------
-- Module-level clipboard so cells can be moved across buffers.
M._clipboard = nil

function Notebook:copy_cell(cell)
  cell = cell or self:cell_at_row()
  if not cell then return end
  local body = self:cell_body_lines(cell)
  while #body > 0 and body[#body] == "" do table.remove(body, #body) end
  M._clipboard = {
    kind = cell.kind,
    source = body,
    metadata = vim.deepcopy(self.cell_metadata[cell.id] or {}),
  }
end

function Notebook:paste_cell(cell)
  if not M._clipboard then return end
  cell = cell or self:cell_at_row()
  local clip = M._clipboard
  local id = Util.short_id()
  local sep = Ipynb.format_separator({
    id = id, kind = clip.kind, metadata = clip.metadata,
  })
  local lines = { "", sep }
  for _, ln in ipairs(clip.source) do lines[#lines + 1] = ln end
  lines[#lines + 1] = ""

  local insert_at
  if cell then
    local idx = self:cell_index(cell.id)
    insert_at = (self.cells[idx + 1] and self.cells[idx + 1].header_row) or
      vim.api.nvim_buf_line_count(self.buf)
  else
    insert_at = vim.api.nvim_buf_line_count(self.buf)
  end

  self:_with_mutation(function()
    vim.api.nvim_buf_set_lines(self.buf, insert_at, insert_at, false, lines)
    self.cell_metadata[id] = vim.deepcopy(clip.metadata)
  end)
end

function Notebook:duplicate_cell(cell)
  cell = cell or self:cell_at_row()
  if not cell then return end
  self:copy_cell(cell)
  self:paste_cell(cell)
end

-- ---------- output state ----------

function Notebook:ensure_output(id)
  if not self.outputs[id] then
    self.outputs[id] = { items = {}, status = "idle", exec_count = nil, ms = 0 }
  end
  return self.outputs[id]
end

function Notebook:clear_output(id)
  self.outputs[id] = nil
end

function Notebook:clear_all_outputs()
  self.outputs = {}
end

-- ---------- (de)serialization to/from ipynb structure ----------

function Notebook:to_ipynb_struct()
  -- Identify cells whose execution is in flight (running or queued). Save
  -- writes these as "not yet executed" — empty outputs, null exec_count —
  -- so we never block waiting for the kernel to finish before :w returns.
  -- The in-memory state is untouched: the user can save again once the cell
  -- completes to flush its output to disk. SPEC: "Non-blocking save".
  local in_flight = {}
  if self.kernel then
    if self.kernel.running then
      in_flight[self.kernel.running.cell_id] = true
    end
    for _, task in ipairs(self.kernel.queue or {}) do
      in_flight[task.cell_id] = true
    end
  end
  -- Record every in-flight cell in self._skipped_at_save so the kernel's
  -- execute_done branch knows to mark the buffer modified when the cell
  -- finally finishes. Without this, the cell's eventual output stays in
  -- memory but the next :w is a no-op (vim only tracks `modified` on text
  -- changes), and the user thinks the save "worked." SPEC Invariant 14.
  if next(in_flight) ~= nil then
    self._skipped_at_save = self._skipped_at_save or {}
    for id in pairs(in_flight) do
      self._skipped_at_save[id] = true
    end
  end

  local cells = {}
  local last_idx = #self.cells
  for i, c in ipairs(self.cells) do
    local body = self:cell_body_lines(c)
    -- Trim a single trailing empty line — but ONLY for non-last cells.
    -- For non-last cells the trailing "" is the visual gap to_buffer_lines
    -- inserts between cells; for the last cell there's no such gap, so a
    -- trailing "" is real user content and must survive.
    if i < last_idx and #body > 0 and body[#body] == "" then
      table.remove(body, #body)
    end
    local out = self.outputs[c.id]
    -- For an in-flight cell, treat as if it had no output state at all. We
    -- could emit partial items, but a half-streamed tqdm bar or a missing
    -- exec_count makes the file look inconsistent on next reload.
    if in_flight[c.id] then out = nil end
    -- Preserve metadata from the original JSON; let separator-encoded tags
    -- override, and stash unknown separator tokens under mercury_extras so
    -- they survive the JSON round-trip (the buffer is the source of truth
    -- for everything visible in the separator line — see SPEC.md "Separator
    -- extras round-trip").
    local md = vim.deepcopy(self.cell_metadata[c.id] or {})
    local extras = c.meta and c.meta.extras
    -- The separator is authoritative for tags AND for mercury_extras.
    -- Removing `tags=foo,bar` from the buffer must drop the tags from the
    -- saved JSON; symmetric with mercury_extras below. Without this, a user
    -- editing the separator to delete tags would see them silently come back
    -- on next reload (we deepcopied them from cell_metadata above).
    if extras and extras.tags then
      md.tags = vim.split(extras.tags, ",", { plain = true, trimempty = true })
    else
      md.tags = nil
    end
    local stash, has_any = {}, false
    if extras then
      for k, v in pairs(extras) do
        if k ~= "tags" then stash[k] = v; has_any = true end
      end
    end
    md.mercury_extras = has_any and stash or nil
    -- Persist the collapsed state under JupyterLab's canonical metadata
    -- location so reopening the notebook in any tool (or in Mercury after
    -- a session restart) shows the same outputs hidden / shown state.
    -- We write BOTH the classic `metadata.collapsed` (classic Notebook,
    -- still tolerated by Lab) AND `metadata.jupyter.outputs_hidden` (the
    -- modern Lab/VS Code canonical key) so the file round-trips through
    -- every tool consistently.
    if out and out._collapsed then
      md.collapsed = true
      local j = md.jupyter
      if type(j) ~= "table" then j = {} end
      j.outputs_hidden = true
      md.jupyter = j
    else
      -- Don't leave a stale `collapsed=true` lingering on a cell whose
      -- output is now expanded; that would silently re-collapse on reload.
      if md.collapsed ~= nil then md.collapsed = nil end
      if type(md.jupyter) == "table" then
        md.jupyter.outputs_hidden = nil
        if next(md.jupyter) == nil then md.jupyter = nil end
      end
    end
    cells[#cells + 1] = {
      id = c.id,
      kind = c.kind,
      source = body,
      outputs = out and out.items or {},
      exec_count = out and out.exec_count or nil,
      metadata = md,
      -- attachments only meaningful for markdown cells per nbformat; we still
      -- pass through whatever was loaded so non-markdown cells round-trip
      -- losslessly if some other tool put attachments there. encode() gates
      -- emission to markdown only.
      attachments = self.cell_attachments[c.id],
    }
  end
  return {
    meta = self.meta or {},
    nbformat = self.nbformat or 4,
    nbformat_minor = self.nbformat_minor or 5,
    cells = cells,
  }
end

return M
