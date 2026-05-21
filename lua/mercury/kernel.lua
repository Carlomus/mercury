-- Lua-side client for the Python jupyter bridge.

local Cfg = require("mercury.config")
local Util = require("mercury.util")

local M = {}

local Kernel = {}
Kernel.__index = Kernel

local function default_python()
  local cfg = Cfg.get()
  if cfg.python and vim.fn.executable(cfg.python) == 1 then return cfg.python end
  local g = vim.g.mercury_python or vim.g.python3_host_prog
  if g and vim.fn.executable(g) == 1 then return g end
  local env = vim.env.VIRTUAL_ENV or vim.env.CONDA_PREFIX
  if env and env ~= "" then
    local sep = package.config:sub(1, 1)
    local cand = env .. (sep == "\\" and "\\Scripts\\python.exe" or "/bin/python")
    if vim.fn.executable(cand) == 1 then return cand end
  end
  for _, name in ipairs({ "python3", "python" }) do
    local p = vim.fn.exepath(name)
    if p ~= "" then return p end
  end
  return nil
end

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
    local out = nb:ensure_output(msg.cell_id)
    self:_apply_item(out, msg.item or {})
    self.on_change()
  elseif typ == "execute_done" then
    local out = nb:ensure_output(msg.cell_id)
    out.exec_count = msg.exec_count or out.exec_count
    out.ms = msg.ms or 0
    -- A trailing `clear_output(wait=True)` whose next output never arrives is
    -- a Jupyter idiom: tqdm clears its progress bar before exiting the loop.
    -- If we left `_pending_clear` set, the previous run's items would survive
    -- into the next execute. Drop them now so the cell's final state matches
    -- what the user typed.
    if out._pending_clear then
      out.items = {}
      out._pending_clear = nil
    end
    -- Preserve terminal statuses set earlier in the same execute: `error`
    -- from an iopub error message, or `killed` from an interrupted/cancelled
    -- handler. Without this, an interrupt whose `interrupted` event landed
    -- before the iopub error would have its terminal status quietly
    -- downgraded to "ok" here.
    if not _is_terminal(out.status) then
      out.status = "ok"
    end
    if msg.outputs and (#out.items == 0) then
      for _, it in ipairs(msg.outputs) do self:_apply_item(out, it) end
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
    self:_cancel_in_flight("killed")
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
    local cb = self._on_list
    self._on_list = nil
    if cb then cb(self.kernels) end
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
    -- bound to that display_id, not just the first. Iterate through all and
    -- only fall through to "insert as fresh display_data" if there were no
    -- matches at all.
    local did = (item.transient or {}).display_id
    if did then
      local updated = false
      for _, it in ipairs(out.items) do
        if it._display_id == did then
          it.data = item.data or it.data
          it.metadata = item.metadata or it.metadata
          updated = true
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
    self:_handle_msg(msg)
    return
  end
  -- A non-JSON line on the bridge's stdout means something is corrupting the
  -- protocol stream — typically a python library that prints a banner /
  -- progress / deprecation warning to stdout. Surface it instead of silently
  -- dropping; otherwise the user sees "executes randomly fail" with no clue.
  -- Truncate so a pathological caller can't blow up the notify panel.
  local snippet = line:sub(1, 200)
  Util.notify("kernel: corrupt protocol line (likely a library printing to "
    .. "stdout): " .. snippet, vim.log.levels.WARN)
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
    on_exit = function()
      -- Distinguish a clean user-initiated shutdown (Kernel:stop sets
      -- _stopping) from a bridge crash. On crash, queue/running are still
      -- set from the pre-crash state; without clearing them, `_pump`'s
      -- `if self.running then return end` guard would block every future
      -- execute and the queue would jam.
      local was_stopping = self_ref._stopping
      self_ref._stopping = false
      self_ref.job_id = nil
      self_ref.chan = nil
      self_ref.json_buf = ""
      if not was_stopping then
        self_ref:_cancel_in_flight("killed")
        Util.notify("kernel bridge exited unexpectedly", vim.log.levels.WARN)
        if self_ref.on_change then pcall(self_ref.on_change) end
      end
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
  pcall(vim.fn.chansend, self.chan, vim.json.encode(payload) .. "\n")
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
  self:_send({ type = "execute", cell_id = task.cell_id, code = task.code })
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
  self:_send({ type = "restart" })
  if opts.clear then self.notebook:clear_all_outputs(); self.on_change() end
end

function Kernel:stop()
  -- Tell on_exit this exit is expected, so it doesn't fire the
  -- "bridge exited unexpectedly" notification.
  self._stopping = true
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
  self._on_list = cb
  self:_send({ type = "list_kernels" })
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
