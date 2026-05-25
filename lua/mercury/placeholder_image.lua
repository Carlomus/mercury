-- Kitty unicode-placeholder image rendering for Mercury.
--
-- This module is the modern replacement for the image.nvim cursor-based
-- rendering path (SPEC I18). Where the old path computed terminal
-- coordinates from buffer rows and re-positioned images on every scroll
-- (badly, in many edge cases), this path embeds the kitty unicode
-- placeholder character (U+10EEEE) directly into Mercury's virt_lines.
-- Each placeholder cell carries two diacritics encoding its row/col
-- inside the image grid, and the foreground color of the cell encodes
-- the image_id. Kitty reads those properties off the terminal and
-- paints image pixels at exactly those character positions.
--
-- The user-visible win: because the placeholders ARE part of nvim's
-- text rendering, they scroll/shift/redraw with the buffer like any
-- other virt_text. No WinScrolled hook, no image:move, no renderer
-- branches — image follows its cell automatically.
--
-- Image transmission to kitty (the byte upload) is delegated to
-- snacks.image, which already handles kitty/tmux passthrough,
-- async-conversion, and lifecycle. Snacks gives us an `id`; we then
-- generate the placeholder grid ourselves and let Mercury's virt_lines
-- carry it.

local Util = require("mercury.util")
local Cfg = require("mercury.config")

local M = {}

-- The kitty placeholder character. Every cell of the rendered image
-- grid is a copy of this character followed by two diacritics encoding
-- (row, col) within the image.
local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

-- Diacritic codepoints (kitty protocol). Each entry is the unicode
-- codepoint (as hex) of a combining mark that — when applied to the
-- placeholder character — tells kitty "this cell is at row/col N of
-- the image". The list defines a stable mapping from indices 1..N to
-- specific codepoints; kitty has a matching table on its side.
--
-- Borrowed verbatim from snacks.image.placement so we use kitty's
-- exact accepted set (truncating or substituting would silently
-- corrupt images larger than the largest contiguous prefix kitty
-- recognized).
local DIACRITICS_HEX = "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244"

-- Lazy-decoded diacritic table: indices 1..N → single-character UTF-8
-- strings. Built once on first access.
local _diac_table
local function diacritics()
  if _diac_table then return _diac_table end
  _diac_table = {}
  for _, hex in ipairs(vim.split(DIACRITICS_HEX, ",", { plain = true })) do
    _diac_table[#_diac_table + 1] = vim.fn.nr2char(tonumber(hex, 16))
  end
  return _diac_table
end

-- ---------- snacks integration ----------

-- Resolve `snacks.image.image` lazily so importing Mercury doesn't
-- depend on snacks at load time. Returns the module or nil.
local function _snacks_image()
  local ok_snacks = pcall(require, "snacks")
  if not ok_snacks then return nil end
  -- Snacks must be loaded; the top-level `snacks` module's image
  -- submodule resolves via its __index metamethod.
  if not _G.Snacks or not _G.Snacks.image then return nil end
  if not _G.Snacks.image.image then return nil end
  return _G.Snacks.image.image
end

-- Resolve `snacks.image.terminal` for env / placeholder-support detection.
local function _snacks_terminal()
  if not _G.Snacks or not _G.Snacks.image then return nil end
  return _G.Snacks.image.terminal
end

-- Returns true iff (a) snacks is loaded AND (b) the current terminal
-- supports the kitty unicode-placeholder protocol. Currently kitty and
-- ghostty support it; wezterm/foot/zellij don't (snacks's env table).
--
-- Side effect: ensures snacks.image.setup() has been called and that
-- vim.o.termguicolors is true. Both are prerequisites for the
-- placeholder protocol — snacks's setup wires up the cleanup autocmds
-- (without which transmitted images leak), and termguicolors makes
-- nvim emit the per-image fg color as a 24-bit RGB sequence (without
-- which kitty can't recover the image_id from the placeholder cell's
-- color). If termguicolors is off, available() returns false; user
-- must opt in by setting `vim.o.termguicolors = true`.
local _setup_done = false
local _tgc_warned = false
function M.available()
  if Cfg.get and Cfg.get().output and Cfg.get().output.disable_placeholders then
    return false
  end
  local img_mod = _snacks_image()
  if not img_mod then return false end
  if _G.Snacks and _G.Snacks.image and not _setup_done then
    _setup_done = true
    pcall(function() _G.Snacks.image.setup() end)
  end
  local term = _snacks_terminal()
  if not term or type(term.env) ~= "function" then return false end
  local ok, env = pcall(term.env)
  if not ok or type(env) ~= "table" then return false end
  if env.placeholders ~= true then return false end
  if not vim.o.termguicolors then
    if not _tgc_warned then
      _tgc_warned = true
      vim.notify(
        "[mercury] kitty unicode placeholders require `:set termguicolors`. "
          .. "Add `vim.o.termguicolors = true` to your config. "
          .. "Falling back to legacy image.nvim path.",
        vim.log.levels.WARN)
    end
    return false
  end
  return true
end

-- ---------- terminal cell size ----------

