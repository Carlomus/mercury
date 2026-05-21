local Keymaps = require("mercury.keymaps")

local function has(maps, lhs)
  for _, m in ipairs(maps) do
    if m.lhs == lhs then return m end
  end
  return nil
end

describe("keymaps", function()
  it("execution keys bind both normal and insert mode", function()
    local buf = vim.api.nvim_create_buf(false, true)
    Keymaps.apply(buf)
    local n = vim.api.nvim_buf_get_keymap(buf, "n")
    local i = vim.api.nvim_buf_get_keymap(buf, "i")
    assert.is_not_nil(has(n, "<S-CR>"))
    assert.is_not_nil(has(i, "<S-CR>"))
    assert.is_not_nil(has(n, "<C-CR>"))
    assert.is_not_nil(has(i, "<C-CR>"))
  end)

  it("structural keys bind normal mode only", function()
    local buf = vim.api.nvim_create_buf(false, true)
    Keymaps.apply(buf)
    local i = vim.api.nvim_buf_get_keymap(buf, "i")
    assert.is_nil(has(i, "]c"))
    assert.is_nil(has(i, "<leader>cd"))
  end)

  it("uses <cmd> dispatch (doesn't pollute insert mode with :commands)", function()
    local buf = vim.api.nvim_create_buf(false, true)
    Keymaps.apply(buf)
    local m = has(vim.api.nvim_buf_get_keymap(buf, "n"), "<S-CR>")
    assert.is_not_nil(m)
    assert.matches("<[Cc]md>NotebookExec", m.rhs or "")
  end)

  it("user can unbind a default by setting Keymaps.defaults[lhs] = nil", function()
    -- The pattern users follow to disable a default. The apply() loop
    -- skips entries with cmd == nil.
    local saved = Keymaps.defaults["<S-CR>"]
    Keymaps.defaults["<S-CR>"] = nil
    local buf = vim.api.nvim_create_buf(false, true)
    Keymaps.apply(buf)
    local n = vim.api.nvim_buf_get_keymap(buf, "n")
    assert.is_nil(has(n, "<S-CR>"))
    -- Restore.
    Keymaps.defaults["<S-CR>"] = saved
  end)

  it("user can override a default with a custom command", function()
    local saved = Keymaps.defaults["<S-CR>"]
    Keymaps.defaults["<S-CR>"] = "NotebookExecAlone"
    local buf = vim.api.nvim_create_buf(false, true)
    Keymaps.apply(buf)
    local m = has(vim.api.nvim_buf_get_keymap(buf, "n"), "<S-CR>")
    assert.is_not_nil(m)
    assert.matches("NotebookExecAlone", m.rhs or "")
    Keymaps.defaults["<S-CR>"] = saved
  end)

  it("M._setup_buffer_keymaps respects keymaps.enabled = false", function()
    -- The gate lives in init.lua's _setup_buffer_keymaps. If disabled,
    -- the user gets no keymaps at all.
    local Mercury = require("mercury")
    local Cfg = require("mercury.config")
    Cfg.setup({ keymaps = { enabled = false } })
    local buf = vim.api.nvim_create_buf(false, true)
    Mercury._setup_buffer_keymaps(buf)
    local n = vim.api.nvim_buf_get_keymap(buf, "n")
    assert.is_nil(has(n, "<S-CR>"))
    Cfg.setup({})  -- restore
  end)
end)
