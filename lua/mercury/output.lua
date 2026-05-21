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

local function pick_mime(data)
  if not data then return nil end
  -- Prefer rich formats (image, latex, markdown) first; for text fallbacks,
  -- prefer plain over html because our html→text is naive and would mangle
  -- common cases like pandas DataFrame _repr_html_.
  for _, m in ipairs({
    "image/png", "image/jpeg", "image/svg+xml", "text/latex",
    "text/markdown", "text/plain", "text/html",
  }) do
    if data[m] then return m end
  end
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

  local body_lines = {}
  for _, item in ipairs(out.items or {}) do
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
      elseif mime == "image/png" or mime == "image/jpeg" or mime == "image/svg+xml" then
        -- When image.nvim is available it renders the image inline below the
        -- virt_lines; in that case the placeholder is just noise. Show one
        -- only as a fallback when no image renderer is loaded.
        local image_ok, Image = pcall(require, "mercury.image")
        if not image_ok or not Image.available() then
          body_lines[#body_lines + 1] = { ("[%s]"):format(mime), "Comment" }
        end
      elseif mime == "text/html" then
        local txt = html_to_text(_value_to_string(item.data["text/html"]))
        for _, ln in ipairs(Util.split_lines(txt)) do
          body_lines[#body_lines + 1] = { ln, "Comment" }
        end
      elseif mime == "text/latex" then
        local ok, Latex = pcall(require, "mercury.latex")
        if ok and Latex.available() then
          body_lines[#body_lines + 1] = { "[text/latex (rendered below)]", "Comment" }
        else
          for _, ln in ipairs(Util.split_lines(_value_to_string(item.data[mime]))) do
            body_lines[#body_lines + 1] = { ln, "Special" }
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
    lines[#lines + 1] = { body_lines[i] }
  end
  if #body_lines > n then
    lines[#lines + 1] =
      { { ("  … %d lines hidden"):format(#body_lines - n), "Comment" } }
  end
  return lines
end

-- Get just the plain text of an output (for copy / scratch view).
function M.to_plain_text(out)
  local lines = {}
  if out.exec_count then
    lines[#lines + 1] = ("Out[%s] %s ms"):format(out.exec_count, out.ms or 0)
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
      if mime then
        local raw = item.data[mime]
        if mime:sub(1, 5) == "text/" or mime == "application/json" then
          local s = _value_to_string(raw)
          for _, ln in ipairs(Util.split_lines(s)) do lines[#lines + 1] = ln end
        else
          -- Binary-ish payload (image/*, application/octet-stream, etc.).
          -- It's a base64 string at the wire level; len of the string is fine.
          local s = type(raw) == "string" and raw or _value_to_string(raw)
          lines[#lines + 1] = ("[%s, %d bytes]"):format(mime, #s)
        end
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
-- attributes first (with px/pt unit stripping), then falls back to viewBox
-- when width/height are missing or non-pixel ("100%"). Returns nil if no
-- intrinsic size can be resolved (the caller then falls back to the full
-- available width + max-rows reservation).
function M.svg_dimensions(svg)
  if not svg or type(svg) ~= "string" or svg == "" then return nil end
  local function as_px(s)
    if not s then return nil end
    -- Reject relative units ("100%", "1em", etc.) — viewBox is the
    -- authoritative answer for those.
    if s:find("%%") then return nil end
    local n = s:match("^(%d+%.?%d*)") or s:match("^(%.%d+)")
    return n and tonumber(n) or nil
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
