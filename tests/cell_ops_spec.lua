local Notebook = require("mercury.notebook")
local Cfg = require("mercury.config")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("cell operations", function()
  before_each(function() Cfg.setup() end)

  it("creates a new cell below", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:new_cell_below()
    assert.equals(3, #nb.cells)
    assert.equals("aaaa1111", nb.cells[1].id)
    assert.equals("bbbb2222", nb.cells[3].id)
    Notebook.detach(buf)
  end)

  it("deletes the current cell and keeps surroundings intact", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222",
      "y = 2",
      "# %% id=cccc3333",
      "z = 3",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })  -- inside cell bbbb2222
    nb:delete_cell()
    assert.equals(2, #nb.cells)
    local ids = {}
    for _, c in ipairs(nb.cells) do ids[#ids + 1] = c.id end
    assert.same({ "aaaa1111", "cccc3333" }, ids)
    Notebook.detach(buf)
  end)

  it("delete_cell drops any pending kernel execution for the cell", function()
    -- Otherwise the user-deleted code keeps running on the kernel and its
    -- side effects (writes, network calls) land in a notebook that no
    -- longer has the cell. Output is GC'd by rescan but the execution
    -- already happened.
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Stand in for nb.kernel: minimal surface we need for delete_cell's
    -- queue-cleanup branch.
    nb.kernel = {
      queue = {
        { cell_id = "bbbb2222", code = "y = 2" },
        { cell_id = "aaaa1111", code = "x = 1" },
      },
      running = nil,
    }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })  -- inside cell bbbb2222
    nb:delete_cell()

    -- bbbb2222 was deleted -> its queued task must be gone too.
    -- aaaa1111's queued task is untouched.
    assert.equals(1, #nb.kernel.queue)
    assert.equals("aaaa1111", nb.kernel.queue[1].cell_id)
    Notebook.detach(buf)
  end)

  it("merges current cell with the next", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:merge_below()
    assert.equals(1, #nb.cells)
    assert.equals("aaaa1111", nb.cells[1].id)
    local body = nb:cell_body_lines(nb.cells[1])
    assert.same({ "x = 1", "y = 2" }, body)
    Notebook.detach(buf)
  end)

  it("moves a cell down", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    nb:move_down()
    assert.equals("bbbb2222", nb.cells[1].id)
    assert.equals("aaaa1111", nb.cells[2].id)
    Notebook.detach(buf)
  end)

  it("moves a cell up", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    nb:move_up()
    assert.equals("bbbb2222", nb.cells[1].id)
    assert.equals("aaaa1111", nb.cells[2].id)
    Notebook.detach(buf)
  end)

  it("converts cell type", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "markdown")
    assert.equals("markdown", nb.cells[1].kind)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.matches("%[markdown%]", lines[1])
    nb:set_kind(nil, "code")
    assert.equals("code", nb.cells[1].kind)
    Notebook.detach(buf)
  end)

  it("set_kind preserves tags encoded on the separator", function()
    local buf = make_buf({
      "# %% id=aaaa1111 tags=foo,bar",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "markdown")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.matches("tags=foo,bar", lines[1])
    assert.matches("%[markdown%]", lines[1])
    Notebook.detach(buf)
  end)

  -- In-buffer cell bodies keep the trailing blank that visually separates
  -- adjacent cells; `to_ipynb_struct` trims it at save time. Tests compare
  -- against the trimmed shape since that's what survives a round trip.
  local function trimmed_body(nb, cell)
    local body = nb:cell_body_lines(cell)
    while #body > 0 and body[#body] == "" do table.remove(body, #body) end
    return body
  end

  it("duplicates the current cell below it", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:duplicate_cell()
    assert.equals(3, #nb.cells)
    assert.equals("aaaa1111", nb.cells[1].id)
    assert.equals("bbbb2222", nb.cells[3].id)
    -- New middle cell has a fresh id and the same body.
    assert.is_not.equals("aaaa1111", nb.cells[2].id)
    assert.same({ "x = 1" }, trimmed_body(nb, nb.cells[2]))
    Notebook.detach(buf)
  end)

  it("copy and paste insert a new cell with the same body", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "print('keep')",
      "# %% id=bbbb2222",
      "print('paste-after-me')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:copy_cell()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    nb:paste_cell()
    assert.equals(3, #nb.cells)
    assert.equals("bbbb2222", nb.cells[2].id)
    -- Pasted body equals copied body.
    assert.same({ "print('keep')" }, trimmed_body(nb, nb.cells[3]))
    Notebook.detach(buf)
  end)
end)
