-- Verifies that Kernel:_handle_chunk respects the :h channel-lines protocol:
-- partial lines must be buffered across callbacks, not synthesized into
-- broken complete lines. Regression test for the bug where large outputs
-- (images, long stdout) crossing pipe-buffer boundaries got silently dropped.

local Kernel = require("mercury.kernel")
local Util = require("mercury.util")

local function fresh_client()
  local k = Kernel.new({})
  local got = {}
  k._handle_msg = function(_, msg) table.insert(got, msg) end
  return k, got
end

describe("kernel JSONL framing", function()
  it("emits a single complete message from a single chunk", function()
    local k, got = fresh_client()
    k:_handle_chunk({ '{"type":"output","cell_id":"a"}', "" })
    assert.equals(1, #got)
    assert.equals("output", got[1].type)
    assert.equals("a", got[1].cell_id)
  end)

  it("emits multiple complete messages from one chunk", function()
    local k, got = fresh_client()
    k:_handle_chunk({
      '{"type":"a","cell_id":"x"}',
      '{"type":"b","cell_id":"y"}',
      "",
    })
    assert.equals(2, #got)
    assert.equals("a", got[1].type)
    assert.equals("b", got[2].type)
  end)

  it("buffers a partial line until completed", function()
    -- A single message split across three callbacks. None should emit until
    -- a newline-bearing chunk arrives.
    local k, got = fresh_client()
    k:_handle_chunk({ '{"type":"out' })
    assert.equals(0, #got)
    k:_handle_chunk({ 'put","cell_id":' })
    assert.equals(0, #got)
    k:_handle_chunk({ '"a"}', "" })
    assert.equals(1, #got)
    assert.equals("output", got[1].type)
    assert.equals("a", got[1].cell_id)
  end)

  it("first element of a chunk extends the previous tail", function()
    -- Reproduces the exact pattern of `:h channel-lines`: when a callback's
    -- first element is non-empty it must be concatenated to the leftover.
    local k, got = fresh_client()
    k:_handle_chunk({ '{"type":"' })
    k:_handle_chunk({ 'foo"}', "" })
    assert.equals(1, #got)
    assert.equals("foo", got[1].type)
  end)

  it("handles two messages where the second is partial", function()
    local k, got = fresh_client()
    k:_handle_chunk({ '{"type":"a"}', '{"type":"par' })
    assert.equals(1, #got)
    assert.equals("a", got[1].type)
    k:_handle_chunk({ 'tial"}', "" })
    assert.equals(2, #got)
    assert.equals("partial", got[2].type)
  end)

  it("does not surface a message for undecodable lines (notify is best-effort)", function()
    -- Undecodable lines no longer pass through to _handle_msg. They fire a
    -- vim.notify (best-effort observability) but never produce a parsed
    -- message — that's the framing contract.
    local k, got = fresh_client()
    k:_handle_chunk({ "not json at all", "" })
    assert.equals(0, #got)
  end)

  it("does not emit anything for empty / single-empty chunks", function()
    local k, got = fresh_client()
    k:_handle_chunk({})
    k:_handle_chunk({ "" })
    assert.equals(0, #got)
  end)

  it("batches multiple corrupt lines into a single notify (debounced)", function()
    -- A library that prints to stdout produces multiple non-JSON lines.
    -- _emit_line accumulates them into _corrupt_buf and a single 100ms
    -- debounced timer emits a batched notification — saving the user from
    -- a flood of N notifies if the library spams stdout.
    -- Drain any prior scheduled notifies first so we count only ours.
    vim.wait(150, function() return false end)
    local k = Kernel.new({})
    local notifications = {}
    local Util = require("mercury.util")
    local orig = Util.notify
    Util.notify = function(msg)
      if type(msg) == "string" and msg:find("corrupt protocol") then
        notifications[#notifications + 1] = msg
      end
    end
    k:_emit_line("this is not json")
    k:_emit_line("neither is this")
    k:_emit_line("nor this third")
    -- Wait for the debouncer.
    vim.wait(200, function() return #notifications > 0 end)
    Util.notify = orig
    -- Single batched notify covering all three lines.
    assert.equals(1, #notifications,
      "all three corrupt lines must collapse into a single notify")
    assert.matches("3 corrupt protocol line", notifications[1])
  end)

  it("handles a single large message split into many tiny chunks", function()
    -- Worst-case fragmentation: every couple of bytes.
    local k, got = fresh_client()
    local msg = '{"type":"big","payload":"' .. string.rep("x", 200) .. '"}'
    -- Feed it 5 bytes at a time, single-element callbacks (no newline yet).
    local i = 1
    while i <= #msg do
      k:_handle_chunk({ msg:sub(i, i + 4) })
      i = i + 5
    end
    assert.equals(0, #got)
    -- Now the newline arrives.
    k:_handle_chunk({ "", "" })
    assert.equals(1, #got)
    assert.equals("big", got[1].type)
    assert.equals(200, #got[1].payload)
  end)
end)
