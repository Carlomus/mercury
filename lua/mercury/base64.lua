local M = {}

local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local LOOKUP = {}
for i = 1, #CHARS do LOOKUP[CHARS:sub(i, i)] = i - 1 end

function M.decode(data)
  if not data or data == "" then return "" end
  data = data:gsub("%s", "")
  data = data:gsub("[^" .. CHARS .. "=]", "")
  local pad = 0
  if data:sub(-2) == "==" then
    pad = 2
  elseif data:sub(-1) == "=" then
    pad = 1
  end
  data = data:gsub("=", "")
  local out = {}
  for i = 1, #data, 4 do
    local c1 = LOOKUP[data:sub(i, i)] or 0
    local c2 = LOOKUP[data:sub(i + 1, i + 1)] or 0
    local c3 = LOOKUP[data:sub(i + 2, i + 2)] or 0
    local c4 = LOOKUP[data:sub(i + 3, i + 3)] or 0
    local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    out[#out + 1] = string.char(math.floor(n / 256) % 256)
    out[#out + 1] = string.char(n % 256)
  end
  local s = table.concat(out)
  if pad > 0 then s = s:sub(1, #s - pad) end
  return s
end

return M
