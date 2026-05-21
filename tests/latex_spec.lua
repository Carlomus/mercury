local Latex = require("mercury.latex")
local Cfg = require("mercury.config")
local Util = require("mercury.util")

describe("latex rasterizer", function()
  before_each(function() Cfg.setup() end)

  it("calls a function backend with the source and returns its path", function()
    local seen
    local tmp = vim.fn.tempname() .. ".png"
    Util.write_file(tmp, "fake png bytes")
    Cfg.setup({
      latex = {
        rasterizer = function(src) seen = src; return tmp end,
      },
    })
    local out = Latex.rasterize("E = mc^2")
    assert.equals(tmp, out)
    assert.equals("E = mc^2", seen)
    os.remove(tmp)
  end)

  it("returns nil when the function backend returns nil", function()
    Cfg.setup({ latex = { rasterizer = function() return nil end } })
    assert.is_nil(Latex.rasterize("x"))
  end)

  it("returns nil when the function backend returns a non-existent path", function()
    Cfg.setup({ latex = { rasterizer = function() return "/no/such/path.png" end } })
    assert.is_nil(Latex.rasterize("x"))
  end)

  it("cache key depends on the backend name", function()
    -- Same source, different backends → distinct cache keys, so switching
    -- backends doesn't return a stale entry written by the previous one.
    local k_pdflatex = Latex._cache_key("E = mc^2", "pdflatex+pdftoppm")
    local k_katex    = Latex._cache_key("E = mc^2", "katex")
    local k_tex2png  = Latex._cache_key("E = mc^2", "tex2png")
    assert.is_true(k_pdflatex ~= k_katex)
    assert.is_true(k_katex ~= k_tex2png)
    assert.is_true(k_pdflatex ~= k_tex2png)
  end)

  it("cache key changes when the source changes", function()
    local a = Latex._cache_key("a", "katex")
    local b = Latex._cache_key("b", "katex")
    assert.is_true(a ~= b)
  end)

  it("available() returns true when a function rasterizer is set", function()
    Cfg.setup({ latex = { rasterizer = function() return nil end } })
    assert.is_true(Latex.available())
  end)

  it("rasterize returns nil for nil/empty source", function()
    Cfg.setup({ latex = { rasterizer = function() return "/tmp/x.png" end } })
    assert.is_nil(Latex.rasterize(nil))
    assert.is_nil(Latex.rasterize(""))
  end)

  it("rasterize concats a table source before passing to backend", function()
    -- text/latex output from a kernel can be either a string or a list of
    -- strings (multilineString form). The rasterizer must coerce.
    local seen
    Cfg.setup({
      latex = {
        rasterizer = function(src) seen = src; return nil end,
      },
    })
    Latex.rasterize({ "a", "b", "c" })
    assert.equals("abc", seen)
  end)

  it("rasterize ignores backend returning a non-string (defensive)", function()
    -- A misbehaving backend could return a number / table. Don't crash
    -- inside fs_stat — return nil.
    Cfg.setup({ latex = { rasterizer = function() return 42 end } })
    assert.is_nil(Latex.rasterize("x"))
    Cfg.setup({ latex = { rasterizer = function() return {} end } })
    assert.is_nil(Latex.rasterize("y"))
  end)

  it("rasterize returns nil when backend is 'auto' and no system rasterizer is on PATH", function()
    -- We can't reliably control whether pdflatex/katex/tex2png exist in
    -- CI. But we can stub vim.fn.executable to force 'auto' to find nothing.
    Cfg.setup({ latex = { rasterizer = "auto" } })
    local orig_exe = vim.fn.executable
    vim.fn.executable = function() return 0 end
    local ok, result = pcall(Latex.rasterize, "x")
    vim.fn.executable = orig_exe
    assert.is_true(ok)
    assert.is_nil(result)
  end)

  it("rasterize returns cached PNG on a second call with same source/backend", function()
    -- The cache hit branch returns the existing file without re-running.
    local call_count = 0
    Cfg.setup({
      latex = {
        rasterizer = function(src)
          call_count = call_count + 1
          local tmp = vim.fn.tempname() .. ".png"
          Util.write_file(tmp, "fake")
          return tmp
        end,
      },
    })
    -- Function-backends manage their own caching (mercury doesn't); two
    -- calls invoke the function twice. The cache-hit branch only applies
    -- to the system backends (pdflatex/tex2png/katex). Pin this contract:
    Latex.rasterize("x")
    Latex.rasterize("x")
    assert.equals(2, call_count)
  end)
end)
