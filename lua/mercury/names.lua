local N = {}

N.blocks = vim.api.nvim_create_namespace("ipynb_blocks_input")
N.blocks_output = vim.api.nvim_create_namespace("ipynb_blocks_output")
N.headers = vim.api.nvim_create_namespace("ipynb_headers")
N.block_cols = vim.api.nvim_create_namespace("notebook_blocks")
N.preview = vim.api.nvim_create_namespace("ipynb_preview_legacy")

return N
