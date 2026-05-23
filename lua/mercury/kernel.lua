-- Lua-side client for the Python jupyter bridge.

local Cfg = require("mercury.config")
local Util = require("mercury.util")

local M = {}

local Kernel = {}
Kernel.__index = Kernel

-- ISO-8601 UTC timestamp with real microsecond precision. JupyterLab's
-- ExecuteTime extension writes microsecond-precise stamps, and a notebook
-- that round-trips Lab→Mercury→Lab should not lose that precision. Uses
-- vim.uv.gettimeofday() when available (returns sec, microsec), falling
-- back to second precision when not.
local function _iso_now()
  local uv = vim.uv or vim.loop
  local ok, sec, usec = pcall(uv.gettimeofday)
  if ok and type(sec) == "number" and type(usec) == "number" then
    return os.date("!%Y-%m-%dT%H:%M:%S", sec) ..
      string.format(".%06dZ", usec)
  end
  return os.date("!%Y-%m-%dT%H:%M:%S.000000Z")
end
M._iso_now = _iso_now

-- Delegate to the single source of truth in util.lua. health.lua resolves
-- the same way via the same helper; keeping them in sync is load-bearing
-- (an :checkhealth pass for a python that's not the one the bridge actually
-- launches is worse than no health check at all).
local default_python = Util.resolve_python

local function find_bridge_script()
  -- Always resolve relative to this Lua file; works regardless of how the
  -- plugin was installed (lazy.nvim, packer, raw config dir).
  local src = debug.getinfo(1, "S").source
  local this = (src:sub(1, 1) == "@") and src:sub(2) or src
  local cand = vim.fn.fnamemodify(this, ":p:h") .. "/python/bridge.py"
  if vim.loop.fs_stat(cand) then return cand end
  return nil
end

local function build_cmd()
  local cfg = Cfg.get()
  if cfg.bridge_cmd and #cfg.bridge_cmd > 0 then return cfg.bridge_cmd end
  local python = default_python()
  if not python then return nil, "no python interpreter found" end
  local script = find_bridge_script()
  if not script then return nil, "bridge.py not found" end
  return { python, "-u", script }, nil, python
end

-- Pre-bridge dependency check. The bridge itself emits a `kernel_error` with
-- `kind=missing_module` on import failure, but only AFTER spawning python +
-- attempting to import jupyter_client (a noticeable delay on slow
-- filesystems / Windows). A Lua-side `python -c` probe finishes in 50-100 ms
-- and lets us surface a clear actionable error — and the `auto_install`
-- knob — before paying the bridge spawn cost.
--
-- Synchronous-return contract:
--   * returns true  → deps are present, caller can launch the bridge now
--   * returns false → deps missing; an install or a user prompt may have
--                     been kicked off in the background. The caller must
--                     bail; the user re-triggers execute() once the
--                     install completes (we surface a notify when ready).
--
-- We don't block the event loop on `pip install` because the editor would
-- otherwise hang for tens of seconds on a fresh venv. Re-execution by the
-- user is the natural retry signal.
function Kernel:_ensure_deps_or_offer_install()
  local python = default_python()
  if not python then
    Util.notify(
      "no python interpreter found — set vim.g.python3_host_prog, "
      .. "activate a venv, or pass python = ... to mercury.setup()",
      vim.log.levels.ERROR)
    return false
  end
  local res = Util.check_kernel_deps(python)
  if res.ok then return true end
  if self._install_pending then
    Util.notify("kernel deps install in progress; try again in a moment",
      vim.log.levels.INFO)
    return false
  end
  local missing_list = table.concat(res.missing, ", ")
  -- "Don't nag on every execute" guard. Once the user has explicitly
  -- declined an install for THIS python in this session, we surface a
  -- terse error notify (with the manual install command and a pointer to
  -- :NotebookKernelSelect) instead of re-firing the modal prompt. Cleared
  -- on `select_kernel` because that introduces a (potentially different)
  -- python whose deps state the user hasn't decided on yet.
  if self._install_declined and self._install_declined[python] then
    Util.notify(
      ("missing %s in %s — install with: %s -m pip install %s, "
       .. "or switch kernel via :NotebookKernelSelect"):format(
        missing_list, python, python, table.concat(res.missing, " ")),
      vim.log.levels.ERROR)
    return false
  end
  local cfg = Cfg.get()
  local policy = (cfg.kernel or {}).auto_install
  if policy == nil then policy = "ask" end
  if policy == false then
    Util.notify(
      ("missing python module%s in %s: %s — install with: %s -m pip install %s")
        :format(#res.missing == 1 and "" or "s", python, missing_list,
                python, table.concat(res.missing, " ")),
      vim.log.levels.ERROR)
    return false
  end
  local self_ref = self
  local function do_install()
    self_ref._install_pending = true
    Util.notify(("installing %s into %s …"):format(missing_list, python),
      vim.log.levels.INFO)
    Util.install_kernel_deps(python, res.missing, function(ok, err)
      self_ref._install_pending = false
      if ok then
        Util.notify(
          ("installed %s into %s — re-run the cell to start the kernel")
            :format(missing_list, python),
          vim.log.levels.INFO)
      else
        Util.notify(
          ("failed to install %s into %s: %s — install manually with: "
           .. "%s -m pip install %s"):format(missing_list, python,
            err or "unknown error", python, table.concat(res.missing, " ")),
          vim.log.levels.ERROR)
      end
    end)
  end
  if policy == true then
    do_install()
    return false
  end
  -- "ask" path: prompt asynchronously. Same retry-after-install contract as
  -- the silent path — when the user confirms, the install kicks off and
  -- they re-trigger execute() once we notify that the install landed.
  -- On Cancel we record the decline so subsequent executes don't re-prompt
  -- — the modal-style nagging was the user's complaint.
  vim.schedule(function()
    vim.ui.select(
      { "Install now", "Cancel" },
      {
        prompt = ("Mercury: %s missing in %s. Install?")
          :format(missing_list, python),
      },
      function(choice)
        if choice == "Install now" then
          do_install()
        else
          self_ref._install_declined = self_ref._install_declined or {}
          self_ref._install_declined[python] = true
        end
      end)
  end)
  return false
end

