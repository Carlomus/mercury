local M = {}

local CSI = "\27%[[0-?]*[ -/]*[@-~]"
local ESC_OTHER = "\27[@-Z\\-_]"

function M.strip(s)
  if not s or s == "" then return s or "" end
  s = s:gsub(CSI, "")
  s = s:gsub(ESC_OTHER, "")
  s = s:gsub("\r\n", "\n")
  s = s:gsub("\r", "\n")
  return s
end

return M
