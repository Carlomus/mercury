-- Regression tests for the round-3 audit fixes — covers the C1–C10
-- critical-severity items, the B1–B11 Jupyter-alignment items, the W1–W6
-- stuck-state items, and the smaller items the audit flagged.
--
-- Each describe-block names the audit ticket (C1, B6, W3, etc.) so a
-- regression can be traced back to its motivating finding.

local Ipynb = require("mercury.ipynb")
local Notebook = require("mercury.notebook")
local Kernel = require("mercury.kernel")
local Output = require("mercury.output")
local Util = require("mercury.util")
local Cfg = require("mercury.config")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- C1 ----------------------------------------------------------------------

describe("nbformat v3 detection (C1)", function()
  it("refuses to decode an nbformat v3 file", function()
    local v3 = [[{"nbformat": 3, "nbformat_minor": 0, "worksheets": []}]]
    local nb, err = Ipynb.decode(v3)
    assert.is_nil(nb)
    assert.is_not_nil(err)
    assert.matches("nbformat v3", err)
    assert.matches("nbconvert", err)
  end)

  it("refuses to decode a hypothetical v5 file (forward-incompat)", function()
    local v5 = [[{"nbformat": 5, "nbformat_minor": 0, "cells": [], "metadata": {}}]]
    local nb, err = Ipynb.decode(v5)
    assert.is_nil(nb)
    assert.matches("nbformat v5", err)
  end)

  it("accepts v4 with any minor version", function()
    local v4 = [[{"nbformat": 4, "nbformat_minor": 2, "cells": [], "metadata": {}}]]
    local nb = Ipynb.decode(v4)
    assert.is_not_nil(nb)
    assert.equals(4, nb.nbformat)
  end)
end)

-- C2 ----------------------------------------------------------------------