function M.new(notebook, opts)
  local k = setmetatable({
    notebook = notebook,
    job_id = nil,
    chan = nil,
    queue = {},          -- pending: { { cell_id, code } }
    running = nil,       -- { cell_id, started_at }
    json_buf = "",
    on_change = opts and opts.on_change or function() end,
    kernel_opts = opts and opts.kernel or Cfg.get().kernel,
    kernels = nil,
    _on_list = nil,
    _stderr_buf = {},
    _stderr_timer = nil,
  }, Kernel)
  return k
end

function Kernel:_prompt_select_kernel(available)
  vim.schedule(function()
    vim.ui.select(available or {}, {
      prompt = "Mercury: pick a kernel",
      format_item = function(it)
        return ("%s  (%s)"):format(it.display_name or it.name, it.name)
      end,
    }, function(choice)
      if not choice then return end
      self:select_kernel(choice)
    end)
  end)
end

-- True if `status` is a terminal status that subsequent events must not
-- downgrade. SPEC invariant 10: once a cell reaches `error` it stays `error`
-- (the user must see the traceback signal even if a later interrupt fires);
-- and once it reaches `killed` from an interrupt, a stale `execute_done` from
-- the same execute must not silently flip it back to `ok`.
local function _is_terminal(status)
  return status == "error" or status == "killed"
end

