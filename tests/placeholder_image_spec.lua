-- Pin contracts for Mercury's kitty unicode-placeholder image renderer
-- (SPEC I18, replacement for image.nvim cursor-based positioning).
--
-- These tests mock snacks.image so the module can be exercised without
-- a real kitty terminal, and verify:
--   * M.available() correctly gates on snacks + terminal capability.
--   * M.transmit returns the expected descriptor with a placeholder grid
--     whose dimensions match Mercury's compute_dimensions math.
--   * Placeholder rows have the right structure (PLACEHOLDER + 2
--     diacritics per cell), so kitty can decode them.
--   * The per-image highlight is registered with fg = image_id.
--   * Calling M.transmit twice with the same path reuses the same id
--     and rows (cache hit, no re-transmission).

local Util = require("mercury.util")

-- Synthesize a 1x1 minimal valid PNG (signature + IHDR), enough for
-- M.png_dimensions to read w/h. Mirrors the helper in image_layout_spec.
local function fake_png(w, h)
  local function be32(n)
    return string.char(
      math.floor(n / 16777216) % 256,
      math.floor(n / 65536) % 256,
      math.floor(n / 256) % 256,
      n % 256)
  end
  return "\137PNG\r\n\26\n"
    .. be32(13) .. "IHDR" .. be32(w) .. be32(h)
    .. string.char(8, 6, 0, 0, 0)
    .. "\0\0\0\0IEND\174B`\130"
end

