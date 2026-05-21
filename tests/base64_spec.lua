local B = require("mercury.base64")

describe("base64.decode", function()
  it("decodes a padded value to the original bytes", function()
    -- Canonical RFC 4648 form: 5 bytes, requires `=` padding to 8 chars.
    assert.equals("hello", B.decode("aGVsbG8="))
  end)

  it("decodes a value with `==` padding (one-byte input)", function()
    assert.equals("f", B.decode("Zg=="))
  end)

  it("decodes a value with `=` padding (two-byte input)", function()
    assert.equals("fo", B.decode("Zm8="))
  end)

  it("decodes an unpadded value without emitting trailing null bytes", function()
    -- Producers that strip `=` (legal under RFC 4648 §3.2) previously
    -- caused a stray "\0" at the end because the decoder assumed pad=0
    -- whenever no `=` was found. That broke PNG/JPEG byte streams downstream
    -- (corrupt bytes ended up in the cache). Derive pad from `#data % 4`.
    assert.equals("hello", B.decode("aGVsbG8"))
    assert.equals("f", B.decode("Zg"))
    assert.equals("fo", B.decode("Zm8"))
  end)

  it("decodes an unpadded multi-quad value", function()
    assert.equals("hello world", B.decode("aGVsbG8gd29ybGQ"))
    assert.equals("hello world", B.decode("aGVsbG8gd29ybGQ=")) -- padded equivalent
  end)

  it("decodes a 3n-length value without padding (already byte-aligned)", function()
    -- 6 input chars -> 4.5 bytes? No — 6 chars * 6 bits = 36 bits = 4.5 bytes.
    -- Actually: 4-char inputs = 3 bytes, 8-char = 6 bytes; 6 chars is in
    -- the "padding-2" form. Use a 4-char input here for the 3n bytes case.
    assert.equals("Man", B.decode("TWFu"))   -- 3 bytes, no padding needed
    assert.equals("foob", B.decode("Zm9vYg==")) -- 4 bytes, 2 pad
  end)

  it("returns empty string for empty input", function()
    assert.equals("", B.decode(""))
    assert.equals("", B.decode(nil))
  end)

  it("decodes a real PNG header (round-trip safety for image outputs)", function()
    -- 1x1 transparent PNG (canonical example bytes from nbformat test fixtures).
    local b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
    local bytes = B.decode(b64)
    -- PNG signature: 0x89 50 4E 47 0D 0A 1A 0A
    assert.equals(string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A),
      bytes:sub(1, 8))
    -- And: IEND chunk at the tail = "IEND" + CRC.
    assert.is_not_nil(bytes:find("IEND", 1, true))
  end)

  it("strips whitespace inside the input", function()
    assert.equals("hello", B.decode("aGVs\nbG8="))
    assert.equals("hello", B.decode("a G V s b G 8 ="))
  end)

  it("ignores out-of-alphabet characters", function()
    -- Garbage chars get filtered out; the alphabetical content still decodes.
    assert.equals("hello", B.decode("a!G@V#s$b%G^8&="))
  end)

  it("drops a trailing odd char when input length % 4 == 1 (malformed)", function()
    -- A well-formed base64 input never has length 1 mod 4. Producing such
    -- a length means the input is malformed (a single trailing char that
    -- can't represent any byte). The decoder strips the stray char rather
    -- than crashing. Output is whatever the leading well-formed quad set
    -- decoded to.
    -- "aGVsbG8gd29ybGQa" is 16 chars = "hello world\x1a", well-formed.
    -- Append one more char to make 17 (== 1 mod 4) — the trailing 'a' is dropped.
    local out = B.decode("aGVsbG8gd29ybGQa" .. "X")
    -- The first 16 chars still decode normally.
    assert.equals("hello world\x1a", out)
  end)
end)
