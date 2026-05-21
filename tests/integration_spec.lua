-- Integration tests: open .ipynb -> edit -> save -> reopen.

local Util = require("mercury.util")
local Ipynb = require("mercury.ipynb")
local Notebook = require("mercury.notebook")

local function fixture_path(name)
  local script = debug.getinfo(1, "S").source:sub(2)
  local dir = vim.fn.fnamemodify(script, ":p:h")
  return dir .. "/fixtures/" .. name
end

describe("integration: read/edit/write", function()
  before_each(function()
    require("mercury").setup()
  end)

  it("BufReadCmd loads a notebook and renders cell separators", function()
    local tmp = vim.fn.tempname() .. ".ipynb"
    local data = Util.read_file(fixture_path("simple.ipynb"))
    Util.write_file(tmp, data)
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    assert.is_not_nil(nb)
    assert.equals(3, #nb.cells)
    assert.equals("abc12345", nb.cells[1].id)
    assert.equals("def67890", nb.cells[2].id)
    assert.equals("markdown", nb.cells[2].kind)

    -- Outputs should have been seeded from the ipynb.
    local out1 = nb.outputs["abc12345"]
    assert.is_not_nil(out1)
    assert.equals("stream", out1.items[1].type)
    assert.equals("hello\n", out1.items[1].text)

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("BufWriteCmd round-trips outputs preserved across reload", function()
    local tmp = vim.fn.tempname() .. ".ipynb"
    local data = Util.read_file(fixture_path("simple.ipynb"))
    Util.write_file(tmp, data)
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    -- Mutate the first cell's output.
    local out = nb:ensure_output("abc12345")
    out.items = {
      { type = "stream", name = "stdout", text = "MUTATED\n" },
    }
    out.exec_count = 99
    out.status = "ok"

    -- Save.
    vim.cmd("write")

    -- Reopen.
    vim.cmd("bwipeout!")
    vim.cmd("edit " .. tmp)
    local buf2 = vim.api.nvim_get_current_buf()
    local nb2 = Notebook.get(buf2)
    local out2 = nb2.outputs["abc12345"]
    assert.is_not_nil(out2)
    assert.equals("stream", out2.items[1].type)
    assert.equals("MUTATED\n", out2.items[1].text)
    assert.equals(99, out2.exec_count)

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("inserts a separator when a buffer has none", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x = 1", "print(x)" })
    require("mercury")._attach_buffer(buf, {})
    local nb = Notebook.get(buf)
    assert.equals(1, #nb.cells)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.matches("^# %%%% id=", lines[1])
    Notebook.detach(buf)
  end)

  it("merging a cell drops the merged-cell output", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=keepit01", "x = 1",
      "# %% id=goneit02", "y = 2",
    })
    require("mercury")._attach_buffer(buf, {})
    local nb = Notebook.get(buf)
    nb:ensure_output("keepit01").items = { { type = "stream", text = "K" } }
    nb:ensure_output("goneit02").items = { { type = "stream", text = "G" } }
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    nb:merge_below()
    assert.equals(1, #nb.cells)
    assert.is_nil(nb.outputs["goneit02"])
    assert.is_not_nil(nb.outputs["keepit01"])
    Notebook.detach(buf)
  end)

  it("preserves markdown cell.attachments across the full save/reload cycle", function()
    -- Unit test in ipynb_spec covers the codec; this test covers the full
    -- pipeline: disk -> BufReadCmd -> Notebook state -> :w -> disk again.
    -- A bug in seeding cell_attachments, in to_ipynb_struct, or in the
    -- encoder would all show up here.
    local tmp = vim.fn.tempname() .. ".ipynb"
    -- Tiny 1x1 transparent PNG, base64'd. Real attachment bytes.
    local b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
    local doc = {
      cells = {
        { cell_type = "markdown", id = "attchcel", metadata = {},
          source = { "![pic](attachment:pic.png)" },
          attachments = { ["pic.png"] = { ["image/png"] = b64 } } },
      },
      metadata = {},
      nbformat = 4, nbformat_minor = 5,
    }
    Util.write_file(tmp, vim.json.encode(doc))

    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    -- Attachments were seeded from disk into the per-id side table.
    assert.is_not_nil(nb.cell_attachments["attchcel"])
    assert.equals(b64, nb.cell_attachments["attchcel"]["pic.png"]["image/png"])

    -- Mutate the cell body (force the buffer to be modified) and save.
    vim.api.nvim_buf_set_lines(buf, 1, 2, false,
      { "![pic](attachment:pic.png)", "added a line" })
    -- Wait for debounced rescan to settle.
    nb:rescan()
    vim.cmd("write")

    -- Reload from disk. The attachment bytes must still be there.
    vim.cmd("bwipeout!")
    vim.cmd("edit " .. tmp)
    local nb2 = Notebook.get(vim.api.nvim_get_current_buf())
    assert.is_not_nil(nb2.cell_attachments["attchcel"])
    assert.equals(b64, nb2.cell_attachments["attchcel"]["pic.png"]["image/png"])

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("preserves execution_count on round-trip when outputs were cleared (Jupyter Lab compatibility)", function()
    -- Jupyter Lab's "Clear All Outputs" leaves execution_count intact:
    -- {"execution_count": 5, "outputs": []}. A previous bug only seeded
    -- nb.outputs[id] when outputs were non-empty, so the encoder saw
    -- nb.outputs[id]==nil and wrote `"execution_count": null` on save — pure
    -- data loss on a no-op edit cycle. SPEC: "Save round-trips back to .ipynb
    -- JSON, preserving outputs".
    local tmp = vim.fn.tempname() .. ".ipynb"
    local doc = {
      cells = {
        { cell_type = "code", id = "execcnt1", metadata = {},
          source = { "x = 1" }, execution_count = 5, outputs = {} },
      },
      metadata = {},
      nbformat = 4, nbformat_minor = 5,
    }
    Util.write_file(tmp, vim.json.encode(doc))

    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    -- The output record exists with exec_count seeded even though items is empty.
    local out = nb.outputs["execcnt1"]
    assert.is_not_nil(out)
    assert.equals(5, out.exec_count)
    assert.equals(0, #out.items)

    -- Mutate the body to make the buffer modified, then save.
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "x = 1", "" })
    nb:rescan()
    vim.cmd("write")

    -- Re-read the file directly and check the JSON.
    local raw = Util.read_file(tmp)
    -- The JSON must still carry "execution_count": 5, not null.
    assert.matches('"execution_count":%s*5', raw)
    -- And NOT have flipped to null.
    assert.is_nil(raw:match('"execution_count":%s*null'))

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("save writes in-flight cells as 'not yet executed' (non-blocking)", function()
    -- The old design drained the kernel for up to 30s before saving. The
    -- new design: a cell that's running / queued when :w fires is written
    -- to JSON as if it hadn't executed (empty outputs, null exec_count).
    -- The in-memory state is preserved so a subsequent save flushes the
    -- output once the cell finishes.
    local tmp = vim.fn.tempname() .. ".ipynb"
    local data = Util.read_file(fixture_path("simple.ipynb"))
    Util.write_file(tmp, data)
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)

    -- Stash the original output for the first cell, then pretend it is
    -- currently running on the kernel. The save must NOT serialize its
    -- in-memory items (those are "live" output, not committed state).
    local orig = nb.outputs["abc12345"]
    assert.is_not_nil(orig)
    assert.equals("stream", orig.items[1].type)
    -- Mark the cell as the one currently executing.
    nb.kernel.running = { cell_id = "abc12345", started_at = 0 }
    -- And queue the third cell behind it.
    nb.kernel.queue = { { cell_id = "fab10111", code = "x" } }

    -- Save (no drain, returns immediately).
    vim.cmd("write")

    -- On reload, the running + queued cells should appear unexecuted.
    vim.cmd("bwipeout!")
    vim.cmd("edit " .. tmp)
    local nb2 = Notebook.get(vim.api.nvim_get_current_buf())
    -- abc12345 was running -> saved without output.
    assert.is_nil(nb2.outputs["abc12345"])
    -- fab10111 was queued -> saved without output.
    assert.is_nil(nb2.outputs["fab10111"])
    -- The middle markdown cell is untouched (had no output anyway).
    -- The "in-flight" tagging only affects in-flight cells; the saved
    -- file is structurally valid and reloads cleanly.
    assert.equals(3, #nb2.cells)

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("streaming output is coalesced to one render per event-loop tick (Invariant 7)", function()
    -- The kernel emits one `output` iopub message per stream chunk. Without
    -- coalescing, a tqdm loop dumping thousands of lines would trigger
    -- thousands of renders per second. We assert end-to-end (not just
    -- coalesce in isolation) that on_change being called 50 times in one
    -- tick produces exactly 1 render call.
    local tmp = vim.fn.tempname() .. ".ipynb"
    Util.write_file(tmp, Util.read_file(fixture_path("simple.ipynb")))
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    -- Spy on the renderer's render method to count calls.
    local render_calls = 0
    nb._renderer.render = function() render_calls = render_calls + 1 end
    -- Fire on_change 50 times rapidly — the kernel does this from iopub
    -- frames in normal execution.
    for _ = 1, 50 do nb.kernel.on_change() end
    -- Before the scheduler runs, no render has happened.
    assert.equals(0, render_calls)
    -- After the scheduler drains, exactly one render runs.
    vim.wait(50, function() return render_calls > 0 end)
    assert.equals(1, render_calls,
      "50 on_change calls in one tick must coalesce to exactly 1 render")

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("execute_done flushes buffer.modified for previously-skipped in-flight cells", function()
    -- Save with a running cell: the saved JSON has no output for it. After
    -- the cell finishes, the user expects :w to flush the actual output.
    -- vim tracks buffer.modified by TEXT changes, so an output-only change
    -- wouldn't naturally re-arm save. The fix: on execute_done for a
    -- previously-skipped cell, set vim.bo[buf].modified = true so :w
    -- doesn't silently skip the write. SPEC invariant 14.
    local tmp = vim.fn.tempname() .. ".ipynb"
    Util.write_file(tmp, Util.read_file(fixture_path("simple.ipynb")))
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    -- Pretend the first cell was in flight when we saved.
    nb._skipped_at_save = { abc12345 = true }
    -- Saved buffer is unmodified (just loaded).
    vim.bo[buf].modified = false

    -- Simulate execute_done arriving for that cell.
    nb.kernel.running = { cell_id = "abc12345", started_at = 0 }
    nb:ensure_output("abc12345").items = { { type = "stream", text = "done\n" } }
    nb.kernel:_handle_msg({ type = "execute_done", cell_id = "abc12345",
      exec_count = 7, ms = 12 })

    -- The buffer is now marked modified so the next :w will actually write.
    assert.is_true(vim.bo[buf].modified)
    -- And the skipped-tracking entry is cleaned up.
    assert.is_nil(nb._skipped_at_save)

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("save_ipynb goes through atomic_write_file (atomic rename, no torn write)", function()
    -- SPEC invariant 22. A regression that swapped atomic_write_file for
    -- write_file would still pass unit tests of atomic_write_file in isolation.
    -- Verify the integration by stubbing the path-rename step and checking
    -- the original file is untouched on failure.
    local tmp = vim.fn.tempname() .. ".ipynb"
    Util.write_file(tmp, Util.read_file(fixture_path("simple.ipynb")))
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    -- Modify a cell so the buffer is dirty.
    nb:ensure_output("abc12345").items = {
      { type = "stream", name = "stdout", text = "MUTATED for atomic test\n" },
    }
    vim.bo[buf].modified = true

    -- Stub fs_rename to fail. The tempfile should be cleaned up and the
    -- original file should still be the OLD content.
    local uv = vim.uv or vim.loop
    local orig_rename = uv.fs_rename
    uv.fs_rename = function() error("simulated rename failure") end
    local original_bytes = Util.read_file(tmp)
    pcall(function() vim.cmd("write") end)
    uv.fs_rename = orig_rename
    -- Original file content is unchanged.
    assert.equals(original_bytes, Util.read_file(tmp))
    -- No leftover tempfile.
    assert.is_nil(vim.loop.fs_stat(tmp .. ".mercury_save_tmp"))

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("debounced rescan is triggered by TextChanged", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".ipynb")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=aaaa1111", "x = 1",
    })
    require("mercury")._attach_buffer(buf, {})
    local nb = Notebook.get(buf)
    assert.equals(1, #nb.cells)

    vim.api.nvim_buf_set_lines(buf, 2, 2, false, {
      "# %% id=bbbb2222", "y = 2",
    })
    -- Force a synchronous rescan to bypass the debounce.
    nb:rescan()
    assert.equals(2, #nb.cells)
    Notebook.detach(buf)
  end)

  it("uses the notebook's kernelspec.name when opening", function()
    -- Build a tiny notebook on disk whose metadata.kernelspec.name is custom.
    local tmp = vim.fn.tempname() .. ".ipynb"
    local doc = {
      cells = {
        { cell_type = "code", id = "abc12345", metadata = {},
          execution_count = vim.NIL, source = { "x = 1" }, outputs = {} },
      },
      metadata = {
        kernelspec = { name = "fancy_env", display_name = "Fancy", language = "python" },
        language_info = { name = "python" },
      },
      nbformat = 4, nbformat_minor = 5,
    }
    Util.write_file(tmp, vim.json.encode(doc))

    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    assert.is_not_nil(nb)
    -- Both the kernel client's opts and the buffer-local var should reflect
    -- the notebook's kernelspec, not the global default.
    assert.equals("fancy_env", nb.kernel.kernel_opts.name)
    assert.equals("fancy_env", vim.b[buf].mercury_kernel_name)

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("prefers metadata.mercury_kernel.python over kernelspec.name on open", function()
    -- mercury_kernel is mercury's override for explicit python-path selection;
    -- when set, it must win against the standard kernelspec.name field even
    -- if both are present in the file.
    local tmp = vim.fn.tempname() .. ".ipynb"
    local doc = {
      cells = {
        { cell_type = "code", id = "abc12345", metadata = {},
          execution_count = vim.NIL, source = { "x = 1" }, outputs = {} },
      },
      metadata = {
        kernelspec = { name = "python3",
                       display_name = "Python 3", language = "python" },
        mercury_kernel = { python = "/abs/path/to/venv/bin/python" },
      },
      nbformat = 4, nbformat_minor = 5,
    }
    Util.write_file(tmp, vim.json.encode(doc))
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    assert.is_not_nil(nb)
    assert.equals("/abs/path/to/venv/bin/python", nb.kernel.kernel_opts.python)
    assert.is_nil(nb.kernel.kernel_opts.name)
    -- b:mercury_kernel_name must surface the ACTIVE selector (the python
    -- path here), not the fallback kernelspec.name. SPEC: "whichever of
    -- name/python/spec_path is active". Without this, lualine would show
    -- "python3" on a notebook the user pointed at a custom venv.
    assert.equals("/abs/path/to/venv/bin/python",
      vim.b[buf].mercury_kernel_name)
    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it(":e! does not stack per-buffer autocmds across reloads", function()
    -- Pre-fix: per-buffer autocmds were created with `buffer = buf` but no
    -- group, so a reattach (e.g. :e!) added a fresh copy alongside the old
    -- ones. After N reloads, every TextChanged fired N+1 rescans, each on a
    -- different (mostly detached) Notebook closure. Post-fix: a per-buffer
    -- augroup with clear=true wipes the previous attach's autocmds first.
    local tmp = vim.fn.tempname() .. ".ipynb"
    local data = Util.read_file(fixture_path("simple.ipynb"))
    Util.write_file(tmp, data)
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()

    -- Make the kernel stop a no-op so the reloads don't try to tear down a
    -- real bridge — we only care about autocmd lifecycle here.
    local nb = Notebook.get(buf)
    nb.kernel.stop = function(self)
      self.running = nil; self.queue = {}
      self.job_id = nil; self.chan = nil
    end

    -- Filter to Mercury's per-buffer augroup. Counting ALL buffer autocmds
    -- catches nvim's one-shot BufUnload (registered on first edit of the
    -- buffer, fires + self-removes on the first reload) — which would make
    -- this test flaky depending on whether the buffer had ever been
    -- unloaded before. The contract under test is specifically about
    -- Mercury not stacking its own autocmds across reloads, so scope the
    -- count to MercuryBuf_<bufnr>.
    local mercury_group = "MercuryBuf_" .. buf
    local function count_buffer_autocmds()
      local n = 0
      for _, a in ipairs(vim.api.nvim_get_autocmds({ buffer = buf })) do
        if a.group_name == mercury_group then n = n + 1 end
      end
      return n
    end
    local initial = count_buffer_autocmds()
    assert.is_true(initial > 0)

    -- Reload a few times. The autocmd count must not grow.
    for _ = 1, 5 do
      -- Re-mock stop on each fresh notebook attached by :e!.
      vim.cmd("edit!")
      local nb2 = Notebook.get(vim.api.nvim_get_current_buf())
      nb2.kernel.stop = function(self)
        self.running = nil; self.queue = {}
        self.job_id = nil; self.chan = nil
      end
    end
    assert.equals(initial, count_buffer_autocmds())

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it(":e! reloads cleanly without leaking the previous kernel + renderer", function()
    -- Pre-fix: BufReadCmd refiring on the same buffer (e.g. :e!) would
    -- create a fresh Renderer + Kernel and overwrite the references on
    -- the existing Notebook instance, leaving the old kernel's bridge
    -- job running and the old renderer's image.nvim handles live.
    -- Post-fix: load_ipynb detaches the previous Notebook first.
    local tmp = vim.fn.tempname() .. ".ipynb"
    local data = Util.read_file(fixture_path("simple.ipynb"))
    Util.write_file(tmp, data)
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    local nb1 = Notebook.get(buf)
    assert.is_not_nil(nb1)

    -- Spy on the old kernel's stop() so we can prove it ran on reload.
    local stop_calls = 0
    local original_stop = nb1.kernel.stop
    nb1.kernel.stop = function(self, ...)
      stop_calls = stop_calls + 1
      -- Don't actually try to teardown a real bridge — there isn't one
      -- in this test, and we just want to assert the call happened.
      self.running = nil
      self.queue = {}
      self.job_id = nil
      self.chan = nil
    end
    -- Restore in case anything else clones from the metatable.
    local _ = original_stop

    vim.cmd("edit!")

    local nb2 = Notebook.get(buf)
    -- Fresh notebook instance after reload — the old one was detached and
    -- a new one was attached.
    assert.is_not_nil(nb2)
    assert.are_not.equal(nb1, nb2)
    -- And the old kernel's stop was invoked exactly once during teardown.
    assert.equals(1, stop_calls)

    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)

  it("fires User MercuryAttached once a notebook buffer is set up", function()
    -- Earlier tests that left buffers alive may still have MercuryAttached
    -- events scheduled; drain the scheduler before subscribing so we only
    -- count our own attach.
    vim.wait(50, function() return false end)

    local fired = 0
    local seen_buf
    local au = vim.api.nvim_create_autocmd("User", {
      pattern = "MercuryAttached",
      callback = function(args)
        fired = fired + 1
        seen_buf = args.data and args.data.buf
      end,
    })

    local tmp = vim.fn.tempname() .. ".ipynb"
    local data = Util.read_file(fixture_path("simple.ipynb"))
    Util.write_file(tmp, data)
    vim.cmd("edit " .. tmp)
    local buf = vim.api.nvim_get_current_buf()
    -- The autocmd is scheduled, so give it a tick to fire.
    vim.wait(50, function() return fired > 0 end)

    assert.equals(1, fired)
    assert.equals(buf, seen_buf)

    pcall(vim.api.nvim_del_autocmd, au)
    vim.cmd("bwipeout!")
    os.remove(tmp)
  end)
end)