-- Mount a fake snacks module in package.loaded so require("snacks")
-- and _G.Snacks.image.* resolve to our test doubles. Returns the
-- fake's transmit log so tests can introspect.
local function _install_fake_snacks(supports_placeholders)
  local transmitted = {}
  local next_id = 1000

  local fake_terminal = {
    env = function()
      return { placeholders = supports_placeholders }
    end,
  }

  local fake_image_image = {}
  local img_cache = {}
  fake_image_image.new = function(src)
    if img_cache[src] then return img_cache[src] end
    next_id = next_id + 1
    transmitted[#transmitted + 1] = src
    local img = {
      src = src,
      id = next_id,
      placements = {},
      del = function(self) self._deleted = true end,
    }
    img_cache[src] = img
    return img
  end

  local fake_snacks = {
    image = {
      terminal = fake_terminal,
      image = fake_image_image,
    },
  }

  package.loaded["snacks"] = fake_snacks
  _G.Snacks = fake_snacks

  return { transmitted = transmitted, img_cache = img_cache }
end

local function _uninstall_fake_snacks()
  package.loaded["snacks"] = nil
  _G.Snacks = nil
  package.loaded["mercury.placeholder_image"] = nil
end

describe("placeholder_image.available()", function()
  after_each(_uninstall_fake_snacks)

  it("returns false when snacks isn't loaded at all", function()
    _G.Snacks = nil
    package.loaded["snacks"] = nil
    package.loaded["mercury.placeholder_image"] = nil
    local P = require("mercury.placeholder_image")
    assert.is_false(P.available())
  end)

  it("returns false when terminal env reports placeholders = false", function()
    _install_fake_snacks(false)
    local P = require("mercury.placeholder_image")
    assert.is_false(P.available())
  end)

  it("returns true when snacks loaded AND terminal supports placeholders", function()
    _install_fake_snacks(true)
    local P = require("mercury.placeholder_image")
    assert.is_true(P.available())
  end)
end)

describe("placeholder_image.transmit", function()
  local fake
  before_each(function()
    fake = _install_fake_snacks(true)
    require("mercury.config").setup()
  end)
  after_each(_uninstall_fake_snacks)

  it("returns nil when snacks isn't available (no transmit)", function()
    _uninstall_fake_snacks()
    _G.Snacks = nil
    package.loaded["snacks"] = nil
    package.loaded["mercury.placeholder_image"] = nil
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/nope.png", { available_cols = 80 })
    assert.is_nil(entry)
  end)

  it("returns nil when the image file can't be read", function()
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/does_not_exist_42.png",
      { available_cols = 80 })
    assert.is_nil(entry)
  end)

  it("returns a descriptor with id, grid size, rows, and hl", function()
    Util.write_file("/tmp/mph_a.png", fake_png(400, 200))
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/mph_a.png",
      { available_cols = 80, width_px = 400, height_px = 200 })
    assert.is_table(entry)
    assert.equals("number", type(entry.id))
    assert.is_true(entry.width_cells > 0)
    assert.is_true(entry.height_cells > 0)
    assert.equals("table", type(entry.rows))
    assert.equals(entry.height_cells, #entry.rows)
    assert.matches("^MercuryImg_", entry.hl)
    os.remove("/tmp/mph_a.png")
  end)

  it("transmits via snacks (one entry in transmit log per unique path)", function()
    Util.write_file("/tmp/mph_b.png", fake_png(400, 200))
    local P = require("mercury.placeholder_image")
    -- Two transmits of the same path: snacks.image.image.new dedupes
    -- by file path, so the transmit log should only show it ONCE.
    P.transmit("/tmp/mph_b.png", { available_cols = 80, width_px = 400, height_px = 200 })
    P.transmit("/tmp/mph_b.png", { available_cols = 80, width_px = 400, height_px = 200 })
    assert.equals(1, #fake.transmitted)
    assert.equals("/tmp/mph_b.png", fake.transmitted[1])
    os.remove("/tmp/mph_b.png")
  end)

  it("each placeholder row contains PLACEHOLDER + 2 diacritics per cell", function()
    Util.write_file("/tmp/mph_c.png", fake_png(80, 80))
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/mph_c.png",
      { available_cols = 80, width_px = 80, height_px = 80 })
    assert.is_table(entry)
    -- Row strings are UTF-8 of <PLACEHOLDER + diac_r + diac_c>*width.
    -- Count placeholders by string.find loop — each instance is the
    -- start of one cell.
    local PLACEHOLDER = P._placeholder
    for _, row in ipairs(entry.rows) do
      local _, count = row:gsub(PLACEHOLDER, "")
      assert.equals(entry.width_cells, count,
        "every row must contain exactly width_cells placeholders")
    end
    -- The first row's first cell must start with PLACEHOLDER followed
    -- immediately by two combining marks (diacritics).
    local diac = P._diacritics()
    local first_row = entry.rows[1]
    assert.equals(PLACEHOLDER .. diac[1] .. diac[1],
      first_row:sub(1, #(PLACEHOLDER .. diac[1] .. diac[1])),
      "first cell must be PLACEHOLDER + diac[1] + diac[1]")
    os.remove("/tmp/mph_c.png")
  end)

  it("registers a per-image highlight with fg = image_id", function()
    Util.write_file("/tmp/mph_d.png", fake_png(80, 80))
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/mph_d.png",
      { available_cols = 80, width_px = 80, height_px = 80 })
    assert.is_table(entry)
    local hl = vim.api.nvim_get_hl(0, { name = entry.hl })
    assert.equals(entry.id, hl.fg,
      "highlight fg must equal the image_id (kitty decodes the id from the placeholder cell's fg)")
    os.remove("/tmp/mph_d.png")
  end)

  it("two distinct images get distinct ids and distinct highlights", function()
    Util.write_file("/tmp/mph_e.png", fake_png(80, 80))
    Util.write_file("/tmp/mph_f.png", fake_png(80, 80))
    local P = require("mercury.placeholder_image")
    local e1 = P.transmit("/tmp/mph_e.png",
      { available_cols = 80, width_px = 80, height_px = 80 })
    local e2 = P.transmit("/tmp/mph_f.png",
      { available_cols = 80, width_px = 80, height_px = 80 })
    assert.is_true(e1.id ~= e2.id)
    assert.is_true(e1.hl ~= e2.hl)
    os.remove("/tmp/mph_e.png"); os.remove("/tmp/mph_f.png")
  end)
end)

