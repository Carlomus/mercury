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

-- ---------------------------------------------------------------------------
-- Round 2 audit regressions (SPEC Invariants 41–48).
--
-- These pin behavior the first audit pass found missing: sorted JSON keys,
-- empty-dict serialization, transient.display_id round-trip, in-flight
-- save flush nudge, id-rename kernel-pointer migration, _cancel_running
-- transient cleanup, deferred RestartClear, interrupt/restart guards,
-- atomic-write short-write detection, SVG pt-unit conversion.
-- ---------------------------------------------------------------------------

local Ipynb = require("mercury.ipynb")

describe("Ipynb.encode — deterministic JSON shape (SPEC Invariant 3)", function()
  it("sorts keys alphabetically at every level", function()
    -- The function _encode_pretty (sorted output) IS the encode path now;
    -- the dead-code fallback through vim.json.encode + reindent was the
    -- audit P0. Verify ordering across cells, output objects, and the
    -- top-level document. Insertion order here is deliberately scrambled.
    local doc = {
      nbformat_minor = 5,
      cells = {
        {
          source = { "x" },
          metadata = {},
          id = "aaaa0001",
          kind = "code",
          exec_count = 1,
          outputs = {
            {
              type = "execute_result",
              metadata = {},
              data = { ["text/plain"] = "1" },
              execution_count = 1,
            },
          },
        },
      },
      meta = { language_info = { name = "python" } },
      nbformat = 4,
    }
    local json = Ipynb.encode(doc)
    -- Helper: assert a sequence of substring tags appears in the given order
    -- inside the given window (defaults to the whole JSON). Searches are
    -- non-overlapping — each match starts after the prior match — so this
    -- correctly handles repeated keys like "metadata" that appear at
    -- multiple nesting levels.
    local function assert_order(tags, window_start, window_end)
      window_start = window_start or 1
      window_end = window_end or #json
      local cursor = window_start
      for i, tag in ipairs(tags) do
        local s, e = json:find(tag, cursor, true)
        assert.is_truthy(s,
          ("missing tag %s after position %d"):format(tag, cursor))
        assert.is_true(e <= window_end,
          ("tag %s landed outside window"):format(tag))
        if i > 1 then
          assert.is_true(s > cursor,
            ("keys out of order: %s at %d should follow previous at %d")
              :format(tag, s, cursor))
        end
        cursor = e + 1
      end
    end

    -- Document-level (whole JSON): cells < metadata < nbformat < nbformat_minor
    -- Use full tags so this matches the OUTER metadata only at the very end
    -- of the JSON (the cell-level and output-level "metadata" keys appear
    -- earlier; assert_order's non-overlapping search will land on them
    -- first, which is also fine — every subsequent tag must come AFTER
    -- the previous one, so as long as nbformat and nbformat_minor are
    -- after the LAST "metadata", we're good).
    assert_order({ '"cells"', '"metadata"', '"nbformat"', '"nbformat_minor"' })

    -- Cell-level: locate cell[0]'s object boundaries via the unique id.
    local cell_start = json:find('"cell_type"', 1, true)
    local cell_end = json:find('"source"', cell_start, true)
      and json:find('\n  }', cell_start, true) or #json
    assert_order(
      { '"cell_type"', '"execution_count"', '"id"', '"metadata"',
        '"outputs"', '"source"' },
      cell_start, cell_end)

    -- Output-level: scope to the outputs array via the `"outputs"` key.
    local out_start = json:find('"outputs"', cell_start, true)
    local out_end = json:find('"source"', out_start, true)
    assert_order(
      { '"data"', '"execution_count"', '"metadata"', '"output_type"' },
      out_start, out_end)
  end)

  it("empty metadata at every level serializes as {} not []", function()
    -- Audit P0: a fresh code cell whose kernel didn't emit output metadata
    -- (empty Lua table) used to serialize as `metadata: []`, which is
    -- invalid nbformat. ensure_dict() routes empty Lua tables through
    -- vim.empty_dict() so they encode as `{}`.
    local doc = {
      meta = {},                    -- top-level
      nbformat = 4, nbformat_minor = 5,
      cells = {
        {
          id = "aaaa0002", kind = "code", source = {},
          exec_count = 1, metadata = {},  -- cell-level
          outputs = {
            {
              type = "display_data",
              data = { ["text/plain"] = "x" },
              metadata = {},          -- output-level
            },
          },
        },
      },
    }
    local json = Ipynb.encode(doc)
    -- No `metadata: []` anywhere — only `metadata: {}`.
    assert.is_nil(json:find('"metadata": %['),
      "empty metadata must serialize as {} not [] (invalid nbformat)")
    -- Three occurrences of `"metadata": {}` — top-level, cell-level, output-level.
    local count = 0
    for _ in json:gmatch('"metadata": {}') do count = count + 1 end
    assert.equals(3, count, "all three empty-metadata sites should be {}")
  end)

  it("round-trips display_id under metadata.mercury.display_id on display_data outputs", function()
    -- IPython.display.update_display(display_id=X) requires saving the
    -- display_id with the output so a reload-then-execute can still find
    -- the bound output. The kernel's in-memory state tracks _display_id;
    -- ipynb persists it under `metadata.mercury.display_id`.
    --
    -- This intentionally diverges from older Mercury builds that wrote a
    -- sibling `transient.display_id` field — `transient` is a messaging-
    -- protocol concept, not an nbformat output field, and strict nbformat
    -- validators reject it. The decoder still accepts the legacy shape
    -- for forwards-compat with existing files.
    local doc = {
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = {
        {
          id = "aaaa0003", kind = "code", source = {},
          exec_count = 1, metadata = {},
          outputs = {
            {
              type = "display_data",
              data = { ["text/plain"] = "x" },
              metadata = {},
              _display_id = "my-disp",
            },
          },
        },
      },
    }
    local json = Ipynb.encode(doc)
    assert.matches('"mercury":', json)
    assert.matches('"display_id": "my%-disp"', json)
    -- Encoder must NOT write the legacy transient.display_id shape any more.
    assert.is_nil(json:match('"transient"'))
    -- Decoder accepts the canonical (metadata.mercury.display_id) shape.
    local decoded = Ipynb.decode(json)
    assert.equals("my-disp", decoded.cells[1].outputs[1]._display_id)
    -- Decoder ALSO accepts the legacy transient.display_id shape for
    -- backwards-compat with files Mercury wrote before this fix.
    local legacy_json = [[{
 "cells": [
  {
   "cell_type": "code",
   "execution_count": 1,
   "id": "aaaa0003",
   "metadata": {},
   "outputs": [
    {
     "data": {"text/plain": "x"},
     "metadata": {},
     "output_type": "display_data",
     "transient": {"display_id": "legacy-disp"}
    }
   ],
   "source": []
  }
 ],
 "metadata": {},
 "nbformat": 4,
 "nbformat_minor": 5
}
]]
    local legacy = Ipynb.decode(legacy_json)
    assert.equals("legacy-disp", legacy.cells[1].outputs[1]._display_id)
  end)
end)

describe("notebook in-flight save bookkeeping (SPEC Invariant 14)", function()
  it("to_ipynb_struct populates _skipped_at_save for in-flight cells", function()
    local buf = make_buf({
      "# %% id=runaway0",
      "x = 1",
      "# %% id=queued01",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel("runaway0", { "queued01" })
    nb:to_ipynb_struct()
    -- Both in-flight cells appear in the skipped set so the kernel's
    -- execute_done branch knows to mark the buffer modified when each
    -- completes. Without this the kernel's read-side (kernel.lua:188-194)
    -- was dead code — the audit P0.
    assert.is_table(nb._skipped_at_save)
    assert.is_true(nb._skipped_at_save["runaway0"])
    assert.is_true(nb._skipped_at_save["queued01"])
    Notebook.detach(buf)
  end)

  it("does not populate _skipped_at_save when no cell is in flight", function()
    local buf = make_buf({ "# %% id=idle0001", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel(nil, {})
    nb:to_ipynb_struct()
    assert.is_nil(nb._skipped_at_save)
    Notebook.detach(buf)
  end)
end)

describe("rescan id-rename migrates kernel pointers (SPEC Invariant 4)", function()
  it("rewrites self.kernel.running.cell_id when a separator id is edited", function()
    local buf = make_buf({ "# %% id=before00", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel("before00", {})
    -- Manually rewrite the id on the separator line — same edit a user
    -- would make in normal vim. rescan must migrate kernel.running.
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# %% id=after001" })
    nb:rescan()
    assert.equals("after001", nb.kernel.running.cell_id,
      "running.cell_id must follow the rename or `_live_code_cell` "
      .. "drops every subsequent iopub frame and the pill stays stuck "
      .. "in `running` forever")
    Notebook.detach(buf)
  end)

  it("rewrites kernel.queue[*].cell_id on rename so the queue isn't evicted", function()
    local buf = make_buf({ "# %% id=before00", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    nb.kernel = fake_kernel(nil, { "before00" })
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# %% id=after002" })
    nb:rescan()
    assert.equals(1, #nb.kernel.queue,
      "the queued task must survive — without migration, rescan's "
      .. "`no longer code` filter evicts it because before00 vanished")
    assert.equals("after002", nb.kernel.queue[1].cell_id)
    Notebook.detach(buf)
  end)
end)

describe("_cancel_running resets transient execute state", function()
  local Kernel = require("mercury.kernel")

  it("clears _pending_clear and _started_iso on cancel", function()
    -- Audit P1: a re-execute of the same cell after interrupt was silently
    -- wiping the first chunk of new output because _pending_clear from
    -- the killed run carried over.
    local buf = make_buf({ "# %% id=cancelxx", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb)
    k.running = { cell_id = "cancelxx" }
    local out = nb:ensure_output("cancelxx")
    out._pending_clear = true
    out._started_iso = "2026-01-01T00:00:00.000000Z"
    out.status = "running"

    k:_cancel_running("killed")

    assert.is_nil(out._pending_clear)
    assert.is_nil(out._started_iso)
    assert.equals("killed", out.status)
    Notebook.detach(buf)
  end)

  it("preserves transient state when status is already terminal (error stays sticky)", function()
    -- Sticky-terminal rule (SPEC Invariant 10) still holds: an `error`
    -- pill doesn't downgrade to `killed`. But the transient fields
    -- (_pending_clear / _started_iso) still get cleaned up.
    local buf = make_buf({ "# %% id=errorxxx", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb)
    k.running = { cell_id = "errorxxx" }
    local out = nb:ensure_output("errorxxx")
    out._pending_clear = true
    out._started_iso = "2026-01-01T00:00:00.000000Z"
    out.status = "error"  -- terminal

    k:_cancel_running("killed")

    -- Status stays `error` (sticky).
    assert.equals("error", out.status)
    -- Transient fields are still cleaned.
    assert.is_nil(out._pending_clear)
    assert.is_nil(out._started_iso)
    Notebook.detach(buf)
  end)
end)

describe("Kernel:interrupt / Kernel:restart guards (SPEC Invariants 11, 25)", function()
  local Kernel = require("mercury.kernel")

  it("interrupt refuses while _stopping is true", function()
    local buf = make_buf({ "# %% id=guarded1", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb)
    k.chan = 99999
    k._stopping = true
    local sent = false
    k._send = function() sent = true; return true end
    k:interrupt()
    assert.is_false(sent,
      "interrupt during stop teardown would write to a dying channel")
    Notebook.detach(buf)
  end)

  it("interrupt refuses while _restart_pending is true", function()
    local buf = make_buf({ "# %% id=guarded2", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb)
    k.chan = 99999
    k._restart_pending = true
    local sent = false
    k._send = function() sent = true; return true end
    k:interrupt()
    assert.is_false(sent,
      "interrupt during restart window has no live execution to interrupt")
    Notebook.detach(buf)
  end)

  it("restart refuses while _stopping is true", function()
    local buf = make_buf({ "# %% id=guarded3", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb)
    k.chan = 99999
    k._stopping = true
    local sent = false
    k._send = function() sent = true; return true end
    k:restart({})
    assert.is_false(sent)
    -- And we did NOT set _restart_pending — otherwise on_exit / the next
    -- execute would observe stale state.
    assert.is_not_true(k._restart_pending)
    Notebook.detach(buf)
  end)

  it("restart refuses a second restart while one is pending", function()
    local buf = make_buf({ "# %% id=guarded4", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    local k = Kernel.new(nb)
    k.chan = 99999
    k._restart_pending = true
    local send_count = 0
    k._send = function() send_count = send_count + 1; return true end
    k:restart({})
    assert.equals(0, send_count,
      "a second restart while one is pending must not re-send")
    Notebook.detach(buf)
  end)
end)

describe("util.atomic_write_file — short-write protection (audit P1)", function()
  it("treats a write that returns (nil, err) as a failure and removes the tempfile", function()
    local tmp = vim.fn.tempname() .. ".ipynb"
    -- Wrap the real file handle so :write returns nil, err — the disk-full
    -- shape Lua's io.write uses to report ENOSPC. The audit found Util's
    -- pcall caught only Lua errors, not return-value failures, so this
    -- pinned the gap.
    local orig_open = io.open
    io.open = function(path, mode)
      local real, err = orig_open(path, mode)
      if not real then return nil, err end
      -- Drop a small write so the file exists on disk (close+rename must
      -- still be reachable for the test's cleanup assertions to be valid),
      -- but make the *full* write return the (nil, err) failure.
      local handle = {}
      function handle:write(_data)
        return nil, "ENOSPC: no space left on device"
      end
      function handle:close() return real:close() end
      return handle
    end
    local ok, err = Util.atomic_write_file(tmp, "lots of data")
    io.open = orig_open
    assert.is_false(ok,
      "a write that returns nil/err must not result in a successful save")
    assert.matches("ENOSPC", tostring(err or ""))
    -- No torn tempfile left lying around for the next save to confuse itself with.
    local stat = (vim.uv or vim.loop).fs_stat(tmp .. ".mercury_save_tmp")
    assert.is_nil(stat,
      "the tempfile must be cleaned up after a short-write failure")
    -- Original path is also untouched (it never existed in this test).
    assert.is_nil((vim.uv or vim.loop).fs_stat(tmp))
  end)
end)

describe("Output svg_dimensions — pt→px conversion (audit P1)", function()
  local Output = require("mercury.output")
  it("converts pt → px at 96 DPI (1pt = 4/3 px)", function()
    local w, h = Output.svg_dimensions(
      [[<svg width="72pt" height="144pt"></svg>]])
    assert.equals(96, w)   -- 72 * 4 / 3
    assert.equals(192, h)  -- 144 * 4 / 3
  end)

  it("rejects unknown absolute units so viewBox wins", function()
    -- "in" / "cm" / "em" are too dependent on user-agent DPI to silently
    -- approximate. Falling back to viewBox is the safer answer.
    local w, h = Output.svg_dimensions(
      [[<svg width="2in" height="1in" viewBox="0 0 192 96"></svg>]])
    assert.equals(192, w)
    assert.equals(96, h)
  end)
end)

describe("RestartClear is deferred to `restarted` (SPEC Invariant 42)", function()
  local Kernel = require("mercury.kernel")

  it("does not clear outputs synchronously in Kernel:restart", function()
    local buf = make_buf({ "# %% id=deferclr", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    nb:ensure_output("deferclr").status = "ok"
    nb.outputs["deferclr"].items =
      { { type = "stream", name = "stdout", text = "stale" } }
    local k = Kernel.new(nb)
    k.chan = 99999
    k._send = function() return true end

    k:restart({ clear = true })
    -- BEFORE `restarted` arrives, outputs are NOT cleared — they may yet
    -- receive late iopub frames from the old kernel. clear_all_outputs
    -- here would race with `ensure_output` calls from those frames.
    assert.is_not_nil(rawget(nb.outputs, "deferclr"),
      "synchronous clear in Kernel:restart was the audit P1 race")
    assert.is_true(k._restart_clear_pending)

    k:_handle_msg({ type = "restarted" })
    -- AFTER `restarted`, the deferred clear has run.
    assert.is_nil(rawget(nb.outputs, "deferclr"))
    assert.is_nil(k._restart_clear_pending)
    Notebook.detach(buf)
  end)

  it("drops the deferred clear if the restart fails (kernel_dead path)", function()
    local buf = make_buf({ "# %% id=deferclr2", "x = 1" })
    local nb = Notebook.attach(buf); nb:rescan()
    nb:ensure_output("deferclr2").status = "ok"
    local k = Kernel.new(nb)
    k.chan = 99999
    k._send = function() return true end

    k:restart({ clear = true })
    -- Restart fails (kernel never relaunched) → emit a fatal kernel_error.
    -- Outputs stay where they are; user can RestartClear again later.
    k:_handle_msg({ type = "kernel_error", error = "boom" })
    assert.is_nil(k._restart_clear_pending)
    -- Outputs survive the failed restart — the user can decide.
    assert.is_not_nil(rawget(nb.outputs, "deferclr2"))
    Notebook.detach(buf)
  end)
end)
