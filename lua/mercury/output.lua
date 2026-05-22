-- Render an output state to virt_lines and (optionally) inline images.
-- Pure-ish: rendering math is testable without nvim's image plugin.

local Ansi = require("mercury.ansi")
local B64 = require("mercury.base64")
local Util = require("mercury.util")

local M = {}

-- Coerce a mimebundle value to a string for display. nbformat allows three
-- shapes for `data["<mime>"]`: a string, an array of strings (multiline),
-- or any JSON object/array (e.g., for `application/json`). The first two
-- are common; the third is rare but real (Plotly, Vega-Lite, JSON-typed
-- repr outputs). We must not crash on those — render them as pretty JSON
-- instead.
local function _value_to_string(val)
  if val == nil then return "" end
  if type(val) == "string" then return val end
  if type(val) == "table" then
    -- Array of strings: join (we already do this in normalize, but renderers
    -- can be called on raw decoded data too).
    local n = #val
    if n > 0 then
      local all_strings = true
      for i = 1, n do
        if type(val[i]) ~= "string" then all_strings = false; break end
      end
      if all_strings then return table.concat(val, "") end
    end
    -- Dict-like or mixed: encode as JSON. pcall in case the value contains
    -- something vim.json can't serialize.
    local ok, enc = pcall(vim.json.encode, val)
    if ok then return enc end
    return tostring(val)
  end
  return tostring(val)
end

local STATUS_TEXT = {
  idle    = { glyph = "",   hl = "MercuryPillIdle"    },
  running = { glyph = "⏳", hl = "MercuryPillRunning" },
  queued  = { glyph = "⏸",  hl = "MercuryPillQueued"  },
  ok      = { glyph = "✓",  hl = "MercuryPillOk"      },
  error   = { glyph = "✗",  hl = "MercuryPillError"   },
  killed  = { glyph = "󱚢",  hl = "MercuryPillError"   },
}

