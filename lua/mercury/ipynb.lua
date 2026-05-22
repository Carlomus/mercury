-- Read and write nbformat v4 .ipynb JSON.
-- The reader produces { meta, cells = { { id, kind, source, outputs, exec_count, metadata, attachments? } ... } }
-- The writer takes the same shape and emits a JSON string.
--
-- Cell kinds: "code", "markdown", "raw". `raw` cells round-trip verbatim;
-- they don't participate in execution or LSP masking.

local Util = require("mercury.util")
local M = {}

local SEP_PAT = "^#%s*%%%%(.*)$"

-- Map our internal kind <-> nbformat cell_type. Anything we don't recognize
-- maps to "code" (the only kind we know how to render and execute), but the
-- ORIGINAL cell_type is stashed in metadata.mercury_original_cell_type on
-- decode and restored on encode so round-trip is lossless even for cell
-- types nbformat doesn't yet define (sql, julia, etc.). SPEC "Cell types".
local function nb_cell_type(kind)
  if kind == "markdown" then return "markdown" end
  if kind == "raw" then return "raw" end
  return "code"
end

local KNOWN_CELL_TYPES = { code = true, markdown = true, raw = true }

local function kind_from_cell_type(ct)
  if ct == "markdown" then return "markdown" end
  if ct == "raw" then return "raw" end
  return "code"
end

-- parse_meta(rest) — rest is the substring after "# %%". Returns
--   { id?, kind = "code"|"markdown"|"raw", extras = { ... }, raw = rest }
-- extras is a string-keyed dict of every non-id, non-flag token.
--
-- Key class is [%w_%-%.]+ — alphanumerics plus underscore, hyphen, and dot.
-- (`%w` alone excludes underscore, which would silently drop common
-- snake_case keys like `vscode.cell_id` on rescan.)
--
-- Value class is [^%s%]]+ matched DIRECTLY after `=` (no `%s*` between `=`
-- and value): `id=abc tags= foo=bar` must produce tags=nil, foo=bar, not
-- tags="foo=bar" via whitespace-skipping (H4).
local function parse_meta(meta_str)
  local meta = { kind = "code", extras = {}, raw = meta_str or "" }
  meta_str = meta_str or ""
  local lower = meta_str:lower()
  if lower:find("%[markdown%]") or lower:find("%[md%]") then
    meta.kind = "markdown"
  elseif lower:find("%[raw%]") then
    meta.kind = "raw"
  end
  for k, v in meta_str:gmatch("([%w_%-%.]+)=([^%s%]]+)") do
    if k == "id" and not meta.id then
      meta.id = v
    elseif k ~= "id" then
      meta.extras[k] = v
    end
  end
  return meta
end

-- Validity helpers shared between format_separator (drop bad keys) and
-- to_buffer_lines (warn on the load-side mercury_extras stash). The contract
-- is that whatever format_separator emits must round-trip through parse_meta
-- — so the key class here MUST match parse_meta's key class exactly.
local function _is_valid_extras_key(k)
  return type(k) == "string" and k:match("^[%w_%-%.]+$") ~= nil
end

-- Reserved keys that have their own canonical emission path (id from cell.id,
-- tags from cell.metadata.tags). An extras stash with these keys would be
-- silently swallowed on reparse; drop them on emission so what we write is
-- what the next read will see.
local RESERVED_EXTRAS_KEYS = { id = true, tags = true }

-- Drop tags that would corrupt the separator's tags=foo,bar grammar:
--   - comma: collides with the value separator
--   - whitespace: parse_meta's value class `[^%s%]]+` would truncate at first WS
--   - `]`: same value-class exclusion
-- nbformat treats tags as arbitrary strings, so we can't always preserve
-- them losslessly in the separator. format_separator drops bad tags
-- defensively; to_buffer_lines emits a one-shot WARN per bad tag so the
-- user notices the silent data drop before the next save bakes it in.
local function _is_valid_tag(t)
  return type(t) == "string" and t ~= "" and not t:find("[,%s%]]")
end

