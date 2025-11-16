local Names = require("mercury.names")

local Block = {}
Block.__index = Block

local function input_mark_cfg(row)
	return {
		end_row = row,
		end_col = 0,
		right_gravity = false,
		-- When inserting at the end of the input region, let the end move down
		end_right_gravity = true,
	}
end

local function output_mark_cfg(row)
	return {
		end_row = row,
		end_col = 0,
		-- Output extmarks should move down when text is inserted before them
		right_gravity = true,
		end_right_gravity = true,
	}
end

local function header_config(header_text)
	return {
		virt_lines = { { { header_text, "Comment" } } },
		virt_lines_above = true,
		hl_mode = "combine",
		right_gravity = false,
	}
end

function Block.new(buf, start_row, end_row, id, type_, header_text)
	if end_row < start_row then
		end_row = start_row
	end
	if end_row < start_row + 1 then
		end_row = start_row + 1
	end

	-- INPUT region extmark
	local input_mark =
		vim.api.nvim_buf_set_extmark(buf, Names.blocks, start_row, 0, input_mark_cfg(end_row))

	-- OUTPUT region extmark: initially empty, placed immediately after input.
	local output_mark =
		vim.api.nvim_buf_set_extmark(buf, Names.blocks_output, end_row, 0, output_mark_cfg(end_row))

	local self = setmetatable({
		id = id,
		buf = buf,
		type = type_ or "python",
		header_text = header_text or (type_ == "markdown" and "# %% [markdown]" or "# %%"),

		-- extmarks
		input_mark = input_mark,
		output_mark = output_mark,
		header_virt_mark = nil,

		-- background highlight extmarks
		_bg = nil,
	}, Block)

	self:show_header_virtual()
	self:set_highlight(
		(self.type == "markdown") and "NotebookMarkdownBlock" or "NotebookPythonBlock",
		"NotebookOutputBlock"
	)

	return self
end

function Block:input_range()
	local pos = vim.api.nvim_buf_get_extmark_by_id(
		self.buf,
		Names.blocks,
		self.input_mark,
		{ details = true }
	)
	if not pos then
		return 0, 0
	end
	local s = pos[1]
	local details = pos[3] or {}
	local e = details.end_row or s
	return s, e
end

function Block:output_range()
	local pos = vim.api.nvim_buf_get_extmark_by_id(
		self.buf,
		Names.blocks_output,
		self.output_mark,
		{ details = true }
	)
	if not pos then
		local _, in_e = self:input_range()
		return in_e, in_e
	end
	local s = pos[1]
	local details = pos[3] or {}
	local e = details.end_row or s
	return s, e
end

function Block:range()
	local in_s, in_e = self:input_range()
	local _, out_e = self:output_range()
	local s = in_s
	local e = math.max(in_e, out_e)
	return s, e
end

function Block:text()
	local s, e = self:input_range()
	return vim.api.nvim_buf_get_lines(self.buf, s, e, false)
end

function Block:output_text()
	local s, e = self:output_range()
	if e <= s then
		return {}
	end
	return vim.api.nvim_buf_get_lines(self.buf, s, e, false)
end

function Block:output_insert_row()
	local _, in_e = self:input_range()
	return in_e
end

function Block:set_input_span(new_s, new_e)
	local n = vim.api.nvim_buf_line_count(self.buf)

	-- Clamp start to [0, n-1] so that new_s + 1 is always <= n
	new_s = math.max(0, math.min(new_s or 0, math.max(n - 1, 0)))
	-- end must be within [new_s+1, n]
	new_e = math.max(new_s + 1, math.min(new_e or (new_s + 1), n))

	vim.api.nvim_buf_set_extmark(self.buf, Names.blocks, new_s, 0, {
		id = self.input_mark,
		end_row = new_e,
		end_col = 0,
		right_gravity = false,
		end_right_gravity = true,
	})

	local out_s, out_e = self:output_range()
	if out_s == out_e then
		local row = new_e
		local cfg = output_mark_cfg(row)
		cfg.id = self.output_mark
		vim.api.nvim_buf_set_extmark(self.buf, Names.blocks_output, row, 0, cfg)
	end

	self:sync_decorations()
end

function Block:set_end_row(e_excl)
	local s, _ = self:input_range()
	self:set_input_span(s, e_excl)
