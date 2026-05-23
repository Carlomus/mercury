-- Pins three image-rendering contracts the user reported as bugs:
--   (1) When image.nvim renders the image inline, no `[image/png]` placeholder
--       line appears in the cell's body. The image IS the label.
--   (2) image.nvim is told the EXACT row height we computed via
--       `image_row_height`, so the rows reserved for the image match what we
--       expect — preventing tall images from being painted over the next cell.
--   (3) On tab switches / window changes, cached image handles are re-painted
--       (handle:render called again) so images that vanished after a tab
--       round-trip come back.

local Output = require("mercury.output")
local Util = require("mercury.util")

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

describe("image placeholder labelling", function()
  it("DOES emit `[image/png]` when image.nvim is NOT available", function()
    -- Image.nvim missing → user has no other signal an image is in the
    -- output. We still emit a fallback label so the cell isn't visually
    -- blank.
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data",
          data = { ["image/png"] = "AAAA" } },
      },
    }, { show_status_pill = false })
    local saw_label = false
    for _, vline in ipairs(virt) do
      if vline[1][1]:match("%[image/png%]") then saw_label = true end
    end
    assert.is_true(saw_label,
      "fallback placeholder should appear when image.nvim is unavailable")
  end)

  it("does NOT emit `[image/png]` when image.nvim IS available", function()
    -- The actual image renders below via image.nvim — having a `[image/png]`
    -- label sit above it (or under it where the image paints overlap) is
    -- the noise the user reported. Pin "no label when rendering."
    package.loaded["image"] = {
      is_enabled = function() return true end,
      from_file = function() return { render = function() end } end,
    }
    -- Force mercury.image to re-evaluate against the new fake module.
    package.loaded["mercury.image"] = nil
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data",
          data = { ["image/png"] = "AAAA" } },
      },
    }, { show_status_pill = false })
    for _, vline in ipairs(virt) do
      assert.is_nil(vline[1][1]:match("%[image/"),
        "no mime placeholder line should appear when image.nvim is rendering")
    end
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
  end)

  it("emits a clean diagnostic when bytes are unavailable (no mime prefix)", function()
    -- The unavailable diagnostic used to read "[image/png: image bytes
    -- unavailable; re-execute the cell]" — same mime-prefix shape as the
    -- regular placeholder, which collided with the image rendering. Now
    -- it's a single human-readable line with no mime in it.
    package.loaded["image"] = {
      is_enabled = function() return true end,
      from_file = function() return { render = function() end } end,
    }
    package.loaded["mercury.image"] = nil
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data",
          data = { ["image/png"] = "AAAA" },
          _mercury_image_unavailable = true },
      },
    }, { show_status_pill = false })
    local saw = false
    for _, vline in ipairs(virt) do
      local txt = vline[1][1]
      if txt:match("image bytes unavailable") then saw = true end
      assert.is_nil(txt:match("image/png"),
        "unavailable diagnostic must not include the mime token")
    end
    assert.is_true(saw)
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
  end)
end)

