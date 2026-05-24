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

-- same_placement intentionally EXCLUDES `y`. Under SPEC I18,
-- `y` is the terminal screen row of the cell's anchor — it changes
-- on every scroll, but a change in `y` does NOT require destroying
-- and recreating the image.nvim image. Instead, `image:move(x, y)`
-- updates the geometry cheaply (no disk read, no decode). Including
-- `y` in this comparison would force Mercury's periodic render
-- (TextChanged, BufWinEnter, etc.) to recreate every image after
-- any scroll, which churns image.nvim's state and produces visible
-- flicker.
--
-- Fields that DO require a fresh `from_file`: window context, x
-- (extmark differentiator), width (affects rendered pixel size),
-- render_offset_top (positions image inside the virt_lines block),
-- with_virtual_padding, overlap.
local function same_placement(a, b)
  if not a or not b then return false end
  return a.x == b.x
    and a.width == b.width
    and a.render_offset_top == b.render_offset_top
    and a.with_virtual_padding == b.with_virtual_padding
    and a.overlap == b.overlap
    and a.window == b.window
end

-- Fully remove an image.nvim image from its global registry.
-- `Image:clear()` removes the buffer extmark and clears the terminal
-- pixels, but image.nvim KEEPS the image object in `state.images`. Its
-- WinScrolled / WinResized autocmds then iterate that registry and
-- call `render()` on each image — recreating extmarks and re-painting
-- the kitty graphics. That's why "RestartClear doesn't work": Mercury
-- clears, image.nvim brings the images back.
--
-- image.nvim doesn't expose a public removal API, but each Image holds
-- a reference to the global state table via `image.global_state`. We
-- reach into `global_state.images` and nil out the entry after a
-- standard clear, so the next autocmd-driven render can't find it.
-- This is a bounded hack; if image.nvim ever ships a public
-- `api.destroy(id)`, swap to that.
local function _fully_remove_image(img)
  if not img then return end
  pcall(function() if img.clear then img:clear() end end)
  pcall(function()
    if img.global_state and img.global_state.images and img.id then
      img.global_state.images[img.id] = nil
    end
  end)
end

function Renderer:_clear_handles(cell_id)
  local entry = self.cache[cell_id]
  if not entry then return end
  for _, img in pairs(entry.handles) do
    _fully_remove_image(img)
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

-- Query image.nvim's runtime cell pixel size — populated by image.nvim
-- at startup from the terminal's TIOCGWINSZ ioctl, with 8×16 fallback
-- for terminals that don't report (typical SSH sessions).
--
-- Returns `cell_w, cell_h` (numbers). Falls back to 8, 16 when
-- image.nvim's API is unreachable, which keeps Mercury working in
-- mock/test environments where the module isn't loaded. Field names
-- (`cell_width`, `cell_height`) come from image.nvim's term.lua source:
--   https://github.com/3rd/image.nvim/blob/master/lua/image/utils/term.lua
local function _runtime_cell_size()
  local ok, term = pcall(require, "image.utils.term")
  if not ok or type(term) ~= "table" or type(term.get_size) ~= "function" then
    return nil, nil
  end
  local ok2, sz = pcall(term.get_size)
  if not ok2 or type(sz) ~= "table" then return nil, nil end
  local w, h = sz.cell_width, sz.cell_height
  if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
    return w, h
  end
  return nil, nil
end

