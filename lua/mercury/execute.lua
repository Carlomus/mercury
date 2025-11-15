local Mgr = require("mercury.manager")
local Kern = require("mercury.kernels")

local E = {}

local CONF = {
	show_virtual_preview = true,
	virtual_preview_lines = 12,
}

-- Per-buffer state:
-- STATE[bufnr] = {
--   buf = bufnr,
--   job_id = nil,
--   chan_id = nil,
--   capture = {},
--   pending = {},
--   json_buf = "",
-- }
local STATE = {}

-- Map job_id → bufnr so callbacks can find the right buffer
local JOB_TO_BUF = {}

local function curbuf()
	return vim.api.nvim_get_current_buf()
end

local function get_buf_state(bufnr)
	local buf = bufnr or curbuf()
	local S = STATE[buf]
	if not S then
		S = {
			buf = buf,
			job_id = nil,
			chan_id = nil,
			capture = {},
			pending = {},
			json_buf = "",
		}
		STATE[buf] = S
	end
	return S
end

local function head_capture(S)
	return S.capture[1]
end

local function mark_head_killed(S)
	local head = head_capture(S)
	if head then
		local reg = Mgr.registry_for(S.buf)
		local b = reg.by_id[head.block_id]
		if b and b.set_killed then
			b:set_killed()
		end
	end
end

local function clear_queues(S)
	S.capture = {}
	S.pending = {}
end

local function ensure_block_output(b)
	if not b.output or not b.output.items then
		b.output = {
			exec_count = 0,
			ms = 0,
			items = {},
			max_preview_lines = CONF.virtual_preview_lines,
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

local function on_bridge_msg(bufnr, msg)
	local S = get_buf_state(bufnr)
	local reg = Mgr.registry_for(bufnr)
	local typ = msg.type

	if typ == "execute_start" then
		return
	elseif typ == "output" then
		local bid = msg.cell_id
		local b = bid and reg.by_id[bid]
		if not b then
			return
		end
		apply_item(b, msg.item or {})
		b:insert_output(b.output)
		return
	elseif typ == "execute_done" then
		local bid = msg.cell_id
		local b = bid and reg.by_id[bid]
		-- pop head capture
		table.remove(S.capture, 1)

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
		end

		-- start next pending
		if #S.capture == 0 and #S.pending > 0 then
			local p = table.remove(S.pending, 1)
			table.insert(S.capture, { block_id = p.block_id })
			vim.fn.chansend(S.chan_id, vim.json.encode(p.payload) .. "\n")
		end
		return
	elseif typ == "interrupted" then
		-- mark head, but DO NOT pop here – then allow next pending
		local head = S.capture[1]
		if head and msg.cell_id == head.block_id then
			local b = reg.by_id[head.block_id]
			if b and b.set_killed then
				b:set_killed()
			end
		end
		table.remove(S.capture, 1)
		if #S.capture == 0 and #S.pending > 0 then
			local p = table.remove(S.pending, 1)
			table.insert(S.capture, { block_id = p.block_id })
			vim.fn.chansend(S.chan_id, vim.json.encode(p.payload) .. "\n")
		end
		return
	elseif typ == "restarted" then
		-- clean queues; mark killed for good UX
		mark_head_killed(S)
		clear_queues(S)
		return
	elseif typ == "kernel_dead" or typ == "kernel_error" then
		mark_head_killed(S)
		clear_queues(S)
		vim.notify("Jupyter kernel died: " .. (msg.error or typ), vim.log.levels.ERROR)
		-- mark bridge as gone; ensure_bridge will recreate
		if S.job_id then
			JOB_TO_BUF[S.job_id] = nil
		end
		S.job_id, S.chan_id = nil, nil
		return
	end
end

local function handle_stdout_chunk(bufnr, lines)
	local S = get_buf_state(bufnr)
	for _, line in ipairs(lines or {}) do
		if line == "" then
			goto continue
		end
		S.json_buf = S.json_buf .. line .. "\n"
		while true do
			local nl = S.json_buf:find("\n", 1, true)
			if not nl then
				break
			end
			local one = S.json_buf:sub(1, nl - 1)
			S.json_buf = S.json_buf:sub(nl + 1)
			if one ~= "" then
				local ok, msg = pcall(vim.json.decode, one)
				if ok and msg then
					on_bridge_msg(bufnr, msg)
				else
					vim.notify("Bridge decode failed: " .. one, vim.log.levels.WARN)
				end
			end
		end
		::continue::
	end
end

local function ensure_bridge(bufnr)
	local S = get_buf_state(bufnr)
	if S.job_id and vim.fn.jobwait({ S.job_id }, 0)[1] == -1 then
		return true
	end

	local cmd = Kern.default_bridge_cmd()
	if not cmd then
		return false
	end

	local cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(S.buf or 0), ":p:h")
	if cwd == "" then
		cwd = nil
	end

	local job = vim.fn.jobstart(cmd, {
		cwd = cwd,
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(job_id, d, _)
			if d then
				local buf = JOB_TO_BUF[job_id]
				if buf then
					handle_stdout_chunk(buf, d)
				end
			end
		end,
		on_stderr = function(job_id, d, _)
			if d then
				for _, ln in ipairs(d) do
					if ln ~= "" then
						local buf = JOB_TO_BUF[job_id]
						local prefix = buf and ("[buf " .. buf .. "] ") or ""
						vim.notify(prefix .. ln, vim.log.levels.WARN)
					end
				end
			end
		end,
	})

	if job <= 0 then
		vim.notify("Failed to start Jupyter kernel bridge", vim.log.levels.ERROR)
		return false
	end

	S.job_id, S.chan_id = job, job
	S.json_buf = ""
	JOB_TO_BUF[job] = S.buf
	return true
