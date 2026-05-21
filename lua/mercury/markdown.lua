-- Per-cell markdown injection via LanguageTree included regions. Each
-- markdown cell's body becomes a region parsed by the markdown TS parser, so
-- prose without `#` prefixes still highlights correctly.
--
-- This is the only mechanism Mercury uses for markdown highlighting. No
-- treesitter predicate or injection query is involved — the regions are
-- driven directly from the buffer's parsed cell list on every rescan.

local M = {}

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

  local children = parser:children()
  if not children.markdown then
    if not pcall(vim.treesitter.language.add, "markdown") then return end
    pcall(function() parser:add_child("markdown") end)
    children = parser:children()
  end
  if children.markdown then
    pcall(function() children.markdown:set_included_regions(regions) end)
  end
end

return M
