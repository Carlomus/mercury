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
-- every image visibly (because most terminals' actual cell_width > 8).
-- Keeping static 8 preserves the user's familiar image size, and
-- image.nvim is free to render the image at its own cell_width — the
-- image is "upscaled" pixel-wise when the runtime cell is wider, which
-- is the visual result the user wants.
--
-- HEIGHT (SPEC I6, I14) — must match image.nvim's actual rendered row
-- count or our reservation underflows and the image paints over the
-- next row. image.nvim's height formula is:
--     target_w_px  = img_cols * runtime_cell_w
--     scaled_h_px  = h_px * (target_w_px / w_px)
--     rows         = ceil(scaled_h_px / runtime_cell_h)
-- so Mercury MUST use image.nvim's runtime cell_w / cell_h in the row
-- math (SPEC I14). With 8×16 static we'd only be correct when the
-- terminal's cell aspect happens to match — common but not universal,
-- and a single percentage-point divergence accumulates across multi-
-- image cells.
--
-- Even with the runtime values we keep the +25% +3 safety bump (SPEC I6)
-- as a backstop for:
--   * the runtime query failing (image.nvim API drift / mock env);
--   * any future image.nvim scaling pass we haven't accounted for;
--   * sub-cell rounding inside image.nvim's renderer.
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
          local bare = Output.image_row_height(
            w, h, img_cols, cell_w_runtime, cell_h_runtime, max_rows)
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
  --
  -- screenpos / render_offset_top semantics (SPEC I13).
  -- image.nvim renders the image at:
  --     absolute_y = screenpos(window, y+1, x+1).row + render_offset_top
  -- `screenpos.row` is the SCREEN ROW of body_end itself (NOT below it).
  -- The first virt_line we attach to that row displays at body_end_screen
  -- + 1. So to render the image at virt_line[K] (0-indexed within our
  -- virt_lines stack), `render_offset_top` must be `K + 1`.
  -- `layout.offsets[i]` is the 0-indexed K from output.lua; we add 1 here
  -- to convert. Forgetting this +1 makes the image render at virt_line[K-1]
  -- — concretely, the first image ends up on the pill row (overlap).
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
      local virt_line_idx = offsets and offsets[i] or (text_offset + cumulative)
      local off = virt_line_idx + 1   -- SPEC I13: convert idx → screen offset
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
