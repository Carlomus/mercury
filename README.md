# Mercury

A Neovim plugin that opens `.ipynb` files and gives you a Jupyter notebook
editing experience close to VS Code's: real cell separators, inline plots
(via [image.nvim]), collapsible outputs, kernel selection, save preserves
outputs.

See [`SPEC.md`](SPEC.md) for the design contract.

## Requirements

- Neovim ≥ 0.10
- Python ≥ 3.9 with `jupyter_client` and `ipykernel`
- Optional: [image.nvim](https://github.com/3rd/image.nvim) for inline plots
  (kitty graphics protocol)
- Optional: a LaTeX rasterizer (`pdflatex+pdftoppm`, `tex2png`, or `katex`)
  for `text/latex` outputs
- Optional: [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for the
  test suite

## Install

Mercury follows the canonical Neovim plugin layout (`lua/mercury/…`), so any
plugin manager can install it from a git URL or a local path.

### lazy.nvim

```lua
-- From a git remote:
{
  "you/mercury",
  dependencies = { "3rd/image.nvim", "nvim-treesitter/nvim-treesitter" },
  config = function() require("mercury").setup({}) end,
}

-- Or from a local checkout (e.g. while developing):
{
  dir = "~/code/mercury",
  name = "mercury",
  dependencies = { "3rd/image.nvim", "nvim-treesitter/nvim-treesitter" },
  config = function() require("mercury").setup({}) end,
}
```

### packer / vim-plug

The runtime path entries are conventional, so packer / vim-plug / mini.deps /
etc. all work — point them at the plugin root and `require("mercury")` will
resolve to `<root>/lua/mercury/init.lua`.

### Configuration (all keys optional; defaults shown)

```lua
require("mercury").setup({
  python = nil,                       -- path to python; auto-detected
  kernel = {
    mode = "local", name = nil,
    -- Behavior when `jupyter_client` / `ipykernel` aren't importable in
    -- the resolved python:
    --   "ask" (default)  — prompt once via vim.ui.select
    --   true             — silently `pip install` into the resolved python
    --   false            — never install; surface an error and let the
    --                      user fix it manually
    auto_install = "ask",
  },
  output = {
    max_preview_lines = 20,
    image_max_height_rows = 40,       -- cap on rows reserved per image
    cell_width_px = 8,                -- terminal cell pixel size
    cell_height_px = 16,              -- (used for image row math + natural-size clamp)
    show_status_pill = true,
  },
  latex  = { rasterizer = "auto" },   -- or "pdflatex+pdftoppm"/"tex2png"/"katex"/function
  lsp = {
    mask_markdown_cells = true,
    filter_diagnostics  = true,
  },
  keymaps = { enabled = true },
})
```

### Markdown highlighting inside markdown cells

Markdown highlighting "just works" — Mercury drives Treesitter's
`set_included_regions` from the parsed cell list, so prose in `[markdown]`
cells is parsed by the markdown parser regardless of `#` prefixes. No
injection query file or predicate setup is required.

## Commands

| Command | Default key | Effect |
|---|---|---|
| `:NotebookExec` | `<S-CR>` | Run cell + advance |
| `:NotebookExecAlone` | `<C-CR>` | Run cell without advancing |
| `:NotebookExecAll` | — | Run all code cells top-to-bottom |
| `:NotebookExecAbove` | — | Run all code cells above (inclusive) |
| `:NotebookCellNewBelow` | `]n` | New code cell below |
| `:NotebookCellNewAbove` | `[n` | New code cell above |
| `:NotebookCellMoveDown` | `]m` | Swap with next cell |
| `:NotebookCellMoveUp` | `[m` | Swap with previous cell |
| `:NotebookCellNext` | `]c` | Jump to next cell |
| `:NotebookCellPrev` | `[c` | Jump to previous cell (or this cell's body) |
| `:NotebookCellDelete` | `<leader>cd` | Delete current cell |
| `:NotebookCellMergeBelow` | `<leader>cM` | Merge with next cell |
| `:NotebookCellToCode` | `<leader>cc` | Convert to code |
| `:NotebookCellToMarkdown` | `<leader>cm` | Convert to markdown |
| `:NotebookCellSelect` | `<leader>cs` | Visual-select current cell |
| `:NotebookOutputToggle` | `<leader>oo` | Collapse/expand output |
| `:NotebookOutputClear` | `<leader>oc` | Clear current cell output |
| `:NotebookOutputClearAll` | `<leader>oC` | Clear all outputs |
| `:NotebookOutputCopy` | `<leader>oy` | Copy output text to `+` |
| `:NotebookOutputView` | `<leader>ov` | Open output in scratch buffer |
| `:NotebookKernelSelect` | `<leader>kk` | Pick a kernelspec |
| `:NotebookKernelRestart` | `<leader>kr` | Restart kernel |
| `:NotebookKernelRestartClear` | `<leader>kR` | Restart + clear outputs |
| `:NotebookKernelInterrupt` | `<leader>ki` | Interrupt current execution (Jupyter semantics: queued cells continue) |
| `:NotebookKernelStop` | `<leader>ks` | Stop kernel (cancels queued cells too) |

`<S-CR>` and `<C-CR>` are bound in **both normal and insert mode** so you
can execute a cell without leaving insert mode. The `<cmd>` dispatch
keeps you in the mode you were in.

### Customizing keymaps

All defaults live in `lua/mercury/keymaps.lua` as a flat table. Override
before calling `setup{}`:

```lua
local km = require("mercury.keymaps")
km.defaults["<S-CR>"]      = nil                      -- disable
km.defaults["<leader>x"]   = "NotebookExec"           -- rebind
km.defaults["<leader>kk"]  = "NotebookKernelSelect"   -- already default
require("mercury").setup({ keymaps = { enabled = true } })
```

If you'd rather wire everything yourself, set `keymaps = { enabled = false }`
and bind the `:Notebook*` commands directly.

## Folding

Cells fold at their `# %%` separator via a buffer-local `foldexpr`. Use
the standard fold keys: `zo` open, `zc` close, `za` toggle, `zR` open all,
`zM` close all. Output toggle is on `<leader>oo` to keep `zo` free.

## Lualine integration

`lua/mercury/lualine.lua` exposes ready-made components:

```lua
local mlual = require("mercury.lualine")
require("lualine").setup({
  sections = {
    lualine_x = {
      mlual.kernel,        -- ⎈ python3
      mlual.queue,         -- ⏳ run abc12 / ⏸ queue=2 / ✓ idle
      mlual.last_exec,     -- Out[7] 142 ms
      mlual.current_cell,  -- cell 3/12 py
      "encoding", "filetype",
    },
  },
})
```

Each component returns `""` for non-Mercury buffers, so they're invisible
when you're editing other files.

## Kernels

There are three ways to specify which kernel mercury should launch, all
under the default `kernel.mode = "local"`:

```lua
require("mercury").setup({
  -- (a) registered kernelspec — same as `jupyter kernelspec list`
  kernel = { name = "python3" },

  -- (b) absolute path to a python executable — mercury synthesizes a
  --     kernelspec on the fly (uses ipykernel_launcher in that python's env)
  kernel = { python = "/path/to/.venv/bin/python" },

  -- (c) absolute path to an existing kernelspec directory (containing
  --     kernel.json) that isn't registered with KernelSpecManager
  kernel = { spec_path = "/path/to/kernels/myenv" },

  -- (d) connect to an already-running kernel via a connection file
  kernel = { mode = "existing", connection_file = "/path/to/kernel-XXX.json" },
})
```

`python > spec_path > name` in priority order; setting one clears the
others on `:NotebookKernelSelect`.

### Auto-discovery

`:NotebookKernelSelect` builds a unified picker from three sources:

- **registered kernelspecs** (`jupyter kernelspec list`)
- **discovered python interpreters**:
  - active `$VIRTUAL_ENV` or `$CONDA_PREFIX`
  - `.venv/` / `venv/` / `env/` directories found by walking up from
    the notebook's directory
- **manual entry** — type any absolute path (python executable or
  kernelspec directory)

This is what makes the "just point at the venv next to my notebook"
workflow work without `jupyter kernelspec install`.

### Persistence

When opening an `.ipynb`, mercury picks the kernel in this priority:

1. `setup{kernel={...}}` — your explicit config wins
2. `metadata.mercury_kernel.{python,spec_path}` — written by
   `:NotebookKernelSelect` when you choose a python path
3. `metadata.kernelspec.name` — the standard nbformat field

The notebook's `metadata.kernelspec` block stays populated either way
(with a sensible fallback `name`) for the benefit of other tools.

## LaTeX rasterization

`text/latex` outputs are rasterized to PNG and rendered inline (cached on
disk by `(src, backend)`, so switching rasterizers invalidates stale entries
and first-render-per-equation is the only slow path).

Default is `"auto"`, which picks the first available of:

1. `pdflatex` + `pdftoppm` — best fidelity (requires a TeX install)
2. `tex2png`
3. `katex` (renders to SVG)

You can also pass a function for full control:

```lua
require("mercury").setup({
  latex = {
    rasterizer = function(src)
      -- run any pipeline; return path to PNG/SVG, or nil to skip
      return "/tmp/eq.png"
    end,
  },
})
```

If no rasterizer is available, `text/latex` falls back to displaying the
raw source.

## Multi-image cells

Plots stack cleanly via `image.nvim`'s `render_offset_top` with distinct
extmark columns per image. PNG dimensions are read directly from the
IHDR chunk to compute exact row heights — no need for image.nvim to
report sizes back. Try it:

```sh
python3 scripts/multi_image_demo.py /tmp/mercury_multi.ipynb
nvim /tmp/mercury_multi.ipynb
```

Then `Shift-Enter` on the code cell. Three plots should stack below
without overlapping.

If your terminal's cell aspect ratio differs from the default (8×16 px),
override `output.cell_width_px` / `output.cell_height_px` so the height
estimate stays accurate.

If image.nvim isn't installed, image outputs render as a `[image/png]`
placeholder line (the actual image bytes are still preserved across
save/reload).

## LSP behavior

Mercury sets the buffer's filetype to `python` so pyright/ruff/mypy attach
normally. To make markdown cells invisible to the LSP, mercury patches the
LSP client's `notify` method: every `textDocument/didOpen` and
`textDocument/didChange` for a mercury buffer is rewritten so the server
sees a comment-masked view of the document (markdown-cell lines prepended
with `# `, code-cell lines unchanged). Because line and column positions
are preserved, **all LSP positions use identity mapping** — diagnostics,
hover, completion, goto-def, references, code actions, semantic tokens,
and inlay hints work natively for code cells and correctly produce no
result on prose lines.

Design rationale and the full attach/change flow are in
[`SPEC.md`](SPEC.md) under "LSP integration".

A small safety-net `publishDiagnostics` filter remains under the mask:
if some client bypasses `client.notify` (custom transport, third-party
plugin) and emits a diagnostic on a markdown row, it's dropped. With the
mask in place this should never trigger.

Defaults:

```lua
require("mercury").setup({
  lsp = {
    mask_markdown_cells = true,   -- the primary mechanism
    filter_diagnostics  = true,   -- safety net
  },
})
```

## Autocmds

Mercury fires `User MercuryAttached` once per notebook buffer after the
kernel and renderer are wired up. The event's `data.buf` field holds the
buffer number — use it to attach per-notebook setup without monkey-patching:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "MercuryAttached",
  callback = function(args) require("my.config").setup_notebook(args.data.buf) end,
})
```

## Health check

```
:checkhealth mercury
```

Reports neovim version, the resolved python interpreter, whether
`jupyter_client` and `ipykernel` are importable in it, available
kernelspecs, image.nvim availability, LaTeX rasterizer backends, and
treesitter parsers. Useful first stop when something isn't working.

## Tests

```sh
make test                          # run the whole suite
make test-file FILE=tests/notebook_spec.lua
```

The kernel tests use a fake bridge written in Python so CI doesn't need a
real `ipykernel` installed.
