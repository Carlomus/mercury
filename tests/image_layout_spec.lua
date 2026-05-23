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

  it("passes explicit `height` to image.nvim matching our row computation", function()
    -- Tall image: 400x600 with cell 8x16. Width clamps to natural 50 cols
    -- (400/8). target_w_px = 50*8 = 400. scaled_h_px = 600*(400/400) = 600.
    -- rows = ceil(600/16) = 38. Mercury must pass height=38 so image.nvim
    -- reserves exactly 38 rows — and the next cell's lines stay below.
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
    assert.is_truthy(recorded[1].opts.height,
      "image.nvim must receive an explicit height opt")
    -- Height matches `image_row_height` for these dimensions exactly.
    local expected_rows = Output.image_row_height(400, 600,
      recorded[1].opts.width, 8, 16, 40)
    assert.equals(expected_rows, recorded[1].opts.height)
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/h_check.png")
  end)

  it("a height change between renders re-creates the handle", function()
    -- If we ever start re-rendering at a different width/height (the user
    -- resized their window between renders), the cached handle must NOT be
    -- reused — same_placement must reject divergent heights.
    local Image = require("mercury.image")
    Util.write_file("/tmp/sp_h.png", fake_png(400, 300))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=sameplt1", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = require("mercury.notebook").attach(buf); nb:rescan()
    local renderer = Image.new(nb)
    renderer:render(nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "png", path = "/tmp/sp_h.png", hash = "sp_h" } })
    -- Mutate the cached placement's height — emulates the window resize
    -- causing a different row count.
    local entry = renderer.cache[nb.cells[1].id]
    local hash = "sp_h"
    entry.placements[hash].height = entry.placements[hash].height + 5
    renderer:render(nb.cells[1], nb:cell_anchor_row(nb.cells[1]),
      { { kind = "png", path = "/tmp/sp_h.png", hash = "sp_h" } })
    assert.equals(2, #recorded,
      "different height in cached placement should invalidate same_placement")
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/sp_h.png")
  end)

  it("re-paints cached handles on every render (idempotent re-paint on tab return)", function()
    -- The bug: switch tab, come back, image is gone. Root cause: image.nvim's
    -- terminal-side placement is dropped when the tab leaves, but Mercury's
    -- cached handle survives in Lua. With the fix, every render() call
    -- through this path calls `handle:render()` again — cheap, idempotent,
    -- and brings the image back.
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
    assert.equals(1, fake_handle_renders[1],
      "first render: handle:render must be called once")

    -- Second render — same placement, same content. Pre-fix this was a
    -- pure cache hit with NO re-paint. Now we must see another render
    -- call so terminals that lost the placement get it back.
    renderer:render(nb.cells[1], anchor, imgs)
    -- from_file is NOT called a second time (cache hit on hash+placement).
    assert.equals(1, #recorded)
    assert.equals(2, fake_handle_renders[1],
      "second render: cached handle must be re-painted via handle:render")

    -- Third render: still cheap, still re-paints.
    renderer:render(nb.cells[1], anchor, imgs)
    assert.equals(1, #recorded)
    assert.equals(3, fake_handle_renders[1])

    require("mercury.notebook").detach(buf)
    os.remove("/tmp/tabretab.png")
  end)

  it("multi-image stack: image i+1 starts exactly where image i ends (no overlap)", function()
    -- Geometric anti-overlap pin. Image[i].render_offset_top must equal
    -- Image[i-1].render_offset_top + Image[i-1].height. If any pair's
    -- offset doesn't match the previous image's height, images would
    -- overlap visually in the terminal. The explicit `height` opt makes
    -- image.nvim respect our exact reservation.
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
    for i = 2, 3 do
      local prev = recorded[i - 1].opts
      local cur = recorded[i].opts
      assert.equals(prev.render_offset_top + prev.height,
        cur.render_offset_top,
        ("image %d should start at prev.offset+prev.height, got offset=%d (expected %d)")
          :format(i, cur.render_offset_top,
                  prev.render_offset_top + prev.height))
    end
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/ov_a.png"); os.remove("/tmp/ov_b.png"); os.remove("/tmp/ov_c.png")
  end)

  it("multi-image stack: total reserved height equals sum of per-image heights", function()
    -- Regression guard for "images cover the next cell". The cumulative
    -- height returned by `Image:render` is what the UI uses to anchor the
    -- next cell below the image stack — if it diverges from the sum of
    -- per-image heights, content gets covered.
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
    -- Per-image heights are passed as opts.height; sum must equal `total`.
    local h_sum = 0
    for _, r in ipairs(recorded) do h_sum = h_sum + r.opts.height end
    assert.equals(h_sum, total)
    require("mercury.notebook").detach(buf)
    os.remove("/tmp/ms_a.png"); os.remove("/tmp/ms_b.png")
  end)
end)
