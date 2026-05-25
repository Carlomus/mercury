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

-- Cache key for image.nvim placements. y is EXCLUDED from the comparison
-- because we now set y dynamically to body_end's current screen row
-- (SPEC I18, window=nil mode) — y changes on every scroll. The cache
-- still hits on unchanged content/x/width/offset; y differences are
-- propagated to the cached handle via image:move() rather than tearing
-- down and recreating.
local function same_placement(a, b)
  if not a or not b then return false end
  return a.x == b.x
    and a.width == b.width
    and a.render_offset_top == b.render_offset_top
    and a.with_virtual_padding == b.with_virtual_padding
end

-- Compute body_end's terminal screen row (0-indexed). Returns nil if no
-- valid window is found.
--
-- For body_end visible in the viewport: vim.fn.screenpos returns the
-- 1-indexed terminal row directly; subtract 1.
--
-- For body_end above the viewport (cell scrolled past): screenpos
-- returns 0,0. Extrapolate using `winrow + (body_end_1idx - topline)`
-- — assumes a linear buffer (no folds, no virt_lines_above on
-- intervening lines). For Mercury cells with only virt_lines_below,
-- this is accurate enough; even when it's slightly off, image.nvim's
-- bounds check (is_above) will clip or hide the image correctly.
local function _body_end_screen_y_0idx(win, body_end)
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  -- screenpos errors with E966 if the line number is past the buffer's
  -- last line — happens in test setups and during transient states
  -- where the cell scan hasn't caught up with the buffer. pcall it
  -- and treat any failure as "off-screen, extrapolate".
  local ok, sp = pcall(vim.fn.screenpos, win, body_end + 1, 1)
  if ok and sp and type(sp.row) == "number" and sp.row > 0 then
    return sp.row - 1
  end
  local wi_list = vim.fn.getwininfo(win)
  local wi = wi_list and wi_list[1]
  if not wi then return nil end
  local topline = wi.topline or 1
  local winrow = wi.winrow or 1
  return winrow + body_end - topline
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

-- Pin image.nvim's extmark with right_gravity=false so text inserted at
-- the anchor column doesn't shift it. image.nvim creates its extmark
-- with default right_gravity=true (image/image.lua, the
-- vim.api.nvim_buf_set_extmark call); when the user types at body_end's
-- col 0 the extmark shifts right, image.nvim's TextChanged handler then
-- spots the move via `has_extmark_moved()` and re-renders the image at
-- the new column — visually the image jumps horizontally.
--
-- DELETE-AND-RECREATE, not in-place update. Empirically, calling
-- nvim_buf_set_extmark with the existing id and an opts table that
-- includes `right_gravity` does NOT always change the gravity on the
-- existing extmark in older nvim builds. Delete + set with a fresh
-- id guarantees the gravity sticks.
local function _pin_extmark(img)
  if not img then return end
  if not img.buffer or not img.extmark then return end
  if not img.global_state or not img.global_state.extmarks_namespace then return end
  if not img.internal_id then return end
  local ns = img.global_state.extmarks_namespace
  local row = img.extmark.row or 0
  local col = img.extmark.col or 0
  pcall(vim.api.nvim_buf_del_extmark, img.buffer, ns, img.internal_id)
  pcall(
    vim.api.nvim_buf_set_extmark,
    img.buffer,
    ns,
    row,
    col,
    { id = img.internal_id, right_gravity = false, strict = false }
  )
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

