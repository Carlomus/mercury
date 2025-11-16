local Names = require("mercury.names")
local Block = require("mercury.blocks")
local Util = require("mercury.utils")

local M = {}

-- One state per buffer
-- [bufnr] -> {
--      buf,
--      registry = { by_id = {} },
--      _mark_to_id = {},       -- input extmark id -> block id
--      _out_mark_to_id = {},   -- output extmark id -> block id
--      order = { head, tail, next = {}, prev = {} },
-- }

local STATE = {}

local function curbuf()
	return vim.api.nvim_get_current_buf()
end

local function ensure_state(buf)
	buf = buf or curbuf()
	local S = STATE[buf]
	if not S then
		S = {
			buf = buf,
			registry = { by_id = {} },
			_mark_to_id = {},
			_out_mark_to_id = {},
			order = { head = nil, tail = nil, next = {}, prev = {} },
		}
		STATE[buf] = S
	end
	return S
end

function M.registry_for(buf)
	return ensure_state(buf).registry
end

setmetatable(M, {
	__index = function(_, k)
		if k == "registry" then
			return ensure_state(nil).registry
		elseif k == "buf" then
			return curbuf()
		end
	end,
})

local function emit_blocks_changed(S)
	if not S.buf or not vim.api.nvim_buf_is_loaded(S.buf) then
		return
	end
	vim.schedule(function()
		pcall(
			vim.api.nvim_exec_autocmds,
			"User",
			{ pattern = "NotebookBlocksChanged", modeline = false, data = { buf = S.buf } }
		)
	end)
end

local function order_clear(S)
	S.order.head, S.order.tail = nil, nil
	S.order.next, S.order.prev = {}, {}
end

local function order_insert_after(S, after_id, id)
	local O = S.order
	if not O.head then
		O.head, O.tail = id, id
		return
	end
	if not after_id then
		S.order.prev[O.head] = id
		S.order.next[id] = O.head
		O.head = id
		return
	end
	local nxt = O.next[after_id]
	O.next[after_id] = id
	O.prev[id] = after_id
	if nxt then
		O.next[id] = nxt
		O.prev[nxt] = id
	else
		O.tail = id
	end
end

local function order_remove(S, id)
	local O = S.order
	local p, n = O.prev[id], O.next[id]
	if p then
		O.next[p] = n
	else
		O.head = n
	end
	if n then
		O.prev[n] = p
	else
		O.tail = p
	end
	O.next[id], O.prev[id] = nil, nil
end

