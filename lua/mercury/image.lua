-- Inline image rendering via image.nvim. Caches handles by content hash so we
-- only re-create images when their content actually changes.

local Cfg = require("mercury.config")
local Output = require("mercury.output")
local Util = require("mercury.util")

local M = {}

-- Read config at call time (not load time) so users can hot-reload settings
-- without restarting nvim. Returns the output section, which is all image.lua
-- cares about (cell pixel size + max_rows clamp).
local function _cfg()
  return (Cfg.get() or {}).output or {}
end

local function api()
  local ok, mod = pcall(require, "image")
  if not ok then return nil end
  if mod.is_enabled and not mod.is_enabled() then return nil end
  return mod
end

M.available = function() return api() ~= nil end

local Renderer = {}
Renderer.__index = Renderer

function M.new(notebook)
  return setmetatable({
    notebook = notebook,
    cache = {},      -- cell_id -> { handles = { hash -> img }, placements = { hash -> opts } }
    config = require("mercury.config").get().output,
  }, Renderer)
end

local function same_placement(a, b)
  if not a or not b then return false end
  return a.y == b.y
    and a.x == b.x
    and a.width == b.width
    and a.render_offset_top == b.render_offset_top
    and a.with_virtual_padding == b.with_virtual_padding
    and a.window == b.window
end

function Renderer:_clear_handles(cell_id)
  local entry = self.cache[cell_id]
  if not entry then return end
  for _, img in pairs(entry.handles) do
    pcall(function() if img and img.clear then img:clear() end end)
  end
  self.cache[cell_id] = nil
end

function Renderer:clear_cell(cell)
  self:_clear_handles(cell.id)
end

function Renderer:clear_all()
  for id, _ in pairs(self.cache) do self:_clear_handles(id) end
end

-- GC handles for cell ids not in the `present` set. Called at the end of
-- each ui render pass so handles for deleted / merged / converted-to-
-- markdown cells don't survive forever in memory (and as ghost extmarks on
-- platforms where image.nvim keeps the placement alive after the source
-- cell is gone). SPEC Invariant 17.
function Renderer:gc(present)
  present = present or {}
  for id, _ in pairs(self.cache) do
    if not present[id] then self:_clear_handles(id) end
  end
end

-- Window-selection helper. Returns a window id currently showing this
-- buffer (focused window preferred, else first valid in win_findbuf), or
-- nil if no window shows it. Splits out so `compute_dimensions` and
-- `render` can share the lookup without duplication.
function Renderer:_visible_window()
  local cur = vim.api.nvim_get_current_win()
  local wins = vim.fn.win_findbuf(self.notebook.buf) or {}
  for _, w in ipairs(wins) do
    if w == cur and vim.api.nvim_win_is_valid(w) then return w end
  end
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) then return w end
  end
  return nil
end

-- Compute per-image render width (cols) and height (rows) without doing
-- any image.nvim placement. Returns:
--   widths[]          — per-image render width in columns
--   heights[]         — per-image render height in rows
--   available_cols    — the window-width-derived cap used as the upper
--                       bound for each image's width
--
-- Pulled out as a public method so output.lua can interleave image
-- placeholders with text in the cell's virt_lines stack: it needs to know
-- how many blank lines to reserve per image BEFORE the placements are
-- finalised. `image.unavailable` is mutated on each image whose bytes
-- can't be read (the renderer surfaces a text placeholder for those).
function Renderer:compute_dimensions(images)
  local widths, heights = {}, {}
  if not images or #images == 0 then
    return widths, heights, 20
  end
  local win = self:_visible_window()
  local win_w = win and vim.api.nvim_win_get_width(win) or 80
  -- Available width: cap at 85% of the window so the image doesn't crowd
  -- the whole pane. Hard floor of 20 cols so very narrow splits still render.
  local available_cols = math.max(20, math.floor(win_w * 0.85))
  local cfg = _cfg()
  local max_rows = cfg.image_max_height_rows or 40
  local cell_w = cfg.cell_width_px or 8
  local cell_h = cfg.cell_height_px or 16

  for i, img in ipairs(images) do
    local img_cols = available_cols
    local rows = 1
    img.unavailable = nil
    if img.kind == "png" or img.kind == "jpeg" or img.kind == "svg" then
      local data = Util.read_file(img.path)
      if not data or data == "" then
        img.unavailable = true
        img_cols = 1
        rows = 1
      else
        local w, h = Output.image_dimensions(img.kind, data)
        if w and h then
          local natural_cols = math.ceil(w / cell_w)
          img_cols = math.min(available_cols, natural_cols)
          rows = Output.image_row_height(w, h, img_cols, cell_w, cell_h, max_rows)
        else
          -- Unknown dimensions (e.g. SVG without an intrinsic size): use the
          -- pessimistic max_rows so wide plots don't truncate. Invariant 15.
          rows = max_rows
        end
      end
    end
    widths[i] = img_cols
    heights[i] = rows
  end
  return widths, heights, available_cols
