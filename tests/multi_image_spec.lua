-- Verifies the image stacking math: each image gets a distinct extmark column
-- and a render_offset_top equal to the cumulative height of prior images.
-- This runs without image.nvim by injecting a fake `image` module.

local Output = require("mercury.output")
local B64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64encode(bytes)
  local out, n = {}, #bytes
  local i = 1
  while i <= n do
    local b1 = bytes:byte(i) or 0
    local b2 = bytes:byte(i + 1) or 0
    local b3 = bytes:byte(i + 2) or 0
    local v = b1 * 65536 + b2 * 256 + b3
    out[#out + 1] = B64_chars:sub(math.floor(v / 262144) % 64 + 1, math.floor(v / 262144) % 64 + 1)
    out[#out + 1] = B64_chars:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
    out[#out + 1] = (i + 1 <= n) and
      B64_chars:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1) or "="
    out[#out + 1] = (i + 2 <= n) and
      B64_chars:sub(v % 64 + 1, v % 64 + 1) or "="
    i = i + 3
  end
  return table.concat(out)
end

-- Build a synthetic PNG with the given width and height encoded in IHDR.
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

describe("multi-image stacking", function()
  local recorded
  local fake_image_mod = {
    is_enabled = function() return true end,
    from_file = function(path, opts)
      table.insert(recorded, { path = path, opts = opts })
      return {
        render = function() end,
        clear = function() end,
        move = function(_, _, _) end,
      }
    end,
  }

  before_each(function()
    recorded = {}
    package.loaded["image"] = fake_image_mod
    require("mercury.config").setup()
  end)

  after_each(function()
    package.loaded["image"] = nil
  end)

  it("places each image at distinct cols with increasing render_offset_top", function()
    local Image = require("mercury.image")
    local png_a = fake_png(400, 200)
    local png_b = fake_png(400, 600)
    local png_c = fake_png(400, 100)
    local images = {
      { kind = "png", path = "/tmp/a.png", hash = "h1" },
      { kind = "png", path = "/tmp/b.png", hash = "h2" },
      { kind = "png", path = "/tmp/c.png", hash = "h3" },
    }
    -- Write the fake PNGs so png_dimensions reads real bytes.
    local Util = require("mercury.util")
    Util.write_file("/tmp/a.png", png_a)
    Util.write_file("/tmp/b.png", png_b)
    Util.write_file("/tmp/c.png", png_c)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=aaaa1111", "print('hi')",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = Image.new(nb)
    renderer:render(nb.cells[1], nb:cell_anchor_row(nb.cells[1]), images)

    assert.equals(3, #recorded)
    -- Each call sees a distinct col and monotonically increasing offset.
    assert.equals(0, recorded[1].opts.x)
    assert.equals(1, recorded[2].opts.x)
    assert.equals(2, recorded[3].opts.x)
    assert.equals(0, recorded[1].opts.render_offset_top)
    assert.is_true(recorded[2].opts.render_offset_top > 0)
    assert.is_true(recorded[3].opts.render_offset_top > recorded[2].opts.render_offset_top)
    -- Only the last reserves virtual padding.
    assert.is_false(recorded[1].opts.with_virtual_padding)
    assert.is_false(recorded[2].opts.with_virtual_padding)
    assert.is_true(recorded[3].opts.with_virtual_padding)
    -- All images share the same buffer-row anchor.
    assert.equals(recorded[1].opts.y, recorded[2].opts.y)
    assert.equals(recorded[2].opts.y, recorded[3].opts.y)

    -- Tall image (400x600) must claim more rows than short one (400x100).
    local h_b = recorded[3].opts.render_offset_top - recorded[2].opts.render_offset_top
    local h_a = recorded[2].opts.render_offset_top - recorded[1].opts.render_offset_top
    assert.is_true(h_b > h_a)

    require("mercury.notebook").detach(buf)
    os.remove("/tmp/a.png"); os.remove("/tmp/b.png"); os.remove("/tmp/c.png")
  end)

  it("re-uses cached image handles when content+placement are unchanged", function()
    local Util = require("mercury.util")
    local png = fake_png(400, 200)
    Util.write_file("/tmp/a.png", png)
    local images = { { kind = "png", path = "/tmp/a.png", hash = "h1" } }

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=ccccdddd", "print('hi')",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = require("mercury.image").new(nb)
    local anchor = nb:cell_anchor_row(nb.cells[1])

    renderer:render(nb.cells[1], anchor, images)
    assert.equals(1, #recorded)
    -- Second render with identical inputs must not call from_file again.
    renderer:render(nb.cells[1], anchor, images)
    assert.equals(1, #recorded,
      "image cache should skip re-creation when hash+placement unchanged")

    -- Different anchor row should invalidate the cache.
    renderer:render(nb.cells[1], anchor + 5, images)
    assert.equals(2, #recorded)

    require("mercury.notebook").detach(buf)
    os.remove("/tmp/a.png")
  end)

  it("reuses cached handles for identical content + placement", function()
    -- SPEC invariant: a re-render with the same content at the same place
    -- must not call from_file or render again. Without this, every
    -- TextChanged would recreate every handle, causing flicker during
    -- streaming output.
    local Image = require("mercury.image")
    local Util = require("mercury.util")
    local png = fake_png(400, 200)
    Util.write_file("/tmp/reuse.png", png)
    local images = { { kind = "png", path = "/tmp/reuse.png", hash = "reuse-hash" } }

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=reusable", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = Image.new(nb)
    local anchor = nb:cell_anchor_row(nb.cells[1])

    renderer:render(nb.cells[1], anchor, images)
    assert.equals(1, #recorded)
    -- Second render with same images at same anchor: should NOT call from_file.
    renderer:render(nb.cells[1], anchor, images)
    assert.equals(1, #recorded)
    -- Moving the anchor row invalidates placement -> must re-create.
    renderer:render(nb.cells[1], anchor + 5, images)
    assert.equals(2, #recorded)

    require("mercury.notebook").detach(buf)
    os.remove("/tmp/reuse.png")
  end)

  it("gc clears handles for cells not in the present set", function()
    local Image = require("mercury.image")
    local Util = require("mercury.util")
    local png = fake_png(100, 100)
    Util.write_file("/tmp/gc.png", png)
    local images = { { kind = "png", path = "/tmp/gc.png", hash = "gc-hash" } }

    local cleared = {}
    -- Override fake_image_mod's clear so we can observe it.
    local prev_from_file = fake_image_mod.from_file
    fake_image_mod.from_file = function(path, opts)
      table.insert(recorded, { path = path, opts = opts })
      return {
        render = function() end,
        clear = function(self) cleared[opts.y] = (cleared[opts.y] or 0) + 1 end,
      }
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=todelete", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = Image.new(nb)
    renderer:render(nb.cells[1], nb:cell_anchor_row(nb.cells[1]), images)

    -- Simulate the cell being deleted: gc with empty present set.
    renderer:gc({})
    assert.is_true(next(cleared) ~= nil)

    fake_image_mod.from_file = prev_from_file
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/gc.png")
  end)

  it("skips render and reserves minimal rows when the cached image bytes are missing", function()
    -- When the on-disk cached image file has been evicted between
    -- extract_images and the render pass, the renderer used to fall back to
    -- max_rows (40 blank rows per image — a huge dead-space gap dwarfing
    -- everything else on screen). Current behavior: skip rendering the
    -- image (from_file is NOT called), reserve only 1 row per missing image,
    -- and surface a `[image bytes unavailable]` text placeholder via the
    -- build_virt_lines path.
    local images = {
      { kind = "png", path = "/nonexistent_xyz.png", hash = "x1" },
      { kind = "png", path = "/nonexistent_xyz.png", hash = "x2" },
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=bbbb2222", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = require("mercury.image").new(nb)
    local total = renderer:render(
      nb.cells[1], nb:cell_anchor_row(nb.cells[1]), images)
    -- No image placements are recorded because from_file is bypassed for
    -- unavailable images.
    assert.equals(0, #recorded)
    -- 1 row reserved per image (2 unavailable images → 2 rows of virtual gap).
    assert.equals(2, total)
    -- The descriptors carry the unavailable flag so build_virt_lines can
    -- show a text placeholder.
    assert.is_true(images[1].unavailable)
    assert.is_true(images[2].unavailable)
    require("mercury.notebook").detach(buf)
  end)

  it("does not upscale images smaller than the available render width", function()
    -- A tiny 32x32 icon should render at ~4 columns (32px / 8px per cell),
    -- not be blown up to 85% of the window. This matches VS Code / Jupyter
    -- Lab: images render at their intrinsic resolution when smaller than
    -- the cell, and downscale when larger.
    local Image = require("mercury.image")
    local Util = require("mercury.util")
    local tiny = fake_png(32, 32)
    Util.write_file("/tmp/tiny_icon.png", tiny)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=tinytiny", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)

    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    Image.new(nb):render(
      nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "png", path = "/tmp/tiny_icon.png", hash = "tiny" } })

    assert.equals(1, #recorded)
    -- With default cell_width_px = 8: 32 / 8 = 4 natural cols. Render width
    -- must be 4 regardless of window size — the natural-size clamp wins.
    assert.equals(4, recorded[1].opts.width)

    require("mercury.notebook").detach(buf)
    os.remove("/tmp/tiny_icon.png")
  end)

  it("does not upscale small SVGs (natural-size clamp applies to vectors)", function()
    -- A tiny SVG icon with explicit width/height must render at its
    -- intrinsic columns, not be blown up to 85% of the window. SVG used
    -- to be carved out of the natural-size clamp; that meant a 32×32
    -- inline icon reserved up to image_max_height_rows of empty space.
    local Image = require("mercury.image")
    local Util = require("mercury.util")
    local svg = [[<svg xmlns="http://www.w3.org/2000/svg" ]]
      .. [[width="32" height="32"><rect width="32" height="32"/></svg>]]
    Util.write_file("/tmp/tiny_icon.svg", svg)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=svgicon1", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)

    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    Image.new(nb):render(
      nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "svg", path = "/tmp/tiny_icon.svg", hash = "svg-tiny" } })

    assert.equals(1, #recorded)
    -- 32px / cell_w_px=8 = 4 natural cols.
    assert.equals(4, recorded[1].opts.width)
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/tiny_icon.svg")
  end)

  it("uses viewBox for SVGs without explicit width/height", function()
    -- katex emits SVGs with width="100%" + viewBox; the natural size comes
    -- from the viewBox. Without this fallback path the SVG would render
    -- at full width regardless of its actual aspect ratio.
    local Image = require("mercury.image")
    local Util = require("mercury.util")
    local svg = [[<svg xmlns="http://www.w3.org/2000/svg" ]]
      .. [[width="100%" height="100%" viewBox="0 0 80 40"/>]]
    Util.write_file("/tmp/vb_only.svg", svg)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=svgvbox1", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)

    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    Image.new(nb):render(
      nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "svg", path = "/tmp/vb_only.svg", hash = "svg-vb" } })

    assert.equals(1, #recorded)
    -- viewBox declares 80 units wide. With cell_w_px=8 that's 10 cols
    -- natural, well below available — natural wins.
    assert.equals(10, recorded[1].opts.width)
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/vb_only.svg")
  end)

  it("falls back to full width for SVGs with no resolvable size", function()
    -- An SVG with no width/height/viewBox is treated like a PNG with an
    -- unreadable IHDR: use the full available width and reserve max_rows.
    -- This preserves the legacy behavior for the corner case while letting
    -- well-formed SVGs honor the natural-size clamp.
    local Image = require("mercury.image")
    local Util = require("mercury.util")
    Util.write_file("/tmp/nodim.svg",
      [[<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>]])

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=svgnodim", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)

    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    Image.new(nb):render(
      nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "svg", path = "/tmp/nodim.svg", hash = "svg-nodim" } })

    assert.equals(1, #recorded)
    local win_w = vim.api.nvim_win_get_width(0)
    local expected = math.max(20, math.floor(win_w * 0.85))
    assert.equals(expected, recorded[1].opts.width)
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/nodim.svg")
  end)

  it("render returns 0 silently when no window shows the buffer", function()
    -- image.nvim's render requires a visible window. If the buffer has no
    -- window (e.g. opened in the background), the function must no-op
    -- without raising. Pin the behavior.
    local Image = require("mercury.image")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=nowin001", "x = 1",
    })
    -- Do NOT set this buffer as the current one — no window shows it.
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = Image.new(nb)
    -- Call render. With no window for the buffer, the function returns
    -- without invoking from_file.
    local ok = pcall(renderer.render, renderer,
      nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "png", path = "/tmp/nowin.png", hash = "h-nw" } })
    assert.is_true(ok)
    -- No image was placed because there's no window.
    local placed = false
    for _, r in ipairs(recorded) do
      if r.path == "/tmp/nowin.png" then placed = true end
    end
    assert.is_false(placed)
    require("mercury.notebook").detach(buf)
  end)

  it("render clears prior handles when the new images list is empty", function()
    -- Transition: cell rendered images, then re-renders with no images
    -- (e.g. cell re-executed and no longer produces a plot). The previous
    -- handles must be cleared.
    local Image = require("mercury.image")
    local Util = require("mercury.util")
    Util.write_file("/tmp/clear_me.png", fake_png(100, 100))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=clrtst01", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = Image.new(nb)
    -- First render: one image.
    renderer:render(
      nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "png", path = "/tmp/clear_me.png", hash = "clrtst" } })
    -- Second render: empty list.
    renderer:render(nb.cells[1], nb:cell_anchor_row(nb.cells[1]), {})
    -- The cache entry for this cell should be gone.
    assert.is_nil(renderer.cache[nb.cells[1].id])
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/clear_me.png")
  end)

  it("downscales large images to the 85% window cap", function()
    -- A 4000x3000 image is much bigger than any reasonable terminal window.
    -- min(available_cols, natural_cols) should pick available_cols here.
    local Image = require("mercury.image")
    local Util = require("mercury.util")
    local big = fake_png(4000, 3000)
    Util.write_file("/tmp/big_pic.png", big)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=bigpic01", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)

    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    Image.new(nb):render(
      nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "png", path = "/tmp/big_pic.png", hash = "big" } })

    -- Compute the expected available_cols from the actual window — headless
    -- nvim's window width isn't user-settable, so don't hard-code it.
    local win_w = vim.api.nvim_win_get_width(0)
    local expected = math.max(20, math.floor(win_w * 0.85))
    -- Natural is 4000/8 = 500 cols; expected < 500, so min picks expected.
    assert.equals(1, #recorded)
    assert.equals(expected, recorded[1].opts.width)

    require("mercury.notebook").detach(buf)
    os.remove("/tmp/big_pic.png")
  end)
end)