end

local function send_block(b)
	if not b or b.type ~= "python" then
		return
	end

	local buf = b.buf
	local S = get_buf_state(buf)

	if not ensure_bridge(buf) then
		return
	end

	b:set_running()

	local code = table.concat(b:text(), "\n")
	local payload = { type = "execute", cell_id = b.id, code = code }

	if #S.capture > 0 then
		table.insert(S.pending, { block_id = b.id, payload = payload })
		return
	end

	table.insert(S.capture, { block_id = b.id })
	vim.fn.chansend(S.chan_id, vim.json.encode(payload) .. "\n")
end

function E.exec_current()
	local b = Mgr.block_at_cursor()
	if not b then
		return
	end
	send_block(b)
end

function E.exec_all()
	local buf = curbuf()
	for _, id in ipairs(Mgr.order_list(buf)) do
		local reg = Mgr.registry_for(buf)
		local b = reg.by_id[id]
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
	local buf = b.buf
	for _, id in ipairs(Mgr.order_list(buf)) do
		local reg = Mgr.registry_for(buf)
		local bb = reg.by_id[id]
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
	local buf = curbuf()
	local S = get_buf_state(buf)
	if not ensure_bridge(buf) then
		return
	end
	mark_head_killed(S)
	clear_queues(S)
	vim.fn.chansend(S.chan_id, vim.json.encode({ type = "restart" }) .. "\n")
end

function E.restart_and_clear()
	E.restart()
	local buf = curbuf()
	for _, id in ipairs(Mgr.order_list(buf)) do
		local reg = Mgr.registry_for(buf)
		local b = reg.by_id[id]
		if b then
			b:clear_output()
		end
	end
end

function E.stop()
	local buf = curbuf()
	local S = get_buf_state(buf)
	mark_head_killed(S)
	clear_queues(S)
	if S.job_id then
		pcall(vim.fn.chanclose, S.chan_id)
		pcall(vim.fn.jobstop, S.job_id)
		JOB_TO_BUF[S.job_id] = nil
	end
	S.job_id, S.chan_id = nil, nil
	S.json_buf = ""
end

function E.interrupt()
	local buf = curbuf()
	local S = get_buf_state(buf)
	if not S.job_id then
		return
	end
	vim.fn.chansend(S.chan_id, vim.json.encode({ type = "interrupt" }) .. "\n")
end

function E.clear_output()
	local buf = curbuf()
	for _, id in ipairs(Mgr.order_list(buf)) do
		local reg = Mgr.registry_for(buf)
		local b = reg.by_id[id]
		if b then
			b:clear_output()
		end
	end
end

function E.setup(opts)
	CONF = vim.tbl_deep_extend("force", CONF, opts or {})
end

return E
