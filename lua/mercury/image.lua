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

-- Compute per-image render width (cols) and reserved height (rows).
-- Both are consumed by the single-extmark interleave path: width is
-- passed to image.nvim's from_file (SPEC I1), height drives how many
-- blank virt_lines to reserve per image in our extmark (SPEC I6,
-- I8). Caller is `Output.build_virt_lines` (via ui.lua).
--
-- SPEC invariants:
--   I1 — width uses `cfg.cell_width_px` (default 8). Mercury does NOT
--        query image.nvim's runtime cell pixel size; doing so returned
--        larger values on common terminals and shrank images visibly.
--   I6 — reserved height = max(image_row_height + 3,
--                              ceil(image_row_height * 1.25)),
--        clamped to image_max_height_rows. The bump absorbs the
--        divergence between Mercury's static (8×16) cell-pixel
--        assumption and image.nvim's runtime terminal measurement,
--        so an intermediate image (no with_virtual_padding backstop,
--        SPEC I9) can't bleed into the row below.
function Renderer:compute_dimensions(images)
  local widths, heights = {}, {}
  if not images or #images == 0 then
    return widths, heights, 20
  end
  local win = self:_visible_window()
  local win_w = win and vim.api.nvim_win_get_width(win) or 80
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
          local bare = Output.image_row_height(
            w, h, img_cols, cell_w, cell_h, max_rows)
          -- SPEC Invariant I6 safety margin.
          local safe = math.max(bare + 3, math.ceil(bare * 1.25))
          rows = math.min(safe, max_rows)
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

-- Render images for a cell. Two layout modes, chosen by `layout`:
--
--   * `layout.offsets[i]` is per-image row offsets. The caller
--     (Output.build_virt_lines via ui.lua) reserved N+1 blank rows for
--     each image at its item position, and offsets[i] is the matching
--     row. We anchor image i there.
--   * No `layout.offsets` — fallback to cumulative geometric stacking
--     anchored at `layout.text_offset` (or 0). Used by direct callers
--     and tests that don't go through build_virt_lines.
--
-- The LAST image ALWAYS gets `with_virtual_padding = true` — image.nvim
-- reserves `render_offset_top + rendered_height` rows of virt_lines,
-- which sits BELOW our own virt_lines extmark and pushes the next cell
-- clear of the image stack. This is the safety net against any
-- divergence between our row math (uses `cell_width_px`/`cell_height_px`
-- from config) and image.nvim's actual rendering (queries the terminal
-- at runtime). Some over-reservation is the price; an image painting
-- over the next cell would be worse.
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

  local widths, heights = self:compute_dimensions(images)

  -- Place each image. Distinct extmark `x` columns prevent extmark
  -- collisions when many images share the same anchor row.
  --
  -- IMPORTANT: only `width` is passed to image.nvim — `height` is
  -- computed by image.nvim itself (SPEC I12). Forcing both `width` and
  -- `height` via `from_file` made real image.nvim render NOTHING.
  local offsets = layout.offsets
  local text_offset = layout.text_offset or 0
  local cumulative = 0
  for i, img in ipairs(images) do
    seen[img.hash] = true
    if not img.unavailable then
      local is_last = (i == #images)
      -- SPEC I4: cumulative offsets stack images vertically with a +1
      -- visual gap row baked in. SPEC I9: only the last image carries
      -- with_virtual_padding=true (SPEC I5 is the cell-spill backstop).
      local off = offsets and offsets[i] or (text_offset + cumulative)
      local opts = {
        buffer = self.notebook.buf,
        window = win,
        inline = true,
        -- Last image: image.nvim reserves the rest of the rows it
        -- actually needs (catches under-reserving from our height
        -- math). Others: no padding from image.nvim — our virt_lines
        -- already reserved the rows.
        with_virtual_padding = is_last,
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
      end
      -- Cache hit: do NOT re-call render() — image.nvim treats some
      -- repeated render() invocations as additional placements rather
      -- than a refresh, which caused the "single image shows up twice"
      -- regression. Tab-switch / window-revisit invalidation happens
      -- via force_invalidate_* in the autocmd path.
    end
    -- 1-row visual gap row between consecutive RENDERED images. Skip the
    -- gap on unavailable images (nothing was drawn — gap would be a row
    -- of empty space with no visual separation purpose).
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

-- Force-clear all cached handles for ALL cells so the next render
-- creates fresh placements. Called from init.lua's `VimResized`
-- autocmd (SPEC I11): the terminal's cell pixel size has actually
-- changed, so cached image.nvim handles reference stale geometry.
-- Wiring this to BufWinEnter / TabEnter / WinEnter was tried and
-- produced the "two slots per image" bug (SPEC I11).
function Renderer:force_invalidate_all()
  for id, _ in pairs(self.cache) do self:_clear_handles(id) end
end

return M
