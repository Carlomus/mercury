-- Produce the LSP-facing view of a mercury buffer.
--
-- Strategy: for every line inside a [markdown] cell, prepend "# " so the LSP
-- server sees a python comment where prose used to be. Code cell lines and
-- separator lines pass through unchanged. Line counts and column positions on
-- code lines are preserved, so all LSP positions can use identity mapping.
--
-- See SPEC.md "LSP integration" for the rationale.

local Notebook = require("mercury.notebook")

local M = {}

local MARKDOWN_PREFIX = "# "

-- Pure: given a list of buffer lines and the notebook's parsed cells, return
-- the masked-lines list (same length as input). Exposed for testing.
--
-- Trailing \r on a markdown-cell line is stripped before the "# " prefix is
-- applied (SPEC Invariant 31). Vim buffers can carry CR on Windows-authored
-- ipynb that has CRLF line endings inside cell bodies; without stripping,
-- the LSP server would see "# prose\r" with the CR breaking some servers'
-- per-line position accounting. We don't touch code-cell lines — those
-- pass through unchanged so identity column mapping isn't disturbed.
function M.mask_lines(lines, cells)
  local masked = {}
  for i, ln in ipairs(lines) do masked[i] = ln end
  for _, c in ipairs(cells or {}) do
    if c.kind == "markdown" and c.body_end >= c.body_start then
      for row = c.body_start, c.body_end do
        local idx = row + 1  -- 0-indexed row -> 1-indexed list
        local ln = masked[idx]
        if ln ~= nil then
          -- Strip a single trailing CR before prefixing.
          if ln:sub(-1) == "\r" then ln = ln:sub(1, -2) end
          masked[idx] = MARKDOWN_PREFIX .. ln
        end
      end
    end
  end
  return masked
end

-- Convenience: get the masked text for a live buffer. Returns the joined
-- string (no trailing newline) ready to send as textDocument.text.
function M.masked_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local nb = Notebook.get(buf)
  if not nb then
    return table.concat(lines, "\n")
  end
  return table.concat(M.mask_lines(lines, nb.cells), "\n")
end

return M
