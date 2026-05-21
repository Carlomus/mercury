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
-- becomes "code" so we never lose data on encode.
local function nb_cell_type(kind)
  if kind == "markdown" then return "markdown" end
  if kind == "raw" then return "raw" end
  return "code"
end

local function kind_from_cell_type(ct)
  if ct == "markdown" then return "markdown" end
  if ct == "raw" then return "raw" end
  return "code"
end

local function parse_meta(meta_str)
  local meta = { kind = "code", extras = {}, raw = meta_str or "" }
  meta_str = meta_str or ""
  local lower = meta_str:lower()
  if lower:find("%[markdown%]") or lower:find("%[md%]") then
    meta.kind = "markdown"
  elseif lower:find("%[raw%]") then
    meta.kind = "raw"
  end
  for k, v in meta_str:gmatch("(%w+)%s*=%s*([^%s%]]+)") do
    if k == "id" then
      meta.id = v
    else
      meta.extras[k] = v
    end
  end
  return meta
end

local function format_separator(cell)
  local parts = { "# %%" }
  if cell.id then parts[#parts + 1] = "id=" .. cell.id end
  if cell.kind == "markdown" then parts[#parts + 1] = "[markdown]" end
  if cell.kind == "raw" then parts[#parts + 1] = "[raw]" end
  if cell.metadata and cell.metadata.tags and #cell.metadata.tags > 0 then
    parts[#parts + 1] = "tags=" .. table.concat(cell.metadata.tags, ",")
  end
  -- Preserve unknown separator tokens (foo=bar) through save/load. We stash
  -- them in metadata.mercury_extras during serialization and emit them back
  -- here when rendering the buffer text. Values can't contain whitespace —
  -- that's the same constraint parse_meta enforces on the read side.
  if cell.extras then
    local keys = {}
    for k in pairs(cell.extras) do
      if k ~= "tags" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = k .. "=" .. tostring(cell.extras[k])
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
-- This helper joins arrays of strings (the multilineString case) and passes
-- everything else through unchanged. Without this distinction, a Lua dict
-- value for `application/json` would silently `table.concat` to "" and the
-- data would be lost on first load — corrupting Plotly / Vega-Lite outputs.
local function _denest_mime_value(val)
  if type(val) ~= "table" then return val end
  -- An array of strings: per nbformat, every element is a string (often
  -- ending with "\n"). Join into a single string.
  local n = #val
  if n > 0 then
    for i = 1, n do
      if type(val[i]) ~= "string" then return val end
    end
    return table.concat(val, "")
  end
  -- Empty table OR a dict-shaped table: pass through. (An empty array would
  -- also pass through; that's a no-op for our renderer since split_lines
  -- handles "" specially anyway, but more importantly it preserves the
  -- structure for application/json `{}`.)
  return val
end

local function normalize_output(o)
  local t = o.output_type
  if t == "stream" then
    local text = o.text
    if type(text) == "table" then text = table.concat(text, "") end
    return { type = "stream", name = o.name or "stdout", text = text or "" }
  elseif t == "display_data" or t == "execute_result" then
    local data = {}
    for mime, val in pairs(o.data or {}) do
      data[mime] = _denest_mime_value(val)
    end
    local out = {
      type = t,
      data = data,
      metadata = o.metadata or {},
    }
    if t == "execute_result" then out.execution_count = o.execution_count end
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
      text = o.text or "",
    }
  elseif o.type == "display_data" or o.type == "execute_result" then
    local data = {}
    for mime, val in pairs(o.data or {}) do
      data[mime] = val
    end
    local out = {
      output_type = o.type,
      data = data,
      metadata = o.metadata or {},
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

M.denormalize_output = denormalize_output
M.normalize_output = normalize_output

local function ensure_dict(t)
  if t == nil or (type(t) == "table" and next(t) == nil) then
    return vim.empty_dict()
  end
  return t
end

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
  local cells = {}
  local injected_id = false
  for _, c in ipairs(doc.cells or {}) do
    local kind = kind_from_cell_type(c.cell_type)
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
    cells[#cells + 1] = {
      id = id,
      kind = kind,
      source = to_lines(c.source),
      outputs = outputs,
      -- Only code cells have execution_count per nbformat.
      exec_count = kind == "code" and c.execution_count or nil,
      metadata = c.metadata or {},
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
    nbformat = doc.nbformat or 4,
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

-- Encode internal shape back to nbformat v4 JSON text.
function M.encode(nb)
  local cells = {}
  for _, c in ipairs(nb.cells or {}) do
    local cell = {
      cell_type = c.kind == "markdown" and "markdown" or "code",
      id = c.id,
      metadata = c.metadata or {},
      source = lines_to_nbsource(c.source or {}),
    }
    if cell.cell_type == "code" then
      cell.execution_count = c.exec_count or vim.NIL
      local outs = {}
      for _, o in ipairs(c.outputs or {}) do
        local d = denormalize_output(o)
        if d then outs[#outs + 1] = d end
      end
      cell.outputs = outs
    end
    cells[#cells + 1] = cell
  end
  local doc = {
    cells = cells,
    metadata = nb.meta or vim.empty_dict(),
    nbformat = nb.nbformat or 4,
    nbformat_minor = nb.nbformat_minor or 5,
  }
  return reindent_json(vim.json.encode(doc)) .. "\n"
end

-- Render a decoded notebook to buffer lines (the py:percent-style text).
function M.to_buffer_lines(nb)
  local out = {}
  for i, c in ipairs(nb.cells or {}) do
    out[#out + 1] = format_separator({
      id = c.id, kind = c.kind, metadata = c.metadata,
      -- mercury_extras is our stash for unknown separator tokens; pull them
      -- out so they reappear in the buffer text exactly as they were before.
      extras = c.metadata and c.metadata.mercury_extras,
    })
    for _, line in ipairs(c.source or {}) do
      out[#out + 1] = line
    end
    if i < #nb.cells then
      out[#out + 1] = ""
    end
  end
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
