local Mgr = require("mercury.manager")

local E = {}
local state = {
	job_id = nil,
	chan_id = nil,

	conf = {
		output = {
			style = "float",
			split = { pos = "botright", size = 12 },
			float = { width = 0.5, height = 0.45, border = "rounded" },
		},
		show_virtual_preview = true,
		virtual_preview_lines = 12,
	},

	-- queue & streaming state
	capture = {}, -- { { block_id = ... } }   -- head is the active cell
	pending = {}, -- { { block_id = ..., payload = ... } }
	json_buf = "",
}

-- helpers to find a working Python
local function _exepath(bin)
	local p = vim.fn.exepath(bin)
	if p and p ~= "" then
		return p
	end
	return nil
end

local function _is_file(p)
	return p and p ~= "" and (vim.fn.filereadable(p) == 1 or vim.fn.executable(p) == 1)
end

local function resolve_python()
	-- venv / conda
	local sep = package.config:sub(1, 1) -- '/' or '\'
	local env = vim.env.VIRTUAL_ENV or vim.env.CONDA_PREFIX
	if env and env ~= "" then
		local cand = env .. (sep == "\\" and "\\Scripts\\python.exe" or "/bin/python")
		if _is_file(cand) then
			return cand
		end
	end

	local gpy = vim.g.python3_host_prog
	if _is_file(gpy) then
		return gpy
	end

	-- PATH fallbacks
	local p3 = _exepath("python3")
	if p3 then
		return p3
	end
	local p = _exepath("python")
	if p then
		return p
	end

	return nil
end

-- locate bridge and build argv
local function default_bridge_cmd()
	local src = debug.getinfo(1, "S").source
	local this = (src:sub(1, 1) == "@") and src:sub(2) or src
	local this_dir = vim.fn.fnamemodify(this, ":p:h")

	local hits = vim.api.nvim_get_runtime_file("mercury/python/bridge.py", false)
	local bridge = hits and hits[1]
	if not bridge then
		local candidates = {
			this_dir .. "/../../python/bridge.py",
			this_dir .. "/../python/bridge.py",
			this_dir .. "/../../../python/bridge.py",
		}
		for _, pth in ipairs(candidates) do
			if vim.loop.fs_stat(pth) then
				bridge = pth
				break
			end
		end
	end

	if not bridge then
		vim.notify("mercury: bridge.py not found.", vim.log.levels.ERROR)
		return nil
	end

	local py = resolve_python()
	if not py then
		vim.notify(
			"mercury: no Python interpreter found (tried venv/conda/python3/python). "
				.. "Either set vim.g.mercury_python = '/path/to/python'",
			vim.log.levels.ERROR
		)
		return nil
	end

	bridge = vim.fn.fnamemodify(bridge, ":p")

	return { py, "-u", bridge }
end

local function head_capture()
	return state.capture[1]
end

local function mark_head_killed()
	local head = head_capture()
	if head then
		local b = Mgr.registry.by_id[head.block_id]
		if b and b.set_killed then
			b:set_killed()
		end
	end
end

local function clear_queues()
	state.capture = {}
	state.pending = {}
end

local function ensure_block_output(b)
	if not b.output or not b.output.items then
		b.output = {
			exec_count = 0,
			ms = 0,
			items = {},
			max_preview_lines = state.conf.virtual_preview_lines,
		}
	end
end

-- Apply a single JMP item incrementally to a block's output
local function apply_item(b, item)
	ensure_block_output(b)
	local t = item.type

	if t == "clear_output" then
		b.output.items = {}
		return
	end

	-- map update_display_data by transient.display_id
	local transient = item.transient or {}
	local display_id = transient.display_id

	if t == "update_display_data" and display_id then
		for idx, it in ipairs(b.output.items) do
			if it._display_id == display_id then
				b.output.items[idx].data = item.data or b.output.items[idx].data
				b.output.items[idx].metadata = item.metadata or b.output.items[idx].metadata
				return
			end
		end
		t = "display_data"
	end

	if (t == "display_data" or t == "execute_result") and item.data then
		local newit = {
			type = t,
			data = item.data or {},
			metadata = item.metadata or {},
			_display_id = display_id,
		}
		table.insert(b.output.items, newit)
		return
	end

	if t == "stream" then
		table.insert(
			b.output.items,
			{ type = "stream", name = item.name or "stdout", text = item.text or "" }
		)
		return
	end

	if t == "error" then
		table.insert(b.output.items, {
			type = "error",
			ename = item.ename,
			evalue = item.evalue,
			traceback = item.traceback,
		})
		return
	end

	table.insert(b.output.items, item)
end

