-- Verifies the python auto-discovery: active VIRTUAL_ENV / CONDA_PREFIX, and
-- the upward walk for project-local .venv/venv/env. We can't call real venv
-- pythons in CI, so we fake the directory layout and only assert on what
-- discover.pythons returns from those fakes.

local Discover = require("mercury.discover")
local Util = require("mercury.util")

local function mktree(...)
  -- Create a temp tree from a list of (relpath, content?) tuples and return
  -- the tree root. Files marked content=nil are created as empty executables.
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  for _, entry in ipairs({ ... }) do
    local rel, content = entry[1], entry[2]
    local full = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    local f = io.open(full, "w"); f:write(content or "#!/bin/sh\nexit 0\n"); f:close()
    vim.loop.fs_chmod(full, 493)  -- 0755
  end
  return root
end

local function with_env(overrides, fn)
  local saved = {}
  for k, _ in pairs(overrides) do saved[k] = vim.env[k] end
  for k, v in pairs(overrides) do vim.env[k] = v end
  local ok, err = pcall(fn)
  for k, _ in pairs(overrides) do vim.env[k] = saved[k] end
  if not ok then error(err) end
end

describe("discover.pythons", function()
  it("surfaces an active VIRTUAL_ENV", function()
    local root = mktree({ "myvenv/bin/python" })
    with_env({ VIRTUAL_ENV = root .. "/myvenv", CONDA_PREFIX = "" }, function()
      local pythons = Discover.pythons({ start_dir = root })
      local active = nil
      for _, p in ipairs(pythons) do
        if p.source == "active venv" then active = p end
      end
      assert.is_not_nil(active)
      assert.equals(root .. "/myvenv/bin/python", active.path)
    end)
  end)

  it("surfaces an active CONDA_PREFIX when no VIRTUAL_ENV is set", function()
    local root = mktree({ "miniconda/envs/data/bin/python" })
    with_env({ VIRTUAL_ENV = "",
               CONDA_PREFIX = root .. "/miniconda/envs/data" }, function()
      local pythons = Discover.pythons({ start_dir = root })
      local got
      for _, p in ipairs(pythons) do
        if p.source == "active conda env" then got = p end
      end
      assert.is_not_nil(got)
    end)
  end)

  it("finds project-local .venv by walking up from start_dir", function()
    local root = mktree({
      ".venv/bin/python",
      "subdir/notebook.ipynb",
    })
    with_env({ VIRTUAL_ENV = "", CONDA_PREFIX = "" }, function()
      local pythons = Discover.pythons({ start_dir = root .. "/subdir" })
      assert.is_true(#pythons >= 1)
      local found
      for _, p in ipairs(pythons) do
        if p.path:match("/.venv/bin/python$") then found = p end
      end
      assert.is_not_nil(found)
    end)
  end)

  it("dedupes when active venv == project venv", function()
    local root = mktree({ ".venv/bin/python" })
    with_env({ VIRTUAL_ENV = root .. "/.venv", CONDA_PREFIX = "" }, function()
      local pythons = Discover.pythons({ start_dir = root })
      assert.equals(1, #pythons)
    end)
  end)

  it("returns empty when no env is active and no project venv exists", function()
    local root = mktree({ "subdir/notebook.ipynb" })
    with_env({ VIRTUAL_ENV = "", CONDA_PREFIX = "" }, function()
      local pythons = Discover.pythons({ start_dir = root .. "/subdir" })
      assert.equals(0, #pythons)
    end)
  end)

  it("finds project-local 'venv' (without leading dot)", function()
    -- The walk covers .venv / venv / env; only .venv was tested previously.
    local root = mktree({ "venv/bin/python" })
    with_env({ VIRTUAL_ENV = "", CONDA_PREFIX = "" }, function()
      local pythons = Discover.pythons({ start_dir = root })
      local found
      for _, p in ipairs(pythons) do
        if p.path:match("/venv/bin/python$") then found = p end
      end
      assert.is_not_nil(found)
    end)
  end)

  it("finds project-local 'env' directory", function()
    local root = mktree({ "env/bin/python" })
    with_env({ VIRTUAL_ENV = "", CONDA_PREFIX = "" }, function()
      local pythons = Discover.pythons({ start_dir = root })
      local found
      for _, p in ipairs(pythons) do
        if p.path:match("/env/bin/python$") then found = p end
      end
      assert.is_not_nil(found)
    end)
  end)

  it("walks up multiple directory levels (not just one)", function()
    -- .venv is 3 levels above the notebook.
    local root = mktree({
      ".venv/bin/python",
      "a/b/c/notebook.ipynb",
    })
    with_env({ VIRTUAL_ENV = "", CONDA_PREFIX = "" }, function()
      local pythons = Discover.pythons({ start_dir = root .. "/a/b/c" })
      assert.is_true(#pythons >= 1)
    end)
  end)

  it("dedupes using fs_realpath (handles intermediate symlinks)", function()
    -- Create a real venv and a symlink to its parent. The active VIRTUAL_ENV
    -- points through the symlink path; the project venv resolves via the
    -- real path. fs_realpath canonicalizes both, so dedup catches the
    -- duplicate.
    local root = mktree({ "proj/.venv/bin/python" })
    local link = root .. "/symlink_to_proj"
    pcall(vim.loop.fs_symlink, root .. "/proj", link)
    if not vim.loop.fs_stat(link) then return end  -- skip if no symlink support
    with_env({
      VIRTUAL_ENV = link .. "/.venv",
      CONDA_PREFIX = "",
    }, function()
      local pythons = Discover.pythons({ start_dir = root .. "/proj" })
      -- After realpath canonicalization, both should resolve to the same
      -- physical python; only one entry should survive.
      assert.equals(1, #pythons)
    end)
  end)
end)

describe("discover.short_label", function()
  it("collapses .venv paths to '.venv (project)'", function()
    assert.equals(".venv (myproj)",
      Discover.short_label("/home/x/myproj/.venv/bin/python"))
  end)

  it("returns the full path for non-venv interpreters", function()
    assert.equals("/usr/bin/python3",
      Discover.short_label("/usr/bin/python3"))
  end)

  it("collapses 'venv' (without leading dot) to 'venv (project)'", function()
    assert.equals("venv (proj)",
      Discover.short_label("/home/x/proj/venv/bin/python"))
  end)

  it("collapses 'env' parent to 'env (project)'", function()
    assert.equals("env (proj)",
      Discover.short_label("/home/x/proj/env/bin/python"))
  end)
end)