-- Probe image.nvim's runtime cell pixel size; same helper used by
-- image.lua's compute_dimensions (SPEC I14) so width/height land at
-- the same number of cells as the old path. Falls back to config
-- defaults when image.nvim isn't reachable.
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

-- ---------- highlight management ----------

-- Per-image highlight registry. The fg of each highlight is the image_id
-- (as a 24-bit RGB integer); kitty parses the cell's fg color to recover
-- the id when rendering.
--
-- bg = "NONE" matches snacks's own placement highlight ("bg = 'none'") —
-- without it the placeholder cells inherit Normal's background, which
-- doesn't break kitty's pixel painting per se but DOES emit extra
-- background-color escape sequences that have been observed to confuse
-- the placeholder decoder in some kitty / multiplexer combinations.
--
-- nocombine = true so other syntax highlights on the same row can't
-- override our fg encoding.
--
-- nvim doesn't expose a way to query whether a highlight exists, so we
-- track our own set to avoid redundant set_hl calls per render.
local _hl_set = {}
local function _ensure_hl(id)
  local name = "MercuryImg_" .. tostring(id)
  if _hl_set[name] then return name end
  vim.api.nvim_set_hl(0, name, {
    fg = id,
    bg = "NONE",
    nocombine = true,
  })
  _hl_set[name] = true
  return name
end

-- ---------- placeholder grid generation ----------

