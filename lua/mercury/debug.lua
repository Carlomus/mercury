local Mgr = require("mercury.manager")

local function dump_blocks(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	local reg = Mgr.registry_for(buf)
	for _, id in ipairs(Mgr.order_list(buf)) do
		local b = reg.by_id[id]
		if b then
			local in_s, in_e = b:input_range()
			local out_s, out_e = b:output_range()
			local blk_s, blk_e = b:range()
			print(
				string.format(
					"Block %s: Blk[%d,%d)  In[%d,%d)  Out[%d,%d)",
					b.id,
					blk_s,
					blk_e,
					in_s,
					in_e,
					out_s,
					out_e
				)
			)
		end
	end
end

vim.api.nvim_create_user_command("NotebookDebugMarks", function()
	dump_blocks(0)
end, {})
