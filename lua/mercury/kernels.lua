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
		if b == current_buf() then
			LAST_CHOICE = nil
		end
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

local function path_join(a, b)
	local sep = package.config:sub(1, 1)
	if a:sub(-1) == sep then
		return a .. b
	end
	return a .. sep .. b
end

local function dirname(p)
	return vim.fn.fnamemodify(p, ":h")
end

local function find_project_venv(bufnr)
	bufnr = bufnr or current_buf()
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return {}
	end
	local dir = vim.fn.fnamemodify(name, ":p:h")
	if dir == "" then
		return {}
	end

	local sep = package.config:sub(1, 1)
	local results = {}
	local seen_dir = {}

	while dir and dir ~= "" and not seen_dir[dir] do
		seen_dir[dir] = true
		local venv_dir = path_join(dir, ".venv")
		local py = (
			venv_dir
			and (
				sep == "\\" and path_join(path_join(venv_dir, "Scripts"), "python.exe")
				or path_join(path_join(venv_dir, "bin"), "python")
			)
		)
		if py and _is_file(py) then
			local label = (".venv (%s)"):format(py)
			table.insert(results, { path = py, label = label })
			-- Do NOT break; parent dirs may also have .venv
		end

		local parent = dirname(dir)
		if not parent or parent == "" or parent == dir then
			break
		end
		dir = parent
	end

	return results
end

local function find_conda_envs()
	local results = {}
	local ok, out = pcall(vim.fn.system, { "conda", "env", "list", "--json" })
	if not ok or vim.v.shell_error ~= 0 or not out or out == "" then
		return results
	end
	local ok_j, decoded = pcall(vim.json.decode, out)
	if not ok_j or type(decoded) ~= "table" or type(decoded.envs) ~= "table" then
		return results
	end

	local sep = package.config:sub(1, 1)
	for _, env_path in ipairs(decoded.envs) do
		if type(env_path) == "string" and env_path ~= "" then
			local py = (
				sep == "\\" and path_join(path_join(env_path, "Scripts"), "python.exe")
				or path_join(path_join(env_path, "bin"), "python")
			)
			if _is_file(py) then
				local name = vim.fn.fnamemodify(env_path, ":t")
				local label = ("conda:%s (%s)"):format(name, py)
				table.insert(results, { path = py, label = label })
			end
		end
	end

	return results
end

local function run_cmd(cmd, input)
	-- Prefer vim.system when available
	if vim.system then
		local result = vim.system(cmd, { text = true, stdin = input }):wait()
		local ok = (result.code == 0)
		return ok, result.stdout or "", result.stderr or ""
	else
		local joined = table.concat(cmd, " ")
		local out = vim.fn.system(joined, input)
		local ok = (vim.v.shell_error == 0)
		return ok, out or "", ok and "" or out or ""
	end
end

local function env_has_jupyter(py)
	local ok, _, _ = run_cmd({ py, "-c", "import jupyter_client, ipykernel" })
	return ok
end

local function ensure_env_ready(py)
	-- Already good?
	if env_has_jupyter(py) then
		return true
	end

	-- Ask if we should install
	local items = {
		("Selected Python (%s) is missing Jupyter deps."):format(py),
		"1) Install ipykernel + jupyter_client into this environment (via pip)",
		"2) Cancel",
	}
	local choice = vim.fn.inputlist(items)
	if choice ~= 1 then
		vim.notify(
			"mercury: environment missing ipykernel/jupyter_client; cancelled install.",
			vim.log.levels.WARN
		)
		return false
	end

	vim.notify(
		("mercury: installing ipykernel + jupyter_client into %s ..."):format(py),
		vim.log.levels.INFO
	)

	local ok_install, _, err =
		run_cmd({ py, "-m", "pip", "install", "-U", "ipykernel", "jupyter_client" })
	if not ok_install then
		vim.notify(("mercury: pip install failed for %s: %s"):format(py, err), vim.log.levels.ERROR)
		return false
	end

	-- Try to ensure a 'python3' kernelspec exists; ignore failures.
	run_cmd({ py, "-m", "ipykernel", "install", "--user", "--name", "python3" })

	if not env_has_jupyter(py) then
		vim.notify(
			("mercury: environment %s still missing Jupyter deps after install."):format(py),
			vim.log.levels.ERROR
		)
		return false
	end

	vim.notify(
		("mercury: environment %s is ready for Jupyter kernels."):format(py),
		vim.log.levels.INFO
	)
	return true
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

	local buf = current_buf()

	if _is_file(vim.g.mercury_python) then
		add(vim.g.mercury_python, ("g:mercury_python (%s)"):format(vim.g.mercury_python))
	end

	for _, v in ipairs(find_project_venv(buf)) do
		add(v.path, v.label)
	end

	local sep = package.config:sub(1, 1)
	if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then
		local p = vim.env.VIRTUAL_ENV .. (sep == "\\" and "\\Scripts\\python.exe" or "/bin/python")
		add(p, ("VIRTUAL_ENV (%s)"):format(p))
	end
	if vim.env.CONDA_PREFIX and vim.env.CONDA_PREFIX ~= "" then
		local p = vim.env.CONDA_PREFIX .. (sep == "\\" and "\\Scripts\\python.exe" or "/bin/python")
		add(p, ("CONDA_PREFIX (%s)"):format(p))
	end

	-- 4. All conda envs (if conda is available)
	for _, env in ipairs(find_conda_envs()) do
		add(env.path, env.label)
	end

	-- 5. Base/system python(s). Only one per unique path.
	local p3 = _exepath("python3")
	local p = _exepath("python")
	if p3 then
		add(p3, ("python3 (%s)"):format(p3))
	end
	if p and (not p3 or p ~= p3) then
		-- Only add if it is a different path than python3
		add(p, ("python (%s)"):format(p))
	end

	-- 6. Last choice in this Neovim session (if not already in list)
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

	for i, c in ipairs(cands) do
		table.insert(items, string.format("%d) %s", i, c.label))
	end

	local idx_custom = #cands + 2
	local idx_cancel = #cands + 3

	table.insert(items, string.format("%d) %s", #cands + 1, "Custom path..."))
	table.insert(items, string.format("%d) %s", #cands + 2, "Cancel"))

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

	if not ensure_env_ready(py) then
		return nil
	end

	bridge = vim.fn.fnamemodify(bridge, ":p")
	return { py, "-u", bridge }
end

return M
