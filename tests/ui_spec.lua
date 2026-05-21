-- ui.lua's Renderer is the visible side of mercury. A regression in the
-- separator, id-conceal, code/markdown-background, or output-extmark logic
-- doesn't break the kernel or storage layer — it just makes the editor
-- look wrong. These tests exercise the Renderer end-to-end and assert on
-- the extmarks it produces.

local UI = require("mercury.ui")
local Notebook = require("mercury.notebook")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".ipynb")
  vim.bo[buf].filetype = "python"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function extmarks_in(buf, ns_name)
  local ns = Notebook.ns(ns_name)
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

describe("ui.Renderer", function()
  it("places separator and concealment extmarks on cell headers", function()
    local buf = make_buf({
      "# %% id=ui000001",
      "x = 1",
      "# %% id=ui000002 [markdown]",
      "# prose",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local r = UI.new(nb)
    r:render()
    -- A separator extmark exists for each cell's header row.
    local sep_marks = extmarks_in(buf, "separator")
    -- At least 2 separator marks (the per-cell header highlight).
    assert.is_true(#sep_marks >= 2)
    Notebook.detach(buf)
  end)

  it("conceals dotted ids in headers (regex includes '.')", function()
    -- The conceal regex now accepts `[%w_%-%.]+`. Pin that an id with a
    -- dot gets concealed entirely (no leading `.bar` visible after the
    -- concealed `id=foo`).
    local buf = make_buf({
      "# %% id=ui.dot01",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local r = UI.new(nb)
    r:render()
    -- The conceal extmark on the separator should span the entire id
    -- including the `.dot01` portion.
    local sep_marks = extmarks_in(buf, "separator")
    local conceal_mark
    for _, m in ipairs(sep_marks) do
      if m[4] and m[4].conceal == "" then conceal_mark = m end
    end
    assert.is_not_nil(conceal_mark, "expected at least one conceal extmark")
    -- end_col should be at least 16 (= " id=ui.dot01") past the start.
    if conceal_mark then
      local start_col = conceal_mark[3]
      local end_col = conceal_mark[4].end_col
      assert.is_true(end_col - start_col >= 12,
        "conceal must cover the entire dotted id")
    end
    Notebook.detach(buf)
  end)

  it("clears all extmarks via clear_all()", function()
    local buf = make_buf({
      "# %% id=clr00001",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local r = UI.new(nb)
    r:render()
    r:clear_all()
    -- After clear_all, no extmarks in any of mercury's namespaces.
    for _, ns_name in ipairs({ "separator", "hl_code", "hl_md", "output" }) do
      assert.equals(0, #extmarks_in(buf, ns_name),
        "expected no extmarks in " .. ns_name .. " after clear_all")
    end
    Notebook.detach(buf)
  end)

  it("renders output extmark when a cell has output", function()
    local buf = make_buf({
      "# %% id=outx0001",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb:ensure_output("outx0001").items = {
      { type = "stream", name = "stdout", text = "hi\n" },
    }
    nb:ensure_output("outx0001").status = "ok"
    nb:ensure_output("outx0001").exec_count = 1
    nb:ensure_output("outx0001").ms = 5
    local r = UI.new(nb)
    r:render()
    -- One output extmark for the cell.
    local marks = extmarks_in(buf, "output")
    assert.equals(1, #marks)
    -- The extmark has virt_lines.
    assert.is_not_nil(marks[1][4].virt_lines)
    Notebook.detach(buf)
  end)

  it("output extmark id is reused across renders for the same cell", function()
    -- Pre-fix risk: a fresh extmark per render would orphan the previous
    -- one and leak. The id-reuse path keeps a single extmark per cell.
    local buf = make_buf({
      "# %% id=reuse001",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb:ensure_output("reuse001").items = { { type = "stream", text = "a" } }
    nb:ensure_output("reuse001").status = "ok"
    local r = UI.new(nb)
    r:render()
    local m1 = extmarks_in(buf, "output")
    local id1 = m1[1][1]
    r:render()
    local m2 = extmarks_in(buf, "output")
    -- Same number of marks.
    assert.equals(1, #m2)
    -- Same id (reused via opts.id).
    assert.equals(id1, m2[1][1])
    Notebook.detach(buf)
  end)

  it("no output extmark on a markdown cell", function()
    local buf = make_buf({
      "# %% id=md000001 [markdown]",
      "prose",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Markdown cells have no outputs by spec; rescan would clear any
    -- if they snuck in. Just verify the renderer doesn't emit one.
    local r = UI.new(nb)
    r:render()
    assert.equals(0, #extmarks_in(buf, "output"))
    Notebook.detach(buf)
  end)

  it("setup_highlights does not raise", function()
    -- We can't reliably assert ColorScheme effects in headless; just pin
    -- that the function runs without raising.
    assert.has_no.errors(function() UI.setup_highlights() end)
  end)
end)
