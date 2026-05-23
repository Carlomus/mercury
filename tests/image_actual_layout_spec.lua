-- End-to-end measurement test for image layout. Rather than asserting
-- properties of build_virt_lines or image:render in isolation, this
-- spec drives a full render() through ui.lua and INSPECTS THE BUFFER
-- afterwards — extmark contents, virt_lines structure, and the image
-- opts that image.nvim received — to verify that visually, the image
-- lands in its reserved row.
--
-- This exists because reasoning about screenpos + render_offset_top
-- semantics produced two incorrect "fixes" already. Tests must
-- MEASURE, not assume.

local Notebook = require("mercury.notebook")
local UI = require("mercury.ui")
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

-- Inspect the cell's output extmark and dump a normalized view:
--   { virt_lines = { "<text of virt_line[0]>", "<text of virt_line[1]>", ... },
--     image_calls = { { offset, x }, ... },
--     anchor_row = <row of body_end> }
local function inspect(buf, recorded)
  local Notebook_mod = require("mercury.notebook")
  local ns_out = Notebook_mod.ns("output")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns_out, 0, -1, { details = true })
  local extmark_summary = {}
  for _, m in ipairs(marks) do
    local row = m[2]
    local details = m[4] or {}
    local lines_dump = {}
    if details.virt_lines then
      for _, vline in ipairs(details.virt_lines) do
        local s = ""
        for _, chunk in ipairs(vline) do
          if type(chunk[1]) == "table" then
            for _, sub in ipairs(chunk) do s = s .. sub[1] end
          else
            s = s .. chunk[1]
          end
        end
        lines_dump[#lines_dump + 1] = s
      end
    end
    extmark_summary[#extmark_summary + 1] = { row = row, virt_lines = lines_dump }
  end
  local image_calls = {}
  for _, r in ipairs(recorded) do
    image_calls[#image_calls + 1] = {
      offset = r.opts.render_offset_top,
      x = r.opts.x,
      y = r.opts.y,
      width = r.opts.width,
      padding = r.opts.with_virtual_padding,
    }
  end
  return { extmarks = extmark_summary, image_calls = image_calls }
end

describe("ACTUAL rendered layout — measure, don't assume", function()
  local fake_image_mod
  local recorded
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
    require("mercury.config").setup()
  end)
  after_each(function()
    package.loaded["image"] = nil
    package.loaded["mercury.image"] = nil
  end)

  local function _render_with(items, extract_images_result, image_paths)
    -- Write each image to disk so compute_dimensions can read pixel dims.
    for path, data in pairs(image_paths or {}) do
      Util.write_file(path, data)
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=measure01", "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    nb:set_renderer(UI.new(nb))
    local out = nb:ensure_output(nb.cells[1].id)
    out.status = "ok"; out.exec_count = 1; out.ms = 42
    out.items = items
    local Output_mod = require("mercury.output")
    local orig = Output_mod.extract_images
    Output_mod.extract_images = function() return extract_images_result end
    nb._renderer:render()
    Output_mod.extract_images = orig
    return buf, nb, inspect(buf, recorded)
  end

  it("DUMP: single image — show me virt_lines and image offset", function()
    local buf, nb, info = _render_with(
      { { type = "display_data", data = { ["image/png"] = "a" } } },
      { { kind = "png", path = "/tmp/measureA.png", hash = "msa1", item_index = 1 } },
      { ["/tmp/measureA.png"] = fake_png(400, 300) })

    print("\n=== SINGLE IMAGE DUMP ===")
    print("Cell body_end (anchor row, 0-indexed):", nb:cell_anchor_row(nb.cells[1]))
    print(("Extmarks (%d total):"):format(#info.extmarks))
    for i, m in ipairs(info.extmarks) do
      print(("  extmark[%d] anchored at row %d, %d virt_lines:")
        :format(i, m.row, #m.virt_lines))
      for j, l in ipairs(m.virt_lines) do
        print(("    virt_line[%d] = %q"):format(j - 1, l))
      end
    end
    print(("Image calls (%d total):"):format(#info.image_calls))
    for i, c in ipairs(info.image_calls) do
      print(("  image[%d]: y=%d offset_top=%d x=%d width=%d padding=%s")
        :format(i, c.y, c.offset, c.x, c.width, tostring(c.padding)))
    end
    -- HYPOTHESIS to verify: image's first painted row = body_end + 1 + offset
    --   because virt_line[K] sits at body_end_screen + (K + 1). The image
    --   should land at virt_line[K] where K = offset - 1.
    --   For pill_rows=1, no text: pill at virt_line[0], first image blank
    --   at virt_line[1]. Image should land at virt_line[1], so offset = 2.
    local first_image_offset = info.image_calls[1].offset
    -- Where does that put us in the virt_lines stack? virt_line index K = offset - 1.
    local landing_idx = first_image_offset - 1
    print(("\n  → IMAGE LANDS AT virt_line[%d] = %q\n")
      :format(landing_idx, info.extmarks[1].virt_lines[landing_idx + 1] or "<out of bounds>"))
    -- Assert the image is NOT on a pill / text row.
    local landing_text = info.extmarks[1].virt_lines[landing_idx + 1] or ""
    assert.is_false(landing_text:match("Out") ~= nil,
      ("REGRESSION: image lands on pill row (virt_line[%d] = %q)")
        :format(landing_idx, landing_text))
    Notebook.detach(buf)
    os.remove("/tmp/measureA.png")
  end)

  it("DUMP: image + text + image — show me the interleave", function()
    local buf, nb, info = _render_with(
      {
        { type = "display_data", data = { ["image/png"] = "a" } },
        { type = "stream", name = "stdout", text = "middle\n" },
        { type = "display_data", data = { ["image/png"] = "b" } },
      },
      {
        { kind = "png", path = "/tmp/measureB.png", hash = "msb1", item_index = 1 },
        { kind = "png", path = "/tmp/measureC.png", hash = "msb2", item_index = 3 },
      },
      {
        ["/tmp/measureB.png"] = fake_png(400, 200),
        ["/tmp/measureC.png"] = fake_png(400, 250),
      })

    print("\n=== IMG + TEXT + IMG DUMP ===")
    print("Cell body_end (anchor row, 0-indexed):", nb:cell_anchor_row(nb.cells[1]))
    print(("Extmarks (%d total):"):format(#info.extmarks))
    for i, m in ipairs(info.extmarks) do
      print(("  extmark[%d] anchored at row %d, %d virt_lines:")
        :format(i, m.row, #m.virt_lines))
      for j, l in ipairs(m.virt_lines) do
        local marker = (l == "" or l:match("^%s*$")) and "[blank]" or string.format("%q", l)
        print(("    virt_line[%d] = %s"):format(j - 1, marker))
      end
    end
    print(("Image calls (%d total):"):format(#info.image_calls))
    for i, c in ipairs(info.image_calls) do
      print(("  image[%d]: y=%d offset_top=%d x=%d width=%d padding=%s")
        :format(i, c.y, c.offset, c.x, c.width, tostring(c.padding)))
    end
    -- Each image's landing virt_line index = offset - 1. Print it.
    for i, c in ipairs(info.image_calls) do
      local landing_idx = c.offset - 1
      local landing_text = info.extmarks[1].virt_lines[landing_idx + 1] or "<OOB>"
      print(("  → image[%d] lands at virt_line[%d] = %q")
        :format(i, landing_idx, landing_text))
    end
    print("")
    Notebook.detach(buf)
    os.remove("/tmp/measureB.png"); os.remove("/tmp/measureC.png")
  end)
end)
