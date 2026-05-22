-- Style text/markdown outputs into virt_lines chunks. The output is a list
-- (one entry per source line) of `{ {text, hl_group}, ... }` chunks ready
-- to be slotted into a virt_lines extmark.
--
-- Why this exists: render-markdown.nvim styles real buffer lines via extmark
-- virt_text + conceal, and its decorations CANNOT be relayed through another
-- buffer's virt_lines (extmarks attach to buffers, not to floating chunks).
-- Mercury renders `text/markdown` outputs as virt_lines under the cell
-- anchor, so we apply markdown styling here ourselves, using the same
-- treesitter highlight groups that markdown-aware themes already style
-- (Title, @markup.heading.N, @markup.strong, @markup.emphasis,
-- @markup.raw.markdown_inline, @markup.list.markdown,
-- @markup.quote.markdown). With render-markdown.nvim installed, those
-- groups generally inherit the same look the plugin uses for real
-- markdown lines; without it, they fall back to the theme's
-- markdown-treesitter palette. Either way the prose comes out styled, not
-- raw. SPEC § "Markdown rendering" + Invariant 33.
--
-- The parser is intentionally regex-based and conservative — markdown's
-- grammar is full of edge cases (nested emphasis, escapes, link refs,
-- HTML blocks) that aren't worth tracking in a notebook output context.
-- The goal is "Jupyter-style styled prose," not bug-for-bug markdown
-- compliance. Common formats — headings, lists, code fences, inline
-- code, **bold**, *italic*, blockquotes — render correctly; exotic
-- constructs degrade to plain prose with no styling.

local Util = require("mercury.util")

local M = {}

local DEFAULT_HL = "MercuryMarkdownOut"

-- Inline-emphasis scanning. Walks one line and emits chunks for inline
-- code (`code`), bold (**bold**), and italic (*italic*) — picking the
-- earliest match each iteration. The order in `_PATTERNS` matters when
-- two candidate spans start at the same column: `**bold**` MUST be tried
-- before `*italic*`, otherwise the bold span would be parsed as two
-- empty italic spans flanking the word.
local _PATTERNS = {
  -- { lua_pattern, hl_group }. Patterns use `()` so we can recover the
  -- start position via string.find's first return; lengths come from end.
  { "`[^`\n]+`",            "@markup.raw.markdown_inline" },
  { "%*%*[^%*\n]-%*%*",     "@markup.strong" },
  { "__[^_\n]-__",          "@markup.strong" },
  { "%*[^%*\n]-%*",         "@markup.emphasis" },
  { "_[^_\n]-_",            "@markup.emphasis" },
}

local function _next_inline_match(line, from)
  -- Find the earliest match across all patterns. Ties broken by
  -- _PATTERNS order (i.e., bold before italic).
  local best
  for _, spec in ipairs(_PATTERNS) do
    local s, e = line:find(spec[1], from)
    if s and (not best or s < best.s) then
      best = { s = s, e = e, hl = spec[2] }
    end
  end
  return best
end

local function _parse_inline(line, default_hl)
  default_hl = default_hl or DEFAULT_HL
  local chunks = {}
  local cursor = 1
  local n = #line
  while cursor <= n do
    local m = _next_inline_match(line, cursor)
    if not m then
      -- No further inline spans — emit the tail and return.
      local tail = line:sub(cursor)
      if tail ~= "" then chunks[#chunks + 1] = { tail, default_hl } end
      break
    end
    if m.s > cursor then
      chunks[#chunks + 1] = { line:sub(cursor, m.s - 1), default_hl }
    end
    chunks[#chunks + 1] = { line:sub(m.s, m.e), m.hl }
    cursor = m.e + 1
  end
  if #chunks == 0 then chunks[1] = { "", default_hl } end
  return chunks
end

-- Public: classify a single line in isolation. Used by tests; `chunks`
-- below calls this once per line after fence-state tracking.
function M.style_line(line, in_fence)
  if in_fence then
    -- Inside a fenced code block: no inline markdown applies. Whole line
    -- renders with the raw-code highlight.
    return { { line, "@markup.raw.markdown" } }
  end
  -- ATX heading: 1-6 leading `#`s followed by at least one space.
  local hashes = line:match("^(#+)%s")
  if hashes and #hashes >= 1 and #hashes <= 6 then
    return { { line, ("@markup.heading.%d.markdown"):format(#hashes) } }
  end
  -- Horizontal rule.
  if line:match("^%s*%-%-%-+%s*$")
      or line:match("^%s*%*%*%*+%s*$")
      or line:match("^%s*___+%s*$") then
    return { { line, "Comment" } }
  end
  -- Blockquote.
  if line:match("^>%s") or line == ">" then
    return { { line, "@markup.quote.markdown" } }
  end
  -- List marker. Emit the marker as @markup.list, the rest with inline parsing.
  local marker_end = line:find("^%s*[-*+]%s") or line:find("^%s*%d+%.%s")
  if marker_end then
    local _, mend = line:find("^%s*[-*+]%s")
    if not mend then _, mend = line:find("^%s*%d+%.%s") end
    local prefix = line:sub(1, mend)
    local rest = line:sub(mend + 1)
    local out = { { prefix, "@markup.list.markdown" } }
    for _, ch in ipairs(_parse_inline(rest, DEFAULT_HL)) do
      out[#out + 1] = ch
    end
    return out
  end
  return _parse_inline(line, DEFAULT_HL)
end

-- Public: turn a markdown source string into a list of styled virt_lines
-- chunks. Each entry is `{ {text, hl}, ... }`. Tracks fenced-code state
-- across lines so the inside of a ``` block renders as raw code.
function M.chunks(text)
  local result = {}
  if text == nil or text == "" then return result end
  local lines = Util.split_lines(text)
  local in_fence = false
  for _, line in ipairs(lines) do
    if line:match("^```") then
      -- Fence boundary: render the fence line itself as code, then flip
      -- the state for subsequent lines.
      result[#result + 1] = { { line, "@markup.raw.markdown" } }
      in_fence = not in_fence
    else
      result[#result + 1] = M.style_line(line, in_fence)
    end
  end
  return result
end

return M
