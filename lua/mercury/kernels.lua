local M = {}
local BUF_STATE = {}
local LAST_CHOICE = nil

local function _exepath(bin)
	local p = vim.fn.exepath(bin)
	if p and p ~= "" then
		return p
	end
	return nil
end

local function _is_file(p)
	return p and p ~= "" and (vim.fn.filereadable(p) == 1 or vim.fn.executable(p) == 1)
end

local function current_buf()
	return vim.api.nvim_get_current_buf()
end

local function get_state(bufnr, create)
	local buf = bufnr or current_buf()
	local st = BUF_STATE[buf]
	if not st and create then
		st = {}
		BUF_STATE[buf] = st
	end
	return st, buf
end

function M.get_buf_python(bufnr)
	local st = BUF_STATE[bufnr or current_buf()]
	if st and st.python and _is_file(st.python) then
		return st.python
	end

	local gpy = vim.g.mercury_python
	if _is_file(gpy) then
		return gpy
	end
	return nil
end

function M.set_buf_python(bufnr, python, label)
	if not python or python == "" then
		return
	end
	local st = get_state(bufnr, true)
	st.python = python
	st.label = label or python
end

function M.clear_kernel_for_buf(bufnr)
	local st, b = get_state(bufnr or current_buf(), false)
	if st then
		BUF_STATE[b] = nil
	end
end

function M.kernel_info_for_buf(bufnr)
	local st = BUF_STATE[bufnr or current_buf()]
	if st and st.python then
		return { python = st.python, label = st.label or st.python }
	end
	local gpy = vim.g.mercury_python
	if _is_file(gpy) then
		return { python = gpy, label = ("g:mercury_python (%s)"):format(gpy) }
	end
	return nil
end

local function detect_candidates()
	local cands = {}
	local seen = {}

	local function add(path, label)
		if _is_file(path) and not seen[path] then
			table.insert(cands, { path = path, label = label or path })
			seen[path] = true
		end
	end

	if _is_file(vim.g.mercury_python) then
		add(vim.g.mercury_python, ("g:mercury_python (%s)"):format(vim.g.mercury_python))
	end

	-- Active venv / conda
	local sep = package.config:sub(1, 1)
	if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then
		local p = vim.env.VIRTUAL_ENV .. (sep == "\\" and "\\Scripts\\python.exe" or "/bin/python")
		add(p, ("VIRTUAL_ENV (%s)"):format(p))
	end
	if vim.env.CONDA_PREFIX and vim.env.CONDA_PREFIX ~= "" then
		local p = vim.env.CONDA_PREFIX .. (sep == "\\" and "\\Scripts\\python.exe" or "/bin/python")
		add(p, ("CONDA_PREFIX (%s)"):format(p))
	end

	-- Neovim host python
	if _is_file(vim.g.python3_host_prog) then
		add(vim.g.python3_host_prog, ("python3_host_prog (%s)"):format(vim.g.python3_host_prog))
	end

	-- Raw python3/python on PATH
	local p3 = _exepath("python3")
	if p3 then
		add(p3, ("python3 (%s)"):format(p3))
	end
	local p = _exepath("python")
	if p then
		add(p, ("python (%s)"):format(p))
	end

	-- Last choice in this Neovim session (if any and not already present)
	if LAST_CHOICE and _is_file(LAST_CHOICE) and not seen[LAST_CHOICE] then
		table.insert(cands, 1, {
			path = LAST_CHOICE,
			label = ("last used (%s)"):format(LAST_CHOICE),
		})
		seen[LAST_CHOICE] = true
	end

	return cands
end

local function prompt_for_python(bufnr)
	bufnr = bufnr or current_buf()

	local cands = detect_candidates()

	-- If we couldn't detect anything, just ask for a path.
	if #cands == 0 then
		local input = vim.fn.input("Python executable for this notebook: ", "", "file")
		if not input or input == "" then
			return nil
		end
		if not _is_file(input) then
			vim.notify("mercury: not an executable python: " .. input, vim.log.levels.ERROR)
			return nil
		end
		return input, input
	end

	local items = { "Select Python interpreter for this notebook buffer:" }

	for _, c in ipairs(cands) do
		table.insert(items, "  " .. c.label)
	end

	local idx_custom = #cands + 2
	local idx_cancel = #cands + 3

	table.insert(items, "  Custom path...")
	table.insert(items, "  Cancel")

	-- inputlist returns the index of the *line*, where line 1 is the header above.
	local choice = vim.fn.inputlist(items)

	-- 0 = user aborted; 1 = header; idx_cancel = explicit cancel
	if choice == 0 or choice == 1 or choice == idx_cancel then
		return nil
	end

	if choice == idx_custom then
		local input = vim.fn.input("Python executable for this notebook: ", "", "file")
		if not input or input == "" then
			return nil
		end
		if not _is_file(input) then
			vim.notify("mercury: not an executable python: " .. input, vim.log.levels.ERROR)
			return nil
		end
		return input, input
	end

	-- Map selection line -> candidate index
	local idx = choice - 1
	local cand = cands[idx]
	if not cand then
		return nil
	end
	return cand.path, cand.label
end

---Interactively select a kernel (python) for the given buffer.
function M.select_kernel_for_buf(bufnr)
	bufnr = bufnr or current_buf()
	local py, label = prompt_for_python(bufnr)
	if not py then
		return nil
	end

	M.set_buf_python(bufnr, py, label)
	LAST_CHOICE = py

	vim.notify(
		string.format("mercury: using %s for buffer #%d", label or py, bufnr),
		vim.log.levels.INFO
	)

	return py
end

function M.default_bridge_cmd()
	-- Locate bridge.py
	local src = debug.getinfo(1, "S").source
	local this = (src:sub(1, 1) == "@") and src:sub(2) or src
	local this_dir = vim.fn.fnamemodify(this, ":p:h")

	local hits = vim.api.nvim_get_runtime_file("mercury/python/bridge.py", false)
	local bridge = hits and hits[1]
	if not bridge then
		local candidates = {
			this_dir .. "/../python/bridge.py",
			this_dir .. "/../../python/bridge.py",
			this_dir .. "/../../../python/bridge.py",
		}
		for _, pth in ipairs(candidates) do
			if vim.loop.fs_stat(pth) then
				bridge = pth
				break
			end
		end
	end

	if not bridge then
		vim.notify("mercury: bridge.py not found.", vim.log.levels.ERROR)
		return nil
	end

	-- Per-buffer Python selection:
	local bufnr = current_buf()
	local py = M.get_buf_python(bufnr)

	-- No kernel yet for this buffer: prompt user.
	if not py then
		py = M.select_kernel_for_buf(bufnr)
	end

	if not py then
		vim.notify(
			"mercury: no Python interpreter selected for this notebook buffer.",
			vim.log.levels.ERROR
		)
		return nil
	end

	bridge = vim.fn.fnamemodify(bridge, ":p")
	return { py, "-u", bridge }
end

return M
