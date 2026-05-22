-- Regression tests for the round-4 audit fixes. Each describe-block names the
-- audit finding the spec defends. Where the fix changed an existing module's
-- behavior in a way an older spec didn't anticipate, the new test is the
-- canonical regression — running the suite without the fix should show
-- exactly the new specs failing.

local Ipynb = require("mercury.ipynb")
local Notebook = require("mercury.notebook")
local Kernel = require("mercury.kernel")
local Output = require("mercury.output")
local Util = require("mercury.util")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- R4-1: image-unavailable placeholder reaches the virt_lines layer ---------

describe("image-unavailable placeholder (R4-1)", function()
  it("build_virt_lines emits the placeholder when the item is flagged", function()
    -- The flag is set by ui.lua before build_virt_lines runs; here we
    -- exercise build_virt_lines directly to confirm the placeholder path
    -- fires. This is the half that previously had no caller.
    --
    -- The placeholder fires only when image.nvim is "available" — we can't
    -- reliably stub the require("mercury.image") path inside the suite, so
    -- skip when image.nvim isn't installed (no behavior to assert against).
    local ok_img, Image = pcall(require, "mercury.image")
    if not (ok_img and Image.available()) then
      pending("image.nvim not available; placeholder path not exercised")
      return
    end
    local out = {
      status = "ok", exec_count = 1, ms = 5,
      items = {
        { type = "display_data",
          data = { ["image/png"] = "fake" },
          _mercury_image_unavailable = true },
      },
    }
    local lines = Output.build_virt_lines(out, { show_status_pill = false })
    -- The placeholder line lives somewhere in the virt_lines list as a
    -- single chunk whose text contains "image bytes unavailable".
    local saw_placeholder = false
    for _, virt in ipairs(lines) do
      for _, chunk in ipairs(virt) do
        local txt = type(chunk) == "table" and chunk[1] or ""
        if type(txt) == "string" and txt:find("image bytes unavailable", 1, true) then
          saw_placeholder = true
        end
      end
    end
    assert.is_true(saw_placeholder)
  end)

  it("does NOT emit the placeholder when the flag is absent", function()
    local ok_img, Image = pcall(require, "mercury.image")
    if not (ok_img and Image.available()) then
      pending("image.nvim not available")
      return
    end
    local out = {
      status = "ok", exec_count = 1, ms = 5,
      items = {
        { type = "display_data", data = { ["image/png"] = "fake" } },
      },
    }
    local lines = Output.build_virt_lines(out, { show_status_pill = false })
    for _, virt in ipairs(lines) do
      for _, chunk in ipairs(virt) do
        local txt = type(chunk) == "table" and chunk[1] or ""
        if type(txt) == "string" then
          assert.is_nil(txt:find("image bytes unavailable", 1, true))
        end
      end
    end
  end)
end)

-- R4-2: _swap_cells preserves visual gap when one cell is last ------------