local function order_as_list(S)
	local out, id = {}, S.order.head
	while id do
		out[#out + 1] = id
		id = S.order.next[id]
	end
	return out
end

function M.sanitize_headers(buf)
	buf = buf or M.buf
	local S = ensure_state(buf)
	if not S.buf or not vim.api.nvim_buf_is_loaded(S.buf) then
		return
	end

	-- Find all header lines (# %% / # %% [markdown] etc.)
	local headers = {}
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i, line in ipairs(lines) do
		if Util.is_py_cell_start(line) then
			headers[#headers + 1] = i - 1 -- 0-based row
		end
	end

	if #headers == 0 then
		return
	end

	table.sort(headers, function(a, b)
		return a > b
	end)

	for _, row in ipairs(headers) do
		pcall(vim.api.nvim_buf_set_lines, buf, row, row + 1, false, {})
	end

	M.reflow_all(buf)
end

local function register_block(S, b, insert_after_id)
	S.registry.by_id[b.id] = b
	S._mark_to_id[b.input_mark] = b.id
	if b.output_mark then
		S._out_mark_to_id[b.output_mark] = b.id
	end
	order_insert_after(S, insert_after_id, b.id)
end

local function unregister_block(S, b)
	S._mark_to_id[b.input_mark] = nil
	if b.output_mark then
		S._out_mark_to_id[b.output_mark] = nil
	end
	S.registry.by_id[b.id] = nil
	order_remove(S, b.id)
end

local function prev_block_of(S, b)
	local pid = S.order.prev[b.id]
	return pid and S.registry.by_id[pid] or nil
end

local function next_block_of(S, b)
	local nid = S.order.next[b.id]
	return nid and S.registry.by_id[nid] or nil
end

-- Turn current block structure into py:percent lines for Jupytext encode
-- IMPORTANT: we only serialize INPUT, never runtime outputs.
function M.materialize_pypercent(buf)
	buf = buf or M.buf
	local out = {}
	for _, id in ipairs(M.order_list(buf)) do
		local b = M.registry.by_id[id]
		local s, e = b:input_range()
		local header = (b.type == "markdown") and "# %% [markdown]" or "# %%"
		table.insert(out, header)
		local body = vim.api.nvim_buf_get_lines(buf, s, e, false)
		for i = 1, #body do
			out[#out + 1] = body[i]
		end
		if #out > 0 and out[#out] ~= "" then
			out[#out + 1] = ""
		end
	end
	return out
end

-- ----- low-level buffer queries ----------------------------------------------
local function block_at_row(S, row)
	if not S.buf then
		return nil
	end

	-- First, try input extmarks (normal case: cursor in input).
	local got = vim.api.nvim_buf_get_extmarks(
		S.buf,
		Names.blocks,
		{ row, 0 },
		{ row, 0 },
		{ details = true, overlap = true, limit = 1 }
	)
	if #got > 0 then
		local mark = got[1][1]
		local id = S._mark_to_id[mark]
		if id and S.registry.by_id[id] then
			return S.registry.by_id[id]
		end
	end

	-- If none, treat clicks in the output region as inside the cell:
	local got_out = vim.api.nvim_buf_get_extmarks(
		S.buf,
		Names.blocks_output,
		{ row, 0 },
		{ row, 0 },
		{ details = true, overlap = true, limit = 1 }
	)
	if #got_out > 0 then
		local mark = got_out[1][1]
		local id = S._out_mark_to_id[mark]
		if id and S.registry.by_id[id] then
			return S.registry.by_id[id]
		end
	end

	return nil
end

function M.block_covering(sr, er, buf)
	local S = ensure_state(buf)
	local b = block_at_row(S, sr)
	if not b then
		return nil
	end
	local s, e = b:range()
	return (sr >= s and er <= e) and b or nil
end

-- ----- header scanning --------------------------------------------------------
local function compute_headers(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local headers = {}
	for i = 1, #lines do
		local line = lines[i]
		if Util.is_py_cell_start(line) then
			headers[#headers + 1] = {
				header_row = i - 1,
				type = Util.parse_header(line),
				header_text = line,
			}
		end
	end
	return headers
end

local function pairs_from_headers(buf, headers)
	local pairs_ = {}
	local n = vim.api.nvim_buf_line_count(buf) -- end-exclusive top
	for i, h in ipairs(headers) do
		local content_start = h.header_row + 1
		local e = (i < #headers) and headers[i + 1].header_row or n
		pairs_[#pairs_ + 1] = {
			s = content_start,
			e = e,
			type = h.type,
			header_row = h.header_row,
			header_text = h.header_text,
		}
	end
	return pairs_
end

local function strip_headers(buf, pairs)
	for _, p in ipairs(pairs) do
		local line = Util.getline(buf, p.header_row)
		if Util.is_py_cell_start(line) then
			pcall(vim.api.nvim_buf_set_lines, buf, p.header_row, p.header_row + 1, false, {})
		end
	end
end

local function rebuild_order_from_extmarks(S)
	order_clear(S)
	local marks = vim.api.nvim_buf_get_extmarks(S.buf, Names.blocks, 0, -1, {})
	for _, m in ipairs(marks) do
		local id = S._mark_to_id[m[1]]
		if id and S.registry.by_id[id] then
			order_insert_after(S, S.order.tail, id)
		end
	end
end

-- ----- Public API -------------------------------------------------------------
function M.scan_initial(buf)
	local S = ensure_state(buf)
	S.registry.by_id = {}
	S._mark_to_id = {}
	S._out_mark_to_id = {}
	order_clear(S)

	local headers = compute_headers(S.buf)
	if #headers == 0 then
		local last = vim.api.nvim_buf_line_count(S.buf)
		local id = Util.new_ID()
		local blk = Block.new(S.buf, 0, last, id, "python", "# %%")
		register_block(S, blk, S.order.tail)
		emit_blocks_changed(S)
		return
	end

	local pairs = pairs_from_headers(S.buf, headers)
	for _, hdr in ipairs(pairs) do
		local id = Util.new_ID()
		local blk = Block.new(S.buf, hdr.s, hdr.e, id, hdr.type, hdr.header_text)
		register_block(S, blk, S.order.tail)
	end

	strip_headers(S.buf, pairs)
	emit_blocks_changed(S)
end

function M.reflow_all(buf)
	local S = ensure_state(buf)
	if not S.buf or not vim.api.nvim_buf_is_loaded(S.buf) then
		return
	end

	local items = {}
	local marks = vim.api.nvim_buf_get_extmarks(S.buf, Names.blocks, 0, -1, { details = true })
	for _, m in ipairs(marks) do
		local id = S._mark_to_id[m[1]]
		local b = id and S.registry.by_id[id] or nil
		if b then
			local s, e = b:input_range()
			items[#items + 1] = { id = id, s = s, e = e }
		end
	end
	if #items == 0 then
		return
	end

	local changed = false
	do
		local i, id = 1, S.order.head
		while id and i <= #items do
			if id ~= items[i].id then
				changed = true
				break
			end
			id, i = S.order.next[id], i + 1
		end
		if id or i <= #items then
			changed = true
		end
	end
	if changed then
		rebuild_order_from_extmarks(S)
	end

	-- Keep same “normalization” semantics as before but only for input spans.
	local nlines = vim.api.nvim_buf_line_count(S.buf)

	for i = 2, #items do
		if items[i].s <= items[i - 1].s then
			local b = S.registry.by_id[items[i].id]
			items[i].s = items[i - 1].s + 1
			if b then
				b:set_input_span(items[i].s, items[i].e)
			end
		end
	end

	for i = 1, #items do
		local next_s = items[i + 1] and items[i + 1].s or nlines
		local want_e = math.min(items[i].e, next_s - 1)
		if want_e < items[i].s then
			want_e = items[i].s
		end
		if want_e ~= items[i].e then
			local b = S.registry.by_id[items[i].id]
			items[i].e = want_e
			if b then
				b:set_input_span(items[i].s, items[i].e)
			end
		end
	end

	for _, it in ipairs(items) do
		local b = S.registry.by_id[it.id]
		if b and b.sync_decorations then
			b:sync_decorations()
		end
	end

	emit_blocks_changed(S)
end

-- Operations ------------------------------------------------------------------

local function insert_blank_lines_at(S, row, count)
	row = math.max(0, row or 0)
	count = math.max(1, count or 1)
	local blanks = {}
	for i = 1, count do
		blanks[i] = ""
	end
	return pcall(vim.api.nvim_buf_set_lines, S.buf, row, row, false, blanks)
end

function M.new_block_above(buf)
	local S = ensure_state(buf)
	local cur = M.block_at_cursor(S.buf)
	if not cur then
		return
	end
	local s_in, e_in = cur:input_range()

	insert_blank_lines_at(S, s_in, 2)
	cur:set_input_span(s_in + 2, e_in + 2)

	local nid = Util.new_ID()
	local nb = Block.new(S.buf, s_in, s_in + 1, nid, "python", "# %%")

	local prev_id = S.order.prev[cur.id]
	register_block(S, nb, prev_id)

	nb:show_header_virtual()
	nb:sync_decorations()

	M.reflow_all(S.buf)
	local ns = nb:input_range()
	vim.api.nvim_win_set_cursor(0, { ns + 1, 0 })
end

function M.new_block_below_from(b)
	if not b then
		return M.new_block_below(nil)
	end
	local S = ensure_state(b.buf)
	local _, e_full = b:range()

	insert_blank_lines_at(S, e_full, 2)

	local nid = Util.new_ID()
	local nb = Block.new(S.buf, e_full + 1, e_full + 2, nid, "python", "# %%")

	register_block(S, nb, b.id)

	nb:show_header_virtual()
	nb:sync_decorations()

	M.reflow_all(S.buf)
	return nb
end

function M.new_block_below(buf)
	local S = ensure_state(buf)
	local b = M.block_at_cursor(S.buf)
	if not b then
		return
	end
	local _, e_full = b:range()

	insert_blank_lines_at(S, e_full, 2)

	local nid = Util.new_ID()
	local nb = Block.new(S.buf, e_full + 1, e_full + 2, nid, "python", "# %%")

	register_block(S, nb, b.id)

	nb:show_header_virtual()
	nb:sync_decorations()

	M.reflow_all(S.buf)
	return nb
end

function M.delete_block(buf)
	local S = ensure_state(buf)
	local b = M.block_at_cursor(S.buf)
	if not b then
		return
	end

	local prev, nextb = prev_block_of(S, b), next_block_of(S, b)
	local s, e = b:range()
	e = e + 1

	unregister_block(S, b)
	pcall(vim.api.nvim_buf_set_lines, S.buf, s, e, false, {})
	b:destroy()

	if prev and prev.sync_decorations then
		prev:sync_decorations()
	end
	if nextb and nextb.sync_decorations then
		nextb:sync_decorations()
	end

	M.reflow_all(S.buf)
end

function M.merge_below(buf)
	local S = ensure_state(buf)
	local b1 = M.block_at_cursor(S.buf)
	if not b1 then
		return
	end
	local b2 = next_block_of(S, b1)
	if not b2 then
		return
	end

	local _, b2_in_e = b2:input_range()
	local b2_in_s, _ = b2:input_range()
	local b2_in_lines = vim.api.nvim_buf_get_lines(S.buf, b2_in_s, b2_in_e, false)

	-- Append b2 input into b1 input
	local b1_in_s, b1_in_e = b1:input_range()
	vim.api.nvim_buf_set_lines(S.buf, b1_in_e, b1_in_e, false, b2_in_lines)
	b1:set_input_span(b1_in_s, b1_in_e + #b2_in_lines)

	-- Remove entire b2 (input + output)
	local s2_full, e2_full = b2:range()
	unregister_block(S, b2)
	b2:destroy()
	pcall(vim.api.nvim_buf_set_lines, S.buf, s2_full, e2_full, false, {})

	b1:sync_decorations()
	M.reflow_all(S.buf)
end

function M.select_block(buf)
	local S = ensure_state(buf)
	local b = M.block_at_cursor(S.buf)
	if not b then
		return
	end
	local s, e = b:input_range()
	local last = math.max(s, e - 1)
	vim.api.nvim_win_set_cursor(0, { s + 1, 0 })
	vim.cmd("normal! V")
	vim.api.nvim_win_set_cursor(0, { last + 1, 0 })
end

function M.set_block_type(t, buf)
	local S = ensure_state(buf)
	local b = M.block_at_cursor(S.buf)
	if not b then
		return
	end
	b:set_type(t == "markdown" and "markdown" or "python")
	b:sync_decorations()
	emit_blocks_changed(S)
end

-- Encoding / queries ----------------------------------------------------------

function M.block_at_cursor(buf)
	local S = ensure_state(buf)
	local row = (vim.api.nvim_win_get_cursor(0)[1] - 1)
	return block_at_row(S, row)
end

function M.order_list(buf)
	return order_as_list(ensure_state(buf))
end

return M
