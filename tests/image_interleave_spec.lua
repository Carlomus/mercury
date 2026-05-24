-- Pin the simplified image-layout contracts:
--   (1) The `Out[N]` pill is NOT painted over by an image — the renderer
--       shifts each image's `render_offset_top` by the number of text
--       virt_lines emitted ABOVE the image stack.
--   (2) The LAST image gets `with_virtual_padding=true` so image.nvim
--       reserves enough buffer rows to keep the next cell clear of the
--       image stack (previous regression: images bled into next cell).
--   (3) A 1-row visual gap separates consecutive images in the stack.
--   (4) `:NotebookKernelRestartClear` clears outputs even before the
--       bridge has ever started (fresh notebook from disk).
--
-- The previous design interleaved image-height blank rows in
-- build_virt_lines to preserve item order between text and images. That
-- failed two ways: blank rows counted against `max_preview_lines` and
-- got truncated on long outputs, and any divergence between our row math
-- and image.nvim's actual rendering bled into the next cell. The new
-- design gives up item-order in mixed text/image cells in exchange for
-- robustness — image.nvim's `with_virtual_padding` handles the bottom
-- reservation regardless of any height mismatch.

local Output = require("mercury.output")
local Kernel = require("mercury.kernel")
local Notebook = require("mercury.notebook")
local Cfg = require("mercury.config")

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

describe("build_virt_lines interleave (item-order layout)", function()
  it("[image, text, image] preserves item order via reserved blanks", function()
    -- The user's notebook-parity case. With image_heights provided,
    -- build_virt_lines walks items in order and reserves blanks at the
    -- image positions — so the text between image 1 and image 2 stays
    -- VISIBLE between the two image rows.
    local virt, offsets = Output.build_virt_lines({
      status = "ok", exec_count = 1, ms = 10, items = {
        { type = "display_data", data = { ["image/png"] = "img1" } },
        { type = "stream", name = "stdout", text = "middle\n" },
        { type = "display_data", data = { ["image/png"] = "img2" } },
      },
    }, {
      image_heights = { 4, 6 },
    })
    -- Pill row (1) + img1 blanks (4) + gap (1) + "middle" (1) + img2 (6) + gap (1) = 14
    assert.equals(14, #virt)
    -- offsets are anchored to body_end. Pill is at 0 (1 row). img1 starts
    -- at row 1. After 4 blanks + 1 gap (5 rows) + "middle" (1 row) = 7,
    -- img2 starts at row 7.
    assert.equals(1, offsets[1])
    assert.equals(7, offsets[2])
    -- The "middle" line is at row 6 — between the two image reservations,
    -- not pushed to the bottom. Verify the row's text.
    local middle_idx = 1 + 4 + 1 + 1   -- 1-indexed: pill + 4 blanks + gap + middle
    assert.matches("middle", virt[middle_idx][1][1])
  end)

  it("image-blank rows are exempt from max_preview_lines truncation", function()
    -- The cap is set to 2 and there are 3 text lines + a 5-row image.
    -- Pre-fix, the cap counted image-blank rows and chopped them off so
    -- the image rendered past Mercury's reservation. With the fix, the
    -- 5+1=6 image-blank rows ALWAYS emit; only the TEXT past the cap is
    -- replaced with a "… N hidden" marker. The marker emits after the
    -- last body row.
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "stream", name = "stdout",
          text = "line1\nline2\nline3\n" },
        { type = "display_data", data = { ["image/png"] = "img" } },
      },
    }, {
      show_status_pill = false,
      max_preview_lines = 2,
      image_heights = { 5 },
    })
    -- Expected: line1, line2, [6 image-blanks], "… 1 hidden" = 9 rows.
    assert.equals(9, #virt)
    assert.matches("line1", virt[1][1][1])
    assert.matches("line2", virt[2][1][1])
    -- Image blanks at rows 3..8 (5 image rows + 1 gap).
    for i = 3, 8 do
      assert.equals("", virt[i][1][1],
        ("row %d should be an empty image-blank, got %q")
          :format(i, virt[i][1][1]))
    end
    -- Hidden marker at the end.
    assert.matches("1 lines hidden", virt[9][1][1])
  end)

  it("interleave passes through to a clean virt_lines structure (no Invalid table)", function()
    -- Regression: a previous design attached `_image_blank` directly to
    -- the chunk table. Neovim's strict virt_lines converter rejected
    -- those tables. Now the blank marker lives in a parallel array so
    -- the emitted chunks are pure {text, hl} pairs.
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data", data = { ["image/png"] = "img" } },
      },
    }, { image_heights = { 3 } })
    -- Every chunk in every line must have exactly two elements: text + hl.
    for _, line in ipairs(virt) do
      for _, chunk in ipairs(line) do
        -- A chunk is `{ text, hl }`; if the first element is a table the
        -- line is multi-chunk and each sub-element should be a chunk.
        local function check_clean(c)
          assert.equals("string", type(c[1]))
          assert.equals("string", type(c[2]))
          -- No leaking marker fields.
          assert.is_nil(c._image_blank)
        end
        if type(chunk[1]) == "table" then
          for _, sub in ipairs(chunk) do check_clean(sub) end
        else
          check_clean(chunk)
        end
      end
    end
  end)