-- Widgets are explicitly out-of-scope (SPEC Non-goals + Invariant 34).
-- Recognising the mime up front avoids two bad fallbacks: (a) pick_mime
-- falling into the unknown-application/* branch and rendering a base64
-- blob, and (b) build_virt_lines hitting `[empty output]` when a kernel
-- emits a widget without a `text/plain` companion repr.
local WIDGET_MIME = "application/vnd.jupyter.widget-view+json"

local function pick_mime(data)
  if not data then return nil end
  -- Mime preference order — matches Jupyter Lab's rendermime ordering for the
  -- formats Mercury can render, with two deliberate divergences for a
  -- terminal UI:
  --
  --   1. text/plain ranks ABOVE text/html. Most rich `_repr_html_` outputs
  --      (pandas DataFrame, sklearn estimator, etc.) also emit a text/plain
  --      companion — our html→text path mangles tables, so we'd rather
  --      surface the plain repr than a flattened HTML version.
  --   2. image/svg+xml ranks ABOVE image/png (matches Jupyter Lab — SVG is
  --      sharper when both are present, as matplotlib commonly emits).
  --   3. text/markdown ranks ABOVE text/latex. Latex rasterizes to an image,
  --      which is heavy and loses interactivity; markdown styles inline via
  --      treesitter HL groups. Matches Jupyter Lab when both are present.
  --
  -- The remaining ordering inside image/* matches Jupyter Lab.
  for _, m in ipairs({
    "image/svg+xml", "image/png", "image/jpeg",
    "text/markdown", "text/latex",
    "text/plain", "text/html",
  }) do
    if data[m] then return m end
  end
  -- ipywidgets: explicit recognition so the renderer can emit a clear
  -- "[widget unsupported]" line instead of falling through to the
  -- unknown-mime branch.
  if data[WIDGET_MIME] then return WIDGET_MIME end
  -- Unknown-mime fallback. Prefer ANY text/* over unknown application/*
  -- (Plotly etc. emit `application/vnd.plotly.v1+json` alongside `text/plain`;
  -- alphabetical sort would pick the application/* binary blob).
  local text_keys, other_keys = {}, {}
  for k in pairs(data) do
    if type(k) == "string" and k:sub(1, 5) == "text/" then
      text_keys[#text_keys + 1] = k
    else
      other_keys[#other_keys + 1] = k
    end
  end
  table.sort(text_keys)
  table.sort(other_keys)
  if text_keys[1] then return text_keys[1] end
  if other_keys[1] then return other_keys[1] end
  return nil
end

M.pick_mime = pick_mime

-- HTML entity decoder. ORDER MATTERS: numeric / named entities decode first,
-- then &amp; LAST so that `&amp;lt;` collapses to literal `&lt;` (one round
-- of decode), not `<` (two rounds). A regression that re-orders this would
-- silently corrupt HTML-encoded user data containing escaped ampersands.
local function html_to_text(html)
  html = html or ""
  html = html:gsub("<[bB][rR]%s*/?>", "\n")
  html = html:gsub("</p>", "\n")
  html = html:gsub("<[^>]+>", "")
  -- Numeric entities (decimal &#NNN; and hex &#xHHH;).
  html = html:gsub("&#[xX](%x+);", function(h)
    local n = tonumber(h, 16)
    if not n then return "" end
    local ok, ch = pcall(vim.fn.nr2char, n)
    return ok and ch or ""
  end)
  html = html:gsub("&#(%d+);", function(d)
    local n = tonumber(d)
    if not n then return "" end
    local ok, ch = pcall(vim.fn.nr2char, n)
    return ok and ch or ""
  end)
  -- Named entities (except &amp; which goes last).
  html = html:gsub("&nbsp;", " ")
  html = html:gsub("&lt;", "<")
  html = html:gsub("&gt;", ">")
  html = html:gsub("&quot;", '"')
  html = html:gsub("&apos;", "'")
  html = html:gsub("&amp;", "&")
  return html
end

-- Build the text-only virtual lines for the output (no images).
-- Returns a list of virt_lines (each virt_line = list of {text, hl} chunks).
function M.build_virt_lines(out, opts)
  opts = opts or {}
  local lines = {}

  if opts.show_status_pill ~= false then
    local status = STATUS_TEXT[out.status] or STATUS_TEXT.idle
    local pill = {}
    if out.status == "running" then
      pill[#pill + 1] = { "⏳ running…", status.hl }
    elseif out.status == "queued" then
      pill[#pill + 1] = { "⏸ queued", status.hl }
    elseif out.status == "killed" then
      pill[#pill + 1] = { "󱚢 killed", status.hl }
    elseif out.status == "ok" or out.status == "error" or out.status == "idle" then
      local glyph = status.glyph
      local nstr = out.exec_count and ("[" .. tostring(out.exec_count) .. "]") or ""
      -- 0 is truthy in Lua; freshly loaded notebooks have ms=0 from the
      -- side-table default and shouldn't render "0 ms".
      local mstr = (out.ms and out.ms > 0) and (" " .. tostring(out.ms) .. " ms") or ""
      local gstr = (glyph and glyph ~= "") and (" " .. glyph) or ""
      -- Skip the pill entirely for never-run cells: nothing useful to show.
      if not (out.status == "idle" and nstr == "" and mstr == "") then
        pill[#pill + 1] = {
          ("▶ Out%s%s%s"):format(nstr, mstr, gstr),
          status.hl,
        }
      end
    end
    if #pill > 0 then lines[#lines + 1] = pill end
  end

  if opts.collapsed then
    lines[#lines + 1] = { { "  …  output collapsed", "Comment" } }
    return lines
  end

  -- Stream merging (SPEC Invariant 36): the side-table preserves the exact
  -- nbformat interleaving so round-trip is byte-stable, but visually we
  -- group consecutive same-name stream items into one block. A
  -- stdout/stderr/stdout interleave becomes "stdout block then stderr block
  -- then stdout block" in the buffer — matches Jupyter Lab. Walk items
  -- once and build a merged item list, then render.
  local items = {}
  for _, item in ipairs(out.items or {}) do
    if item.type == "stream" then
      local prev = items[#items]
      if prev and prev.type == "stream" and prev.name == (item.name or "stdout") then
        prev.text = (prev.text or "") .. (item.text or "")
      else
        items[#items + 1] = {
          type = "stream", name = item.name or "stdout", text = item.text or "",
        }
      end
    else
      items[#items + 1] = item
    end
  end

  -- LaTeX is rendered via image.nvim by extract_images(); but if rasterization
  -- *fails* mid-flight (pdflatex package missing, on-disk write fail, etc.),
  -- the rasterize call returns nil. We must not leave the cell with a "rendered
  -- below" placeholder and no image — fall back to raw source instead. SPEC
  -- Invariant 4 (LaTeX fallback). We discover failure by attempting the
  -- rasterize ourselves up-front: cheap, content-hash cached, and necessary so
  -- the renderer knows whether to show the placeholder.
  local function latex_renders(src)
    local ok, Latex = pcall(require, "mercury.latex")
    if not ok or not Latex.available() then return false end
    return Latex.rasterize(src) ~= nil
  end

  local body_lines = {}
  for _, item in ipairs(items) do
    if item.type == "stream" then
      local text = item.text or ""
      text = Ansi.strip(text)
      local hl = item.name == "stderr" and "ErrorMsg" or "Comment"
      for _, ln in ipairs(Util.split_lines(text)) do
        body_lines[#body_lines + 1] = { ln, hl }
      end
    elseif item.type == "error" then
      body_lines[#body_lines + 1] =
        { ("%s: %s"):format(item.ename or "Error", item.evalue or ""), "ErrorMsg" }
      for _, tb in ipairs(item.traceback or {}) do
        for _, ln in ipairs(Util.split_lines(Ansi.strip(tb))) do
          body_lines[#body_lines + 1] = { ln, "ErrorMsg" }
        end
      end
    elseif item.type == "display_data" or item.type == "execute_result" then
      local mime = pick_mime(item.data)
      if not mime then
        body_lines[#body_lines + 1] = { "[empty output]", "Comment" }
      elseif mime == WIDGET_MIME then
        -- ipywidgets are explicitly unsupported (SPEC Non-goals +
        -- Invariant 34). Render a single placeholder rather than the
        -- raw JSON blob; the kernel typically emits a `text/plain` repr
        -- alongside which picks_mime would have chosen first when present.
        body_lines[#body_lines + 1] = { "[widget unsupported]", "Comment" }
      elseif mime == "image/png" or mime == "image/jpeg" or mime == "image/svg+xml" then
        -- When image.nvim is available it renders the image inline below the
        -- virt_lines; in that case the placeholder is just noise. Show one
        -- only as a fallback when no image renderer is loaded.
        --
        -- If the image renderer is available but the per-item descriptor
        -- carries an `unavailable` flag (set by the image driver when the
        -- on-disk cached bytes have been evicted between extract and
        -- render), surface a clear text placeholder so the user knows why
        -- nothing is appearing inline. Without this, the cell shows a tiny
        -- (1-row) blank slot and the user has no diagnostic.
        local image_ok, Image = pcall(require, "mercury.image")
        if not image_ok or not Image.available() then
          body_lines[#body_lines + 1] = { ("[%s]"):format(mime), "Comment" }
        elseif item._mercury_image_unavailable then
          body_lines[#body_lines + 1] = {
            ("[%s: image bytes unavailable; re-execute the cell]"):format(mime),
            "Comment",
          }
        end
      elseif mime == "text/html" then
        local txt = html_to_text(_value_to_string(item.data["text/html"]))
        for _, ln in ipairs(Util.split_lines(txt)) do
          body_lines[#body_lines + 1] = { ln, "Comment" }
        end
      elseif mime == "text/latex" then
        if latex_renders(item.data[mime]) then
          body_lines[#body_lines + 1] = { "[text/latex (rendered below)]", "Comment" }
        else
          -- Fall through to raw source for both "no rasterizer available"
          -- and "rasterizer configured but failed" — matches SPEC contract
          -- ("If no rasterizer is available, the raw source is shown
          -- verbatim").
          for _, ln in ipairs(Util.split_lines(_value_to_string(item.data[mime]))) do
            body_lines[#body_lines + 1] = { ln, "Special" }
          end
        end
      elseif mime == "text/markdown" then
        -- text/markdown is styled via mercury.markdown_out, which applies
        -- the same treesitter highlight groups (@markup.heading.N,
        -- @markup.strong, @markup.emphasis, @markup.raw.markdown_inline,
        -- @markup.list.markdown, @markup.quote.markdown) that a
        -- markdown-aware theme — render-markdown.nvim included — already
        -- styles. SPEC § "Markdown rendering" + Invariant 33.
        --
        -- Why not just relay the source to render-markdown.nvim: that
        -- plugin styles real buffer lines via extmark virt_text + conceal,
        -- and those decorations CANNOT be relayed across buffers as
        -- virt_lines. We render in-place with the same HL group names so
        -- the visual result is consistent.
        local MdOut = require("mercury.markdown_out")
        local md_chunks = MdOut.chunks(_value_to_string(item.data[mime]))
        if #md_chunks == 0 then
          -- Empty markdown payload: keep a placeholder line so the cell
          -- isn't visually empty.
          body_lines[#body_lines + 1] = { "", "MercuryMarkdownOut" }
        else
          for _, line_chunks in ipairs(md_chunks) do
            -- body_lines is a list of {text, hl} chunks (one per logical
            -- output line) — flatten the multi-chunk lines by emitting
            -- the first chunk as the line entry and pushing the rest as
            -- *additional* same-line chunks via the caller's virt_lines
            -- packing below. Since body_lines[i] is shaped as a single
            -- {text, hl} chunk pair (later wrapped in a virt_line by the
            -- final loop), we collapse multi-chunk markdown lines into a
            -- single concatenated chunk-list and stash a flag for the
            -- packer to detect.
            body_lines[#body_lines + 1] = line_chunks
          end
        end
      else
        for _, ln in ipairs(Util.split_lines(_value_to_string(item.data[mime]))) do
          body_lines[#body_lines + 1] = { ln, "Comment" }
        end
      end
    end
  end

  local cap = opts.max_preview_lines or 9999
  local n = math.min(cap, #body_lines)
  for i = 1, n do
    -- body_lines entries are one of two shapes:
    --   (a) single chunk `{ "text", "hl" }`  — most output types push this
    --   (b) multi-chunk line `{ {t1,h1}, {t2,h2}, ... }` — markdown lines
    --       carry inline styling spans and arrive pre-shaped.
    -- Detect by checking whether the first element is itself a table.
    local entry = body_lines[i]
    if type(entry[1]) == "table" then
      lines[#lines + 1] = entry
    else
      lines[#lines + 1] = { entry }
    end
  end
  if #body_lines > n then
    lines[#lines + 1] =
      { { ("  … %d lines hidden"):format(#body_lines - n), "Comment" } }
  end
  return lines
end

-- Get just the plain text of an output (for copy / scratch view). The
-- surface here MUST mirror what `build_virt_lines` shows on screen —
-- including the status pill, [empty output] placeholders, and the
-- formatting rules around exec_count / ms suppression. SPEC Invariant 54.
function M.to_plain_text(out)
  local lines = {}
  -- Status-pill line, matching build_virt_lines' suppression rules:
  --   * idle + no exec_count + ms <= 0 ⇒ no pill (fresh, never-run cell)
  --   * killed/running/queued ⇒ a status word
  --   * ok/error ⇒ "Out[N]  M ms  ✓" with "M ms" omitted when ms<=0
  if out.status == "running" then
    lines[#lines + 1] = "running…"
  elseif out.status == "queued" then
    lines[#lines + 1] = "queued"
  elseif out.status == "killed" then
    lines[#lines + 1] = "killed"
  elseif out.status == "ok" or out.status == "error" then
    local n = out.exec_count and ("[" .. tostring(out.exec_count) .. "]") or ""
    local ms = (out.ms and out.ms > 0) and (tostring(out.ms) .. " ms") or ""
    local glyph = (out.status == "ok") and "✓" or "✗"
    local parts = { "Out" .. n }
    if ms ~= "" then parts[#parts + 1] = ms end
    parts[#parts + 1] = glyph
    lines[#lines + 1] = table.concat(parts, "  ")
  elseif out.status == "idle"
      and (out.exec_count or (out.ms and out.ms > 0)) then
    -- Loaded-from-disk cell with execution_count set: show "Out[N]" with
    -- no ms (ms=0 means "unknown", not "instant"). Matches inline render.
    local n = out.exec_count and ("[" .. tostring(out.exec_count) .. "]") or ""
    lines[#lines + 1] = "Out" .. n
  end
  for _, item in ipairs(out.items or {}) do
    if item.type == "stream" then
      for _, ln in ipairs(Util.split_lines(Ansi.strip(item.text or ""))) do
        lines[#lines + 1] = ln
      end
    elseif item.type == "error" then
      lines[#lines + 1] = ("%s: %s"):format(item.ename or "", item.evalue or "")
      for _, tb in ipairs(item.traceback or {}) do
        for _, ln in ipairs(Util.split_lines(Ansi.strip(tb))) do
          lines[#lines + 1] = ln
        end
      end
    elseif item.type == "display_data" or item.type == "execute_result" then
      local mime = pick_mime(item.data)
      if not mime then
        -- Mirror build_virt_lines: emit the same placeholder for an output
        -- with no recognizable mime payload.
        lines[#lines + 1] = "[empty output]"
      elseif mime == WIDGET_MIME then
        lines[#lines + 1] = "[widget unsupported]"
      elseif mime == "text/html" then
        local txt = html_to_text(_value_to_string(item.data[mime]))
        for _, ln in ipairs(Util.split_lines(txt)) do lines[#lines + 1] = ln end
      elseif mime == "text/latex" then
        for _, ln in ipairs(Util.split_lines(_value_to_string(item.data[mime]))) do
          lines[#lines + 1] = ln
        end
      elseif mime:sub(1, 5) == "text/"
          or mime == "application/json"
          or mime:find("%+json$") then
        local s = _value_to_string(item.data[mime])
        for _, ln in ipairs(Util.split_lines(s)) do lines[#lines + 1] = ln end
      else
        local raw = item.data[mime]
        local s = type(raw) == "string" and raw or _value_to_string(raw)
        lines[#lines + 1] = ("[%s, %d bytes]"):format(mime, #s)
      end
    end
  end
  return lines
end

-- ---------- image extraction ----------
-- Extract images from output items and return descriptors + content hash.
-- Each descriptor: { kind = "png"|"svg", path = cached_file, hash = sha256 }.
-- text/latex outputs are rasterized lazily (cached on disk) so math renders
-- inline like in VS Code. Images are written to a shared cache keyed by
-- content hash, so re-renders don't pile up new tempfiles per session.
local IMAGE_CACHE_DIR = vim.fn.stdpath("cache") .. "/mercury_images"
local function _ensure_image_cache()
  if vim.fn.isdirectory(IMAGE_CACHE_DIR) == 0 then
    vim.fn.mkdir(IMAGE_CACHE_DIR, "p")
  end
end

function M.extract_images(out)
  local images = {}
  for i, item in ipairs(out.items or {}) do
    if item.type == "display_data" or item.type == "execute_result" then
      local data = item.data or {}
      if data["image/png"] then
        -- B64 payloads in nbformat may legitimately be either a string OR a
        -- list of strings (the array-of-string multilineString form). Coerce
        -- defensively before decoding.
        local png_b64 = _value_to_string(data["image/png"])
        local bin = B64.decode(png_b64)
        -- Signature gate: a corrupt/empty payload must not land in the
        -- content-addressed cache (where it would persist for 30 days).
        if type(bin) == "string" and bin:sub(1, 8) == "\137PNG\r\n\26\n" then
          local hash = Util.hash(bin)
          _ensure_image_cache()
          local path = IMAGE_CACHE_DIR .. "/" .. hash:sub(1, 16) .. ".png"
          if not vim.loop.fs_stat(path) then
            Util.write_file(path, bin)
          else
            Util.touch(path)   -- mark hit so age-based GC doesn't evict
          end
          images[#images + 1] = { kind = "png", path = path, hash = hash, item_index = i }
        end
      elseif data["image/jpeg"] then
        local jpg_b64 = _value_to_string(data["image/jpeg"])
        local bin = B64.decode(jpg_b64)
        if type(bin) == "string" and #bin >= 2
          and bin:byte(1) == 0xFF and bin:byte(2) == 0xD8 then
          local hash = Util.hash(bin)
          _ensure_image_cache()
          local path = IMAGE_CACHE_DIR .. "/" .. hash:sub(1, 16) .. ".jpg"
          if not vim.loop.fs_stat(path) then
            Util.write_file(path, bin)
          else
            Util.touch(path)
          end
          images[#images + 1] = { kind = "jpeg", path = path, hash = hash, item_index = i }
        end
      elseif data["image/svg+xml"] then
        local svg = data["image/svg+xml"]
        if type(svg) == "table" then svg = table.concat(svg, "") end
        local hash = Util.hash(svg)
        _ensure_image_cache()
        local path = IMAGE_CACHE_DIR .. "/" .. hash:sub(1, 16) .. ".svg"
        if not vim.loop.fs_stat(path) then
          Util.write_file(path, svg)
        else
          Util.touch(path)
        end
        images[#images + 1] = { kind = "svg", path = path, hash = hash, item_index = i }
      elseif data["text/latex"] then
        local ok, Latex = pcall(require, "mercury.latex")
        if ok and Latex.available() then
          local path = Latex.rasterize(data["text/latex"])
          if path then
            local kind = path:sub(-4) == ".svg" and "svg" or "png"
            local data_bytes = Util.read_file(path) or ""
            local hash = Util.hash(data_bytes)
            images[#images + 1] = { kind = kind, path = path, hash = hash, item_index = i }
          end
        end
      end
    end
  end
  return images
end

-- Compute PNG dimensions from the IHDR chunk. Returns w, h or nil.
function M.png_dimensions(bytes)
  if not bytes or #bytes < 24 then return nil end
  if bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
  local function be32(s)
    local b1, b2, b3, b4 = s:byte(1, 4)
    return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
  end
  local w = be32(bytes:sub(17, 20))
  local h = be32(bytes:sub(21, 24))
  return w, h
end

-- Compute JPEG dimensions by walking marker segments to the first SOFn
-- (Start Of Frame: baseline 0xC0, extended 0xC1, progressive 0xC2, etc.).
-- The SOF segment payload starts with: precision(1) + height(2) + width(2),
-- big-endian. Returns w, h or nil if the file isn't a JPEG.
function M.jpeg_dimensions(bytes)
  if not bytes or #bytes < 4 then return nil end
  -- SOI marker.
  if bytes:byte(1) ~= 0xFF or bytes:byte(2) ~= 0xD8 then return nil end
  local i = 3
  local n = #bytes
  while i + 3 <= n do
    if bytes:byte(i) ~= 0xFF then return nil end
    local marker = bytes:byte(i + 1)
    -- Pad bytes (0xFF*) between markers are legal; skip them.
    if marker == 0xFF then i = i + 1
    else
      -- Standalone markers (no length / payload).
      if marker == 0xD8 or marker == 0xD9 or (marker >= 0xD0 and marker <= 0xD7) then
        i = i + 2
      else
        local seg_len = bytes:byte(i + 2) * 256 + bytes:byte(i + 3)
        -- SOF0..SOF15 except DHT(0xC4), DAC(0xCC), JPG(0xC8) — those aren't
        -- frame headers and don't carry image dimensions.
        local is_sof = marker >= 0xC0 and marker <= 0xCF
          and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
        if is_sof then
          if i + 9 > n then return nil end
          local h = bytes:byte(i + 5) * 256 + bytes:byte(i + 6)
          local w = bytes:byte(i + 7) * 256 + bytes:byte(i + 8)
          return w, h
        end
        i = i + 2 + seg_len
      end
    end
  end
  return nil
end

-- Read intrinsic dimensions from an SVG document. Tries literal width/height
-- attributes first (px and pt absolute units accepted; pt is converted at
-- the SVG default 96 DPI so a 100pt attribute becomes 133.33px), then falls
-- back to viewBox when width/height are missing or non-pixel ("100%").
-- Returns nil if no intrinsic size can be resolved (the caller then falls
-- back to the full available width + max-rows reservation).
function M.svg_dimensions(svg)
  if not svg or type(svg) ~= "string" or svg == "" then return nil end
  -- Convert an SVG length attribute to pixels.
  --
  -- Matplotlib (and most desktop SVG generators) emit width/height in pt,
  -- not px. Treating "100pt" as 100 pixels makes plots render ~25% too
  -- small. We do the standard SVG-DOM conversion: 1in = 96px, 1pt = 1/72in,
  -- so 1pt = 4/3 px. Relative units (`%`, `em`, …) and unparseable values
  -- return nil so the caller falls back to viewBox.
  local function as_px(s)
    if not s then return nil end
    if s:find("%%") then return nil end
    local num_str, unit = s:match("^(%d+%.?%d*)(.-)$")
    if not num_str or num_str == "" then
      num_str, unit = s:match("^(%.%d+)(.-)$")
    end
    local n = num_str and tonumber(num_str) or nil
    if not n then return nil end
    unit = (unit or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if unit == "pt" then return n * 4 / 3 end
    -- Unknown unit (em, ex, in, cm, mm, …) → treat as not-resolvable so
    -- viewBox wins. SVG default for unitless values is px.
    if unit ~= "" and unit ~= "px" then return nil end
    return n
  end
  local w = as_px(svg:match("<svg[^>]-width%s*=%s*\"([^\"]+)\""))
  local h = as_px(svg:match("<svg[^>]-height%s*=%s*\"([^\"]+)\""))
  if w and h then return w, h end
  -- viewBox="minX minY width height"
  local vb = svg:match("<svg[^>]-viewBox%s*=%s*\"([^\"]+)\"")
  if vb then
    local _, _, vw, vh = vb:match("(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s+(%d+%.?%d*)%s+(%d+%.?%d*)")
    if vw and vh then return tonumber(vw), tonumber(vh) end
  end
  return nil
end

-- Dispatch by image kind. Image renderer feeds this to the row-height math.
function M.image_dimensions(kind, bytes)
  if kind == "png" then return M.png_dimensions(bytes) end
  if kind == "jpeg" then return M.jpeg_dimensions(bytes) end
  if kind == "svg" then return M.svg_dimensions(bytes) end
  return nil
end

-- Compute how many editor cell rows an image of pixel-height h_px should
-- occupy, assuming a target render width of `cols` columns and a cell aspect
-- ratio (cell_w_px x cell_h_px).
--
-- The min clamp is 1 (a tiny icon should occupy one row, not be padded to
-- four rows of empty space). The max clamp protects against pathological
-- inputs — a 12000-pixel-tall image shouldn't push the rest of the
-- buffer off-screen — but the default is bumped to fit typical matplotlib
-- figures without clipping (640x480 default mpl renders at ~30 rows).
function M.image_row_height(w_px, h_px, cols, cell_w_px, cell_h_px, max_rows)
  if not w_px or not h_px or w_px == 0 or h_px == 0 then
    return max_rows or 40
  end
  local target_w_px = cols * cell_w_px
  local scaled_h_px = h_px * (target_w_px / w_px)
  local rows = math.ceil(scaled_h_px / cell_h_px)
  rows = Util.clamp(rows, 1, max_rows or 40)
  return rows
end

return M
