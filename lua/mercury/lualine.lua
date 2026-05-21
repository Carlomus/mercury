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

function M.kernel()
  local n = nb(); if not n then return "" end
  local name = (n.meta and n.meta.kernelspec and n.meta.kernelspec.name) or "python3"
  return ("⎈ %s"):format(name)
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