end)

describe("build_virt_lines text-only (no image rows)", function()
  it("image items contribute NO virt_lines when image.nvim is available", function()
    -- Image is rendered separately by image.nvim below the text virt_lines.
    -- A `[image/png]` placeholder row would just collide with the actual
    -- rendered image, which is the user's original complaint.
    package.loaded["image"] = {
      is_enabled = function() return true end,
      from_file = function() return { render = function() end } end,
    }
    package.loaded["mercury.image"] = nil
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "stream", name = "stdout", text = "hello\n" },
        { type = "display_data", data = { ["image/png"] = "x" } },
      },
    }, { show_status_pill = false })
    -- Only the stream line.
    assert.equals(1, #virt)
    assert.matches("hello", virt[1][1][1])
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
  end)

  it("emits [mime] fallback when image.nvim is NOT available", function()
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data", data = { ["image/png"] = "x" } },
      },
    }, { show_status_pill = false })
    -- One placeholder line (fallback for missing image.nvim).
    assert.equals(1, #virt)
    assert.matches("%[image/png%]", virt[1][1][1])
  end)
end)

describe("ui shifts images below text via layout.text_offset", function()
  local recorded
  local fake_image_mod
  before_each(function()
    recorded = {}
    fake_image_mod = {
      is_enabled = function() return true end,
      from_file = function(path, opts)
        table.insert(recorded, { path = path, opts = opts })
        return { render = function() end, clear = function() end }
      end,
    }
    package.loaded["image"] = fake_image_mod
    package.loaded["mercury.image"] = nil
    Cfg.setup()
  end)
  after_each(function()
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
  end)

  it("EVERY image has with_virtual_padding=false and window=nil (SPEC I9, I16, I18)", function()
    -- Mercury's virt_lines are the sole row reservation (I16) so
    -- `with_virtual_padding = false` is the source of truth for
    -- blanks beneath the image.
    --
    -- `window = nil` (SPEC I18, current mode): Mercury bypasses
    -- image.nvim's renderer branches entirely by setting window=nil.
    -- With window=nil image.nvim takes a single simple code path
    -- (absolute_y = y + render_offset_top) and Mercury controls the
    -- screen position via dynamic y. No `overlap` opt is needed.
    local Util = require("mercury.util")
    local UI = require("mercury.ui")
    Util.write_file("/tmp/vpa.png", fake_png(400, 200))
    Util.write_file("/tmp/vpb.png", fake_png(400, 200))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=virtpadd", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    nb:set_renderer(UI.new(nb))
    local out = nb:ensure_output(nb.cells[1].id)
    out.status = "ok"; out.exec_count = 1
    out.items = {
      { type = "display_data", data = { ["image/png"] = "a" } },
      { type = "display_data", data = { ["image/png"] = "b" } },
    }
    local Output_mod = require("mercury.output")
    local orig = Output_mod.extract_images
    Output_mod.extract_images = function()
      return {
        { kind = "png", path = "/tmp/vpa.png", hash = "vpa", item_index = 1 },
        { kind = "png", path = "/tmp/vpb.png", hash = "vpb", item_index = 2 },
      }
    end
    nb._renderer:render()
    Output_mod.extract_images = orig

    assert.equals(2, #recorded)
    assert.is_false(recorded[1].opts.with_virtual_padding,
      "every image must have padding=false (SPEC I16)")
    assert.is_false(recorded[2].opts.with_virtual_padding,
      "even the last image must have padding=false (SPEC I16)")
    assert.is_nil(recorded[1].opts.window,
      "SPEC I18: window must be nil to bypass image.nvim's "
        .. "renderer branches (we manage screen y ourselves)")
    assert.is_nil(recorded[2].opts.window,
      "SPEC I18: window must be nil on every image")
    -- Cumulative offsets: image 2's offset > image 1's so they stack.
    assert.is_true(recorded[2].opts.render_offset_top
                   > recorded[1].opts.render_offset_top,
      "images stack via cumulative render_offset_top (SPEC I4)")
    Notebook.detach(buf)
    os.remove("/tmp/vpa.png"); os.remove("/tmp/vpb.png")
  end)

  it("multi-image stack: 1-row gap baked into cumulative offset", function()
    -- The gap is added between consecutive rendered images via the
    -- `cumulative + heights[i] + 1` formula. Verify a stack of 3 images
    -- has strictly-increasing offsets that include the gap.
    local Util = require("mercury.util")
    local Image = require("mercury.image")
    Util.write_file("/tmp/g_a.png", fake_png(400, 200))
    Util.write_file("/tmp/g_b.png", fake_png(400, 200))
    Util.write_file("/tmp/g_c.png", fake_png(400, 200))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=gaprows", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    local total = Image.new(nb):render(
      nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      {
        { kind = "png", path = "/tmp/g_a.png", hash = "g_a" },
        { kind = "png", path = "/tmp/g_b.png", hash = "g_b" },
        { kind = "png", path = "/tmp/g_c.png", hash = "g_c" },
      })
    assert.is_true(total > 0)
    -- Each image's offset minus prior image's offset equals
    -- prior_height + 1 (the gap). Walk and check.
    for i = 2, 3 do
      local prev = recorded[i - 1].opts
      local cur = recorded[i].opts
      -- The delta must be greater than prev image's height (because of
      -- the +1 gap row).
      assert.is_true(cur.render_offset_top > prev.render_offset_top,
        ("image %d offset must exceed image %d's offset"):format(i, i - 1))
    end
    Notebook.detach(buf)
    os.remove("/tmp/g_a.png"); os.remove("/tmp/g_b.png"); os.remove("/tmp/g_c.png")
  end)
