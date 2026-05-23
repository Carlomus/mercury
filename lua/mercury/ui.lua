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
  -- One extmark per cell (SPEC I8). Delete the extmark for any cell
  -- whose id is gone from nb.cells; otherwise the orphan extmark stays
  -- attached to whatever row neighbours absorbed the deletion, leaving
  -- the dead cell's pill + body stuck to a live cell.
  if self._marks then
    local ns_out = Notebook.ns(NS_OUTPUT)
    for id, mark_id in pairs(self._marks) do
      if not present[id] then
        pcall(vim.api.nvim_buf_del_extmark, buf, ns_out, mark_id)
        self._marks[id] = nil
      end
    end
  end
  if self.image and self.image.gc then self.image:gc(present) end
end

function Renderer:render_cell_output(cell)
  local nb = self.nb
  local out = nb.outputs[cell.id]
  local buf = nb.buf
  local ns_out = Notebook.ns(NS_OUTPUT)
  local cfg = Cfg.get().output

  -- One extmark per cell (SPEC Invariant I8). The extmark carries pill +
  -- text + image-blank reservations in document order; image placements
  -- are managed in parallel by image.lua's cache.
  if not out or (out.status == "idle" and #(out.items or {}) == 0) then
    if self["_marks"] and self._marks[cell.id] then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns_out, self._marks[cell.id])
      self._marks[cell.id] = nil
    end
    self.image:clear_cell(cell)
    return
  end

  local collapsed = (out._collapsed == true)

  -- Extract images BEFORE build_virt_lines so we can mark output items
  -- whose cached bytes vanished (eviction race). build_virt_lines reads
  -- `item._mercury_image_unavailable` to surface a diagnostic line in
  -- place of the image. compute_dimensions then gives us the row count
  -- to reserve per image in the virt_lines stack.
  local images
  local image_heights
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
    if self.image and self.image.compute_dimensions and #images > 0 then
      _, image_heights = self.image:compute_dimensions(images)
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

  local virt, image_offsets = Output.build_virt_lines(out, {
    show_status_pill = cfg.show_status_pill,
    max_preview_lines = collapsed and 0 or (cfg.max_preview_lines or 9999),
    collapsed = collapsed,
    queue_pos = queue_pos,
    image_heights = image_heights,
  })

  local anchor = nb:cell_anchor_row(cell)
  self._marks = self._marks or {}
  local mark_id = self._marks[cell.id]
  local opts = {
    virt_lines = virt,
    virt_lines_above = false,
    hl_mode = "combine",
    right_gravity = false,
  }
  if mark_id then opts.id = mark_id end
  self._marks[cell.id] = vim.api.nvim_buf_set_extmark(buf, ns_out, anchor, 0, opts)

  if not collapsed then
    if images then
      -- Single-extmark layout (SPEC I8). build_virt_lines reserved
      -- image-blank rows per image at its item position; image_offsets[i]
      -- is the matching row offset. image:render anchors each image
      -- there. The LAST image gets `with_virtual_padding = true` so
      -- image.nvim's own reservation back-stops any divergence between
      -- Mercury's row math and image.nvim's actual rendering (SPEC I5).
      self.image:render(cell, anchor, images, {
        offsets = image_offsets,
      })
    else
      self.image:clear_cell(cell)
    end
  else
    self.image:clear_cell(cell)
  end
end

return M
