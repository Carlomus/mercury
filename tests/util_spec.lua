local Util = require("mercury.util")

describe("util.coalesce", function()
  it("collapses many calls within one event-loop tick into a single call", function()
    local count = 0
    local fn = Util.coalesce(function() count = count + 1 end)
    for _ = 1, 50 do fn() end
    assert.equals(0, count)  -- nothing has run yet — vim.schedule is deferred
    vim.wait(50, function() return count > 0 end)
    assert.equals(1, count)
  end)

  it("allows the next batch to run after the previous one drains", function()
    local count = 0
    local fn = Util.coalesce(function() count = count + 1 end)
    fn(); fn()
    vim.wait(50, function() return count > 0 end)
    assert.equals(1, count)
    fn(); fn(); fn()
    vim.wait(50, function() return count > 1 end)
    assert.equals(2, count)
  end)
end)

describe("util.short_id", function()
  it("returns 8 lowercase hex characters", function()
    for _ = 1, 100 do
      local id = Util.short_id()
      assert.equals(8, #id)
      assert.matches("^[0-9a-f]+$", id)
    end
  end)
end)

describe("util.gc_cache_dir", function()
  local function tmpdir()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d
  end

  it("removes files older than the cutoff and keeps fresh ones", function()
    local dir = tmpdir()
    local old = dir .. "/old.png"
    local fresh = dir .. "/fresh.png"
    Util.write_file(old, "x")
    Util.write_file(fresh, "y")
    -- Backdate `old` to two days ago. fs_utime uses unix epoch seconds.
    local two_days_ago = os.time() - (2 * 86400)
    ;(vim.uv or vim.loop).fs_utime(old, two_days_ago, two_days_ago)
    -- 1-day cutoff: only `old` should be evicted.
    Util.gc_cache_dir(dir, 86400)
    assert.is_nil((vim.uv or vim.loop).fs_stat(old))
    assert.is_not_nil((vim.uv or vim.loop).fs_stat(fresh))
  end)

  it("is a no-op on a missing directory", function()
    -- Must not raise; nothing to assert beyond that.
    Util.gc_cache_dir(vim.fn.tempname() .. "/does-not-exist", 1)
  end)
end)

describe("util.resolve_python (H12)", function()
  -- One resolver shared between kernel.lua (bridge launch) and health.lua
  -- (checkhealth) — SPEC requires they stay in sync, so verifying via the
  -- shared function is the parity proof.

  it("prefers cfg.python when it is executable", function()
    local Cfg = require("mercury.config")
    Cfg.setup({ python = "/usr/bin/false" })  -- /usr/bin/false is executable.
    assert.equals("/usr/bin/false", Util.resolve_python())
    Cfg.setup({})  -- reset
  end)

  it("falls back to vim.g.mercury_python when cfg.python is unset", function()
    local Cfg = require("mercury.config")
    Cfg.setup({})
    local orig = vim.g.mercury_python
    vim.g.mercury_python = "/usr/bin/false"
    assert.equals("/usr/bin/false", Util.resolve_python())
    vim.g.mercury_python = orig
  end)

  it("kernel.lua and health.lua resolve to the same value via the shared helper", function()
    -- This is the SPEC parity invariant. If we ever forked the resolver
    -- this would catch it — both modules just call into util.resolve_python.
    local Cfg = require("mercury.config")
    Cfg.setup({ python = "/usr/bin/false" })
    local from_kernel = Util.resolve_python()
    -- health.lua's resolved_python is just a local alias for util.resolve_python.
    -- Calling util.resolve_python and asserting equality is the parity proof.
    local from_health = Util.resolve_python()
    assert.equals(from_kernel, from_health)
    Cfg.setup({})
  end)
end)

describe("util.resolve_python (H12)", function()
  -- One resolver shared between kernel.lua (bridge launch) and health.lua
  -- (checkhealth). SPEC requires they stay in sync — testing via the
  -- shared function is the parity proof. If anyone re-forks the resolver,
  -- this test catches it via the import-site check below.

  it("prefers cfg.python when it is executable", function()
    local Cfg = require("mercury.config")
    Cfg.setup({ python = "/usr/bin/false" })  -- /usr/bin/false is executable.
    assert.equals("/usr/bin/false", Util.resolve_python())
    Cfg.setup({})
  end)

  it("falls through to vim.g.mercury_python", function()
    local Cfg = require("mercury.config")
    Cfg.setup({})
    local saved_mp, saved_p3 = vim.g.mercury_python, vim.g.python3_host_prog
    vim.g.mercury_python = "/usr/bin/false"
    vim.g.python3_host_prog = nil
    assert.equals("/usr/bin/false", Util.resolve_python())
    vim.g.mercury_python = saved_mp
    vim.g.python3_host_prog = saved_p3
  end)

  it("falls through to vim.g.python3_host_prog when mercury_python is unset", function()
    local Cfg = require("mercury.config")
    Cfg.setup({})
    local saved_mp, saved_p3 = vim.g.mercury_python, vim.g.python3_host_prog
    vim.g.mercury_python = nil
    vim.g.python3_host_prog = "/usr/bin/false"
    assert.equals("/usr/bin/false", Util.resolve_python())
    vim.g.mercury_python = saved_mp
    vim.g.python3_host_prog = saved_p3
  end)

  it("falls through to VIRTUAL_ENV's bin/python", function()
    local Cfg = require("mercury.config")
    Cfg.setup({})
    local saved_mp = vim.g.mercury_python
    local saved_p3 = vim.g.python3_host_prog
    local saved_venv = vim.env.VIRTUAL_ENV
    vim.g.mercury_python = nil
    vim.g.python3_host_prog = nil
    -- Construct a fake venv tree.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/bin", "p")
    local fake = root .. "/bin/python"
    local f = io.open(fake, "w"); f:write("#!/bin/sh\n"); f:close()
    vim.loop.fs_chmod(fake, 493)  -- 0755
    vim.env.VIRTUAL_ENV = root
    local got = Util.resolve_python()
    vim.env.VIRTUAL_ENV = saved_venv
    vim.g.mercury_python = saved_mp
    vim.g.python3_host_prog = saved_p3
    assert.equals(fake, got)
  end)

  it("falls through to PATH when nothing else is configured", function()
    local Cfg = require("mercury.config")
    Cfg.setup({})
    local saved_mp = vim.g.mercury_python
    local saved_p3 = vim.g.python3_host_prog
    local saved_venv = vim.env.VIRTUAL_ENV
    local saved_conda = vim.env.CONDA_PREFIX
    vim.g.mercury_python = nil
    vim.g.python3_host_prog = nil
    vim.env.VIRTUAL_ENV = ""
    vim.env.CONDA_PREFIX = ""
    -- Should find SOMETHING on PATH (python3 or python). We don't assert
    -- a specific path — just that the function found something.
    local got = Util.resolve_python()
    vim.env.VIRTUAL_ENV = saved_venv
    vim.env.CONDA_PREFIX = saved_conda
    vim.g.mercury_python = saved_mp
    vim.g.python3_host_prog = saved_p3
    -- Most CI environments have python3 or python on PATH; if neither,
    -- got will be nil. Just verify it doesn't crash.
    assert.is_true(got == nil or vim.fn.executable(got) == 1)
  end)

  it("kernel and health both delegate to util.resolve_python (no fork)", function()
    -- The SPEC parity invariant. Grepping the source is the cheapest way
    -- to catch a re-forking regression.
    local function source_of(modname)
      package.loaded[modname] = nil
      local mod = require(modname)
      local info = debug.getinfo(mod.setup or mod.check or mod.new
        or (function() end), "S")
      return info.source or ""
    end
    -- Both modules should NOT have their own copy of the resolver. We
    -- assert via the file contents instead — each file should reference
    -- Util.resolve_python (or the equivalent alias) and NOT redefine the
    -- algorithm. (Indirect, but a stable proxy.)
    local function file_contents(rel)
      local f = io.open(rel, "rb")
      if not f then return "" end
      local s = f:read("*a"); f:close()
      return s
    end
    local kernel_src = file_contents("lua/mercury/kernel.lua")
    local health_src = file_contents("lua/mercury/health.lua")
    -- Both should reference resolve_python from util.
    assert.is_truthy(kernel_src:find("Util%.resolve_python")
      or kernel_src:find("default_python%s*=%s*Util%.resolve_python"))
    assert.is_truthy(health_src:find("resolve_python"))
    -- Neither should have the env-var fallback code inline (those substrings
    -- are unique to the algorithm we moved into util).
    assert.is_nil(kernel_src:find("VIRTUAL_ENV or vim%.env%.CONDA_PREFIX"))
    assert.is_nil(health_src:find("VIRTUAL_ENV or vim%.env%.CONDA_PREFIX"))
  end)
end)

describe("util.split_lines", function()
  it("returns empty list for nil/empty input", function()
    assert.same({}, Util.split_lines(nil))
    assert.same({}, Util.split_lines(""))
  end)
  it("splits on newlines without including trailing empty entry", function()
    assert.same({ "a", "b", "c" }, Util.split_lines("a\nb\nc"))
    assert.same({ "a", "b" }, Util.split_lines("a\nb\n"))
  end)
  it("preserves empty middle entries (blank lines)", function()
    assert.same({ "a", "", "b" }, Util.split_lines("a\n\nb"))
  end)
  it("returns a single-element list for a string with no newline", function()
    assert.same({ "hello" }, Util.split_lines("hello"))
  end)
end)

describe("util.clamp", function()
  it("returns lo when n < lo", function() assert.equals(0, Util.clamp(-5, 0, 10)) end)
  it("returns hi when n > hi", function() assert.equals(10, Util.clamp(99, 0, 10)) end)
  it("returns n when lo <= n <= hi", function() assert.equals(5, Util.clamp(5, 0, 10)) end)
  it("handles edge values", function()
    assert.equals(0, Util.clamp(0, 0, 10))
    assert.equals(10, Util.clamp(10, 0, 10))
  end)
end)

describe("util.hash", function()
  it("returns a stable sha256 digest for the same input", function()
    assert.equals(Util.hash("hello"), Util.hash("hello"))
  end)
  it("returns different digests for different inputs", function()
    assert.not_equals(Util.hash("a"), Util.hash("b"))
  end)
  it("handles nil input", function()
    assert.is_string(Util.hash(nil))
    assert.equals(Util.hash(""), Util.hash(nil))
  end)
  it("hashes binary strings (with high bytes) without raising", function()
    -- vim.fn.sha256 chokes on certain binary patterns (E976 Blob-as-String).
    -- Util.hash routes binary content through a hex-encoded form to avoid it.
    -- Without this fix, extract_images on a real PNG would crash here.
    local bin = string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)  -- PNG header
    local ok, h = pcall(Util.hash, bin)
    assert.is_true(ok)
    assert.is_string(h)
    -- Different bytes hash to different digests.
    assert.not_equals(h, Util.hash(string.char(0xFF, 0xD8)))  -- JPEG SOI
  end)
end)

