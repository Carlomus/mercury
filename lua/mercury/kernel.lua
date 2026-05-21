-- Lua-side client for the Python jupyter bridge.

local Cfg = require("mercury.config")
local Util = require("mercury.util")

local M = {}

local Kernel = {}
Kernel.__index = Kernel

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
  return { python, "-u", script }
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
    if out and not _is_terminal(out.status) then out.status = out_status end
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
  elseif typ == "execute_done" then
    local out = nb:ensure_output(msg.cell_id)
    out.exec_count = msg.exec_count or out.exec_count
    out.ms = msg.ms or 0
    -- A trailing `clear_output(wait=True)` whose next output never arrives is
    -- a Jupyter idiom: tqdm clears its progress bar before exiting the loop.
    if out._pending_clear then
      out.items = {}
      out._pending_clear = nil
    end
    -- Preserve terminal statuses set earlier in the same execute.
    if not _is_terminal(out.status) then
      out.status = "ok"
    end
    if msg.outputs and (#out.items == 0) then
      for _, it in ipairs(msg.outputs) do self:_apply_item(out, it) end
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
    self.on_change()
  elseif typ == "kernel_dead" or typ == "kernel_error" then
    if msg.kind == "unsupported" then
      -- Soft warning: a request couldn't be served by this transport, but
      -- nothing has actually died. Don't clobber running/queue — the cell
      -- is still executing on whatever kernel we're connected to.
      Util.notify("kernel: " .. (msg.error or typ), vim.log.levels.WARN)
      return
    end
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
    -- Coalesce consecutive streams of the same name.
    local last = out.items[#out.items]
    if last and last.type == "stream" and last.name == item.name then
      last.text = (last.text or "") .. (item.text or "")
    else
      table.insert(out.items, {
        type = "stream", name = item.name or "stdout", text = item.text or "",
      })
    end
  elseif t == "update_display_data" then
    -- IPython.display.update_display(obj, display_id="x") updates EVERY item
    -- bound to that display_id, across ALL cells in the notebook — not just
    -- the cell that emitted the update. Jupyter Lab and VS Code both
    -- implement this: cell A creates `display(..., display_id="x")`, cell B
    -- calls `update_display(new_obj, display_id="x")` to refresh A's display.
    local did = (item.transient or {}).display_id
    if did then
      local updated = false
      local function update_in(items)
        for _, it in ipairs(items or {}) do
          if it._display_id == did then
            it.data = item.data or it.data
            it.metadata = item.metadata or it.metadata
            updated = true
          end
        end
      end
      update_in(out.items)
      -- Walk every OTHER cell's outputs too.
      if self.notebook and self.notebook.outputs then
        for _, other in pairs(self.notebook.outputs) do
          if other ~= out and other.items then update_in(other.items) end
        end
      end
      if updated then return end
    end
    table.insert(out.items, {
      type = "display_data", data = item.data or {},
      metadata = item.metadata or {},
      _display_id = did,
    })
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
    table.insert(out.items, {
      type = "error",
      ename = item.ename, evalue = item.evalue,
      traceback = item.traceback or {},
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

function Kernel:_ensure_started()
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
  if self.job_id and vim.fn.jobwait({ self.job_id }, 0)[1] == -1 then
    return true
  end
  local cmd, err = build_cmd()
  if not cmd then
    Util.notify("kernel: " .. err, vim.log.levels.ERROR)
    return false
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
-- and by tests directly. Ignores stale callbacks whose job_id no longer
-- matches self.job_id — a Kernel:stop followed quickly by Kernel:execute
-- creates a new job and the old one's deferred on_exit must not clobber
-- the new state. SPEC § "Graceful shutdown".
function Kernel:_handle_exit(job_id)
  if self.job_id ~= nil and job_id ~= nil and job_id ~= self.job_id then
    return
  end
  -- _expected_exit survives across the event-loop tick — _stopping is
  -- cleared synchronously at the end of stop() so the next execute can
  -- respawn; _expected_exit tells THIS callback the exit was user-initiated.
  local expected = self._expected_exit
  self._expected_exit = false
  self._stopping = false
  self.job_id = nil
  self.chan = nil
  self.json_buf = ""
  if not expected then
    self:_cancel_in_flight("killed")
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
  local code = table.concat(self.notebook:cell_body_lines(cell), "\n")
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
  self:_send({ type = "interrupt" })
end

function Kernel:restart(opts)
  opts = opts or {}
  if not self.chan then
    Util.notify("kernel is not running", vim.log.levels.INFO)
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
  self:_send({ type = "restart" })
  if opts.clear then self.notebook:clear_all_outputs() end
  if self.on_change then self.on_change() end
end

function Kernel:stop()
  -- Block new executes while we tear down (SPEC Invariant 13).
  self._stopping = true
  -- _expected_exit is a SEPARATE flag from _stopping: _stopping is cleared
  -- synchronously at the end of stop() so the next execute can respawn the
  -- bridge, but _expected_exit must survive until the on_exit callback runs
  -- on a later event-loop tick. If on_exit consulted _stopping it'd already
  -- be false by then and would treat the clean stop as a crash.
  self._expected_exit = true
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

function Kernel:list_kernels(cb)
  if not self:_ensure_started() then return end
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
  end
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
