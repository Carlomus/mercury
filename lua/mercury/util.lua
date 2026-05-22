local M = {}

function M.split_lines(s)
  s = s or ""
  if s == "" then return {} end
  local out = {}
  local start = 1
  while true do
    local nl = s:find("\n", start, true)
    if not nl then
      local tail = s:sub(start)
      if tail ~= "" then out[#out + 1] = tail end
      break
    end
    out[#out + 1] = s:sub(start, nl - 1)
    start = nl + 1
  end
  return out
end

function M.read_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

function M.write_file(path, data)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(data)
  f:close()
  return true
end

-- Atomic write via a sibling tempfile + POSIX rename. A kill -9 / power
-- loss during :w would otherwise corrupt the notebook; rename(2) is atomic
-- within a single filesystem so observers see either the previous complete
-- contents or the new ones, never a torn write. The tempfile lives next to
-- the target so the rename stays intra-filesystem. SPEC Invariant 22.
--
-- fsync failures are surfaced (return false, err) rather than swallowed:
-- a disk-full / hardware-error fsync would otherwise let the rename proceed
-- with un-durable bytes, silently downgrading atomicity. The caller
-- (save_ipynb) prefers to refuse the save and let the user retry.
--
-- A cross-filesystem rename (EXDEV) is reported as a clear, actionable
-- error rather than retried with a non-atomic copy: the tempfile is by
-- construction adjacent to the target path (`<path>.mercury_save_tmp`),
-- so EXDEV here means the target's *directory* is on a different
-- filesystem than where the tempfile somehow landed — very unusual, but
-- best surfaced explicitly so the user can investigate.
--
-- Uses uv.fs_rename (not os.rename) so tests can stub it.
function M.atomic_write_file(path, data)
  local tmp = path .. ".mercury_save_tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return false, err end
  local ok, werr = pcall(function() f:write(data) end)
  f:close()
  if not ok then
    pcall(os.remove, tmp)
    return false, werr
  end
  local uv = vim.uv or vim.loop
  if uv and uv.fs_open then
    local fd = uv.fs_open(tmp, "r", 438)
    if fd then
      local fsync_ok, fsync_err = pcall(uv.fs_fsync, fd)
      uv.fs_close(fd)
      if not fsync_ok or fsync_err == false then
        pcall(os.remove, tmp)
        return false, "fsync failed: " .. tostring(fsync_err or "unknown")
      end
    end
  end
  local ok2, rerr = pcall(uv.fs_rename, tmp, path)
  if not ok2 or rerr == false then
    pcall(os.remove, tmp)
    local msg = tostring(rerr or "rename failed")
    if msg:find("EXDEV") then
      msg = "cross-filesystem rename refused (EXDEV): tempfile and target "
        .. "on different filesystems; tried to move "
        .. tostring(tmp) .. " → " .. tostring(path)
    end
    return false, msg
  end
  return true
end

-- Single source of truth for "which python should mercury use?". Both
-- kernel.lua (bridge launch) and health.lua (:checkhealth) delegate here so
-- a divergence between "the interpreter we report on" and "the interpreter
-- we actually run" is impossible. SPEC § "Health" calls this out explicitly.
--
-- Priority:
--   1. Cfg.get().python
--   2. vim.g.mercury_python
--   3. vim.g.python3_host_prog
--   4. $VIRTUAL_ENV/bin/python
--   5. $CONDA_PREFIX/bin/python  (only if VIRTUAL_ENV is unset)
--   6. python3 on PATH
--   7. python on PATH
function M.resolve_python()
  local ok_cfg, Cfg = pcall(require, "mercury.config")
  if ok_cfg then
    local cfg = Cfg.get()
    if cfg and cfg.python and vim.fn.executable(cfg.python) == 1 then
      return cfg.python
    end
  end
  if vim.g.mercury_python and vim.fn.executable(vim.g.mercury_python) == 1 then
    return vim.g.mercury_python
  end
  if vim.g.python3_host_prog and vim.fn.executable(vim.g.python3_host_prog) == 1 then
    return vim.g.python3_host_prog
  end
  local venv = vim.env.VIRTUAL_ENV
  if venv and venv ~= "" then
    local sep = package.config:sub(1, 1)
    local cand = venv .. (sep == "\\" and "\\Scripts\\python.exe" or "/bin/python")
    if vim.fn.executable(cand) == 1 then return cand end
  end
  local conda = vim.env.CONDA_PREFIX
  if conda and conda ~= "" and (not venv or venv == "") then
    local sep = package.config:sub(1, 1)
    local cand = conda .. (sep == "\\" and "\\python.exe" or "/bin/python")
    if vim.fn.executable(cand) == 1 then return cand end
  end
  if vim.fn.executable("python3") == 1 then return "python3" end
  if vim.fn.executable("python") == 1 then return "python" end
  return nil
end

function M.tmpfile(suffix)
  return vim.fn.tempname() .. (suffix or "")
end

function M.short_id()
  -- Prefer libuv's CSPRNG so we don't share global math.random state with
  -- the rest of the editor — otherwise a third-party plugin that reseeds
  -- math.random could produce id collisions across notebooks in one session.
  local uv = vim.uv or vim.loop
  if uv and uv.random then
    local ok, bytes = pcall(uv.random, 4)
    if ok and type(bytes) == "string" and #bytes == 4 then
      return ("%02x%02x%02x%02x"):format(bytes:byte(1, 4))
    end
  end
  local hex = "0123456789abcdef"
  local out = {}
  for _ = 1, 8 do
    out[#out + 1] = hex:sub(math.random(1, 16), math.random(1, 16))
  end
  return table.concat(out)
end

-- Stable content hash for cache keys. Pure-Lua FNV-1a 64-bit, hex-formatted.
-- We can't delegate to vim.fn.sha256 because it raises "E976: Using a Blob
-- as a String" on bytes outside printable ASCII — and PNG / JPEG payloads
-- always contain such bytes. Truncation is the caller's job.
function M.hash(data)
  data = data or ""
  -- FNV-1a 64 with 32-bit halves so it works on Lua 5.1 (no native int64).
  -- Tracks h = h_hi*2^32 + h_lo and multiplies by 64-bit PRIME by hand.
  local h_hi, h_lo = 0xcbf29ce4, 0x84222325
  local PRIME_HI, PRIME_LO = 0x00000100, 0x000001b3
  for i = 1, #data do
    -- bit.bxor is provided by LuaJIT (nvim bundles LuaJIT, so this is safe).
    h_lo = bit.bxor(h_lo, data:byte(i))
    local lo_lo = h_lo * PRIME_LO
    local lo_hi = h_hi * PRIME_LO
    local hi_lo = h_lo * PRIME_HI
    local new_lo = lo_lo % 4294967296
    local carry = math.floor(lo_lo / 4294967296)
    local new_hi = (lo_hi + hi_lo + carry) % 4294967296
    h_lo = new_lo
    h_hi = new_hi
  end
  return string.format("%08x%08x", h_hi, h_lo)
end

function M.debounce(ms, fn)
  local timer
  return function(...)
    local args = { ... }
    if timer then timer:stop() end
    timer = vim.defer_fn(function()
      timer = nil
      fn(unpack(args))
    end, ms)
  end
end

-- Coalesce many calls within one event-loop tick into a single invocation.
-- Designed for kernel-driven render triggers: streaming output emits one
-- on_change per chunk; without coalescing, a tqdm loop would issue thousands
-- of renders per second. With coalescing it's one render per tick regardless.
function M.coalesce(fn)
  local pending = false
  return function()
    if pending then return end
    pending = true
    vim.schedule(function()
      pending = false
      fn()
    end)
  end
end

function M.clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

function M.notify(msg, level)
  vim.schedule(function()
    vim.notify("[mercury] " .. msg, level or vim.log.levels.INFO)
  end)
end

-- Bump mtime on a cache file so age-based GC treats it as recently-used.
-- Cheap and best-effort — failure to touch is fine, the file just becomes
-- a slightly earlier eviction candidate.
function M.touch(path)
  local now = os.time()
  pcall((vim.uv or vim.loop).fs_utime, path, now, now)
end

-- Sweep files in `dir` whose mtime is older than `max_age_seconds` (default
-- 30 days). Used by the image and latex caches, both of which are keyed by
-- content hash, so eviction never loses data — a future render will recreate
-- the file from the source bytes.
function M.gc_cache_dir(dir, max_age_seconds)
  max_age_seconds = max_age_seconds or (30 * 86400)
  if vim.fn.isdirectory(dir) == 0 then return end
  local uv = vim.uv or vim.loop
  local now = os.time()
  for _, name in ipairs(vim.fn.readdir(dir)) do
    local path = dir .. "/" .. name
    local stat = uv.fs_stat(path)
    if stat and stat.type == "file"
        and now - (stat.mtime and stat.mtime.sec or 0) > max_age_seconds then
      pcall(uv.fs_unlink, path)
    end
  end
end

return M
