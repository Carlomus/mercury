-- Per-cell markdown injection via LanguageTree included regions. Each
-- markdown cell's body becomes a region parsed by the markdown TS parser, so
-- prose without `#` prefixes still highlights correctly.
--
-- This is the only mechanism Mercury uses for markdown highlighting. No
-- treesitter predicate or injection query is involved — the regions are
-- driven directly from the buffer's parsed cell list on every rescan.

local M = {}

-- Per-buffer cache of the last region key we set. If the new rescan
-- produces the same regions, skip the set_included_regions call entirely —
-- treesitter re-parsing the whole markdown subtree is the single largest
-- per-keystroke cost on a long notebook.
M._last_key = {}

local function regions_key(regions)
  local parts = {}
  for _, region in ipairs(regions) do
    for _, r in ipairs(region) do
      parts[#parts + 1] = table.concat(r, ",")
    end
    parts[#parts + 1] = "|"
  end
  return table.concat(parts, ";")
end

function M.update(buf, cells)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "python")
  if not ok or not parser then return end

  local regions = {}
  for _, cell in ipairs(cells) do
    if cell.kind == "markdown" and cell.body_end >= cell.body_start then
      local last = vim.api.nvim_buf_get_lines(buf, cell.body_end, cell.body_end + 1, false)[1] or ""
      regions[#regions + 1] = { { cell.body_start, 0, cell.body_end, #last } }
    end
  end

  local key = regions_key(regions)
  if M._last_key[buf] == key then return end

  local children = parser:children()
  if not children.markdown then
    if not pcall(vim.treesitter.language.add, "markdown") then return end
    pcall(function() parser:add_child("markdown") end)
    children = parser:children()
  end
  if children.markdown then
    pcall(function() children.markdown:set_included_regions(regions) end)
    M._last_key[buf] = key
  end
end

-- Forget a buffer's cached region key. Called from Notebook.detach so a
-- recycled bufnr can't inherit a stale entry that happens to match its
-- next rescan, silently skipping the set_included_regions call.
function M._forget(buf)
  M._last_key[buf] = nil
end

return M
