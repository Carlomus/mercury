-- Strip ANSI control sequences from kernel stream output before rendering as
-- virt_lines. The renderer can't interpret CSI / OSC / Fe escapes; leaving
-- them in produces visual garbage (bracketed sequences in tracebacks,
-- hyperlink payloads next to URLs, etc.).
--
-- Hand-rolled byte-at-a-time scanner instead of a single regex because:
--   - OSC's two legal terminators (BEL or ESC\) trip up a greedy gsub: a
--     character-class like `[\7\27]` matches whichever comes first, and the
--     pattern then over-eats the leading ESC of an adjacent CSI.
--   - A trailing `\\?` to absorb the `\` of an ESC\ terminator gobbles
--     literal backslashes in subsequent output (e.g. Windows paths after a
--     hyperlink).
--   - Orphan ESC bytes from chunk-boundary truncation must collapse to
--     nothing without consuming the next byte.

local M = {}

function M.strip(s)
  if not s or s == "" then return s or "" end
  local out = {}
  local i = 1
  local n = #s
  while i <= n do
    local b = s:byte(i)
    if b == 0x1b then                                      -- ESC
      local nb = s:byte(i + 1)
      if nb == 0x5b then                                   -- ESC [ -> CSI
        -- params (0x30-0x3F) then intermediates (0x20-0x2F) then final (0x40-0x7E)
        local j = i + 2
        while j <= n do
          local bj = s:byte(j)
          if bj >= 0x30 and bj <= 0x3f then j = j + 1 else break end
        end
        while j <= n do
          local bj = s:byte(j)
          if bj >= 0x20 and bj <= 0x2f then j = j + 1 else break end
        end
        if j <= n then
          local bj = s:byte(j)
          if bj >= 0x40 and bj <= 0x7e then
            i = j + 1
          else
            i = i + 1                                      -- incomplete CSI; eat ESC only
          end
        else
          i = i + 1                                        -- truncated at chunk boundary
        end
      elseif nb == 0x5d then                               -- ESC ] -> OSC
        local j = i + 2
        local terminated = false
        while j <= n do
          local bj = s:byte(j)
          if bj == 0x07 then                               -- BEL terminator
            i = j + 1
            terminated = true
            break
          elseif bj == 0x1b and s:byte(j + 1) == 0x5c then -- ESC \ (ST) terminator
            i = j + 2
            terminated = true
            break
          end
          j = j + 1
        end
        if not terminated then
          i = i + 1                                        -- no terminator; eat ESC only
        end
      elseif nb and nb >= 0x40 and nb <= 0x5f then         -- Fe escapes (NEL, IND, RI, etc.)
        i = i + 2
      else
        i = i + 1                                          -- orphan ESC
      end
    elseif b == 0x0d then                                  -- \r
      if s:byte(i + 1) == 0x0a then
        out[#out + 1] = "\n"
        i = i + 2
      else
        out[#out + 1] = "\n"
        i = i + 1
      end
    else
      out[#out + 1] = s:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

return M