-- bridge lifecycle
local function on_bridge_msg(msg)
	local typ = msg.type

	if typ == "execute_start" then
		return
	elseif typ == "output" then
		local bid = msg.cell_id
		local b = bid and Mgr.registry.by_id[bid]
		if not b then
			return
		end
		apply_item(b, msg.item or {})
		b:insert_output(b.output)
		return
	elseif typ == "execute_done" then
		local bid = msg.cell_id
		local b = bid and Mgr.registry.by_id[bid]
		-- pop head capture
		table.remove(state.capture, 1)

		if b then
			ensure_block_output(b)
			b.output.exec_count = msg.exec_count or (b.output.exec_count or 0)
			b.output.ms = msg.ms or 0
			-- If bridge sent a one-shot error (no prior streaming), merge those outputs
			if msg.outputs and #msg.outputs > 0 and (#b.output.items == 0) then
				for _, it in ipairs(msg.outputs) do
					apply_item(b, it)
				end
			end
			b:insert_output(b.output)
		elseif typ == "interrupted" then
			-- mark head, but DO NOT pop here.
			local head = state.capture[1]
			if head and msg.cell_id == head.block_id then
				mark_head_killed()
			end
			return
		end

		-- start next pending
		if #state.capture == 0 and #state.pending > 0 then
			local p = table.remove(state.pending, 1)
			table.insert(state.capture, { block_id = p.block_id })
			vim.fn.chansend(state.chan_id, vim.json.encode(p.payload) .. "\n")
		end
		return
	elseif typ == "interrupted" then
		mark_head_killed()
		-- allow next pending to run (drop head)
		table.remove(state.capture, 1)
		if #state.capture == 0 and #state.pending > 0 then
			local p = table.remove(state.pending, 1)
			table.insert(state.capture, { block_id = p.block_id })
			vim.fn.chansend(state.chan_id, vim.json.encode(p.payload) .. "\n")
		end
		return
	elseif typ == "restarted" then
		-- clean queues; mark killed for good UX
		mark_head_killed()
		clear_queues()
		return
	elseif typ == "kernel_dead" or typ == "kernel_error" then
		mark_head_killed()
		clear_queues()
		vim.notify("Jupyter kernel died: " .. (msg.error or typ), vim.log.levels.ERROR)
		return
	end
end

local function handle_stdout_chunk(lines)
	for _, line in ipairs(lines or {}) do
		if line == "" then
			goto continue
		end
		state.json_buf = state.json_buf .. line .. "\n"
		while true do
			local nl = state.json_buf:find("\n", 1, true)
			if not nl then
				break
			end
			local one = state.json_buf:sub(1, nl - 1)
			state.json_buf = state.json_buf:sub(nl + 1)
			if one ~= "" then
				local ok, msg = pcall(vim.json.decode, one)
				if ok and msg then
					on_bridge_msg(msg)
				else
					vim.notify("Bridge decode failed: " .. one, vim.log.levels.WARN)
				end
			end
		end
		::continue::
	end
end

local function ensure_bridge()
	if state.job_id and vim.fn.jobwait({ state.job_id }, 0)[1] == -1 then
		return true
	end
	local cmd = default_bridge_cmd()
	local cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(Mgr.buf or 0), ":p:h")

	local job = vim.fn.jobstart(cmd, {
		cwd = cwd,
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, d, _)
			if d then
				handle_stdout_chunk(d)
			end
		end,
		on_stderr = function(_, d, _)
			if d then
				for _, ln in ipairs(d) do
					if ln ~= "" then
						vim.notify(ln, vim.log.levels.WARN)
					end
				end
			end
		end,
	})

	if job <= 0 then
		vim.notify("Failed to start Jupyter kernel bridge", vim.log.levels.ERROR)
		return false
	end
	state.job_id, state.chan_id = job, job
	state.json_buf = ""
	return true
end

-- ---------- sending ----------

local function send_block(b)
	if not b or b.type ~= "python" then
		return
	end
	if not ensure_bridge() then
		return
	end

	b:set_running()

	local code = table.concat(b:text(), "\n")
	local payload = { type = "execute", cell_id = b.id, code = code }

	if #state.capture > 0 then
		table.insert(state.pending, { block_id = b.id, payload = payload })
		return
	end

	table.insert(state.capture, { block_id = b.id })
	vim.fn.chansend(state.chan_id, vim.json.encode(payload) .. "\n")
end

-- ---------- public API ----------

function E.exec_current()
	local b = Mgr.block_at_cursor()
	if not b then
		return
	end
	send_block(b)
end

function E.exec_all()
	for _, id in ipairs(Mgr.order_list()) do
		local b = Mgr.registry.by_id[id]
		send_block(b)
	end
end

function E.exec_and_next()
	local b = Mgr.block_at_cursor()
	if not b then
		return
	end
	send_block(b)
	local s, _ = b:range()
	local next_b = nil
	for _, id in ipairs(Mgr.order_list()) do
		local bb = Mgr.registry.by_id[id]
		local bs, _ = bb:range()
		if bs > s then
			next_b = bb
			break
		end
	end
	if not next_b then
		next_b = Mgr.new_block_below_from(b)
	end
	if next_b then
		local ns = next_b:range()
		vim.api.nvim_win_set_cursor(0, { ns + 1, 0 })
	end
end

function E.toggle_collapsed_output()
	local b = Mgr.block_at_cursor()
	if not b then
		return
	end
	b:toggle_collapse_output()
end

function E.toggle_showing_full_output()
	local b = Mgr.block_at_cursor()
	if not b then
		return
	end
	if b.toggle_full_output then
		b:toggle_full_output()
	end
end

function E.restart()
	if not ensure_bridge() then
		return
	end
	mark_head_killed()
	clear_queues()
	vim.fn.chansend(state.chan_id, vim.json.encode({ type = "restart" }) .. "\n")
end

function E.restart_and_clear()
	E.restart()
	for _, id in ipairs(Mgr.order_list()) do
		local b = Mgr.registry.by_id[id]
		if b then
			b:clear_output()
		end
	end
end

function E.stop()
	mark_head_killed()
	clear_queues()
	if state.job_id then
		pcall(vim.fn.chanclose, state.chan_id)
		pcall(vim.fn.jobstop, state.job_id)
	end
	state.job_id, state.chan_id = nil, nil
	state.json_buf = ""
end

function E.interrupt()
	if not state.job_id then
		return
	end
	vim.fn.chansend(state.chan_id, vim.json.encode({ type = "interrupt" }) .. "\n")
end

function E.clear_output()
	for _, id in ipairs(Mgr.order_list()) do
		local b = Mgr.registry.by_id[id]
		if b then
			b:clear_output()
		end
	end
end

function E.setup(opts)
	state.conf = vim.tbl_deep_extend("force", state.conf, opts or {})
end

return E
