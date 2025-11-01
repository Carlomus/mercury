local Names = require("mercury.lua.names")
local Block = require("mercury.lua.blocks")
local Util = require("mercury.lua.utils")

local M = {}

M.registry = { by_id = {}, order = {} }
M.buf = nil
M._mutating = false

M._id_to_index = {}
M._mark_to_id = {}

-- ---------------- internal helpers ----------------

local function emit_blocks_changed()
	if not M.buf or not vim.api.nvim_buf_is_loaded(M.buf) then
		return
	end
	vim.schedule(function()
		pcall(
			vim.api.nvim_exec_autocmds,
			"User",
			{ pattern = "NotebookBlocksChanged", modeline = false }
		)
	end)
end

local function reindex_order()
	local t = {}
	for i, id in ipairs(M.registry.order) do
		t[id] = i
	end
	M._id_to_index = t
end

local function register_block(b, at_index)
	if at_index then
		table.insert(M.registry.order, at_index, b.id)
	else
		M.registry.order[#M.registry.order + 1] = b.id
	end
	M.registry.by_id[b.id] = b
	M._mark_to_id[b.mark] = b.id
	reindex_order()
end

local function unregister_block(b)
	M._mark_to_id[b.mark] = nil
	M.registry.by_id[b.id] = nil
	local idx = M._id_to_index[b.id]
	if idx then
		table.remove(M.registry.order, idx)
	end
	reindex_order()
end

local function ordered_ids_by_extmarks()
	if not M.buf then
		return {}
	end
	local ids = {}
	local marks = vim.api.nvim_buf_get_extmarks(M.buf, Names.blocks, 0, -1, {})
	for _, m in ipairs(marks) do
		local mark_id = m[1]
		local id = M._mark_to_id[mark_id]
		if id and M.registry.by_id[id] then
			ids[#ids + 1] = id
		end
	end
	return ids
end

local function block_index(id)
	return M._id_to_index[id]
end

local function prev_block_of(b)
	local i = M._id_to_index[b.id]
	if not i or i <= 1 then
		return nil
	end
	return M.registry.by_id[M.registry.order[i - 1]]
end

local function next_block_of(b)
	local i = M._id_to_index[b.id]
	if not i then
		return nil
	end
	local nid = M.registry.order[i + 1]
	return nid and M.registry.by_id[nid] or nil
end

local function insert_blank_lines_at(row, count)
	row = math.max(0, row or 0)
	count = math.max(1, count or 1)
	local blanks = {}
	for i = 1, count do
		blanks[i] = ""
	end
	return pcall(vim.api.nvim_buf_set_lines, M.buf, row, row, false, blanks)
end

local function dedupe_order()
	local seen, uniq = {}, {}
	for _, id in ipairs(M.registry.order) do
		if (not seen[id]) and M.registry.by_id[id] ~= nil then
			seen[id] = true
			uniq[#uniq + 1] = id
		end
	end
	M.registry.order = uniq
	reindex_order()
end

local function reorder_by_extmarks()
	M.registry.order = ordered_ids_by_extmarks()
	reindex_order()
end

local function block_at_row(row)
	if not M.buf then
		return nil
	end
	local got = vim.api.nvim_buf_get_extmarks(
		M.buf,
		Names.blocks,
		{ row, 0 },
		{ row, 0 },
		{ details = true, overlap = true, limit = 1 }
	)
	if #got == 0 then
		return nil
	end
	local mark = got[1][1]
	local id = M._mark_to_id[mark]
	return id and M.registry.by_id[id] or nil
end

function M.block_covering(sr, er)
	local b = block_at_row(sr)
	if not b then
		return nil
	end
	local s, e = b:range()
	if sr >= s and er <= e then
		return b
	end
	return nil
end

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
	local n = vim.api.nvim_buf_line_count(buf)
	for i, h in ipairs(headers) do
		local content_start = h.header_row + 1
		local e = (i < #headers) and (headers[i + 1].header_row - 1) or (n - 1)
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

local function virtualize_headers(buf, pairs)
	table.sort(pairs, function(a, b)
		return a.header_row > b.header_row
	end)
	for _, p in ipairs(pairs) do
		local line = Util.getline(buf, p.header_row)
		if Util.is_py_cell_start(line) then
			pcall(vim.api.nvim_buf_set_lines, buf, p.header_row, p.header_row + 1, false, {})
		end
	end
end

function M.scan_initial(buf)
	M.buf = buf or 0
	local headers = compute_headers(M.buf)

	if #headers == 0 then
		local last = math.max(0, vim.api.nvim_buf_line_count(M.buf) - 1)
		local id = Util.new_ID()
		local blk = Block.new(M.buf, 0, last, id, "python", nil, "# %%")
		register_block(blk)
		emit_blocks_changed()
		return
	end

	local pairs = pairs_from_headers(M.buf, headers)
	for _, p in ipairs(pairs) do
		local id = Util.new_ID()
		local blk = Block.new(M.buf, p.s, p.e, id, p.type, nil, p.header_text)
		register_block(blk)
	end

	virtualize_headers(M.buf, pairs)
	emit_blocks_changed()
end

-- Normalizer
function M.reflow_all()
	if not M.buf or not vim.api.nvim_buf_is_loaded(M.buf) then
		return
	end
	dedupe_order()

	-- Build items from extmarks (already sorted by position)
	local items = {}
	local marks = vim.api.nvim_buf_get_extmarks(M.buf, Names.blocks, 0, -1, { details = true })
	for _, m in ipairs(marks) do
		local mark_id = m[1]
		local id = M._mark_to_id[mark_id]
		local b = id and M.registry.by_id[id] or nil
		if b then
			local s, e = b:range()
			items[#items + 1] = { id = id, s = s, e = e }
		end
	end
	if #items == 0 then
		return
	end

	-- If extmark order differs from registry order, adopt it
	local changed_order = (#items ~= #M.registry.order)
	if not changed_order then
		for i = 1, #items do
			if M.registry.order[i] ~= items[i].id then
				changed_order = true
				break
			end
		end
	end
	if changed_order then
		local new_order = {}
		for i = 1, #items do
			new_order[i] = items[i].id
		end
		M.registry.order = new_order
		reindex_order()
	end

	-- Ensure starts are strictly increasing
	for i = 2, #items do
		if items[i].s <= items[i - 1].s then
			local b = M.registry.by_id[items[i].id]
			items[i].s = items[i - 1].s + 1
			if b then
				b:set_span(items[i].s, items[i].e)
			end
		end
	end

	-- Clamp ends to next start - 1 (and to buffer size)
	local nlines = vim.api.nvim_buf_line_count(M.buf)
	for i = 1, #items do
		local next_s = items[i + 1] and items[i + 1].s or nlines
		local want_e = math.min(items[i].e, next_s - 1)
		if want_e < items[i].s then
			want_e = items[i].s
		end
		if want_e ~= items[i].e then
			local b = M.registry.by_id[items[i].id]
			items[i].e = want_e
			if b then
				b:set_span(items[i].s, items[i].e)
			end
		end
	end

	-- Refresh visuals
	for _, it in ipairs(items) do
		local b = M.registry.by_id[it.id]
		if b and b.sync_decorations then
			b:sync_decorations()
		end
	end

	emit_blocks_changed()
end

-- Operations
function M.new_block_above()
	if not M.buf then
		return
	end
	local cur = M.block_at_cursor()
	if not cur then
		return
	end
	local s, e = cur:range()

	M._mutating = true
	insert_blank_lines_at(s, 2)
	cur:set_span(s + 2, e + 2)

	local nid = Util.new_ID()
	local nb = Block.new(M.buf, s, s + 1, nid, "python", nil, "# %%")
	local idx = (block_index(cur.id) or 1)
	register_block(nb, idx)

	nb:show_header_virtual()
	nb:sync_decorations()
	M._mutating = false

	M.reflow_all()
	local ns = nb:range()
	vim.api.nvim_win_set_cursor(0, { ns + 1, 0 })
end

function M.new_block_below_from(b)
	b = b or M.block_at_cursor()
	if not b then
		return
	end
	local s, e = b:range()

	M._mutating = true
	insert_blank_lines_at(e, 2)
	b:set_span(s, e)

	local nid = Util.new_ID()
	local nb = Block.new(M.buf, e + 1, e + 2, nid, "python", nil, "# %%")

	local idx = (block_index(b.id) or #M.registry.order) + 1
	register_block(nb, idx)

	nb:show_header_virtual()
	nb:sync_decorations()
	M._mutating = false

	M.reflow_all()
	return nb
end

function M.new_block_below()
	return M.new_block_below_from(nil)
end

function M.delete_block()
	if not M.buf then
		return
	end
	local b = M.block_at_cursor()
	if not b then
		return
	end

	local prev, nextb = prev_block_of(b), next_block_of(b)
	local s, e = b:range()
	e = e + 1

	unregister_block(b)

	M._mutating = true
	pcall(vim.api.nvim_buf_set_lines, M.buf, s, e, false, {})
	if prev and nextb then
		if prev.set_end_row_exclusive then
			prev:set_end_row_exclusive(s)
		end
	elseif prev and prev.set_end_row_exclusive then
		prev:set_end_row_exclusive(s)
	end
	b:destroy()
	if prev and prev.sync_decorations then
		prev:sync_decorations()
	end
	if nextb and nextb.sync_decorations then
		nextb:sync_decorations()
	end
	M._mutating = false

	M.reflow_all()
end

function M.merge_below()
	local b1 = M.block_at_cursor()
	if not b1 then
		return
	end
	local b2 = next_block_of(b1)
	if not b2 then
		return
	end

	local _, e2 = b2:range()
	local out = b2.output

	b1:set_end_row_exclusive(e2)
	unregister_block(b2)
	b2:destroy()

	if out then
		b1:insert_output(out)
	end
	b1:sync_decorations()

	M.reflow_all()
end

function M.select_block()
	local b = M.block_at_cursor()
	if not b then
		return
	end
	local s, e = b:range()
	local last = math.max(s, e - 1)
	vim.api.nvim_win_set_cursor(0, { s + 1, 0 })
	vim.cmd("normal! V")
	vim.api.nvim_win_set_cursor(0, { last + 1, 0 })
end

function M.set_block_type(t)
	local b = M.block_at_cursor()
	if not b then
		return
	end
	b:set_type(t == "markdown" and "markdown" or "python")
	b:sync_decorations()
	emit_blocks_changed()
end

-- Encoding
function M.block_at_cursor()
	local row = (vim.api.nvim_win_get_cursor(0)[1] - 1)
	return block_at_row(row)
end

function M.materialize_pypercent()
	local lines_out = {}
	reorder_by_extmarks()
	for _, id in ipairs(M.registry.order) do
		local b = M.registry.by_id[id]
		lines_out[#lines_out + 1] = b.header_text
		local s, e = b:range()
		local body = vim.api.nvim_buf_get_lines(M.buf, s, e, false)
		for _, ln in ipairs(body) do
			lines_out[#lines_out + 1] = ln
		end
	end
	return lines_out
end

return M