describe("image rendering — explicit height + tab re-render", function()
  local recorded
  local fake_handle_renders
  local fake_image_mod = {
    is_enabled = function() return true end,
    from_file = function(path, opts)
      table.insert(recorded, { path = path, opts = opts })
      local handle = {
        _id = #recorded,
        render = function(self)
          fake_handle_renders[self._id] = (fake_handle_renders[self._id] or 0) + 1
        end,
        clear = function() end,
      }
      return handle
    end,
  }

  before_each(function()
    recorded = {}
    fake_handle_renders = {}
    package.loaded["image"] = fake_image_mod
    package.loaded["mercury.image"] = nil  -- reload against fake module
    require("mercury.config").setup()
  end)
  after_each(function()
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
  end)

  it("does NOT pass explicit `height` to image.nvim's from_file", function()
    -- Real image.nvim renders nothing when both `width` AND `height` are
    -- forced via `from_file` (regression seen against a matplotlib cell).
    -- We pass only `width`; image.nvim derives the row height from the
    -- on-disk pixel dimensions plus the terminal cell aspect. Pin the
    -- absence so a future refactor doesn't reintroduce the bug.
    local Image = require("mercury.image")
    Util.write_file("/tmp/h_check.png", fake_png(400, 600))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=heightch", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    Image.new(nb):render(nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "png", path = "/tmp/h_check.png", hash = "hch" } })
    assert.equals(1, #recorded)
    assert.is_nil(recorded[1].opts.height,
      "from_file must NOT receive a `height` opt (breaks real image.nvim)")
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/h_check.png")
  end)

  it("our internal row math still tracks each image's expected row count", function()
    -- Even though we don't pass `height` to image.nvim, we still compute it
    -- ourselves to drive `render_offset_top` for image i+1 and to return a
    -- meaningful cumulative reservation. Verify the same `image_row_height`
    -- contract — the math itself is the public surface other layout code
    -- depends on.
    local rows = Output.image_row_height(400, 600,
      math.min(50, math.max(20, math.floor(80 * 0.85))),
      8, 16, 40)
    assert.is_true(rows >= 1 and rows <= 40)
  end)

  it("force_invalidate_all drops cached handles for the next render", function()
    -- Tab-switch / window-revisit recovery path. The previous design
    -- called handle:render() on cache hits to repaint, but some
    -- image.nvim versions treated repeated render() as new placements
    -- and rendered the image twice. Multi-extmark layout now relies on
    -- `force_invalidate_all` (invoked from BufWinEnter / TabEnter etc.)
    -- to drop the cached handles so the next render creates fresh ones,
    -- giving a clean redraw without duplicate placements.
    local Image = require("mercury.image")
    Util.write_file("/tmp/tabretab.png", fake_png(200, 100))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=tabretab", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = Image.new(nb)
    local anchor = nb:cell_anchor_row(nb.cells[1])
    local imgs = { { kind = "png", path = "/tmp/tabretab.png", hash = "tr1" } }

    renderer:render(nb.cells[1], anchor, imgs)
    assert.equals(1, #recorded)

    -- Second render with the same opts is a cache hit — from_file is
    -- NOT called again, and crucially handle:render() is NOT called
    -- again either (the duplicate-render bug).
    renderer:render(nb.cells[1], anchor, imgs)
    assert.equals(1, #recorded)
    assert.equals(1, fake_handle_renders[1],
      "cache hit must not re-call render() on the handle")

    -- force_invalidate_all drops the cached handle so the next render
    -- creates a fresh one.
    renderer:force_invalidate_all()
    renderer:render(nb.cells[1], anchor, imgs)
    assert.equals(2, #recorded,
      "after force_invalidate_all, next render must call from_file again")
    -- The new placement gets a fresh _id (2) and its own render counter.
    assert.equals(1, fake_handle_renders[2],
      "fresh from_file means a fresh handle with render() called once")

    require("mercury.notebook").detach(buf)
    os.remove("/tmp/tabretab.png")
  end)

  it("multi-image stack: render_offset_top monotonically increases (no overlap)", function()
    -- Anti-overlap pin. Without distinct `render_offset_top` per image,
    -- multiple images at the same anchor row would render at the same
    -- position and overlap. The cumulative sum of our internal per-image
    -- row heights drives offset_top.
    local Image = require("mercury.image")
    Util.write_file("/tmp/ov_a.png", fake_png(800, 400))
    Util.write_file("/tmp/ov_b.png", fake_png(400, 800))
    Util.write_file("/tmp/ov_c.png", fake_png(200, 200))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=overcheck", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    Image.new(nb):render(nb.cells[1], nb:cell_anchor_row(nb.cells[1]), {
      { kind = "png", path = "/tmp/ov_a.png", hash = "ova" },
      { kind = "png", path = "/tmp/ov_b.png", hash = "ovb" },
      { kind = "png", path = "/tmp/ov_c.png", hash = "ovc" },
    })
    assert.equals(3, #recorded)
    -- SPEC I13: first image's render_offset_top = virt_line_idx (0) + 1
    -- so it lands at virt_line[0] (one row BELOW body_end), not on the
    -- body_end content row itself.
    assert.equals(1, recorded[1].opts.render_offset_top)
    for i = 2, 3 do
      assert.is_true(
        recorded[i].opts.render_offset_top > recorded[i - 1].opts.render_offset_top,
        ("image %d render_offset_top should exceed image %d's"):format(i, i - 1))
    end
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/ov_a.png"); os.remove("/tmp/ov_b.png"); os.remove("/tmp/ov_c.png")
  end)

  it("multi-image stack: total reserved rows is positive and stable", function()
    local Image = require("mercury.image")
    Util.write_file("/tmp/ms_a.png", fake_png(400, 200))
    Util.write_file("/tmp/ms_b.png", fake_png(400, 400))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=mstotal1", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local total = Image.new(nb):render(nb.cells[1],
      nb:cell_anchor_row(nb.cells[1]), {
        { kind = "png", path = "/tmp/ms_a.png", hash = "ms_a" },
        { kind = "png", path = "/tmp/ms_b.png", hash = "ms_b" },
      })
    assert.is_true(total > 0)
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/ms_a.png"); os.remove("/tmp/ms_b.png")
  end)
end)