-- Compute per-image render width (cols) and reserved height (rows).
-- Both are consumed by the single-extmark interleave path: width is
-- passed to image.nvim's from_file (SPEC I1), height drives how many
-- blank virt_lines to reserve per image in our extmark (SPEC I6,
-- I8). Caller is `Output.build_virt_lines` (via ui.lua).
--
-- WIDTH (SPEC I1) — `natural_cols = ceil(w_px / 8)`. Static 8 px/cell on
-- purpose: users have configured around the 8-px assumption and an
-- earlier change that used image.nvim's runtime cell_width here shrank
-- every image visibly. Keeping static 8 preserves the user's familiar
-- image size.
--
-- HEIGHT (SPEC I6, I14) — uses image.nvim's runtime cell_w / cell_h so
-- our row reservation matches what image.nvim actually draws:
--     target_w_px  = img_cols * runtime_cell_w
--     scaled_h_px  = h_px * (target_w_px / w_px)
--     rows         = ceil(scaled_h_px / runtime_cell_h)
--
-- Safety margin (SPEC I6) — ZERO. With I14 the row math matches
-- image.nvim within sub-cell rounding (0–1 row drift). The gap row
-- that build_virt_lines adds AFTER every non-trailing image absorbs
-- the worst-case +1 drift, so the bare reservation suffices.
-- Previous values (+25%/+3, then +1) left a visible blank row below
-- every image — the "too many lines between sequential images"
-- regression. Now bare is exactly the number we reserve; the gap
-- row is the only visible separator between consecutive content.
-- Runtime-query-fallback path: in that case our static 8×16 may
-- drift more than 1 row from image.nvim's actual, but the LAST
-- image's `with_virtual_padding=true` (SPEC I5/I15) is the
-- terminal backstop there. For intermediate images, the gap row
-- provides 1 row of buffer.
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
  -- Static width baseline (SPEC I1).
  local cell_w_static = cfg.cell_width_px or 8
  -- Runtime values for the height row math (SPEC I14). Fall back to
  -- config defaults when the runtime query isn't reachable.
  local rt_w, rt_h = _runtime_cell_size()
  local cell_w_runtime = rt_w or cfg.cell_width_px or 8
  local cell_h_runtime = rt_h or cfg.cell_height_px or 16

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
          -- Width: keep static 8 px/cell so the image renders at the
          -- familiar size (SPEC I1).
          local natural_cols = math.ceil(w / cell_w_static)
          img_cols = math.min(available_cols, natural_cols)
          -- Height: use image.nvim's runtime cell sizes (SPEC I14).
          -- No safety bump (SPEC I6) — the gap row in
          -- build_virt_lines is the buffer for any sub-cell drift.
          rows = Output.image_row_height(
            w, h, img_cols, cell_w_runtime, cell_h_runtime, max_rows)
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

-- Compute the screen position (1-indexed row + col) where buffer row
-- `anchor_row` displays in the focused window showing this notebook.
-- Returns `nil, nil` if no window shows the buffer OR the row is
-- off-screen. SPEC I18 — Mercury uses this to drive `window=nil`
-- manual-position image rendering.
function Renderer:_anchor_screen_pos(anchor_row)
  local win = self:_visible_window()
  if not win then return nil, nil end
  local ok, sp = pcall(vim.fn.screenpos, win, anchor_row + 1, 1)
  if not ok or type(sp) ~= "table" then return nil, nil end
  -- screenpos returns 0,0 when the buffer line is outside the viewport.
  if sp.row == 0 and sp.col == 0 then return nil, nil end
  return sp.row, sp.col
end