-- Render images for a cell using image.nvim's `inline=true` mode with
-- `window = nil` (SPEC I18). With window=nil, image.nvim's renderer
-- takes a single simple branch (renderer.lua:214):
--
--     absolute_x = original_x
--     absolute_y = original_y + render_offset_top
--
-- — no `screenpos`, no lock branch, no diff branch, no `get_overlap`
-- helper. Just direct screen coordinates. Mercury controls them.
--
-- This bypasses all the image.nvim renderer quirks that gave us the
-- previous bug grab-bag (image-snaps-to-image-2, image-stays-on-scroll,
-- image-overlaps-text-on-scroll, image-disappears-in-multi-cell). The
-- trade-offs:
--
--   * `y` is now a SCREEN row, computed dynamically per render and
--     per WinScrolled event (Renderer:reposition_for_scroll below).
--     Same_placement excludes y from the cache key — we update y via
--     image:move() on cache hits instead of tearing down and recreating.
--   * image.nvim's own auto-cleanup on BufLeave/WinClosed/TabEnter
--     (init.lua:296) skips images with window=nil. Mercury hooks
--     BufLeave/WinLeave/BufWipeout and calls Renderer:clear_pixels_only
--     to manually clear the kitty graphics when the buffer/window goes
--     out of view, and Renderer:redraw_all on BufWinEnter/WinEnter/
--     TabEnter to re-emit them when it comes back.
--   * Cell-spill safety still relies on our virt_lines reservation
--     (SPEC I16) since image.nvim's virtual-padding path isn't active.
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
  if not win then return 0 end

  local widths, heights = self:compute_dimensions(images)

  -- y is the SCREEN row (0-indexed) where body_end currently displays.
  -- absolute_y = y + offset_top with window=nil, so we want
  -- y + offset_top + 1 (the kitty cursor +1) to land at body_end's
  -- terminal row + virt_line_offset.
  local screen_y = _body_end_screen_y_0idx(win, anchor_row)
  if not screen_y then return 0 end

  local offsets = layout.offsets
  local text_offset = layout.text_offset or 0
  local cumulative = 0
  for i, img in ipairs(images) do
    seen[img.hash] = true
    if not img.unavailable then
      -- SPEC I4: cumulative offsets stack images vertically with a +1
      -- visual gap row baked in.
      -- SPEC I13 (window=nil mode): with y = body_end_screen_row_0idx,
      -- absolute_y = y + offset_top + 1 = (body_end's 1-indexed
      -- terminal row) + offset_top. For the image to land at
      -- body_end_screen + virt_line_idx + 1 (= virt_line[K]'s terminal
      -- row), set offset_top = virt_line_idx + 1.
      local virt_line_idx = offsets and offsets[i] or (text_offset + cumulative)
      local off = virt_line_idx + 1
      local opts = {
        buffer = self.notebook.buf,
        window = nil,                   -- SPEC I18: bypass image.nvim's renderer branches
        -- SPEC I18 (extended): inline = FALSE so image.nvim doesn't
        -- create a per-image extmark. We pass y as a SCREEN ROW
        -- (0-indexed terminal row), but image.nvim's inline-mode
        -- extmark code stores y as a BUFFER ROW. If the buffer
        -- later changes near that row, the extmark moves;
        -- image.nvim's TextChanged handler then reads the new
        -- BUFFER row, writes it back into geometry.y, and re-renders
        -- the image at `that_buffer_row + offset_top` — a meaningless
        -- terminal position. inline=false skips the entire extmark
        -- creation block (image.lua:101 `if was_rendered and
        -- self.buffer and self.inline then ...`), so
        -- has_extmark_moved returns false (no extmark) and the
        -- TextChanged handler does nothing for our images.
        inline = false,
        with_virtual_padding = false,   -- SPEC I16
        x = i - 1,                      -- distinct cols per image
        y = screen_y,                   -- body_end's CURRENT screen row (0-indexed)
        width = widths[i],
        render_offset_top = off,
        -- No `overlap` opt. With window=nil, image.nvim's renderer
        -- skips the entire `get_overlap_scroll_position` /
        -- diff-branch / lock-branch block. overlap is meaningless
        -- here and only mattered when image.nvim was doing screen
        -- positioning for us.
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
          _pin_extmark(h)
          entry.handles[img.hash] = h
          entry.placements[img.hash] = opts
        else
          entry.handles[img.hash] = nil
          entry.placements[img.hash] = nil
        end
      elseif handle.geometry and handle.geometry.y ~= screen_y then
        -- Cache hit but body_end's screen row changed (typing added a
        -- line earlier in the buffer, scroll, etc.). Update y via
        -- image:move() — cheap, no disk read.
        pcall(function() handle:move(handle.geometry.x or (i - 1), screen_y) end)
        _pin_extmark(handle)
        entry.placements[img.hash] = opts
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

-- Reposition every cached image to its cell's current body_end screen
-- row (SPEC I18, window=nil mode). Called from init.lua's WinScrolled
-- autocmd. Cheap: at most one image:move() per handle, no disk read,
-- and only when the row actually changed.
function Renderer:reposition_for_scroll()
  local win = self:_visible_window()
  if not win then return end
  for cell_id, entry in pairs(self.cache or {}) do
    -- Find the cell by id. notebook.cells is small, linear scan is fine.
    local cell = nil
    for _, c in ipairs(self.notebook.cells or {}) do
      if c.id == cell_id then cell = c; break end
    end
    if cell then
      local new_y = _body_end_screen_y_0idx(win, cell.body_end)
      if new_y then
        for _, handle in pairs(entry.handles or {}) do
          if handle.geometry and handle.geometry.y ~= new_y then
            pcall(function()
              handle:move(handle.geometry.x or 0, new_y)
            end)
            _pin_extmark(handle)
          end
        end
      end
    end
  end
end

-- Clear all kitty graphics pixels for our cached images, but PRESERVE
-- the handle objects so we can redraw cheaply later. Used on
-- BufLeave/WinLeave — image.nvim's own BufLeave cleanup skips images
-- with window=nil (init.lua:312 in image.nvim), so we must do this
-- ourselves or the pixels stay on the terminal even after the buffer
-- is no longer visible.
--
-- Shallow=true tells image.nvim's backend.clear to keep the
-- state.images entry; we still own the handle and can re-render it.
function Renderer:clear_pixels_only()
  for _, entry in pairs(self.cache or {}) do
    for _, handle in pairs(entry.handles or {}) do
      pcall(function()
        if handle.clear then handle:clear(true) end
      end)
    end
  end
end

-- Re-emit kitty graphics for every cached image. Used on
-- BufWinEnter/WinEnter/TabEnter after a clear_pixels_only — the
-- handles still exist with their last geometry, so render() reuses
-- the in-memory transmitted image bytes and just re-emits the
-- placement command. No disk read, no decode.
function Renderer:redraw_all()
  for _, entry in pairs(self.cache or {}) do
    for _, handle in pairs(entry.handles or {}) do
      pcall(function() if handle.render then handle:render() end end)
    end
  end
end

return M
