local N = {}

N.blocks = vim.api.nvim_create_namespace("ipynb_blocks")
N.preview = vim.api.nvim_create_namespace("ipynb_preview")
N.execvirt = vim.api.nvim_create_namespace("ipynb_exec_virt")
N.block_cols = vim.api.nvim_create_namespace("notebook_blocks")
N.headers = vim.api.nvim_create_namespace("ipynb_headers")

return N