-- Build the rows of the placeholder grid. Each row is a Lua string
-- containing `width_cells` repetitions of:
--     PLACEHOLDER + diac[row] + diac[col]
-- Highlighting (fg = image_id) is applied at the virt_lines layer by
-- the caller via `hl`, not encoded in the string itself.
local function _build_rows(width_cells, height_cells)
  local diac = diacritics()
  local rows = {}
  for r = 1, height_cells do
    local cells = {}
    for c = 1, width_cells do
      cells[#cells + 1] = PLACEHOLDER .. diac[r] .. diac[c]
    end
    rows[#rows + 1] = table.concat(cells)
  end
  return rows
end

-- Compute the target placeholder grid size (width_cells, height_cells)
-- for an image with pixel dimensions (w_px, h_px). Mirrors image.lua's
-- compute_dimensions math so the rendered grid lands at exactly the
-- same number of cell rows the old path was reserving — preserving
-- the layout users are accustomed to.
local function _compute_grid_size(w_px, h_px, available_cols)
  local cfg_out = (Cfg.get() and Cfg.get().output) or {}
  local cell_w_static = cfg_out.cell_width_px or 8
  local rt_w, rt_h = _runtime_cell_size()
  local cell_w_runtime = rt_w or cell_w_static
  local cell_h_runtime = rt_h or cfg_out.cell_height_px or 16
  -- SPEC I1: width derived from static 8 px/cell.
  local natural_cols = math.max(1, math.ceil(w_px / cell_w_static))
  local width_cells = math.max(1, math.min(available_cols, natural_cols))
  -- SPEC I14: height derived from runtime cell sizes.
  local target_w_px = width_cells * cell_w_runtime
  local scaled_h_px = h_px * (target_w_px / w_px)
  local height_cells = math.max(1, math.ceil(scaled_h_px / cell_h_runtime))
  local max_rows = cfg_out.image_max_height_rows or 40
  height_cells = math.min(height_cells, max_rows)
  -- Diacritic-table cap — kitty can't address beyond #diac rows/cols.
  local diac_max = #diacritics()
  width_cells = math.min(width_cells, diac_max)
  height_cells = math.min(height_cells, diac_max)
  return width_cells, height_cells
end

-- ---------- transmit cache ----------

-- Cache keyed by image file path. Value: entry table with id, grid
-- size, pre-built placeholder rows, and the snacks.Image reference
-- (kept alive so snacks doesn't garbage-collect or re-transmit).
--
-- Mercury's image extraction already content-addresses paths via the
-- sha256 hash of the image bytes (output.lua's IMAGE_CACHE_DIR layout),
-- so two cells producing the same plot share a cache entry naturally.
local _cache = {}

-- Transmit an image to kitty and return its placeholder descriptor.
-- Returns nil if snacks isn't available, the file can't be read, or
-- the dimensions can't be determined.
--
-- opts:
--   available_cols: int — upper bound for width_cells. Required.
--   width_px, height_px: int? — pre-computed dimensions. If absent,
--     the function reads the file and re-derives them. Mercury's UI
--     path always has these in hand (image.lua's compute_dimensions
--     reads PNG metadata once per render), so passing them avoids a
--     redundant disk read.
function M.transmit(path, opts)
  opts = opts or {}
  if type(path) ~= "string" or path == "" then return nil end
  if not M.available() then return nil end

  local entry = _cache[path]
  if entry then return entry end

  local img_mod = _snacks_image()
  if not img_mod then return nil end

  -- Pixel dimensions: from opts when caller already has them
  -- (Mercury's UI flow does — see image.lua's compute_dimensions),
  -- otherwise read the file's bytes once.
  local w_px, h_px = opts.width_px, opts.height_px
  if not w_px or not h_px then
    local bytes = Util.read_file(path)
    if not bytes then return nil end
    local Output = require("mercury.output")
    -- Dispatch by extension; matches what extract_images stored.
    local ext = path:sub(-4):lower()
    local kind = "png"
    if ext == ".jpg" or ext == "jpeg" then kind = "jpeg"
    elseif ext == ".svg" then kind = "svg" end
    w_px, h_px = Output.image_dimensions(kind, bytes)
    if not w_px or not h_px then return nil end
  end

  -- Initiate transmission via snacks. snacks.image.image.new(path) is
  -- idempotent per file (its internal `images` cache dedupes by
  -- file path), so calling it multiple times in a session for the same
  -- path returns the same Image with the same id.
  local img
  local ok = pcall(function() img = img_mod.new(path) end)
  if not ok or not img or not img.id then return nil end

  local available_cols = opts.available_cols or 80
  local width_cells, height_cells = _compute_grid_size(w_px, h_px, available_cols)
  local rows = _build_rows(width_cells, height_cells)
  local hl = _ensure_hl(img.id)

  entry = {
    id = img.id,
    width_cells = width_cells,
    height_cells = height_cells,
    rows = rows,
    hl = hl,
    snacks_img = img,   -- retain so snacks doesn't drop the transmit
    path = path,
  }
  _cache[path] = entry

  -- CRITICAL: snacks's image:new() runs `magick identify` ASYNC even
  -- for already-PNG files (Snacks/image/convert.lua's Convert:resolve
  -- always appends an identify step). That means img.sent stays false
  -- until magick finishes; if we return now and nvim draws our
  -- placeholders before send() completes, kitty sees placeholder
  -- cells whose fg color encodes an image_id it doesn't have yet —
  -- nothing renders. By the time send() finally completes, nvim has
  -- already drawn the screen and won't re-emit the placeholders
  -- unless something triggers a redraw.
  --
  -- Two-pronged fix:
  --   (a) Wait briefly (up to ~250ms) for img.sent to flip true.
  --       Matplotlib plots are small (sub-MB) and magick identify is
  --       fast; most of the time this is well under the timeout.
  --   (b) ALSO register a fake placement so snacks's on_send callback
  --       fires when transmission completes — schedules a redraw so
  --       the placeholders re-emit to kitty even if (a) timed out
  --       (e.g., magick not installed, large image, slow disk).
  if not img.sent then
    -- (a) Bounded sync wait. 250 ms is a balance between not
    -- blocking the UI noticeably and giving magick identify time to
    -- finish for typical matplotlib output.
    pcall(function()
      vim.wait(250, function() return img.sent == true end, 10)
    end)
    -- (b) Async safety net: even if the wait timed out, register an
    -- on-send hook so kitty gets the placeholders re-emitted once
    -- transmission completes. We mimic snacks's placement protocol
    -- by `place()`-ing a stub object whose `update()` triggers a
    -- redraw — snacks's on_send iterates placements and calls
    -- update on each.
    if not img.sent and type(img.place) == "function" then
      local stub_placement = {
        update = function(_self)
          vim.schedule(function() pcall(vim.cmd, "redraw!") end)
        end,
        error = function() end,
        close = function() end,
      }
      pcall(function() img:place(stub_placement) end)
    end
  end

  return entry
end

-- Drop a single cached image and ask kitty to delete its placement.
-- Called when Mercury determines a cell no longer references the image
-- (output cleared, cell deleted, re-execution produced different
-- pixels with a different hash).
function M.cleanup(path)
  local entry = _cache[path]
  if not entry then return end
  local img = entry.snacks_img
  if img and type(img.del) == "function" then
    pcall(function() img:del() end)
  end
  _cache[path] = nil
end

-- Drop everything. Used on full Mercury teardown.
function M.cleanup_all()
  for path, _ in pairs(_cache) do M.cleanup(path) end
end

-- Diagnostic snapshot for :NotebookDebugImages. Returns a table with
-- everything we can probe about the placeholder rendering path. Read
-- by init.lua's command to print a user-facing report.
function M.diagnose()
  local report = {}
  local snacks_ok = pcall(require, "snacks")
  report.snacks_loaded = snacks_ok and _G.Snacks ~= nil
  report.snacks_image_module = _snacks_image() ~= nil
  report.termguicolors = vim.o.termguicolors
  report.setup_called = _setup_done

  local term = _snacks_terminal()
  if term and type(term.env) == "function" then
    local ok, env = pcall(term.env)
    if ok and type(env) == "table" then
      report.env_name = env.name
      report.env_supported = env.supported
      report.env_placeholders = env.placeholders
      report.env_remote = env.remote
    end
  end

  report.available = M.available()

  local cache_entries = {}
  for path, entry in pairs(_cache) do
    cache_entries[#cache_entries + 1] = {
      path = path,
      id = entry.id,
      width_cells = entry.width_cells,
      height_cells = entry.height_cells,
      hl = entry.hl,
    }
  end
  report.cache = cache_entries

  return report
end

-- Test/debug helpers — not part of the public API but exposed so tests
-- can verify the registered highlight name and inspect the cache.
M._placeholder = PLACEHOLDER
M._diacritics = diacritics
M._cache = _cache

return M
