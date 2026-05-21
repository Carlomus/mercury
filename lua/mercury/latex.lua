-- Rasterize text/latex outputs to PNG so they can be displayed inline via
-- image.nvim, matching what VS Code / Jupyter do for math.
--
-- The rasterizer is configurable via mercury.config:
--
--   latex.rasterizer = "auto"           -- detect installed tools (default)
--   latex.rasterizer = "pdflatex+pdftoppm"
--   latex.rasterizer = "tex2png"
--   latex.rasterizer = "katex"
--   latex.rasterizer = function(src)    -- return path-to-png/svg or nil
--
-- Auto mode tries pdflatex+pdftoppm first (best fidelity), then tex2png,
-- then katex. Results are cached on disk by (src, backend) so re-rendering
-- the same equation with the same backend is cheap.

local Util = require("mercury.util")
local Cfg = require("mercury.config")

local M = {}

local CACHE_DIR = vim.fn.stdpath("cache") .. "/mercury_latex"

local function ensure_cache()
  if vim.fn.isdirectory(CACHE_DIR) == 0 then
    vim.fn.mkdir(CACHE_DIR, "p")
  end
end

local function exe(bin) return vim.fn.executable(bin) == 1 end

local function run(cmd, cwd)
  local res = vim.system(cmd, { text = true, cwd = cwd }):wait()
  return res.code == 0, res.stdout or "", res.stderr or ""
end

-- ---------- backends ----------

local function rasterize_pdflatex(src, out_png)
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local tex_path = tmpdir .. "/eq.tex"
  Util.write_file(tex_path, table.concat({
    "\\documentclass[border=2pt,convert={density=300}]{standalone}",
    "\\usepackage{amsmath,amssymb,amsfonts}",
    "\\begin{document}",
    src,
    "\\end{document}",
  }, "\n"))
  local ok = run({ "pdflatex", "-interaction=nonstopmode", "-halt-on-error",
    "-no-shell-escape", "-output-directory", tmpdir, tex_path }, tmpdir)
  if not ok then return false end
  local pdf = tmpdir .. "/eq.pdf"
  if vim.fn.filereadable(pdf) == 0 then return false end
  return run({ "pdftoppm", "-png", "-r", "200", pdf,
    out_png:gsub("%.png$", "") })
end

local function rasterize_tex2png(src, out_png)
  local tmp_in = vim.fn.tempname() .. ".tex"
  Util.write_file(tmp_in, src)
  return run({ "tex2png", "-i", tmp_in, "-o", out_png })
end

-- katex CLI -> SVG. output.lua treats SVGs the same as PNGs via image.nvim.
local function rasterize_katex(src, out_path)
  local out = out_path:gsub("%.png$", ".svg")
  local res = vim.system({ "katex" }, { stdin = src, text = true }):wait()
  if res.code ~= 0 or not res.stdout or res.stdout == "" then return false end
  local ok = Util.write_file(out, res.stdout)
  if not ok then return false end
  return true, out
end

local function pick_backend()
  if exe("pdflatex") and exe("pdftoppm") then return "pdflatex+pdftoppm" end
  if exe("tex2png") then return "tex2png" end
  if exe("katex") then return "katex" end
  return nil
end

-- ---------- public API ----------

function M.available()
  return pick_backend() ~= nil or type(Cfg.get().latex.rasterizer) == "function"
end

-- Exposed for testing: the on-disk cache key depends on src AND backend, so
-- switching backends invalidates results.
function M._cache_key(src, backend)
  return Util.hash((src or "") .. "|" .. (backend or "")):sub(1, 16)
end

function M.rasterize(src)
  if not src or src == "" then return nil end
  src = (type(src) == "table") and table.concat(src, "") or src

  local cfg = Cfg.get().latex
  local backend = cfg.rasterizer

  -- Function backends manage their own caching; we just call them.
  if type(backend) == "function" then
    local out = backend(src)
    if out and vim.loop.fs_stat(out) then return out end
    return nil
  end

  if backend == nil or backend == "auto" then
    backend = pick_backend()
    if not backend then return nil end
  end

  ensure_cache()
  local key = M._cache_key(src, backend)
  local cached_png = CACHE_DIR .. "/" .. key .. ".png"
  if vim.loop.fs_stat(cached_png) then
    Util.touch(cached_png)   -- mark hit so age-based GC doesn't evict
    return cached_png
  end
  local cached_svg = CACHE_DIR .. "/" .. key .. ".svg"
  if vim.loop.fs_stat(cached_svg) then
    Util.touch(cached_svg)
    return cached_svg
  end

  local ok = false
  local out
  if backend == "pdflatex+pdftoppm" then
    ok = rasterize_pdflatex(src, cached_png)
    -- pdftoppm appends -1.png to the prefix; rename to the cache path.
    local generated = cached_png:gsub("%.png$", "-1.png")
    if vim.loop.fs_stat(generated) then
      vim.loop.fs_rename(generated, cached_png)
      out = cached_png
    elseif vim.loop.fs_stat(cached_png) then
      out = cached_png
    else
      ok = false
    end
  elseif backend == "tex2png" then
    ok = rasterize_tex2png(src, cached_png); out = cached_png
  elseif backend == "katex" then
    ok, out = rasterize_katex(src, cached_png)
  end

  if ok and out and vim.loop.fs_stat(out) then return out end
  return nil
end

return M
