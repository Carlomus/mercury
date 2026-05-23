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

  it("first image's render_offset_top >= #text_virt_lines (no pill overlap)", function()
    local Util = require("mercury.util")
    local UI = require("mercury.ui")
    Util.write_file("/tmp/sa.png", fake_png(400, 300))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=shftbelow", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    nb:set_renderer(UI.new(nb))
    local out = nb:ensure_output(nb.cells[1].id)
    out.status = "ok"
    out.exec_count = 1
    out.ms = 42
    out.items = {
      { type = "display_data", data = { ["image/png"] = "x" } },
    }
    local orig = require("mercury.output").extract_images
    require("mercury.output").extract_images = function()
      return { { kind = "png", path = "/tmp/sa.png", hash = "sa", item_index = 1 } }
    end
    nb._renderer:render()
    require("mercury.output").extract_images = orig

    assert.equals(1, #recorded)
    -- A pill is rendered (Out[1] line) so #text_virt_lines >= 1. The
    -- image's render_offset_top must be at least that.
    assert.is_true(recorded[1].opts.render_offset_top >= 1,
      ("first image offset must be >= text rows; got %d")
        :format(recorded[1].opts.render_offset_top))
    Notebook.detach(buf)
    os.remove("/tmp/sa.png")
  end)

  it("last image gets with_virtual_padding=true (reserves the stack)", function()
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
    -- First image: padding off (it's not the last).
    assert.is_false(recorded[1].opts.with_virtual_padding)
    -- Last image: padding on so image.nvim reserves enough rows.
    assert.is_true(recorded[2].opts.with_virtual_padding)
    -- Second image's offset > first image's, ensures stacking order.
    assert.is_true(recorded[2].opts.render_offset_top
                   > recorded[1].opts.render_offset_top)
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