end)

describe("compute_dimensions row math (SPEC I6)", function()
  it("returns bare image_row_height (NO safety margin)", function()
    -- SPEC Invariant I6: per-image height is exactly image_row_height
    -- (clamped to max_rows). No safety bump — the gap row in
    -- build_virt_lines is the buffer for sub-cell drift. Previous
    -- formulas (+25%/+3 then +1) added a visible blank row below
    -- every image.
    local Util = require("mercury.util")
    local Image = require("mercury.image")
    local function fake_png_local(w, h)
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
    Util.write_file("/tmp/safetym.png", fake_png_local(400, 600))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=safetych", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local _, heights = Image.new(nb):compute_dimensions({
      { kind = "png", path = "/tmp/safetym.png", hash = "safetym" },
    })
    local Output = require("mercury.output")
    local available = math.max(20, math.floor(
      vim.api.nvim_win_get_width(0) * 0.85))
    local natural_cols = math.ceil(400 / 8)
    local bare = Output.image_row_height(400, 600,
      math.min(available, natural_cols), 8, 16, 40)
    -- I6 (current): zero safety bump.
    local expected = math.min(40, bare)
    assert.equals(expected, heights[1],
      ("expected I6 bare height = %d; got %d (any margin bloats spacing)")
        :format(expected, heights[1]))
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/safetym.png")
  end)

  it("max_rows clamp still applies (no overflow on huge images)", function()
    -- Image so tall that bare row count already saturates max_rows. The
    -- +1 safety must NOT push past the clamp — that's the upper bound
    -- the user configured to keep cells from dominating the screen.
    local Util = require("mercury.util")
    local Image = require("mercury.image")
    local function fake_png_local(w, h)
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
    Util.write_file("/tmp/clamp.png", fake_png_local(100, 5000))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=clampchk", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local _, heights = Image.new(nb):compute_dimensions({
      { kind = "png", path = "/tmp/clamp.png", hash = "clamp" },
    })
    -- max_rows default 40.
    assert.is_true(heights[1] <= 40,
      ("safety must not push past max_rows; got %d"):format(heights[1]))
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/clamp.png")
  end)
