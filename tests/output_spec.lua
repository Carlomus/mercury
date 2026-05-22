local Output = require("mercury.output")

describe("output rendering", function()
  it("builds a status pill for ok status", function()
    local virt = Output.build_virt_lines({
      status = "ok", exec_count = 7, ms = 142, items = {},
    }, {})
    assert.is_true(#virt >= 1)
    local first = virt[1][1][1]
    assert.matches("Out%[7%]", first)
    assert.matches("142 ms", first)
  end)

  it("renders stream output as virt lines", function()
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "stream", name = "stdout", text = "hello\nworld\n" },
      },
    }, { show_status_pill = false })
    -- Two lines plus final newline -> 2 chunks (split_lines drops trailing empty)
    local texts = {}
    for _, vline in ipairs(virt) do texts[#texts + 1] = vline[1][1] end
    assert.same({ "hello", "world" }, texts)
  end)

  it("renders error tracebacks", function()
    local virt = Output.build_virt_lines({
      status = "error", items = {
        {
          type = "error", ename = "ValueError", evalue = "bad",
          traceback = { "  File ...", "ValueError: bad" },
        },
      },
    }, { show_status_pill = false })
    assert.matches("ValueError: bad", virt[1][1][1])
  end)

  it("collapses output when requested", function()
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "stream", name = "stdout", text = "a\nb\nc\n" },
      },
    }, { show_status_pill = false, collapsed = true })
    -- Only the collapsed marker.
    assert.equals(1, #virt)
    assert.matches("collapsed", virt[1][1][1])
  end)

  it("truncates with max_preview_lines", function()
    local items = {}
    table.insert(items, { type = "stream", name = "stdout", text = "1\n2\n3\n4\n5\n" })
    local virt = Output.build_virt_lines({
      status = "ok", items = items,
    }, { show_status_pill = false, max_preview_lines = 2 })
    assert.equals(3, #virt)  -- 2 lines + "hidden" marker
    assert.matches("hidden", virt[3][1][1])
  end)

  it("computes png dimensions from header", function()
    -- Tiny 1x1 PNG
    local png = "\137PNG\r\n\26\n"
        .. string.char(0, 0, 0, 13)  -- IHDR length
        .. "IHDR"
        .. string.char(0, 0, 0, 1)   -- width
        .. string.char(0, 0, 0, 1)   -- height
        .. string.char(8, 6, 0, 0, 0)
    local w, h = Output.png_dimensions(png)
    assert.equals(1, w)
    assert.equals(1, h)
  end)

  it("computes jpeg dimensions from SOF marker", function()
    -- Synthetic JPEG: SOI + APP0 (skip-able marker) + SOF0 + EOI.
    --   SOF0 payload: precision(1=8) + height(2) + width(2) + components(1)
    --   width = 320, height = 200
    local function be16(n)
      return string.char(math.floor(n / 256) % 256, n % 256)
    end
    local app0_payload = "JFIF\0" .. string.char(1, 1, 0, 0, 0x48, 0, 0x48, 0, 0)
    local app0_seg = "\xFF\xE0" .. be16(2 + #app0_payload) .. app0_payload
    local sof_payload = string.char(8) .. be16(200) .. be16(320) .. string.char(1)
    local sof_seg = "\xFF\xC0" .. be16(2 + #sof_payload) .. sof_payload
    local jpeg = "\xFF\xD8" .. app0_seg .. sof_seg .. "\xFF\xD9"
    local w, h = Output.jpeg_dimensions(jpeg)
    assert.equals(320, w)
    assert.equals(200, h)
    -- Returns nil for a non-JPEG.
    assert.is_nil(Output.jpeg_dimensions("not a jpeg"))
    -- image_dimensions dispatches by kind.
    local w2, h2 = Output.image_dimensions("jpeg", jpeg)
    assert.equals(320, w2); assert.equals(200, h2)
    assert.is_nil(Output.image_dimensions("png", jpeg))
  end)

  it("image row height — min 1 row (no padding for tiny images)", function()
    -- 16x16 image, cell 8x16: 1 row natural. Old behavior clamped to 4
    -- (wasted 3 rows of empty padding under tiny icons).
    local rows = Output.image_row_height(16, 16, 2, 8, 16, 40)
    assert.equals(1, rows)
  end)

  it("clamps image row height to max", function()
    local rows = Output.image_row_height(1000, 100000, 80, 8, 16, 24)
    assert.equals(24, rows)
  end)

  it("svg_dimensions reads literal width / height attributes", function()
    -- Most matplotlib-emitted SVGs have explicit width/height; we should
    -- read them so the natural-size clamp applies the same way it does
    -- for PNG (a tiny SVG icon shouldn't reserve 40 rows of empty space).
    local w, h = Output.svg_dimensions(
      [[<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" ]]
      .. [[width="200" height="100"><rect/></svg>]])
    assert.equals(200, w)
    assert.equals(100, h)
  end)

  it("svg_dimensions parses px / pt units on width / height", function()
    -- "px" strips trivially (SVG default is px for unitless values).
    local w, h = Output.svg_dimensions(
      [[<svg width="64px" height="32px"></svg>]])
    assert.equals(64, w)
    assert.equals(32, h)
    -- "pt" converts at 96 DPI (1pt = 4/3 px). Matplotlib emits pt; treating
    -- pt as px (the old bug) made plots render ~25% too small. Audit P1.
    local w2, h2 = Output.svg_dimensions(
      [[<svg width="120pt" height="60pt"></svg>]])
    assert.equals(160, w2)  -- 120 * 4 / 3
    assert.equals(80, h2)   -- 60 * 4 / 3
  end)

  it("svg_dimensions falls back to viewBox for unknown absolute units", function()
    -- "in", "cm", "em", etc. aren't units we want to silently approximate
    -- — viewBox is the authoritative answer when the absolute unit is
    -- something we can't convert deterministically.
    local w, h = Output.svg_dimensions(
      [[<svg width="2in" height="1in" viewBox="0 0 192 96"></svg>]])
    assert.equals(192, w)
    assert.equals(96, h)
  end)

  it("svg_dimensions falls back to viewBox when width is %", function()
    -- katex and some chart libraries emit width="100%" — that's relative
    -- to a viewport we don't have, so fall through to the viewBox.
    local w, h = Output.svg_dimensions(
      [[<svg width="100%" height="100%" viewBox="0 0 300 150"></svg>]])
    assert.equals(300, w)
    assert.equals(150, h)
  end)

  it("svg_dimensions uses viewBox when width / height are missing", function()
    local w, h = Output.svg_dimensions(
      [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600"/>]])
    assert.equals(800, w)
    assert.equals(600, h)
  end)

  it("svg_dimensions returns nil when nothing is resolvable", function()
    -- No width/height/viewBox at all — caller's fallback applies
    -- (full available width + max-rows reservation).
    local w, h = Output.svg_dimensions([[<svg xmlns="x"></svg>]])
    assert.is_nil(w)
    assert.is_nil(h)
    -- Junk input.
    assert.is_nil(Output.svg_dimensions(""))
    assert.is_nil(Output.svg_dimensions("not an svg"))
  end)

  it("image_dimensions dispatches svg the same way as png / jpeg", function()
    local w, h = Output.image_dimensions("svg",
      [[<svg width="40" height="20"/>]])
    assert.equals(40, w)
    assert.equals(20, h)
  end)

  it("converts output items to plain text", function()
    local lines = Output.to_plain_text({
      status = "ok", exec_count = 3, ms = 50,
      items = {
        { type = "stream", name = "stdout", text = "hi\nthere\n" },
        { type = "execute_result", data = { ["text/plain"] = "42" } },
      },
    })
    assert.matches("Out%[3%]", lines[1])
    assert.equals("hi", lines[2])
    assert.equals("there", lines[3])
    assert.equals("42", lines[4])
  end)

  it("mime preference order — images > latex > md > plain > html", function()
    -- Pin the deliberate divergence from Jupyter Lab so a refactor can't
    -- silently flip the order. SPEC documents this as intentional.
    assert.equals("image/png", Output.pick_mime({
      ["image/png"] = "x", ["text/html"] = "<table>",
      ["text/plain"] = "table-repr",
    }))
    assert.equals("image/jpeg", Output.pick_mime({
      ["image/jpeg"] = "x", ["text/plain"] = "fallback",
    }))
    assert.equals("image/svg+xml", Output.pick_mime({
      ["image/svg+xml"] = "<svg/>", ["text/html"] = "<svg/>",
    }))
    assert.equals("text/latex", Output.pick_mime({
      ["text/latex"] = "$x$", ["text/plain"] = "x",
    }))
    -- pandas DataFrame case: HTML + plain. Mercury prefers plain.
    assert.equals("text/plain", Output.pick_mime({
      ["text/html"] = "<table>", ["text/plain"] = "table-repr",
    }))
    -- HTML is last resort.
    assert.equals("text/html", Output.pick_mime({
      ["text/html"] = "<p>only me</p>",
    }))
  end)

  it("mime preference fallback prefers text/* over unknown application/* (H8)", function()
    -- Plotly emits `application/vnd.plotly.v1+json` alongside `text/plain`.
    -- Pre-fix, the alphabetical fallback picked the application/* key
    -- (sorts before text/plain) and rendered the JSON blob as Comment
    -- text. With H8, an unknown non-text mime loses to any text/*.
    assert.equals("text/plain", Output.pick_mime({
      ["application/vnd.plotly.v1+json"] = "{}",
      ["text/plain"] = "Figure(...)",
    }))
    -- If there's no text/* either, fall back to the alphabetically-first
    -- mime (deterministic).
    assert.equals("application/json", Output.pick_mime({
      ["application/json"] = "{}",
      ["application/vnd.foo+json"] = "{}",
    }))
  end)

  it("pick_mime returns nil for nil/empty data", function()
    assert.is_nil(Output.pick_mime(nil))
    assert.is_nil(Output.pick_mime({}))
  end)

  ---------------------------------------------------------------------------
  -- Status pill rules (SPEC lines 430-435)
  ---------------------------------------------------------------------------

  it("idle status with no exec_count and no positive ms shows NO pill", function()
    -- A freshly-created code cell that never ran. The pill `▶ Out  0 ms`
    -- would be incoherent — explicitly suppress it.
    local virt = Output.build_virt_lines({
      status = "idle", items = {},
    }, {})
    -- No pill, no items → empty virt_lines.
    assert.equals(0, #virt)
  end)

  it("idle status with exec_count from a loaded .ipynb shows pill with [N], no ms", function()
    -- ms=0 means "unknown" (not "instant"); don't render "0 ms".
    local virt = Output.build_virt_lines({
      status = "idle", exec_count = 5, ms = 0, items = {},
    }, {})
    local first = virt[1][1][1]
    assert.matches("Out%[5%]", first)
    assert.is_nil(first:match("0 ms"),
      "ms=0 must not render as 0 ms")
  end)

  it("running status renders the ⏳ pill with lowercase 'running…'", function()
    local virt = Output.build_virt_lines({
      status = "running", items = {},
    }, {})
    assert.matches("running…", virt[1][1][1])
  end)

  it("queued status renders the ⏸ pill with 'queued'", function()
    local virt = Output.build_virt_lines({
      status = "queued", items = {},
    }, {})
    assert.matches("queued", virt[1][1][1])
  end)

  it("killed status renders the killed pill", function()
    local virt = Output.build_virt_lines({
      status = "killed", items = {},
    }, {})
    assert.matches("killed", virt[1][1][1])
  end)

  it("error status with ename and evalue defaults", function()
    -- A bare error item with no ename/evalue still produces something
    -- legible (defaults "Error" / "").
    local virt = Output.build_virt_lines({
      status = "error", items = {
        { type = "error" },  -- no fields at all
      },
    }, { show_status_pill = false })
    -- The default "Error" name with empty evalue.
    assert.matches("Error", virt[1][1][1])
  end)

  it("unknown status does not crash; emits no pill (defensive)", function()
    -- A future status string we don't know about must not crash. The
    -- explicit pill branches only handle the documented statuses; an
    -- unrecognized one silently skips the pill (rather than rendering a
    -- meaningless one). This is the safe degraded behavior.
    local ok, virt = pcall(Output.build_virt_lines, {
      status = "weirdfuture", exec_count = 3, ms = 50, items = {},
    }, {})
    assert.is_true(ok, "unknown status must not raise")
    -- No items either, so virt is empty.
    assert.equals(0, #virt)
  end)

  ---------------------------------------------------------------------------
  -- html_to_text (private; we exercise via text/html mime path)
  ---------------------------------------------------------------------------

  it("text/html mime decodes named entities", function()
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data",
          data = { ["text/html"] = "x &lt; y &amp; z &gt; w" } },
      },
    }, { show_status_pill = false })
    local rendered = virt[1][1][1]
    assert.matches("x < y & z > w", rendered)
  end)

  it("text/html mime decodes numeric entities (decimal and hex)", function()
    -- &#8230; → … (decimal). &#x2014; → — (hex).
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data",
          data = { ["text/html"] = "a &#8230; b &#x2014; c" } },
      },
    }, { show_status_pill = false })
    local rendered = virt[1][1][1]
    assert.matches("…", rendered)
    assert.matches("—", rendered)
  end)

  it("text/html &amp; ordering: &amp;lt; decodes to &lt;, not <", function()
    -- LOAD-BEARING invariant: &amp; must decode LAST so that &amp;lt; goes
    -- through one level of decode (→ &lt;) instead of two (→ <). A regression
    -- that re-orders the gsub calls would silently break this.
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data",
          data = { ["text/html"] = "&amp;lt;raw&amp;gt;" } },
      },
    }, { show_status_pill = false })
    -- Must contain literal `&lt;` and `&gt;` AFTER one round of decode.
    assert.matches("&lt;raw&gt;", virt[1][1][1])
  end)

  it("text/html decodes &quot; and &apos;", function()
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data",
          data = { ["text/html"] = "&quot;a&apos;b" } },
      },
    }, { show_status_pill = false })
    assert.matches('"a\'b', virt[1][1][1])
  end)

  it("text/html replaces <br> and </p> with newlines and strips other tags", function()
    -- The build_virt_lines turns each line into its own virt entry; the
    -- decoder normalizes <br> and </p> to \n.
    local virt = Output.build_virt_lines({
      status = "ok", items = {
        { type = "display_data",
          data = { ["text/html"] = "<p>one</p><p>two</p>" } },
      },
    }, { show_status_pill = false })
    -- Expect at least 2 lines (one and two on separate virt entries).
    assert.is_true(#virt >= 2)
  end)

  it("invalid numeric entity does not crash and emits empty", function()
    -- &#abc; isn't a valid decimal; tonumber returns nil; nr2char in pcall
    -- → empty substitution. The point is the function doesn't raise.
    local ok = pcall(function()
      Output.build_virt_lines({
        status = "ok", items = {
          { type = "display_data",
            data = { ["text/html"] = "x &#zzz; y" } },
        },
      }, { show_status_pill = false })
    end)
    assert.is_true(ok)
  end)

  ---------------------------------------------------------------------------
  -- extract_images signature gating
  ---------------------------------------------------------------------------

  it("extract_images skips PNG output without a valid PNG signature", function()
    -- A corrupt base64 input would decode to non-PNG bytes and (pre-fix)
    -- would land in the content-addressed cache, persisting for 30 days.
    -- The signature gate must skip the image entirely. The output still
    -- renders via fallback mimes if present.
    local bad_b64 = "QUFBQQ==" -- decodes to "AAAA" — no PNG header.
    local images = Output.extract_images({
      items = {
        { type = "display_data",
          data = { ["image/png"] = bad_b64 } },
      },
    })
    assert.equals(0, #images,
      "extract_images must skip output whose decoded bytes don't start with PNG signature")
  end)

  it("extract_images accepts a valid PNG (1x1 transparent)", function()
    local valid_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
    local images = Output.extract_images({
      items = {
        { type = "display_data",
          data = { ["image/png"] = valid_b64 } },
      },
    })
    assert.equals(1, #images)
    assert.equals("png", images[1].kind)
    assert.is_truthy(vim.loop.fs_stat(images[1].path))
  end)

  it("extract_images skips JPEG output without a valid JPEG SOI marker", function()
    -- "AAAA" again — not a JPEG.
    local images = Output.extract_images({
      items = {
        { type = "display_data",
          data = { ["image/jpeg"] = "QUFBQQ==" } },
      },
    })
    assert.equals(0, #images)
  end)
end)
