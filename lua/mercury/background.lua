local Mgr = require("mercury.manager")

local BG = {}
local OPTS = {
	python_hl = "NotebookPythonBlock",
	markdown_hl = "NotebookMarkdownBlock",
}

local function ensure_default_hls()
	local function ensure(name, color)
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
		if not ok or not hl or not hl.bg then
			vim.api.nvim_set_hl(0, name, { bg = color })
		end
	end
	ensure(OPTS.python_hl, "#253340")
	ensure(OPTS.markdown_hl, "#3a2b3a")
end

function BG.highlight(buf)
	buf = buf or 0
	for _, id in ipairs(Mgr.order_list(buf)) do
		local block = Mgr.registry.by_id[id]
		if block then
			local t = block.type or "python"
			local group = (t == "markdown") and OPTS.markdown_hl or OPTS.python_hl
			if block.set_highlight then
				block:set_highlight(group)
			end
		end
	end
end

function BG.setup(_)
	ensure_default_hls()
	vim.api.nvim_create_autocmd("ColorScheme", { callback = ensure_default_hls })
end

return BG
