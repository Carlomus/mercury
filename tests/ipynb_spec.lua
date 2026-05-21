local Ipynb = require("mercury.ipynb")
local Util = require("mercury.util")

local function fixture(name)
  local script = debug.getinfo(1, "S").source:sub(2)
  local dir = vim.fn.fnamemodify(script, ":p:h")
  return dir .. "/fixtures/" .. name
end

describe("ipynb codec", function()
  it("decodes a simple notebook", function()
    local data = Util.read_file(fixture("simple.ipynb"))
    assert.is_not_nil(data)
    local nb = Ipynb.decode(data)
    assert.equals(3, #nb.cells)
    assert.equals("code", nb.cells[1].kind)
    assert.equals("abc12345", nb.cells[1].id)
    assert.same({ "print('hello')" }, nb.cells[1].source)
    assert.equals(1, #nb.cells[1].outputs)
    assert.equals("stream", nb.cells[1].outputs[1].type)
    assert.equals("hello\n", nb.cells[1].outputs[1].text)

    assert.equals("markdown", nb.cells[2].kind)
    assert.same({ "# Heading", "some text" }, nb.cells[2].source)

    assert.equals("code", nb.cells[3].kind)
    assert.same({ "x = 42", "x" }, nb.cells[3].source)
    assert.equals("execute_result", nb.cells[3].outputs[1].type)
    assert.equals("42", nb.cells[3].outputs[1].data["text/plain"])
  end)

  it("preserves outputs through round trip", function()
    local data = Util.read_file(fixture("simple.ipynb"))
    local nb = Ipynb.decode(data)
    local roundtrip = Ipynb.encode(nb)
    local nb2 = Ipynb.decode(roundtrip)
    assert.equals(#nb.cells, #nb2.cells)
    for i = 1, #nb.cells do
      assert.equals(nb.cells[i].id, nb2.cells[i].id)
      assert.equals(nb.cells[i].kind, nb2.cells[i].kind)
      assert.same(nb.cells[i].source, nb2.cells[i].source)
      assert.equals(#nb.cells[i].outputs, #nb2.cells[i].outputs)
    end
  end)

  it("renders cells to buffer lines with separators", function()
    local data = Util.read_file(fixture("simple.ipynb"))
    local nb = Ipynb.decode(data)
    local lines = Ipynb.to_buffer_lines(nb)
    assert.matches("^# %%%% id=abc12345", lines[1])
    -- Find the markdown header row.
    local md_row
    for i, line in ipairs(lines) do
      if line:match("id=def67890") then md_row = i; break end
    end
    assert.is_not_nil(md_row)
    assert.matches("%[markdown%]", lines[md_row])
  end)

  it("scan_lines finds cells and assigns missing ids", function()
    local lines = {
      "# %%",
      "print(1)",
      "# %% id=fixed01ab",
      "print(2)",
      "# %% [markdown]",
      "# heading",
    }
    local r = Ipynb.scan_lines(lines)
    assert.equals(3, #r.cells)
    assert.is_true(r.mutated)
    assert.is_string(r.cells[1].id)
    assert.equals("fixed01ab", r.cells[2].id)
    assert.equals("markdown", r.cells[3].kind)
    assert.equals(0, r.cells[1].header_row)
    assert.equals(1, r.cells[1].body_start)
    assert.equals(1, r.cells[1].body_end)
  end)

  it("scan_lines synthesizes a cell when there is no separator", function()
    local lines = { "x = 1", "y = 2" }
    local r = Ipynb.scan_lines(lines)
    assert.equals(1, #r.cells)
    assert.equals(-1, r.cells[1].header_row)
    assert.equals(0, r.cells[1].body_start)
    assert.equals(1, r.cells[1].body_end)
    assert.is_true(r.cells[1].injected_separator)
  end)

  it("encoded JSON is indented (diff-friendly) and round-trips", function()
    local data = Util.read_file(fixture("simple.ipynb"))
    local nb = Ipynb.decode(data)
    local encoded = Ipynb.encode(nb)
    -- Should be multi-line (nbformat convention is 1-space indent).
    local nl_count = select(2, encoded:gsub("\n", "\n"))
    assert.is_true(nl_count > 5,
      "expected multi-line encoded JSON, got " .. nl_count .. " newlines")
    -- And it should still round-trip cleanly.
    local nb2 = Ipynb.decode(encoded)
    assert.equals(#nb.cells, #nb2.cells)
    for i = 1, #nb.cells do
      assert.equals(nb.cells[i].id, nb2.cells[i].id)
      assert.same(nb.cells[i].source, nb2.cells[i].source)
    end
  end)

  it("reindent preserves strings containing JSON-significant chars", function()
    -- Strings with braces/brackets must not trigger indentation.
    local raw = '{"a":"he said {x:1, y:[2,3]}","b":42}'
    local pretty = Ipynb._reindent_json(raw)
    -- The string content survives unchanged.
    assert.matches('"he said {x:1, y:%[2,3%]}"', pretty)
    -- And it parses back to the same Lua shape.
    local ok, decoded = pcall(vim.json.decode, pretty)
    assert.is_true(ok)
    assert.equals("he said {x:1, y:[2,3]}", decoded.a)
    assert.equals(42, decoded.b)
  end)
end)
