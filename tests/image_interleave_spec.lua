-- Pin four image-layout contracts the user reported as broken:
--   (1) The `Out[N]` pill is NOT painted over by an image — the image
--       starts BELOW the pill's text virt_lines.
--   (2) Output items are rendered in item order: an `image, text, image`
--       output stays visually `image, text, image` (was: text first,
--       both images stacked at the end → image covered text).
--   (3) A 1-row visual gap separates consecutive images.
--   (4) :NotebookKernelRestartClear clears outputs even before the bridge
--       has ever started (fresh notebook from disk).

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

describe("build_virt_lines interleave with image_heights", function()
  it("reserves N+1 blank rows per image at the item's position", function()
    -- Two text rows from a stream + one image with height=5 should produce
    -- virt_lines of shape: [pill, text1, text2, blank, blank, blank,
    -- blank, blank, blank_gap]. Image offset = #pill_rows + #text_rows.
    local virt, offsets = Output.build_virt_lines({
      status = "ok", exec_count = 1, ms = 10, items = {
        { type = "stream", name = "stdout", text = "line1\nline2\n" },
        { type = "display_data", data = { ["image/png"] = "AAAA" } },
      },
    }, {
      image_heights = { 5 },
    })
    -- Layout: pill (1) + line1 + line2 + 5 blanks + 1 gap blank = 9 entries.
    assert.equals(9, #virt)
    -- Offset accounts for pill row + 2 text rows = row 3.
    assert.equals(3, offsets[1])
  end)

  it("preserves item order: [image, text, image] interleaves correctly", function()
    -- The user's exact case. Image 1 must come BEFORE the stream; image 2
    -- AFTER. Output items in this order.
    local virt, offsets = Output.build_virt_lines({
      status = "ok", exec_count = 1, ms = 5, items = {
        { type = "display_data", data = { ["image/png"] = "img1" } },
        { type = "stream", name = "stdout", text = "between\n" },
        { type = "display_data", data = { ["image/png"] = "img2" } },
      },
    }, {
      image_heights = { 4, 6 },
    })
    -- Layout: pill, [4 blanks + 1 gap for img1], between, [6 blanks + 1 gap for img2]
    -- pill = row 0
    -- img1 starts at row 1 (offsets[1] = 1)
    -- gap row 6 after img1
    -- text "between" at row 6
    -- img2 starts at row 7 (offsets[2] = 7)
    assert.equals(1, offsets[1])
    -- Image 2's offset is past pill (1) + img1 reservation (4+1=5) + text (1).
    assert.equals(7, offsets[2])
    -- Total virt_lines = pill + img1_block + text + img2_block.
    -- = 1 + 5 + 1 + 7 = 14
    assert.equals(14, #virt)
  end)

  it("does NOT interleave when image_heights is omitted (back-compat)", function()
    -- Old callers passing no image_heights get the original text-only
    -- behavior: image items contribute either a fallback [mime] line or
    -- nothing (image.nvim available). No blank-row reservation.
    package.loaded["image"] = {
      is_enabled = function() return true end,
      from_file = function() return { render = function() end } end,
    }
    package.loaded["mercury.image"] = nil
    local virt, offsets = Output.build_virt_lines({
      status = "ok", items = {
        { type = "stream", name = "stdout", text = "hello\n" },
        { type = "display_data", data = { ["image/png"] = "x" } },
      },
    }, { show_status_pill = false })
    -- Only the stream line — image item contributed no rows because
    -- image.nvim is available and no offset was requested.
    assert.equals(1, #virt)
    -- offsets is an empty table for the omit-heights path.
    assert.equals(0, #offsets)
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
  end)

  it("1-row gap reserved between consecutive images", function()
    -- Two adjacent image items (no text between): there should still be
    -- ONE blank row separating them.
    local virt, offsets = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data", data = { ["image/png"] = "a" } },
        { type = "display_data", data = { ["image/png"] = "b" } },
      },
    }, {
      show_status_pill = false,
      image_heights = { 3, 4 },
    })
    -- offsets[1] = 0 (first image at start), offsets[2] = 3 + 1 = 4
    -- (after first image's 3 rows + 1 gap row).
    assert.equals(0, offsets[1])
    assert.equals(4, offsets[2])
    -- Total: 3 (img1) + 1 (gap) + 4 (img2) + 1 (trailing gap) = 9
    assert.equals(9, #virt)
  end)
end)

describe("ui passes computed heights/offsets to image:render", function()
  -- Stub a fake image.nvim that records every from_file call's opts.
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

  it("anchors images at offsets that put them BELOW the Out[x] pill", function()
    local Util = require("mercury.util")
    local UI = require("mercury.ui")
    Util.write_file("/tmp/intp.png", fake_png(400, 300))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=intabovx", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    nb:set_renderer(UI.new(nb))
    local out = nb:ensure_output(nb.cells[1].id)
    out.status = "ok"
    out.exec_count = 1
    out.ms = 42
    out.items = {
      -- A typical Matplotlib cell: pill above, one image below.
      { type = "display_data",
        data = { ["image/png"] = require("mercury.base64") and "x" or "x" },
        path = "/tmp/intp.png" },
    }
    -- Manually pre-seed an extract_images result by mutating items so
    -- extract picks up the file: actually, easier — bypass extract_images
    -- by stubbing it. We focus on the offset math.
    local orig = require("mercury.output").extract_images
    require("mercury.output").extract_images = function(o)
      return { { kind = "png", path = "/tmp/intp.png", hash = "ip1",
                 item_index = 1 } }
    end
    nb._renderer:render()
    require("mercury.output").extract_images = orig

    assert.equals(1, #recorded)
    -- The pill emits one virt_line (the Out[1] line). The image must
    -- start at offset >= 1 so it doesn't paint over the pill.
    assert.is_true(recorded[1].opts.render_offset_top >= 1,
      ("image render_offset_top must be >= 1 to leave room for the Out[1] pill; got %d")
        :format(recorded[1].opts.render_offset_top))
    Notebook.detach(buf)
    os.remove("/tmp/intp.png")
  end)

  it("renders multi-image stack with offsets so img2 starts after img1+gap", function()
    local Util = require("mercury.util")
    local UI = require("mercury.ui")
    Util.write_file("/tmp/ia.png", fake_png(400, 200))
    Util.write_file("/tmp/ib.png", fake_png(400, 200))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=intstack", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    nb:set_renderer(UI.new(nb))
    local out = nb:ensure_output(nb.cells[1].id)
    out.status = "ok"
    out.exec_count = 1
    out.items = {
      { type = "display_data", data = { ["image/png"] = "a" } },
      { type = "display_data", data = { ["image/png"] = "b" } },
    }
    local Output_mod = require("mercury.output")
    local orig = Output_mod.extract_images
    Output_mod.extract_images = function(o)
      return {
        { kind = "png", path = "/tmp/ia.png", hash = "ia", item_index = 1 },
        { kind = "png", path = "/tmp/ib.png", hash = "ib", item_index = 2 },
      }
    end
    nb._renderer:render()
    Output_mod.extract_images = orig

    assert.equals(2, #recorded)
    -- Second image's offset must be strictly greater than first image's
    -- offset + first image's height (at minimum). The 1-row gap is
    -- baked into the offsets via output.lua's blank-row reservation.
    local off1 = recorded[1].opts.render_offset_top
    local off2 = recorded[2].opts.render_offset_top
    assert.is_true(off2 > off1)
    -- Image 2 must NOT have with_virtual_padding=true (virt_lines
    -- already reserved the rows; image.nvim's padding would double-count).
    assert.is_false(recorded[2].opts.with_virtual_padding)
    Notebook.detach(buf)
    os.remove("/tmp/ia.png"); os.remove("/tmp/ib.png")
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
    -- Simulate outputs loaded from disk (no kernel ever ran them).
    local out = nb:ensure_output("freshrcl")
    out.status = "ok"; out.exec_count = 7
    out.items = { { type = "stream", name = "stdout", text = "stale\n" } }
    assert.is_not_nil(nb.outputs["freshrcl"])

    -- Bridge is NOT running (`self.chan == nil`). Old behavior was:
    -- notify "kernel not running" and bail, leaving the output stuck.
    -- New behavior: still clear locally when opts.clear is set.
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

    kernel:restart({})  -- no clear flag
    -- Output should be untouched — there was no kernel to restart and
    -- the user did not ask for a clear.
    assert.is_not_nil(nb.outputs["noclearr"])
    Notebook.detach(buf)
  end)
end)
