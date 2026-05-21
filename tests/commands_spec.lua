-- :Notebook* user-command tests. Every command in init.lua's
-- _register_commands is documented in SPEC.md and bound by default
-- keymaps, but pre-existing tests only invoked the underlying methods
-- directly — a regression in the command-registration glue (typo'd command
-- name, wrong dispatch function, missing buffer-only flag, etc.) would
-- not be caught.
--
-- These tests use `vim.cmd(":NotebookXxx")` end-to-end against a real
-- attached buffer. The kernel is stubbed so no real bridge is spun up.

local Notebook = require("mercury.notebook")
local Util = require("mercury.util")
local function fixture_path(name)
  return vim.fn.getcwd() .. "/tests/fixtures/" .. name
end

local function fresh_buffer()
  local tmp = vim.fn.tempname() .. ".ipynb"
  Util.write_file(tmp, Util.read_file(fixture_path("simple.ipynb")))
  vim.cmd("edit " .. tmp)
  local buf = vim.api.nvim_get_current_buf()
  local nb = Notebook.get(buf)
  -- Stub kernel side-effects so command tests don't depend on a live bridge.
  nb.kernel.execute = function(self, cell)
    self._test_executed = self._test_executed or {}
    table.insert(self._test_executed, cell and cell.id or "?")
  end
  nb.kernel.interrupt = function(self) self._test_interrupted = true end
  nb.kernel.restart = function(self, opts)
    self._test_restarted = (self._test_restarted or 0) + 1
    self._test_restart_opts = opts
  end
  nb.kernel.stop = function(self)
    self._test_stopped = true
    self.running = nil; self.queue = {}; self.job_id = nil; self.chan = nil
  end
  return buf, nb, tmp
end

local function teardown(tmp)
  pcall(function() vim.cmd("bwipeout!") end)
  if tmp then os.remove(tmp) end
end

