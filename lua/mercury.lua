local Mgr = require("mercury.lua.manager")
local Bg = require("mercury.lua.background")
local Auto = require("mercury.lua.autocommands")
local Run = require("mercury.lua.execute")

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
			Bg.highlight(args.buf, Mgr.registry)
		end,
	})

	local lenses = { Auto.jupytext_lens() }
	for _, s in ipairs(lenses) do
		Auto.setup_autocmds(s)
	end

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
