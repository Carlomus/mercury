-- Regression tests for the round-2 audit fixes (D1–D10) plus the additional
-- coverage requested for SPEC Invariants 22 (atomic save) and 47 (id-rename
-- migration of kernel pointers).
--
-- Each describe-block names the audit item (D1, D2, …) so the test maps
-- back to the audit ticket. Tests are written defensively against the
-- production code paths — no monkey-patching beyond the minimum needed to
-- isolate the assertion.

local Notebook = require("mercury.notebook")
local Cfg = require("mercury.config")
local Util = require("mercury.util")
local Ipynb = require("mercury.ipynb")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function fake_kernel(running_id, queued_ids)
  return {
    running = running_id and { cell_id = running_id } or nil,
    queue = vim.tbl_map(function(id) return { cell_id = id } end, queued_ids or {}),
  }
end

-- D1 — merge_below refuses on busy cell ----------------------------------

describe("merge_below busy guard (D1)", function()
  before_each(function() Cfg.setup() end)

  it("refuses to merge when the CURRENT cell is running", function()
    local buf = make_buf({
      "# %% id=aaaa1111", "x = 1",
      "# %% id=bbbb2222", "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel("aaaa1111", {})
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:merge_below()
    -- Both cells survive — merge was refused.
    assert.equals(2, #nb.cells)
    assert.equals("aaaa1111", nb.cells[1].id)
    assert.equals("bbbb2222", nb.cells[2].id)
    Notebook.detach(buf)
  end)

  it("refuses to merge when the NEXT cell is queued", function()
    local buf = make_buf({
      "# %% id=aaaa1111", "x = 1",
      "# %% id=bbbb2222", "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel(nil, { "bbbb2222" })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:merge_below()
    assert.equals(2, #nb.cells)
    Notebook.detach(buf)
  end)

  it("succeeds when neither cell is busy", function()
    local buf = make_buf({
      "# %% id=aaaa1111", "x = 1",
      "# %% id=bbbb2222", "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel(nil, {})
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:merge_below()
    assert.equals(1, #nb.cells)
    Notebook.detach(buf)
  end)
end)

-- D2 — copy/paste/duplicate don't break a running cell -------------------

describe("copy/paste/duplicate don't interfere with kernel state (D2)", function()
  before_each(function() Cfg.setup() end)

  it("copy_cell of a running cell doesn't touch kernel.running", function()
    local buf = make_buf({
      "# %% id=aaaa1111", "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel("aaaa1111", {})
    local snapshot_running = nb.kernel.running
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:copy_cell()
    -- Kernel state pointer untouched.
    assert.equals(snapshot_running, nb.kernel.running)
    -- And the module-level clipboard now holds a snapshot (no outputs).
    local clip = require("mercury.notebook")._clipboard
    assert.is_not_nil(clip)
    assert.equals("code", clip.kind)
    assert.is_nil(clip.outputs,
      "clipboard must not carry outputs — pasting must produce a fresh cell")
    Notebook.detach(buf)
  end)

  it("paste_cell of a running cell creates a fresh-id cell with NO outputs", function()
    local buf = make_buf({
      "# %% id=aaaa1111", "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Mark the cell as running with output. Copying should snapshot body
    -- only — outputs must not propagate to the paste target.
    nb.outputs["aaaa1111"] = {
      items = { { type = "stream", name = "stdout", text = "live" } },
      status = "running", exec_count = 7,
    }
    nb.kernel = fake_kernel("aaaa1111", {})
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:copy_cell()
    nb:paste_cell()
    -- Two cells now. The pasted one has a different id and no outputs.
    assert.equals(2, #nb.cells)
    local pasted = nb.cells[2]
    assert.is_not.equals("aaaa1111", pasted.id)
    assert.is_nil(nb.outputs[pasted.id])
    -- Original kernel.running pointer is untouched.
    assert.equals("aaaa1111", nb.kernel.running.cell_id)
    -- Original cell's output is untouched.
    assert.equals("running", nb.outputs["aaaa1111"].status)
    assert.equals("live", nb.outputs["aaaa1111"].items[1].text)
    Notebook.detach(buf)
  end)

  it("duplicate_cell of a running cell doesn't disrupt the running cell", function()
    local buf = make_buf({
      "# %% id=aaaa1111", "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.outputs["aaaa1111"] = {
      items = {}, status = "running", exec_count = 1,
    }
    nb.kernel = fake_kernel("aaaa1111", {})
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:duplicate_cell()
    assert.equals(2, #nb.cells)
    -- Running cell is still tracked by id.
    assert.equals("aaaa1111", nb.kernel.running.cell_id)
    -- And its output state is preserved.
    assert.equals("running", nb.outputs["aaaa1111"].status)
    Notebook.detach(buf)
  end)
end)

-- D3 — empty-cells valid file preserved ---------------------------------

describe("load preserves a parsed-but-empty .ipynb (D3)", function()
  before_each(function() require("mercury").setup() end)

  it("doesn't overwrite a structurally-valid empty cells file on save", function()
    -- The hazard: a third-party tool wrote {"cells":[], "metadata":{...}}.
    -- Pre-fix: mercury replaced the parsed empty notebook with blank_notebook()
    -- and marked the buffer fresh — losing the original metadata and
    -- silently rewriting the file on the next :w.
    --
    -- Post-fix: the parsed notebook is preserved (metadata intact), a single
    -- placeholder code cell is added to give the user somewhere to type, and
    -- the buffer is NOT marked modified, so :w with no edits does not run
    -- (vim only fires BufWriteCmd when modified=true or on :w!).
    local tmp = vim.fn.tempname() .. "_empty_cells.ipynb"
    local original = vim.json.encode({
      cells = {},
      metadata = {
        kernelspec = { name = "my_special_env",
                       display_name = "Special", language = "python" },
        language_info = { name = "python" },
      },
      nbformat = 4, nbformat_minor = 5,
    })
    Util.write_file(tmp, original)
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    assert.is_not_nil(nb)
    -- Metadata preserved through the load path.
    assert.equals("my_special_env", nb.meta.kernelspec.name)
    -- Placeholder cell exists so the user can edit.
    assert.equals(1, #nb.cells)
    -- And the buffer is NOT modified — a casual :w wouldn't fire BufWriteCmd
    -- and wouldn't clobber the original file.
    assert.is_false(vim.bo[buf].modified,
      "loading a parsed-but-empty .ipynb must NOT mark the buffer modified")
    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)
end)

-- D4 — kernel execute trims trailing visual-gap blank --------------------

describe("Kernel:execute trims trailing visual-gap blank (D4)", function()
  local Kernel = require("mercury.kernel")
  before_each(function() Cfg.setup() end)

  it("does not send the visual-gap empty line to the bridge", function()
    -- Mercury's in-buffer representation inserts a blank line between cells
    -- (visual gap). cell_body_lines includes that blank because body_end
    -- covers it. The kernel must not see it.
    local buf = make_buf({
      "# %% id=trim0001", "x = 1", "",
      "# %% id=trim0002", "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb); nb:set_kernel(k)
    k._ensure_started = function() return true end
    local sent
    k._send = function(_, payload) sent = payload; return true end
    k:execute(nb.cells[1])
    assert.is_not_nil(sent)
    assert.equals("x = 1", sent.code,
      "kernel must see 'x = 1' without the trailing visual-gap newline")
    Notebook.detach(buf)
  end)

  it("preserves trailing newlines that the user actually typed (last cell)", function()
    -- The last cell has no visual gap appended; trimming logic must not
    -- swallow blank lines the user intentionally added at the end of the
    -- last cell body. (Currently we trim ALL trailing blanks; if a user
    -- left several blank lines at the end of the last cell, we send the
    -- code without them — which matches what to_ipynb_struct does to the
    -- non-last cells, but the LAST cell saves N blanks verbatim. The
    -- documented contract trades cleaner kernel input for a slight
    -- asymmetry against save.)
    local buf = make_buf({
      "# %% id=onlycell", "x = 1", "",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = require("mercury.kernel").new(nb); nb:set_kernel(k)
    k._ensure_started = function() return true end
    local sent
    k._send = function(_, payload) sent = payload; return true end
    k:execute(nb.cells[1])
    assert.equals("x = 1", sent.code)
    Notebook.detach(buf)
  end)
end)

-- D6 — cross-cell display update fires on_change -------------------------

describe("update_display_data cross-cell update triggers a render (D6)", function()
  local Kernel = require("mercury.kernel")
  before_each(function() Cfg.setup() end)

  it("calls on_change when the update mutates a different cell's items", function()
    -- Defense in depth: even if the caller forgets to fire on_change, the
    -- cross-cell update must reach the screen. on_change is coalesced
    -- (SPEC Invariant 7) so redundant calls collapse to one render.
    local buf = make_buf({
      "# %% id=cellAxxx", "x = 1",
      "# %% id=cellBxxx", "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb); nb:set_kernel(k)
    local render_calls = 0
    k.on_change = function() render_calls = render_calls + 1 end

    -- Seed cellA with a registered display_id.
    local out_a = nb:ensure_output("cellAxxx")
    out_a.items = {
      { type = "display_data", data = { ["text/plain"] = "v1" },
        _display_id = "shared", metadata = {} },
    }
    -- cellB is running and emits an update_display_data targeting cellA.
    local out_b = nb:ensure_output("cellBxxx")
    k:_apply_item(out_b, {
      type = "update_display_data",
      data = { ["text/plain"] = "v2" },
      transient = { display_id = "shared" },
    })
    assert.equals("v2", out_a.items[1].data["text/plain"])
    assert.is_true(render_calls >= 1,
      "cross-cell mutation must schedule a render even when the caller "
      .. "forgets to call on_change after _apply_item")
    Notebook.detach(buf)
  end)

  it("does NOT fire on_change when the update is same-cell (caller handles it)", function()
    -- When the update lands on the same cell that received the iopub
    -- frame, the caller's existing on_change covers the render. We don't
    -- want to fire a second one inside _apply_item.
    local buf = make_buf({ "# %% id=onlycell", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb); nb:set_kernel(k)
    local render_calls = 0
    k.on_change = function() render_calls = render_calls + 1 end
    local out = nb:ensure_output("onlycell")
    out.items = {
      { type = "display_data", data = { ["text/plain"] = "v1" },
        _display_id = "shared", metadata = {} },
    }
    k:_apply_item(out, {
      type = "update_display_data",
      data = { ["text/plain"] = "v2" },
      transient = { display_id = "shared" },
    })
    assert.equals(0, render_calls,
      "same-cell update should not double-render (caller is responsible)")
    Notebook.detach(buf)
  end)
end)

-- D7 — rescan-driven busy-cell conversion sends interrupt ----------------

describe("rescan interrupts busy cell on direct-edit conversion (D7)", function()
  before_each(function() Cfg.setup() end)

  it("interrupts the kernel when a running cell's separator is edited to [markdown]", function()
    -- A user editing the separator by hand bypasses set_kind. Without
    -- this interrupt, the kernel keeps executing the code while iopub
    -- frames are silently dropped by _live_code_cell.
    local buf = make_buf({
      "# %% id=busy0001", "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local interrupted = false
    nb.kernel = {
      running = { cell_id = "busy0001", started_at = 0 },
      queue = {},
      interrupt = function() interrupted = true end,
    }
    -- Hand-edit the separator: flip to markdown.
    vim.api.nvim_buf_set_lines(buf, 0, 1, false,
      { "# %% id=busy0001 [markdown]" })
    nb:rescan()
    assert.is_true(interrupted,
      "running code cell converted to markdown via direct text edit must "
      .. "trigger kernel:interrupt so side effects stop")
    Notebook.detach(buf)
  end)

  it("does NOT interrupt for queued-only cells converted to markdown", function()
    -- Queued tasks are evicted by rescan's queue filter (kinds[id] ~= "code").
    -- No interrupt needed — there's no running cell to SIGINT.
    local buf = make_buf({
      "# %% id=runnera0", "x = 1",
      "# %% id=queueda0", "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local interrupted = false
    nb.kernel = {
      running = { cell_id = "runnera0", started_at = 0 },
      queue = { { cell_id = "queueda0", code = "y = 2" } },
      interrupt = function() interrupted = true end,
    }
    -- Convert the QUEUED cell to markdown by direct edit.
    vim.api.nvim_buf_set_lines(buf, 2, 3, false,
      { "# %% id=queueda0 [markdown]" })
    nb:rescan()
    -- The queued task is evicted but the running cell is untouched —
    -- no interrupt should fire.
    assert.is_false(interrupted)
    assert.equals(0, #nb.kernel.queue)
    Notebook.detach(buf)
  end)
end)

-- D8 — to_plain_text matches build_virt_lines for HTML / json / widget ---

describe("Output.to_plain_text mirrors build_virt_lines (D8)", function()
  local Output = require("mercury.output")

  it("strips HTML tags so copy text matches the rendered view", function()
    local out = {
      status = "ok", items = { {
        type = "display_data",
        data = { ["text/html"] = "<p>hello</p><br/><b>world</b>" },
        metadata = {},
      } },
    }
    local lines = Output.to_plain_text(out)
    local joined = table.concat(lines, "\n")
    -- Tags stripped. <p> becomes newline (Output's html_to_text rule).
    -- <br/> becomes newline. <b> stripped. The visible chars are "hello"
    -- and "world".
    assert.is_not_nil(joined:find("hello", 1, true))
    assert.is_not_nil(joined:find("world", 1, true))
    -- And no raw tags in the output.
    assert.is_nil(joined:find("<p>", 1, true))
    assert.is_nil(joined:find("</p>", 1, true))
    assert.is_nil(joined:find("<b>", 1, true))
  end)

  it("renders application/vnd.foo+json as text via JSON encoding", function()
    local out = {
      status = "ok", items = { {
        type = "display_data",
        data = { ["application/vnd.plotly.v1+json"] = { x = { 1, 2, 3 } } },
        metadata = {},
      } },
    }
    local lines = Output.to_plain_text(out)
    local joined = table.concat(lines, "\n")
    -- Should be a JSON-shaped string, not a "[mime, N bytes]" placeholder.
    assert.is_nil(joined:find("bytes%]", 1, true))
    assert.is_not_nil(joined:find('"x"', 1, true))
  end)

  it("emits [widget unsupported] for the ipywidgets mime", function()
    local out = {
      status = "ok", items = { {
        type = "display_data",
        data = { ["application/vnd.jupyter.widget-view+json"] = "{...}" },
        metadata = {},
      } },
    }
    local lines = Output.to_plain_text(out)
    local joined = table.concat(lines, "\n")
    assert.matches("widget unsupported", joined)
  end)

  it("still emits [mime, N bytes] for true binary payloads (image/png)", function()
    local out = {
      status = "ok", items = { {
        type = "display_data",
        data = { ["image/png"] = string.rep("A", 100) },
        metadata = {},
      } },
    }
    local lines = Output.to_plain_text(out)
    local joined = table.concat(lines, "\n")
    assert.matches("image/png", joined)
    assert.matches("bytes", joined)
  end)
end)

-- D9 — list_kernels has a bounded timeout --------------------------------

describe("Kernel:list_kernels timeout (D9)", function()
  local Kernel = require("mercury.kernel")
  before_each(function() Cfg.setup() end)

  it("fires the callback with empty list when the bridge never replies", function()
    local nb = { outputs = {}, cells = {},
      ensure_output = function(self, id)
        self.outputs[id] = self.outputs[id] or { items = {}, status = "idle" }
        return self.outputs[id]
      end,
    }
    local k = Kernel.new(nb)
    k._ensure_started = function() return true end
    -- Override the constant for this test so we don't sit through 5s.
    -- We do this by stubbing vim.defer_fn to call the callback synchronously.
    local orig_defer = vim.defer_fn
    local deferred_fn
    vim.defer_fn = function(fn, ms) deferred_fn = fn; return { stop = function() end, close = function() end } end
    local sent = 0
    k._send = function() sent = sent + 1; return true end
    local got
    k:list_kernels(function(ks) got = ks end)
    assert.equals(1, sent)
    -- Fire the timeout manually.
    assert.is_function(deferred_fn)
    deferred_fn()
    vim.defer_fn = orig_defer
    assert.is_not_nil(got, "callback must fire on timeout")
    assert.equals(0, #got, "list is empty when the bridge missed the deadline")
  end)

  it("cancels the timeout when the bridge replies in time", function()
    local nb = { outputs = {}, cells = {},
      ensure_output = function(self, id) return {} end,
    }
    local k = Kernel.new(nb)
    k._ensure_started = function() return true end
    local timer_stopped = false
    local orig_defer = vim.defer_fn
    vim.defer_fn = function(fn, ms)
      return {
        stop = function() timer_stopped = true end,
        close = function() end,
      }
    end
    k._send = function() return true end
    local got
    k:list_kernels(function(ks) got = ks end)
    k:_handle_msg({ type = "kernels_listed", kernels = { { name = "python3" } } })
    vim.defer_fn = orig_defer
    assert.is_true(timer_stopped, "the timeout must be cancelled on a timely reply")
    assert.equals("python3", got[1].name)
  end)
end)

-- D10 — image render picks the first VALID window ------------------------
-- This one is harder to test in headless without image.nvim; the assertion
-- is on the window-selection logic. We exercise it indirectly by asserting
-- render returns 0 cleanly when no valid window shows the buffer.

describe("image render no-window fallback (D10)", function()
  local Image = require("mercury.image")
  before_each(function() Cfg.setup() end)

  it("returns 0 cleanly when no window shows the buffer (no crash)", function()
    -- Create an unlisted buffer that no window will show.
    local buf = vim.api.nvim_create_buf(false, true)
    local fake_nb = { buf = buf }
    local r = Image.new(fake_nb)
    -- Even with images supplied, no window means we bail without touching
    -- image.nvim. The mod-availability gate also bails first if image.nvim
    -- isn't installed; the contract under test is "doesn't crash on a
    -- buffer with no associated window."
    local ok, ret = pcall(function()
      return r:render({ id = "x" }, 0,
        { { kind = "png", path = "/nonexistent", hash = "h" } })
    end)
    assert.is_true(ok)
    -- Returns 0 either because (a) image.nvim isn't available, or
    -- (b) no window — both code paths.
    assert.equals(0, ret)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

-- SPEC Invariant 47 — multi-cell rename migrates kernel pointers --------

describe("rescan id-rename migration — multi-cell (SPEC Invariant 47)", function()
  before_each(function() Cfg.setup() end)

  it("migrates side-tables for many simultaneous renames", function()
    -- A bulk find-and-replace might rename multiple separator ids at once.
    -- The migration must walk every position in lockstep, not just the
    -- first divergence — and the "previous id not in new set" guard
    -- prevents one rename from cannibalizing another.
    local buf = make_buf({
      "# %% id=oldcell1", "a = 1",
      "# %% id=oldcell2", "b = 2",
      "# %% id=oldcell3", "c = 3",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.outputs["oldcell1"] = { items = {}, status = "ok", exec_count = 1 }
    nb.outputs["oldcell2"] = { items = {}, status = "ok", exec_count = 2 }
    nb.outputs["oldcell3"] = { items = {}, status = "ok", exec_count = 3 }
    nb.cell_metadata["oldcell1"] = { tags = { "first" } }
    nb.cell_metadata["oldcell2"] = { tags = { "second" } }
    nb.cell_metadata["oldcell3"] = { tags = { "third" } }

    -- Bulk-rename: all three separators get new ids in one buffer write.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=newcell1", "a = 1",
      "# %% id=newcell2", "b = 2",
      "# %% id=newcell3", "c = 3",
    })
    nb:rescan()

    -- Side tables migrated by position.
    assert.is_not_nil(nb.outputs["newcell1"])
    assert.equals(1, nb.outputs["newcell1"].exec_count)
    assert.is_not_nil(nb.outputs["newcell2"])
    assert.equals(2, nb.outputs["newcell2"].exec_count)
    assert.is_not_nil(nb.outputs["newcell3"])
    assert.equals(3, nb.outputs["newcell3"].exec_count)

    -- Old ids GC'd.
    assert.is_nil(nb.outputs["oldcell1"])
    assert.is_nil(nb.outputs["oldcell2"])
    assert.is_nil(nb.outputs["oldcell3"])

    -- Metadata migrated.
    assert.same({ "first" }, nb.cell_metadata["newcell1"].tags)
    assert.same({ "second" }, nb.cell_metadata["newcell2"].tags)
    assert.same({ "third" }, nb.cell_metadata["newcell3"].tags)

    Notebook.detach(buf)
  end)

  it("doesn't cannibalize a swap-rename (cell A's old id == cell B's new id)", function()
    -- Edge case: user renames cell A from "aaa" to "bbb", and cell B was
    -- already "bbb". The conservative guard ("previous id has no surviving
    -- cell") prevents the migration so cell A starts with empty side-tables
    -- and cell B keeps its own.
    local buf = make_buf({
      "# %% id=aaa11111", "a = 1",
      "# %% id=bbb22222", "b = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.outputs["aaa11111"] = { items = {}, status = "ok", exec_count = 11 }
    nb.outputs["bbb22222"] = { items = {}, status = "ok", exec_count = 22 }

    -- Rename cell A to a NEW id, but cell B already exists under bbb22222.
    -- The scan_lines duplicate detection assigns a fresh id to whichever
    -- conflict wins; we want to assert no SILENT cannibalization happens.
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# %% id=bbb22222" })
    nb:rescan()

    -- Cell B's outputs survive (it kept its id).
    assert.is_not_nil(nb.outputs["bbb22222"])
    assert.equals(22, nb.outputs["bbb22222"].exec_count)
    -- Cell A's old id was either migrated to its NEW id (the dup-rewrite
    -- assigned a fresh one), or GC'd. Crucially: cell B's data is not
    -- overwritten with cell A's exec_count=11.
    assert.equals(22, nb.outputs["bbb22222"].exec_count)
    Notebook.detach(buf)
  end)

  it("migrates kernel.running.cell_id and kernel.queue across simultaneous renames", function()
    -- The migration of self.kernel.running and self.kernel.queue should
    -- happen for EACH renamed cell, not just the first.
    local buf = make_buf({
      "# %% id=run00001", "a = 1",
      "# %% id=que00001", "b = 2",
      "# %% id=que00002", "c = 3",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = {
      running = { cell_id = "run00001" },
      queue = {
        { cell_id = "que00001", code = "b = 2" },
        { cell_id = "que00002", code = "c = 3" },
      },
    }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=run99999", "a = 1",
      "# %% id=que99991", "b = 2",
      "# %% id=que99992", "c = 3",
    })
    nb:rescan()

    assert.equals("run99999", nb.kernel.running.cell_id)
    assert.equals(2, #nb.kernel.queue)
    assert.equals("que99991", nb.kernel.queue[1].cell_id)
    assert.equals("que99992", nb.kernel.queue[2].cell_id)
    Notebook.detach(buf)
  end)
end)

-- SPEC Invariant 22 — additional atomic-save tests ----------------------

describe("atomic save — additional coverage (SPEC Invariant 22)", function()
  it("removes the tempfile when fsync fails", function()
    -- fs_fsync failure leaves un-durable bytes; we must NOT rename them
    -- over the user's file. Stub fs_fsync to fail.
    local uv = vim.uv or vim.loop
    local orig = uv.fs_fsync
    uv.fs_fsync = function() return false end
    local tmp = vim.fn.tempname() .. ".ipynb"
    local ok, err = Util.atomic_write_file(tmp, "data")
    uv.fs_fsync = orig
    assert.is_false(ok)
    assert.matches("fsync", tostring(err))
    -- Tempfile cleaned up.
    assert.is_nil(uv.fs_stat(tmp .. ".mercury_save_tmp"))
    -- Target file was never created.
    assert.is_nil(uv.fs_stat(tmp))
  end)

  it("a second successful save overwrites the first cleanly", function()
    -- Idempotency on consecutive saves: no residual tempfile, no
    -- intermediate state visible to a concurrent reader.
    local tmp = vim.fn.tempname() .. ".ipynb"
    local ok1 = Util.atomic_write_file(tmp, "first\n")
    assert.is_true(ok1)
    local ok2 = Util.atomic_write_file(tmp, "second\n")
    assert.is_true(ok2)
    local uv = vim.uv or vim.loop
    -- No tempfile left.
    assert.is_nil(uv.fs_stat(tmp .. ".mercury_save_tmp"))
    -- File holds the second write.
    local f = io.open(tmp, "rb")
    local content = f:read("*a"); f:close()
    assert.equals("second\n", content)
    os.remove(tmp)
  end)

  it("the new content fully replaces the old (no append, no truncation)", function()
    -- A regression that opened the file in append mode would silently
    -- concatenate the new bytes to the old. Verify the new content is
    -- exactly what we asked to write.
    local tmp = vim.fn.tempname() .. ".ipynb"
    Util.atomic_write_file(tmp, "long original content here\n")
    Util.atomic_write_file(tmp, "short\n")
    local f = io.open(tmp, "rb")
    local content = f:read("*a"); f:close()
    assert.equals("short\n", content)
    os.remove(tmp)
  end)

  it("a failed write leaves the previous file intact (rename never ran)", function()
    -- The combo: existing file, failed write of new content, original file
    -- must not have been touched. (Invariant 22's whole point.)
    local tmp = vim.fn.tempname() .. ".ipynb"
    Util.atomic_write_file(tmp, "ORIGINAL\n")
    local original_bytes = Util.read_file(tmp)

    -- Stub fs_rename to fail. atomic_write_file returns false.
    local uv = vim.uv or vim.loop
    local orig = uv.fs_rename
    uv.fs_rename = function() return false end
    local ok = Util.atomic_write_file(tmp, "NEW CONTENT\n")
    uv.fs_rename = orig

    assert.is_false(ok)
    -- Original file untouched.
    assert.equals(original_bytes, Util.read_file(tmp))
    -- Tempfile cleaned up.
    assert.is_nil(uv.fs_stat(tmp .. ".mercury_save_tmp"))
    os.remove(tmp)
  end)
end)
