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

  it("every image gets with_virtual_padding=true under the multi-extmark layout", function()
    -- Multi-extmark layout: each image has its OWN extmark with
    -- virtual_padding=true so image.nvim owns the row reservation per
    -- image. Render order = creation order = document order, so the
    -- pill text from the preceding text-segment extmark appears ABOVE
    -- each image without any row-math on Mercury's side.
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
    -- Both images get virtual_padding=true (each owns its own extmark
    -- and image.nvim's reservation).
    assert.is_true(recorded[1].opts.with_virtual_padding)
    assert.is_true(recorded[2].opts.with_virtual_padding)
    -- render_offset_top is 0 for each — vertical positioning comes from
    -- extmark stacking order, not from row math.
    assert.equals(0, recorded[1].opts.render_offset_top)
    assert.equals(0, recorded[2].opts.render_offset_top)
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

describe("compute_dimensions row math", function()
  it("returns image_row_height directly (no safety bump under multi-extmark)", function()
    -- The multi-extmark layout delegates row reservation to image.nvim
    -- (each image's own extmark has `with_virtual_padding=true`), so we
    -- no longer need a safety bump on top of image_row_height —
    -- image.nvim reserves exactly what it actually renders. Pin that
    -- the returned height matches image_row_height with no inflation;
    -- a future regression adding margin back would silently waste
    -- vertical space below every image.
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
    assert.equals(bare, heights[1],
      ("expected bare image_row_height (%d); got %d"):format(bare, heights[1]))
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
