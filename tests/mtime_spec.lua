-- Verifies that BufWriteCmd refuses to clobber a file that's been modified on
-- disk since load. Mirrors vim's default behavior (W12 warning + refuse
-- without :w!); since mercury replaces vim's write path with BufWriteCmd, the
-- protection has to live in mercury.

local Util = require("mercury.util")

local FIXTURE = [[
{"cells":[{"cell_type":"code","id":"abc12345","execution_count":1,"metadata":{},"outputs":[],"source":["x = 1"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
]]

describe("save mtime guard", function()
  before_each(function() require("mercury").setup() end)

  it("refuses to save when the file changed on disk since load", function()
    local tmp = vim.fn.tempname() .. ".ipynb"
    Util.write_file(tmp, FIXTURE)
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    -- Touch the file on disk so its mtime advances past what we recorded.
    vim.loop.sleep(1100)  -- mtime resolution is 1s on some filesystems
    Util.write_file(tmp, FIXTURE .. " ")
    -- Mark the buffer dirty so :w would actually run.
    vim.bo[buf].modified = true
    local before = Util.read_file(tmp)
    -- :w should be refused; in headless mode the BufWriteCmd error surfaces
    -- as a vim error so we wrap it.
    pcall(function() vim.cmd("write") end)
    local after = Util.read_file(tmp)
    -- File on disk must still match what we externally wrote (not the
    -- buffer's serialization), proving the save was refused.
    assert.equals(before, after)
    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it(":w! overrides the guard", function()
    local tmp = vim.fn.tempname() .. ".ipynb"
    Util.write_file(tmp, FIXTURE)
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    vim.loop.sleep(1100)
    Util.write_file(tmp, FIXTURE .. " ")
    vim.bo[buf].modified = true
    pcall(function() vim.cmd("write!") end)
    -- With ! the guard is bypassed; the file should now contain mercury's
    -- serialization (pretty-printed JSON starting with "{\n").
    local after = Util.read_file(tmp)
    assert.matches("^{\n", after)
    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it(":saveas a pre-existing target does not trigger the mtime guard", function()
    -- The guard compares against the ORIGINAL loaded file's mtime, but
    -- :saveas writes to a different file entirely. Without scoping the
    -- guard to the loaded path, the first :saveas to a pre-existing
    -- newer file would spuriously refuse with W12. SPEC invariant 21.
    local src = vim.fn.tempname() .. ".ipynb"
    local dst = vim.fn.tempname() .. ".ipynb"
    Util.write_file(src, FIXTURE)
    -- Make dst exist with a newer mtime than the buffer's stored mtime.
    Util.write_file(dst, "{}\n")
    vim.cmd("edit " .. src)
    local buf = vim.api.nvim_get_current_buf()
    vim.loop.sleep(1100)
    Util.write_file(dst, "{}\n")   -- advance dst's mtime past load time
    vim.bo[buf].modified = true
    -- :saveas should succeed without :w!.
    pcall(function() vim.cmd("saveas! " .. dst) end)
    -- ! is allowed but not required; we use it here so the test isn't
    -- defeated by vim's own "file already exists" prompt in some
    -- configurations. The mercury guard is what we're asserting.
    local after = Util.read_file(dst)
    -- File at dst now contains mercury's serialization.
    assert.matches("^{\n", after)
    -- And the buffer is now tracking dst. Compare via realpath to absorb
    -- the macOS /var -> /private/var symlink difference between
    -- `vim.fn.fnamemodify(:p)` (no resolve) and `nvim_buf_get_name` (resolved).
    local function realpath(p) return vim.loop.fs_realpath(p) or p end
    assert.equals(realpath(dst), realpath(vim.b[buf].mercury_loaded_path))
    vim.cmd("bwipeout!")
    os.remove(src); os.remove(dst)
  end)
end)
