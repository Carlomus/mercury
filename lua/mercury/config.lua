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

function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.values
end

function M.get() return M.values end

return M
