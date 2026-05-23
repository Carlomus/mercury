-- Buffer-level UI: cell highlights, separator overlay, output virt_lines.

local Output = require("mercury.output")
local Notebook = require("mercury.notebook")
local Cfg = require("mercury.config")
local Image = require("mercury.image")
local Util = require("mercury.util")

local M = {}

local NS_OUTPUT = "output"
local NS_HL_CODE = "hl_code"
local NS_HL_MD = "hl_md"
local NS_SEP = "separator"

function M.setup_highlights()
  local hl = Cfg.get().highlights
  local function set(name, opts)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    else
      local existing = vim.api.nvim_get_hl(0, { name = name })
      if vim.tbl_isempty(existing) then vim.api.nvim_set_hl(0, name, opts) end
    end
  end
  set("MercuryCodeBlock",     { bg = hl.code_bg, default = true })
  set("MercuryMarkdownBlock", { bg = hl.markdown_bg, default = true })
  set("MercurySeparator",     { fg = hl.separator_fg, italic = true, default = true })
  set("MercuryPillRunning",   { fg = hl.pill_running, bold = true, default = true })
  set("MercuryPillOk",        { fg = hl.pill_ok, default = true })
  set("MercuryPillError",     { fg = hl.pill_error, bold = true, default = true })
  set("MercuryPillQueued",    { fg = hl.pill_queued, default = true })
  set("MercuryPillIdle",      { fg = hl.pill_queued, default = true })
  -- Used by `text/markdown` outputs as the BASE prose color. Inline-emphasis
  -- spans (bold / italic / code) use the standard treesitter markdown
  -- highlight groups (set below).
  set("MercuryMarkdownOut",   { link = "Normal", default = true })
  -- Treesitter @markup.* groups for markdown output styling. With a
  -- modern theme installed (or render-markdown.nvim's defaults loaded),
  -- these typically resolve through the theme's own markdown palette.
  -- We use `default = true` so user/theme definitions ALWAYS win — these
  -- only kick in when the group is otherwise undefined, so on a bare
  -- terminal a `# Heading` doesn't render as un-styled prose.
  set("@markup.heading.1.markdown", { link = "Title",          default = true })
  set("@markup.heading.2.markdown", { link = "Title",          default = true })
  set("@markup.heading.3.markdown", { link = "Title",          default = true })
  set("@markup.heading.4.markdown", { link = "Title",          default = true })
  set("@markup.heading.5.markdown", { link = "Title",          default = true })
  set("@markup.heading.6.markdown", { link = "Title",          default = true })
  set("@markup.strong",             { bold = true,             default = true })
  set("@markup.emphasis",           { italic = true,           default = true })
  set("@markup.raw.markdown_inline",{ link = "Special",        default = true })
  set("@markup.raw.markdown",       { link = "Comment",        default = true })
  set("@markup.list.markdown",      { link = "Statement",      default = true })
  set("@markup.quote.markdown",     { link = "Comment",        default = true })
end

local Renderer = {}
Renderer.__index = Renderer

function M.new(nb)
  return setmetatable({
    nb = nb,
    image = Image.new(nb),
  }, Renderer)
end

function Renderer:_clear_ns(name, line_start, line_end)
  local ns = Notebook.ns(name)
  vim.api.nvim_buf_clear_namespace(self.nb.buf, ns, line_start or 0, line_end or -1)
end

function Renderer:clear_all()
  self:_clear_ns(NS_OUTPUT)
  self:_clear_ns(NS_HL_CODE)
  self:_clear_ns(NS_HL_MD)
  self:_clear_ns(NS_SEP)
  self.image:clear_all()
end

function Renderer:render()
  local nb = self.nb
  local buf = nb.buf
  if not vim.api.nvim_buf_is_loaded(buf) then return end

  -- Highlights and separators.
  self:_clear_ns(NS_HL_CODE)
  self:_clear_ns(NS_HL_MD)
  self:_clear_ns(NS_SEP)

  for _, c in ipairs(nb.cells) do
    if c.header_row >= 0 then
      vim.api.nvim_buf_set_extmark(buf, Notebook.ns(NS_SEP), c.header_row, 0, {
        end_row = c.header_row + 1,
        end_col = 0,
        hl_group = "MercurySeparator",
        hl_eol = true,
        priority = 90,
      })
      local line = vim.api.nvim_buf_get_lines(buf, c.header_row, c.header_row + 1, false)[1] or ""
      -- Match the same id key-class parse_meta uses: [%w_%-%.]. A dotted id
      -- (vendor-prefixed) must conceal the whole token.
      local id_s, id_e = line:find("%s+id=[%w_%-%.]+")
      if id_s then
        vim.api.nvim_buf_set_extmark(buf, Notebook.ns(NS_SEP), c.header_row, id_s - 1, {
          end_col = id_e,
          conceal = "",
          priority = 95,
        })
      end
      if c.kind == "code" and not line:find("%[markdown%]") and not line:find("%[md%]") then
        vim.api.nvim_buf_set_extmark(buf, Notebook.ns(NS_SEP), c.header_row, 0, {
          virt_text = { { " python", "Comment" } },
          virt_text_pos = "eol",
          priority = 95,
        })
      end
    end
    local hl_ns, hl_group
    if c.kind == "markdown" then
      hl_ns, hl_group = Notebook.ns(NS_HL_MD), "MercuryMarkdownBlock"
    else
      hl_ns, hl_group = Notebook.ns(NS_HL_CODE), "MercuryCodeBlock"
    end
    if c.body_end >= c.body_start then
      -- One ranged extmark per cell body (hl_group + hl_eol + end_row) instead
      -- of one per body row. Matches the separator's approach and scales to
      -- large cell bodies without re-emitting N extmarks each render. The
      -- visual swap from line_hl_group is intentional: the gutter no longer
      -- gets tinted, which keeps it consistent with the separator row.
      vim.api.nvim_buf_set_extmark(buf, hl_ns, c.body_start, 0, {
        end_row = c.body_end + 1,
        end_col = 0,
        hl_group = hl_group,
        hl_eol = true,
        priority = 10,
      })
    end
  end

  -- Output virt_lines.
  for _, c in ipairs(nb.cells) do
    self:render_cell_output(c)
  end

  -- GC tracked extmark ids whose cells no longer exist (rename/delete/merge).
  --
  -- IMPORTANT: deleting the cell's separator line does NOT delete its output
  -- extmark from the buffer — the extmark just relocates to whatever row
  -- nvim chose (typically the row that absorbed the deletion). The Lua
  -- lookup table forgetting the id is not enough; we have to explicitly
  -- call `nvim_buf_del_extmark` so the virt_lines stop rendering. Without
  -- this, a user who deletes a cell's `# %%` separator sees the old
  -- cell's output pill and body stuck to the merged cell with no way to
  -- clear it (`:NotebookOutputClear` operates on the cell at cursor,
  -- whose id is the surviving one — the orphan's id is unreachable).
  --
  -- Same logic applies to image.nvim handles, which the plugin holds onto
  -- until we explicitly call `:clear()` — we must drop those too or
  -- deleted cells leak live images that linger in the terminal.
  local present = {}
  for _, c in ipairs(nb.cells) do present[c.id] = true end
  -- `_marks[cell_id]` is a LIST of extmark ids per cell (one per text /
  -- image segment) under the multi-extmark layout. Delete every extmark
  -- attached to a vanished cell so its virt_lines / image placements
  -- can't survive past the cell deletion.
  if self._marks then
    local ns_out = Notebook.ns(NS_OUTPUT)
    for id, mark_list in pairs(self._marks) do
      if not present[id] then
        for _, mark_id in ipairs(mark_list) do
          pcall(vim.api.nvim_buf_del_extmark, buf, ns_out, mark_id)
        end
        self._marks[id] = nil
      end
    end
  end
  if self.image and self.image.gc then self.image:gc(present) end
end

local function _delete_marks(buf, ns_out, mark_list)
  if not mark_list then return end
  for _, mark_id in ipairs(mark_list) do
    pcall(vim.api.nvim_buf_del_extmark, buf, ns_out, mark_id)
  end
end

function Renderer:render_cell_output(cell)
  local nb = self.nb
  local out = nb.outputs[cell.id]
  local buf = nb.buf
  local ns_out = Notebook.ns(NS_OUTPUT)
  local cfg = Cfg.get().output

  self._marks = self._marks or {}
  -- Multi-extmark layout: every render replaces ALL prior extmarks for
  -- this cell because the segment boundaries (and therefore the count
  -- and content of extmarks) may have shifted. Trying to reuse extmark
  -- ids while changing virt_lines would leave stale rows when segments
  -- shrink.
  _delete_marks(buf, ns_out, self._marks[cell.id])
  self._marks[cell.id] = nil

  -- No output? Done — extmarks cleared above; clear any images too.
  if not out or (out.status == "idle" and #(out.items or {}) == 0) then
    self.image:clear_cell(cell)
    return
  end

  local collapsed = (out._collapsed == true)

  -- Extract images so build_virt_segments knows which item produced
  -- which image (by walk order). Mark unavailable items so the segment
  -- builder substitutes a diagnostic line instead of leaving a hole.
  local images
  if not collapsed and Image.available() then
    images = Output.extract_images(out)
    for _, item in ipairs(out.items or {}) do
      if item._mercury_image_unavailable then item._mercury_image_unavailable = nil end
    end
    for _, img in ipairs(images) do
      local data = Util.read_file(img.path)
      if (not data or data == "") and out.items[img.item_index] then
        out.items[img.item_index]._mercury_image_unavailable = true
      end
    end
  end

  -- Queue position for `⏸ queued #N`. Derived per render so an
  -- enqueue/pop elsewhere updates this cell's pill on the next tick.
  local queue_pos
  if out.status == "queued" and nb.kernel and nb.kernel.queue then
    for i, task in ipairs(nb.kernel.queue) do
      if task.cell_id == cell.id then queue_pos = i; break end
    end
  end

  local anchor = nb:cell_anchor_row(cell)
  local mark_list = {}
  self._marks[cell.id] = mark_list

  -- Multi-extmark pipeline. Each text segment gets its own extmark with
  -- a virt_lines list of just that segment's rows. Each image segment
  -- calls render_one, which creates an image.nvim extmark with
  -- with_virtual_padding=true so image.nvim owns the row reservation
  -- for that image. All extmarks anchor at the same row (cell.body_end)
  -- and stack their virt_lines in CREATION ORDER, which gives us
  -- document order — without Mercury having to predict image.nvim's
  -- actual rendered height.
  local segments
  if collapsed then
    -- Collapsed output: one text segment, no images. build_virt_segments
    -- returns the collapsed marker as a single text segment.
    segments = Output.build_virt_segments(out, {
      show_status_pill = cfg.show_status_pill,
      collapsed = true,
      queue_pos = queue_pos,
    })
  else
    segments = Output.build_virt_segments(out, {
      show_status_pill = cfg.show_status_pill,
      queue_pos = queue_pos,
    })
  end

  for _, seg in ipairs(segments) do
    if seg.kind == "text" and seg.lines and #seg.lines > 0 then
      local mark_id = vim.api.nvim_buf_set_extmark(buf, ns_out, anchor, 0, {
        virt_lines = seg.lines,
        virt_lines_above = false,
        hl_mode = "combine",
        right_gravity = false,
      })
      mark_list[#mark_list + 1] = mark_id
    elseif seg.kind == "image" and not collapsed and images then
      local img = images[seg.index]
      if img then
        -- The slot_index keeps each image's extmark column distinct so
        -- two adjacent images don't collide. Use the segment's index in
        -- extract_images order, not the segment list index — that way
        -- the cache key stays stable across re-renders.
        self.image:render_one(cell, anchor, img, seg.index)
      end
    end
  end

  -- Drop image cache entries for hashes no longer in this render. Avoids
  -- ghost placements when a cell re-executes and produces different
  -- images.
  if not collapsed and images then
    local present_hashes = {}
    for _, img in ipairs(images) do present_hashes[img.hash] = true end
    local entry = self.image.cache[cell.id]
    if entry and entry.handles then
      for hash, h in pairs(entry.handles) do
        if not present_hashes[hash] then
          pcall(function() if h.clear then h:clear() end end)
          entry.handles[hash] = nil
          if entry.placements then entry.placements[hash] = nil end
        end
      end
    end
  elseif collapsed or not images then
    self.image:clear_cell(cell)
  end
end

return M
