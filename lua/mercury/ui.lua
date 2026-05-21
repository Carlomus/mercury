-- Buffer-level UI: cell highlights, separator overlay, output virt_lines.

local Output = require("mercury.output")
local Notebook = require("mercury.notebook")
local Cfg = require("mercury.config")
local Image = require("mercury.image")

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
  -- The text extmark itself goes away with the line, but the lookup table
  -- would otherwise grow without bound across a long editing session. Same
  -- problem applies to image.nvim handles, which the plugin holds onto until
  -- we explicitly clear them — we must drop those too or deleted cells leak
  -- live images.
  local present = {}
  for _, c in ipairs(nb.cells) do present[c.id] = true end
  if self._marks then
    for id in pairs(self._marks) do
      if not present[id] then self._marks[id] = nil end
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

  -- No output? Make sure we removed any prior decoration / images.
  if not out or (out.status == "idle" and #(out.items or {}) == 0) then
    -- Clear any prior extmark for this cell by scanning and re-creating? We
    -- track per-cell extmark id ourselves.
    if self["_marks"] and self._marks[cell.id] then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns_out, self._marks[cell.id])
      self._marks[cell.id] = nil
    end
    self.image:clear_cell(cell)
    return
  end

  local collapsed = (out._collapsed == true)
  local virt = Output.build_virt_lines(out, {
    show_status_pill = cfg.show_status_pill,
    max_preview_lines = collapsed and 0 or (cfg.max_preview_lines or 9999),
    collapsed = collapsed,
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
    -- Decoding base64 PNGs and writing them to tmp is wasted work if image.nvim
    -- isn't going to render them anyway.
    if Image.available() then
      local images = Output.extract_images(out)
      self.image:render(cell, anchor, images)
    else
      self.image:clear_cell(cell)
    end
  else
    self.image:clear_cell(cell)
  end
end

return M
