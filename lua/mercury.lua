local Mgr = require("mercury.manager")
local Bg = require("mercury.background")
local Auto = require("mercury.autocommands")
local Run = require("mercury.execute")
local Kern = require("mercury.kernels")
local M = {}

function M.setup(opts)
	opts = opts or {}

	Run.setup(opts)
	Bg.setup(opts)

	vim.api.nvim_create_autocmd("User", {
		pattern = "NotebookBlocksChanged",
		callback = function(args)
			if vim.bo[args.buf].filetype ~= "python" then
				return
			end
			Bg.highlight(args.buf)
		end,
	})

	local lenses = { Auto.jupytext_lens() }
	for _, s in ipairs(lenses) do
		Auto.setup_autocmds(s)
	end

	require("mercury.qol")

	-- Block management commands
	vim.api.nvim_create_user_command("NotebookBlockNewAbove", function()
		Mgr.new_block_above()
	end, {})
	vim.api.nvim_create_user_command("NotebookBlockNewBelow", function()
		Mgr.new_block_below()
	end, {})
	vim.api.nvim_create_user_command("NotebookBlockDelete", function()
		Mgr.delete_block()
	end, {})
	vim.api.nvim_create_user_command("NotebookBlockSelect", function()
		Mgr.select_block()
	end, {})
	vim.api.nvim_create_user_command("NotebookToPython", function()
		Mgr.set_block_type("python")
	end, {})
	vim.api.nvim_create_user_command("NotebookToMarkdown", function()
		Mgr.set_block_type("markdown")
	end, {})
	vim.api.nvim_create_user_command("NotebookMergeBelow", function()
		Mgr.merge_below()
	end, {})

	-- Execution commands
	vim.api.nvim_create_user_command("NotebookExecBlock", Run.exec_current, {})
	vim.api.nvim_create_user_command("NotebookExecAll", Run.exec_all, {})
	vim.api.nvim_create_user_command("NotebookExecAndNext", Run.exec_and_next, {})
	vim.api.nvim_create_user_command(
		"NotebookToggleShowFullOutput",
		Run.toggle_showing_full_output,
		{}
	)
	vim.api.nvim_create_user_command("NotebookRestart", Run.restart, {})
	vim.api.nvim_create_user_command("NotebookRestartClear", Run.restart_and_clear, {})
	vim.api.nvim_create_user_command("NotebookInterrupt", Run.interrupt, {})
	vim.api.nvim_create_user_command("NotebookStop", Run.stop, {})
	vim.api.nvim_create_user_command("NotebookClearOutput", Run.clear_output, {})

	vim.keymap.set("n", "<S-CR>", ":NotebookExecAndNext<CR>", { desc = "Notebook: exec + next" })

	-- Keep Treesitter highlights in sync with block type
	vim.api.nvim_create_autocmd("User", {
		pattern = "NotebookBlocksChanged",
		callback = function(args)
			local ok, parser = pcall(vim.treesitter.get_parser, args.buf, "python")
			if ok and parser then
				parser:parse(true)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		pattern = { "*.ipynb", "*.[iI][pP][yY][nN][bB]" },
		callback = function(args)
			Mgr.sanitize_headers(args.buf)
		end,
	})

	vim.api.nvim_create_user_command("NotebookKernelSelect", function()
		Kern.select_kernel_for_buf()
	end, {
		desc = "Select Python kernel for the current Mercury notebook buffer",
	})

	vim.api.nvim_create_user_command("NotebookKernelClear", function()
		Kern.clear_kernel_for_buf()
		vim.notify(
			"mercury: cleared kernel selection for current buffer (will prompt on next exec)",
			vim.log.levels.INFO
		)
	end, {
		desc = "Clear kernel selection for the current Mercury notebook buffer",
	})

	vim.api.nvim_create_user_command("NotebookKernelInfo", function()
		local info = Kern.kernel_info_for_buf()
		if info then
			vim.notify(
				string.format("mercury: current buffer uses %s", info.label or info.python),
				vim.log.levels.INFO
			)
		else
			vim.notify(
				"mercury: no kernel selected yet for this buffer (execution will prompt).",
				vim.log.levels.INFO
			)
		end
	end, {
		desc = "Show Python kernel used by current Mercury notebook buffer",
	})
end

-- TS predicate
local function capture_rows(cap)
	if not cap then
		return
	end
	if type(cap) == "table" and getmetatable(cap) == nil then
		local first, last = cap[1], cap[#cap]
		if not first or not last then
			return
		end
		local s1 = select(1, first:range())
		local _, _, e2 = last:range()
		return s1, e2
	else
		local s, _, e = cap:range()
		return s, e
	end
end

vim.treesitter.query.add_predicate("in_notebook_markdown_block?", function(match, _, _, predicate)
	local capid = predicate[2]
	local cap = match[capid]
	local sr, er = capture_rows(cap)
	if not sr then
		return false
	end
	local b = Mgr.block_covering(sr, er)
	return b and b.type == "markdown"
end)

return M
