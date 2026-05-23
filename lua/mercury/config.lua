local M = {}

M.defaults = {
  python = nil,
  bridge_cmd = nil,
  kernel = {
    mode = "local",        -- "local" or "existing"
    -- One of `name`, `python`, or `spec_path` selects the kernel in local
    -- mode (priority: python > spec_path > name; default falls back to
    -- "python3" if all are nil). `connection_file` applies in "existing"
    -- mode. See SPEC.md "Kernel selection".
    name = nil,            -- registered kernelspec name
    python = nil,          -- absolute path to a python executable
    spec_path = nil,       -- absolute path to a kernelspec directory
    connection_file = nil,
    -- Behavior when ipykernel / jupyter_client are not importable in the
    -- resolved python interpreter at bridge-launch time:
    --   "ask"  → prompt the user once (default; same as `nil`)
    --   true   → install silently into the resolved python with no prompt
    --   false  → never install; surface an error and let the user fix it
    --            manually (suitable for CI / containerised environments
    --            where pip is read-only)
    auto_install = "ask",
  },
  output = {
    max_preview_lines = 20,
    -- Upper bound on how many editor rows a single image can occupy. The
    -- default fits a typical 640x480 matplotlib figure with room to spare;
    -- bump higher for taller plots, lower if you want images to never
    -- dominate the screen.
    image_max_height_rows = 40,
    -- Terminal cell pixel size, used to compute how many editor rows an
    -- image should reserve and to clamp images to their natural pixel size
    -- (so a 32x32 icon doesn't get upscaled to 85% of the window).
    -- Override to match your terminal/font if image stacking looks off.
    cell_width_px = 8,
    cell_height_px = 16,
    show_status_pill = true,
  },
  latex = {
    rasterizer = "auto",
  },
  -- Save is non-blocking: a cell that's still running when :w fires writes
  -- as "not yet executed" in the JSON. The drain_timeout_ms knob is gone —
  -- there is no drain to time-out. See SPEC.md "Non-blocking save".
  save = {},
  keymaps = {
    enabled = true,
  },
  lsp = {
    -- Mask markdown cells so the LSP sees them as python comments. This is
    -- the primary mechanism — see SPEC.md "LSP integration".
    mask_markdown_cells = true,
    -- Safety net under the mask: drop any diagnostic that still lands on a
    -- markdown-cell row (e.g., from a client that bypasses client.notify).
    filter_diagnostics = true,
  },
  highlights = {
    code_bg = "#1e2530",
    markdown_bg = "#2a2030",
    separator_fg = "#7a8390",
    pill_running = "#f5d76e",
    pill_ok = "#7ec699",
    pill_error = "#e07b75",
    pill_queued = "#7a8390",
  },
}

M.values = vim.deepcopy(M.defaults)

-- ---------- validation ----------
--
-- Catches the common copy-paste mistakes (string where a number is expected,
-- typo'd enum, kernel = "python3" instead of kernel = { name = "python3" })
-- before they propagate into runtime crashes. Validation is non-fatal:
-- setup() merges defaults regardless and surfaces errors via WARN.
--
-- Schema is intentionally narrow: it enumerates the typed/bounded keys we
-- actually depend on. Unknown keys (e.g. user-added `highlights.foo`) pass
-- through unchallenged so users can extend the config however they like.

local SCHEMA = {
  python      = { type = "string?" },
  bridge_cmd  = { type = "string?" },
  kernel = {
    type = "table",
    fields = {
      mode            = { type = "string?", enum = { "local", "existing" } },
      name            = { type = "string?" },
      python          = { type = "string?" },
      spec_path       = { type = "string?" },
      connection_file = { type = "string?" },
      auto_install    = { type = "string|boolean?",
                          enum = { "ask" } },
    },
  },
  output = {
    type = "table",
    fields = {
      max_preview_lines     = { type = "number?", min = 0 },
      image_max_height_rows = { type = "number?", min = 1 },
      cell_width_px         = { type = "number?", min = 1 },
      cell_height_px        = { type = "number?", min = 1 },
      show_status_pill      = { type = "boolean?" },
    },
  },
  latex = {
    type = "table",
    fields = {
      rasterizer = { type = "string|function?" },
    },
  },
  save = { type = "table?" },
  keymaps = {
    type = "table",
    fields = {
      enabled = { type = "boolean?" },
    },
  },
  lsp = {
    type = "table",
    fields = {
      mask_markdown_cells = { type = "boolean?" },
      filter_diagnostics  = { type = "boolean?" },
    },
  },
  highlights = { type = "table?" },   -- free-form: arbitrary group names allowed
}

local function _type_ok(t, expected, value)
  -- expected is a `type` field from SCHEMA: e.g. "string?", "number", "string|function?"
  local optional = expected:sub(-1) == "?"
  if optional then expected = expected:sub(1, -2) end
  if value == nil then return optional end
  for choice in expected:gmatch("[^|]+") do
    if t == choice then return true end
  end
  return false
end

local function _validate_section(section, schema, path, errs)
  if type(section) ~= "table" then
    errs[#errs + 1] = path .. ": expected table, got " .. type(section)
    return
  end
  for k, spec in pairs(schema) do
    local v = section[k]
    local sub_path = path == "" and k or (path .. "." .. k)
    if v ~= nil then
      if not _type_ok(type(v), spec.type, v) then
        errs[#errs + 1] = sub_path .. ": expected "
          .. spec.type:gsub("%?$", "") .. ", got " .. type(v)
      elseif type(v) == "number" and spec.min and v < spec.min then
        errs[#errs + 1] = sub_path .. ": " .. tostring(v)
          .. " < min " .. tostring(spec.min)
      elseif type(v) == "string" and spec.enum then
        local found = false
        for _, e in ipairs(spec.enum) do if e == v then found = true; break end end
        if not found then
          errs[#errs + 1] = sub_path .. ": '" .. v .. "' not in {"
            .. table.concat(spec.enum, ", ") .. "}"
        end
      elseif type(v) == "table" and spec.fields then
        _validate_section(v, spec.fields, sub_path, errs)
      end
    end
  end
end

function M._validate(opts)
  local errs = {}
  if opts == nil then return errs end
  if type(opts) ~= "table" then
    errs[#errs + 1] = "config: expected table, got " .. type(opts)
    return errs
  end
  _validate_section(opts, SCHEMA, "", errs)
  return errs
end

function M.setup(opts)
  local errs = M._validate(opts)
  if #errs > 0 then
    vim.schedule(function()
      vim.notify(
        "[mercury] config invalid:\n  " .. table.concat(errs, "\n  "),
        vim.log.levels.WARN)
    end)
  end
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.values
end

function M.get() return M.values end

return M