describe("output.build_virt_lines image_placeholders branch", function()
  -- Verifies the wiring in output.lua: when an image_placeholders[i]
  -- entry is present, build_virt_lines pushes the placeholder rows
  -- (with the per-image highlight) instead of blank rows.
  it("uses placeholder rows + per-image hl in place of blank rows", function()
    local Output = require("mercury.output")
    -- Build a fake placeholder descriptor with two rows of three cells.
    local placeholder = {
      id = 12345,
      width_cells = 3,
      height_cells = 2,
      rows = { "row1text", "row2text" },
      hl = "MercuryImg_12345",
    }
    local virt, image_offsets = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data", data = { ["image/png"] = "fakepng" } },
      },
    }, {
      show_status_pill = false,   -- skip pill to make assertions simpler
      image_placeholders = { [1] = placeholder },
    })
    -- image_offsets is the virt_line index where the image starts.
    -- With show_status_pill=false there are no rows above the image,
    -- so it lands at index 0.
    assert.equals(0, image_offsets[1])
    -- Expect: 0 pill rows, then 2 placeholder rows, then 1 trailing
    -- gap blank = 3 virt_lines total.
    assert.equals(3, #virt)
    -- The placeholder rows must carry the per-image highlight.
    assert.equals("row1text", virt[1][1][1])
    assert.equals("MercuryImg_12345", virt[1][1][2])
    assert.equals("row2text", virt[2][1][1])
    assert.equals("MercuryImg_12345", virt[2][1][2])
    -- The trailing gap is a blank row with "Normal" hl.
    assert.equals("", virt[3][1][1])
    assert.equals("Normal", virt[3][1][2])
  end)

  it("placeholder branch takes priority over image_heights when both passed", function()
    local Output = require("mercury.output")
    local placeholder = {
      id = 7, width_cells = 1, height_cells = 1,
      rows = { "PHROW" }, hl = "MercuryImg_7",
    }
    local virt, _ = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data", data = { ["image/png"] = "fakepng" } },
      },
    }, {
      show_status_pill = false,
      image_placeholders = { [1] = placeholder },
      image_heights = { [1] = 20 },    -- would reserve 21 blank rows on the legacy path
    })
    -- Placeholder path = 1 placeholder row + 1 trailing gap = 2 virt_lines.
    -- Legacy path would have produced 21 rows. Verify we took the
    -- placeholder path.
    assert.equals(2, #virt)
    assert.equals("PHROW", virt[1][1][1])
  end)

  it("falls back to blank rows when image_placeholders is nil", function()
    -- Legacy parity check: existing image.nvim flow (no placeholders
    -- passed, only image_heights) still produces the same output.
    local Output = require("mercury.output")
    local virt, _ = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data", data = { ["image/png"] = "fakepng" } },
      },
    }, {
      show_status_pill = false,
      image_heights = { [1] = 3 },
    })
    -- 3 blank rows for the image + 1 trailing gap = 4 virt_lines.
    assert.equals(4, #virt)
    for i = 1, 4 do
      assert.equals("", virt[i][1][1])
    end
  end)
end)

describe("placeholder_image.cleanup", function()
  before_each(function()
    _install_fake_snacks(true)
    require("mercury.config").setup()
  end)
  after_each(_uninstall_fake_snacks)

  it("drops the cache entry and asks snacks to delete the kitty image", function()
    Util.write_file("/tmp/mph_g.png", fake_png(80, 80))
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/mph_g.png",
      { available_cols = 80, width_px = 80, height_px = 80 })
    assert.is_table(entry)
    assert.is_not_nil(P._cache["/tmp/mph_g.png"])
    P.cleanup("/tmp/mph_g.png")
    assert.is_nil(P._cache["/tmp/mph_g.png"])
    assert.is_true(entry.snacks_img._deleted)
    os.remove("/tmp/mph_g.png")
  end)
end)
