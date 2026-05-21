-- Verifies that unknown separator tokens (foo=bar) survive a JSON save+load
-- round-trip via metadata.mercury_extras. SPEC.md "Separator extras
-- round-trip" promises this; without the stash, the buffer text and the
-- saved file diverge on the first :w.

local Ipynb = require("mercury.ipynb")
local Notebook = require("mercury.notebook")

describe("separator extras round-trip", function()
  it("format_separator emits unknown extras alphabetically after tags", function()
    local line = Ipynb.format_separator({
      id = "abc12345",
      kind = "code",
      metadata = { tags = { "a", "b" } },
      extras = { beta = "2", alpha = "1" },
    })
    assert.equals("# %% id=abc12345 tags=a,b alpha=1 beta=2", line)
  end)

  it("format_separator emits no extras section when none are present", function()
    local line = Ipynb.format_separator({ id = "abc12345", kind = "code" })
    assert.equals("# %% id=abc12345", line)
  end)

  it("to_buffer_lines surfaces metadata.mercury_extras back into separators", function()
    local doc = {
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = {
        { id = "abc12345", kind = "code",
          source = { "x = 1" }, outputs = {},
          metadata = { mercury_extras = { foo = "bar" } } },
      },
    }
    local lines = Ipynb.to_buffer_lines(doc)
    assert.equals("# %% id=abc12345 foo=bar", lines[1])
  end)

  it("notebook stashes unknown extras under mercury_extras on save", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=abc12345 foo=bar tags=t1,t2",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local struct = nb:to_ipynb_struct()
    local meta = struct.cells[1].metadata
    -- tags get the structured treatment, foo lands in mercury_extras.
    assert.same({ "t1", "t2" }, meta.tags)
    assert.same({ foo = "bar" }, meta.mercury_extras)
    Notebook.detach(buf)
  end)

  it("round-trips an unknown extra through encode -> decode -> render", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=abc12345 foo=bar",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local struct = nb:to_ipynb_struct()
    local json = Ipynb.encode(struct)
    local decoded = Ipynb.decode(json)
    local lines = Ipynb.to_buffer_lines(decoded)
    assert.equals("# %% id=abc12345 foo=bar", lines[1])
    Notebook.detach(buf)
  end)

  it("round-trips extras keys containing underscore, hyphen, and dot", function()
    -- Lua's `%w` doesn't include `_`, so a naive `(%w+)=...` parse would
    -- silently drop these keys (or worse — `foo_bar=v` would parse as
    -- `bar=v` because gmatch would skip past the underscore). JSON metadata
    -- routinely uses underscore identifiers; without this, a notebook
    -- produced by another tool with `metadata.mercury_extras.my_key = "v"`
    -- would lose `my_key` on the first :w after mercury reads it.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=abc12345 snake_key=u dash-key=h dotted.key=d",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local struct = nb:to_ipynb_struct()
    assert.same(
      { ["snake_key"] = "u", ["dash-key"] = "h", ["dotted.key"] = "d" },
      struct.cells[1].metadata.mercury_extras)
    Notebook.detach(buf)
  end)

  it("warns when an extras value would be truncated by ']' or whitespace", function()
    -- parse_meta's value capture is `[^%s%]]+`, so an externally-edited JSON
    -- whose mercury_extras carries either character will silently round-trip
    -- as the truncated prefix. We warn so the user can fix the JSON or
    -- accept the truncation. Two cases: whitespace, and the `]` flag char.
    local warnings = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if type(msg) == "string" and msg:find("mercury_extras") then
        warnings[#warnings + 1] = { msg = msg, level = level }
      end
    end

    local doc = {
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = {
        { id = "ws000001", kind = "code", source = { "" }, outputs = {},
          metadata = { mercury_extras = { foo = "a b" } } },
        { id = "br000001", kind = "code", source = { "" }, outputs = {},
          metadata = { mercury_extras = { foo = "a]b" } } },
        { id = "both0001", kind = "code", source = { "" }, outputs = {},
          metadata = { mercury_extras = { foo = "a ]b" } } },
      },
    }
    Ipynb.to_buffer_lines(doc)
    -- Drain scheduled callbacks.
    vim.wait(20, function() return #warnings >= 3 end)
    vim.notify = orig_notify

    assert.equals(3, #warnings)
    assert.matches("whitespace", warnings[1].msg)
    assert.matches("'%]'", warnings[2].msg)
    -- The both-violations case names both.
    assert.matches("whitespace", warnings[3].msg)
    assert.matches("'%]'", warnings[3].msg)
  end)

  it("format_separator emits [markdown] flag before tags and extras", function()
    -- Token order in the separator matters because the buffer text is
    -- canonical: a regression that moves `[markdown]` after tags would
    -- silently change the format users see, and external tooling that
    -- parses the separator (jupytext, vscode jupyter percent format) might
    -- expect the flag to appear in the early position.
    local line = Ipynb.format_separator({
      id = "abcd1234",
      kind = "markdown",
      metadata = { tags = { "a", "b" } },
      extras = { alpha = "1" },
    })
    assert.equals("# %% id=abcd1234 [markdown] tags=a,b alpha=1", line)
  end)

  it("format_separator drops extras keys outside [A-Za-z0-9_.-]", function()
    -- parse_meta's key class is `[%w_%-%.]+`; emitting a key with chars
    -- outside that set produces a separator line that won't survive a
    -- rescan (parse_meta would mis-capture or skip it). Drop bad keys on
    -- emission so the buffer text always parses back to itself.
    local line = Ipynb.format_separator({
      id = "abc12345", kind = "code",
      extras = { ["weird+key"] = "v", ok = "x" },
    })
    assert.equals("# %% id=abc12345 ok=x", line)
  end)

  it("to_buffer_lines warns when mercury_extras contains a bad key", function()
    local warnings = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if type(msg) == "string" and msg:find("mercury_extras key") then
        warnings[#warnings + 1] = { msg = msg, level = level }
      end
    end

    Ipynb.to_buffer_lines({
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = {
        { id = "bk000001", kind = "code", source = { "" }, outputs = {},
          metadata = { mercury_extras = { ["bad key"] = "v" } } },
      },
    })
    vim.wait(20, function() return #warnings >= 1 end)
    vim.notify = orig_notify

    assert.equals(1, #warnings)
    assert.matches("bad key", warnings[1].msg)
    assert.matches("dropped from the separator", warnings[1].msg)
  end)

  it("format_separator drops reserved extras keys 'id' and 'tags' (H5)", function()
    -- The canonical `id=` (cell.id) and `tags=` (metadata.tags) are emitted
    -- from their own sources. An extras key with these names would either
    -- be ignored (id: first match wins on reparse) or silently filtered
    -- (tags: skipped here). Drop them on emission so the output is what
    -- the next reparse will see — symmetric.
    local line = Ipynb.format_separator({
      id = "abc12345", kind = "code",
      metadata = { tags = { "real" } },
      extras = { id = "fake", tags = "ghost", ok = "value" },
    })
    assert.equals("# %% id=abc12345 tags=real ok=value", line)
  end)

  it("to_buffer_lines warns when mercury_extras contains reserved 'id' key (H5)", function()
    local warnings = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if type(msg) == "string" and msg:find("reserved") then
        warnings[#warnings + 1] = { msg = msg, level = level }
      end
    end
    Ipynb.to_buffer_lines({
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = {
        { id = "rk000001", kind = "code", source = { "" }, outputs = {},
          metadata = { mercury_extras = { id = "fake" } } },
        { id = "rk000002", kind = "code", source = { "" }, outputs = {},
          metadata = { mercury_extras = { tags = "ghost" } } },
      },
    })
    vim.wait(20, function() return #warnings >= 2 end)
    vim.notify = orig_notify
    assert.equals(2, #warnings)
    -- Both messages name the reserved-token alternative source.
    local found_id, found_tags = false, false
    for _, w in ipairs(warnings) do
      if w.msg:find('"id"') then found_id = true end
      if w.msg:find('"tags"') then found_tags = true end
    end
    assert.is_true(found_id)
    assert.is_true(found_tags)
  end)

  it("parse_meta does not gobble the next key when a value is empty (H4)", function()
    -- Pre-fix: the gmatch pattern `([%w_%-%.]+)%s*=%s*([^%s%]]+)` allowed
    -- whitespace between `=` and the value. For input `id=abc tags= foo=bar`
    -- (a degenerate `tags=` followed by another token), the value class
    -- greedily consumed `foo=bar` AFTER the whitespace — producing
    -- tags="foo=bar" and silently swallowing the foo extra. Round-trip lost
    -- the foo extra entirely.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=abc12345 tags= foo=bar",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local struct = nb:to_ipynb_struct()
    local meta = struct.cells[1].metadata
    -- tags is empty (no value), so it must not appear.
    assert.is_nil(meta.tags)
    -- foo must land in mercury_extras as the user intended.
    assert.same({ foo = "bar" }, meta.mercury_extras)
    Notebook.detach(buf)
  end)

  it("clears mercury_extras when no unknown extras remain", function()
    -- User deletes the foo=bar token from the separator — the JSON should
    -- not retain a stale mercury_extras = {} either.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=abc12345",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Pretend we previously loaded the cell with a stash.
    nb.cell_metadata["abc12345"] = { mercury_extras = { foo = "bar" } }
    local struct = nb:to_ipynb_struct()
    assert.is_nil(struct.cells[1].metadata.mercury_extras)
    Notebook.detach(buf)
  end)
end)