-- Render images for a cell using image.nvim's `window=nil` absolute-
-- positioning mode (SPEC I18). Mercury computes the terminal screen row
-- where each image should land based on the current scroll state and
-- passes it as `y`; image.nvim then renders at exactly that row, plus
-- `render_offset_top`.
--
-- Why window=nil mode:
--
--   * `inline=true` + `window=current_win` (the previous design)
--     made image.nvim's renderer take its "partial-scroll" path
--     whenever the user scrolled into a cell's virt_lines area
--     (Vim keeps `topline` pinned to the cell's body_end while
--     scrolling through its virt_lines, and image.nvim's
--     `if original_y + 1 == topline` branch locks the image at
--     `winrow`). That produced the "image stays fixed on terminal /
--     image appears below text after scroll" bugs.
--
--   * `window=nil` makes image.nvim skip ALL the scroll-handling
--     branches (including partial-scroll) and use straight absolute
--     terminal coordinates: `absolute_y = original_y + render_offset_top`.
--     image.nvim's `WinScrolled` autocmd path filters by
--     `(opts.window, opts.buffer)` — our images with `window=nil`
--     fail that filter and are NOT re-rendered by image.nvim's
--     autocmds. Mercury owns scroll updates entirely (see
--     `reposition_for_scroll`).
--
--   * `layout.offsets[i]` is the buffer-relative virt_line index;
--     `render_offset_top = offsets[i] + 1` (SPEC I13). Combined with
--     `y = body_end_screen_row`, the image ends up at the right
--     terminal row.
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

  -- Get the screen row of the cell's anchor. nil → off-screen → we
  -- still create the placement but at a sentinel y that triggers
  -- image.nvim's `is_above` bounds-clear (so nothing's painted in the
  -- viewport). When the cell scrolls back into view, our
  -- `reposition_for_scroll` updates the geometry to the real row.
  local screen_row = self:_anchor_screen_pos(anchor_row)
  local off_screen_sentinel = -1000

  -- Remember the buffer-relative anchor on the cache entry so the
  -- scroll-driven reposition can recompute terminal coords without
  -- needing the cell list.
  entry.anchor_row = anchor_row

  local widths, heights = self:compute_dimensions(images)

  local offsets = layout.offsets
  local text_offset = layout.text_offset or 0
  local cumulative = 0
  for i, img in ipairs(images) do
    seen[img.hash] = true
    if not img.unavailable then
      -- SPEC I4: cumulative offsets stack images vertically with a +1
      -- visual gap row baked in.
      -- SPEC I13: convert virt_line index → render_offset_top (+1
      -- because image.nvim's effective position is `y + offset_top`,
      -- and virt_line[K] sits at y+(K+1) when y is the screen row of
      -- the anchor buffer line; with window=nil mode, y IS that
      -- screen row so the same +1 applies).
      local virt_line_idx = offsets and offsets[i] or (text_offset + cumulative)
      local off = virt_line_idx + 1
      local image_y = screen_row or off_screen_sentinel
      local opts = {
        -- SPEC I18: window=nil so image.nvim skips its partial-scroll
        -- branches and `WinScrolled` autocmd filter — Mercury owns
        -- positioning entirely via this render call + reposition_for_scroll.
        buffer = self.notebook.buf,
        window = nil,
        inline = true,
        with_virtual_padding = false,
        x = i - 1,
        y = image_y,
        width = widths[i],
        render_offset_top = off,
      }
      local handle = entry.handles[img.hash]
      local prev = entry.placements[img.hash]
      if not (handle and same_placement(prev, opts)) then
        -- Fully remove the prior image from image.nvim's registry so
        -- it can't be re-rendered by autocmds (SPEC I17).
        if handle then _fully_remove_image(handle) end
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
        -- Cache hit on identity fields. y may still have changed (the
        -- buffer scrolled between renders) — update via image:move so
        -- the placement tracks the current screen row without an
        -- expensive from_file. SPEC I18.
        if prev.y ~= opts.y then
          prev.y = opts.y
          pcall(function() handle:move(opts.x or 0, opts.y) end)
        end
      end
    end
    -- 1-row visual gap row between consecutive RENDERED images. Skip the
    -- gap on unavailable images (nothing was drawn — gap would be a row
    -- of empty space with no visual separation purpose).
    cumulative = cumulative + heights[i] + (img.unavailable and 0 or 1)
  end

  for hash, h in pairs(entry.handles) do
    if not seen[hash] then
      -- Fully remove (not just clear) so image.nvim's autocmds can't
      -- re-render this stale image. SPEC I17.
      _fully_remove_image(h)
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

-- Reposition all cached images for the current scroll state. Called
-- from init.lua's `WinScrolled` autocmd (SPEC I18). Each image's
-- terminal-screen `y` is recomputed from its cell's `anchor_row` (the
-- buffer row, captured at render time). image.nvim's `image:move(x, y)`
-- updates geometry and re-renders at the new position; with
-- `window=nil` this stays in the absolute-coordinate path and never
-- touches image.nvim's partial-scroll logic.
--
-- Off-screen handling: when the anchor row is no longer visible,
-- screen_pos returns nil and we move the image to a far-negative `y`
-- — image.nvim's `is_above` bounds check clears the terminal pixels.
-- When the anchor scrolls back into view, the next call here updates
-- `y` and image.nvim re-renders at the proper position.
function Renderer:reposition_for_scroll()
  if not api() then return end
  for cell_id, entry in pairs(self.cache or {}) do
    if entry.anchor_row ~= nil and entry.handles then
      local sp_row = self:_anchor_screen_pos(entry.anchor_row)
      local image_y = sp_row or -1000
      for hash, handle in pairs(entry.handles) do
        local placement = entry.placements and entry.placements[hash]
        if placement and handle and handle.move then
          local prev_y = placement.y
          if prev_y ~= image_y then
            placement.y = image_y
            pcall(function() handle:move(placement.x or 0, image_y) end)
          end
        end
      end
    end
  end
end

return M