end

-- Render images for a cell. Two layout modes, chosen by `layout.offsets`:
--   * `layout.offsets` is a list of per-image row offsets (anchored against
--     `anchor_row`) — used by the interleave path (output.lua reserved
--     blank rows in virt_lines for each image; we place at those rows).
--   * No `layout.offsets` — fallback to cumulative geometric stack
--     (back-compat for direct callers / tests).
--
-- `layout.widths` and `layout.heights` may be supplied to skip the
-- compute_dimensions pass when the caller already has them.
function Renderer:render(cell, anchor_row, images, layout)
  layout = layout or {}
  local mod = api()
  if not mod then return 0 end
  if not images or #images == 0 then
    self:_clear_handles(cell.id)
    return 0
  end

  local entry = self.cache[cell.id] or { handles = {}, placements = {} }
  entry.placements = entry.placements or {}
  local seen = {}

  local win = self:_visible_window()
  -- Window must exist before from_file is called — image.nvim's render
  -- path needs a live window. The BufWinEnter autocmd re-runs render()
  -- when the buffer is revealed; cached handles survive the gap.
  if not win then return 0 end

  local widths, heights = layout.widths, layout.heights
  if not widths or not heights then
    widths, heights = self:compute_dimensions(images)
  end

  -- Place each image. Distinct extmark `x` columns prevent extmark
  -- collisions when many images share the same anchor row.
  --
  -- When `layout.offsets` is provided we trust it — output.lua reserved
  -- the exact blank rows we're placing into, and the geometry is
  -- already interleaved with the cell's text. Otherwise we fall back to
  -- cumulative stacking with a 1-row visual gap between consecutive
  -- images so the user can tell where one ends and the next begins.
  --
  -- IMPORTANT: only `width` is passed to image.nvim — `height` is
  -- computed by image.nvim itself. Forcing both `width` and `height` via
  -- `from_file` made real image.nvim render NOTHING.
  local offsets = layout.offsets
  local cumulative = 0
  for i, img in ipairs(images) do
    seen[img.hash] = true
    if not img.unavailable then
      local is_last = (i == #images)
      local off = offsets and offsets[i] or cumulative
      local opts = {
        buffer = self.notebook.buf,
        window = win,
        inline = true,
        -- With explicit offsets, the caller has reserved blank virt_lines
        -- below the anchor — virtual_padding from image.nvim would
        -- double-count. Without offsets, the last image still reserves
        -- padding so following cells aren't covered (back-compat).
        with_virtual_padding = (offsets == nil) and is_last or false,
        x = i - 1,
        y = anchor_row,
        width = widths[i],
        render_offset_top = off,
      }
      local handle = entry.handles[img.hash]
      local prev = entry.placements[img.hash]
      if not (handle and same_placement(prev, opts)) then
        if handle and handle.clear then pcall(function() handle:clear() end) end
        local ok, h = pcall(mod.from_file, img.path, opts)
        if ok and h then
          pcall(function() h:render() end)
          entry.handles[img.hash] = h
          entry.placements[img.hash] = opts
        else
          entry.handles[img.hash] = nil
          entry.placements[img.hash] = nil
        end
      else
        -- Re-paint cached handle so a tab-switch round-trip gets the image
        -- back. Idempotent + cheap (no disk read).
        pcall(function() if handle.render then handle:render() end end)
      end
    end
    -- 1-row visual gap row between consecutive RENDERED images. Skip the
    -- gap on unavailable images (nothing was drawn — gap would be a row
    -- of empty space with no visual separation purpose) so the rest of
    -- the row math stays predictable for direct callers / fallback mode.
    cumulative = cumulative + heights[i] + (img.unavailable and 0 or 1)
  end

  for hash, h in pairs(entry.handles) do
    if not seen[hash] then
      pcall(function() if h.clear then h:clear() end end)
      entry.handles[hash] = nil
      entry.placements[hash] = nil
    end
  end

  self.cache[cell.id] = entry
  return cumulative
end

return M