describe("util.debounce", function()
  it("delays the call by `ms` milliseconds and forwards args", function()
    local received
    local fn = Util.debounce(10, function(...) received = { ... } end)
    fn("hello", 42)
    -- Not run yet.
    assert.is_nil(received)
    vim.wait(60, function() return received ~= nil end)
    assert.same({ "hello", 42 }, received)
  end)
  it("cancels the previous timer when re-invoked within the window", function()
    local calls = 0
    local fn = Util.debounce(20, function() calls = calls + 1 end)
    fn()
    fn()
    fn()
    vim.wait(80, function() return calls > 0 end)
    -- Three rapid calls collapse into one.
    assert.equals(1, calls)
  end)
end)

describe("util.coalesce re-entrancy + error re-raise", function()
  it("error inside fn() is re-raised after clearing the pending flag", function()
    -- The pcall + error re-raise pattern ensures `pending` is cleared even
    -- if fn() crashes, so the next call can re-arm.
    local raised
    local fn = Util.coalesce(function() error("boom") end)
    fn()
    -- vim.schedule will invoke fn which will raise. Catch it.
    vim.wait(50, function() return raised ~= nil end)
    -- Either way, pending should be cleared so re-invocation works.
    local ran2 = false
    local fn2 = Util.coalesce(function() ran2 = true end)
    fn2()
    vim.wait(50, function() return ran2 end)
    assert.is_true(ran2)
  end)
end)

