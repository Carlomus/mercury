-- Minimal init for plenary's headless test runner.
-- Run with:
--   nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"
--
-- Resolves plenary from lazy.nvim's default install path, then prepends this
-- plugin's root to runtimepath so `require("mercury")` finds
-- <root>/lua/mercury/init.lua. The plugin root is derived from this file's
-- own path rather than hard-coded, so tests work whether the plugin lives
-- under ~/.config/nvim or anywhere else.

local plenary = vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
vim.opt.rtp:append(plenary)

local this = debug.getinfo(1, "S").source
local this_path = (this:sub(1, 1) == "@") and this:sub(2) or this
-- tests/minimal_init.lua -> plugin root (two parent dirs)
local plugin_root = vim.fn.fnamemodify(this_path, ":p:h:h")
vim.opt.rtp:prepend(plugin_root)

vim.cmd("runtime plugin/plenary.vim")

-- Deterministic random for id generation.
math.randomseed(1)
