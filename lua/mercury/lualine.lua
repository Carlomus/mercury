-- Status-line components for lualine.nvim. Each component is a function
-- returning a short string. They auto-detect the current buffer; if the
-- buffer is not a Mercury notebook, they return "".
--
-- Example lualine config:
--
--   local mlual = require("mercury.lualine")
--   require("lualine").setup({
--     sections = {
--       lualine_x = { mlual.kernel, mlual.queue, mlual.last_exec },
--     },
--   })

local Notebook = require("mercury.notebook")

local M = {}

local function nb()
  return Notebook.get(vim.api.nvim_get_current_buf())
end

-- Short display label for an arbitrary kernel selector string. If the
-- selector looks like an absolute python path, run it through
-- `Discover.short_label` (e.g. `/work/proj/.venv/bin/python` → `.venv (proj)`)
-- so the lualine doesn't get crowded; otherwise return it as-is.
local function _short(selector)
  if type(selector) ~= "string" or selector == "" then return selector end
  -- Heuristic: absolute path containing a `/` AND ending in `python*` is a
  -- python executable. Anything else (kernelspec name, registered alias) is
  -- already short.
  if selector:sub(1, 1) == "/" and selector:match("python[^/]*$") then
    local ok, Discover = pcall(require, "mercury.discover")
    if ok and Discover.short_label then
      return Discover.short_label(selector)
    end
  end
  return selector
end

function M.kernel()
  local n = nb(); if not n then return "" end
  -- Prefer the active selector (b:mercury_kernel_name is updated by
  -- attach_buffer and select_kernel) so what lualine shows matches the
  -- interpreter the bridge actually runs against. Fall back to
  -- metadata.kernelspec.name for notebooks that haven't gone through
  -- attach yet (e.g., the buffer was never opened).
  local active = vim.b[n.buf].mercury_kernel_name
  local name = active
    or (n.meta and n.meta.kernelspec and n.meta.kernelspec.name)
    or "python3"
  return ("⎈ %s"):format(_short(name))
end

function M.queue()
  local n = nb(); if not n or not n.kernel then return "" end
  local k = n.kernel
  if k.running then
    return ("⏳ run %s"):format(k.running.cell_id and k.running.cell_id:sub(1, 6) or "")
  end
  if #k.queue > 0 then
    return ("⏸ queue=%d"):format(#k.queue)
  end
  return "✓ idle"
end

function M.last_exec()
  local n = nb(); if not n then return "" end
  -- Find the most-recently-executed cell with an exec_count.
  local best
  for _, c in ipairs(n.cells) do
    local out = n.outputs[c.id]
    if out and out.exec_count and (not best or out.exec_count > best.exec_count) then
      best = out
    end
  end
  if not best then return "" end
  return ("Out[%s] %s ms"):format(best.exec_count, best.ms or 0)
end

function M.cell_count()
  local n = nb(); if not n then return "" end
  return ("%d cells"):format(#n.cells)
end

function M.current_cell()
  local n = nb(); if not n then return "" end
  local cell, idx = n:cell_at_row()
  if not cell then return "" end
  return ("cell %d/%d %s"):format(idx, #n.cells, cell.kind == "markdown" and "md" or "py")
end

return M
