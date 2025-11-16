local Mgr = require("mercury.manager")

local M = {}

local function has_vim_system()
	return vim.system ~= nil
end

local function run_cmd(cmd, input)
	if has_vim_system() then
		local result = vim.system(cmd, { text = true, stdin = input }):wait()
		local ok = (result.code == 0)
		return ok, result.stdout or "", result.stderr or ""
	else
		-- Fallback: pass list of args directly to system() to avoid manual shell-escaping.
		local out = vim.fn.system(cmd, input)
		local ok = (vim.v.shell_error == 0)
		return ok, out or "", ok and "" or out or ""
	end
end

function M.jupytext_lens()
	return {
		pattern = { "*.ipynb" },
		decode = function(path, buf)
			local ok, out, err = run_cmd({ "jupytext", "--to", "py:percent", "-o", "-", path })
			if not ok then
				return false, ("jupytext decode failed: %s"):format(err)
			end
			local lines = vim.split(out, "\n", { plain = true })
			vim.bo[buf].modifiable = true
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.bo[buf].modifiable = true
			Mgr.scan_initial(buf)
			return true
		end,

		encode = function(path, buf)
			local percent_lines = Mgr.materialize_pypercent(buf)
			local input = table.concat(percent_lines, "\n")
			local args = {
				"jupytext",
				"--from",
				"py:percent",
				"--to",
				"notebook",
				"-o",
				path,
				"-",
			}
			if vim.loop.fs_stat(path) then
				table.insert(args, 2, "--update")
			end

			local ok, _, err = run_cmd(args, input)
			if not ok then
				return false, ("jupytext encode failed: %s"):format(err)
			end
			return true
		end,
	}
end

local function apply_common_buf_opts(buf, _)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undofile = true
	vim.bo[buf].filetype = "python"
	vim.bo[buf].modifiable = true
	vim.bo[buf].modified = false
end

function M.setup_autocmds(spec)
	vim.api.nvim_create_autocmd("BufReadCmd", {
		pattern = spec.pattern,
		callback = function(args)
			local buf = args.buf
			local path = vim.fn.fnamemodify(args.match or vim.api.nvim_buf_get_name(buf), ":p")
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
			apply_common_buf_opts(buf, spec)
			local ok, errmsg = spec.decode(path, buf)
			if not ok then
				vim.notify(errmsg or "Decode failed", vim.log.levels.ERROR)
				return
			end
			vim.api.nvim_buf_set_name(buf, path)
			vim.bo[buf].modified = false

			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(buf) then
					pcall(Mgr.sanitize_headers, buf)
					pcall(Mgr.reflow_all, buf)
				end
			end)
		end,
	})

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		pattern = spec.pattern,
		callback = function(args)
			local buf = args.buf
			local path = vim.fn.fnamemodify(args.match or vim.api.nvim_buf_get_name(buf), ":p")
			local ok, errmsg = spec.encode(path, buf)
			if not ok then
				vim.notify(errmsg or "Encode failed", vim.log.levels.ERROR)
				return
			end
			vim.bo[buf].modified = false
		end,
	})

	-- Single TextChanged / TextChangedI autocmd (no duplicates).
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		pattern = { "*.ipynb", "*.[iI][pP][yY][nN][bB]" },
		callback = function(args)
			Mgr.sanitize_headers(args.buf)
		end,
	})

	-- Softer BufEnter: only jump to first code block if we're not already in any block.
	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = { "*.ipynb", "*.[iI][pP][yY][nN][bB]" },
		callback = function(args)
			local buf = args.buf
			-- Ensure current window is actually showing this buffer
			if vim.api.nvim_get_current_buf() ~= buf then
				return
			end

			-- If cursor is already inside a notebook block (input or output), don't move it.
			local cur_block = Mgr.block_at_cursor(buf)
			if cur_block then
				return
			end

			-- Otherwise, jump to first python block input (notebook-style "focus top cell").
			local reg = Mgr.registry_for(buf)
			for _, id in ipairs(Mgr.order_list(buf)) do
				local b = reg.by_id[id]
				if b and b.type == "python" then
					local s, _ = b:input_range()
					pcall(vim.api.nvim_win_set_cursor, 0, { s + 1, 0 })
					break
				end
			end
		end,
	})
end

return M
