-- Integration shim with render-markdown.nvim. Optional dependency: Mercury
-- works without it (markdown cells still highlight via treesitter), but with
-- it installed the plugin styles headings / lists / emphasis the way users
-- expect from a real notebook UI.
--
-- The plugin attaches to buffers based on filetype, and Mercury's buffers
-- are `filetype = python`. We can't just set the buffer's filetype to
-- markdown (it'd break LSP, treesitter, the whole notebook). Instead:
--
--   1. On setup, add "python" to render-markdown's `filetypes` list so the
--      plugin treats python buffers as candidates. (Won't render most
--      python buffers — they have no `markdown` injection — but only adds
--      a per-buffer attach check.)
--   2. On every notebook attach, call render-markdown's per-buffer enable
--      API directly so it's wired up regardless of timing vs FileType.
--
-- The render-markdown.nvim public API has shifted across versions (v5/v6/v7
-- and the upstream rename to `MeanderingProgrammer/render-markdown.nvim`).
-- We probe a small list of known entry points and use whichever exists.
-- Failures are silent — this is decorative.

local M = {}

-- Returns the loaded render-markdown module if installed, else nil.
local function _try_require()
  local ok, mod = pcall(require, "render-markdown")
  if ok and type(mod) == "table" then return mod end
  return nil
end

-- True iff render-markdown.nvim is installed and loadable.
function M.available()
  return _try_require() ~= nil
end

-- Ensure "python" appears in render-markdown.nvim's configured filetypes
-- list. We call this once from mercury.setup so the plugin's auto-attach
-- on FileType picks up notebook buffers. Idempotent.
function M.ensure_python_filetype()
  local rm = _try_require()
  if not rm then return false end
  -- Several API surfaces have existed over versions; try them in order
  -- from most-current to least.
  --   (v7+) require("render-markdown").setup{ filetypes = { ... } }
  --   (v6)  require("render-markdown.state").config.file_types
  --   (v5)  require("render-markdown.config").file_types
  -- We don't want to overwrite the user's setup, only append.
  local appended = false
  local function append(list)
    if type(list) ~= "table" then return false end
    for _, ft in ipairs(list) do
      if ft == "python" then return true end
    end
    list[#list + 1] = "python"
    return true
  end
  -- v6/v7 carry config under render-markdown.state.config or a similarly
  -- named module. Probe defensively.
  for _, modname in ipairs({ "render-markdown.state", "render-markdown.config" }) do
    local ok, mod = pcall(require, modname)
    if ok and type(mod) == "table" then
      if mod.config and type(mod.config) == "table" then
        if append(mod.config.file_types) or append(mod.config.filetypes) then
          appended = true
        end
      end
      if append(mod.file_types) or append(mod.filetypes) then
        appended = true
      end
    end
  end
  -- Last-ditch: call setup with our filetype if there's a setup function.
  if not appended and type(rm.setup) == "function" then
    pcall(rm.setup, { file_types = { "python", "markdown" } })
    appended = true
  end
  return appended
end

-- Enable render-markdown on the given buffer (if the plugin exposes a
-- per-buffer API). Called from Mercury's attach_buffer.
function M.enable_buffer(buf)
  local rm = _try_require()
  if not rm then return false end
  -- Try the documented APIs across versions.
  for _, modname in ipairs({
    "render-markdown.api",
    "render-markdown.manager",
    "render-markdown",
  }) do
    local ok, mod = pcall(require, modname)
    if ok and type(mod) == "table" then
      for _, name in ipairs({ "buf_enable", "enable_buf", "enable" }) do
        local fn = mod[name]
        if type(fn) == "function" then
          local _ok = pcall(fn, buf)
          if _ok then return true end
        end
      end
    end
  end
  return false
end

return M
