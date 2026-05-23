-- Regression: deleting a cell's separator line must remove its output's
-- VIRTUAL lines from the buffer (not just from the Lua side-table). The
-- previous code GC'd the `_marks` lookup table but never called
-- `nvim_buf_del_extmark`, leaving an orphan extmark that continued to
-- render the dead cell's pill + body. The orphan was unreachable from
-- `:NotebookOutputClear` (no cell-id at cursor matched) so users had no way
-- to remove it short of `:e!`.

local Notebook = require("mercury.notebook")
local UI = require("mercury.ui")
local Cfg = require("mercury.config")

describe("orphan output cleanup when a cell separator is deleted", function()
  before_each(function()
    -- Force a fresh render path without inline-image side effects.
    package.loaded["image"] = {
      is_enabled = function() return false end,
      from_file = function() return {} end,
    }
    Cfg.setup()
  end)
  after_each(function() package.loaded["image"] = nil end)

  it("the deleted cell's output is dropped from nb.outputs", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=keepalpha", "print('a')",
      "# %% id=deldelta1", "print('b')",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    local renderer = UI.new(nb); nb:set_renderer(renderer)

    -- Fake some output on the doomed cell.
    local out = nb:ensure_output("deldelta1")
    out.status = "ok"; out.exec_count = 7
    out.items = { { type = "stream", name = "stdout", text = "doomed\n" } }
    renderer:render()
    assert.is_not_nil(nb.outputs["deldelta1"])

    -- User deletes the second cell's separator line (row 2 in 0-indexed).
    -- The body "print('b')" gets absorbed into the first cell.
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
    nb:rescan()

    -- The cell list is one cell long. The orphan output must be GC'd.
    assert.equals(1, #nb.cells)
    assert.equals("keepalpha", nb.cells[1].id)
    assert.is_nil(nb.outputs["deldelta1"],
      "rescan must GC outputs for cells whose id is no longer present")
  end)

  it("the orphan virt_lines extmark is removed from the buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=keepalph", "print('a')",
      "# %% id=delgamma", "print('b')",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    local renderer = UI.new(nb); nb:set_renderer(renderer)

    local out = nb:ensure_output("delgamma")
    out.status = "ok"; out.exec_count = 3
    out.items = { { type = "stream", name = "stdout", text = "stays?\n" } }
    renderer:render()

    -- An output extmark exists for the doomed cell.
    local ns_out = Notebook.ns("output")
    local marks_before = vim.api.nvim_buf_get_extmarks(buf, ns_out, 0, -1,
      { details = true })
    -- Two cells, each with one output extmark (the first has no output, so
    -- only the second's extmark exists). At least one must be present.
    local has_virt_lines_before = false
    for _, m in ipairs(marks_before) do
      if m[4] and m[4].virt_lines then has_virt_lines_before = true end
    end
    assert.is_true(has_virt_lines_before)

    -- Delete the separator of the second cell.
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
    nb:rescan()
    renderer:render()

    -- After render, the orphan extmark must be gone. No extmark in the
    -- output namespace may carry virt_lines that point at the deleted id's
    -- output content.
    local marks_after = vim.api.nvim_buf_get_extmarks(buf, ns_out, 0, -1,
      { details = true })
    for _, m in ipairs(marks_after) do
      if m[4] and m[4].virt_lines then
        -- The surviving cell ("keepalph") had no output set, so no extmark
        -- should carry virt_lines after the rescan.
        local concat = ""
        for _, vl in ipairs(m[4].virt_lines) do
          for _, chunk in ipairs(vl) do concat = concat .. chunk[1] end
        end
        assert.is_nil(concat:match("stays%?"),
          "orphan virt_lines extmark must be removed when the cell is gone")
      end
    end
  end)

  it("renderer._marks does not retain the deleted id", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=stayyepy", "print('a')",
      "# %% id=byebyepy", "print('b')",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    local renderer = UI.new(nb); nb:set_renderer(renderer)

    local out = nb:ensure_output("byebyepy")
    out.status = "ok"; out.exec_count = 1
    out.items = { { type = "stream", name = "stdout", text = "x\n" } }
    renderer:render()
    assert.is_not_nil(renderer._marks["byebyepy"])

    -- Delete the separator of the doomed cell.
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
    nb:rescan(); renderer:render()
    assert.is_nil(renderer._marks["byebyepy"],
      "renderer._marks must be GC'd for cells that no longer exist")
  end)
end)
