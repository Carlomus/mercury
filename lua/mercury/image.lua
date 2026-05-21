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

function Renderer:render(cell, anchor_row, images)
  local mod = api()
  if not mod then return 0 end
  if not images or #images == 0 then
    self:_clear_handles(cell.id)
    return 0
  end

  local entry = self.cache[cell.id] or { handles = {}, placements = {} }
  entry.placements = entry.placements or {}
  local seen = {}

  -- Render in a window that's actually showing this notebook buffer; the
  -- callback may fire while the user is focused elsewhere.
  local wins = vim.fn.win_findbuf(self.notebook.buf)
  local win = wins and wins[1]
  if not win or not vim.api.nvim_win_is_valid(win) then return 0 end
  local win_w = vim.api.nvim_win_get_width(win)
  -- Available width: cap at 85% of the window so the image doesn't crowd the
  -- whole pane. Hard floor of 20 cols so very narrow splits still render.
  local available_cols = math.max(20, math.floor(win_w * 0.85))
  local cfg = _cfg()
  local max_rows = cfg.image_max_height_rows or 40

  local cell_w = cfg.cell_width_px or 8
  local cell_h = cfg.cell_height_px or 16

  -- First pass: compute each image's render width (cols) and row height.
  --
  -- The render width is min(available_cols, natural_cols). The natural-size
  -- floor prevents a 32x32 icon from being upscaled to 85% of the window;
  -- VS Code / Jupyter Lab render images at their intrinsic resolution and
  -- only downscale when larger than the cell. This matches that contract.
  -- SVG is the exception: it's resolution-independent, so we use the full
  -- available width (rendering as small as the natural PNG dimensions would
  -- waste the vector's whole point).
  local widths, heights = {}, {}
  for i, img in ipairs(images) do
    local img_cols = available_cols
    local rows = max_rows
    if img.kind == "png" or img.kind == "jpeg" or img.kind == "svg" then
      local data = Util.read_file(img.path)
      local w, h = Output.image_dimensions(img.kind, data or "")
      if w and h then
        local natural_cols = math.ceil(w / cell_w)
        img_cols = math.min(available_cols, natural_cols)
        rows = Output.image_row_height(w, h, img_cols, cell_w, cell_h, max_rows)
      end
    end
    widths[i] = img_cols
    heights[i] = rows
  end

  -- Place each image. Distinct columns prevent extmark collisions when many
  -- images share the same anchor row. Only the last image reserves virtual
  -- padding for the full stacked height. Re-use a cached handle when both the
  -- content hash and the placement opts are unchanged — re-creating on every
  -- rescan causes visible flicker on long cells.
  local cumulative = 0
  for i, img in ipairs(images) do
    seen[img.hash] = true
    local is_last = (i == #images)
    local opts = {
      buffer = self.notebook.buf,
      window = win,
      inline = true,
      with_virtual_padding = is_last,
      x = i - 1,                        -- distinct extmark col per image
      y = anchor_row,
      width = widths[i],
      render_offset_top = cumulative,
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
    end
    cumulative = cumulative + heights[i]
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
