local M = {}

local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local LOOKUP = {}
for i = 1, #CHARS do LOOKUP[CHARS:sub(i, i)] = i - 1 end

function M.decode(data)
  if not data or data == "" then return "" end
  data = data:gsub("%s", "")
  data = data:gsub("[^" .. CHARS .. "=]", "")
  data = data:gsub("=", "")    -- drop any explicit padding; we infer from length

  local out = {}
  local n = #data
  local full_quads = math.floor(n / 4)
  for q = 0, full_quads - 1 do
    local i = q * 4 + 1
    local c1 = LOOKUP[data:sub(i, i)] or 0
    local c2 = LOOKUP[data:sub(i + 1, i + 1)] or 0
    local c3 = LOOKUP[data:sub(i + 2, i + 2)] or 0
    local c4 = LOOKUP[data:sub(i + 3, i + 3)] or 0
    local v = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
    out[#out + 1] = string.char(math.floor(v / 65536) % 256)
    out[#out + 1] = string.char(math.floor(v / 256) % 256)
    out[#out + 1] = string.char(v % 256)
  end
  -- Tail group: 0, 2, or 3 chars. A 1-char tail is malformed (no whole byte
  -- is recoverable from 6 bits); drop it silently rather than emit garbage.
  -- For 2 / 3 chars we treat the missing chars as 0 and emit only the
  -- well-defined bytes (1 byte for 2-char tail, 2 bytes for 3-char tail).
  local rem = n - full_quads * 4
  if rem == 2 or rem == 3 then
    local i = full_quads * 4 + 1
    local c1 = LOOKUP[data:sub(i, i)] or 0
    local c2 = LOOKUP[data:sub(i + 1, i + 1)] or 0
    local c3 = (rem == 3) and (LOOKUP[data:sub(i + 2, i + 2)] or 0) or 0
    local v = c1 * 262144 + c2 * 4096 + c3 * 64    -- c4 = 0 (absent)
    out[#out + 1] = string.char(math.floor(v / 65536) % 256)
    if rem == 3 then
      out[#out + 1] = string.char(math.floor(v / 256) % 256)
    end
  end
  return table.concat(out)
end

return M
