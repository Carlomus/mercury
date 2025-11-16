local Mgr = require("mercury.manager")

local OG = {}

local function is_in_output(buf, row)
	local reg = Mgr.registry_for(buf)
	for _, id in ipairs(Mgr.order_list(buf)) do
		local b = reg.by_id[id]
		if b then
			local out_s, out_e = b:output_range()
			if row >= out_s and row < out_e then
				return true, b
			end
		end
	end
	return false, nil
end

local function guard_output()
	local buf = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local inside, b = is_in_output(buf, row)
	if not inside or not b then
		return
	end

	local s_in, e_in = b:input_range()
	local target = math.max(s_in, e_in - 1)
	pcall(vim.api.nvim_win_set_cursor, 0, { target + 1, 0 })
	vim.notify("mercury: outputs are read-only; moved cursor to cell input", vim.log.levels.INFO)
end

function OG.setup()
	local aug = vim.api.nvim_create_augroup("MercuryOutputGuard", { clear = true })
	vim.api.nvim_create_autocmd({ "InsertEnter", "CursorMovedI" }, {
		group = aug,
		pattern = { "*.ipynb", "*.[iI][pP][yY][nN][bB]" },
		callback = guard_output,
	})
end

return OG