-- Mark the running cell (if any) with `out_status` and clear self.running.
-- Used by paths that should stop the current execution but NOT cancel cells
-- waiting in the queue (the "interrupt" path — matches Jupyter where SIGINT
-- only affects what's executing right now, not what's queued behind it).
--
-- Only touches *existing* output entries — does NOT synthesize a new one.
-- That matters for `:NotebookKernelRestartClear`, which calls
-- `clear_all_outputs()` then sends restart; without this guard, the
-- "restarted" handler would resurrect a phantom "killed" pill on every
-- previously-running/queued cell the user just asked to clear.
--
-- Terminal statuses ("error", "killed") are sticky. An interrupt arriving
-- after an iopub `error` must not overwrite the error pill — the user would
-- otherwise lose the visible signal that a cell raised. SPEC invariant 10.
function Kernel:_cancel_running(out_status)
  out_status = out_status or "killed"
  local nb = self.notebook
  if nb and self.running then
    local out = nb.outputs and nb.outputs[self.running.cell_id]
    if out then
      if not _is_terminal(out.status) then out.status = out_status end
      -- Reset transient execution flags so a re-execute of the same cell
      -- after :NotebookKernelInterrupt starts from a clean slate:
      --   * `_pending_clear` carrying over would silently wipe the first
      --     output of the new run (the next `_apply_item` flushes pending
      --     before appending — that's the tqdm-style deferred clear);
      --   * `_started_iso` would orphan a stale ExecuteTime "start" inside
      --     cell_metadata.execution without a matching "end" timestamp.
      -- SPEC Invariant 10's sticky-status rule still holds (status fields
      -- on terminal `error`/`killed` aren't downgraded); these are
      -- per-execute transient fields, not the user-visible pill.
      out._pending_clear = nil
      out._started_iso = nil
    end
  end
  self.running = nil
end

-- Mark every queued cell with `out_status` and clear self.queue. Like
-- _cancel_running, only updates entries that already exist — no phantom
-- pills on cells the user explicitly cleared. Same sticky-terminal rule.
function Kernel:_cancel_queue(out_status)
  out_status = out_status or "killed"
  local nb = self.notebook
  if nb and nb.outputs then
    for _, task in ipairs(self.queue) do
      local out = nb.outputs[task.cell_id]
      if out and not _is_terminal(out.status) then out.status = out_status end
    end
  end
  self.queue = {}
end

-- Cancel BOTH running and queued cells. The "kernel is going away" path —
-- restart / kernel_dead / stop / unexpected-exit all leave nothing to pump
-- against, so dropping the queue is the right thing.
function Kernel:_cancel_in_flight(out_status)
  self:_cancel_running(out_status)
  self:_cancel_queue(out_status)
end

function Kernel:_handle_msg(msg)
  local typ = msg.type
  local nb = self.notebook
  if typ == "execute_start" then
    -- already set running on send; ignore
  elseif typ == "output" then
    -- Defense in depth (SPEC Invariant 19): the kernel keeps emitting until
    -- execute_done even if the cell was deleted or converted to non-code
    -- mid-execution. Without this guard, ensure_output would resurrect a
    -- ghost entry on every chunk — harmless to render but a real
    -- inconsistency the next rescan would have to clean up.
    local Notebook = require("mercury.notebook")
    if not Notebook._live_code_cell or Notebook._live_code_cell(nb, msg.cell_id) then
      local out = nb:ensure_output(msg.cell_id)
      self:_apply_item(out, msg.item or {})
      self.on_change()
    end
  elseif typ == "execute_input" then
    -- The kernel publishes `execute_input` on iopub as soon as it pulls the
    -- request off the shell channel; this is what populates the live `In[N]`
    -- prompt in JupyterLab / VS Code well before `execute_reply` arrives.
    -- Bind exec_count and the ISO-8601 start timestamp here so a long-running
    -- cell shows its In[N] number immediately.
    local Notebook = require("mercury.notebook")
    if (not Notebook._live_code_cell) or Notebook._live_code_cell(nb, msg.cell_id) then
      local out = nb:ensure_output(msg.cell_id)
      if msg.exec_count then out.exec_count = msg.exec_count end
      if msg.started_iso then out._started_iso = msg.started_iso end
      self.on_change()
    end
  elseif typ == "execute_done" then
    -- SPEC Invariant 24: like the `output` branch, the cell may have
    -- vanished or been converted to non-code mid-execution. We still
    -- need to clear self.running and pump the queue (the kernel is now
    -- free), but we must NOT resurrect a writable output entry — that
    -- would create exactly the side-table residue rescan's GC pass works
    -- to avoid. The buffer-modified flag in `_skipped_at_save` housekeeping
    -- also only makes sense for a live cell.
    local Notebook = require("mercury.notebook")
    local live = (not Notebook._live_code_cell)
      or Notebook._live_code_cell(nb, msg.cell_id)
    if live then
      local out = nb:ensure_output(msg.cell_id)
      out.exec_count = msg.exec_count or out.exec_count
      out.ms = msg.ms or 0
      -- Drop any leftover deferred-clear flag, but do NOT wipe `out.items`.
      -- IPython's documented `clear_output(wait=True)` semantics: defer the
      -- clear until the *next* output arrives; if no further output arrives
      -- before the cell finishes, the prior content STAYS. This is what
      -- preserves tqdm's final progress-bar frame in JupyterLab / VS Code /
      -- classic Notebook. Earlier Mercury releases flushed the pending
      -- clear at execute_done, wiping the final frame — divergent from
      -- every other notebook UI.
      out._pending_clear = nil
      -- Preserve terminal statuses set earlier in the same execute.
      if not _is_terminal(out.status) then
        out.status = "ok"
      end
      if msg.outputs and (#out.items == 0) then
        for _, it in ipairs(msg.outputs) do self:_apply_item(out, it) end
      end
      -- ExecuteTime nbformat extension (Invariant 27): record the iso8601
      -- end timestamp so a notebook round-tripped Jupyter Lab ↔ Mercury
      -- doesn't lose absolute execute timing. `out._started_iso` is set
      -- by `_pump` when this cell started running (or by the bridge's
      -- execute_input forward); copy it over to the cell_metadata.execution
      -- block under JupyterLab's dotted-leaf-keys convention now.
      if out._started_iso then
        nb.cell_metadata[msg.cell_id] = nb.cell_metadata[msg.cell_id] or {}
        local cm = nb.cell_metadata[msg.cell_id]
        cm.execution = cm.execution or {}
        cm.execution["iopub.execute_input"] = out._started_iso
        cm.execution["shell.execute_reply"] = _iso_now()
        out._started_iso = nil
      end
      -- If this cell was in-flight at the last :w (and therefore written to
      -- JSON as not-yet-executed), the now-available output is something the
      -- user expects a second :w to capture. Vim only tracks `modified` on
      -- buffer text, so we set it ourselves so a re-save isn't silently a
      -- no-op. SPEC Invariant 14.
      if nb._skipped_at_save and nb._skipped_at_save[msg.cell_id] then
        nb._skipped_at_save[msg.cell_id] = nil
        if vim.api.nvim_buf_is_valid(nb.buf) then
          vim.bo[nb.buf].modified = true
        end
        if next(nb._skipped_at_save) == nil then nb._skipped_at_save = nil end
      end
    end
    if self.running and self.running.cell_id == msg.cell_id then self.running = nil end
    self:_pump()
    self.on_change()
  elseif typ == "interrupted" then
    -- Jupyter semantics: interrupt SIGINTs the kernel, which raises
    -- KeyboardInterrupt in the running cell. Queued cells continue to
    -- execute in order once the current one stops. Use restart (or stop)
    -- to drop the queue.
    self:_cancel_running("killed")
    self.on_change()
  elseif typ == "restarted" then
    -- Two paths land here:
    --   1. User invoked Kernel:restart — we already _cancel_in_flight'd
    --      synchronously up-front. Cancelling again here would clobber any
    --      cell the user queued during the restart window.
    --   2. The bridge spontaneously emitted `restarted` — no synchronous
    --      cancel ran, so we still need to clear in-flight cells.
    if self._restart_pending then
      self._restart_pending = false
    else
      self:_cancel_in_flight("killed")
    end
    -- Apply the deferred clear (RestartClear) now — the bridge has emitted
    -- `restarted` after draining its parent_to_cell map, so no more old-
    -- kernel frames will arrive. Clearing earlier (synchronously in
    -- Kernel:restart) raced iopub frames in flight. SPEC Invariant 42.
    if self._restart_clear_pending then
      self._restart_clear_pending = nil
      if self.notebook and self.notebook.clear_all_outputs then
        self.notebook:clear_all_outputs()
      end
    end
    self.on_change()
  elseif typ == "kernel_dead" or typ == "kernel_error" then
    if msg.kind == "unsupported" then
      -- Soft warning: a request couldn't be served by this transport, but
      -- nothing has actually died. Don't clobber running/queue — the cell
      -- is still executing on whatever kernel we're connected to.
      Util.notify("kernel: " .. (msg.error or typ), vim.log.levels.WARN)
      return
    end
    -- Fatal/restart-failed path: if we were mid-restart, the restart didn't
    -- land. Clear the gate so the user can recover with another execute /
    -- restart instead of being permanently locked out by `_ensure_started`'s
    -- refusal (SPEC Invariant 25 made bidirectional — entering AND leaving
    -- the restart window are both bounded events). Without this, a failed
    -- restart (e.g., existing-mode supervisor never relaunched the kernel,
    -- or local restart raised in bridge.restart()) wedged every subsequent
    -- :NotebookExec into the "kernel is restarting" notify forever.
    -- Drop the deferred clear too — the kernel is gone, outputs stay where
    -- they are; user can re-run RestartClear later.
    self._restart_pending = false
    self._restart_clear_pending = nil
    self:_cancel_in_flight("killed")
    if msg.kind == "no_kernelspec" and msg.available and #msg.available > 0 then
      Util.notify("kernel: " .. (msg.error or typ), vim.log.levels.WARN)
      self:_prompt_select_kernel(msg.available)
    elseif typ == "kernel_dead" then
      -- The kernel subprocess died but the bridge is still alive. The next
      -- :NotebookExec would fail noisily; nudge the user toward the recovery
      -- action so they don't sit there wondering why nothing runs.
      Util.notify("kernel died: " .. (msg.error or "unknown") ..
        " — use :NotebookKernelRestart to recover",
        vim.log.levels.ERROR)
    else
      Util.notify("kernel: " .. (msg.error or typ), vim.log.levels.ERROR)
    end
    self.on_change()
  elseif typ == "kernels_listed" then
    self.kernels = msg.kernels or {}
    local cbs = self._on_list
    self._on_list = nil
    -- Cancel the pending timeout — the reply arrived in time, so the
    -- fallback "bridge did not reply" notify must not fire later.
    if self._list_kernels_timer then
      pcall(function() self._list_kernels_timer:stop() end)
      pcall(function() self._list_kernels_timer:close() end)
      self._list_kernels_timer = nil
    end
    if cbs then
      -- Backwards-compatible: old form was a single function. New form is
      -- a list of functions queued via list_kernels — fire all of them.
      if type(cbs) == "function" then
        cbs(self.kernels)
      else
        for _, cb in ipairs(cbs) do pcall(cb, self.kernels) end
      end
    end
  else
    -- Unknown message type from the bridge. A future protocol version might
    -- add new message kinds; don't silently drop them (masks protocol drift).
    -- Once-per-type rate-limit via _unknown_typs so a misbehaving bridge
    -- can't spam.
    if typ then
      self._unknown_typs = self._unknown_typs or {}
      if not self._unknown_typs[typ] then
        self._unknown_typs[typ] = true
        Util.notify("kernel: unrecognized bridge message type "
          .. tostring(typ) .. " — protocol drift", vim.log.levels.WARN)
      end
    end
  end
end

function Kernel:_apply_item(out, item)
  local t = item.type
  if t == "clear_output" then
    -- wait=True means "clear on next output", per Jupyter protocol — needed
    -- for tqdm-style progress redraws to not flicker.
    if item.wait then
      out._pending_clear = true
    else
      out.items = {}
      out._pending_clear = nil
    end
    return
  end
  if out._pending_clear then
    out.items = {}
    out._pending_clear = nil
  end
  if t == "stream" then
    -- Clamp `name` to {stdout, stderr} per nbformat schema. A buggy / non-
    -- compliant kernel emitting `name="custom"` would otherwise propagate
    -- through to disk and fail `nbformat.validate()` on the next pass. We
    -- can't drop the frame outright (text would be lost), so the conservative
    -- coercion is to route unknown names to stdout — same display path as
    -- the default value, no information lost beyond the name itself.
    local name = item.name
    if name ~= "stdout" and name ~= "stderr" then name = "stdout" end
    -- Coalesce consecutive streams of the same name.
    local last = out.items[#out.items]
    if last and last.type == "stream" and last.name == name then
      last.text = (last.text or "") .. (item.text or "")
    else
      table.insert(out.items, {
        type = "stream", name = name, text = item.text or "",
      })
    end
  elseif t == "update_display_data" then
    -- IPython.display.update_display(obj, display_id="x") updates EVERY item
    -- bound to that display_id, across ALL cells in the notebook — not just
    -- the cell that emitted the update. Jupyter Lab and VS Code both
    -- implement this: cell A creates `display(..., display_id="x")`, cell B
    -- calls `update_display(new_obj, display_id="x")` to refresh A's display.
    local did = (item.transient or {}).display_id
    -- update_display_data WITHOUT a display_id is meaningless — there's no
    -- target to update. Real JupyterLab silently drops these. The prior
    -- behavior here was to fall through and insert a phantom display_data
    -- in the calling cell with `_display_id = nil`, which is both unhelpful
    -- (the update was supposed to refresh an existing block, not create a
    -- new one) and divergent from every other notebook UI. Drop and return.
    if not did or did == "" then return end
    local updated = false
    local cross_cell_updated = false
    local function update_in(items, is_other)
      for _, it in ipairs(items or {}) do
        if it._display_id == did then
          it.data = item.data or it.data
          it.metadata = item.metadata or it.metadata
          updated = true
          if is_other then cross_cell_updated = true end
        end
      end
    end
    update_in(out.items, false)
    -- Walk every OTHER cell's outputs too.
    if self.notebook and self.notebook.outputs then
      for _, other in pairs(self.notebook.outputs) do
        if other ~= out and other.items then update_in(other.items, true) end
      end
    end
    if updated then
      -- Defense in depth: if a different cell's items got mutated, schedule
      -- a render here rather than relying on the caller. on_change is
      -- coalesced (SPEC Invariant 7) so a redundant call collapses; this
      -- guarantees the cross-cell update lands visually even if a future
      -- caller of _apply_item forgets to call on_change after.
      if cross_cell_updated and self.on_change then
        pcall(self.on_change)
      end
      return
    end
    -- `display_id` was provided but no existing output holds it: the
    -- target display block was deleted (the cell that created it was
    -- removed, or its outputs were cleared). Real JupyterLab silently
    -- drops the update in this case; the prior behavior of inserting a
    -- new `display_data` in the CALLING cell produced a phantom block
    -- in the wrong place. Drop and return.
    return
  elseif t == "display_data" or t == "execute_result" then
    table.insert(out.items, {
      type = t,
      data = item.data or {},
      metadata = item.metadata or {},
      execution_count = item.execution_count,
      _display_id = (item.transient or {}).display_id,
    })
  elseif t == "error" then
    out.status = "error"
    -- nbformat requires traceback to be array<string>. A buggy kernel that
    -- sends a single string would otherwise propagate to disk and fail
    -- `nbformat.validate()`. Coerce: wrap a string in a single-element list,
    -- and filter any non-string entries from an existing list (rare but
    -- possible if the kernel mixed types).
    local tb = item.traceback
    if type(tb) == "string" then
      tb = { tb }
    elseif type(tb) == "table" then
      local clean = {}
      for _, line in ipairs(tb) do
        if type(line) == "string" then
          clean[#clean + 1] = line
        else
          clean[#clean + 1] = tostring(line)
        end
      end
      tb = clean
    else
      tb = {}
    end
    table.insert(out.items, {
      type = "error",
      ename = item.ename, evalue = item.evalue,
      traceback = tb,
    })
  else
    table.insert(out.items, item)
  end
end

-- Process a chunk of stdout from the bridge. Honors :h channel-lines —
-- each list element is one "line" of pipe output, split on "\n". The first
-- element extends the previous callback's tail; the last element is a
-- pending partial (or "" if the stream just ended with a newline). We must
-- NOT synthesize "\n" between elements, or partial JSON messages get
-- treated as complete and silently dropped (which breaks large outputs).
function Kernel:_handle_chunk(lines)
  if not lines or #lines == 0 then return end
  self.json_buf = self.json_buf .. (lines[1] or "")
  for i = 2, #lines do
    self:_emit_line(self.json_buf)
    self.json_buf = lines[i] or ""
  end
end

function Kernel:_emit_line(line)
  if not line or line == "" then return end
  local ok, msg = pcall(vim.json.decode, line)
  if ok and type(msg) == "table" then
    -- pcall the handler too so a Lua error inside _handle_msg can't propagate
    -- up through jobstart's stdout callback and tear down the channel.
    pcall(self._handle_msg, self, msg)
    return
  end
  -- A non-JSON line on the bridge's stdout means something is corrupting the
  -- protocol stream — typically a python library that prints a banner /
  -- progress / deprecation warning. Batch these into a single debounced
  -- notify so a library spamming stdout doesn't drown the user in popups.
  self._corrupt_buf = self._corrupt_buf or {}
  self._corrupt_buf[#self._corrupt_buf + 1] = line:sub(1, 200)
  if self._corrupt_timer then return end
  self._corrupt_timer = vim.defer_fn(function()
    local lines = self._corrupt_buf or {}
    self._corrupt_buf = nil
    self._corrupt_timer = nil
    if #lines == 0 then return end
    local sample = lines[1]
    Util.notify(("kernel: %d corrupt protocol line%s (likely a library "
      .. "printing to stdout); first: %s"):format(
        #lines, #lines == 1 and "" or "s", sample),
      vim.log.levels.WARN)
  end, 100)
end

-- Three deps policies, controlled by `opts`:
--
--   default                 — probe deps; if missing, prompt the user per
--                             `kernel.auto_install` and return false.
--   silent_deps_check=true  — probe deps; if missing, return false WITHOUT
--                             prompting. Used by `:NotebookKernelSelect`'s
--                             `list_kernels` so opening the picker doesn't
--                             nag the user with an install dialog — the
--                             picker is itself the recovery path (switch
--                             to a venv that has deps).
--   skip_deps_check=true    — don't probe deps at all. Used by tests that
--                             stub `_send` so the bridge subprocess never
--                             actually runs.
function Kernel:_ensure_started(opts)
  opts = opts or {}
  -- Refuse to start (or piggy-back on) the bridge while a shutdown is in
  -- flight. Without this, a keystroke that lands during the ~500ms `jobwait`
  -- window inside `Kernel:stop` would push onto self.queue, the cell would
  -- transition to "queued", and then `_cancel_in_flight` (which already ran
  -- at the top of stop()) wouldn't see it — leaving the cell stuck queued
  -- forever.
  if self._stopping then
    Util.notify("kernel is stopping; try again in a moment",
      vim.log.levels.INFO)
    return false
  end
  -- Same logic for a restart in flight (SPEC Invariant 25). Without this,
  -- a `<S-CR>` landing between `Kernel:restart` and the bridge's
  -- `restarted` reply calls `_send({execute})` to the OLD kernel — the
  -- bridge's `_restart_seq` epoch keeps the result from being reported,
  -- but the kernel may still execute the code with side effects (file
  -- writes, os.system calls) the user didn't expect on a "restarted" run.
  if self._restart_pending then
    Util.notify("kernel is restarting; try again in a moment",
      vim.log.levels.INFO)
    return false
  end
  if self.job_id and vim.fn.jobwait({ self.job_id }, 0)[1] == -1 then
    return true
  end
  local cmd, err = build_cmd()
  if not cmd then
    Util.notify("kernel: " .. err, vim.log.levels.ERROR)
    return false
  end
  -- Fail fast: probe `jupyter_client` + `ipykernel` availability before paying
  -- the bridge spawn cost. If missing, surface an actionable error (and
  -- optionally kick off a `pip install` per `kernel.auto_install`). Bypassed
  -- when the user has overridden `bridge_cmd` since we can't tell what
  -- arbitrary command needs, OR when the caller opted out via the
  -- `skip_deps_check` / `silent_deps_check` flags (see this function's
  -- header for policy details).
  if not opts.skip_deps_check
      and not (Cfg.get().bridge_cmd and #Cfg.get().bridge_cmd > 0) then
    if opts.silent_deps_check then
      local python = default_python()
      if python then
        local res = Util.check_kernel_deps(python)
        if not res.ok then return false end
      end
    else
      if not self:_ensure_deps_or_offer_install() then return false end
    end
  end
  local cwd
  if vim.api.nvim_buf_is_valid(self.notebook.buf) then
    local name = vim.api.nvim_buf_get_name(self.notebook.buf)
    if name ~= "" then cwd = vim.fn.fnamemodify(name, ":p:h") end
  end
  local self_ref = self
  local job = vim.fn.jobstart(cmd, {
    cwd = cwd,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, d, _) if d then self_ref:_handle_chunk(d) end end,
    on_stderr = function(_, d, _)
      if not d then return end
      for _, ln in ipairs(d) do
        if ln ~= "" then
          table.insert(self_ref._stderr_buf, ln)
        end
      end
      if self_ref._stderr_timer then return end
      self_ref._stderr_timer = vim.defer_fn(function()
        local lines = self_ref._stderr_buf
        self_ref._stderr_buf = {}
        self_ref._stderr_timer = nil
        if #lines > 0 then
          Util.notify("bridge:\n" .. table.concat(lines, "\n"),
            vim.log.levels.WARN)
        end
      end, 100)
    end,
    on_exit = function(job_id)
      self_ref:_handle_exit(job_id)
    end,
  })
  if job <= 0 then
    Util.notify("failed to start kernel bridge", vim.log.levels.ERROR)
    return false
  end
  self.job_id, self.chan = job, job
  self.json_buf = ""
  -- Send init opts (kernel mode, name, etc.)
  self:_send({ type = "init", kernel = self.kernel_opts })
  return true
end

function Kernel:_send(payload)
  if not self.chan then return false end
  local ok, err = pcall(vim.fn.chansend, self.chan, vim.json.encode(payload) .. "\n")
  if not ok then
    Util.notify("kernel: failed to send to bridge: " .. tostring(err),
      vim.log.levels.WARN)
    return false
  end
  return true
end

function Kernel:_pump()
  if self.running then return end
  if #self.queue == 0 then return end
  local task = table.remove(self.queue, 1)
  self.running = { cell_id = task.cell_id, started_at = os.time() }
  local out = self.notebook:ensure_output(task.cell_id)
  out.status = "running"
  out.items = {}
  -- Record an ISO-8601 UTC start timestamp on the live output (microsecond
  -- precision, matching JupyterLab's ExecuteTime extension). execute_done
  -- copies it (along with a fresh end-timestamp) into
  -- cell_metadata.execution to populate the nbformat ExecuteTime extension.
  -- SPEC Invariant 27. Stored on `out` (not directly on cell_metadata) so
  -- a partial in-flight execute that's later restarted doesn't leak a
  -- start-without-end into the saved JSON. If the bridge later forwards
  -- iopub `execute_input` for this cell, it will overwrite this estimate
  -- with the kernel-side stamp so the saved metadata matches what
  -- JupyterLab would have written.
  out._started_iso = _iso_now()
  self.on_change()
  -- Roll back the running state if _send fails (bridge died mid-flight).
  -- Without this, self.running stays set forever and _pump refuses to
  -- advance the queue on the next execute. Mark the cell killed so the
  -- pill reflects what actually happened.
  if not self:_send({ type = "execute", cell_id = task.cell_id, code = task.code }) then
    self.running = nil
    if not _is_terminal(out.status) then out.status = "killed" end
    self.on_change()
  end
end

-- Bridge job has exited (clean or otherwise). Called by jobstart's on_exit
-- and by tests directly.
--
-- Two layers of job_id correctness here:
--
-- (1) Stale on_exit guard. A Kernel:stop followed quickly by Kernel:execute
-- creates a NEW job, and the OLD job's deferred on_exit must not clobber
-- the new state. If `job_id ~= self.job_id`, this is the old job's late
-- callback — we still consume its expected flag (so the next tick on a
-- live job doesn't see a leftover) but otherwise do nothing.
--
-- (2) Per-job `_expected_exit_for`. The pre-existing single `_expected_exit`
-- boolean was a Kernel-level flag, which means: stop() sets it true, then
-- before the OLD job's on_exit fires the user runs execute(), a new job
-- is spawned, the NEW job dies instantly (bad python, etc.), and the NEW
-- on_exit consumes the boolean — treating the new crash as expected and
-- silently swallowing the failure. Pinning to a specific job_id closes
-- that race: the boolean only releases when the on_exit matches the job
-- that stop() observed. SPEC § "Graceful shutdown" — `_expected_exit_for`.
function Kernel:_handle_exit(job_id)
  if self.job_id ~= nil and job_id ~= nil and job_id ~= self.job_id then
    -- Old job's late callback. Reap its expected-flag entry if it owns one
    -- so a future real death of a new job doesn't read it.
    if self._expected_exit_for == job_id then
      self._expected_exit_for = nil
    end
    return
  end
  local expected = (self._expected_exit_for ~= nil)
    and (self._expected_exit_for == job_id)
  if expected then self._expected_exit_for = nil end
  self._stopping = false
  -- Failed restart that ends with the bridge dying (vs. emitting a
  -- kernel_error) must also clear `_restart_pending`, or `_ensure_started`
  -- refuses every subsequent execute forever. SPEC Invariant 25.
  self._restart_pending = false
  self._restart_clear_pending = nil
  self.job_id = nil
  self.chan = nil
  self.json_buf = ""
  if not expected then
    self:_cancel_in_flight("killed")
    -- The `_skipped_at_save` table tracks cells that were in-flight at the
    -- last :w so a later execute_done can mark the buffer modified. A bridge
    -- death means those cells will never finish — every subsequent save would
    -- still skip them under SPEC Invariant 14's "no in-flight" check, but the
    -- table would grow forever. Clear it; if the user re-runs the cells the
    -- table repopulates on the next save with in-flight entries.
    local nb = self.notebook
    if nb and nb._skipped_at_save then nb._skipped_at_save = nil end
    Util.notify("kernel bridge exited unexpectedly", vim.log.levels.WARN)
    if self.on_change then pcall(self.on_change) end
  end
end

function Kernel:execute(cell)
  if cell.kind ~= "code" then return end
  if not self:_ensure_started() then return end
  -- Dedup: if this cell is already running or queued, refuse the new
  -- request. Two rapid `<S-CR>` presses would otherwise stack a second
  -- entry that, when popped by _pump, sets `out.items = {}` and wipes the
  -- live output that the first run is still streaming. Jupyter Lab disables
  -- the run button while a cell is busy; this is the equivalent.
  if self.running and self.running.cell_id == cell.id then
    Util.notify("cell is already running", vim.log.levels.INFO)
    return
  end
  for _, task in ipairs(self.queue) do
    if task.cell_id == cell.id then
      Util.notify("cell is already queued", vim.log.levels.INFO)
      return
    end
  end
  -- Trim the trailing visual-gap blank line(s) that to_buffer_lines inserts
  -- between cells. They are purely visual — the user did not type them and
  -- they're stripped on save (to_ipynb_struct) — so the kernel should not see
  -- them either. Without this, "%%timeit foo" / last-expression-evaluation
  -- semantics on some kernels can be perturbed by a stray trailing newline,
  -- and tools that introspect the source (e.g., IPython's `??`) would
  -- display the extra blank.
  local body = self.notebook:cell_body_lines(cell)
  while #body > 0 and body[#body] == "" do table.remove(body, #body) end
  local code = table.concat(body, "\n")
  local out = self.notebook:ensure_output(cell.id)
  out.status = "queued"
  table.insert(self.queue, { cell_id = cell.id, code = code })
  self.on_change()
  self:_pump()
end

function Kernel:interrupt()
  if not self.chan then
    Util.notify("kernel is not running", vim.log.levels.INFO)
    return
  end
  -- Don't shove an interrupt at a channel that's being torn down. The bridge
  -- has already received `shutdown`; the kernel may or may not see SIGINT
  -- before its supervisor reaps it. Either way, the user expectation is
  -- "interrupt the active execution," and there is no active execution to
  -- interrupt during stop/restart windows. SPEC Invariant 11 made bidirectional.
  if self._stopping then
    Util.notify("kernel is stopping; interrupt ignored",
      vim.log.levels.INFO)
    return
  end
  if self._restart_pending then
    Util.notify("kernel is restarting; interrupt ignored",
      vim.log.levels.INFO)
    return
  end
  self:_send({ type = "interrupt" })
end

function Kernel:restart(opts)
  opts = opts or {}
  if not self.chan then
    -- Bridge isn't running yet — typical on a freshly-opened notebook where
    -- the user wants to wipe the outputs that came in from disk. Honor
    -- `opts.clear` locally: no kernel to bounce, just drop the side-table.
    -- This makes `:NotebookKernelRestartClear` work the same way before and
    -- after the first execute.
    if opts.clear and self.notebook and self.notebook.clear_all_outputs then
      self.notebook:clear_all_outputs()
      if self.on_change then pcall(self.on_change) end
      Util.notify("outputs cleared (kernel was not running)",
        vim.log.levels.INFO)
      return
    end
    Util.notify("kernel is not running", vim.log.levels.INFO)
    return
  end
  -- Symmetric to interrupt: pressing :NotebookKernelRestart while a stop
  -- teardown is in flight, or while a previous restart hasn't completed,
  -- would otherwise write to a dying channel and the result of the
  -- subsequent execute could be confusing.
  if self._stopping then
    Util.notify("kernel is stopping; restart ignored (next execute will respawn the bridge)",
      vim.log.levels.INFO)
    return
  end
  if self._restart_pending then
    Util.notify("kernel is already restarting", vim.log.levels.INFO)
    return
  end
  -- Cancel in-flight cells synchronously BEFORE sending restart so a user
  -- who fires :NotebookExec immediately afterwards doesn't have their new
  -- cell wiped by the eventual `restarted` event arriving back from the
  -- bridge. Without this, _pump's `if self.running then return` guard sees
  -- the still-set running state and queues the new cell; when `restarted`
  -- lands, _cancel_in_flight drops the just-queued cell along with the old
  -- ones.
  --
  -- _restart_pending tells the eventual `restarted` handler that we
  -- already cancelled — without it, the handler would cancel again and
  -- clobber any cell the user queued during the restart window.
  self:_cancel_in_flight("killed")
  self._restart_pending = true
  -- Defer the clear until `restarted` arrives. The bridge's restart()
  -- empties `parent_to_cell` and bumps `_restart_seq` before SIGKILLing the
  -- kernel, but iopub frames that were already on the wire when restart
  -- was called continue to arrive until the channel drains. Those frames
  -- land in `_handle_msg` → `ensure_output` and resurrect output entries
  -- on cells the user just asked to clear. By deferring the clear until
  -- after `restarted` (which is emitted *after* the bridge's lock-held
  -- drain), we know no more old-kernel frames are coming. SPEC Invariant 42.
  self._restart_clear_pending = (opts.clear and true) or nil
  self:_send({ type = "restart" })
  if self.on_change then self.on_change() end
end

function Kernel:stop()
  -- Block new executes while we tear down (SPEC Invariant 13).
  self._stopping = true
  -- `_expected_exit_for` is a SEPARATE flag from _stopping: _stopping is
  -- cleared synchronously at the end of stop() so the next execute can
  -- respawn the bridge, but the expected-exit signal must survive until
  -- the on_exit callback runs on a later event-loop tick. If on_exit
  -- consulted _stopping it'd already be false by then and would treat the
  -- clean stop as a crash.
  --
  -- We pin to the specific job_id stop() is tearing down. Without that pin,
  -- a stop() followed by a fast execute() that spawns a new bridge that
  -- itself dies would have its NEW on_exit consume the OLD stop's expected
  -- signal and silently swallow the new failure (see _handle_exit comment).
  if self.job_id then
    self._expected_exit_for = self.job_id
  end
  -- Stop also exits the restart window cleanly — without this clear, a
  -- restart that races a stop() before the bridge emits `restarted` leaves
  -- `_restart_pending` stuck true after stop returns. SPEC Invariant 25.
  self._restart_pending = false
  self._restart_clear_pending = nil
  -- Mark any running / queued cells as killed BEFORE we clear them, so the
  -- UI doesn't show a permanent "Running…" or "Queued" pill on cells whose
  -- kernel is gone. (The on_exit handler does this for *unexpected* exits;
  -- this is the symmetric path for explicit stops — :NotebookKernelStop and
  -- :NotebookKernelSelect both come through here.)
  self:_cancel_in_flight("killed")
  if self.job_id then
    -- Give the bridge a chance to shut down its kernel cleanly. The bridge
    -- handles a "shutdown" message by breaking its read loop and running
    -- the close() finalizer (which calls km.shutdown_kernel). A bare jobstop
    -- delivers SIGTERM and may bypass python's finally blocks, leaking the
    -- kernel subprocess.
    pcall(self._send, self, { type = "shutdown" })
    local job = self.job_id
    -- Bounded wait — 500ms is enough for the bridge's close() finalizer in
    -- the common case; we still SIGTERM on timeout so a hung bridge can't
    -- pin nvim on exit.
    pcall(vim.fn.jobwait, { job }, 500)
    pcall(vim.fn.chanclose, self.chan)
    pcall(vim.fn.jobstop, job)
  end
  -- Cancel any pending stderr flush — otherwise it fires post-stop with the
  -- residual buffer and notifies the user about a kernel that's already gone.
  if self._stderr_timer then
    pcall(function() self._stderr_timer:stop() end)
    pcall(function() self._stderr_timer:close() end)
    self._stderr_timer = nil
  end
  self._stderr_buf = {}
  -- Same for the list_kernels timeout: if the bridge is going away, a
  -- pending picker that already lost its reply must fire its callbacks
  -- (with empty lists) so callers aren't stranded waiting.
  if self._list_kernels_timer then
    pcall(function() self._list_kernels_timer:stop() end)
    pcall(function() self._list_kernels_timer:close() end)
    self._list_kernels_timer = nil
  end
  local cbs = self._on_list
  self._on_list = nil
  if cbs then
    if type(cbs) == "function" then
      pcall(cbs, {})
    else
      for _, c in ipairs(cbs) do pcall(c, {}) end
    end
  end
  self.job_id = nil; self.chan = nil
  self.json_buf = ""
  -- Clear _stopping so the next execute can respawn the bridge. We held this
  -- across the jobwait window above to block executes from racing in; now
  -- shutdown is complete and the next execute will fall into the cold-start
  -- path of _ensure_started.
  self._stopping = false
  -- _cancel_in_flight just changed pill statuses; trigger a render so the
  -- user actually sees them transition out of running/queued.
  if self.on_change then pcall(self.on_change) end
end

-- Bounded wait for the bridge's `kernels_listed` reply. If the bridge
-- accepted the request but never replies (bridge bug, process wedged), the
-- picker would never open and the user would have no recovery short of
-- `:NotebookKernelStop`. The timeout fires the callbacks with an empty list
-- and emits a WARN so the user understands why the picker stayed silent.
local LIST_KERNELS_TIMEOUT_MS = 5000

function Kernel:list_kernels(cb)
  -- The picker can populate itself from discovered pythons + manual entry
  -- even when registered kernelspecs aren't available — so don't block the
  -- user with the install prompt when they're trying to switch kernels.
  -- `silent_deps_check = true` makes _ensure_started probe deps but skip
  -- the install prompt; on a missing-deps verdict it returns false and we
  -- hand the caller an empty list so the picker opens with the other
  -- two sources (the user's natural recovery path).
  if not self:_ensure_started({ silent_deps_check = true }) then
    vim.schedule(function() pcall(cb, {}) end)
    return
  end
  -- Queue multiple callers. Without this, a second list_kernels call before
  -- the bridge reply lands silently overwrites the first caller's callback.
  -- If a request is already in-flight, just append the callback — the
  -- single bridge reply fans out to all queued callbacks.
  local in_flight = self._on_list ~= nil
  if type(self._on_list) == "function" then
    self._on_list = { self._on_list, cb }
  elseif type(self._on_list) == "table" then
    self._on_list[#self._on_list + 1] = cb
  else
    self._on_list = { cb }
  end
  if not in_flight then
    self:_send({ type = "list_kernels" })
    -- Arm a one-shot timeout. _handle_msg clears `_on_list` on reply, so
    -- the timer callback checks whether the slot is still set — if so the
    -- bridge missed the deadline. Cleared on Kernel:stop too.
    if self._list_kernels_timer then
      pcall(function() self._list_kernels_timer:stop() end)
      pcall(function() self._list_kernels_timer:close() end)
    end
    self._list_kernels_timer = vim.defer_fn(function()
      self._list_kernels_timer = nil
      if self._on_list == nil then return end   -- reply already arrived
      local cbs = self._on_list
      self._on_list = nil
      Util.notify("kernel: bridge did not reply to list_kernels within "
        .. tostring(LIST_KERNELS_TIMEOUT_MS) .. "ms; the picker will be empty",
        vim.log.levels.WARN)
      if type(cbs) == "function" then
        pcall(cbs, {})
      else
        for _, c in ipairs(cbs) do pcall(c, {}) end
      end
    end, LIST_KERNELS_TIMEOUT_MS)
  end
end

-- Summarise the kernel selection in human-readable form: which selector is
-- active (python path / spec_path / kernelspec name), the mode, and the
-- bridge's live/idle status. Used by `:NotebookKernelInfo` to surface
-- everything the user might want to know about "which kernel am I running?"
-- without digging into b:mercury_kernel_name.
function Kernel:info()
  local opts = self.kernel_opts or {}
  local mode = opts.mode or "local"
  local lines = { ("mode: %s"):format(mode) }
  -- Active selector lines — priority matches resolve order
  -- (python > spec_path > name) so the line list reads top-to-bottom in
  -- the same order Mercury actually consults.
  if opts.python then
    lines[#lines + 1] = "python: " .. opts.python
  end
  if opts.spec_path then
    lines[#lines + 1] = "spec_path: " .. opts.spec_path
  end
  if opts.name then
    lines[#lines + 1] = "kernelspec: " .. opts.name
  end
  if mode == "existing" and opts.connection_file then
    lines[#lines + 1] = "connection_file: " .. opts.connection_file
  end
  -- If NONE of those are set, the bridge falls back to "python3" on launch.
  if not opts.python and not opts.spec_path and not opts.name
      and not opts.connection_file then
    lines[#lines + 1] = "kernelspec: python3 (default fallback)"
  end
  -- Bridge status: alive vs idle. `jobwait({job}, 0)[1] == -1` means the
  -- process is still running; anything else means it's gone or never started.
  local alive = self.job_id ~= nil
    and (vim.fn.jobwait({ self.job_id }, 0)[1] == -1)
  lines[#lines + 1] = "bridge: " .. (alive and "running" or "not started")
  if self.running then
    lines[#lines + 1] = "currently executing: " ..
      (tostring(self.running.cell_id):sub(1, 8))
  end
  if self.queue and #self.queue > 0 then
    lines[#lines + 1] = ("queue length: %d"):format(#self.queue)
  end
  return lines
end

-- Accept any of:
--   string                                — registered kernelspec name
--   { name, display_name?, language? }    — registered kernelspec
--   { python = "/abs/path/python", ... }  — synthesize a kernelspec from a
--                                           python executable
--   { spec_path = "/abs/path/kernel/" }   — load kernelspec from an absolute
--                                           directory containing kernel.json
--
-- All three live in "local" mode; only the way the bridge resolves the
-- kernel changes. mode="existing" can't be changed via :NotebookKernelSelect
-- (would need a setup{} call to switch transports).
--
-- On change:
--   * kernel_opts is overwritten so old selectors don't shadow the new one,
--   * nb.meta.kernelspec is updated for tools that read standard nbformat,
--   * nb.meta.mercury_kernel.{python,spec_path} carries the mercury-specific
--     override across save/reopen,
--   * buffer is marked modified (so the user sees they need :w to persist),
--   * the bridge is stopped so the next :NotebookExec respawns with the
--     new selector.
function Kernel:select_kernel(spec)
  if type(spec) == "string" then spec = { name = spec } end
  if not spec then return end
  if not (spec.name or spec.python or spec.spec_path) then return end

  local mode = (self.kernel_opts and self.kernel_opts.mode) or "local"
  if mode ~= "local" then
    Util.notify(
      ("kernel selection ignored: transport is '%s'; change via setup{}"):format(mode),
      vim.log.levels.WARN)
    return
  end

  -- Build fresh opts so we don't carry over a stale selector (e.g. a
  -- name="python3" left from a previous selection would otherwise shadow a
  -- new python= path because vim.tbl_extend merges instead of replacing).
  self.kernel_opts = {
    mode = "local",
    name = spec.name,
    python = spec.python,
    spec_path = spec.spec_path,
  }
  -- New kernel = potentially different python = the user hasn't decided
  -- about ITS deps state yet. Reset the declined-install gate so the
  -- normal "ask once" flow fires fresh on the next execute.
  self._install_declined = nil

  local nb = self.notebook
  if nb then
    nb.meta = nb.meta or {}
    -- Merge into the existing kernelspec rather than replacing the whole
    -- object: notebooks produced by other tools may carry vendor-specific
    -- sub-keys (e.g. `kernelspec.env`, `kernelspec.interrupt_mode`,
    -- `kernelspec.metadata`) that we don't understand but must round-trip.
    -- Whole-object replacement would silently drop them. We only overwrite
    -- the three standard keys mercury manages directly.
    local merged = vim.deepcopy(nb.meta.kernelspec or {})
    merged.name = spec.name or merged.name or "python3"
    merged.display_name = spec.display_name or merged.display_name
      or (spec.python and
        ("Python (" .. require("mercury.discover").short_label(spec.python) .. ")"))
      or (spec.name or "Python 3")
    merged.language = spec.language or merged.language or "python"
    nb.meta.kernelspec = merged
    if spec.python or spec.spec_path then
      nb.meta.mercury_kernel = {
        python = spec.python,
        spec_path = spec.spec_path,
      }
    else
      nb.meta.mercury_kernel = nil
    end
    if nb.buf and vim.api.nvim_buf_is_valid(nb.buf) then
      vim.b[nb.buf].mercury_kernel_name =
        spec.name or spec.python or spec.spec_path
      vim.bo[nb.buf].modified = true
    end
  end

  self:stop()
end

return M
