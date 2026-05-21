-- Default key bindings for Mercury. To change a binding, override before
-- calling require("mercury").setup{}, or set `keymaps.enabled = false` in
-- setup() and bind the commands yourself.
--
--   require("mercury.keymaps").defaults["<S-CR>"] = nil   -- disable one
--   require("mercury.keymaps").defaults["<leader>x"] = "NotebookExec"
--   require("mercury").setup{}
--
-- The values are :NotebookXxx command names (no leading colon).

local M = {}

M.defaults = {
  -- execution
  ["<S-CR>"]      = "NotebookExec",            -- run cell + advance
  ["<C-CR>"]      = "NotebookExecAlone",       -- run cell, no advance

  -- cell creation / movement / navigation
  ["]n"]          = "NotebookCellNewBelow",
  ["[n"]          = "NotebookCellNewAbove",
  ["]m"]          = "NotebookCellMoveDown",
  ["[m"]          = "NotebookCellMoveUp",
  ["]c"]          = "NotebookCellNext",
  ["[c"]          = "NotebookCellPrev",

  -- cell editing
  ["<leader>cd"]  = "NotebookCellDelete",
  ["<leader>cM"]  = "NotebookCellMergeBelow",
  ["<leader>cc"]  = "NotebookCellToCode",
  ["<leader>cm"]  = "NotebookCellToMarkdown",
  ["<leader>cs"]  = "NotebookCellSelect",
  ["<leader>cD"]  = "NotebookCellDuplicate",
  ["<leader>cy"]  = "NotebookCellCopy",
  ["<leader>cp"]  = "NotebookCellPaste",

  -- output
  ["<leader>oo"]  = "NotebookOutputToggle",    -- collapse/expand
  ["<leader>oc"]  = "NotebookOutputClear",
  ["<leader>oC"]  = "NotebookOutputClearAll",
  ["<leader>oy"]  = "NotebookOutputCopy",
  ["<leader>ov"]  = "NotebookOutputView",

  -- kernel
  ["<leader>kk"]  = "NotebookKernelSelect",
  ["<leader>kr"]  = "NotebookKernelRestart",
  ["<leader>kR"]  = "NotebookKernelRestartClear",
  ["<leader>ki"]  = "NotebookKernelInterrupt",
  ["<leader>ks"]  = "NotebookKernelStop",
}

-- Keys that should also fire while in insert mode — typical "execute and
-- keep typing" workflow. <cmd> dispatch doesn't change mode, so the user
-- stays in insert mode at the new cursor position after the command runs.
M.insert_mode_keys = {
  ["<S-CR>"] = true,
  ["<C-CR>"] = true,
}

function M.apply(buf)
  for lhs, cmd in pairs(M.defaults) do
    if cmd ~= nil then
      local rhs = "<cmd>" .. cmd .. "<CR>"
      local opts = { buffer = buf, silent = true, desc = "Mercury: " .. cmd }
      vim.keymap.set("n", lhs, rhs, opts)
      if M.insert_mode_keys[lhs] then
        vim.keymap.set("i", lhs, rhs, opts)
      end
    end
  end
end

return M