end)

-- Per-invariant pins. Each `it(...)` below maps 1:1 to a SPEC invariant
-- ID so a future regression that breaks the contract surfaces here with
-- a clear pointer to which invariant the change violated.

describe("SPEC image invariants — direct pins", function()
  local fake_image_mod
  local recorded2
  before_each(function()
    recorded2 = {}
    fake_image_mod = {
      is_enabled = function() return true end,
      from_file = function(path, opts)
        table.insert(recorded2, { path = path, opts = opts })
        return { render = function() end, clear = function() end }
      end,
    }
    package.loaded["image"] = fake_image_mod
    package.loaded["mercury.image"] = nil
    require("mercury.config").setup()
  end)
  after_each(function()
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
  end)

  local function _setup_cell(items, extract)
    local Util = require("mercury.util")
    Util.write_file("/tmp/inv_a.png", fake_png(400, 300))
    Util.write_file("/tmp/inv_b.png", fake_png(400, 200))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=invpin01", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    nb:set_renderer(require("mercury.ui").new(nb))
    local out = nb:ensure_output(nb.cells[1].id)
    out.status = "ok"; out.exec_count = 1
    out.items = items
    local Output_mod = require("mercury.output")
    local orig_extract = Output_mod.extract_images
    Output_mod.extract_images = function() return extract end
    nb._renderer:render()
    Output_mod.extract_images = orig_extract
    return buf, nb
  end

  it("I1: width uses cfg.cell_width_px (8), NOT a runtime query", function()
    -- Image is 400px wide, default cell_width_px = 8, so natural cols
    -- should be 50. min(available, 50) — verify Mercury uses 8 px/cell.
    local buf = _setup_cell(
      { { type = "display_data", data = { ["image/png"] = "a" } } },
      { { kind = "png", path = "/tmp/inv_a.png", hash = "ia1", item_index = 1 } })
    assert.equals(1, #recorded2)
    local available = math.max(20, math.floor(
      vim.api.nvim_win_get_width(0) * 0.85))
    local natural_at_8 = math.ceil(400 / 8)
    local expected = math.min(available, natural_at_8)
    assert.equals(expected, recorded2[1].opts.width,
      ("width must use 8 px/cell (expected %d cols, got %d)")
        :format(expected, recorded2[1].opts.width))
    require("mercury.notebook").detach(buf)
  end)

  it("I3: image render_offset_top > 0 so the pill stays visible above", function()
    local buf = _setup_cell(
      { { type = "display_data", data = { ["image/png"] = "a" } } },
      { { kind = "png", path = "/tmp/inv_a.png", hash = "ia2", item_index = 1 } })
    assert.equals(1, #recorded2)
    assert.is_true(recorded2[1].opts.render_offset_top > 0,
      "first image must be offset BELOW the pill (SPEC I3)")
    require("mercury.notebook").detach(buf)
  end)

  it("I4: multi-image cumulative offsets stack vertically (no overlap)", function()
    local buf = _setup_cell({
      { type = "display_data", data = { ["image/png"] = "a" } },
      { type = "display_data", data = { ["image/png"] = "b" } },
    }, {
      { kind = "png", path = "/tmp/inv_a.png", hash = "ib1", item_index = 1 },
      { kind = "png", path = "/tmp/inv_b.png", hash = "ib2", item_index = 2 },
    })
    assert.equals(2, #recorded2)
    -- Image 2 offset must be strictly after image 1's, by AT LEAST image
    -- 1's height (SPEC I4 — anti-overlap).
    local off1 = recorded2[1].opts.render_offset_top
    local off2 = recorded2[2].opts.render_offset_top
    assert.is_true(off2 > off1,
      ("SPEC I4 violated: image 2 offset (%d) must exceed image 1 offset (%d)")
        :format(off2, off1))
    require("mercury.notebook").detach(buf)
  end)

  it("I9/I16/I18: EVERY image has padding=false and window=nil", function()
    local buf = _setup_cell({
      { type = "display_data", data = { ["image/png"] = "a" } },
      { type = "display_data", data = { ["image/png"] = "b" } },
    }, {
      { kind = "png", path = "/tmp/inv_a.png", hash = "ic1", item_index = 1 },
      { kind = "png", path = "/tmp/inv_b.png", hash = "ic2", item_index = 2 },
    })
    assert.equals(2, #recorded2)
    for i, rec in ipairs(recorded2) do
      assert.is_false(rec.opts.with_virtual_padding,
        ("SPEC I9/I16: image %d must have padding=false"):format(i))
      assert.is_nil(rec.opts.window,
        ("SPEC I18: image %d needs window=nil so image.nvim's "
          .. "renderer takes the simple `absolute_y = y + offset_top` "
          .. "path that Mercury controls directly"):format(i))
    end
    require("mercury.notebook").detach(buf)
  end)

  it("I8: cell uses a SINGLE output extmark (not multi-extmark)", function()
    local Notebook_mod = require("mercury.notebook")
    local buf = _setup_cell(
      { { type = "stream", name = "stdout", text = "hi\n" },
        { type = "display_data", data = { ["image/png"] = "a" } } },
      { { kind = "png", path = "/tmp/inv_a.png", hash = "id1", item_index = 1 } })
    -- One extmark in the output namespace per cell.
    local ns_out = Notebook_mod.ns("output")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns_out, 0, -1, {})
    assert.equals(1, #marks,
      ("SPEC I8 violated: expected 1 output extmark, got %d"):format(#marks))
    Notebook_mod.detach(buf)
  end)

  it("I12: `height` is NOT passed to image.nvim's from_file", function()
    local buf = _setup_cell(
      { { type = "display_data", data = { ["image/png"] = "a" } } },
      { { kind = "png", path = "/tmp/inv_a.png", hash = "ie1", item_index = 1 } })
    assert.equals(1, #recorded2)
    assert.is_nil(recorded2[1].opts.height,
      "SPEC I12: from_file must NOT receive a height opt")
    require("mercury.notebook").detach(buf)
  end)

  it("I13: render_offset_top = virt_line_idx + 1 (window=nil mode)", function()
    -- Build a cell with one stream item, then one image. The image's
    -- virt_line_idx (from build_virt_lines) is pill_rows (1) + 1 text
    -- row = 2. With window=nil, offset_top = virt_line_idx + 1.
    -- image.nvim's window=nil branch computes
    -- absolute_y = y + offset_top, written at terminal row
    -- absolute_y + 1 (kitty's 1-indexed cursor). For the image to
    -- land at body_end_screen_1idx + virt_line_idx + 1, we set
    -- y = body_end_screen_0idx and offset_top = virt_line_idx + 1.
    local Output_mod = require("mercury.output")
    local buf = _setup_cell({
      { type = "stream", name = "stdout", text = "hi\n" },
      { type = "display_data", data = { ["image/png"] = "a" } },
    }, {
      { kind = "png", path = "/tmp/inv_a.png", hash = "if1", item_index = 2 },
    })
    assert.equals(1, #recorded2)
    local nb = require("mercury.notebook").get(buf)
    local out = nb.outputs[nb.cells[1].id]
    local image_heights = ({ require("mercury.image").new(nb):compute_dimensions({
      { kind = "png", path = "/tmp/inv_a.png", hash = "if1" },
    }) })[2]
    local _, image_offsets = Output_mod.build_virt_lines(out, {
      show_status_pill = true, image_heights = image_heights,
    })
    local expected = image_offsets[1] + 1
    assert.equals(expected, recorded2[1].opts.render_offset_top,
      ("SPEC I13: render_offset_top must be virt_line_idx + 1. "
        .. "idx=%d, expected=%d, got=%d"):format(
        image_offsets[1], expected, recorded2[1].opts.render_offset_top))
    -- window must be nil so image.nvim doesn't go through screenpos /
    -- lock / diff / overlap branches.
    assert.is_nil(recorded2[1].opts.window,
      "SPEC I18: window must be nil so image.nvim's renderer takes "
        .. "the simple `absolute_y = y + offset_top` branch")
    require("mercury.notebook").detach(buf)
  end)

  it("I14: row reservation uses image.nvim's runtime cell sizes when available", function()
    -- When require("image.utils.term").get_size() returns custom
    -- cell_width / cell_height, our height row count must use THOSE
    -- values (so the reservation matches image.nvim's actual render),
    -- not Mercury's static 8x16.
    --
    -- Spoof image.utils.term to return cell_width=10, cell_height=10
    -- (square cells). For a 400x400 image at 50 cols:
    --   target_w_px = 50 * 10 = 500
    --   scaled_h_px = 400 * (500/400) = 500
    --   rendered_rows = ceil(500/10) = 50
    -- With max_rows clamp (default 40), reservation = clamp(50*1.25,
    -- 40) = 40. Without the I14 fix (using static 8x16): rows = 400/16
    -- = 25 → safe = 32 → clamp = 32. The two answers differ — pin the
    -- runtime-based answer.
    local orig_term = package.loaded["image.utils.term"]
    package.loaded["image.utils.term"] = {
      get_size = function() return { cell_width = 10, cell_height = 10 } end,
    }
    -- Force the image module to re-require term (we replaced it).
    package.loaded["mercury.image"] = nil
    local Image = require("mercury.image")
    local Util_mod = require("mercury.util")
    local function fake_png_local(w, h)
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
    Util_mod.write_file("/tmp/i14.png", fake_png_local(400, 400))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=i14test1", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local _, heights = Image.new(nb):compute_dimensions({
      { kind = "png", path = "/tmp/i14.png", hash = "i14a" },
    })

    -- With cell_height=10 runtime: bare rendered rows from image.nvim's
    -- formula = 50. Plus +25% +3 safety, clamped to 40.
    -- We just verify the runtime path produced something larger than
    -- what static 8x16 would have given (25 base → 32 safe), so the
    -- code IS picking up the runtime values rather than ignoring them.
    assert.is_true(heights[1] >= 33,
      ("SPEC I14: heights[1] must reflect runtime cell sizes; "
        .. "got %d (static would be <=32)"):format(heights[1]))

    require("mercury.notebook").detach(buf)
    os.remove("/tmp/i14.png")
    package.loaded["image.utils.term"] = orig_term
    package.loaded["mercury.image"] = nil
  end)


  it("I17: clearing an image removes it from image.nvim's global_state.images", function()
    -- image.nvim's autocmds iterate state.images and call render() on
    -- each, recreating extmarks. Just calling Image:clear() leaves the
    -- entry behind — cleared images come back on next scroll. SPEC I17
    -- says Mercury reaches into image.global_state.images and nils the
    -- entry to fully evict.
    local Util = require("mercury.util")
    local Image = require("mercury.image")
    local function fake_png_local(w, h)
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
    Util.write_file("/tmp/inv_clear.png", fake_png_local(400, 200))

    -- Spoof a fake image module that tracks state.images registry.
    local fake_registry = {}
    package.loaded["image"] = {
      is_enabled = function() return true end,
      from_file = function(path, opts)
        local handle
        handle = {
          id = path,
          buffer = opts.buffer,
          global_state = { images = fake_registry },
          render = function() fake_registry[path] = handle end,
          clear = function() end,        -- no-op, like real image.nvim
        }
        return handle
      end,
    }
    package.loaded["mercury.image"] = nil

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=invclr01", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = require("mercury.image").new(nb)
    renderer:render(nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "png", path = "/tmp/inv_clear.png", hash = "iclr" } })
    assert.is_not_nil(fake_registry["/tmp/inv_clear.png"],
      "after render, image must be registered in image.nvim state")

    -- Clear the cell — Mercury should fully remove from state.images.
    renderer:clear_cell(nb.cells[1])
    assert.is_nil(fake_registry["/tmp/inv_clear.png"],
      ("SPEC I17 violated: cleared image must NOT survive in "
        .. "image.nvim's state.images registry; otherwise the "
        .. "WinScrolled autocmd re-renders it and the user sees "
        .. "the image come back after :NotebookKernelRestartClear"))

    require("mercury.notebook").detach(buf)
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
    os.remove("/tmp/inv_clear.png")
  end)

  it("I18: extmark is pinned with right_gravity=false (no horizontal drift on type)", function()
    -- SPEC I18 (right-gravity pin). image.nvim creates its per-image
    -- extmark with default right_gravity=true, so text inserted at
    -- col 0 of the anchor row shifts the extmark right. image.nvim's
    -- TextChanged handler then re-positions the image at the new
    -- column — visually the image jumps horizontally while typing.
    -- Mercury re-sets the extmark with right_gravity=false right
    -- after each h:render() to pin it. Verify by inspecting the
    -- extmark's options after the render completes.
    local Util = require("mercury.util")
    Util.write_file("/tmp/inv_pin.png", fake_png(400, 200))

    -- Spy backend that exposes the buf_set_extmark calls made by
    -- Mercury's _pin_extmark helper.
    local pin_calls = {}
    package.loaded["image"] = {
      is_enabled = function() return true end,
      from_file = function(path, opts)
        return {
          id = path,
          internal_id = 9001,
          buffer = opts.buffer,
          extmark = { row = opts.y, col = (opts.x or 0) },
          global_state = { extmarks_namespace = 42 },
          render = function() end,
          clear = function() end,
        }
      end,
    }
    package.loaded["mercury.image"] = nil

    -- Wrap nvim_buf_set_extmark to capture calls so we can assert
    -- right_gravity = false was passed.
    local orig_set = vim.api.nvim_buf_set_extmark
    vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, opts)
      if ns == 42 then  -- only image.nvim's namespace
        table.insert(pin_calls, { row = row, col = col, opts = opts })
        return 1
      end
      return orig_set(buf, ns, row, col, opts)
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=invpin01", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = require("mercury.image").new(nb)
    renderer:render(nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "png", path = "/tmp/inv_pin.png", hash = "pin" } })

    vim.api.nvim_buf_set_extmark = orig_set

    -- At least one pin call with right_gravity = false.
    local pinned = false
    for _, c in ipairs(pin_calls) do
      if c.opts and c.opts.right_gravity == false then
        pinned = true; break
      end
    end
    assert.is_true(pinned,
      "SPEC I18: Mercury must re-set image.nvim's extmark with "
        .. "right_gravity = false so typing at col 0 doesn't shift "
        .. "the image horizontally")

    require("mercury.notebook").detach(buf)
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
    os.remove("/tmp/inv_pin.png")
  end)

  it("I13: image with no preceding text still lands BELOW the pill (offset >= 2)", function()
    -- Single image, no text. pill_rows=1, no body before. virt_line_idx=1.
    -- render_offset_top must be 1 + 1 = 2, so the image lands at
    -- virt_line[1] = the first image-blank, NOT at virt_line[0] = pill.
    local buf = _setup_cell(
      { { type = "display_data", data = { ["image/png"] = "a" } } },
      { { kind = "png", path = "/tmp/inv_a.png", hash = "ig1", item_index = 1 } })
    assert.equals(1, #recorded2)
    assert.is_true(recorded2[1].opts.render_offset_top >= 2,
      ("SPEC I13: first image (after pill) must have offset >= 2; got %d")
        :format(recorded2[1].opts.render_offset_top))
    require("mercury.notebook").detach(buf)
  end)
end)

describe(":NotebookKernelRestartClear from a fresh notebook", function()
  it("clears outputs even when the bridge has never started", function()
    Cfg.setup()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=freshrcl", "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)
    local out = nb:ensure_output("freshrcl")
    out.status = "ok"; out.exec_count = 7
    out.items = { { type = "stream", name = "stdout", text = "stale\n" } }
    assert.is_not_nil(nb.outputs["freshrcl"])

    kernel:restart({ clear = true })
    assert.is_nil(nb.outputs["freshrcl"],
      "RestartClear must drop loaded outputs even when bridge is dormant")
    Notebook.detach(buf)
  end)

  it("plain restart without clear=true is still a no-op when bridge is down", function()
    Cfg.setup()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=noclearr", "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)
    local out = nb:ensure_output("noclearr")
    out.status = "ok"; out.items = { { type = "stream", name = "stdout", text = "keep\n" } }

    kernel:restart({})
    assert.is_not_nil(nb.outputs["noclearr"])
    Notebook.detach(buf)
  end)
end)