local function format_separator(cell)
  local parts = { "# %%" }
  if cell.id then parts[#parts + 1] = "id=" .. cell.id end
  if cell.kind == "markdown" then parts[#parts + 1] = "[markdown]" end
  if cell.kind == "raw" then parts[#parts + 1] = "[raw]" end
  if cell.metadata and cell.metadata.tags and #cell.metadata.tags > 0 then
    local valid = {}
    for _, t in ipairs(cell.metadata.tags) do
      if _is_valid_tag(t) then valid[#valid + 1] = t end
    end
    if #valid > 0 then
      parts[#parts + 1] = "tags=" .. table.concat(valid, ",")
    end
  end
  -- Preserve unknown separator tokens (foo=bar) through save/load via
  -- metadata.mercury_extras. Sort keys alphabetically so the output is
  -- deterministic. Filter:
  --   - reserved keys (id, tags) — those come from cell.id / cell.metadata.tags
  --   - keys outside the [A-Za-z0-9_.-] class — those wouldn't parse back
  --   - values containing whitespace or `]` — parse_meta would truncate them
  if cell.extras then
    local keys = {}
    for k in pairs(cell.extras) do
      if not RESERVED_EXTRAS_KEYS[k] and _is_valid_extras_key(k) then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = tostring(cell.extras[k])
      if not v:find("[%s%]]") then
        parts[#parts + 1] = k .. "=" .. v
      end
    end
  end
  return table.concat(parts, " ")
end

M.parse_meta = parse_meta
M.format_separator = format_separator

-- Convert a list-of-strings-with-newlines (nbformat) or a single string into
-- a flat list of lines with no trailing newline embedded.
local function to_lines(src)
  if type(src) == "table" then
    src = table.concat(src, "")
  end
  if not src or src == "" then return {} end
  -- Strip a single trailing newline so we don't get a phantom empty line.
  if src:sub(-1) == "\n" then src = src:sub(1, -2) end
  return Util.split_lines(src)
end

-- Inverse: turn flat lines into nbformat list-of-strings (each with trailing \n
-- except possibly the last).
local function lines_to_nbsource(lines)
  if #lines == 0 then return {} end
  local out = {}
  for i, line in ipairs(lines) do
    if i < #lines then
      out[#out + 1] = line .. "\n"
    else
      out[#out + 1] = line
    end
  end
  return out
end

-- nbformat mimebundle values are spec'd as:
--   string | array<string>  (multilineString — represents text content)
--   any JSON value          (for mimes like application/json that ARE objects)
--
-- The multilineString form applies *only* to `text/*` mimes per nbformat.
-- For `application/json` / `application/vnd.*+json` the value is "any JSON
-- value" and may legitimately be a string array (e.g., a Plotly trace's
-- categorical axis labels). Joining those into a single string would
-- silently corrupt the payload. Mime is required to determine policy.
local function _denest_mime_value(mime, val)
  if type(val) ~= "table" then return val end
  -- Only text mimes are multilineString. Non-text mimes pass through verbatim.
  if not (type(mime) == "string" and mime:match("^text/")) then return val end
  -- An array of strings: per nbformat, every element is a string (often
  -- ending with "\n"). Join into a single string.
  local n = #val
  if n > 0 then
    for i = 1, n do
      if type(val[i]) ~= "string" then return val end
    end
    return table.concat(val, "")
  end
  -- Empty table OR a dict-shaped table: pass through.
  return val
end

-- nbformat's canonical multilineString form on disk is an array of strings:
-- one element per source line, with the trailing "\n" retained on all but
-- (optionally) the last. Mercury keeps a single string in memory for ease
-- of rendering and edit; this helper converts back to array form on save
-- so files we write diff cleanly against `nbformat.write` / Jupyter Lab.
-- A pure single-line value stays a string (nbformat accepts either form).
-- SPEC "Canonical multilineString serialization".
local function _to_multiline_strings(s)
  if type(s) ~= "string" then return s end
  if s == "" then return "" end
  -- Match Python's str.splitlines(True): keep the line terminator on each
  -- segment. Only LF is treated as a line break — nbformat normalizes line
  -- endings to LF in the writer.
  if not s:find("\n", 1, true) then return s end
  local parts = {}
  local i, n = 1, #s
  while i <= n do
    local nl = s:find("\n", i, true)
    if not nl then
      parts[#parts + 1] = s:sub(i)
      break
    end
    parts[#parts + 1] = s:sub(i, nl)
    i = nl + 1
  end
  return parts
end
M._to_multiline_strings = _to_multiline_strings

-- Forward declaration; ensure_dict is defined below alongside the encoder.
local ensure_dict

local function normalize_output(o)
  local t = o.output_type
  if t == "stream" then
    local text = o.text
    if type(text) == "table" then text = table.concat(text, "") end
    return { type = "stream", name = o.name or "stdout", text = text or "" }
  elseif t == "display_data" or t == "execute_result" then
    local data = {}
    for mime, val in pairs(o.data or {}) do
      data[mime] = _denest_mime_value(mime, val)
    end
    local out = {
      type = t,
      data = data,
      metadata = o.metadata or {},
    }
    if t == "execute_result" then out.execution_count = o.execution_count end
    -- Read display_id from EITHER its canonical Mercury location
    -- (`metadata.mercury.display_id`) OR the legacy `transient.display_id`
    -- stash that older Mercury versions wrote. SPEC Invariant 41.
    --
    -- `transient` is a messaging-protocol concept, not an nbformat field;
    -- writing it as a sibling of `output_type` is a schema violation that
    -- strict nbformat validators reject. New saves write the metadata.mercury
    -- location; the legacy reader keeps existing files working.
    local meta = o.metadata
    local display_id
    if type(meta) == "table"
        and type(meta.mercury) == "table"
        and type(meta.mercury.display_id) == "string"
        and meta.mercury.display_id ~= "" then
      display_id = meta.mercury.display_id
    elseif type(o.transient) == "table"
        and type(o.transient.display_id) == "string"
        and o.transient.display_id ~= "" then
      display_id = o.transient.display_id
    end
    if display_id then out._display_id = display_id end
    return out
  elseif t == "error" then
    return {
      type = "error",
      ename = o.ename or "",
      evalue = o.evalue or "",
      traceback = o.traceback or {},
    }
  end
  return nil
end

local function denormalize_output(o)
  if o.type == "stream" then
    return {
      output_type = "stream",
      name = o.name or "stdout",
      text = _to_multiline_strings(o.text or ""),
    }
  elseif o.type == "display_data" or o.type == "execute_result" then
    local data = {}
    for mime, val in pairs(o.data or {}) do
      -- nbformat canonical form for multiline text mimes is an array of
      -- strings. Joining on read + splitting on write keeps files we write
      -- diff-clean against nbformat.write / Jupyter Lab output. Non-text
      -- mimes pass through verbatim.
      if type(val) == "string" and type(mime) == "string" and mime:match("^text/") then
        data[mime] = _to_multiline_strings(val)
      elseif type(val) == "table" and next(val) == nil then
        -- Empty per-mime table (e.g., application/json `{}`) must serialize
        -- as an object, not an array. SPEC Invariant 44.
        data[mime] = ensure_dict(val)
      else
        data[mime] = val
      end
    end
    -- Build metadata with display_id stashed under `mercury.display_id`.
    -- We don't write the legacy `transient.display_id` shape any more, but
    -- the reader accepts it for backwards-compat. SPEC Invariant 41.
    local meta = {}
    for k, v in pairs(o.metadata or {}) do meta[k] = v end
    if o._display_id then
      local m = meta.mercury
      if type(m) ~= "table" then m = {} end
      m.display_id = o._display_id
      meta.mercury = m
    end
    local out = {
      output_type = o.type,
      data = ensure_dict(data),
      metadata = ensure_dict(meta),
    }
    if o.type == "execute_result" then
      out.execution_count = o.execution_count or vim.NIL
    end
    return out
  elseif o.type == "error" then
    return {
      output_type = "error",
      ename = o.ename or "",
      evalue = o.evalue or "",
      traceback = o.traceback or {},
    }
  end
  return nil
end

-- Merge consecutive same-name stream items into one (nbformat canonical
-- form, produced by `nbformat.v4.normalize`). The kernel emits one iopub
-- frame per chunk; nbformat collapses runs of stdout/stderr into single
-- entries with concatenated text. Without this, files Mercury writes
-- re-shape on the next pass through any nbformat-aware tool, producing
-- meaningless diffs. SPEC Invariant 36.
--
-- Operates on already-denormalized outputs (output_type / name / text
-- keys), so it is called after the items have been built for the encoder.
-- For stream items whose text was split into array form by
-- _to_multiline_strings, this re-joins before merging — concatenating two
-- arrays of multiline-text would otherwise produce visually-correct but
-- semantically-redundant nesting. After concat, the merged text is
-- re-split via _to_multiline_strings to preserve nbformat canonical
-- form for the merged result.
local function _merge_stream_items(items)
  if not items or #items < 2 then return items end
  local function _as_string(t)
    if type(t) == "table" then return table.concat(t, "") end
    return t or ""
  end
  local out = {}
  for _, it in ipairs(items) do
    local prev = out[#out]
    if prev and prev.output_type == "stream" and it.output_type == "stream"
        and prev.name == it.name then
      prev.text = _as_string(prev.text) .. _as_string(it.text)
    else
      out[#out + 1] = it
    end
  end
  -- Re-canonicalize stream text to array form after merging.
  for _, it in ipairs(out) do
    if it.output_type == "stream" then
      it.text = _to_multiline_strings(_as_string(it.text))
    end
  end
  return out
end
M._merge_stream_items = _merge_stream_items

M.denormalize_output = denormalize_output
M.normalize_output = normalize_output

ensure_dict = function(t)
  if t == nil or (type(t) == "table" and next(t) == nil) then
    return vim.empty_dict()
  end
  return t
end
M._ensure_dict = ensure_dict

-- nbformat-style pretty printer. vim.json.encode emits single-line JSON, which
-- makes .ipynb files unreadable in GitHub diffs; Jupyter writes indent=1 with
-- sorted keys, so we do the same. Honors vim.empty_dict() / vim.NIL the way
-- vim.json.encode does.
local function _is_dict_table(t)
  if next(t) == nil then
    return vim.json.encode(t) == "{}"
  end
  for k in pairs(t) do
    if type(k) ~= "number" then return true end
  end
  return false
end

local function _encode_pretty(val, indent, level)
  if val == nil or val == vim.NIL then return "null" end
  if type(val) ~= "table" then return vim.json.encode(val) end

  local pad = string.rep(indent, level + 1)
  local close = string.rep(indent, level)

  if _is_dict_table(val) then
    local keys = {}
    for k in pairs(val) do keys[#keys + 1] = k end
    if #keys == 0 then return "{}" end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for i, k in ipairs(keys) do
      parts[i] = pad .. vim.json.encode(tostring(k)) .. ": " ..
        _encode_pretty(val[k], indent, level + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. close .. "}"
  end

  if #val == 0 then return "[]" end
  local parts = {}
  for i, v in ipairs(val) do
    parts[i] = pad .. _encode_pretty(v, indent, level + 1)
  end
  return "[\n" .. table.concat(parts, ",\n") .. "\n" .. close .. "]"
end

-- Lua has no syntactic difference between an empty dict `{}` and an empty
-- array `[]` — both are an empty table. `vim.json.decode` therefore can't
-- tell us which one a JSON `{}` was; on re-encode our `_is_dict_table`
-- defaults empty tables to `[]`, corrupting genuine empty JSON objects
-- (most visibly `IPython.display.JSON({})`, but also any empty `metadata`
-- in odd places). To preserve them, we substitute a sentinel into the
-- raw JSON BEFORE decoding, then walk the decoded tree and convert
-- sentinels back into `vim.empty_dict()` (which the encoder emits as `{}`).
--
-- The substitution is string-aware: empty `{}` occurrences inside JSON
-- string literals are left alone.
local EMPTY_DICT_KEY = "__mercury_internal_empty_dict_marker_v1__"

local function _mark_empty_objects(json)
  local out = {}
  local i, n = 1, #json
  local in_string = false
  local escape = false
  while i <= n do
    local c = json:sub(i, i)
    if in_string then
      if escape then escape = false
      elseif c == "\\" then escape = true
      elseif c == '"' then in_string = false
      end
      out[#out + 1] = c
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "{" then
      -- Look ahead past whitespace for a matching `}` — that's an empty object.
      local j = i + 1
      while j <= n and json:sub(j, j):match("%s") do j = j + 1 end
      if j <= n and json:sub(j, j) == "}" then
        out[#out + 1] = '{"' .. EMPTY_DICT_KEY .. '":1}'
        i = j + 1
      else
        out[#out + 1] = c
        i = i + 1
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function _unmark_empty_objects(val)
  if type(val) ~= "table" then return val end
  -- A sentinel table is a one-key table with the marker key. Replace it
  -- with vim.empty_dict() so the encoder emits `{}` instead of `[]`.
  if val[EMPTY_DICT_KEY] == 1 then
    local count = 0
    for _ in pairs(val) do count = count + 1; if count > 1 then break end end
    if count == 1 then return vim.empty_dict() end
  end
  for k, v in pairs(val) do
    val[k] = _unmark_empty_objects(v)
  end
  return val
end

-- Decode nbformat v4 JSON string into our internal shape.
function M.decode(json_text)
  local preprocessed = _mark_empty_objects(json_text or "")
  local ok, doc = pcall(vim.json.decode, preprocessed,
    { luanil = { object = true, array = true } })
  if not ok or type(doc) ~= "table" then
    return nil, "invalid JSON"
  end
  doc = _unmark_empty_objects(doc)
  -- nbformat v3 has a completely different schema (worksheets, prompt_number
  -- instead of execution_count, etc.). Reading it as v4 silently produces an
  -- empty notebook; a casual :w then overwrites the original with mercury's
  -- placeholder, destroying the user's data. Refuse explicitly so the user
  -- can run `jupyter nbconvert --to notebook` to upgrade in-place first.
  local nbformat_major = doc.nbformat or 4
  if type(nbformat_major) == "number" and nbformat_major < 4 then
    return nil, ("nbformat v%d is not supported by Mercury (reads v4 only). " ..
                 "Run: jupyter nbconvert --to notebook --inplace <file>"):format(nbformat_major)
  end
  if type(nbformat_major) == "number" and nbformat_major > 4 then
    -- Future-proof: refuse a hypothetical v5 too so we don't misinterpret it.
    return nil, ("nbformat v%d is not supported by Mercury (reads v4 only)."):format(nbformat_major)
  end
  local cells = {}
  local injected_id = false
  for _, c in ipairs(doc.cells or {}) do
    local raw_type = c.cell_type
    local kind = kind_from_cell_type(raw_type)
    local id = c.id
    if not id or id == "" then
      id = Util.short_id()
      injected_id = true
    end
    local outputs = {}
    -- Only code cells carry outputs in nbformat. Defensively skip the loop
    -- for non-code cells so a malformed file that put outputs on a markdown
    -- or raw cell doesn't propagate them into our state.
    if kind == "code" then
      for _, o in ipairs(c.outputs or {}) do
        local norm = normalize_output(o)
        if norm then outputs[#outputs + 1] = norm end
      end
    end
    -- Preserve unknown cell_type verbatim across save/load. nbformat may
    -- gain new cell types (sql, julia, etc.); we render them as code in
    -- the buffer (the only kind we know how to display) but the original
    -- cell_type is stashed in metadata.mercury_original_cell_type so the
    -- next save restores it. Lossless round-trip.
    local metadata = c.metadata or {}
    if type(raw_type) == "string" and not KNOWN_CELL_TYPES[raw_type] then
      metadata = vim.deepcopy(metadata)
      metadata.mercury_original_cell_type = raw_type
    end
    cells[#cells + 1] = {
      id = id,
      kind = kind,
      source = to_lines(c.source),
      outputs = outputs,
      -- Only code cells have execution_count per nbformat.
      exec_count = kind == "code" and c.execution_count or nil,
      metadata = metadata,
      -- nbformat v4 lets markdown cells carry an `attachments` table mapping
      -- filename -> { mime -> base64-string }. Preserve verbatim so paste-image
      -- bytes round-trip; we don't decode or render them.
      attachments = c.attachments,
    }
  end
  local nbformat_minor = doc.nbformat_minor or 5
  -- nbformat 4.5 introduced required cell.id. If we had to synthesize any ids
  -- because the file was older / produced by a non-conforming writer, bump the
  -- declared minor so the file we eventually write is self-consistent. We never
  -- bump above 5 (that's the only version that cares about ids today).
  if injected_id and nbformat_minor < 5 then nbformat_minor = 5 end
  return {
    meta = doc.metadata or {},
    nbformat = nbformat_major,
    nbformat_minor = nbformat_minor,
    cells = cells,
  }
end

-- Re-indent the single-line JSON that `vim.json.encode` produces so saved
-- notebooks diff cleanly against Jupyter / VS Code output (both use 1-space
-- indent per the nbformat convention).
local function reindent_json(s)
  local out, depth = {}, 0
  local in_string, escape = false, false
  local function nl()
    out[#out + 1] = "\n"
    for _ = 1, depth do out[#out + 1] = " " end
  end
  local i, n = 1, #s
  while i <= n do
    local ch = s:sub(i, i)
    if in_string then
      out[#out + 1] = ch
      if escape then escape = false
      elseif ch == "\\" then escape = true
      elseif ch == '"' then in_string = false end
    elseif ch == '"' then
      out[#out + 1] = ch
      in_string = true
    elseif ch == "{" or ch == "[" then
      out[#out + 1] = ch
      -- Empty container: emit inline.
      local j = i + 1
      while j <= n and s:sub(j, j):match("%s") do j = j + 1 end
      local close = (ch == "{") and "}" or "]"
      if s:sub(j, j) == close then
        out[#out + 1] = close
        i = j
      else
        depth = depth + 1
        nl()
      end
    elseif ch == "}" or ch == "]" then
      depth = depth - 1
      nl()
      out[#out + 1] = ch
    elseif ch == "," then
      out[#out + 1] = ch
      nl()
    elseif ch == ":" then
      out[#out + 1] = ": "
    elseif ch == " " or ch == "\n" or ch == "\t" then
      -- skip
    else
      out[#out + 1] = ch
    end
    i = i + 1
  end
  return table.concat(out)
end

M._reindent_json = reindent_json
M._encode_pretty = _encode_pretty

-- Encode internal shape back to nbformat v4 JSON text.
--
-- Uses _encode_pretty (not vim.json.encode + reindent) so keys are sorted
-- alphabetically — SPEC Invariant 3. vim.json.encode emits keys in Lua
-- iteration order, which is unstable across inserts and produces churn
-- in saved .ipynb files even when no semantic content changed. _encode_pretty
-- is the single source of truth for on-disk JSON shape.
function M.encode(nb)
  local cells = {}
  for _, c in ipairs(nb.cells or {}) do
    local ctype
    if c.kind == "markdown" then ctype = "markdown"
    elseif c.kind == "raw" then ctype = "raw"
    else ctype = "code" end
    -- Restore the original cell_type stashed at decode time. Mercury
    -- renders unknown types as code in the buffer but the on-disk form
    -- must be byte-stable. SPEC "Cell types".
    local metadata = c.metadata or {}
    local original_ct = metadata.mercury_original_cell_type
    local out_metadata
    if type(original_ct) == "string" and not KNOWN_CELL_TYPES[original_ct] and ctype == "code" then
      ctype = original_ct
      out_metadata = {}
      for k, v in pairs(metadata) do
        if k ~= "mercury_original_cell_type" then out_metadata[k] = v end
      end
    else
      out_metadata = metadata
    end
    local cell = {
      cell_type = ctype,
      id = c.id,
      metadata = ensure_dict(out_metadata),
      source = lines_to_nbsource(c.source or {}),
    }
    if ctype == "code" then
      cell.execution_count = c.exec_count or vim.NIL
      local outs = {}
      for _, o in ipairs(c.outputs or {}) do
        local d = denormalize_output(o)
        if d then outs[#outs + 1] = d end
      end
      cell.outputs = _merge_stream_items(outs)
    elseif ctype == "markdown" and c.attachments and next(c.attachments) ~= nil then
      -- nbformat v4 lets markdown cells carry attachments (pasted images
      -- referenced from prose as `attachment:filename`). Preserve verbatim
      -- across save/load. Code/raw cells don't carry attachments.
      cell.attachments = c.attachments
    end
    cells[#cells + 1] = cell
  end
  local doc = {
    cells = cells,
    metadata = ensure_dict(nb.meta),
    nbformat = nb.nbformat or 4,
    nbformat_minor = nb.nbformat_minor or 5,
  }
  return _encode_pretty(doc, " ", 0) .. "\n"
end

-- Render a decoded notebook to buffer lines (the py:percent-style text).
-- Surfaces three warnings for mercury_extras content that won't survive a
-- round-trip through the separator (so the user can fix the JSON before
-- the next save bakes in the truncation):
--   - value contains whitespace or `]`  (parse_meta would truncate)
--   - key contains characters outside [%w_%-%.]  (parse_meta would skip)
--   - key is the reserved name "id" or "tags"  (own canonical source)
function M.to_buffer_lines(nb)
  local out = {}
  for _, c in ipairs(nb.cells or {}) do
    -- Warn on tags whose contents can't survive the separator round-trip
    -- (commas, whitespace, ']'). format_separator drops them silently —
    -- this notify is what gives the user a chance to migrate them BEFORE
    -- the next save erases them from the JSON. Per-cell, since the same
    -- tag can recur across cells via a Jupyter-Lab-applied tag.
    local md_tags = c.metadata and c.metadata.tags
    if type(md_tags) == "table" then
      for _, t in ipairs(md_tags) do
        if not _is_valid_tag(t) then
          local reason
          if type(t) ~= "string" then reason = "non-string"
          elseif t == "" then reason = "empty"
          elseif t:find(",") then reason = "contains ','"
          elseif t:find("%s") then reason = "contains whitespace"
          elseif t:find("%]") then reason = "contains ']'"
          else reason = "invalid" end
          Util.notify(("cell %s: tag %q dropped from separator (%s) — fix tags in the JSON before saving to preserve them")
            :format(c.id or "?", tostring(t), reason),
            vim.log.levels.WARN)
        end
      end
    end
    local extras = c.metadata and c.metadata.mercury_extras
    if extras then
      for k, v in pairs(extras) do
        if RESERVED_EXTRAS_KEYS[k] then
          local alt = (k == "id") and "cell.id" or "metadata.tags"
          Util.notify(("mercury_extras contains reserved \"%s\" key — value will be sourced from %s, extras entry dropped from the separator")
            :format(k, alt), vim.log.levels.WARN)
        elseif not _is_valid_extras_key(k) then
          Util.notify(("mercury_extras key %q is outside the [A-Za-z0-9_.-] class — dropped from the separator")
            :format(k), vim.log.levels.WARN)
        else
          local s = tostring(v)
          local has_ws = s:find("%s") ~= nil
          local has_br = s:find("%]") ~= nil
          if has_ws and has_br then
            Util.notify(("mercury_extras[\"%s\"] = %q contains whitespace and ']' — both truncated on next save")
              :format(k, s), vim.log.levels.WARN)
          elseif has_ws then
            Util.notify(("mercury_extras[\"%s\"] = %q contains whitespace — truncated on next save")
              :format(k, s), vim.log.levels.WARN)
          elseif has_br then
            Util.notify(("mercury_extras[\"%s\"] = %q contains ']' — truncated on next save")
              :format(k, s), vim.log.levels.WARN)
          end
        end
      end
    end
    out[#out + 1] = format_separator({
      id = c.id, kind = c.kind, metadata = c.metadata,
      extras = extras,
    })
    for _, line in ipairs(c.source or {}) do
      out[#out + 1] = line
    end
  end
  -- Insert one blank visual gap between cells.
  local with_gaps = {}
  for i, line in ipairs(out) do
    with_gaps[#with_gaps + 1] = line
    -- Detect cell boundary: the next line starts a new separator.
    local nxt = out[i + 1]
    if nxt and nxt:match("^#%s*%%%%") then
      with_gaps[#with_gaps + 1] = ""
    end
  end
  out = with_gaps
  if #out == 0 then
    out = { format_separator({ id = Util.short_id(), kind = "code" }) }
  end
  return out
end

-- Scan buffer lines into cells (no outputs, just structure + ids).
-- Returns { cells = {...}, mutated = true|false } where mutated indicates whether
-- the buffer should be rewritten to add missing ids or to disambiguate duplicates.
function M.scan_lines(lines)
  local cells = {}
  local mutated = false
  local n = #lines
  local i = 1
  -- Track which ids we've already emitted in this scan. nbformat 4.5+ requires
  -- ids to be unique across the document. A copy-paste of a cell (separator
  -- included) would otherwise produce two cells sharing one id, which (a) other
  -- tools reject and (b) makes our own per-id side tables (outputs, metadata)
  -- aliased — the first cell's output would render on the second cell too.
  local seen_ids = {}

  -- Implicit first cell if buffer doesn't start with a separator.
  local first_sep = nil
  for k = 1, n do
    local rest = lines[k]:match(SEP_PAT)
    if rest ~= nil then first_sep = k; break end
  end

  if not first_sep then
    -- Whole buffer is one implicit cell.
    local id = Util.short_id()
    cells[#cells + 1] = {
      id = id, kind = "code",
      header_row = -1, body_start = 0, body_end = math.max(n - 1, 0),
      meta = { id = id, kind = "code", extras = {}, raw = "" },
      injected_separator = true,
    }
    return { cells = cells, mutated = false }
  end

  if first_sep > 1 then
    -- There's content before the first separator: treat as a leading cell.
    local id = Util.short_id()
    cells[#cells + 1] = {
      id = id, kind = "code",
      header_row = -1, body_start = 0, body_end = first_sep - 2,
      meta = { id = id, kind = "code", extras = {}, raw = "" },
      injected_separator = true,
    }
    seen_ids[id] = true
  end

  i = first_sep
  while i <= n do
    local rest = lines[i]:match(SEP_PAT)
    if rest == nil then
      i = i + 1
    else
      local meta = parse_meta(rest)
      if not meta.id then
        meta.id = Util.short_id()
        mutated = true
      elseif seen_ids[meta.id] then
        -- Duplicate (likely user yanked-and-pasted a cell). Allocate a fresh
        -- id and rewrite the buffer so subsequent rescans converge.
        meta.id = Util.short_id()
        meta.dup_rewrite = true
        mutated = true
      end
      seen_ids[meta.id] = true
      local body_start = i  -- 0-indexed: body begins on row i (since header is row i-1 0-indexed)
      -- Find next separator
      local j = i + 1
      while j <= n and lines[j]:match(SEP_PAT) == nil do j = j + 1 end
      cells[#cells + 1] = {
        id = meta.id,
        kind = meta.kind,
        header_row = i - 1,           -- 0-indexed header row
        body_start = i,               -- 0-indexed first body row
        body_end = j - 2,             -- 0-indexed last body row (inclusive); -1 if empty body
        meta = meta,
        dup_rewrite = meta.dup_rewrite or nil,
      }
      i = j
    end
  end
  return { cells = cells, mutated = mutated }
end

return M
