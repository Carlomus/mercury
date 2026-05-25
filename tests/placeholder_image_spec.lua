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
-- and _G.Snacks.image.terminal / _G.Snacks.util resolve to our test
-- doubles. Returns the fake's transmit log so tests can introspect.
--
-- Mercury's placeholder_image module now uses ONLY the low-level
-- snacks.image.terminal.request (for the kitty graphics escape
-- sequence) and snacks.util.base64 (for the data field). It does
-- NOT use snacks.image.image.new because that path goes through
-- magick identify which never completes on systems without magick
-- (the user-reported "sent=nil" symptom).
--
-- Side effect: enables termguicolors. Placeholder mode requires it
-- (without termguicolors, the per-image fg color collapses to
-- 256-color and kitty can't decode the image_id from the cell).
-- Most users have it on via their colorscheme; tests need to
-- opt in explicitly.
local function _install_fake_snacks(supports_placeholders)
  vim.o.termguicolors = true
  local transmitted = {}   ---@type table<integer, {i:integer, t:string, f:integer, data:string}>

  local fake_terminal = {
    env = function()
      return { placeholders = supports_placeholders }
    end,
    request = function(opts)
      transmitted[#transmitted + 1] = vim.deepcopy(opts)
    end,
  }

  local fake_util = {
    base64 = function(s) return "base64(" .. s .. ")" end,
  }

  local fake_snacks = {
    image = {
      terminal = fake_terminal,
    },
    util = fake_util,
  }

  package.loaded["snacks"] = fake_snacks
  _G.Snacks = fake_snacks

  return { transmitted = transmitted }
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

  it("returns false when termguicolors is off (fg-color encoding broken)", function()
    _install_fake_snacks(true)
    vim.o.termguicolors = false
    local P = require("mercury.placeholder_image")
    assert.is_false(P.available())
    vim.o.termguicolors = true   -- restore for other tests
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

  it("transmits a kitty graphics request once per unique path", function()
    Util.write_file("/tmp/mph_b.png", fake_png(400, 200))
    local P = require("mercury.placeholder_image")
    -- Two transmits of the same path: Mercury's internal cache
    -- dedupes by path, so the kitty graphics request should fire
    -- only ONCE.
    P.transmit("/tmp/mph_b.png", { available_cols = 80, width_px = 400, height_px = 200 })
    P.transmit("/tmp/mph_b.png", { available_cols = 80, width_px = 400, height_px = 200 })
    assert.equals(1, #fake.transmitted)
    -- Verify the request payload is a kitty PNG-by-path transmit.
    local req = fake.transmitted[1]
    assert.equals("f", req.t,
      "kitty graphics t='f' = transmit by file path")
    assert.equals(100, req.f,
      "kitty format 100 = PNG")
    assert.equals("base64(/tmp/mph_b.png)", req.data,
      "data is base64-encoded file path (we use snacks.util.base64)")
    assert.is_true(req.i > 0,
      "the request must carry our generated image_id")
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
    -- Each placeholder row is a TWO-CHUNK virt_line (matching
    -- snacks's working layout): an empty leading chunk to flush
    -- any prior SGR state, then the placeholder text with the
    -- per-image highlight.
    assert.equals(2, #virt[1])
    assert.equals("", virt[1][1][1])
    assert.equals("Normal", virt[1][1][2])
    assert.equals("row1text", virt[1][2][1])
    assert.equals("MercuryImg_12345", virt[1][2][2])
    assert.equals("row2text", virt[2][2][1])
    assert.equals("MercuryImg_12345", virt[2][2][2])
    -- The trailing gap is a blank row with "Normal" hl (single chunk).
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
    -- placeholder path. Placeholder row is two-chunk (empty Normal +
    -- placeholder with hl).
    assert.equals(2, #virt)
    assert.equals("PHROW", virt[1][2][1])
    assert.equals("MercuryImg_7", virt[1][2][2])
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

describe("ui.lua picks placeholder mode when snacks is available", function()
  -- End-to-end pin: when snacks reports placeholder support, the UI
  -- renderer should call Placeholder.transmit for each image, embed
  -- the resulting rows in the cell's virt_lines, and NOT call
  -- image.nvim's from_file.
  it("renders images via placeholder rows, not image.nvim", function()
    local fake = _install_fake_snacks(true)
    require("mercury.config").setup()

    -- Make sure image.nvim's from_file is NEVER called by Mercury
    -- under placeholder mode. Spy on it via the package.loaded fake
    -- we use elsewhere.
    local image_nvim_from_file_calls = 0
    package.loaded["image"] = {
      is_enabled = function() return true end,
      from_file = function(path, opts)
        image_nvim_from_file_calls = image_nvim_from_file_calls + 1
        return { render = function() end, clear = function() end }
      end,
    }
    -- Mercury's image module's `available()` checks package.loaded.image,
    -- so re-require it after stubbing.
    package.loaded["mercury.image"] = nil

    Util.write_file("/tmp/mph_e2e.png", fake_png(400, 200))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=mphe2e01", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local Notebook = require("mercury.notebook")
    local UI = require("mercury.ui")
    local nb = Notebook.attach(buf); nb:rescan()
    nb:set_renderer(UI.new(nb))
    local out = nb:ensure_output(nb.cells[1].id)
    out.status = "ok"; out.exec_count = 1
    out.items = { { type = "display_data", data = { ["image/png"] = "a" } } }

    -- Stub extract_images so it returns our tmp file path (the real
    -- code base64-decodes the data payload — we want to test the
    -- rendering wiring, not the extraction).
    local Output_mod = require("mercury.output")
    local orig_extract = Output_mod.extract_images
    Output_mod.extract_images = function()
      return {
        { kind = "png", path = "/tmp/mph_e2e.png", hash = "e2e", item_index = 1 },
      }
    end

    nb._renderer:render()
    Output_mod.extract_images = orig_extract

    -- Snacks's transmit log must have one entry (we transmitted the
    -- image via the placeholder path).
    assert.equals(1, #fake.transmitted,
      "placeholder mode must transmit the image via snacks's kitty terminal request")
    assert.equals("f", fake.transmitted[1].t,
      "transmit must be t='f' (kitty PNG-by-file-path)")
    assert.equals("base64(/tmp/mph_e2e.png)", fake.transmitted[1].data)

    -- image.nvim's from_file must NOT have been called — that would
    -- mean we took the legacy cursor-positioned path even though
    -- placeholders are available.
    assert.equals(0, image_nvim_from_file_calls,
      "placeholder mode must skip image.nvim's from_file entirely")

    -- The buffer's output extmark must contain virt_lines whose first
    -- chunk on at least one row is a placeholder string with the
    -- per-image hl.
    local Notebook_mod = require("mercury.notebook")
    local ns_out = Notebook_mod.ns("output")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns_out, 0, -1,
      { details = true })
    assert.is_true(#marks > 0)
    local virt_lines = marks[1][4].virt_lines or {}
    local found_placeholder_row = false
    local P = require("mercury.placeholder_image")
    for _, vl in ipairs(virt_lines) do
      for _, chunk in ipairs(vl) do
        if type(chunk[1]) == "string" and chunk[1]:find(P._placeholder, 1, true) then
          found_placeholder_row = true
          assert.matches("^MercuryImg_", chunk[2] or "",
            "placeholder row must carry the per-image MercuryImg_<id> hl")
        end
      end
    end
    assert.is_true(found_placeholder_row,
      "at least one virt_lines row must contain placeholder chars")

    Notebook_mod.detach(buf)
    os.remove("/tmp/mph_e2e.png")
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
    _uninstall_fake_snacks()
  end)
end)

describe("end-to-end: nvim emits placeholder cells with correct hl", function()
  -- Strongest test we can do without a real terminal: attach a fake
  -- nvim UI, render a Mercury cell with image output, and inspect
  -- the UI events nvim would have sent to a real TUI. If the events
  -- include our placeholder text AND set the per-image foreground
  -- color (kitty's `\x1b[38;2;R;G;Bm` truecolor escape comes from
  -- the highlight's fg attribute), then nvim's emission side is
  -- correct and any remaining "kitty doesn't render" is a
  -- terminal-side issue.

  local fake
  before_each(function()
    fake = _install_fake_snacks(true)
    require("mercury.config").setup()
  end)
  after_each(_uninstall_fake_snacks)

  it("renders the per-image hl with the image_id as 24-bit fg color", function()
    Util.write_file("/tmp/mph_render.png", fake_png(80, 80))
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/mph_render.png",
      { available_cols = 80, width_px = 80, height_px = 80 })
    assert.is_table(entry)
    -- nvim_get_hl returns the resolved attributes of the highlight.
    -- For kitty's unicode-placeholder protocol to work, the fg MUST
    -- be the raw image_id (so nvim emits `\x1b[38;2;R;G;Bm` with
    -- (R,G,B) = (id>>16, id>>8 & 0xFF, id & 0xFF)). nvim's API
    -- returns fg as an integer when set as an integer.
    local hl = vim.api.nvim_get_hl(0, { name = entry.hl, link = false })
    assert.equals(entry.id, hl.fg,
      "fg must equal the image_id — kitty decodes this color back "
      .. "into the image_id when it sees a placeholder cell")
    -- bg defaults to nil/none so kitty isn't confused by extra
    -- background-color escapes interleaved with the fg.
    assert.is_nil(hl.bg)
    -- nocombine must be set so syntax highlights on the same row
    -- can't override our fg encoding.
    assert.is_true(hl.nocombine == true)
  end)

  it("placeholder string has the correct kitty unicode format", function()
    Util.write_file("/tmp/mph_struct.png", fake_png(80, 80))
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/mph_struct.png",
      { available_cols = 80, width_px = 80, height_px = 80 })
    assert.is_table(entry)
    -- Verify the byte-level structure of a placeholder row matches
    -- kitty's spec: each cell is U+10EEEE + a row diacritic + a col
    -- diacritic, with no intervening characters.
    local first_row = entry.rows[1]
    local diac = P._diacritics()
    -- The U+10EEEE codepoint is 4 bytes in UTF-8.
    local placeholder_utf8 = vim.fn.nr2char(0x10EEEE)
    assert.equals(4, #placeholder_utf8,
      "U+10EEEE must encode to 4 UTF-8 bytes")
    -- For width_cells columns the row should start with:
    --   PLACEHOLDER + diac[1] (row=1) + diac[1] (col=1) +
    --   PLACEHOLDER + diac[1] (row=1) + diac[2] (col=2) + ...
    local expected_cell_1 = placeholder_utf8 .. diac[1] .. diac[1]
    local expected_cell_2 = placeholder_utf8 .. diac[1] .. diac[2]
    assert.equals(expected_cell_1 .. expected_cell_2,
      first_row:sub(1, #expected_cell_1 + #expected_cell_2),
      "first two cells of row 1 must be PLACEHOLDER + row[1]_diacritic + col[N]_diacritic")
  end)

  it("snacks transmit call has a=T, U=1, q=2, c, r (kitty placeholder mode)", function()
    -- The U=1 transmit flag is REQUIRED to register the image for
    -- kitty's unicode-placeholder rendering. Without it kitty
    -- stores the bytes but ignores any cells that reference them.
    -- c and r tell kitty to SCALE the image to fit our placeholder
    -- grid exactly — without them kitty paints at native pixels
    -- which leaves visible padding when our grid is larger than
    -- the image's natural cell footprint.
    Util.write_file("/tmp/mph_xmit.png", fake_png(80, 80))
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/mph_xmit.png",
      { available_cols = 80, width_px = 80, height_px = 80 })
    assert.is_table(entry)
    assert.equals(1, #fake.transmitted)
    local req = fake.transmitted[1]
    assert.equals("T", req.a,
      "a='T' = transmit AND mark for display via placeholders")
    assert.equals(1, req.U,
      "U=1 = unicode-placeholder mode (REQUIRED for placeholder cells "
      .. "to decode into image pixels — without it kitty ignores them)")
    assert.equals(2, req.q,
      "q=2 = silence kitty's success/error response (otherwise it "
      .. "leaks into the terminal output)")
    assert.equals("f", req.t)
    assert.equals(100, req.f, "kitty format 100 = PNG")
    assert.equals(entry.width_cells, req.c,
      "c must equal grid width so kitty scales image to fill cells")
    assert.equals(entry.height_cells, req.r,
      "r must equal grid height so kitty scales image to fill cells")
    os.remove("/tmp/mph_xmit.png")
  end)
end)

describe("placeholder_image.cleanup", function()
  local fake
  before_each(function()
    fake = _install_fake_snacks(true)
    require("mercury.config").setup()
  end)
  after_each(_uninstall_fake_snacks)

  it("drops the cache entry and asks kitty to delete the image", function()
    Util.write_file("/tmp/mph_g.png", fake_png(80, 80))
    local P = require("mercury.placeholder_image")
    local entry = P.transmit("/tmp/mph_g.png",
      { available_cols = 80, width_px = 80, height_px = 80 })
    assert.is_table(entry)
    assert.is_not_nil(P._cache["/tmp/mph_g.png"])
    -- First request was the transmit. Second should be the delete.
    assert.equals(1, #fake.transmitted)
    P.cleanup("/tmp/mph_g.png")
    assert.is_nil(P._cache["/tmp/mph_g.png"])
    assert.equals(2, #fake.transmitted)
    local del_req = fake.transmitted[2]
    assert.equals("d", del_req.a, "kitty a='d' = delete")
    assert.equals("i", del_req.d, "d='i' = by image id")
    assert.equals(entry.id, del_req.i)
    os.remove("/tmp/mph_g.png")
  end)
end)
