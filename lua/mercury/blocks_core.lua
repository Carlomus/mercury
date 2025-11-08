local Names = require("mercury.names")

local marks_config = function(end_row)
	return {
		end_row = end_row,
		end_col = 0,
		right_gravity = false,
		end_right_gravity = true,
	}
end

local header_config = function(header_text)
	return {
		virt_lines = { { { header_text, "Comment" } } },
		virt_lines_above = true,
		hl_mode = "combine",
		right_gravity = false,
	}
end

local Block = {}

function Block.new(buf, start_row, end_row, id, type_, header_text)
	if end_row < start_row then
		end_row = start_row
	end
	local mark =
		vim.api.nvim_buf_set_extmark(buf, Names.blocks, start_row, 0, marks_config(end_row))

	local self = setmetatable({
		id = id,
		buf = buf,
		mark = mark,
		type = type_ or "python",
		header_text = header_text or (type_ == "markdown" and "# %% [markdown] " or "# %%"),
		header_virt_mark = nil,
		tail_mark = nil, -- anchor used by output module
		_bg = nil,
	}, Block)

	self:_ensure_tail_anchor()
	self:show_header_virtual()

	return self
end

function Block:range()
	local pos =
		vim.api.nvim_buf_get_extmark_by_id(self.buf, Names.blocks, self.mark, { details = true })
	local sr = (pos and pos[1]) or 0
	local details = pos and pos[3] or nil
	local er = (details and details.end_row) or sr
	return sr, er
end

function Block:_tail_row()
	local s, e = self:range()
	return math.max(s, e)
end

function Block:_ensure_tail_anchor()
	local row = self:_tail_row()
	local cfg = { right_gravity = false, hl_mode = "combine" }
	if self.tail_mark then
		cfg.id = self.tail_mark
	end
	self.tail_mark = vim.api.nvim_buf_set_extmark(self.buf, Names.preview, row, 0, cfg)
end

function Block:text()
	local s, e = self:range()
	return vim.api.nvim_buf_get_lines(self.buf, s, e, false)
end

function Block:set_end_row(e_excl)
	local s, _ = self:range()
	local n = vim.api.nvim_buf_line_count(self.buf)
	local e = math.min(e_excl, n)
	vim.api.nvim_buf_set_extmark(self.buf, Names.blocks, s, 0, {
		id = self.mark,
		end_row = e,
		end_col = 0,
		right_gravity = false,
		end_right_gravity = true,
	})
	self:_ensure_tail_anchor()
	self:sync_decorations()
end

function Block:set_type(new_t)
	self.type = new_t
	self.header_text = (new_t == "markdown") and "# %% [markdown] " or "# %%"
	self:show_header_virtual()
	local group = (self.type == "markdown") and "NotebookMarkdownBlock" or "NotebookPythonBlock"
	self:set_highlight(group)
end

function Block:show_header_virtual()
	if self.header_virt_mark then
		pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.headers, self.header_virt_mark)
		self.header_virt_mark = nil
	end
	local s, _ = self:range()
	self.header_virt_mark =
		vim.api.nvim_buf_set_extmark(self.buf, Names.headers, s, 0, header_config(self.header_text))
end

function Block:set_highlight(group)
	local s, e = self:range()
	local count = e - s
	self._bg = self._bg or { group = nil, s = nil, e = nil, marks = {} }
	local st = self._bg

	if st.group == group and st.s == s and st.e == e then
		return
	end

	local have = #st.marks

	for i = 1, count do
		local row = s + (i - 1)
		local id = st.marks[i]
		st.marks[i] = vim.api.nvim_buf_set_extmark(self.buf, Names.block_cols, row, 0, {
			id = id,
			line_hl_group = group,
			hl_mode = "combine",
			priority = 10,
		})
	end

	for j = have, count + 1, -1 do
		local id = st.marks[j]
		if id then
			pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.block_cols, id)
		end
		st.marks[j] = nil
	end

	st.group, st.s, st.e = group, s, e
end

function Block:sync_decorations()
	local s, _ = self:range()

	if self.header_virt_mark then
		local cfg = {
			virt_lines = { { { self.header_text, "Comment" } } },
			virt_lines_above = true,
			hl_mode = "combine",
			right_gravity = false,
			id = self.header_virt_mark,
		}
		pcall(vim.api.nvim_buf_set_extmark, self.buf, Names.headers, s, 0, cfg)
	end

	self:_ensure_tail_anchor()

	local group = (self.type == "markdown") and "NotebookMarkdownBlock" or "NotebookPythonBlock"
	self:set_highlight(group)
end

function Block:set_span(new_s, new_e)
	local n = vim.api.nvim_buf_line_count(self.buf)
	new_s = math.max(0, math.min(new_s or 0, n))
	new_e = math.max(new_s, math.min(new_e or new_s, n))

	local cfg = marks_config(new_e)
	cfg.id = self.mark
	vim.api.nvim_buf_set_extmark(self.buf, Names.blocks, new_s, 0, cfg)
	self:sync_decorations()
end

function Block:destroy()
	pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.blocks, self.mark)
	if self.tail_mark then
		pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.preview, self.tail_mark)
	end
	if self.header_virt_mark then
		pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.headers, self.header_virt_mark)
	end
	if self._bg and self._bg.marks then
		for _, id in ipairs(self._bg.marks) do
			pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.block_cols, id)
		end
	end
	self._bg = nil
end

return Block
