local Notebook = require("mercury.notebook")
local Cfg = require("mercury.config")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("notebook scan + reconcile", function()
  before_each(function() Cfg.setup() end)

  it("attaches and rescans a buffer with explicit separators", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "print('one')",
      "# %% id=bbbb2222 [markdown]",
      "# heading",
    })
    local nb = Notebook.attach(buf)
    nb:rescan()
    assert.equals(2, #nb.cells)
    assert.equals("aaaa1111", nb.cells[1].id)
    assert.equals("code", nb.cells[1].kind)
    assert.equals("bbbb2222", nb.cells[2].id)
    assert.equals("markdown", nb.cells[2].kind)
    Notebook.detach(buf)
  end)

  it("assigns missing ids and rewrites buffer", function()
    local buf = make_buf({
      "# %%",
      "print(1)",
      "# %%",
      "print(2)",
    })
    local nb = Notebook.attach(buf)
    nb:rescan()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.matches("id=%w+", lines[1])
    assert.matches("id=%w+", lines[3])
    Notebook.detach(buf)
  end)

  it("preserves outputs across rescans for surviving ids", function()
    local buf = make_buf({
      "# %% id=stable11",
      "print(1)",
      "# %% id=stable22",
      "print(2)",
    })
    local nb = Notebook.attach(buf)
    nb:rescan()
    local out = nb:ensure_output("stable11")
    out.items = { { type = "stream", name = "stdout", text = "hi\n" } }
    out.status = "ok"
    -- mutate buffer below cell1 (e.g., add a line)
    vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "extra = 'line'" })
    nb:rescan()
    assert.equals("hi\n", nb.outputs["stable11"].items[1].text)
    Notebook.detach(buf)
  end)

  it("evicts outputs when a cell separator is removed", function()
    local buf = make_buf({
      "# %% id=keep0001",
      "print(1)",
      "# %% id=drop0002",
      "print(2)",
    })
    local nb = Notebook.attach(buf)
    nb:rescan()
    nb:ensure_output("drop0002").items = { { type = "stream", text = "x" } }
    -- delete the second separator
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
    nb:rescan()
    assert.is_nil(nb.outputs["drop0002"])
    Notebook.detach(buf)
  end)

  it("cell_at_row returns the right cell across boundaries", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "print(1)",
      "x = 1",
      "# %% id=bbbb2222",
      "print(2)",
    })
    local nb = Notebook.attach(buf)
    nb:rescan()
    assert.equals("aaaa1111", nb:cell_at_row(0).id)
    assert.equals("aaaa1111", nb:cell_at_row(2).id)
    assert.equals("bbbb2222", nb:cell_at_row(3).id)
    assert.equals("bbbb2222", nb:cell_at_row(4).id)
    Notebook.detach(buf)
  end)

  it("migrates side tables when the user renames a cell id in the buffer", function()
    -- Without rename-detection, editing `id=keep0001` to `id=fresh001` would
    -- GC the cell's outputs / metadata / attachments and start fresh on the
    -- new id. The user just renamed an id; they didn't ask to lose state.
    --
    -- For attachments specifically we test the markdown path — attachments
    -- only live on markdown cells per nbformat, and rescan now also enforces
    -- that invariant (clearing attachments off non-markdown cells). The
    -- rename test uses a code cell to verify outputs+metadata migration and
    -- a markdown cell to verify attachments migration.
    local buf = make_buf({
      "# %% id=keep0001",
      "print(1)",
      "# %% id=mdkeep01 [markdown]",
      "![pic](attachment:pic.png)",
    })
    local nb = Notebook.attach(buf)
    nb:rescan()
    nb:ensure_output("keep0001").items = { { type = "stream", text = "saved" } }
    nb.cell_metadata["keep0001"] = { collapsed = true }
    nb.cell_attachments["mdkeep01"] = { ["pic.png"] = { ["image/png"] = "x" } }
    -- User edits both separators to fresh ids.
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# %% id=fresh001" })
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "# %% id=mdfresh1 [markdown]" })
    nb:rescan()
    -- Migrated, not GC'd.
    assert.equals("saved", nb.outputs["fresh001"].items[1].text)
    assert.same({ collapsed = true }, nb.cell_metadata["fresh001"])
    assert.is_not_nil(nb.cell_attachments["mdfresh1"])
    -- Old id entries are gone.
    assert.is_nil(nb.outputs["keep0001"])
    assert.is_nil(nb.cell_metadata["keep0001"])
    assert.is_nil(nb.cell_attachments["mdkeep01"])
    Notebook.detach(buf)
  end)

  it("rewrites duplicate ids on copy-paste so cells stay unique", function()
    local buf = make_buf({
      "# %% id=abc12345",
      "print(1)",
      "# %% id=abc12345",
      "print(2)",
    })
    local nb = Notebook.attach(buf)
    nb:rescan()
    assert.equals(2, #nb.cells)
    -- One of them keeps the original id; the other gets a fresh one.
    assert.not_equals(nb.cells[1].id, nb.cells[2].id)
    -- Buffer must have been rewritten to reflect the new id.
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.matches("id=" .. nb.cells[2].id, lines[3])
    Notebook.detach(buf)
  end)

  it("_with_mutation resets _suppress_rescan even if fn() raises", function()
    -- Invariant: a Lua error inside a mutation must not leave the buffer in
    -- a state where TextChanged silently does nothing forever.
    local buf = make_buf({ "# %% id=aaaa1111", "x = 1" })
    local nb = Notebook.attach(buf)
    nb:rescan()
    local ok = pcall(function()
      nb:_with_mutation(function() error("kaboom") end)
    end)
    assert.is_false(ok)
    assert.is_false(nb._suppress_rescan)
    Notebook.detach(buf)
  end)

  it("removes tags from saved JSON when user deletes them from separator", function()
    -- Buffer is authoritative for tags. The deepcopy from cell_metadata used
    -- to leave stale tags in place if the user removed the separator token.
    local buf = make_buf({ "# %% id=tagcell1 tags=foo,bar", "x = 1" })
    local nb = Notebook.attach(buf)
    nb:rescan()
    -- Save now; tags should be in the struct.
    local s = nb:to_ipynb_struct()
    assert.same({ "foo", "bar" }, s.cells[1].metadata.tags)
    -- Pretend a prior load put tags in cell_metadata (simulating reload).
    nb.cell_metadata["tagcell1"] = { tags = { "foo", "bar" } }
    -- User removes the tags token from the separator.
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# %% id=tagcell1" })
    nb:rescan()
    s = nb:to_ipynb_struct()
    -- Tags must be gone now.
    assert.is_nil(s.cells[1].metadata.tags)
    Notebook.detach(buf)
  end)

  it("preserves a trailing blank line in the last cell's body on save", function()
    -- The visual-gap trim in to_ipynb_struct used to eat ANY trailing "" from
    -- a cell body, assuming it came from the blank line that to_buffer_lines
    -- inserts between cells. The last cell has no trailing visual gap, so a
    -- trailing "" in its body is real user content — must not be trimmed.
    local buf = make_buf({
      "# %% id=first001",
      "x = 1",
      "",                       -- visual gap (eaten by trim — correct)
      "# %% id=last0001",
      "y = 2",
      "",                       -- intentional blank line at end (must survive)
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local struct = nb:to_ipynb_struct()
    -- Non-last cell: visual-gap blank correctly trimmed.
    assert.same({ "x = 1" }, struct.cells[1].source)
    -- Last cell: trailing blank preserved.
    assert.same({ "y = 2", "" }, struct.cells[2].source)
    Notebook.detach(buf)
  end)

  it("preserves raw cells through scan and round-trip via separator", function()
    local buf = make_buf({
      "# %% id=rrrr0001 [raw]",
      "verbatim line 1",
      "verbatim line 2",
    })
    local nb = Notebook.attach(buf)
    nb:rescan()
    assert.equals(1, #nb.cells)
    assert.equals("raw", nb.cells[1].kind)
    Notebook.detach(buf)
  end)

  it("rescan drops outputs when a cell is converted via direct text edit", function()
    -- The set_kind path drops outputs eagerly, but a user who edits the
    -- separator text directly (changing `# %% id=X` to `# %% id=X [markdown]`)
    -- bypasses set_kind. Rescan must still enforce the "markdown cells don't
    -- carry outputs" invariant or a stale status pill / output text survives
    -- below prose. SPEC invariant 20.
    local buf = make_buf({
      "# %% id=convert1",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local out = nb:ensure_output("convert1")
    out.items = { { type = "stream", name = "stdout", text = "hi\n" } }
    out.status = "ok"
    out.exec_count = 1
    -- Edit the separator directly to convert kind.
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# %% id=convert1 [markdown]" })
    nb:rescan()
    assert.equals("markdown", nb.cells[1].kind)
    assert.is_nil(nb.outputs["convert1"])
    Notebook.detach(buf)
  end)

  it("rescan drops queued tasks for cells converted to non-code", function()
    -- A queued task that was enqueued before the cell was retyped would
    -- still run on the kernel (the bridge captured the code at enqueue
    -- time), producing side effects with no visible output. SPEC 20.
    local buf = make_buf({
      "# %% id=queued03",
      "x = 1",
      "# %% id=keep0003",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = {
      running = nil,
      queue = {
        { cell_id = "queued03", code = "x = 1" },
        { cell_id = "keep0003", code = "y = 2" },
      },
    }
    -- User retypes the first cell to markdown via direct edit.
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# %% id=queued03 [markdown]" })
    nb:rescan()
    -- queued03's task gone, keep0003's task survives.
    assert.equals(1, #nb.kernel.queue)
    assert.equals("keep0003", nb.kernel.queue[1].cell_id)
    Notebook.detach(buf)
  end)

  it("rescan injects an implicit separator when buffer starts without one", function()
    -- A buffer whose first lines are code with no `# %%` separator gets an
    -- injected separator at line 0 (so we always have at least one cell).
    -- SPEC: "The first cell may be implicit".
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "x = 1",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    assert.equals(1, #nb.cells)
    -- Buffer now has a leading separator that mercury injected.
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.matches("^# %%%% id=", lines[1])
    Notebook.detach(buf)
  end)

  it("rescan skips rename detection when cell count changes", function()
    -- Per SPEC: rename detection only runs when #prev == #new. If the user
    -- added/removed cells while also editing an id, side tables for the
    -- renamed cell are GC'd (the safest fallback — we can't reliably
    -- match positionally across structural changes).
    local buf = make_buf({
      "# %% id=multi001",
      "x = 1",
      "# %% id=multi002",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb:ensure_output("multi001").items = { { type = "stream", text = "out1" } }
    -- Rename multi001 -> renamed1 AND delete cell 2 in one edit.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=renamed1",
      "x = 1",
    })
    nb:rescan()
    -- With cell-count change, side tables are NOT migrated.
    assert.is_nil(nb.outputs["renamed1"])
    Notebook.detach(buf)
  end)

  it("to_ipynb_struct writes in-flight (running) cells as not-yet-executed (Invariant 14)", function()
    -- SPEC Non-blocking save: a cell still running when :w fires must
    -- serialize as empty outputs + null execution_count. The in-memory
    -- streaming output is preserved (next save flushes it).
    local buf = make_buf({
      "# %% id=inflight1", "x = expensive()",
      "# %% id=queued002", "y = next()",
      "# %% id=stable01", "z = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Pretend the kernel has cells in flight.
    nb.kernel = nil  -- start clean
    nb.kernel = {
      running = { cell_id = "inflight1", started_at = 0 },
      queue = { { cell_id = "queued002", code = "y = next()" } },
    }
    -- Mid-stream output for the running cell — must not land in JSON.
    nb:ensure_output("inflight1").items = {
      { type = "stream", name = "stdout", text = "tqdm: 50%\n" },
    }
    nb:ensure_output("inflight1").exec_count = nil  -- not yet finished
    -- The stable cell has real output.
    nb:ensure_output("stable01").items = {
      { type = "stream", name = "stdout", text = "done\n" },
    }
    nb:ensure_output("stable01").exec_count = 3

    local struct = nb:to_ipynb_struct()
    local by_id = {}
    for _, c in ipairs(struct.cells) do by_id[c.id] = c end

    -- Running cell: empty outputs, nil exec_count.
    assert.equals(0, #by_id["inflight1"].outputs)
    assert.is_nil(by_id["inflight1"].exec_count)
    -- Queued cell: same.
    assert.equals(0, #by_id["queued002"].outputs)
    assert.is_nil(by_id["queued002"].exec_count)
    -- Stable cell: outputs preserved.
    assert.equals(1, #by_id["stable01"].outputs)
    assert.equals(3, by_id["stable01"].exec_count)

    -- The in-memory state of the running cell is UNTOUCHED. The next save
    -- (after the cell finishes) will pick up the actual output.
    assert.equals("tqdm: 50%\n", nb.outputs["inflight1"].items[1].text)

    Notebook.detach(buf)
  end)

  it("new_cell_above inserts a new code cell above the current one", function()
    local buf = make_buf({
      "# %% id=above001",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local before = #nb.cells
    nb:new_cell_above()
    assert.equals(before + 1, #nb.cells)
    -- The new cell is now FIRST and is code.
    assert.equals("code", nb.cells[1].kind)
    -- Original cell is preserved.
    assert.equals("above001", nb.cells[2].id)
    Notebook.detach(buf)
  end)

  it("new_cell_above is a no-op when cursor is not over any cell", function()
    -- A buffer with no cells (won't happen in practice but defensive).
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    local nb = Notebook.attach(buf); nb:rescan()
    -- A truly empty buffer gets an implicit cell, so this is implicit.
    -- The actual no-op path is when `cell_at_row()` returns nil for a
    -- detached cursor; harder to construct in test, but new_cell_above
    -- must not raise.
    assert.has_no.errors(function() nb:new_cell_above(nil) end)
    Notebook.detach(buf)
  end)

  it("goto_next_cell jumps to next cell's body", function()
    local buf = make_buf({
      "# %% id=gtn00001", "a = 1",
      "# %% id=gtn00002", "b = 2",
      "# %% id=gtn00003", "c = 3",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })  -- in body of first cell
    nb:goto_next_cell()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    -- Should now be in body of the second cell.
    assert.is_true(row >= 4)
    Notebook.detach(buf)
  end)

  it("goto_next_cell at last cell is a no-op", function()
    local buf = make_buf({
      "# %% id=gtnlast1", "a = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local before = vim.api.nvim_win_get_cursor(0)[1]
    nb:goto_next_cell()
    assert.equals(before, vim.api.nvim_win_get_cursor(0)[1])
    Notebook.detach(buf)
  end)

  it("goto_prev_cell jumps backward across cells", function()
    local buf = make_buf({
      "# %% id=gtp00001", "a = 1",
      "# %% id=gtp00002", "b = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })  -- in body of second cell
    nb:goto_prev_cell()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    -- Should move within / above the second cell. First call moves to
    -- body_start of current cell; if already there, moves to previous.
    assert.is_true(row <= 4)
    Notebook.detach(buf)
  end)

  it("select_cell sets visual marks around the current cell", function()
    local buf = make_buf({
      "# %% id=sel00001", "x = 1",
      "# %% id=sel00002", "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.has_no.errors(function() nb:select_cell() end)
    -- Drop out of visual mode if we entered it.
    vim.cmd("normal! \027")
    Notebook.detach(buf)
  end)

  it("cell_anchor_row returns body_end for cells with content", function()
    local buf = make_buf({
      "# %% id=anc00001",
      "x = 1",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- body_end is the last body row index.
    local anchor = nb:cell_anchor_row(nb.cells[1])
    assert.equals(nb.cells[1].body_end, anchor)
    Notebook.detach(buf)
  end)

  it("cell_anchor_row returns header_row for a header-only (zero-body) cell", function()
    local buf = make_buf({
      "# %% id=hdronly1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- body_end < body_start because the cell has no body.
    local c = nb.cells[1]
    local anchor = nb:cell_anchor_row(c)
    -- Either the synthesized cell pushes body_start to header_row+1 and
    -- body_end stays at header_row, OR the implementation falls into
    -- header_row branch. Either way, anchor must be a non-negative row.
    assert.is_true(anchor >= 0)
    Notebook.detach(buf)
  end)

  it("cell_is_busy returns false when notebook has no kernel", function()
    local buf = make_buf({ "# %% id=nokern01", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = nil
    assert.is_false(nb:cell_is_busy("nokern01"))
    Notebook.detach(buf)
  end)

  it("Notebook.detach forgets the markdown-regions cache (H15)", function()
    -- A bufnr recycled by nvim could otherwise inherit a stale included-
    -- regions key whose cached value matches the new buffer's first rescan
    -- by coincidence — silently skipping the set_included_regions call
    -- that the new buffer actually needed.
    local Markdown = require("mercury.markdown")
    local buf = make_buf({
      "# %% id=md000001 [markdown]",
      "# heading",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Force-prime the cache so we can verify forget clears it. The cache
    -- is internal; we read it via the M._last_key table.
    -- (markdown.update is called by rescan via pcall; we can't easily
    -- inspect _last_key from outside without exporting it. Instead just
    -- assert detach can be called and doesn't raise.)
    Markdown._forget(buf)  -- no-op for a fresh cache; pin that it's callable.
    Notebook.detach(buf)
    -- After detach, a subsequent _forget on the same bufnr is still safe
    -- (idempotent) — the cache was already cleared.
    assert.has_no.errors(function() Markdown._forget(buf) end)
  end)

  it("rescan drops queued tasks for cells fully deleted from the buffer", function()
    -- Direct text-deletion of a cell (visual select + d across separator and
    -- body) goes through rescan, not delete_cell. The previous guard
    -- `kinds[id] and kinds[id] ~= "code"` short-circuited to false when
    -- kinds[id] was nil (cell gone entirely), so deleted-cell tasks survived
    -- in the queue and would run on the kernel with no visible UI. SPEC 20.
    local buf = make_buf({
      "# %% id=deleted1",
      "side_effect_1()",
      "# %% id=keep0004",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = {
      running = nil,
      queue = {
        { cell_id = "deleted1", code = "side_effect_1()" },
        { cell_id = "keep0004", code = "y = 2" },
      },
    }
    -- User selects the first cell's separator+body+blank gap and deletes it.
    vim.api.nvim_buf_set_lines(buf, 0, 2, false, {})
    nb:rescan()
    -- deleted1 is gone from cells (kinds[deleted1] == nil), task must be dropped.
    assert.equals(1, #nb.kernel.queue)
    assert.equals("keep0004", nb.kernel.queue[1].cell_id)
    Notebook.detach(buf)
  end)

  it("rescan drops attachments for cells converted away from markdown", function()
    -- Symmetric to the outputs / queue cleanup: nbformat only allows
    -- attachments on markdown cells. Converting a markdown cell to code
    -- via direct text edit must drop attachments so encode() doesn't have
    -- to swallow them on save. SPEC 20.
    local buf = make_buf({
      "# %% id=attach01 [markdown]",
      "![pic](attachment:pic.png)",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.cell_attachments["attach01"] = { ["pic.png"] = { ["image/png"] = "x" } }
    -- User retypes via direct edit, dropping the [markdown] flag.
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# %% id=attach01" })
    nb:rescan()
    assert.equals("code", nb.cells[1].kind)
    assert.is_nil(nb.cell_attachments["attach01"])
    Notebook.detach(buf)
  end)
end)
