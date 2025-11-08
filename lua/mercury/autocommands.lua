local Mgr = require("mercury.manager")

local M = {}

local function has_vim_system()
	return vim.system ~= nil
end

local function run_cmd(cmd, input)
	-- Prefer vim.system when available (robust argv, correct quoting).
	if has_vim_system() then
		local result = vim.system(cmd, { text = true, stdin = input }):wait()
		local ok = (result.code == 0)
		return ok, result.stdout or "", result.stderr or ""
	else
		-- Fallback: best-effort shell join (older Neovim). Kept as-is for compatibility.
		local joined = table.concat(cmd, " ")
		local out = vim.fn.system(joined, input)
		local ok = (vim.v.shell_error == 0)
		return ok, out, ok and "" or out
	end
end

function M.jupytext_lens()
	vim.notify("Starting lense")
	return {
		pattern = { "*.ipynb" },
		decode = function(path, buf)
			-- Drop mismatched CELL_MARKERS metadata; py:percent doesn't use it.
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
			-- Materialize py:percent from extmarks and write back to .ipynb
			local percent_lines = Mgr.materialize_pypercent()
			local input = table.concat(percent_lines, "\n")
			local ok, _, err = run_cmd({
				"jupytext",
				"--update",
				"--from",
				"py:percent",
				"--to",
				"notebook",
				"-o",
				path,
				"-",
			}, input)
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
end

return M
