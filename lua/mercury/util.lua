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

-- Stable content hash for cache keys. Wraps vim.fn.sha256 so we don't need
-- a bit-ops library or a hand-rolled SHA1. Truncation is the caller's job.
function M.hash(data)
  return vim.fn.sha256(data or "")
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