end

function Block:replace_output_lines(lines)
	lines = lines or {}

	local _, in_e = self:input_range()
	local out_s, out_e = self:output_range()

	if out_e > out_s then
		local del_s = math.max(out_s, in_e)
		if del_s < out_e then
			vim.api.nvim_buf_set_lines(self.buf, del_s, out_e, false, {})
		end
	end

	local insert_at = in_e

	if #lines > 0 then
		vim.api.nvim_buf_set_lines(self.buf, insert_at, insert_at, false, lines)
		local new_e = insert_at + #lines
		local cfg = output_mark_cfg(insert_at)
		cfg.id = self.output_mark
		cfg.end_row = new_e
		vim.api.nvim_buf_set_extmark(self.buf, Names.blocks_output, insert_at, 0, cfg)
	else
		local cfg = output_mark_cfg(insert_at)
		cfg.id = self.output_mark
		vim.api.nvim_buf_set_extmark(self.buf, Names.blocks_output, insert_at, 0, cfg)
	end
end

function Block:show_header_virtual()
	if self.header_virt_mark then
		pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.headers, self.header_virt_mark)
		self.header_virt_mark = nil
	end
	local s, _ = self:input_range()
	self.header_virt_mark =
		vim.api.nvim_buf_set_extmark(self.buf, Names.headers, s, 0, header_config(self.header_text))
end

function Block:set_type(new_t)
	self.type = new_t
	self.header_text = (new_t == "markdown") and "# %% [markdown]" or "# %%"
	self:show_header_virtual()
	local group = (self.type == "markdown") and "NotebookMarkdownBlock" or "NotebookPythonBlock"
	self:set_highlight(group, "NotebookOutputBlock")
end

function Block:set_highlight(input_group, output_group)
	local in_s, in_e = self:input_range()
	local out_s, out_e = self:output_range()

	output_group = output_group or input_group

	self._bg = self._bg
		or {
			input = { group = nil, s = nil, e = nil, marks = {} },
			output = { group = nil, s = nil, e = nil, marks = {} },
		}

	local function clear_marks(st)
		if not st or not st.marks then
			return
		end
		for _, id in ipairs(st.marks) do
			if id then
				pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.block_cols, id)
			end
		end
		st.marks = {}
	end

	-- Helper: re-create marks for [s, e) with full-line highlight
	local function apply(st, group, s, e, hl_mode)
		if not group or not s or not e or e <= s then
			clear_marks(st)
			return
		end

		clear_marks(st)
		st.marks = {}

		for row = s, e - 1 do
			local id = vim.api.nvim_buf_set_extmark(self.buf, Names.block_cols, row, 0, {
				line_hl_group = group,
				hl_mode = hl_mode or "combine",
				priority = 50,
			})
			table.insert(st.marks, id)
		end

		st.group, st.s, st.e = group, s, e
	end

	-- Input region: combine with syntax highlighting
	apply(self._bg.input, input_group, in_s, in_e, "combine")

	-- Output region (only if non-empty): replace syntax/diagnostics with plain output bg
	if out_e > out_s then
		apply(self._bg.output, output_group, out_s, out_e, "replace")
	else
		clear_marks(self._bg.output)
	end
end

function Block:sync_decorations()
	local s, _ = self:input_range()

	if self.header_virt_mark then
		local cfg = header_config(self.header_text)
		cfg.id = self.header_virt_mark
		pcall(vim.api.nvim_buf_set_extmark, self.buf, Names.headers, s, 0, cfg)
	end

	local group_in = (self.type == "markdown") and "NotebookMarkdownBlock" or "NotebookPythonBlock"
	self:set_highlight(group_in, "NotebookOutputBlock")
end

function Block:destroy()
	pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.blocks, self.input_mark)
	pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.blocks_output, self.output_mark)
	if self.header_virt_mark then
		pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.headers, self.header_virt_mark)
	end
	if self._bg then
		local function clear(st)
			if not st or not st.marks then
				return
			end
			for _, id in ipairs(st.marks) do
				pcall(vim.api.nvim_buf_del_extmark, self.buf, Names.block_cols, id)
			end
		end
		clear(self._bg.input)
		clear(self._bg.output)
	end
	self._bg = nil
end

return Block