describe(":Notebook* user commands", function()
  before_each(function() require("mercury").setup({}) end)

  ---------------------------------------------------------------------------
  -- Execution
  ---------------------------------------------------------------------------

  it(":NotebookExec runs the current cell and advances cursor", function()
    local buf, nb, tmp = fresh_buffer()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })  -- inside first cell's body
    vim.cmd("NotebookExec")
    assert.is_truthy(nb.kernel._test_executed)
    assert.equals("abc12345", nb.kernel._test_executed[1])
    teardown(tmp)
  end)

  it(":NotebookExecAlone runs without advancing", function()
    local buf, nb, tmp = fresh_buffer()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookExecAlone")
    assert.equals("abc12345", nb.kernel._test_executed[1])
    teardown(tmp)
  end)

  it(":NotebookExecAll runs every code cell in order", function()
    local buf, nb, tmp = fresh_buffer()
    vim.cmd("NotebookExecAll")
    -- simple.ipynb has cells: abc12345 (code), def67890 (markdown), fab10111 (code).
    -- Markdown is skipped.
    assert.same({ "abc12345", "fab10111" }, nb.kernel._test_executed)
    teardown(tmp)
  end)

  it(":NotebookExecAbove runs code cells above (and including) cursor", function()
    local buf, nb, tmp = fresh_buffer()
    -- Position cursor in the LAST code cell.
    local rows = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(0, { rows, 0 })
    vim.cmd("NotebookExecAbove")
    -- Both code cells should run.
    assert.same({ "abc12345", "fab10111" }, nb.kernel._test_executed)
    teardown(tmp)
  end)

  ---------------------------------------------------------------------------
  -- Cell creation & navigation
  ---------------------------------------------------------------------------

  it(":NotebookCellNewBelow inserts a new code cell below cursor", function()
    local buf, nb, tmp = fresh_buffer()
    local before = #nb.cells
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookCellNewBelow")
    nb:rescan()
    assert.equals(before + 1, #nb.cells)
    teardown(tmp)
  end)

  it(":NotebookCellNewAbove inserts a new code cell above cursor", function()
    local buf, nb, tmp = fresh_buffer()
    local before = #nb.cells
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookCellNewAbove")
    nb:rescan()
    assert.equals(before + 1, #nb.cells)
    teardown(tmp)
  end)

  it(":NotebookCellNext jumps cursor to the next cell", function()
    local buf, nb, tmp = fresh_buffer()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })  -- first cell's body
    local before_row = vim.api.nvim_win_get_cursor(0)[1]
    vim.cmd("NotebookCellNext")
    local after_row = vim.api.nvim_win_get_cursor(0)[1]
    assert.is_true(after_row > before_row,
      "cursor should advance to next cell")
    teardown(tmp)
  end)

  it(":NotebookCellPrev jumps cursor to the previous cell", function()
    local buf, nb, tmp = fresh_buffer()
    local rows = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(0, { rows, 0 })  -- last line
    vim.cmd("NotebookCellPrev")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    assert.is_true(row < rows)
    teardown(tmp)
  end)

  it(":NotebookCellDelete removes the current cell", function()
    local buf, nb, tmp = fresh_buffer()
    local before = #nb.cells
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookCellDelete")
    nb:rescan()
    assert.equals(before - 1, #nb.cells)
    teardown(tmp)
  end)

  it(":NotebookCellMergeBelow merges current cell with the next", function()
    local buf, nb, tmp = fresh_buffer()
    local before = #nb.cells
    -- Cursor on the FIRST cell (code), the next cell is markdown.
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookCellMergeBelow")
    nb:rescan()
    assert.equals(before - 1, #nb.cells)
    teardown(tmp)
  end)

  it(":NotebookCellMoveUp swaps with the previous cell", function()
    local buf, nb, tmp = fresh_buffer()
    -- Cursor on the LAST cell (code, id=fab10111).
    local rows = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(0, { rows, 0 })
    local last_id_before = nb.cells[#nb.cells].id
    vim.cmd("NotebookCellMoveUp")
    nb:rescan()
    -- Last cell is now whatever was second-to-last before.
    local last_id_after = nb.cells[#nb.cells].id
    assert.not_equals(last_id_before, last_id_after)
    teardown(tmp)
  end)

  it(":NotebookCellMoveDown swaps with the next cell", function()
    local buf, nb, tmp = fresh_buffer()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })  -- first cell
    local first_id_before = nb.cells[1].id
    vim.cmd("NotebookCellMoveDown")
    nb:rescan()
    local first_id_after = nb.cells[1].id
    assert.not_equals(first_id_before, first_id_after)
    teardown(tmp)
  end)

  ---------------------------------------------------------------------------
  -- Kind conversion
  ---------------------------------------------------------------------------

  it(":NotebookCellToMarkdown converts cell to markdown", function()
    local buf, nb, tmp = fresh_buffer()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookCellToMarkdown")
    assert.equals("markdown", nb.cells[1].kind)
    teardown(tmp)
  end)

  it(":NotebookCellToCode converts cell to code", function()
    local buf, nb, tmp = fresh_buffer()
    -- Position cursor on the markdown cell (index 2).
    -- simple.ipynb: cell 1 = code (rows 1-2), cell 2 = markdown (rows 4-6).
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.cmd("NotebookCellToCode")
    assert.equals("code", nb.cells[2].kind)
    teardown(tmp)
  end)

  it(":NotebookCellSelect visually selects the current cell", function()
    local buf, nb, tmp = fresh_buffer()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookCellSelect")
    -- Visual selection means mode "v" or "V"; we just check that the
    -- command didn't raise. (Asserting mode in headless is unreliable —
    -- the visual marks are set via the function, but mode may not engage.)
    assert.has_no.errors(function()
      vim.cmd("normal! \027")  -- ESC out of visual
    end)
    teardown(tmp)
  end)

  ---------------------------------------------------------------------------
  -- Output management
  ---------------------------------------------------------------------------

  it(":NotebookOutputClear wipes the current cell's output", function()
    local buf, nb, tmp = fresh_buffer()
    nb:ensure_output("abc12345").items = {
      { type = "stream", name = "stdout", text = "stuff\n" },
    }
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookOutputClear")
    -- After clear, the cell's output is gone (items={}).
    local out = nb.outputs["abc12345"]
    if out then assert.equals(0, #out.items) end
    teardown(tmp)
  end)

  it(":NotebookOutputClearAll wipes every cell's output", function()
    local buf, nb, tmp = fresh_buffer()
    nb:ensure_output("abc12345").items = { { type = "stream", text = "a" } }
    nb:ensure_output("fab10111").items = { { type = "stream", text = "b" } }
    vim.cmd("NotebookOutputClearAll")
    -- All outputs cleared.
    local total = 0
    for _, out in pairs(nb.outputs) do total = total + #(out.items or {}) end
    assert.equals(0, total)
    teardown(tmp)
  end)

  it(":NotebookOutputToggle flips the collapsed flag on the current cell's output", function()
    local buf, nb, tmp = fresh_buffer()
    local out = nb:ensure_output("abc12345")
    out.items = { { type = "stream", text = "x" } }
    local before = out._collapsed
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookOutputToggle")
    assert.not_equals(before, out._collapsed)
    teardown(tmp)
  end)

  it(":NotebookOutputCopy copies the cell's output text to the + register", function()
    local buf, nb, tmp = fresh_buffer()
    nb:ensure_output("abc12345").items = {
      { type = "stream", name = "stdout", text = "yanked\n" },
    }
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    -- The `+` register requires xclip / pbcopy in headless. Mercury writes
    -- via vim.fn.setreg('+', ...) — in headless without a clipboard provider
    -- the call still works against the in-memory register table.
    vim.cmd("NotebookOutputCopy")
    -- Either + worked or " (unnamed) caught the spill — both indicate the
    -- copy logic ran.
    local plus = vim.fn.getreg("+")
    local unnamed = vim.fn.getreg('"')
    assert.is_true(plus:find("yanked") ~= nil or unnamed:find("yanked") ~= nil,
      "expected 'yanked' to land in either the + or unnamed register")
    teardown(tmp)
  end)

  it(":NotebookOutputView opens a scratch buffer with the cell's output text", function()
    local buf, nb, tmp = fresh_buffer()
    nb:ensure_output("abc12345").items = {
      { type = "stream", name = "stdout", text = "viewable\n" },
    }
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("NotebookOutputView")
    -- A new buffer should be open.
    local cur = vim.api.nvim_get_current_buf()
    assert.not_equals(buf, cur)
    -- And contain the output text.
    local lines = vim.api.nvim_buf_get_lines(cur, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.matches("viewable", joined)
    vim.cmd("close")
    teardown(tmp)
  end)

  ---------------------------------------------------------------------------
  -- Kernel management
  ---------------------------------------------------------------------------

  it(":NotebookKernelRestart calls Kernel:restart", function()
    local buf, nb, tmp = fresh_buffer()
    vim.cmd("NotebookKernelRestart")
    assert.is_truthy(nb.kernel._test_restarted)
    -- Without `clear` opts:
    assert.is_nil(nb.kernel._test_restart_opts
      and nb.kernel._test_restart_opts.clear)
    teardown(tmp)
  end)

  it(":NotebookKernelRestartClear restarts with clear=true", function()
    local buf, nb, tmp = fresh_buffer()
    vim.cmd("NotebookKernelRestartClear")
    assert.is_truthy(nb.kernel._test_restart_opts)
    assert.is_true(nb.kernel._test_restart_opts.clear)
    teardown(tmp)
  end)

  it(":NotebookKernelInterrupt calls Kernel:interrupt", function()
    local buf, nb, tmp = fresh_buffer()
    vim.cmd("NotebookKernelInterrupt")
    assert.is_true(nb.kernel._test_interrupted)
    teardown(tmp)
  end)

  it(":NotebookKernelStop calls Kernel:stop", function()
    local buf, nb, tmp = fresh_buffer()
    vim.cmd("NotebookKernelStop")
    assert.is_true(nb.kernel._test_stopped)
    teardown(tmp)
  end)

  ---------------------------------------------------------------------------
  -- Buffer-only behavior — commands must be no-ops on a non-mercury buffer
  ---------------------------------------------------------------------------

  it("commands on a non-mercury buffer notify and don't crash", function()
    -- Create a plain scratch buffer.
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(b)
    -- These commands all check Notebook.get(buf) and warn if absent.
    -- Mercury still registers them as global :commands, so they should be
    -- callable even from a non-notebook buffer — just no-op + notify.
    assert.has_no.errors(function() vim.cmd("NotebookExec") end)
    assert.has_no.errors(function() vim.cmd("NotebookCellNewBelow") end)
    assert.has_no.errors(function() vim.cmd("NotebookOutputClear") end)
    vim.api.nvim_buf_delete(b, { force = true })
  end)
end)
