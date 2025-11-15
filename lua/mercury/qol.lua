local Mgr = require("mercury.manager")

local function jump_code_block(dir)
	local buf = vim.api.nvim_get_current_buf()
	local cur = Mgr.block_at_cursor(buf)
	if not cur then
		return
	end

	local cur_s = select(1, cur:range())
	local target = nil
	local target_s = nil

	local reg = Mgr.registry_for(buf)

	for _, id in ipairs(Mgr.order_list(buf)) do
		local b = reg.by_id[id]
		if b and b.type == "python" then
			local s = select(1, b:range())
			if dir == "next" and s > cur_s then
				if not target_s or s < target_s then
					target, target_s = b, s
				end
			elseif dir == "prev" and s < cur_s then
				if not target_s or s > target_s then
					target, target_s = b, s
				end
			end
		end
	end

	if target and target_s then
		vim.api.nvim_win_set_cursor(0, { target_s + 1, 0 })
	else
		vim.notify(
			"Notebook: no " .. (dir == "next" and "next" or "previous") .. " code block",
			vim.log.levels.INFO
		)
	end
end

local function select_cell(inner)
	local b = Mgr.block_at_cursor()
	if not b then
		return
	end
	local s, e = b:range()

	local buf = b.buf
	local last_line = vim.api.nvim_buf_line_count(buf)

	local start_row = s
	local end_row = math.max(s, e - 1)

	if not inner then
		if end_row + 1 < last_line then
			local next_line = vim.api.nvim_buf_get_lines(buf, end_row + 1, end_row + 2, false)[1]
			if next_line == "" then
				end_row = end_row + 1
			end
		end
	end

	vim.fn.setpos("'<", { buf, start_row + 1, 1, 0 })
	vim.fn.setpos("'>", { buf, end_row + 1, vim.v.maxcol, 0 })

	if vim.api.nvim_get_mode().mode:match("[vV]") then
		vim.cmd("normal! gv")
	end
end

vim.keymap.set({ "o", "x" }, "ic", function()
	select_cell(true)
end, { desc = "Notebook: inner cell" })

vim.keymap.set({ "o", "x" }, "ac", function()
	select_cell(false)
end, { desc = "Notebook: around cell" })

vim.keymap.set("n", "]c", function()
	jump_code_block("next")
end, { desc = "Notebook: jump to next code block" })

vim.keymap.set("n", "[c", function()
	jump_code_block("prev")
end, { desc = "Notebook: jump to previous code block" })
