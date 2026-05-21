-- Mercury strips ANSI control sequences from kernel stream output before
-- rendering it as virt_lines. The renderer can't actually interpret CSI /
-- OSC / Fe escapes, and leaving them in produces visual garbage (extra
-- bracketed sequences in tracebacks, hyperlink payloads next to URLs, etc.).
--
-- These specs pin the contract for the most common shapes mercury sees in
-- real notebooks.

local Ansi = require("mercury.ansi")

describe("ansi.strip", function()
  it("removes CSI color sequences", function()
    -- ESC [ 31m red; ESC [ 0m reset. Common in pytest output, rich tracebacks.
    local s = "\27[31mhello\27[0m world"
    assert.equals("hello world", Ansi.strip(s))
  end)

  it("removes OSC 8 hyperlink sequences (BEL-terminated)", function()
    -- ESC ] 8 ; ; URL BEL TEXT ESC ] 8 ; ; BEL — Jupyter Lab uses this
    -- shape for clickable file references in tracebacks. Without OSC
    -- support in ansi.strip the URL and bracketed delimiters render as
    -- garbage; only the bare TEXT should survive.
    local s = "\27]8;;https://example.com\7clickme\27]8;;\7"
    assert.equals("clickme", Ansi.strip(s))
  end)

  it("removes OSC sequences with ST (ESC \\) terminator", function()
    -- ECMA-48 lets OSC end with ST (`ESC \`) instead of BEL. Less common
    -- but legal; emitting tools occasionally use it.
    local s = "\27]0;window title\27\\after"
    assert.equals("after", Ansi.strip(s))
  end)

  it("strips orphan ESC bytes (truncated sequence at a chunk boundary)", function()
    -- Streaming chunks can split mid-sequence. The CSI/OSC regex won't
    -- match a partial; the final ESC-sweep prevents a stray `\27` from
    -- corrupting the render.
    assert.equals("ab", Ansi.strip("a\27b"))
  end)

  it("removes Fe single-byte escapes (NEL, IND, RI, etc.)", function()
    -- ESC E (NEL, next line, 0x45) is in the Fe range (0x40-0x5F) the
    -- ESC_OTHER regex handles. The trailing content survives.
    assert.equals("after", Ansi.strip("\27Eafter"))
  end)

  it("normalizes line endings", function()
    assert.equals("a\nb\nc", Ansi.strip("a\r\nb\rc"))
  end)

  it("is a no-op on plain text", function()
    assert.equals("hello world", Ansi.strip("hello world"))
  end)

  it("handles empty and nil inputs", function()
    assert.equals("", Ansi.strip(""))
    assert.equals("", Ansi.strip(nil))
  end)

  it("does not eat the leading ESC of an adjacent sequence after a BEL-terminated OSC", function()
    -- Pre-fix: `\27%][^\7\27]*[\7\27]\\?` was greedy on the terminator class.
    -- For input `OSC_8;;url BEL ESC[31m red ESC[0m`, the OSC match would
    -- consume the BEL AND then greedily eat the ESC starting the CSI,
    -- leaving `[31m red [0m` as visible text in the output.
    local s = "\27]8;;https://x.io\7\27[31mred\27[0m text"
    assert.equals("red text", Ansi.strip(s))
  end)

  it("does not consume a literal backslash following a BEL-terminated OSC", function()
    -- Pre-fix: the `\\?` at the end of the OSC pattern would gobble a real
    -- backslash in the output (mistaking it for a stray `\` of an ST
    -- terminator). Output containing escaped paths after a hyperlink would
    -- lose their leading `\`.
    local s = "\27]8;;file:///x\7\\path\\name"
    assert.equals("\\path\\name", Ansi.strip(s))
  end)

  it("strips CSI sequences with intermediate bytes (0x20-0x2F)", function()
    -- The CSI pattern allows zero-or-more intermediate chars between
    -- parameters and the final byte. e.g. `ESC [ ? 25 h` is "show cursor"
    -- — the `?` is in the parameter range here, but real intermediates
    -- like `ESC [ 1 ; 2 SP @` would be in 0x20-0x2F.
    -- We exercise the param-byte branch with a private-mode-set sequence.
    local s = "before\27[?25hafter"
    assert.equals("beforeafter", Ansi.strip(s))
  end)

  it("strips a CSI without parameters or intermediates", function()
    -- Bare CSI: ESC [ <final-byte>. Common shape, e.g. ESC [ H (home).
    assert.equals("ab", Ansi.strip("a\27[Hb"))
  end)

  it("strips two consecutive OSCs back-to-back", function()
    -- The opening / closing OSC 8 pair from Jupyter; the previous regex
    -- worked for this case but pin it explicitly so a future refactor
    -- doesn't regress.
    local s = "before \27]8;;u\7TEXT\27]8;;\7 after"
    assert.equals("before TEXT after", Ansi.strip(s))
  end)
end)