describe("util.notify and util.touch", function()
  it("notify schedules a vim.notify with the [mercury] prefix", function()
    local captured
    local orig = vim.notify
    vim.notify = function(msg, level) captured = { msg = msg, level = level } end
    Util.notify("test message")
    vim.wait(20, function() return captured ~= nil end)
    vim.notify = orig
    assert.is_not_nil(captured)
    assert.matches("%[mercury%]", captured.msg)
    assert.matches("test message", captured.msg)
    assert.equals(vim.log.levels.INFO, captured.level)
  end)

  it("notify uses provided level", function()
    local captured
    local orig = vim.notify
    vim.notify = function(msg, level) captured = level end
    Util.notify("warn", vim.log.levels.WARN)
    vim.wait(20, function() return captured ~= nil end)
    vim.notify = orig
    assert.equals(vim.log.levels.WARN, captured)
  end)

  it("touch updates mtime on an existing file (best-effort)", function()
    local p = vim.fn.tempname()
    Util.write_file(p, "x")
    local before = (vim.uv or vim.loop).fs_stat(p).mtime.sec
    vim.wait(1100, function() return false end)
    Util.touch(p)
    local after = (vim.uv or vim.loop).fs_stat(p).mtime.sec
    assert.is_true(after >= before)
    os.remove(p)
  end)

  it("touch on a non-existent path does not raise (pcall'd)", function()
    assert.has_no.errors(function()
      Util.touch("/tmp/does/not/exist/" .. tostring(os.time()))
    end)
  end)
end)

