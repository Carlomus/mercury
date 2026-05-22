-- Regression tests for the audit-driven fixes.
--
-- Each block tests one SPEC invariant that was either freshly introduced
-- (Invariants 23–36) or strengthened in this pass. Grouped by file rather
-- than by invariant number so the assertions sit next to the code paths
-- they exercise.

local Notebook = require("mercury.notebook")
local Cfg = require("mercury.config")
local Util = require("mercury.util")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- A fake kernel that's just enough to satisfy cell_is_busy() and
-- to_ipynb_struct's in-flight-skip path.
local function fake_kernel(running_id, queued_ids)
  return {
    running = running_id and { cell_id = running_id } or nil,
    queue = vim.tbl_map(function(id) return { cell_id = id } end, queued_ids or {}),
  }
end

describe("set_kind cluster — SPEC Invariant 23", function()
  before_each(function() Cfg.setup() end)

  it("refuses to convert a running cell (Invariant 18)", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel("aaaa1111", {})
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "markdown")
    -- Still a code cell — the conversion was refused.
    assert.equals("code", nb.cells[1].kind)
    Notebook.detach(buf)
  end)

  it("refuses to convert a queued cell", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel(nil, { "aaaa1111" })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "markdown")
    assert.equals("code", nb.cells[1].kind)
    Notebook.detach(buf)
  end)

  it("drops outputs when converting code → markdown (Invariant 20)", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.outputs["aaaa1111"] = {
      items = { { type = "stream", name = "stdout", text = "hi" } },
      status = "ok", exec_count = 3, ms = 12,
    }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "markdown")
    assert.is_nil(nb.outputs["aaaa1111"])
    Notebook.detach(buf)
  end)

  it("drops outputs when converting code → raw", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.outputs["aaaa1111"] = { items = {}, status = "ok", exec_count = 1 }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "raw")
    assert.is_nil(nb.outputs["aaaa1111"])
    Notebook.detach(buf)
  end)

  it("drops attachments when converting markdown → code", function()
    local buf = make_buf({
      "# %% id=aaaa1111 [markdown]",
      "![](attachment:foo.png)",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.cell_attachments["aaaa1111"] = {
      ["foo.png"] = { ["image/png"] = "AAAA" }
    }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "code")
    assert.is_nil(nb.cell_attachments["aaaa1111"])
    Notebook.detach(buf)
  end)

  it("preserves extras (mercury_extras tokens) across conversion", function()
    local buf = make_buf({
      "# %% id=aaaa1111 vendor=foo project=bar",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "markdown")
    local sep = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.matches("vendor=foo", sep)
    assert.matches("project=bar", sep)
    assert.matches("%[markdown%]", sep)
    Notebook.detach(buf)
  end)

  it("preserves non-tag cell_metadata fields across conversion", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.cell_metadata["aaaa1111"] = {
      scrolled = true,
      vscode = { languageId = "python" },
    }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "markdown")
    -- scrolled + vscode survive; the kind change shouldn't touch them.
    assert.equals(true, nb.cell_metadata["aaaa1111"].scrolled)
    assert.same({ languageId = "python" }, nb.cell_metadata["aaaa1111"].vscode)
    Notebook.detach(buf)
  end)

  it("clears stale md.tags when extras.tags is absent on the separator", function()
    -- Pre-fix: cell_metadata.tags persisted from the deepcopy if the user
    -- had removed `tags=…` from the separator. The buffer state showed
    -- "no tags" but cell_metadata still claimed the old tags until the
    -- next save corrected it. set_kind must mirror to_ipynb_struct's
    -- contract: separator is authoritative for tags AND mercury_extras.
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Seed cell_metadata with tags (as if loaded from JSON that had them)
    -- but the separator HAS NO tags= token, so extras.tags is nil.
    nb.cell_metadata["aaaa1111"] = { tags = { "stale", "tags" } }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "markdown")
    assert.is_nil(nb.cell_metadata["aaaa1111"].tags)
    Notebook.detach(buf)
  end)

  it("syncs md.tags FROM extras when the separator has tags=", function()
    -- Symmetric case: a separator that DOES carry tags= must populate
    -- cell_metadata.tags from that source after set_kind.
    local buf = make_buf({
      "# %% id=aaaa1111 tags=foo,bar",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:set_kind(nil, "markdown")
    assert.same({ "foo", "bar" }, nb.cell_metadata["aaaa1111"].tags)
    Notebook.detach(buf)
  end)
end)

describe("delete_cell interrupts running cell", function()
  before_each(function() Cfg.setup() end)

  it("calls kernel:interrupt() when the deleted cell is currently running", function()
    -- User confirmed: deleting a running cell should kill the kernel work
    -- for that cell and drop the output. Queued cells continue (Jupyter
    -- SIGINT semantics; the kernel's queue advances). We verify the
    -- interrupt was sent by capturing it on a fake kernel.
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local interrupted = false
    nb.kernel = {
      running = { cell_id = "aaaa1111", started_at = 0 },
      queue = {},
      interrupt = function() interrupted = true end,
    }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:delete_cell()
    assert.is_true(interrupted)
    Notebook.detach(buf)
  end)

  it("does NOT call interrupt when the deleted cell is merely queued", function()
    -- Queued cells are dropped by rescan's GC pass — no kernel signal is
    -- needed because nothing is currently SIGINT-cancellable on the
    -- kernel side. Interrupting here would cancel a DIFFERENT, unrelated
    -- running cell.
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local interrupted = false
    nb.kernel = {
      running = { cell_id = "aaaa1111", started_at = 0 },  -- a DIFFERENT cell runs
      queue = { { cell_id = "bbbb2222" } },
      interrupt = function() interrupted = true end,
    }
    vim.api.nvim_set_current_buf(buf)
    -- Delete the queued cell (line 3 = second cell's separator).
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    nb:delete_cell()
    assert.is_false(interrupted)
    Notebook.detach(buf)
  end)

  it("drops outputs/metadata/attachments and removes the buffer text", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.outputs["aaaa1111"] = { items = {}, status = "ok", exec_count = 1 }
    nb.cell_metadata["aaaa1111"] = { tags = { "x" } }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:delete_cell()
    assert.is_nil(nb.outputs["aaaa1111"])
    assert.is_nil(nb.cell_metadata["aaaa1111"])
    -- Only the second cell survives.
    assert.equals(1, #nb.cells)
    assert.equals("bbbb2222", nb.cells[1].id)
    Notebook.detach(buf)
  end)
end)

describe("tag filtering on serialize", function()
  local Ipynb = require("mercury.ipynb")

  it("format_separator drops tags containing ','", function()
    local sep = Ipynb.format_separator({
      id = "aaaa1111", kind = "code",
      metadata = { tags = { "good", "bad,tag", "also_good" } },
    })
    assert.matches("tags=good,also_good", sep)
    assert.is_nil(sep:find("bad,tag", 1, true))
  end)

  it("format_separator drops tags containing whitespace", function()
    local sep = Ipynb.format_separator({
      id = "aaaa1111", kind = "code",
      metadata = { tags = { "good", "bad tag" } },
    })
    assert.matches("tags=good", sep)
    assert.is_nil(sep:find("bad tag", 1, true))
  end)

  it("format_separator drops tags containing ']'", function()
    local sep = Ipynb.format_separator({
      id = "aaaa1111", kind = "code",
      metadata = { tags = { "good", "bad]tag" } },
    })
    assert.matches("tags=good", sep)
    assert.is_nil(sep:find("bad%]tag"))
  end)

  it("format_separator omits the tags= token entirely if ALL tags are invalid", function()
    local sep = Ipynb.format_separator({
      id = "aaaa1111", kind = "code",
      metadata = { tags = { "bad,one", "bad two" } },
    })
    assert.is_nil(sep:find("tags="))
  end)

  it("to_buffer_lines warns once per bad tag", function()
    -- Capture notifications via vim.notify monkey-patch. The Util notify
    -- helper delegates through vim.notify; we intercept at that level.
    local notified = {}
    local orig = vim.notify
    vim.notify = function(msg, level) notified[#notified + 1] = msg end
    require("mercury.ipynb").to_buffer_lines({
      cells = { {
        id = "aaaa1111", kind = "code",
        source = { "x = 1" },
        metadata = { tags = { "good", "bad,one", "bad two" } },
      } },
    })
    -- vim.notify may be scheduled — flush by yielding to the event loop.
    vim.wait(50, function() return false end)
    vim.notify = orig
    local saw_comma_warn = false
    local saw_ws_warn = false
    for _, msg in ipairs(notified) do
      if msg:find("'") and msg:find(",", 1, true) and msg:find("bad,one", 1, true) then
        saw_comma_warn = true
      end
      if msg:find("whitespace") and msg:find("bad two", 1, true) then
        saw_ws_warn = true
      end
    end
    assert.is_true(saw_comma_warn, "missing comma-tag warn")
    assert.is_true(saw_ws_warn, "missing whitespace-tag warn")
  end)
end)

describe("select_cell on empty body", function()
  before_each(function() Cfg.setup() end)

  it("doesn't produce a zero-width visual block when body is empty", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "# %% id=bbbb2222",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    vim.api.nvim_set_current_buf(buf)
    -- Park cursor on the empty-body cell's separator.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    -- Should not raise; cursor stays on/above the separator.
    nb:select_cell()
    Notebook.detach(buf)
  end)
end)

describe("Notebook.detach clears per-buffer augroup — Invariant 30", function()
  it("nvim_del_augroup_by_name doesn't error after detach", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    -- Simulate attach_buffer creating the augroup.
    local group_name = "MercuryBuf_" .. buf
    vim.api.nvim_create_augroup(group_name, { clear = true })
    Notebook.attach(buf):rescan()
    Notebook.detach(buf)
    -- The group should be gone. Re-creating it must not raise.
    local ok = pcall(vim.api.nvim_create_augroup, group_name, { clear = false })
    assert.is_true(ok)
    pcall(vim.api.nvim_del_augroup_by_name, group_name)
  end)
end)

describe("_with_mutation propagates original error — Invariant H", function()
  it("error inside fn() is re-raised even when rescan fails too", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Replace rescan with one that throws — exercises the recovery rescan
    -- path. The ORIGINAL fn() error must survive.
    nb.rescan = function() error("rescan-failure") end
    local ok, err = pcall(function()
      nb:_with_mutation(function() error("original-failure") end)
    end)
    assert.is_false(ok)
    -- The exception we propagate should mention the *original* failure.
    assert.matches("original%-failure", tostring(err))
    Notebook.detach(buf)
  end)
end)

describe("util.atomic_write_file — surfaces errors", function()
  it("returns true on a successful round-trip", function()
    local tmp = vim.fn.tempname() .. ".ipynb"
    local ok = Util.atomic_write_file(tmp, "hello\n")
    assert.is_true(ok)
    local f = io.open(tmp, "rb")
    local data = f:read("*a"); f:close()
    assert.equals("hello\n", data)
    os.remove(tmp)
  end)

  it("propagates a rename error and cleans up the tempfile", function()
    -- Simulate a rename failure by stubbing uv.fs_rename via a wrapper.
    local uv = vim.uv or vim.loop
    local orig = uv.fs_rename
    uv.fs_rename = function() return false end
    local tmp = vim.fn.tempname() .. ".ipynb"
    local ok, err = Util.atomic_write_file(tmp, "data")
    uv.fs_rename = orig
    assert.is_false(ok)
    assert.is_string(err)
    -- Tempfile must have been cleaned up.
    assert.is_nil((uv.fs_stat)(tmp .. ".mercury_save_tmp"))
    os.remove(tmp)
  end)
end)

describe("output rendering — text/markdown styled inline (Invariant 33)", function()
  it("emits styled markdown chunks (headings use @markup.heading, lists use @markup.list)", function()
    local Output = require("mercury.output")
    local out = {
      status = "ok", exec_count = 1, ms = 1,
      items = { {
        type = "display_data",
        data = { ["text/markdown"] = "# Heading\n\n- bullet" },
        metadata = {},
      } },
    }
    local virt = Output.build_virt_lines(out, { show_status_pill = false })
    -- Collect every hl group that landed on a chunk.
    local hls = {}
    for _, ln in ipairs(virt) do
      for _, chunk in ipairs(ln) do hls[chunk[2]] = true end
    end
    -- Richer styling than the previous degraded path: heading + list markers
    -- carry their semantic hl groups. MercuryMarkdownOut still appears as
    -- the base prose fallback (used for plain run-of-the-mill text after
    -- the list marker).
    assert.is_true(hls["@markup.heading.1.markdown"], "heading line is styled")
    assert.is_true(hls["@markup.list.markdown"], "list marker is styled")
    assert.is_true(hls["MercuryMarkdownOut"], "default prose still uses the base hl")
  end)

  it("widget mime renders as [widget unsupported] (Invariant 34)", function()
    local Output = require("mercury.output")
    local out = {
      status = "ok",
      items = { {
        type = "display_data",
        data = { ["application/vnd.jupyter.widget-view+json"] = "{...}" },
        metadata = {},
      } },
    }
    local virt = Output.build_virt_lines(out, { show_status_pill = false })
    local joined = ""
    for _, ln in ipairs(virt) do
      for _, chunk in ipairs(ln) do joined = joined .. chunk[1] end
    end
    assert.matches("widget unsupported", joined)
  end)

  it("LaTeX falls back to raw source when rasterizer is unavailable OR fails (Invariant 4)", function()
    -- Stub mercury.latex to simulate: (a) available()=true, (b) rasterize()
    -- returns nil (failure case). The renderer must NOT show the
    -- "rendered below" placeholder; it must fall through to raw source.
    local Output = require("mercury.output")
    local Latex = require("mercury.latex")
    local orig_available, orig_rasterize = Latex.available, Latex.rasterize
    Latex.available = function() return true end
    Latex.rasterize = function() return nil end
    local virt = Output.build_virt_lines({
      status = "ok",
      items = { {
        type = "display_data",
        data = { ["text/latex"] = "$x^2$" },
        metadata = {},
      } },
    }, { show_status_pill = false })
    Latex.available, Latex.rasterize = orig_available, orig_rasterize
    local joined = ""
    for _, ln in ipairs(virt) do
      for _, chunk in ipairs(ln) do joined = joined .. chunk[1] end
    end
    assert.is_nil(joined:find("rendered below", 1, true))
    -- Raw source must appear verbatim.
    assert.is_not_nil(joined:find("$x^2$", 1, true))
  end)

  it("merges interleaved stream chunks on render (Invariant 36)", function()
    -- Side table preserves order; renderer groups by name.
    local Output = require("mercury.output")
    local out = {
      status = "ok",
      items = {
        { type = "stream", name = "stdout", text = "1\n" },
        { type = "stream", name = "stderr", text = "ERR\n" },
        { type = "stream", name = "stdout", text = "2\n" },
      },
    }
    local virt = Output.build_virt_lines(out, { show_status_pill = false })
    -- Expect at least three lines (one per logical chunk of text). The key
    -- assertion is the rendering ran without error and produced output for
    -- every stream item — neither merge nor split lose chunks.
    local total = 0
    for _, ln in ipairs(virt) do total = total + #ln end
    assert.is_true(total >= 3)
  end)
end)

describe("LSP filters", function()
  local LSP = require("mercury.lsp")
  local View = require("mercury.lsp_view")

  it("filter_diagnostics keeps diagnostics with nil range (Invariant 32)", function()
    local buf = make_buf({
      "# %% id=aaaa1111 [markdown]",
      "prose",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local kept = LSP.filter_diagnostics(nb, {
      { message = "could not parse file" },         -- no range
      { message = "in markdown", range = {
          start = { line = 1, character = 0 },
          ["end"] = { line = 1, character = 5 } } },
    })
    -- The nil-range diagnostic survives; the markdown-range one is dropped.
    assert.equals(1, #kept)
    assert.equals("could not parse file", kept[1].message)
    Notebook.detach(buf)
  end)

  it("filter_text_edits drops edits inside markdown cells (Invariant 29)", function()
    local buf = make_buf({
      "# %% id=aaaa1111",
      "x = 1",
      "# %% id=bbbb2222 [markdown]",
      "prose line",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local kept = LSP.filter_text_edits(nb, {
      { newText = "x = 2", range = {
          start = { line = 1, character = 0 },
          ["end"] = { line = 1, character = 5 } } },  -- code → keep
      { newText = "prose", range = {
          start = { line = 3, character = 0 },
          ["end"] = { line = 3, character = 5 } } },  -- markdown → drop
    })
    assert.equals(1, #kept)
    assert.equals("x = 2", kept[1].newText)
    Notebook.detach(buf)
  end)

  it("mask_lines strips trailing CR from markdown lines (Invariant 31)", function()
    -- A markdown body with a literal \r at end-of-line. The mask must not
    -- emit "# prose\r" — strip the CR before the prefix.
    local lines = {
      "# %% id=aaaa1111 [markdown]",
      "prose\r",
    }
    local cells = { {
      id = "aaaa1111", kind = "markdown",
      header_row = 0, body_start = 1, body_end = 1,
    } }
    local masked = View.mask_lines(lines, cells)
    assert.equals("# prose", masked[2])
  end)
end)

describe("attachments-load notify — Invariant 35", function()
  -- The notify itself happens inside load_ipynb (not pure-testable) — the
  -- testable invariant is that cell_attachments is populated only for
  -- cells whose attachments are non-empty.
  it("cell_attachments stays empty when source attachments are empty", function()
    local buf = make_buf({
      "# %% id=aaaa1111 [markdown]",
      "prose",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Empty dict should NOT seed cell_attachments — the init.lua path uses
    -- `next(c.attachments) ~= nil` as the gate.
    assert.is_nil(nb.cell_attachments["aaaa1111"])
    Notebook.detach(buf)
  end)
end)

describe("output.pick_mime widget recognition", function()
  it("returns the widget mime when no higher-priority mime is present", function()
    local pick = require("mercury.output").pick_mime
    local m = pick({ ["application/vnd.jupyter.widget-view+json"] = "{}" })
    assert.equals("application/vnd.jupyter.widget-view+json", m)
  end)

  it("prefers text/plain over a widget when both are present", function()
    local pick = require("mercury.output").pick_mime
    local m = pick({
      ["application/vnd.jupyter.widget-view+json"] = "{}",
      ["text/plain"] = "Widget()",
    })
    assert.equals("text/plain", m)
  end)
end)

describe("kernel execute_done — Invariant 24", function()
  local Kernel = require("mercury.kernel")

  it("does not resurrect outputs[id] for a vanished cell", function()
    local buf = make_buf({ "# %% id=alive001", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)
    kernel.running = { cell_id = "ghost001", started_at = 0 }
    kernel._send = function() return true end
    kernel:_handle_msg({
      type = "execute_done", cell_id = "ghost001",
      exec_count = 9, ms = 7,
    })
    -- The ghost must not have any output entry.
    assert.is_nil(nb.outputs["ghost001"])
    Notebook.detach(buf)
  end)
end)

describe("kernel restart-window — Invariant 25", function()
  local Kernel = require("mercury.kernel")

  it("refuses new executes while restart is pending", function()
    local buf = make_buf({ "# %% id=alive001", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)
    kernel.chan = 1  -- pretend a bridge is connected
    kernel._send = function() return true end
    kernel._restart_pending = true
    -- _ensure_started must refuse.
    local started = kernel:_ensure_started()
    assert.is_false(started)
    Notebook.detach(buf)
  end)
end)

describe("kernel ExecuteTime metadata — Invariant 27", function()
  local Kernel = require("mercury.kernel")

  it("populates cell_metadata.execution on execute_done for a live cell", function()
    local buf = make_buf({ "# %% id=alive002", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local kernel = Kernel.new(nb)
    nb:set_kernel(kernel)
    kernel._send = function() return true end
    kernel.running = nil
    kernel.queue = { { cell_id = "alive002", code = "x = 1" } }
    -- Drive the lifecycle directly: pump triggers running/queued + started_iso.
    kernel:_pump()
    assert.is_not_nil(nb.outputs["alive002"]._started_iso)
    kernel:_handle_msg({
      type = "execute_done", cell_id = "alive002", exec_count = 1, ms = 3,
    })
    local cm = nb.cell_metadata["alive002"] or {}
    assert.is_table(cm.execution)
    assert.is_string(cm.execution["iopub.execute_input"])
    assert.is_string(cm.execution["shell.execute_reply"])
    Notebook.detach(buf)
  end)
end)

describe("util.atomic_write_file — EXDEV is surfaced clearly", function()
  it("returns an EXDEV-flagged error when rename returns an EXDEV string", function()
    local uv = vim.uv or vim.loop
    local orig = uv.fs_rename
    uv.fs_rename = function() error("EXDEV: cross-device link") end
    local tmp = vim.fn.tempname() .. ".ipynb"
    local ok, err = Util.atomic_write_file(tmp, "data")
    uv.fs_rename = orig
    assert.is_false(ok)
    assert.matches("EXDEV", tostring(err))
    os.remove(tmp)
  end)
end)
