local Mgr = require("mercury.manager")

local Debug = {}

function Debug.dump_blocks(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end

	local reg = Mgr.registry_for(buf)
	print("=== Notebook blocks for buffer " .. buf .. " ===")
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

function Debug.setup_commands()
	vim.api.nvim_create_user_command("NotebookDebugMarks", function(opts)
		local buf
		if opts.args ~= "" then
			buf = tonumber(opts.args)
		else
			buf = vim.api.nvim_get_current_buf()
		end
		Debug.dump_blocks(buf)
	end, {
		nargs = "?",
		complete = "buffer",
		desc = "Debug Mercury block extmarks for a buffer",
	})
end

return Debug