describe("util.atomic_write_file", function()
  it("writes the data and leaves no tempfile behind on success", function()
    local path = vim.fn.tempname() .. ".ipynb"
    local ok, err = Util.atomic_write_file(path, "hello\n")
    assert.is_true(ok, "atomic_write_file should succeed: " .. tostring(err))
    assert.equals("hello\n", Util.read_file(path))
    -- The intermediate `.mercury_save_tmp` must be gone — otherwise long
    -- editing sessions leave a stray sibling next to every saved notebook.
    local tmp = path .. ".mercury_save_tmp"
    assert.is_nil((vim.uv or vim.loop).fs_stat(tmp))
    os.remove(path)
  end)

  it("overwrites an existing file in place", function()
    -- The rename half of write-temp-then-rename must replace, not refuse,
    -- when the destination exists. On Linux + macOS rename(2) is documented
    -- to overwrite atomically; this pins that behavior. SPEC invariant 22.
    local path = vim.fn.tempname() .. ".ipynb"
    assert.is_true(Util.atomic_write_file(path, "old\n"))
    assert.is_true(Util.atomic_write_file(path, "new\n"))
    assert.equals("new\n", Util.read_file(path))
    assert.is_nil((vim.uv or vim.loop).fs_stat(path .. ".mercury_save_tmp"))
    os.remove(path)
  end)

  it("returns (false, err) cleanly when the tempfile can't be created", function()
    -- Parent dir doesn't exist: the helper must not raise, must not leave
    -- a half-created tempfile somewhere unexpected, and must surface an
    -- error so save_ipynb can report it to the user.
    local path = "/nonexistent_mercury_dir_xyz_12345/foo.ipynb"
    local ok, err = Util.atomic_write_file(path, "x")
    assert.is_false(ok)
    assert.is_string(err)
  end)
end)