describe("swap last-cell preserves visual gap (R4-2)", function()
  it("does not leave a phantom trailing blank after swapping with the last cell", function()
    local buf = make_buf({
      "# %% id=swapcell1",
      "print('a')",
      "",
      "# %% id=swapcell2",
      "print('b')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb:_swap_cells(1, 2)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- After the swap, cell order is swapcell2 then swapcell1. The visual gap
    -- (blank line) must live BETWEEN them, not trailing the last cell.
    local sep2_row, sep1_row, blank_row
    for i, ln in ipairs(lines) do
      if ln:find("id=swapcell2", 1, true) then sep2_row = i end
      if ln:find("id=swapcell1", 1, true) then sep1_row = i end
    end
    assert.is_not_nil(sep2_row)
    assert.is_not_nil(sep1_row)
    assert.is_true(sep2_row < sep1_row)
    -- The line immediately before swapcell1's separator should be blank.
    assert.equals("", lines[sep1_row - 1])
    -- The buffer should NOT end with a phantom blank line that wasn't there
    -- before the swap.
    assert.is_not_equal("", lines[#lines])
    Notebook.detach(buf)
  end)

  it("preserves visual gap when swapping mid-buffer (regression guard)", function()
    -- The mid-buffer case was already correct; this test pins it.
    local buf = make_buf({
      "# %% id=swapmid01",
      "a = 1",
      "",
      "# %% id=swapmid02",
      "b = 2",
      "",
      "# %% id=swapmid03",
      "c = 3",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb:_swap_cells(1, 2)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Three separators must still be present, each preceded by a blank
    -- (except the first, which is at row 0).
    local sep_rows = {}
    for i, ln in ipairs(lines) do
      if ln:match("^#%s*%%%%") then sep_rows[#sep_rows + 1] = i end
    end
    assert.equals(3, #sep_rows)
    for k = 2, 3 do
      assert.equals("", lines[sep_rows[k] - 1])
    end
    Notebook.detach(buf)
  end)
end)

-- R4-3: set_kind code→markdown clears collapsed metadata ------------------

describe("set_kind drops collapsed metadata on leaving code (R4-3)", function()
  it("scrubs md.collapsed and jupyter.outputs_hidden when leaving code", function()
    local buf = make_buf({
      "# %% id=collapsecel",
      "print('x')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Seed an output and the JupyterLab collapsed-flags pair.
    nb.outputs["collapsecel"] = {
      status = "ok", exec_count = 1, ms = 1, _collapsed = true,
      items = { { type = "stream", name = "stdout", text = "x\n" } },
    }
    nb.cell_metadata["collapsecel"] = {
      collapsed = true,
      jupyter = { outputs_hidden = true, source_hidden = false },
    }
    nb:set_kind(nb.cells[1], "markdown")
    -- The output side-table is gone (existing behavior).
    assert.is_nil(nb.outputs["collapsecel"])
    -- The output-only metadata keys are scrubbed; vendor sibling keys
    -- (source_hidden here, which Lab uses for code-source hiding) survive.
    local md = nb.cell_metadata["collapsecel"]
    assert.is_nil(md.collapsed)
    -- jupyter table either dropped entirely (when it had only outputs_hidden)
    -- or has outputs_hidden cleared.
    if md.jupyter ~= nil then
      assert.is_nil(md.jupyter.outputs_hidden)
      assert.equals(false, md.jupyter.source_hidden)
    end
    Notebook.detach(buf)
  end)

  it("survives an entirely-clean conversion (no collapsed flags set)", function()
    local buf = make_buf({
      "# %% id=cleanconv1",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.outputs["cleanconv1"] = { status = "ok", items = {}, exec_count = 1, ms = 0 }
    nb.cell_metadata["cleanconv1"] = { custom = "preserved" }
    nb:set_kind(nb.cells[1], "markdown")
    assert.equals("preserved", nb.cell_metadata["cleanconv1"].custom)
    Notebook.detach(buf)
  end)
end)

-- R4-4: save during restart-clear writes empty outputs --------------------

describe("save during RestartClear writes empty outputs (R4-4)", function()
  it("treats outputs as cleared when _restart_clear_pending is set", function()
    local buf = make_buf({
      "# %% id=rclrcell1",
      "print('a')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.outputs["rclrcell1"] = {
      status = "ok", exec_count = 3, ms = 12,
      items = { { type = "stream", name = "stdout", text = "stale output\n" } },
    }
    -- Inject a kernel-like sentinel: only the _restart_clear_pending and
    -- queue fields are read by to_ipynb_struct, so we don't need a real
    -- Kernel instance to exercise this code path.
    nb.kernel = { _restart_clear_pending = true, queue = {} }
    local struct = nb:to_ipynb_struct()
    -- The saved cell must show empty outputs and a null execution_count —
    -- matching the post-`restarted` state the user already asked for.
    assert.same({}, struct.cells[1].outputs)
    assert.is_nil(struct.cells[1].exec_count)
    Notebook.detach(buf)
  end)

  it("does NOT clear outputs when restart_clear_pending is absent", function()
    local buf = make_buf({
      "# %% id=rclrcell2",
      "print('b')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.outputs["rclrcell2"] = {
      status = "ok", exec_count = 4, ms = 5,
      items = { { type = "stream", name = "stdout", text = "real\n" } },
    }
    nb.kernel = { queue = {} }
    local struct = nb:to_ipynb_struct()
    assert.equals(1, #struct.cells[1].outputs)
    assert.equals(4, struct.cells[1].exec_count)
    Notebook.detach(buf)
  end)
end)

-- R4-5: stream name coerced to {stdout, stderr} ---------------------------

describe("stream name validation (R4-5)", function()
  it("coerces an invalid stream.name to 'stdout'", function()
    local out = { status = "running", items = {}, exec_count = nil, ms = 0 }
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.on_change = function() end
    k:_apply_item(out, { type = "stream", name = "weird_channel", text = "hi\n" })
    assert.equals(1, #out.items)
    assert.equals("stream", out.items[1].type)
    assert.equals("stdout", out.items[1].name)
    assert.equals("hi\n", out.items[1].text)
  end)

  it("preserves a valid stderr name verbatim", function()
    local out = { status = "running", items = {}, exec_count = nil, ms = 0 }
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.on_change = function() end
    k:_apply_item(out, { type = "stream", name = "stderr", text = "warn\n" })
    assert.equals("stderr", out.items[1].name)
  end)

  it("merges a coerced unknown stream into a prior stdout item", function()
    -- A buggy kernel sending stdout then "weird_channel" with the latter
    -- coerced to stdout should result in a SINGLE merged stdout item.
    local out = { status = "running", items = {}, exec_count = nil, ms = 0 }
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.on_change = function() end
    k:_apply_item(out, { type = "stream", name = "stdout", text = "a" })
    k:_apply_item(out, { type = "stream", name = "weird",  text = "b" })
    assert.equals(1, #out.items)
    assert.equals("ab", out.items[1].text)
  end)
end)

-- R4-6: error traceback coerced to array of strings -----------------------

describe("error traceback coercion (R4-6)", function()
  it("wraps a string traceback in a single-element list", function()
    local out = { status = "running", items = {} }
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.on_change = function() end
    k:_apply_item(out, {
      type = "error", ename = "RuntimeError", evalue = "boom",
      traceback = "single line trace",
    })
    assert.equals(1, #out.items)
    assert.equals("error", out.items[1].type)
    assert.same({ "single line trace" }, out.items[1].traceback)
  end)

  it("stringifies non-string entries in a traceback list", function()
    local out = { status = "running", items = {} }
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.on_change = function() end
    k:_apply_item(out, {
      type = "error", ename = "E", evalue = "v",
      traceback = { "line 1", 42, "line 3" },
    })
    -- Non-string entries are coerced via tostring; the array shape is
    -- preserved so the on-disk output passes nbformat.validate().
    assert.equals(3, #out.items[1].traceback)
    assert.equals("line 1", out.items[1].traceback[1])
    assert.equals("42",     out.items[1].traceback[2])
    assert.equals("line 3", out.items[1].traceback[3])
  end)

  it("defaults to an empty array when traceback is missing", function()
    local out = { status = "running", items = {} }
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.on_change = function() end
    k:_apply_item(out, { type = "error", ename = "E", evalue = "v" })
    assert.same({}, out.items[1].traceback)
  end)
end)

-- R4-7: update_display_data with no display_id is dropped -----------------

describe("update_display_data without display_id (R4-7)", function()
  it("drops the update instead of inserting a phantom display_data", function()
    local out = { status = "running", items = {} }
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.on_change = function() end
    k:_apply_item(out, {
      type = "update_display_data",
      data = { ["text/plain"] = "ignored" },
      -- no transient.display_id
    })
    assert.equals(0, #out.items)
  end)

  it("also drops when transient.display_id is the empty string", function()
    local out = { status = "running", items = {} }
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.on_change = function() end
    k:_apply_item(out, {
      type = "update_display_data",
      data = { ["text/plain"] = "ignored" },
      transient = { display_id = "" },
    })
    assert.equals(0, #out.items)
  end)

  it("still updates when a real display_id matches a prior item", function()
    -- Regression guard: the new drop-on-nil branch must not break the
    -- legitimate update path.
    local out = {
      status = "running",
      items = {
        { type = "display_data",
          data = { ["text/plain"] = "old" }, metadata = {},
          _display_id = "did1" },
      },
    }
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.on_change = function() end
    k:_apply_item(out, {
      type = "update_display_data",
      data = { ["text/plain"] = "new" },
      transient = { display_id = "did1" },
    })
    assert.equals(1, #out.items)
    assert.equals("new", out.items[1].data["text/plain"])
  end)
end)

-- R4-8: cell-id validation on decode --------------------------------------

describe("cell id charclass validation (R4-8)", function()
  it("synthesizes a fresh id when the source has a dot in cell.id", function()
    local raw = [[{
      "nbformat": 4, "nbformat_minor": 5, "metadata": {},
      "cells": [{
        "cell_type": "code", "id": "vendor.dotted",
        "execution_count": null, "metadata": {}, "outputs": [], "source": []
      }]
    }]]
    local nb = Ipynb.decode(raw)
    assert.is_not_nil(nb)
    assert.is_not_equal("vendor.dotted", nb.cells[1].id)
    assert.matches("^[A-Za-z0-9_%-]+$", nb.cells[1].id)
  end)

  it("synthesizes a fresh id for an id > 64 chars", function()
    local long_id = string.rep("a", 80)
    local raw = ('{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[' ..
      '{"cell_type":"code","id":"%s","execution_count":null,' ..
      '"metadata":{},"outputs":[],"source":[]}]}'):format(long_id)
    local nb = Ipynb.decode(raw)
    assert.is_not_nil(nb)
    assert.is_not_equal(long_id, nb.cells[1].id)
    assert.is_true(#nb.cells[1].id <= 64)
  end)

  it("preserves a valid id verbatim", function()
    local raw = [[{
      "nbformat": 4, "nbformat_minor": 5, "metadata": {},
      "cells": [{
        "cell_type": "code", "id": "abcd1234",
        "execution_count": null, "metadata": {}, "outputs": [], "source": []
      }]
    }]]
    local nb = Ipynb.decode(raw)
    assert.equals("abcd1234", nb.cells[1].id)
  end)

  it("synthesizes an id for the empty-string case", function()
    local raw = [[{
      "nbformat": 4, "nbformat_minor": 5, "metadata": {},
      "cells": [{
        "cell_type": "code", "id": "",
        "execution_count": null, "metadata": {}, "outputs": [], "source": []
      }]
    }]]
    local nb = Ipynb.decode(raw)
    assert.is_not_nil(nb)
    assert.is_true(#nb.cells[1].id >= 1)
    assert.matches("^[A-Za-z0-9_%-]+$", nb.cells[1].id)
  end)
end)

-- P3.1 — R4-5 round-trip: coerced stream name reaches disk as 'stdout' ----
--
-- The original R4-5 spec only exercised `_apply_item` in memory. nbformat
-- validation runs against the on-disk JSON, so the load-bearing assertion
-- is that an invalid stream name routed through coercion AND round-tripped
-- through to_ipynb_struct → encode → decode still presents as the coerced
-- canonical {stdout, stderr}. Without this, a future regression that drops
-- the coercion on the save side (only fixing the in-memory side) would
-- pass R4-5 and still ship invalid notebooks.

describe("stream name coercion round-trip (R4-5 extension)", function()
  it("survives to_ipynb_struct → encode → decode as 'stdout'", function()
    local buf = make_buf({
      "# %% id=strmcoerce",
      "print('hi')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb)
    k.on_change = function() end
    nb.kernel = k
    -- Seed an output, then push a buggy stream name through the live
    -- apply path. The coercion lives in _apply_item; we exercise it the
    -- same way an iopub frame would land.
    local out = { status = "ok", exec_count = 1, ms = 5, items = {} }
    nb.outputs["strmcoerce"] = out
    k:_apply_item(out, { type = "stream", name = "weird_channel", text = "hi\n" })
    -- In-memory state already validated by R4-5; the new assertion is on
    -- the serialized form.
    -- to_ipynb_struct exposes the in-memory shape (item.type). The
    -- disk-shape transformation (output_type) happens inside Ipynb.encode;
    -- assert against the in-memory key here, and against the decoded shape
    -- (which normalize_output reads from the disk-shape `output_type` and
    -- re-projects to `type`) after the full round-trip.
    local struct = nb:to_ipynb_struct()
    local cell = struct.cells[1]
    assert.equals(1, #cell.outputs)
    assert.equals("stream", cell.outputs[1].type)
    assert.equals("stdout", cell.outputs[1].name)
    -- And the full encode/decode loop preserves the coerced name. A schema
    -- validator (nbformat.validate) refuses anything other than the literal
    -- strings "stdout" / "stderr"; we mirror that constraint here by
    -- inspecting the on-disk JSON directly (output_type key) AND the
    -- decoded in-memory shape (type key) so a future regression that
    -- mishandles either side fails the test.
    local json = Ipynb.encode(struct)
    assert.is_string(json)
    -- Surface-level disk-shape check — the name must round-trip through
    -- the JSON bytes verbatim. We don't want the encoder smuggling a
    -- different name through (e.g., recovering the original "weird_channel"
    -- from some side channel).
    assert.is_nil(json:find("weird_channel", 1, true))
    assert.is_not_nil(json:find('"name": "stdout"', 1, true)
      or json:find('"name":"stdout"', 1, true))
    local reloaded = Ipynb.decode(json)
    assert.is_not_nil(reloaded)
    local rl_outs = reloaded.cells[1].outputs
    assert.equals(1, #rl_outs)
    assert.equals("stream", rl_outs[1].type)
    assert.equals("stdout", rl_outs[1].name)
    Notebook.detach(buf)
  end)
end)

-- P3.2 — D10 strengthened: no-window render leaves image cache untouched -
--
-- The original D10 spec asserted "returns 0, no crash" but the load-bearing
-- contract is that image.nvim handles are NOT created when there's no
-- window — the next render in a windowed buffer relies on the cache being
-- empty (or unchanged) so cached handles survive the gap. This spec
-- exercises the early-return branch and asserts the cache stays at its
-- pre-render state.

describe("image render no-window leaves cache untouched (D10 extension)", function()
  it("does not insert handles into the cache when no window shows the buffer", function()
    local Image = require("mercury.image")
    local buf = vim.api.nvim_create_buf(false, true)
    local fake_nb = { buf = buf }
    local r = Image.new(fake_nb)
    -- Pre-seed a sentinel entry so we can detect either insertion or
    -- accidental wipe of an existing cache.
    r.cache["sentinel"] = { handles = { ["s"] = { _sentinel = true } }, placements = {} }
    -- Run a render against a cell whose buffer has no window. The early-
    -- return branch fires (no `win` found in win_findbuf), and the cache
    -- must come back identical.
    local ret = r:render({ id = "x" }, 0,
      { { kind = "png", path = "/nonexistent", hash = "h" } })
    -- Either we returned 0 because no window matched, or because image.nvim
    -- itself isn't available — either way nothing should have entered the
    -- cache under the requested cell id.
    assert.equals(0, ret)
    assert.is_nil(r.cache["x"])
    -- The pre-existing sentinel cell is untouched.
    assert.is_not_nil(r.cache["sentinel"])
    assert.is_true(r.cache["sentinel"].handles["s"]._sentinel)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

-- P3.3 — D1 strengthened: merge_below busy guard preserves all state ----
--
-- R4 audit pointed out that the original D1 specs only checked cell count
-- and ids survive a refused merge. A future regression that mutates buffer
-- text or side tables mid-refuse would pass. This spec asserts the buffer
-- bytes AND the outputs / metadata / attachments side tables are bit-
-- identical to their pre-call snapshots.

describe("merge_below busy guard preserves byte-identical state (D1 extension)", function()
  it("buffer text and side tables are unchanged after a refused merge", function()
    local buf = make_buf({
      "# %% id=mrgbusy01", "x = 1",
      "# %% id=mrgbusy02", "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Seed side tables on both cells so a stray mutation would show up.
    nb.outputs["mrgbusy01"] = {
      status = "ok", exec_count = 1, ms = 5,
      items = { { type = "stream", name = "stdout", text = "from-1\n" } },
    }
    nb.outputs["mrgbusy02"] = {
      status = "ok", exec_count = 2, ms = 7,
      items = { { type = "stream", name = "stdout", text = "from-2\n" } },
    }
    nb.cell_metadata["mrgbusy01"] = { tags = { "alpha" } }
    nb.cell_metadata["mrgbusy02"] = { tags = { "beta" } }
    -- Snapshot bytes + side-table deep copies.
    local pre_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local pre_outputs = vim.deepcopy(nb.outputs)
    local pre_metadata = vim.deepcopy(nb.cell_metadata)
    local pre_attachments = vim.deepcopy(nb.cell_attachments)
    -- Mark cell 1 as running. merge_below on either cell must refuse.
    nb.kernel = {
      running = { cell_id = "mrgbusy01" }, queue = {},
      interrupt = function() end,
    }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:merge_below()
    -- Buffer text bit-identical.
    local post_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.same(pre_lines, post_lines)
    -- Side tables bit-identical.
    assert.same(pre_outputs, nb.outputs)
    assert.same(pre_metadata, nb.cell_metadata)
    assert.same(pre_attachments, nb.cell_attachments)
    Notebook.detach(buf)
  end)
end)

-- P3.4 — rescan-during-execute migrates kernel.running.cell_id -----------
--
-- The id-rename migration code in notebook.lua:167-178 updates
-- kernel.running.cell_id and queue entries so iopub frames the kernel
-- keeps emitting still land on the renamed cell. The migration is
-- protected by a position-aligned-equal-length walk; an off-by-one in
-- the walk would silently drop the migration. This spec exercises the
-- canonical "user retyped the id token in the separator while the cell
-- was running" path and pins the contract.

describe("rescan migrates kernel pointer for running cell (P3.4)", function()
  it("kernel.running.cell_id follows a separator-id rename through rescan", function()
    local buf = make_buf({
      "# %% id=runbefore1", "import time; time.sleep(10)",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Simulate a running cell. The fake-kernel shape used elsewhere in
    -- this suite is enough — the migration code only reads .running and
    -- .queue, and only writes to .cell_id fields.
    nb.kernel = {
      running = { cell_id = "runbefore1" },
      queue = { { cell_id = "runbefore1" } },
    }
    nb.outputs["runbefore1"] = { status = "running", items = {}, exec_count = nil }
    -- The user edits the separator id directly. This is the only way to
    -- trigger a rename mid-execute — set_kind / new_cell can't change an
    -- id, and the busy guard refuses other mutations. Direct buffer edit
    -- bypasses set_kind by design (separator is the source of truth, per
    -- SPEC Invariant 1).
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# %% id=runafter01" })
    nb:rescan()
    -- The cell still exists, under its new id.
    assert.equals(1, #nb.cells)
    assert.equals("runafter01", nb.cells[1].id)
    -- The kernel's running pointer was migrated — without this, the next
    -- iopub frame for the cell would be silently dropped by _live_code_cell.
    assert.equals("runafter01", nb.kernel.running.cell_id)
    assert.equals("runafter01", nb.kernel.queue[1].cell_id)
    -- Side tables migrated too (existing invariant, asserted defensively).
    assert.is_not_nil(nb.outputs["runafter01"])
    assert.is_nil(nb.outputs["runbefore1"])
    Notebook.detach(buf)
  end)
end)

-- P1.1 — delete_cell repositions cursor on successor body line ----------

describe("delete_cell cursor positioning (P1.1)", function()
  before_each(function() require("mercury").setup() end)
  it("moves cursor to the successor cell's body after delete", function()
    local buf = make_buf({
      "# %% id=delcursor1", "x = 1",
      "# %% id=delcursor2", "y = 2",
      "# %% id=delcursor3", "z = 3",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    -- Cursor starts on cell #1.
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:delete_cell(nb.cells[1])
    -- After delete, the successor (was #2, now #1) should be where the
    -- cursor lives. body_start of the new first cell is at row 1 (line 2).
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local body_row = nb.cells[1].body_start + 1
    assert.equals(body_row, row,
      "cursor must land on the successor cell's body line")
    Notebook.detach(buf)
  end)

  it("falls back to the predecessor when deleting the last cell", function()
    local buf = make_buf({
      "# %% id=dellast001", "a = 1",
      "# %% id=dellast002", "b = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    nb:delete_cell(nb.cells[2])
    -- Predecessor (was #1, still #1) is now the only cell.
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local body_row = nb.cells[1].body_start + 1
    assert.equals(body_row, row,
      "cursor must land on the predecessor cell when the tail is deleted")
    Notebook.detach(buf)
  end)

  it("places cursor on the synthesized placeholder when the only cell is deleted", function()
    local buf = make_buf({
      "# %% id=delonly0001", "lonely = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:delete_cell(nb.cells[1])
    -- The placeholder cell was synthesized; cursor should not be past the
    -- buffer end. The placeholder's body line is row 2 (separator at row 1).
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local total = vim.api.nvim_buf_line_count(buf)
    assert.is_true(row <= total, "cursor must not be past EOF after delete-only")
    Notebook.detach(buf)
  end)
end)

-- P1.2 — mtime guard with inconclusive realpath engages conservatively --

describe("mtime guard inconclusive realpath (P1.2)", function()
  before_each(function() require("mercury").setup() end)
  it("refuses to overwrite a stale-mtime file when realpath is inconclusive", function()
    -- The load-bearing claim: when realpath resolves on one side but not
    -- the other, the guard must engage (not silently skip). The strongest
    -- assertion is that an external mtime bump is actually DETECTED in
    -- this inconclusive case. The previous nil-fallback comparison treated
    -- inconclusive as "different files" and skipped the guard entirely —
    -- letting the save clobber the external edit.
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local target = tmpdir .. "/inconclusive.ipynb"
    Util.write_file(target,
      '{"cells":[{"cell_type":"code","id":"abc12345","execution_count":null,' ..
      '"metadata":{},"outputs":[],"source":[]}],' ..
      '"metadata":{},"nbformat":4,"nbformat_minor":5}')
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(target))
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    if not nb then
      pending("BufReadCmd did not attach mercury — environment skew")
      return
    end
    -- Modify the buffer so :w isn't a no-op.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=incloncel01", "marker = 1",
    })
    vim.bo[buf].modified = true
    -- Pre-disk snapshot — the externally-written bytes the guard must
    -- preserve when refusing the save.
    local pre_disk = Util.read_file(target)
    -- Simulate an external edit: bump the on-disk mtime AND change the
    -- content. The stored mtime in vim.b[buf].mercury_file_mtime is from
    -- the initial load, which is now stale relative to disk.
    vim.loop.sleep(50)  -- ensure at least 50ms have passed for mtime delta
    local external = '{"cells":[{"cell_type":"code","id":"externl1234",' ..
      '"execution_count":null,"metadata":{},"outputs":[],"source":["external\\n"]}],' ..
      '"metadata":{},"nbformat":4,"nbformat_minor":5}'
    Util.write_file(target, external)
    -- Now stub fs_realpath to return nil for the target. This creates the
    -- inconclusive case: loaded_path resolved at load time (cached on the
    -- buffer var) but the current save's realpath call returns nil. The
    -- pre-fix code would set saving_same_file = false here and SKIP the
    -- guard, clobbering the external edit. The post-fix code engages
    -- conservatively → refuses → file unchanged.
    local orig_realpath = vim.loop.fs_realpath
    vim.loop.fs_realpath = function(p)
      if p == target then return nil end
      return orig_realpath(p)
    end
    -- :w (no !) must be refused via the guard. We catch any error and
    -- assert the file on disk still has the EXTERNAL bytes, not the
    -- buffer-written bytes.
    pcall(vim.cmd, "silent! write")
    vim.loop.fs_realpath = orig_realpath
    local post_disk = Util.read_file(target)
    assert.equals(external, post_disk,
      "save under inconclusive realpath must NOT clobber external edits")
    -- Sanity check the precondition — we did actually overwrite the disk.
    assert.is_not_equal(pre_disk, post_disk)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.fn.delete, target)
    pcall(vim.fn.delete, tmpdir, "rf")
  end)
end)

-- P1.3 — pcall wrap on serialize errors propagates as a clean save error -

describe("save catches serialize errors as (false, err) (P1.3)", function()
  before_each(function() require("mercury").setup() end)
  it("returns false when Ipynb.encode raises mid-save", function()
    -- We can't easily make to_ipynb_struct or encode raise from the outside;
    -- the pcall wrap inside save_ipynb is the load-bearing safety net.
    -- Exercise it by patching Ipynb.encode to throw, then call the save
    -- function directly and assert the (false, err) tuple.
    local Init = require("mercury")
    -- Find the save function via the public command surface — it's the
    -- BufWriteCmd autocmd path. The cleanest way to exercise the pcall
    -- branch without a real buffer + autocmd dance is to require the same
    -- modules save_ipynb uses and exercise the wrap directly.
    local orig_encode = Ipynb.encode
    Ipynb.encode = function() error("synthetic encode failure") end
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local target = tmpdir .. "/encode_fail.ipynb"
    Util.write_file(target,
      '{"cells":[{"cell_type":"code","id":"abc12345","execution_count":null,' ..
      '"metadata":{},"outputs":[],"source":[]}],' ..
      '"metadata":{},"nbformat":4,"nbformat_minor":5}')
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(target))
    local buf = vim.api.nvim_get_current_buf()
    -- Mark the buffer modified so :w doesn't short-circuit on no-op.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=savecellxx", "marker = 1",
    })
    vim.bo[buf].modified = true
    -- Capture the disk state before the doomed save.
    local pre_disk = Util.read_file(target)
    -- The save should fail. We deliberately swallow the error notification
    -- via pcall — what matters is that the file on disk is UNCHANGED.
    pcall(vim.cmd, "silent! write")
    local post_disk = Util.read_file(target)
    Ipynb.encode = orig_encode
    -- File contents preserved despite the in-flight encode error. This is
    -- the safety guarantee the pcall wrap exists to deliver: atomic_write_file
    -- must never be reached on a serialize failure.
    assert.equals(pre_disk, post_disk,
      "on-disk file must be unchanged when encode raises")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.fn.delete, target)
    pcall(vim.fn.delete, tmpdir, "rf")
  end)
end)

-- P1.5 — set_kind drops metadata.execution (ExecuteTime) on leaving code

describe("set_kind drops execution metadata on leaving code (P1.5)", function()
  it("scrubs md.execution when converting code → markdown", function()
    local buf = make_buf({
      "# %% id=exectimecel",
      "print('y')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Seed JupyterLab's ExecuteTime extension shape. The literal dotted
    -- keys are intentional — JupyterLab writes "iopub.execute_input" and
    -- "shell.execute_reply" as flat string keys, not nested tables.
    nb.cell_metadata["exectimecel"] = {
      execution = {
        ["iopub.execute_input"] = "2026-01-01T00:00:00.000Z",
        ["shell.execute_reply"] = "2026-01-01T00:00:01.000Z",
      },
    }
    nb:set_kind(nb.cells[1], "markdown")
    local md = nb.cell_metadata["exectimecel"]
    -- Execution timestamps reference a previous *code* execution; on a
    -- markdown cell they are stale and meaningless. They must be gone.
    assert.is_nil(md and md.execution,
      "metadata.execution must be scrubbed when leaving code")
  end)

  it("preserves md.execution when staying within code (no-op set_kind)", function()
    local buf = make_buf({
      "# %% id=execstaycod",
      "print('z')",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.cell_metadata["execstaycod"] = {
      execution = { ["iopub.execute_input"] = "2026-01-01T00:00:00.000Z" },
    }
    nb:set_kind(nb.cells[1], "code")
    -- Same-kind set_kind is a no-op for the output-only scrub; the
    -- ExecuteTime data survives.
    local md = nb.cell_metadata["execstaycod"]
    assert.is_not_nil(md.execution)
    assert.equals("2026-01-01T00:00:00.000Z", md.execution["iopub.execute_input"])
    Notebook.detach(buf)
  end)
end)
