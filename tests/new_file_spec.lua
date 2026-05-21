local Notebook = require("mercury.notebook")
local Util = require("mercury.util")

describe("new / empty .ipynb files", function()
  before_each(function() require("mercury").setup() end)

  it("opens a non-existent .ipynb as a fresh notebook", function()
    local tmp = vim.fn.tempname() .. "_new.ipynb"
    assert.is_nil(vim.loop.fs_stat(tmp))
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    assert.is_not_nil(nb)
    assert.equals(1, #nb.cells)
    assert.equals("code", nb.cells[1].kind)
    assert.is_true(vim.bo[buf].modified)
    -- Saving creates a valid ipynb on disk.
    vim.cmd("write")
    local data = Util.read_file(tmp)
    assert.is_not_nil(data)
    local doc = vim.json.decode(data)
    assert.equals(4, doc.nbformat)
    assert.equals(1, #doc.cells)
    assert.equals("code", doc.cells[1].cell_type)
    assert.is_not_nil(doc.metadata.kernelspec)
    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("opens an empty .ipynb file as a fresh notebook", function()
    local tmp = vim.fn.tempname() .. "_empty.ipynb"
    Util.write_file(tmp, "")
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    assert.equals(1, #nb.cells)
    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("refuses to clobber an existing malformed .ipynb", function()
    local tmp = vim.fn.tempname() .. "_bad.ipynb"
    Util.write_file(tmp, "this is not json {{{")
    -- Notify-on-error surfaces as a Vim error in headless mode; that's expected.
    pcall(function() vim.cmd("edit " .. tmp) end)
    -- The original file on disk should still be the malformed bytes.
    local on_disk = Util.read_file(tmp)
    assert.equals("this is not json {{{", on_disk)
    pcall(function() vim.cmd("bwipeout!") end)
    os.remove(tmp)
  end)

  it("opens a malformed .ipynb as a readonly raw-bytes buffer (H13)", function()
    -- SPEC: "on parse failure, show raw bytes readonly and notify (never
    -- clobber a malformed .ipynb)". Without this, the file gets opened as
    -- writable + modifiable and a casual `:w!` would clobber the user's
    -- broken-but-recoverable bytes.
    local tmp = vim.fn.tempname() .. "_h13_bad.ipynb"
    Util.write_file(tmp, "this is not json {{{")
    pcall(function() vim.cmd("edit " .. tmp) end)
    local buf = vim.api.nvim_get_current_buf()
    -- Buffer is unmodifiable so naive :w won't overwrite the file.
    assert.is_false(vim.bo[buf].modifiable,
      "malformed .ipynb must be loaded as nomodifiable")
    -- Buffer is not modified.
    assert.is_false(vim.bo[buf].modified)
    -- The raw bytes are visible in the buffer so the user can fix-by-eye.
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.matches("this is not json", lines[1])
    pcall(function() vim.cmd("bwipeout!") end)
    os.remove(tmp)
  end)
end)
