-- Auto-discover candidate python interpreters around the current notebook.
--
-- Discovery sources (in priority order):
--   1. Active virtualenv ($VIRTUAL_ENV)
--   2. Active conda env  ($CONDA_PREFIX)
--   3. Project-local venvs walking up from the notebook's directory:
--      `.venv/`, `venv/`, `env/`
--
-- The point isn't to be exhaustive (pyenv, conda env list, etc. are out of
-- scope) — it's to cover the 90% case where the user has the kernel python
-- they want sitting right next to the notebook and doesn't want to run
-- `jupyter kernelspec install` to make mercury see it.

local M = {}

local function is_exe(p)
  if not p or p == "" then return false end
  return vim.fn.executable(p) == 1
end

local function pybin_suffix()
  return (package.config:sub(1, 1) == "\\")
    and "\\Scripts\\python.exe" or "/bin/python"
end

-- Active venv or conda env, if any. Returns one entry or nil.
local function active_env()
  local suffix = pybin_suffix()
  if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then
    local p = vim.env.VIRTUAL_ENV .. suffix
    if is_exe(p) then
      return { source = "active venv", path = p, env_root = vim.env.VIRTUAL_ENV }
    end
  end
  if vim.env.CONDA_PREFIX and vim.env.CONDA_PREFIX ~= "" then
    local p = vim.env.CONDA_PREFIX .. suffix
    if is_exe(p) then
      return { source = "active conda env", path = p,
               env_root = vim.env.CONDA_PREFIX }
    end
  end
  return nil
end

-- Walk up from `start_dir` looking for common venv directory names.
local function project_venvs(start_dir)
  local out = {}
  if not start_dir or start_dir == "" then return out end
  local suffix = pybin_suffix()
  local dir = vim.fn.fnamemodify(start_dir, ":p"):gsub("/$", "")
  for _ = 1, 8 do   -- max 8 levels up — enough for realistic project trees
    for _, name in ipairs({ ".venv", "venv", "env" }) do
      local env_root = dir .. "/" .. name
      local p = env_root .. suffix
      if is_exe(p) then
        out[#out + 1] = {
          source = ("project venv: %s"):format(env_root),
          path = p, env_root = env_root,
        }
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir or parent == "" then break end
    dir = parent
  end
  return out
end

-- Public: discover candidate pythons. Pass start_dir = directory of the
-- current notebook so the upward walk finds the project's venv.
function M.pythons(opts)
  opts = opts or {}
  local raw = {}
  local active = active_env()
  if active then raw[#raw + 1] = active end
  for _, v in ipairs(project_venvs(opts.start_dir)) do
    raw[#raw + 1] = v
  end

  -- Dedupe by resolved absolute path: the active venv and a project venv
  -- can refer to the same interpreter; only show it once.
  local seen, out = {}, {}
  for _, p in ipairs(raw) do
    local key = vim.fn.resolve(p.path)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = p
    end
  end
  return out
end

-- Best-effort short label for a python path. Used as display_name when the
-- bridge synthesizes a kernelspec.
--   /foo/bar/.venv/bin/python -> ".venv (bar)"
--   /usr/bin/python3          -> "/usr/bin/python3"
function M.short_label(python_path)
  if not python_path then return "python" end
  local parent = vim.fn.fnamemodify(python_path, ":h:h")
  local base = vim.fn.fnamemodify(parent, ":t")
  if base == ".venv" or base == "venv" or base == "env" then
    local proj = vim.fn.fnamemodify(parent, ":h:t")
    return ("%s (%s)"):format(base, proj)
  end
  return python_path
end

return M
