-- :checkhealth mercury — surfaces missing dependencies at a glance.
--
-- Mercury's failure modes (no python, no ipykernel, no image.nvim, no LaTeX
-- rasterizer) are silent until you hit them, and the error messages from the
-- failure path don't always point at the root cause. This module lets the
-- user run one command and get a definitive answer.

local M = {}

local function start(name) vim.health.start(name) end
local function ok(msg) vim.health.ok(msg) end
local function warn(msg, advice) vim.health.warn(msg, advice) end
local function err(msg, advice) vim.health.error(msg, advice) end

local function check_nvim()
  start("Neovim")
  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim ≥ 0.10")
  else
    err("Mercury requires Neovim ≥ 0.10",
      { "Upgrade Neovim — image.nvim, vim.uri_to_bufnr, vim.uv.random, and "
        .. "vim.lsp.config all require 0.10+." })
  end
end

-- Resolve the python interpreter the same way kernel.lua does. Returns the
-- path or nil; we keep this in sync with default_python() in kernel.lua —
-- divergence would mean :checkhealth tests a different interpreter than the
-- bridge actually uses.
local function resolved_python()
  local cfg = require("mercury.config").get()
  if cfg.python and vim.fn.executable(cfg.python) == 1 then return cfg.python end
  local g = vim.g.mercury_python or vim.g.python3_host_prog
  if g and vim.fn.executable(g) == 1 then return g end
  local env = vim.env.VIRTUAL_ENV or vim.env.CONDA_PREFIX
  if env and env ~= "" then
    local sep = package.config:sub(1, 1)
    local cand = env .. (sep == "\\" and "\\Scripts\\python.exe" or "/bin/python")
    if vim.fn.executable(cand) == 1 then return cand end
  end
  for _, name in ipairs({ "python3", "python" }) do
    local p = vim.fn.exepath(name)
    if p ~= "" then return p end
  end
  return nil
end

local function check_python()
  start("Python bridge")
  local py = resolved_python()
  if not py then
    err("No python interpreter found",
      { "Set vim.g.python3_host_prog or activate a venv.",
        "Or pass python = '/path/to/python' to mercury.setup()." })
    return
  end
  ok("python: " .. py)

  -- Check each module independently so the error message names the actual
  -- missing dependency. Common failure mode: jupyter_client is system-wide
  -- but ipykernel is venv-local (or vice versa).
  for _, mod in ipairs({ "jupyter_client", "ipykernel" }) do
    local res = vim.system({ py, "-c",
      "import " .. mod .. "; print(" .. mod .. ".__version__)" },
      { text = true }):wait()
    if res.code == 0 then
      ok(("%s %s"):format(mod, (res.stdout or ""):gsub("%s+$", "")))
    else
      err(mod .. " not importable from " .. py,
        { ("Install with: %s -m pip install %s"):format(py, mod) })
    end
  end

  -- List available kernelspecs so the user can see which kernel mercury
  -- will pick (or be prompted to pick).
  local k = vim.system({ py, "-c",
    "from jupyter_client.kernelspec import KernelSpecManager;"
    .. "print('\\n'.join(KernelSpecManager().get_all_specs().keys()))" },
    { text = true }):wait()
  if k.code == 0 and (k.stdout or "") ~= "" then
    ok("kernelspecs: " .. (k.stdout or ""):gsub("%s+$", "")
      :gsub("\n", ", "))
  else
    warn("No kernelspecs installed",
      { ("Install one: %s -m ipykernel install --user --name python3"):format(py) })
  end
end

local function check_image()
  start("Inline images")
  local ok_mod, mod = pcall(require, "image")
  if not ok_mod then
    warn("image.nvim not installed",
      { "Install 3rd/image.nvim for inline plot rendering.",
        "Without it, image outputs render as [image/png] placeholder lines." })
    return
  end
  if mod.is_enabled and not mod.is_enabled() then
    warn("image.nvim loaded but disabled",
      { "Check image.nvim setup() and your terminal's graphics protocol support." })
    return
  end
  ok("image.nvim available")
end

local function check_latex()
  start("LaTeX rasterizer")
  local cfg = require("mercury.config").get().latex
  if type(cfg.rasterizer) == "function" then
    ok("custom function rasterizer configured")
    return
  end
  local backends = {}
  if vim.fn.executable("pdflatex") == 1 and vim.fn.executable("pdftoppm") == 1 then
    backends[#backends + 1] = "pdflatex+pdftoppm"
  end
  if vim.fn.executable("tex2png") == 1 then backends[#backends + 1] = "tex2png" end
  if vim.fn.executable("katex") == 1 then backends[#backends + 1] = "katex" end
  if #backends == 0 then
    warn("No LaTeX rasterizer available",
      { "Install one of: pdflatex+pdftoppm (best fidelity), tex2png, or katex.",
        "Without one, text/latex outputs fall back to raw source." })
  else
    ok("backends: " .. table.concat(backends, ", "))
  end
end

local function check_treesitter()
  start("Treesitter")
  local has_python = pcall(vim.treesitter.language.add, "python")
  local has_md = pcall(vim.treesitter.language.add, "markdown")
  if has_python then ok("python parser installed")
  else err("python treesitter parser not installed",
    { ":TSInstall python" }) end
  if has_md then ok("markdown parser installed")
  else warn("markdown treesitter parser not installed",
    { ":TSInstall markdown — without it, markdown cells lose prose highlighting." }) end
end

function M.check()
  check_nvim()
  check_python()
  check_image()
  check_latex()
  check_treesitter()
end

return M
