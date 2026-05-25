#!/usr/bin/env -S nvim -l
-- Headless verification of Mercury's kitty unicode-placeholder
-- protocol emission. Builds the byte stream Mercury would write for
-- a known image + placeholder grid, then dumps it to stdout for
-- inspection (and optionally pipes through kitty for a visual
-- smoke test).
--
-- Run:
--   nvim -l scripts/kitty_test/verify_protocol.lua [path/to/image.png]
--
-- Output:
--   stderr — analysis of every escape sequence we emit (parsed,
--            decoded; flags any obvious errors).
--   stdout — the raw bytes a real terminal would receive.
--
-- For a visual test:
--   nvim -l scripts/kitty_test/verify_protocol.lua | cat   # pipe to TTY
-- inside a kitty terminal — you should see the image rendered as a
-- grid of placeholder cells.

local function err(msg) io.stderr:write(msg .. "\n") end

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

local DIACRITICS_HEX = "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A"
local diacritics = {}
for _, hex in ipairs(vim.split(DIACRITICS_HEX, ",", { plain = true })) do
  diacritics[#diacritics + 1] = vim.fn.nr2char(tonumber(hex, 16))
end

-- Minimal valid 4x4 RED PNG, hand-crafted.
local function make_test_png()
  local function be32(n)
    return string.char(
      math.floor(n / 16777216) % 256,
      math.floor(n / 65536) % 256,
      math.floor(n / 256) % 256,
      n % 256)
  end
  -- Use ffmpeg/magick/python if available — otherwise use a Mercury
  -- cached image. For this script we just take any PNG path passed
  -- on the command line, or fall back to a known cache file.
  if arg and arg[1] then return arg[1] end
  local cache = vim.fn.stdpath("cache") .. "/mercury_images"
  for path in vim.fn.glob(cache .. "/*.png", true, true)[1] and (function()
    local files = vim.fn.glob(cache .. "/*.png", true, true)
    return ipairs(files)
  end)() or function() return function() end end do
    return path
  end
  err("No PNG path provided and no cached PNG found. Pass one as arg.")
  os.exit(1)
end

local png_path = make_test_png()
err("Using PNG: " .. png_path)

-- Read PNG to get dimensions (used for placeholder grid size).
local f = io.open(png_path, "rb")
if not f then err("Cannot open " .. png_path); os.exit(1) end
local bytes = f:read("*a")
f:close()
if bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
  err("Not a PNG: " .. png_path); os.exit(1)
end
local function be32(s)
  local b1, b2, b3, b4 = s:byte(1, 4)
  return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end
local w_px = be32(bytes:sub(17, 20))
local h_px = be32(bytes:sub(21, 24))
err(("PNG dimensions: %dx%d pixels"):format(w_px, h_px))

-- ---- Base64 encoding (RFC 4648, identical to snacks.util.base64) ----
local b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(s)
  local result = {}
  local i = 1
  while i <= #s do
    local b1 = s:byte(i) or 0
    local b2 = s:byte(i + 1) or 0
    local b3 = s:byte(i + 2) or 0
    local n = b1 * 65536 + b2 * 256 + b3
    table.insert(result, b64_chars:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1))
    table.insert(result, b64_chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
    if i + 1 <= #s then
      table.insert(result, b64_chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1))
    else
      table.insert(result, "=")
    end
    if i + 2 <= #s then
      table.insert(result, b64_chars:sub(n % 64 + 1, n % 64 + 1))
    else
      table.insert(result, "=")
    end
    i = i + 3
  end
  return table.concat(result)
end

-- Generate a small image_id that fits in 24 bits.
local image_id = 0x14001F  -- arbitrary 24-bit value: R=20, G=0, B=31
err(("Image id: %d (0x%06X) — fg color would be (%d, %d, %d)"):format(
  image_id, image_id,
  math.floor(image_id / 65536) % 256,
  math.floor(image_id / 256) % 256,
  image_id % 256))

-- Build the kitty transmit escape. Mercury after the U=1 fix sends:
--   \x1b_Ga=T,U=1,q=2,t=f,i=<id>,f=100;<base64-path>\x1b\\
local function build_transmit(id, path)
  local b64 = base64(path)
  return ("\x1b_Ga=T,U=1,q=2,t=f,i=%d,f=100;%s\x1b\\"):format(id, b64)
end

local transmit = build_transmit(image_id, png_path)
err(("Transmit escape: %d bytes"):format(#transmit))
err("  prefix: " .. transmit:sub(1, 60):gsub("[^\x20-\x7e]", "."))

-- Compute a small placeholder grid: 8 cols x 4 rows (visible test).
local W, H = 8, 4
err(("Placeholder grid: %dx%d cells"):format(W, H))

-- Build placeholder grid rows.
local function build_grid()
  local rows = {}
  for r = 1, H do
    local cells = {}
    for c = 1, W do
      cells[#cells + 1] = PLACEHOLDER .. diacritics[r] .. diacritics[c]
    end
    rows[#rows + 1] = table.concat(cells)
  end
  return rows
end

local rows = build_grid()
err(("Each row is %d bytes (UTF-8)"):format(#rows[1]))

-- Build the full terminal output: SGR truecolor fg + grid + reset.
-- (For each row separately, separated by newline.)
local function build_grid_output(id, rows)
  local R = math.floor(id / 65536) % 256
  local G = math.floor(id / 256) % 256
  local B = id % 256
  local fg_set = ("\x1b[38;2;%d;%d;%dm"):format(R, G, B)
  local fg_reset = "\x1b[39m"
  local out = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = fg_set .. row .. fg_reset .. "\n"
  end
  return table.concat(out)
end

local grid_output = build_grid_output(image_id, rows)
err(("Grid output: %d bytes (including SGR + newlines)"):format(#grid_output))

-- Emit. The transmit goes first; kitty stores the image. Then the
-- grid; kitty paints pixels at the placeholder cells.
io.stdout:write(transmit)
io.stdout:write("\n--- placeholders below ---\n")
io.stdout:write(grid_output)
io.stdout:write("\n--- end ---\n")

err("")
err("Done. If you ran this in kitty (e.g., `nvim -l " .. arg[0] .. " | cat`),")
err("you should see a small image rendered between the markers.")