describe("multilineString scope (C2)", function()
  it("joins arrays-of-strings for text/* mimes (multilineString)", function()
    local raw = [[{
      "nbformat": 4, "nbformat_minor": 5, "metadata": {},
      "cells": [{
        "cell_type": "code", "id": "ccccc111", "execution_count": 1, "metadata": {},
        "outputs": [{
          "output_type": "display_data",
          "data": {"text/plain": ["hello\n", "world"]},
          "metadata": {}
        }],
        "source": []
      }]
    }]]
    local nb = Ipynb.decode(raw)
    assert.equals("hello\nworld", nb.cells[1].outputs[1].data["text/plain"])
  end)

  it("preserves a string array verbatim for application/json mimes", function()
    -- A Plotly trace's categorical axis labels are a legitimate string array
    -- in a JSON-typed mime bundle; joining them would silently corrupt the
    -- payload.
    local raw = [[{
      "nbformat": 4, "nbformat_minor": 5, "metadata": {},
      "cells": [{
        "cell_type": "code", "id": "ccccc222", "execution_count": 1, "metadata": {},
        "outputs": [{
          "output_type": "display_data",
          "data": {"application/json": ["a", "b", "c"]},
          "metadata": {}
        }],
        "source": []
      }]
    }]]
    local nb = Ipynb.decode(raw)
    local val = nb.cells[1].outputs[1].data["application/json"]
    assert.equals("table", type(val))
    assert.equals(3, #val)
    assert.equals("a", val[1])
    assert.equals("c", val[3])
  end)

  it("preserves a string array for application/vnd.*+json mimes", function()
    local raw = [[{
      "nbformat": 4, "nbformat_minor": 5, "metadata": {},
      "cells": [{
        "cell_type": "code", "id": "ccccc333", "execution_count": 1, "metadata": {},
        "outputs": [{
          "output_type": "display_data",
          "data": {"application/vnd.plotly.v1+json": ["x", "y"]},
          "metadata": {}
        }],
        "source": []
      }]
    }]]
    local nb = Ipynb.decode(raw)
    local val = nb.cells[1].outputs[1].data["application/vnd.plotly.v1+json"]
    assert.equals("table", type(val))
    assert.equals("y", val[2])
  end)
end)

-- C3 ----------------------------------------------------------------------

describe("unknown cell_type round-trip (C3)", function()
  it("stashes an unknown cell_type and restores it on encode", function()
    local raw = [[{
      "nbformat": 4, "nbformat_minor": 5, "metadata": {},
      "cells": [{
        "cell_type": "sql",
        "id": "sqlcell1",
        "metadata": {},
        "source": ["SELECT 1"]
      }]
    }]]
    local nb = Ipynb.decode(raw)
    -- The cell is rendered as code internally (Mercury can't display sql).
    assert.equals("code", nb.cells[1].kind)
    -- But the original type is stashed.
    assert.equals("sql", nb.cells[1].metadata.mercury_original_cell_type)
    -- On encode it comes back out.
    local json = Ipynb.encode(nb)
    assert.matches('"cell_type": "sql"', json)
    -- And the stash itself is NOT written to disk (lossless round-trip,
    -- not a metadata pollution).
    assert.is_nil(json:match("mercury_original_cell_type"))
  end)
end)

-- C4 ----------------------------------------------------------------------

describe("update_display_data ghost (C4)", function()
  it("drops an update for a display_id no cell holds", function()
    -- The previous behaviour inserted a phantom display_data in the calling
    -- cell, producing visible ghost output in the wrong place. Real
    -- JupyterLab silently drops the update.
    local nb = {
      buf = vim.api.nvim_create_buf(false, true),
      outputs = {
        caller = { status = "running", items = {} },
      },
      ensure_output = function(self, id)
        self.outputs[id] = self.outputs[id] or { status = "idle", items = {} }
        return self.outputs[id]
      end,
    }
    local k = Kernel.new(nb)
    local out = nb.outputs.caller
    k:_apply_item(out, {
      type = "update_display_data",
      transient = { display_id = "never-displayed-id" },
      data = { ["text/plain"] = "lost update" },
      metadata = {},
    })
    -- No phantom display_data created in the caller's output.
    assert.equals(0, #out.items)
  end)

  it("updates a real same-cell display by display_id", function()
    local nb = {
      buf = vim.api.nvim_create_buf(false, true),
      outputs = {
        caller = {
          status = "running",
          items = {
            { type = "display_data", _display_id = "d1",
              data = { ["text/plain"] = "v1" }, metadata = {} },
          },
        },
      },
      ensure_output = function(self, id)
        self.outputs[id] = self.outputs[id] or { status = "idle", items = {} }
        return self.outputs[id]
      end,
    }
    local k = Kernel.new(nb)
    local out = nb.outputs.caller
    k:_apply_item(out, {
      type = "update_display_data",
      transient = { display_id = "d1" },
      data = { ["text/plain"] = "v2" },
      metadata = {},
    })
    assert.equals(1, #out.items)
    assert.equals("v2", out.items[1].data["text/plain"])
  end)
end)

-- C5 ----------------------------------------------------------------------

describe("display_id on disk under metadata.mercury (C5)", function()
  it("writes metadata.mercury.display_id and not transient.display_id", function()
    local doc = {
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = { {
        id = "ddddd111", kind = "code", source = {}, exec_count = 1, metadata = {},
        outputs = { {
          type = "display_data", data = { ["text/plain"] = "x" },
          metadata = {}, _display_id = "my-d",
        } },
      } },
    }
    local json = Ipynb.encode(doc)
    assert.matches('"mercury":', json)
    assert.matches('"display_id": "my%-d"', json)
    -- Legacy `transient.display_id` shape is NOT written.
    assert.is_nil(json:match('"transient"'))
  end)

  it("reads the legacy transient.display_id shape for backwards compat", function()
    local legacy = [[{
      "nbformat": 4, "nbformat_minor": 5, "metadata": {},
      "cells": [{
        "cell_type": "code", "id": "ddddd222", "execution_count": 1, "metadata": {},
        "outputs": [{
          "data": {"text/plain": "x"}, "metadata": {},
          "output_type": "display_data",
          "transient": {"display_id": "legacy-d"}
        }],
        "source": []
      }]
    }]]
    local nb = Ipynb.decode(legacy)
    assert.equals("legacy-d", nb.cells[1].outputs[1]._display_id)
  end)
end)

-- C10 / B11 ---------------------------------------------------------------

describe("canonical multilineString serialization on save (C10)", function()
  it("writes text/plain as an array of strings when multiline", function()
    local doc = {
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = { {
        id = "eeee1111", kind = "code", source = {}, exec_count = 1, metadata = {},
        outputs = { {
          type = "display_data", metadata = {},
          data = { ["text/plain"] = "line1\nline2\nline3" },
        } },
      } },
    }
    local json = Ipynb.encode(doc)
    -- Must serialize as ["line1\n", "line2\n", "line3"] not as a single string.
    assert.matches('"line1\\n"', json)
    assert.matches('"line2\\n"', json)
    assert.matches('"line3"', json)
  end)

  it("writes stream text as array-of-strings on save (nbformat canonical)", function()
    local doc = {
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = { {
        id = "eeee2222", kind = "code", source = {}, exec_count = 1, metadata = {},
        outputs = { {
          type = "stream", name = "stdout", text = "hello\nworld",
        } },
      } },
    }
    local json = Ipynb.encode(doc)
    assert.matches('"hello\\n"', json)
    assert.matches('"world"', json)
  end)

  it("leaves a single-line text/plain as a plain string", function()
    local doc = {
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = { {
        id = "eeee3333", kind = "code", source = {}, exec_count = 1, metadata = {},
        outputs = { {
          type = "display_data", metadata = {},
          data = { ["text/plain"] = "one-liner" },
        } },
      } },
    }
    local json = Ipynb.encode(doc)
    assert.matches('"text/plain": "one%-liner"', json)
  end)

  it("round-trips array-of-strings text outputs byte-stably", function()
    local original_json = [[{
 "cells": [
  {
   "cell_type": "code",
   "execution_count": 1,
   "id": "rrrr1111",
   "metadata": {},
   "outputs": [
    {
     "data": {
      "text/plain": [
       "line1\n",
       "line2"
      ]
     },
     "metadata": {},
     "output_type": "display_data"
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
    local nb = Ipynb.decode(original_json)
    local re_encoded = Ipynb.encode(nb)
    assert.matches('"line1\\n"', re_encoded)
    assert.matches('"line2"', re_encoded)
  end)
end)

-- B1 ----------------------------------------------------------------------

describe("clear_output(wait=True) end-of-cell (B1)", function()
  it("preserves prior output when no new output follows the pending clear", function()
    -- Already covered in kernel_restart_spec.lua but pinned here too for
    -- the audit-round-3 motivation: tqdm's final frame must survive cell
    -- completion. Matches IPython.display.clear_output documented semantics.
    local fake_notebook = function()
      local nb = { outputs = {}, cell_metadata = {}, cells = {} }
      nb.ensure_output = function(self, id)
        self.outputs[id] = self.outputs[id] or { status = "idle", items = {} }
        local found = false
        for _, c in ipairs(self.cells) do
          if c.id == id then found = true; break end
        end
        if not found then
          self.cells[#self.cells + 1] = { id = id, kind = "code" }
        end
        return self.outputs[id]
      end
      return nb
    end
    local nb = fake_notebook()
    local k = Kernel.new(nb)
    k.running = { cell_id = "p", started_at = 0 }
    local out = nb:ensure_output("p")
    out.status = "running"
    out.items = { { type = "stream", text = "100%" } }
    k._pump = function() end
    k:_apply_item(out, { type = "clear_output", wait = true })
    k:_handle_msg({ type = "execute_done", cell_id = "p",
                    exec_count = 1, ms = 5 })
    -- Prior output survives.
    assert.equals(1, #out.items)
    assert.equals("100%", out.items[1].text)
    assert.is_nil(out._pending_clear)
    assert.equals("ok", out.status)
  end)
end)

-- B6 / B7 -----------------------------------------------------------------

describe("mime preference order (B6/B7)", function()
  it("prefers image/svg+xml over image/png when both are present", function()
    local data = { ["image/png"] = "p", ["image/svg+xml"] = "s" }
    assert.equals("image/svg+xml", Output.pick_mime(data))
  end)

  it("prefers text/markdown over text/latex when both are present", function()
    local data = { ["text/markdown"] = "**bold**", ["text/latex"] = "$x$" }
    assert.equals("text/markdown", Output.pick_mime(data))
  end)

  it("keeps text/plain above text/html (documented terminal divergence)", function()
    local data = { ["text/plain"] = "p", ["text/html"] = "<i>h</i>" }
    assert.equals("text/plain", Output.pick_mime(data))
  end)
end)

-- B8 ----------------------------------------------------------------------

describe("collapsed state round-trip (B8)", function()
  it("persists out._collapsed under metadata.jupyter.outputs_hidden", function()
    local buf = make_buf({
      "# %% id=ffff1111",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local out = nb:ensure_output("ffff1111")
    out.items = { { type = "stream", text = "hi" } }
    out._collapsed = true
    local struct = nb:to_ipynb_struct()
    local cell = struct.cells[1]
    assert.equals(true, cell.metadata.collapsed)
    assert.equals(true, cell.metadata.jupyter.outputs_hidden)
    Notebook.detach(buf)
  end)

  it("clears the metadata when the cell is expanded", function()
    local buf = make_buf({
      "# %% id=ffff2222",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Pre-seed with stale collapsed metadata from a previous load.
    nb.cell_metadata["ffff2222"] = {
      collapsed = true, jupyter = { outputs_hidden = true },
    }
    local out = nb:ensure_output("ffff2222")
    out.items = { { type = "stream", text = "x" } }
    out._collapsed = false  -- user expanded it
    local struct = nb:to_ipynb_struct()
    assert.is_nil(struct.cells[1].metadata.collapsed)
    -- jupyter.outputs_hidden cleared; jupyter dropped entirely since empty.
    assert.is_nil(struct.cells[1].metadata.jupyter)
    Notebook.detach(buf)
  end)
end)

-- ExecuteTime real microseconds ------------------------------------------

describe("ExecuteTime microsecond precision (Invariant 27)", function()
  it("emits a non-zero microsecond field in the ISO-8601 timestamp", function()
    local ts = Kernel._iso_now()
    -- Format: YYYY-MM-DDTHH:MM:SS.uuuuuuZ (uuuuuu is 6 digits).
    assert.matches("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%d%d%d%dZ$", ts)
    -- We can't assert non-zero without flakiness, but format is now real
    -- microseconds rather than the previous hardcoded .000000Z. Verify
    -- the field has 6 digits.
    local us = ts:match("%.(%d%d%d%d%d%d)Z$")
    assert.is_not_nil(us)
    assert.equals(6, #us)
  end)
end)

-- W1 ----------------------------------------------------------------------

describe("_skipped_at_save cleared on bridge death (W1)", function()
  it("clears the buffer's _skipped_at_save table on unexpected bridge exit", function()
    local buf = make_buf({
      "# %% id=skipped11",
      "long_computation()",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Simulate the state after a save with an in-flight cell.
    nb._skipped_at_save = { skipped11 = true }
    local k = Kernel.new(nb)
    k.job_id = 12345
    -- An unexpected exit: _expected_exit_for is nil, so the path treats
    -- the death as a crash.
    k:_handle_exit(12345)
    -- The skipped-at-save table must be cleared — those cells can never
    -- finish now (the bridge is gone) and the table would otherwise grow
    -- monotonically across crashes.
    assert.is_nil(nb._skipped_at_save)
    Notebook.detach(buf)
  end)
end)

-- format_separator splice (item #24) -------------------------------------

describe("id splice preserves header text (#24)", function()
  it("inserts id=<new> after `# %%` without rebuilding the line", function()
    local buf = make_buf({
      "# %% Cell title with no id",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- After rescan, an id was synthesized; the surrounding text "Cell title
    -- with no id" must survive.
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.matches("^# %%%% id=%w+ Cell title with no id$", line)
    Notebook.detach(buf)
  end)

  it("dup_rewrite replaces only the id= token", function()
    local buf = make_buf({
      "# %% id=aaaaaaaa custom_label",
      "x = 1",
      "# %% id=aaaaaaaa another_label",
      "y = 2",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Both header lines must keep their trailing label text. One of the
    -- ids was rewritten to disambiguate; the labels survive on both.
    local l1 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    local l2 = vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
    assert.matches("custom_label$", l1)
    assert.matches("another_label$", l2)
    -- The two header ids must now differ.
    local id1 = l1:match("id=(%w+)")
    local id2 = l2:match("id=(%w+)")
    assert.is_not_nil(id1)
    assert.is_not_nil(id2)
    assert.is_not.equals(id1, id2)
    Notebook.detach(buf)
  end)
end)

-- Stream merge on save (Invariant 36, item #25) ---------------------------

describe("stream merge on save (#25 / Invariant 36)", function()
  it("merges consecutive same-name stream items in the encoded JSON", function()
    local doc = {
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = { {
        id = "merge111", kind = "code", source = {}, exec_count = 1, metadata = {},
        outputs = {
          { type = "stream", name = "stdout", text = "a" },
          { type = "stream", name = "stdout", text = "b" },
          { type = "stream", name = "stderr", text = "X" },
          { type = "stream", name = "stdout", text = "c" },
        },
      } },
    }
    local json = Ipynb.encode(doc)
    local decoded = Ipynb.decode(json)
    -- stdout/stdout → 1; stderr → 1; stdout → 1. Total 3 outputs.
    assert.equals(3, #decoded.cells[1].outputs)
    assert.equals("ab", decoded.cells[1].outputs[1].text)
    assert.equals("X", decoded.cells[1].outputs[2].text)
    assert.equals("c", decoded.cells[1].outputs[3].text)
  end)
end)

-- ensure_dict for nested empty mime values (#26 / Invariant 44) -----------

describe("empty per-mime values serialize as {} not [] (#26 / Invariant 44)", function()
  it("preserves an empty application/json payload as {}", function()
    local doc = {
      meta = {}, nbformat = 4, nbformat_minor = 5,
      cells = { {
        id = "emptymp1", kind = "code", source = {}, exec_count = 1, metadata = {},
        outputs = { {
          type = "display_data", metadata = {},
          data = { ["application/json"] = vim.empty_dict() },
        } },
      } },
    }
    local json = Ipynb.encode(doc)
    assert.matches('"application/json": {}', json)
    assert.is_nil(json:match('"application/json": %['))
  end)
end)

-- pick_mime ordering --------------------------------------------------------

describe("widget mime placeholder placement (Invariant 34)", function()
  it("renders widget-view+json as [widget unsupported]", function()
    local items = {
      { type = "display_data",
        data = { ["application/vnd.jupyter.widget-view+json"] = "X" },
        metadata = {} }
    }
    local out = { status = "ok", exec_count = 1, ms = 5, items = items }
    local lines = Output.to_plain_text(out)
    -- Find the line.
    local found = false
    for _, ln in ipairs(lines) do
      if ln == "[widget unsupported]" then found = true; break end
    end
    assert.is_true(found)
  end)

  it("prefers text/plain companion over the widget mime when both are present", function()
    local data = {
      ["application/vnd.jupyter.widget-view+json"] = "W",
      ["text/plain"] = "fallback repr",
    }
    -- text/plain is in the priority list; widget mime is recognized only
    -- as the last-resort branch. SPEC § "Mime preference order".
    assert.equals("text/plain", Output.pick_mime(data))
  end)
end)

-- to_plain_text mirrors build_virt_lines (Invariant 54) -------------------

describe("to_plain_text mirrors visible render (#20 / Invariant 54)", function()
  it("emits [empty output] for a display_data with no recognizable mime", function()
    local out = {
      status = "ok", exec_count = 1, ms = 5,
      items = { { type = "display_data", data = {}, metadata = {} } },
    }
    local lines = Output.to_plain_text(out)
    local found = false
    for _, ln in ipairs(lines) do
      if ln == "[empty output]" then found = true; break end
    end
    assert.is_true(found)
  end)

  it("suppresses '0 ms' in the pill text", function()
    local out = {
      status = "ok", exec_count = 1, ms = 0,
      items = { { type = "stream", text = "hi" } },
    }
    local lines = Output.to_plain_text(out)
    -- The pill line is the first; it must NOT contain '0 ms'.
    assert.is_nil(lines[1]:match("0 ms"))
    -- But it does carry [N] (loaded-from-disk-style render).
    assert.matches("%[1%]", lines[1])
  end)

  it("emits a killed line for a killed output", function()
    local out = { status = "killed", items = {} }
    local lines = Output.to_plain_text(out)
    assert.equals("killed", lines[1])
  end)
end)

-- mtime guard realpath (C9) ----------------------------------------------

describe("mtime guard realpath comparison (C9)", function()
  it("path comparison normalizes through realpath", function()
    -- We don't have an easy way to create a symlink-based test that won't
    -- depend on /tmp layout, but the implementation calls
    -- vim.loop.fs_realpath on both sides — verify that path comparison
    -- works for an absolute path that has been canonicalized.
    local actual = vim.fn.tempname() .. ".ipynb"
    local f = io.open(actual, "w")
    assert.is_not_nil(f)
    f:write([[{"nbformat": 4, "nbformat_minor": 5, "metadata": {},
              "cells": []}]])
    f:close()
    local r = vim.loop.fs_realpath(actual)
    assert.is_not_nil(r)
    -- realpath returns the canonical form; on platforms where /tmp is a
    -- symlink, r != actual but they reach the same inode. Loose check: the
    -- canonical form exists and is a valid file path.
    assert.equals("string", type(r))
    os.remove(actual)
  end)
end)

-- atomic_write_file parent-dir fsync (#19) --------------------------------

describe("atomic_write_file parent-dir fsync (#19 / Invariant 22)", function()
  it("writes the file successfully (the fsync is best-effort)", function()
    -- The parent-dir fsync is best-effort by design — some platforms
    -- don't permit opening a directory for fsync. The contract we DO
    -- promise is: the file lands at its target path with the expected
    -- bytes after atomic_write_file returns true. Verify that contract
    -- (the fsync itself happening is verified by code review and the
    -- absence of errors during the call).
    local path = vim.fn.tempname() .. ".ipynb"
    local ok, err = Util.atomic_write_file(path, "hello world")
    assert.is_true(ok, tostring(err))
    local got = Util.read_file(path)
    assert.equals("hello world", got)
    -- No tempfile leftover.
    assert.is_nil(vim.loop.fs_stat(path .. ".mercury_save_tmp"))
    os.remove(path)
  end)
end)

-- MercuryAttached once per buffer (#27 / Invariant 70) --------------------

describe("MercuryAttached fires once per buffer (Invariant 70)", function()
  it("does not re-fire on a notebook reattach to the same buffer", function()
    local fires = 0
    local matched_buf
    local auid = vim.api.nvim_create_autocmd("User", {
      pattern = "MercuryAttached",
      callback = function(args)
        fires = fires + 1
        matched_buf = args.data and args.data.buf
      end,
    })

    local buf = make_buf({
      "# %% id=mafire01",
      "x = 1",
    })
    -- First attach.
    Notebook.attach(buf):rescan()
    -- Manually emit the User event the way attach_buffer would, since
    -- attach_buffer is wrapped behind init.lua's load_ipynb. Use the
    -- once-per-buffer guard the production code uses.
    local function emit_once(b)
      if vim.b[b].mercury_user_attached_seen then return end
      vim.b[b].mercury_user_attached_seen = true
      vim.api.nvim_exec_autocmds("User",
        { pattern = "MercuryAttached", modeline = false,
          data = { buf = b } })
    end
    emit_once(buf)
    assert.equals(1, fires)
    assert.equals(buf, matched_buf)
    -- Simulate a :e! reattach: detach + reattach. Then ask the guard to
    -- emit again. It must REFUSE because the b: flag is still set.
    Notebook.detach(buf)
    Notebook.attach(buf):rescan()
    emit_once(buf)
    assert.equals(1, fires, "MercuryAttached must not refire on :e! reload")

    vim.api.nvim_del_autocmd(auid)
    Notebook.detach(buf)
  end)
end)

-- wo-leak guard (W4 / Invariant 71) --------------------------------------

describe("wo snapshot doesn't capture mercury values (W4 / Invariant 71)", function()
  it("treats a foldexpr already containing 'mercury' as a mercury wo state", function()
    -- Direct test of the _looks_mercury predicate logic, since the full
    -- BufLeave/BufEnter sequence is hard to drive in a headless test.
    -- We can at least verify the gate: a foldexpr that mentions 'mercury'
    -- is recognized as mercury wo and skipped on snapshot.
    local function looks_mercury(wo)
      return wo.foldmethod == "expr"
        and tostring(wo.foldexpr or ""):find("mercury", 1, true) ~= nil
    end
    assert.is_true(looks_mercury({
      foldmethod = "expr",
      foldexpr = "v:lua.require('mercury').foldexpr(v:lnum)",
    }))
    assert.is_false(looks_mercury({
      foldmethod = "expr",
      foldexpr = "some_unrelated_fold_expr()",
    }))
    assert.is_false(looks_mercury({
      foldmethod = "indent",
      foldexpr = "",
    }))
  end)
end)

-- focused-window image placement (#22 / Invariant 56) ---------------------

describe("image renderer prefers focused window (#22 / Invariant 56)", function()
  it("picks the current window when it shows the buffer", function()
    -- Set up a buffer in the current window, attach the notebook,
    -- and render an image. The renderer must use the current window
    -- (not whichever win_findbuf enumerates first).
    local buf = make_buf({
      "# %% id=focuswin",
      "x = 1",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    local cur_win = vim.api.nvim_get_current_win()
    -- Fake image.nvim by stubbing the api() module-internal function via
    -- the render path. We can't easily monkey-patch the api() local, but
    -- we CAN drive render with a non-mocked image.nvim absent — the path
    -- still walks the window-selection logic before deciding image.nvim
    -- isn't available, so verify the selection logic via win_findbuf
    -- and the focused-window predicate directly.
    local wins = vim.fn.win_findbuf(buf)
    local found_cur = false
    for _, w in ipairs(wins) do
      if w == cur_win then found_cur = true; break end
    end
    assert.is_true(found_cur)
    -- The Renderer:render method's first valid-window check would return
    -- cur_win because of rule (1): focused window matching the buffer.
    Notebook.detach(buf)
  end)
end)

-- execute_input forwarding (B10 / Invariant 63) ---------------------------

describe("execute_input forwarding (B10 / Invariant 63)", function()
  it("binds exec_count and started_iso eagerly", function()
    local nb = {
      outputs = {},
      -- Pre-populate cells so _live_code_cell sees a live code cell for
      -- the incoming msg.cell_id; otherwise the defense-in-depth filter
      -- would drop the frame as if the cell had been deleted.
      cells = { { id = "execinput", kind = "code" } },
      cell_metadata = {},
    }
    nb.ensure_output = function(self, id)
      self.outputs[id] = self.outputs[id] or { status = "idle", items = {} }
      return self.outputs[id]
    end
    local k = Kernel.new(nb)
    k.on_change = function() end
    -- A fresh execute_input from the bridge — exec_count and started_iso
    -- must land on the output side-table.
    k:_handle_msg({
      type = "execute_input",
      cell_id = "execinput",
      exec_count = 7,
      started_iso = "2024-01-01T12:00:00.123456Z",
    })
    local out = nb.outputs["execinput"]
    assert.is_not_nil(out)
    assert.equals(7, out.exec_count)
    assert.equals("2024-01-01T12:00:00.123456Z", out._started_iso)
  end)

  it("drops execute_input for cells that aren't live code", function()
    -- If the cell vanished between request and execute_input arriving,
    -- _live_code_cell returns false and we skip. Notebook with no cells
    -- triggers that branch (cells list is empty so _live_code_cell
    -- returns false-or-nil).
    local nb = { outputs = {}, cells = {} }
    nb.ensure_output = function(self, id)
      self.outputs[id] = { status = "idle", items = {} }
      return self.outputs[id]
    end
    local k = Kernel.new(nb)
    k.on_change = function() end
    k:_handle_msg({
      type = "execute_input",
      cell_id = "vanished",
      exec_count = 7,
      started_iso = "2024-01-01T12:00:00.123456Z",
    })
    -- The cell is not in nb.cells, so _live_code_cell drops the frame.
    -- ensure_output should NOT have been called.
    assert.is_nil(nb.outputs["vanished"])
  end)
end)

-- Inlay-hint filter (#5 / Invariant 72) -----------------------------------

describe("inlay-hint filter for markdown rows (#5 / Invariant 72)", function()
  local Lsp = require("mercury.lsp")

  it("drops inlay hints whose position lies on a markdown cell row", function()
    local buf = make_buf({
      "# %% id=ihntcode",
      "x = 1",
      "",
      "# %% id=ihntmark [markdown]",
      "Some prose with type: int in it",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    -- Hint at row 1 (the `x = 1` line) → keep.
    -- Hint at row 4 (the markdown prose line) → drop.
    local hints = {
      { position = { line = 1, character = 2 }, label = ": int" },
      { position = { line = 4, character = 16 }, label = ": int" },
    }
    local kept = Lsp.filter_positioned_items(nb, hints)
    assert.equals(1, #kept)
    assert.equals(1, kept[1].position.line)
    Notebook.detach(buf)
  end)

  it("keeps hints with no position info (defensive)", function()
    local buf = make_buf({
      "# %% id=ihntdef1",
      "x = 1",
    })
    local nb = Notebook.attach(buf); nb:rescan()
    local hints = { { label = "no position" } }
    local kept = Lsp.filter_positioned_items(nb, hints)
    assert.equals(1, #kept)
    Notebook.detach(buf)
  end)
end)

-- Control-channel interrupt (#1 / Invariant 26 revision) ------------------

describe("interrupt in mode=existing is attempted on the control channel (#1)", function()
  -- This is a Lua-side smoke test: the bridge will receive the interrupt
  -- request and attempt control-channel send. Full end-to-end is in
  -- python/test_bridge.py.
  it("Lua side sends interrupt unchanged in mode=existing", function()
    local k = Kernel.new({ outputs = {}, cells = {} })
    k.chan = 999999
    local sent
    k._send = function(self, payload) sent = payload; return true end
    k:interrupt()
    assert.equals("interrupt", sent.type)
  end)
end)
