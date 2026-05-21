-- Status-line components are a documented integration surface (README).
-- A regression that misreads notebook/kernel state would silently make
-- every lualine-using user see wrong content. Pin the contract.

local Lualine = require("mercury.lualine")
local Notebook = require("mercury.notebook")

local function fresh_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {
    "# %% id=lualin01", "x = 1",
  })
  vim.api.nvim_set_current_buf(buf)
  return buf
end

describe("mercury.lualine", function()
  it("returns empty string when the buffer is not a notebook", function()
    -- Plain scratch buffer; no Notebook attached.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    assert.equals("", Lualine.kernel())
    assert.equals("", Lualine.queue())
    assert.equals("", Lualine.last_exec())
    assert.equals("", Lualine.cell_count())
    assert.equals("", Lualine.current_cell())
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("kernel() prefers b:mercury_kernel_name (active selector) over meta", function()
    -- A user who selected an explicit venv with :NotebookKernelSelect has
    -- the python path stored in b:mercury_kernel_name. Lualine must
    -- surface the active selector, NOT the fallback meta.kernelspec.name
    -- (which is "python3" by default and would be misleading).
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    nb.meta = { kernelspec = { name = "python3" } }
    vim.b[buf].mercury_kernel_name = "/abs/venv/bin/python"
    assert.equals("⎈ /abs/venv/bin/python", Lualine.kernel())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("kernel() falls back to meta.kernelspec.name when no active selector", function()
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    nb.meta = { kernelspec = { name = "python3-custom" } }
    -- No b:mercury_kernel_name set.
    assert.equals("⎈ python3-custom", Lualine.kernel())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("kernel() defaults to python3 if meta is missing entirely", function()
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    nb.meta = {}
    assert.equals("⎈ python3", Lualine.kernel())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("queue() shows running with a short cell id", function()
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = { running = { cell_id = "abc12345", started_at = 0 }, queue = {} }
    assert.equals("⏳ run abc123", Lualine.queue())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("queue() shows queue count when nothing is running", function()
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = { running = nil, queue = { { cell_id = "a" }, { cell_id = "b" } } }
    assert.equals("⏸ queue=2", Lualine.queue())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("queue() shows idle when nothing is running or queued", function()
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = { running = nil, queue = {} }
    assert.equals("✓ idle", Lualine.queue())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("last_exec() reports the cell with the highest exec_count", function()
    local buf = fresh_buf({
      "# %% id=cell0001", "x = 1",
      "# %% id=cell0002", "y = 2",
      "# %% id=cell0003", "z = 3",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb:ensure_output("cell0001").exec_count = 3
    nb:ensure_output("cell0001").ms = 12
    nb:ensure_output("cell0002").exec_count = 7
    nb:ensure_output("cell0002").ms = 99
    nb:ensure_output("cell0003").exec_count = 1
    nb:ensure_output("cell0003").ms = 5
    assert.equals("Out[7] 99 ms", Lualine.last_exec())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("last_exec() returns empty when no cell has run yet", function()
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    assert.equals("", Lualine.last_exec())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("cell_count() reports the number of cells", function()
    local buf = fresh_buf({
      "# %% id=cnt00001", "a",
      "# %% id=cnt00002", "b",
      "# %% id=cnt00003", "c",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    assert.equals("3 cells", Lualine.cell_count())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("queue() with notebook but nil kernel returns empty", function()
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = nil
    assert.equals("", Lualine.queue())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("queue() with running cell_id == nil renders 'run ' (defensive)", function()
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = { running = { cell_id = nil, started_at = 0 }, queue = {} }
    assert.equals("⏳ run ", Lualine.queue())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("last_exec() handles output with exec_count but no ms", function()
    local buf = fresh_buf()
    local nb = Notebook.attach(buf); nb:rescan()
    nb:ensure_output("lualin01").exec_count = 4
    nb:ensure_output("lualin01").ms = nil  -- defensive: nil ms
    assert.equals("Out[4] 0 ms", Lualine.last_exec())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("current_cell() reports raw cells with 'py' suffix (treated as code visually)", function()
    -- The current implementation only special-cases markdown; raw cells
    -- fall through to the 'py' default. Pin the current behavior.
    local buf = fresh_buf({
      "# %% id=raw00001 [raw]",
      "verbatim",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    -- Raw is shown as py (since it isn't md).
    assert.equals("cell 1/1 py", Lualine.current_cell())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("current_cell() reports the cell at the cursor with kind suffix", function()
    local buf = fresh_buf({
      "# %% id=cur00001", "x",
      "# %% id=cur00002 [markdown]", "# heading",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Cursor on first cell's body (line 2; 1-indexed).
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.equals("cell 1/2 py", Lualine.current_cell())
    -- Cursor on markdown cell body (line 4).
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    assert.equals("cell 2/2 md", Lualine.current_cell())
    Notebook.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
