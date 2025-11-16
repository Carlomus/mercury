local Mgr = require("mercury.manager")

local IG = {}

local function at_block_top()
	local b = Mgr.block_at_cursor()
	if not b then
		return false, nil
	end
	local s, _ = b:input_range()
	local pos = vim.api.nvim_win_get_cursor(0)
	local row = pos[1] - 1
	local col = pos[2]
	return (row == s and col == 0), b
end

function IG.setup()
	local aug = vim.api.nvim_create_augroup("MercuryInputGuard", { clear = true })

	-- Only apply backspace guard in notebook buffers
	vim.api.nvim_create_autocmd("BufEnter", {
		group = aug,
		pattern = { "*.ipynb", "*.[iI][pP][yY][nN][bB]" },
		callback = function(args)
			vim.keymap.set("i", "<BS>", function()
				local at_top = select(1, at_block_top())
				if at_top then
					-- Swallow backspace at very start of a cell to avoid merging with previous cell
					return ""
				end
				return "<BS>"
			end, {
				buffer = args.buf,
				expr = true,
				desc = "mercury: guard notebook cell boundary backspace",
			})
		end,
	})
end

return IG
