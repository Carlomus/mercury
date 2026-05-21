# Mercury — Spec

A Neovim plugin that opens `.ipynb` files and provides a Jupyter notebook
editing experience comparable to VS Code's notebook UI.

This document is the canonical design contract. The code is expected to
conform to it. A new contributor (human or LLM) should be able to
reconstruct the plugin from this spec alone.

## Module map

| File | Owns |
|---|---|
| `init.lua` | Plugin entry: `setup()`, `BufReadCmd`/`BufWriteCmd` autocmds, per-buffer attach (fold/keymaps/`User MercuryAttached`), commands, mtime guard, render throttling glue. |
| `config.lua` | Defaults and `setup(opts)` merge. |
| `ipynb.lua` | Pure nbformat v4 codec. `decode(json) -> doc` (with empty-object sentinel preprocessing), `encode(doc) -> json (pretty)`, `to_buffer_lines(doc)`, `scan_lines(lines)` (with duplicate-id detection), `parse_meta(rest)`, `format_separator(cell)`. Preserves raw cells and markdown attachments verbatim. |
| `notebook.lua` | Per-buffer notebook state: cells, outputs, cell_metadata, cell_attachments. Mutations (`new_cell_*`, `delete_cell`, `merge_below`, `move_*`, `set_kind`, `goto_*_cell`). `rescan()` reconciles cells from buffer text and migrates side tables on id-rename. `to_ipynb_struct()` builds the JSON-shape struct including the `mercury_extras` stash and markdown-cell attachments. |
| `ui.lua` | `Renderer.render()` — separators, cell-background highlights, output virt_lines, image dispatch. Cell-id concealment on separator lines. Drives per-cell image GC. |
| `output.lua` | Pure output-to-virt-lines rendering, mime preference order, `image_row_height` math, PNG IHDR / JPEG SOFn / SVG attribute parsing (`image_dimensions(kind, bytes)`), `to_plain_text`. Defensive `_value_to_string` coerces non-string mime values (e.g. `application/json` objects) for display. |
| `image.lua` | image.nvim driver — per-cell handle cache keyed by `(content_hash, placement)` so unchanged content reuses handles, multi-image stacking via `render_offset_top`, natural-pixel-size clamp on render width. `Renderer:gc(present)` drops handles for vanished cell ids. Reads config dynamically. |
| `latex.lua` | text/latex rasterizer dispatch + on-disk cache keyed by `(src, backend)`. |
| `kernel.lua` | JSONL bridge client. Queue + pump, request/response handling, framing per `:h channel-lines`, kernelspec selection (name / python path / spec_path), **graceful shutdown** protocol. |
| `python/bridge.py` | Bridge process. Local kernel (registered name / synthesized from python path / spec_path) or existing connection-file transport. Worker thread + iopub thread. Defensive parsing in iopub loop. |
| `discover.lua` | Auto-discovery of candidate python interpreters: active `$VIRTUAL_ENV` / `$CONDA_PREFIX`, project-local `.venv` / `venv` / `env` directories. |
| `lsp.lua` | Patches `client.notify` so didOpen/didChange carry a masked python view of the buffer. Diagnostic safety-net filter. `LspAttach` autocmd. |
| `lsp_view.lua` | Pure `mask_lines(lines, cells)` — prepends `# ` to markdown-cell body lines, leaves code untouched. |
| `health.lua` | `:checkhealth mercury` — neovim version, python+modules, kernelspecs, image.nvim, LaTeX backends, treesitter parsers. |
| `keymaps.lua` | Default keymap table; `apply(buf)` registers both normal and insert mode for `<S-CR>`/`<C-CR>`. |
| `markdown.lua` | Markdown TS highlighting via `parser:set_included_regions`. |
| `lualine.lua` | Status-line components. |
| `util.lua` | `split_lines`, `read_file`/`write_file`, `tmpfile`, `short_id` (uv-random with math.random fallback), `hash`, `debounce`, `coalesce`, `clamp`, `notify`. |
| `ansi.lua` | `strip(s)` — removes ANSI CSI/ESC sequences and normalizes line endings. |
| `base64.lua` | `decode(s)` — pure-Lua base64 decoder for PNG payloads. |

## Invariants

These are properties the design depends on. Don't violate them without
updating this spec.

1. **Separators are the single source of truth for cell boundaries.** No
   extmark or side table tracks where cells start; cell ranges are
   re-derived from the buffer text on every change. Random edits can't
   desync structure from text.
2. **Cell ids are stable across edits and saves, and unique across cells.**
   Outputs and metadata side tables are keyed by id. Reorder/duplicate/delete
   of separator lines is the only thing that changes which id owns which
   content. Yank-and-paste of a separator triggers automatic re-id of the
   duplicate so two cells never share an id (nbformat 4.5+ requires this).
   Manual id edits in the buffer trigger a rename-detection pass that
   migrates side-table entries instead of GC'ing them — see
   "Id rename semantics" below.
3. **JSON output is pretty-printed with 1-space indent and sorted keys**
   (jupyter convention). The `.ipynb` stays diff-reviewable on GitHub.
4. **Empty `metadata` and `data` dicts serialize as `{}`, not `[]`.**
   Use `vim.empty_dict()` when the value is logically a dict. The decoder
   also runs a sentinel-substitution preprocessing pass: literal `{}` in
   the source JSON (outside strings) is replaced with a marker before
   `vim.json.decode`, then `_unmark_empty_objects` walks the decoded tree
   and substitutes `vim.empty_dict()` back. This preserves genuinely
   empty JSON objects through round-trip — most visibly
   `IPython.display.JSON({})` — that would otherwise be silently flipped
   to `[]` because Lua can't distinguish empty object from empty array.
5. **Unknown separator tokens round-trip via `metadata.mercury_extras`.**
   The buffer's separator text is canonical; on save, extras land in JSON
   metadata; on load, they're re-emitted into the separator.
6. **Markdown cells are invisible to attached LSPs** — see "LSP
   integration" below. The contract is identity position mapping: line
   counts and column counts on code-cell lines are preserved.
7. **Output rendering is coalesced to one render per event-loop tick.**
   Streaming kernel output must not produce N renders for N chunks.
8. **`Kernel:stop` is graceful** — `shutdown` message before chanclose/jobstop.
9. **Cancellation policy matches Jupyter.** Interrupt cancels *only* the
   running cell (SIGINT → `KeyboardInterrupt`); queued cells continue.
   Restart / stop / `kernel_dead` / unexpected bridge exit cancel both the
   running cell *and* the queue. See "Execution → Cancellation policy".
10. **Terminal output statuses are sticky everywhere.** Once a cell's
    `out.status` reaches `error` or `killed`, NO subsequent path may
    downgrade it. This applies to `execute_done` (the original case) AND to
    every `_cancel_*` path: an interrupt arriving after an iopub `error`
    must not flip the error pill to `killed`, and a `kernel_dead` arriving
    after an `error` must not erase the error signal either. Implemented
    via `_is_terminal(status)` guards in `_cancel_running`, `_cancel_queue`,
    and `execute_done`.
11. **A cell can be running or queued at most once.** `Kernel:execute`
    refuses to enqueue a cell that's already running or already in the
    queue. Without this, a rapid double-keystroke would push a second task
    that — when popped — sets `out.items = {}` and wipes the live output
    the first run is still streaming.
12. **`_with_mutation` never leaves `_suppress_rescan` stuck true.** The
    mutation callback is `pcall`'d; the flag is reset in all paths
    (including error). Otherwise a Lua error inside a mutation would
    silently disable all future TextChanged-driven rescans for the buffer.
13. **`_ensure_started` refuses while `_stopping` is true.** Cells executed
    during the ~500ms shutdown window would otherwise become permanently
    stuck `queued` because `_cancel_in_flight` already ran at the top of
    `stop()`. The flag is cleared at the end of `stop()` so the next
    execute respawns the bridge cleanly.
14. **Save is non-blocking.** `:w` and `:wq` return immediately even if a
    cell is running. In-flight cells (those whose id is in `kernel.running`
    or `kernel.queue`) write to JSON as "not yet executed" — empty outputs,
    null `execution_count`. The cell's in-memory state is preserved; the
    next save flushes it once the cell finishes. See "Non-blocking save".
15. **Image render width is clamped to natural pixel size.** Mercury never
    upscales an image beyond its intrinsic resolution. A 32×32 icon
    renders at 4 columns, not at 85% of the window. Matches VS Code /
    Jupyter Lab. See "Outputs → Image sizing".
16. **Image handles are reused on identical content + placement.** image.nvim
    handles are keyed by `(content_hash, place_key)` where place_key
    encodes (anchor_row, index, total, width, render_offset_top). A
    re-render with the same content at the same place is a no-op. Without
    this, every TextChanged-debounced rescan recreates every handle —
    flicker during streaming output.
17. **Image handles for vanished cell ids are GC'd.** `Renderer:gc(present)`
    runs at the end of each ui render pass and clears image handles for
    any cell id not in the current cell set. Without this, deleted /
    merged / converted cells would leak image.nvim handles forever.
18. **`set_kind` refuses to change a busy cell's kind.** If `cell_is_busy(id)`
    is true (the cell is in `kernel.running` or `kernel.queue`),
    `set_kind` notifies and returns without mutating. Matches Jupyter Lab,
    which disables the cell-type menu while a cell is busy. Without this,
    converting a running cell to markdown would either (a) leak a status
    pill / output below prose, or (b) silently swallow the kernel's
    eventual output while the side effects still landed on the kernel.
19. **iopub frames for non-code or absent cells are dropped.** Defense in
    depth alongside (18) and rescan's non-code-output cleanup: in
    `_handle_msg`, the `output` and `execute_done` branches consult
    `_live_code_cell(nb, cell_id)`. If the cell vanished from the buffer
    while still executing (delete mid-execution) or was converted to
    markdown/raw via a direct text edit (rescan path, not `set_kind`),
    output mutation is skipped. `execute_done` still clears `self.running`
    and calls `_pump` so the queue advances.
20. **Rescan drops outputs / attachments / queue entries for non-code cells.**
    After GC'ing entries for cells that vanished, rescan walks the
    surviving cells and clears `outputs[id]` whenever the cell at that id
    is no longer code, clears `cell_attachments[id]` whenever the cell is
    no longer markdown, and drops queued kernel tasks for cells that are
    no longer code. The `set_kind`-driven path already does this for
    menu-driven conversion; rescan handles the direct-text-edit path
    symmetrically (changing `# %% id=X` to `# %% id=X [markdown]` by hand).
21. **mtime guard is path-scoped.** `mercury_file_mtime` is stored
    alongside `mercury_loaded_path`. The W12-style refuse-to-clobber check
    in `save_ipynb` only fires when the save target matches
    `mercury_loaded_path`. `:saveas other.ipynb` (or `:w other.ipynb`
    targeting a pre-existing file) is writing a copy and must not be
    refused on the basis of the original file's mtime history. On
    successful `:saveas` (detected by `nvim_buf_get_name == args.match`),
    `mercury_loaded_path` is updated so future saves to the new path are
    guarded against external modification.
22. **Saves are atomic.** `save_ipynb` writes via `Util.atomic_write_file`
    which writes to `<path>.mercury_save_tmp`, fsyncs, then `rename(2)`s
    into place. POSIX rename is atomic within a single filesystem, so an
    observer (another process, or a future `:e!` after a crash) sees
    either the previous complete contents or the new complete contents —
    never a torn partial write. Critical for a notebook editor where a
    `kill -9` / power loss during `:w` would otherwise corrupt the user's
    work. The tempfile lives next to the target so the rename stays
    intra-filesystem.

## Goal

Edit `.ipynb` files in Neovim with the workflow you'd get in VS Code:

- Open `notebook.ipynb`, see cells with separators.
- Code cells with Python syntax highlighting, markdown cells with markdown.
- `Shift-Enter` runs the current cell, output appears immediately below.
- Plots and rich output render inline (kitty graphics via `image.nvim`).
- Multiple plots in one cell stack cleanly; they don't overlap.
- Outputs are collapsible, time-stamped, and copyable to the clipboard.
- Cells can be moved up/down, deleted, merged, and converted between
  code/markdown.
- Save round-trips back to `.ipynb` JSON, **preserving outputs** — exactly
  what VS Code does — so notebooks stay reviewable on GitHub.
- **Pick the kernel.** Local kernelspecs are listed via `jupyter_client`'s
  kernelspec API and surfaced through `vim.ui.select`. The chosen kernel is
  recorded in the notebook's `kernelspec` metadata.
- **Connect to an existing kernel** via a connection file
  (`--existing /path/to/kernel-XXX.json`). The same JSONL bridge protocol
  is used; only the transport changes.
- **LaTeX/MathJax** in `text/latex` outputs are rendered to images via a
  configurable rasterizer (`pdflatex+pdftoppm`, `tex2png`, or `katex` CLI)
  and displayed inline with `image.nvim`. If no rasterizer is available,
  the raw source is shown verbatim.

## Non-goals

- Editing outputs by hand.
- Notebook diffing UI (use `nbdime` externally).
- Remote Jupyter Server transport (out of scope; would require WebSocket
  proxying of `/api/kernels/<id>/channels`). Use `mode = "existing"` with
  an SSH-tunneled connection file instead.
- Per-cell-language LSP (a SQL cell with a SQL LSP, etc.). One python LSP
  attaches to the whole buffer; markdown cells are masked from it but
  cross-language LSP routing is out of scope.
- Kernel-driven completion (Jupyter `complete_request` exposed as an
  `nvim-cmp` source). Possible future work; not in this spec.
- Rich text/html rendering. HTML outputs fall back to a text-only render
  (with `text/plain` preferred when both are present).

### Known limitation: `# %%` inside markdown cells

Mercury uses VS Code's `py:percent` convention for the in-buffer
representation, which means any line matching `^#\s*%%(\s+.*)?$` is
treated as a cell separator — regardless of which cell it's inside.
That makes it impossible to round-trip markdown cells whose source
contains a line starting with `# %%` (e.g. prose explaining the
percent-cell syntax itself). On load such a line is interpreted as a
new separator and the markdown cell is split in two.

This is a deliberate cost of staying compatible with the `# %%`
notebook convention that VS Code, Jupytext, Spyder, and PyCharm all
use. Workaround: avoid lines starting with `# %%` in markdown cells —
e.g., write the syntax inside a fenced code block (whose body lines
are indented), or as `<!-- # %% -->` HTML comment.

## File format

On disk: standard `nbformat v4` `.ipynb` JSON.

In buffer: a `py:percent`-like text representation where every cell starts
with a real, visible separator line:

```
# %% id=ab12cd34
print("hello")

# %% id=ef56gh78 [markdown]
# Section title
some markdown

# %% id=99887766 [raw]
this is verbatim text, not python, not markdown
```

Separator rules:

- A separator is a line matching `^#\s*%%(\s+.*)?$`.
- The optional metadata is parsed as `key=value` tokens plus a `[markdown]`
  or `[raw]` flag. Whitespace is the token delimiter; values cannot contain
  spaces.
- Known tokens: `id=<hex>`, `[markdown]`, `[raw]`, `tags=foo,bar`.
- **`[md]` is accepted as a shorthand for `[markdown]`** on parse and
  canonicalized to `[markdown]` on the next write. This is the one
  deliberate exception to "the buffer text is canonical": the shorthand is
  a typing convenience that round-trips deterministically (read accepts
  both, write emits one). Tests pin both halves of the canonicalization
  (`ipynb_spec.lua`: "parse_meta accepts the [md] short flag" and
  "format_separator canonicalizes [md] to [markdown]").
- **Unknown tokens (e.g. `foo=bar`) are preserved across save/load** via
  the `metadata.mercury_extras` stash (see "Separator extras round-trip"
  below). On save they're stashed into the cell's JSON metadata; on load
  they're re-emitted into the separator text.
- Every cell has a stable `id` (8 hex chars). On load, cells without an `id`
  get one assigned by **regex-splicing `id=…` into the existing header
  line** — preserving any other tokens already there. IDs survive edits,
  reorders, and saves.
- The first cell may be implicit: if the file does not begin with a separator,
  Mercury injects `# %% id=...` at line 0 on load.

### Separator extras round-trip

The buffer text of a separator is canonical: whatever appears between
`# %%` and end-of-line is what mercury preserves. Concretely:

1. `Ipynb.parse_meta(rest)` parses tokens into `{ id, kind, extras = { … } }`,
   where `extras` is a string-keyed dict of everything except `id`.
2. On save (`Notebook:to_ipynb_struct`), `extras.tags` becomes a list at
   `metadata.tags`, and every other key (`extras[k] for k ~= "tags"`)
   becomes `metadata.mercury_extras[k]`.
3. On load (`Ipynb.to_buffer_lines`), the renderer emits
   `id=<id> [markdown]? tags=…? <extras alphabetically>` from
   `metadata.mercury_extras`.

Constraints:
- Extras values cannot contain whitespace or a `]` (matches `parse_meta`'s
  `[^%s%]]+` capture — `]` is excluded because `[markdown]` / `[raw]` flag
  tokens own the bracket grammar). Mercury-generated extras can't carry
  either by construction; an externally-edited JSON whose `mercury_extras`
  carries one triggers a warning on load (`to_buffer_lines`) naming the
  offending class(es) and the truncated form that will become canonical
  on the next save.
- Extras keys are `[%w_%-%.]+` — alphanumerics plus `_`, `-`, `.` (Lua's
  `%w` doesn't include underscore, and JSON metadata routinely uses
  snake_case identifiers; a narrower regex would silently drop them on
  rescan).

`Notebook:set_kind` (code↔markdown↔raw conversion) must preserve tags and
extras when rewriting the separator — the round-trip invariant applies to
kind changes too. Conversion to markdown additionally drops
`self.outputs[id]` because markdown cells don't carry outputs, and a
stale "Out[N]" pill on prose would be incoherent. Conversion *away* from
markdown additionally drops `self.cell_attachments[id]` because nbformat
only allows attachments on markdown cells.

### Cell types

nbformat v4 defines three cell types and mercury preserves all three:

| `cell_type` | mercury `kind` | Behaviour |
|---|---|---|
| `code` | `code` | Default. Executes; has `execution_count` and `outputs`. |
| `markdown` | `markdown` | Renders as markdown via treesitter included regions. Has no outputs. May carry `attachments`. Masked as `# ` comments for the LSP. |
| `raw` | `raw` | Verbatim text. Doesn't execute. No outputs. Not masked from the LSP (treated as code, so it's visible to pyright as ordinary python text — accept that LSP may flag it). Round-trips losslessly. |

Round-trip discipline: an unknown `cell_type` on disk is preserved as
`code` (the only safe fallback), but `raw` is recognized and preserved
verbatim across save/load.

### Cell attachments

nbformat lets markdown cells carry `attachments: { filename: { mime: b64 } }`
(used for paste-image-into-markdown in Jupyter Lab / VS Code). Mercury:

- Preserves the field verbatim across save/load — the b64 bytes are
  stashed in `Notebook.cell_attachments[id]`, keyed by stable cell id.
- Does NOT render attachments inline (they're referenced by the markdown
  source as `attachment:filename`; rendering them in the buffer would
  require image.nvim positioning math we don't do today).
- Drops them on conversion away from markdown (see "Cell types").

### Id rename semantics

If the user manually edits the `id=` token on a separator line, the next
rescan would naively GC the old id from `outputs` / `cell_metadata` /
`cell_attachments` and start fresh on the new id — silently erasing the
cell's outputs, tags, mercury_extras, attachments, etc.

Rescan instead performs a positional rename-detection pass before GC:

- If `prev_cells` and `cells` have the same length, walk in lockstep.
- For each position `i` where the id changed AND the previous id is not
  present anywhere in the new cell set, migrate the per-id side-table
  entries (`outputs`, `cell_metadata`, `cell_attachments`) from old to
  new id.
- After migration, GC any side-table entries whose ids are not in the
  new (post-migration) set.

The "previous id absent from new set" guard prevents a rename from
cannibalizing a sibling cell with the same id (e.g., if the user
duplicated a separator and is still in the middle of fixing one of them).

Why real separator lines (and not virtual ones): they are the single source of
truth for cell boundaries. Random edits can't desync them from extmark spans,
because there are no extmark spans tracking boundaries — we re-derive cell
ranges from the text on every change.

## Cell registry

Per buffer:

```
notebook = {
  buf,
  cells = [ { id, kind = "code"|"markdown"|"raw", header_row, body_start, body_end, meta } ... ],
  outputs          = { [id] = { exec_count, ms, status, items[], _pending_clear? } },
  cell_metadata    = { [id] = { ...nbformat cell metadata... } },
  cell_attachments = { [id] = { filename = { mime = b64 } } },  -- markdown only
  meta,             -- nbformat top-level metadata (kernelspec, language_info, …)
  nbformat,
  nbformat_minor,
  kernel,
}
```

`cells` is rebuilt on every `TextChanged`/`TextChangedI` (debounced ~30ms) by
scanning the buffer for separator lines. The three id-keyed side tables
(`outputs`, `cell_metadata`, `cell_attachments`) persist across rescans.
Cells whose ids vanish from the buffer have their side-table entries
evicted, unless `rescan()`'s rename-detection pass migrates them first
(see "Id rename semantics").

## Outputs

Output state for one cell:

```
{
  exec_count, ms, started_at,
  status = "idle" | "running" | "queued" | "ok" | "error" | "killed",
  items[] = list of normalized iopub items:
    { type = "stream", name, text }
    { type = "display_data" | "execute_result", data = {mime -> str}, metadata, display_id? }
    { type = "error", ename, evalue, traceback }
}
```

Rendering:

- Output is attached to the cell via a single `virt_lines` extmark anchored
  to the last real row of the cell body. The first virt line is a status pill:
  `▶ Out[7]  142 ms  ✓` / `⏳ running…` / `✗ error` / `⏸ queued`.
- Text mime types render as virt lines with `Comment` highlight.
- Images render via `image.nvim`. Each image gets its own dedicated
  extmark a few rows below the previous one, with `with_virtual_padding =
  true` so the image reserves real screen rows. Stacking offset is computed
  from the image's pixel height divided by cell height (rounded up). The
  cell pixel size is configurable via `output.cell_width_px` /
  `output.cell_height_px`.
- **Render width = min(available_cols, natural_cols).** Available cols is
  85% of the window width (floor 20). Natural cols is the image's pixel
  width divided by `output.cell_width_px`. The min(…) means a 32x32 icon
  renders at 4 columns instead of being upscaled to 85% of the window, and
  a 4000-pixel-wide photo gets downscaled to 85% of the window. Matches
  VS Code / Jupyter Lab's "show at intrinsic resolution if smaller, scale
  down if larger" contract. SVG follows the same rule: `svg_dimensions`
  reads the document's `width`/`height` attributes (px or pt) or falls
  back to the `viewBox`. SVGs that declare no resolvable intrinsic size
  fall through to the "unknown dimensions" path (full available width +
  max-rows reservation), same as a PNG with an unreadable IHDR.
- **Render height = clamp(natural_height_at_that_width, 1,
  output.image_max_height_rows)**. The minimum of 1 row means a tiny icon
  doesn't get padded with empty space. The maximum (40 by default) caps
  pathologically tall images so they can't push the rest of the buffer
  off-screen; raise this for taller plots.
- Image handles are cached per cell, keyed by content hash. A re-render
  with the same content AND same placement (anchor row, column index,
  width, render_offset_top) reuses the existing image.nvim handle and
  skips the `from_file` + `render` calls entirely. Without this every
  TextChanged-debounced rescan would recreate every handle, causing
  flicker during streaming output.
- Image handles for cells that disappear from the notebook (delete,
  merge, convert to markdown/raw) are GC'd via `Renderer:gc(present)` at
  the end of each ui render pass. Without this, image.nvim handles for
  dead cells would survive forever — both as memory and (on platforms
  where image.nvim keeps the extmark alive) as ghost images.
- LaTeX outputs (`text/latex`) are rasterized to PNG via the configured
  rasterizer and rendered as images. The on-disk cache key includes the
  backend name so switching backends invalidates stale results.

Both the image cache (`stdpath('cache')/mercury_images`) and latex cache
(`stdpath('cache')/mercury_latex`) are content-addressed by hash, so
eviction is always safe (the file will be re-emitted from source bytes on
next use). `setup()` schedules an age-based sweep at startup that drops
files older than 30 days. Cache hits `Util.touch()` the file so
frequently-used entries don't age out.

Status pill rules:

- `idle` with no `exec_count` and no positive `ms`: no pill is rendered
  (a fresh, never-run cell shouldn't show `▶ Out  0 ms`).
- `idle` with `exec_count` from a loaded `.ipynb`: pill shows `▶ Out[N]`
  (no ms — ms=0 means "unknown", not "instant").
- `ok` / `error`: pill shows `▶ Out[N]  <ms> ms  <glyph>`.

Mime preference order in `output.pick_mime`:

1. `image/png`
2. `image/jpeg`
3. `image/svg+xml`
4. `text/latex` (rasterized; renders as image)
5. `text/markdown`
6. `text/plain`
7. `text/html` (lowest priority — pandas etc. always emit text/plain
   alongside; html_to_text is naive and loses table structure)

This deliberately differs from Jupyter Lab / nbviewer, which prefer
`text/html` above `text/plain` (so pandas DataFrames render as HTML
tables). In a terminal those tables degrade to soup; the plain repr is
the readable one. Documented divergence.

LSP integration: `[raw]` cells are NOT masked from the LSP. They appear
to pyright as ordinary python text (since the buffer is filetype=python).
This is intentional — masking raw cells would require deciding whether
their contents should be treated as code or comments, and either choice
is wrong for some user. Treat raw cells as "verbatim text you don't want
mercury to interpret"; if your raw cell is bare prose, pyright will
flag it. Set `lsp.mask_markdown_cells = false` to disable masking
entirely if this matters.

Unknown mimes use the alphabetically-first key in `data` so the fallback
is deterministic.

Streaming render throttling: the kernel emits one `output` message per
iopub chunk. The bridge → Lua → renderer path **must coalesce** so a
tqdm loop dumping thousands of lines does not trigger thousands of
renders. Implementation: `Util.coalesce(fn)` collapses any number of
calls within one event-loop tick into one scheduled call. The kernel's
`on_change` callback is wrapped in `coalesce` at the call site in
`init.lua`.

Image renderer visibility: `image.nvim`'s render path requires a window
currently showing the buffer. Mercury re-runs `renderer:render()` on
`BufWinEnter` so images reappear when the buffer is revealed in a new
window. The image cache is keyed by content hash so re-render does not
recreate unchanged handles.

Collapsing: a per-cell `collapsed` flag toggles between the full virt_lines
set and a single `…  output collapsed` line. Image extmarks are cleared while
collapsed.

Copyable output: outputs are virtual lines, not selectable. Mercury exposes:

- `:NotebookOutputCopy` — copies the current cell's output text to `+`.
- `:NotebookOutputView` — opens a scratch buffer with the full output text,
  selectable and yankable like normal text.

## Execution

The notebook talks to a Python `bridge.py` over a JSONL stdio protocol. The
bridge supports two transports:

1. **Local kernel.** Default. Three mutually-exclusive selectors pick the
   kernel; the bridge dispatches based on which is set:

   | Selector | Effect |
   |---|---|
   | `python = "/abs/path/python"` | Bridge writes a synthesized `kernel.json` (with `argv = [python, -m, ipykernel_launcher, -f, {connection_file}]`) to a tmpdir and starts it via `KernelSpecManager(kernel_dirs=[tmpdir]+…)`. The "just point at a venv" mode — no `jupyter kernelspec install` required. **tmpdir lifecycle**: attached to the `KernelManager` as `_mercury_tmpdir` (it must outlive `start_kernel()` because `restart_kernel()` may re-read `kernel.json`) and reaped by `Bridge.close()`. |
   | `spec_path = "/abs/path/dir"` | Use an existing on-disk kernelspec directory (the one containing `kernel.json`). Parent dir is prepended to `KernelSpecManager.kernel_dirs`. |
   | `name = "python3"` | Look up a registered kernelspec via `KernelSpecManager.get_kernel_spec`. Default fallback when no selector is set. |

   Priority on resolve: `python > spec_path > name`. If none are set,
   defaults to `name = "python3"`. If the requested selector can't be
   resolved, the bridge emits `kernel_error` with kind `no_kernelspec`
   and the available kernelspecs; the Lua side prompts via
   `vim.ui.select`.

2. **Existing connection file.** `mercury.setup{ kernel = { mode =
   "existing", connection_file = "/path/to/kernel-XXX.json" } }` — bridge
   connects to a kernel that's already running, locally or via SSH-tunneled
   ports. **Interrupt is unsupported in this mode** (signal-based, requires
   owning the kernel process) — the bridge emits `kernel_error` with
   `kind="unsupported"`. **Restart is supported** when the kernel has an
   upstream supervisor (jupyter server etc.) that will relaunch it; see
   "Restart" below.

Wire framing: the bridge writes one JSON message per line, but Neovim's
`channel-lines` callback may slice a single message across multiple
callbacks (large outputs cross OS pipe-buffer boundaries). The Lua client
honors that protocol: each callback's first list element extends the
previous tail, and the last element is a pending partial until the next
callback completes it. This is what keeps inline-image outputs from being
silently dropped.

Requests: `init`, `execute`, `interrupt`, `restart`, `shutdown`, `list_kernels`.

Responses: `execute_start`, `output`, `execute_done`, `interrupted`,
`restarted`, `kernel_dead`, `kernel_error`, `kernels_listed`.

`kernel_error` carries an optional `kind` discriminator:

| Kind | Meaning | Lua-side effect |
|---|---|---|
| `no_kernelspec` | Requested kernelspec/python/spec_path couldn't be resolved. `available` lists installed specs. | Prompts via `vim.ui.select` to pick a different kernel. |
| `missing_module` | `jupyter_client` or `ipykernel` not importable in the resolved python. | Surfaced as ERROR; user must install the missing module. |
| `unsupported` | A request can't be served by this transport (e.g. interrupt in `mode="existing"`). **Soft** — nothing has died, queue/running are untouched. | Surfaced as WARN; no state change. |
| (absent) | Generic / fatal kernel-side failure. | Treated like `kernel_dead`: cancels running + queue. |

Cells executed are queued FIFO. Each cell becomes `running` when the
bridge acknowledges; later cells in the queue display as `queued`.

### Streaming clear (`clear_output`)

Jupyter's `clear_output(wait=True)` semantics: "defer the clear until the
next output arrives" — used by tqdm to clear its progress bar before
emitting the next frame. Mercury implements this as a `_pending_clear`
flag on the output state.

End-of-cell handling: if `_pending_clear` is set when `execute_done`
arrives (i.e. the cell finished without emitting further output after
the deferred-clear request), mercury honors the clear. The cell ends with
an empty items list, matching what the user explicitly asked for. This
diverges from classic notebook (which leaves the prior output visible if
nothing follows) and matches modern Jupyter Lab / VS Code behaviour.

### Cancellation policy

The lua side splits "cancel the running cell" from "cancel the whole
queue" so interrupt matches Jupyter's semantics:

| Trigger | Running cell | Queued cells |
|---|---|---|
| `interrupted` (SIGINT → `KeyboardInterrupt`) | `killed` (→ `error` once iopub error arrives) | preserved; `_pump` resumes them on `execute_done` |
| `restarted` | `killed` | dropped |
| `kernel_dead` / fatal `kernel_error` | `killed` | dropped |
| `Kernel:stop` (`:NotebookKernelStop`, `:NotebookKernelSelect`) | `killed` | dropped |
| Bridge exits unexpectedly (`on_exit` without `_expected_exit`) | `killed` | dropped |

Implementation: `_cancel_running(status)`, `_cancel_queue(status)`,
`_cancel_in_flight(status)` (which composes both). Interrupt is the only
path that calls `_cancel_running` alone. Each path also updates each
affected cell's `out.status` so no stale `Running…` / `Queued` pill is
left behind.

### Graceful shutdown

`Kernel:stop` must send `{"type":"shutdown"}` before tearing down the
channel. The bridge's main loop handles `shutdown` by breaking out of
`for line in sys.stdin:` and running its `finally: bridge.close()` block,
which calls `km.shutdown_kernel(now=True)` so the kernel subprocess is
reaped cleanly. A bare SIGTERM via `jobstop` can bypass Python's `finally`
on some platforms and leak the kernel.

Sequence:

1. Mark `_stopping = true` (refuses new executes during the shutdown
   window — SPEC Invariant 13) and `_expected_exit = true` (consumed by
   `on_exit` on a later event-loop tick so a legitimate stop isn't
   misreported as a crash).
2. Cancel running + queued cells (`_cancel_in_flight("killed")`) before
   sending shutdown so no "Running…" / "Queued" pill survives the kernel.
3. `_send({type = "shutdown"})` — pcall'd so a dead channel doesn't raise.
4. `vim.fn.jobwait({ job }, 500)` — bounded wait. If the bridge is hung,
   we still fall through to chanclose+jobstop within ~500 ms so nvim exit
   isn't delayed indefinitely.
5. `chanclose` + `jobstop` — final teardown.
6. Cancel any pending `_stderr_timer` and reset internal state (`job_id`,
   `chan`, `json_buf`) regardless of whether the above succeeded.
7. Clear `_stopping = false` synchronously so the next execute can
   respawn the bridge cleanly. `_expected_exit` stays set until `on_exit`
   consumes it.

Why split `_stopping` and `_expected_exit`: `_stopping` is cleared at the
end of `Kernel:stop` (Invariant 13 requires the next execute to be able
to respawn the bridge). `on_exit` fires on a later event-loop tick. If
`on_exit` read `_stopping` to decide whether the exit was intentional,
the flag would already be false by then and a legitimate stop would
trigger the spurious "kernel bridge exited unexpectedly" warning.
`_expected_exit` is a separate flag that survives until `on_exit`
consumes it. The `else` branch in `Kernel:stop` (no job was running)
clears `_expected_exit` synchronously so a later real start + crash
isn't masked as expected by a stale flag.

`on_exit` mirrors this: if it fires without `_expected_exit` set, the
bridge crashed — it calls `_cancel_in_flight("killed")`, notifies the
user, and resets state so the next execute can respawn the bridge
cleanly (without this, a leftover `self.running` would jam `_pump`
forever).

### Restart

Restart is **a real kernel restart**, not a reconnect. Python state in
the kernel is fully cleared — variables, imports, everything — as Jupyter
users expect.

- **Local mode (`self.km is not None`).** `km.restart_kernel(now=True)`
  SIGKILLs the kernel subprocess and starts a fresh one on the same
  ports. The Lua side receives `restarted` and cancels both running and
  queued cells (the new kernel doesn't know about them).
- **Existing mode (`self.km is None`).** Bridge sends
  `kc.shutdown(restart=True)` over the control channel. Whatever
  supervisor launched the kernel (typically jupyter server's
  `KernelManager`) is responsible for relaunching it; the bridge then
  `wait_for_ready`s on the heartbeat. If nothing relaunches the kernel,
  the wait times out and the bridge emits `kernel_error` so the user
  doesn't end up with a dead connection silently.

**Restart epoch (`_restart_seq`).** Without this, an in-flight `_execute`
on the *old* kernel keeps waiting for shell replies with the old
`parent_id` — replies that the new kernel will never send. The bridge:

1. Increments `_restart_seq` at the start of `restart()`.
2. Drains `task_q` (lua cleared its queue on `restarted` too; any task
   still in the worker's queue is an orphan that would surprise the
   user if it ran on the new kernel).
3. `_execute` captures `_restart_seq` at entry and rechecks it inside
   both wait loops (`get_shell_msg` and idle-wait); on mismatch it
   abandons the parent_id and returns. Without these checks the worker
   thread would deadlock and jam every subsequent execute.

### iopub robustness

`bridge.py:_iopub_loop` wraps the per-message handler in `try/except` so
a malformed message can't kill the iopub thread. If a parse fails, the
bridge emits a `kernel_error` so the UI sees it instead of going silently
mute.

**parent_to_cell registration is atomic with the execute send.** In
`_execute`, both `kc.execute(...)` (which composes and sends the
`execute_request`) and the `self.parent_to_cell[parent_id] = cell_id`
write happen inside a single `with self._lock:` block. `_iopub_loop`
acquires the same lock to look up `cell_id` for an incoming frame, so a
kernel that produces an iopub message within microseconds of receiving
the request can never observe `parent_to_cell` mid-update — the lookup
blocks until both the send and the registration have completed. Without
this, the first stream/display/error frame of a fast cell could be
silently dropped.

## Kernel selection UI

`:NotebookKernelSelect` composes a unified picker from three sources:

1. **Registered kernelspecs** — fetched from the bridge via `list_kernels`
   (which calls `KernelSpecManager().get_all_specs()`).
2. **Auto-discovered python interpreters** — `mercury.discover.pythons({
   start_dir = <notebook directory> })` returns:
   - the active `$VIRTUAL_ENV` python, if any,
   - the active `$CONDA_PREFIX` python, if any (and `VIRTUAL_ENV` isn't set),
   - any `.venv/` / `venv/` / `env/` directories found by walking up from
     the notebook's directory (up to 8 levels).
   Results are deduped by resolved absolute path so a project venv that's
   also currently active appears only once.
3. **Manual entry** — a final "Enter python or kernelspec path…" option
   opens `vim.ui.input` with `completion = "file"`. If the entered path is
   a directory, it's treated as `spec_path`; otherwise as `python`.

On selection, `Kernel:select_kernel(choice)` is called with one of:
`{ name = ... }`, `{ python = ... }`, or `{ spec_path = ... }`. The
implementation replaces (not merges) `kernel_opts` so a previously-set
selector field doesn't shadow the new one. It also updates the
notebook's metadata:

- `metadata.kernelspec.{name,display_name,language}` — best-effort fallback
  for other tools that read the standard nbformat field. Filled in even
  when the user picks a python path (with `name = "python3"` as the
  default).
- `metadata.mercury_kernel.{python,spec_path}` — mercury's override.
  Set only when the user picked a python path or spec_path; cleared when
  switching back to a registered kernelspec name.

On open, `attach_buffer` reads metadata in priority order:
1. `setup{kernel={...}}` — explicit user config always wins
2. `metadata.mercury_kernel.{python,spec_path}` — mercury's override
3. `metadata.kernelspec.name` — standard nbformat field

Selectors are mutually exclusive: setting one clears the others. This
keeps the bridge's dispatch unambiguous.

`b:mercury_kernel_name` is set on both initial load and selection (to
whichever of name/python/spec_path is active) so lualine / users keying
off the buffer var see the current selection.

Kernel selection only changes the kernel *resolver*; the transport mode
(`local` / `existing`) is preserved. Switching transports requires an
explicit `setup{kernel={mode=...}}`.

## Highlights

- Code cell body: `MercuryCodeBlock` (subtle bg).
- Markdown cell body: `MercuryMarkdownBlock` (different subtle bg).
- Separator line: `MercurySeparator` (italic comment-ish).
- Status pill colors per state.

Treesitter: markdown highlighting in markdown cells is driven by
`parser:set_included_regions` — Mercury hands the markdown parser the
exact line ranges of `[markdown]` cells on every rescan. No injection
query file or predicate setup is needed.

## Commands & default keymaps

| Command | Default | Effect |
|---|---|---|
| `:NotebookExec` | `<S-CR>` | Run current cell + advance |
| `:NotebookExecAlone` | `<C-CR>` | Run current cell without advancing |
| `:NotebookExecAll` | — | Run all code cells top to bottom |
| `:NotebookExecAbove` | — | Run all code cells above (inclusive) |
| `:NotebookCellNewBelow` | `]n` | Insert empty code cell below |
| `:NotebookCellNewAbove` | `[n` | Insert empty code cell above |
| `:NotebookCellNext` | `]c` | Jump cursor to next cell |
| `:NotebookCellPrev` | `[c` | Jump cursor to previous cell (or this cell's body) |
| `:NotebookCellDelete` | `<leader>cd` | Delete current cell |
| `:NotebookCellMergeBelow` | `<leader>cM` | Merge with cell below |
| `:NotebookCellMoveUp` | `[m` | Swap with previous cell |
| `:NotebookCellMoveDown` | `]m` | Swap with next cell |
| `:NotebookCellToCode` | `<leader>cc` | Convert to code cell |
| `:NotebookCellToMarkdown` | `<leader>cm` | Convert to markdown cell |
| `:NotebookCellSelect` | `<leader>cs` | Visual-select current cell |
| `:NotebookOutputClear` | `<leader>oc` | Clear current cell's output |
| `:NotebookOutputClearAll` | `<leader>oC` | Clear all outputs |
| `:NotebookOutputToggle` | `<leader>oo` | Collapse/expand output |
| `:NotebookOutputCopy` | `<leader>oy` | Copy output text to `+` |
| `:NotebookOutputView` | `<leader>ov` | Open output in scratch buffer |
| `:NotebookKernelSelect` | `<leader>kk` | Pick a kernelspec |
| `:NotebookKernelRestart` | `<leader>kr` | Restart kernel |
| `:NotebookKernelRestartClear` | `<leader>kR` | Restart + clear all outputs |
| `:NotebookKernelInterrupt` | `<leader>ki` | Interrupt current execution |
| `:NotebookKernelStop` | `<leader>ks` | Stop kernel |

All keymaps are buffer-local to `*.ipynb` buffers and use `<cmd>` dispatch.

**Insert-mode bindings.** `<S-CR>` and `<C-CR>` are registered in *both*
normal and insert mode so the "execute and keep typing" workflow doesn't
require an `<Esc>`. All other keymaps (`]n`, `]c`, `<leader>…`) are
normal-mode only.

## LSP integration

### Goal

Markdown cells must be invisible to any LSP attached to the buffer. Pyright,
ruff, mypy, and similar servers see the buffer as a single python file (since
Mercury sets `filetype = "python"`); bare prose in a markdown cell would
otherwise be diagnosed as a syntax error, and hover / completion / goto-def
on prose rows would return Python-domain results. The user-visible contract
is: editing inside a code cell is indistinguishable from editing a plain
`.py` file with the same LSP setup, and markdown cells produce no LSP
interaction at all.

### Strategy: line-preserving comment mask

Every line inside a `[markdown]` cell is prepended with `# ` in the
LSP-facing view of the document. Code cell lines (and the `# %% …`
separator lines, which are already valid python comments) pass through
unchanged. The masked text has:

- the **same number of lines** as the real buffer,
- the **same column positions** on every code-cell line, and
- valid python comment syntax on every markdown-cell line.

Because line and column positions are preserved, every LSP message in
both directions uses identity position mapping. Diagnostics, hover,
completion, goto-def, references, code actions, semantic tokens, inlay
hints, and document symbols all work natively on code-cell positions and
correctly return "nothing here" for markdown-cell positions.

The alternative — line-stripping the markdown cells and remapping line
numbers in both directions — was rejected because every new LSP message
type that carries a position becomes a new place to forget the mapping;
new features in `vim.lsp` would silently produce off-by-N bugs in mercury
buffers. Identity is the only mapping that doesn't decay.

### Interception layer

The masking is applied by patching `client.notify` on each LSP client
attached to a mercury buffer, intercepting `textDocument/didOpen` and
`textDocument/didChange`:

- **didOpen**: rewrite `params.textDocument.text` to the masked text.
- **didChange**: replace `params.contentChanges` with a single
  `{ text = masked_text }` entry (full document). This sidesteps the
  complexity of masking a sub-range when an incremental change happens to
  land inside a markdown cell; full sync is correct regardless of the
  client's advertised sync kind, and the overhead is negligible for the
  document sizes that fit a notebook workflow.

`reset_server_view` computes the document text directly (via `View.masked_text(buf)`
when masking is enabled, or the raw buffer lines otherwise) rather than
passing `text = ""` and relying on the patched notify to fill it in.
Otherwise, with `mask_markdown_cells = false`, the server would receive
an empty document and every diagnostic would be misaligned.

The patch is per-client and idempotent — applying it twice doesn't
re-wrap, so multiple mercury buffers sharing one server are safe.

**Flag is checked at call time, not patch time.** The wrapper reads
`Cfg.get().lsp.mask_markdown_cells` on every `notify`, so toggling the
flag at runtime takes effect on the next message — no LSP restart
required.

**Reload-safe wrapping.** The `publishDiagnostics` filter records its
installed state on `vim.g._mercury_lsp_publish_wrapped`. File-locals
reset on `:Lazy reload mercury`; the `vim.g` marker survives, so the
wrap happens at most once per nvim session regardless of how many times
the module is re-required.

### Attach flow

Neovim's auto-attach (driven by `FileType python`) sends `didOpen` with
raw buffer text *before* `LspAttach` fires. By the time mercury sees the
attach, the server already has the unmasked view. Mercury's `LspAttach`
handler:

1. Patches `client.notify` (idempotent),
2. Sends `textDocument/didClose` for the buffer,
3. Sends `textDocument/didOpen` with the masked text (which goes through
   the patched notify and lands at the server correctly).

The brief window between (1) and (3) when the server has raw text is
harmless — no diagnostics can be produced and surfaced in that window.

### Change flow

Subsequent edits trigger nvim's normal `textDocument/didChange`
generation. The patched `notify` rewrites the payload to the masked full
text before forwarding. No buffer-side state needs to track.

### Configuration

```lua
require("mercury").setup({
  lsp = {
    mask_markdown_cells = true,   -- default; the integration described above
    filter_diagnostics  = true,   -- safety net: drop diagnostics that
                                  --   still land on markdown rows
  },
})
```

The diagnostic filter remains as defense-in-depth: if some client bypasses
`client.notify` (custom transport, third-party plugin) and emits
diagnostics on a markdown range, the filter still drops them.

The filter applies **only** to markdown cells. Raw cells are kept verbatim
so any diagnostic the server emits on them (e.g. pyright flagging bare
prose) reaches the user — that's the documented contract for raw cells
(see "Outputs → LSP integration"). Code-cell and out-of-cell diagnostics
pass through unchanged.

### Non-goals

- **Per-cell language LSP** (e.g., a SQL cell with a SQL LSP). Mercury
  assumes a single python LSP for the whole buffer.
- **Per-cell scoped completion** (kernel-aware autocomplete that knows
  cells N+1 hasn't executed yet so its imports aren't in scope). That is
  a kernel-client integration, not an LSP one — handled separately if at
  all.

## Persistence

On `:write`:

1. **mtime guard.** If the file on disk has changed since load
   (`vim.loop.fs_stat(path).mtime.sec > vim.b[buf].mercury_file_mtime`),
   refuse the save and instruct the user to use `:w!`. Mirrors vim's
   default `W12` protection, which mercury's `BufWriteCmd` would otherwise
   bypass. `vim.v.cmdbang == 1` skips the check (that's what `:w!` sets).
2. Walk `cells` in current order, read each body's lines, attach outputs
   from `outputs[id]` (formatted as nbformat v4 output objects). **In-flight
   cells (running or queued) are written as "not yet executed"** — empty
   outputs, null exec_count. See "Non-blocking save" below.
3. Serialize an `nbformat v4` JSON document **pretty-printed** (1-space
   indent, sorted keys, trailing newline) and write it.
4. Update `vim.b[buf].mercury_file_mtime` to the new on-disk mtime so
   the next save's guard doesn't false-positive on our own write. If
   `fs_stat` fails (rare; transient filesystem issue), fall back to
   `os.time()` so the guard doesn't wedge subsequent saves into requiring
   `:w!`.
5. The file's existing top-level metadata (kernelspec, language_info) is
   preserved across the round trip; the kernelspec is updated if the
   user changed it.
6. If any cells were skipped as in-flight, notify the user with the count
   and a hint to save again after the cell finishes.

### Trailing blank lines on non-last cells

`to_buffer_lines` inserts one blank line between every pair of cells so the
buffer reads as separated paragraphs. `to_ipynb_struct` removes one trailing
blank line from each non-last cell's body on save so the JSON doesn't
duplicate that visual gap.

Consequence — slightly asymmetric round-trip on non-last cells:

- A cell whose body ends with one blank line in the buffer saves as a body
  with no trailing blank in the JSON; the next reload adds the visual gap
  back, so subsequent saves are byte-stable.
- A cell whose body ends with N≥2 blank lines saves as a body with N−1
  trailing blanks; the next reload adds the visual gap, so the buffer goes
  from N to N. Stable thereafter.

So: any non-last cell loses *one* trailing blank on its first save. The
last cell is unaffected because there's no visual gap after it. This is a
deliberate tradeoff — the alternative is no normalization, which produces
diff churn whenever a cell is moved (the trailing-blank count changes
based on whether it's now the last cell).

### Non-blocking save

`:w` and `:wq` return immediately even when a cell is still executing.
The previous design drained the kernel queue first (blocking the editor
for up to 30s, `<C-c>` to abort); the current design accepts the
tradeoff that an in-flight cell's eventual output is NOT in the saved
file unless the user saves again.

Rules:

- A cell is "in flight" iff its id appears in `kernel.running` or
  `kernel.queue`. `to_ipynb_struct` reads those tables (via
  `self.kernel.*`) and emits empty `outputs` + null `execution_count`
  for those cells. Their in-memory state is untouched — the buffer
  still shows live streaming output.
- After the cell finishes, the next `:w` flushes its output. Because
  vim tracks `modified` on buffer *text* and an output change doesn't
  modify text, the user may need to make any trivial edit to re-trigger
  a save (or use `:w!`). This is a known UX rough edge; a deferred-write
  design would smooth it over but breaks vim's synchronous BufWriteCmd
  contract.
- On `:wq` with running cells, the save proceeds, vim quits, the
  running cell's eventual output is lost. This is the explicit deal.
- We notify on save with the count of skipped cells so the user isn't
  surprised.

On read:

1. Parse the JSON; on parse failure, show raw bytes readonly and notify
   (never clobber a malformed `.ipynb`).
2. Record `vim.b[buf].mercury_file_mtime` from `fs_stat`.
3. Render each cell as `# %% id=<id>[ markdown][ tags=…][ <extras>]\n<source>`
   joined by blank lines.

Mercury does **not** depend on `jupytext`. The reader/writer is a small,
testable Lua module (`ipynb.lua`).

### Empty dict vs. empty list

`vim.json.encode({})` emits `[]`. To get `{}` (required for nbformat
`metadata` fields), callers must pass `vim.empty_dict()`. The
pretty-printer in `Ipynb.encode` honors this: it uses
`vim.json.encode(t)` to detect dict-vs-list for empty tables. The encode
helper `ensure_dict(t)` wraps the relevant fields (`metadata`, `data`,
top-level meta) so empty defaults serialize correctly.

## Autocmds

All per-buffer autocmds (every entry below tagged "per buffer") are
registered under a per-buffer augroup named `MercuryBuf_<bufnr>`, created
with `clear = true` at the top of `attach_buffer`. A reattach (e.g. `:e!`
refires `BufReadCmd`, which detaches + reattaches without wiping the
buffer) clears the previous attach's autocmds before the fresh set lands.
Without this, every reload stacked a duplicate `TextChanged` /
`BufWinEnter` / `BufWipeout` handler closing over a now-stale
`Notebook`/`Renderer`; the per-keystroke work grew linearly with reload
count. The global autocmds (`BufReadCmd` / `BufWriteCmd` / `ColorScheme`)
live under the `Mercury` augroup created once in `setup()`.

Mercury creates these autocmds:

- **`BufReadCmd` / `BufNewFile` on `*.ipynb`** — calls `load_ipynb()` to
  parse JSON and populate the buffer.
- **`BufWriteCmd` on `*.ipynb`** — calls `save_ipynb()`, checking the
  mtime guard and `v:cmdbang`.
- **`BufWipeout` per buffer** — calls `Notebook.detach()` which stops
  the kernel and clears renderer state. A separate `BufWipeout` callback
  restores any saved window-local opts across all windows (BufLeave
  doesn't fire on `:bd` / `:bw`, so without this a wiped notebook would
  leak `foldexpr` / `conceallevel` onto whatever buffer nvim swaps in).
- **`BufWinEnter` / `BufEnter` per buffer** — saves & applies window-local
  options (foldmethod, foldexpr, conceallevel) so leaving the notebook
  doesn't leak them to the next buffer. Saved opts are restored on
  `BufLeave` or `BufWipeout`.
- **`BufWinEnter` per buffer (second)** — re-runs `renderer:render()` so
  images reappear when the buffer is revealed in a new window
  (image.nvim's render path requires a visible window).
- **`TextChanged` / `TextChangedI` / `TextChangedP`** — debounced ~30ms;
  triggers `nb:rescan()` + `renderer:render()`.
- **`LspAttach`** — patches the attached client for the LSP integration
  (see "LSP integration" below).
- **`ColorScheme`** — re-applies mercury highlight groups.

Mercury fires `User MercuryAttached` once a notebook buffer is fully set
up (cells parsed, kernel client constructed, keymaps applied).
`args.data.buf` holds the buffer number. Use this for per-notebook user
hooks rather than monkey-patching Mercury.

## Health

`:checkhealth mercury` runs `lua/mercury/health.lua` and reports:

- Neovim version (must be ≥ 0.10).
- Resolved python interpreter (same resolution order as `kernel.lua`'s
  `default_python` — config, `g:python3_host_prog`, active venv,
  `python3`/`python` on PATH).
- `jupyter_client` and `ipykernel` importability **in that interpreter**
  (each checked separately so the error names the missing module).
- Available kernelspecs (so the user can see what `:NotebookKernelSelect`
  will offer).
- `image.nvim` plugin availability and enable state.
- LaTeX rasterizer backends present on PATH.
- Treesitter `python` and `markdown` parsers.

The health-check module's `default_python` resolution **must stay in
sync** with `kernel.lua`'s — divergence would mean checkhealth tests a
different interpreter than the bridge actually uses.

## Tests

Layout:

```
tests/
  minimal_init.lua          -- runtime path setup, deterministic randomseed
  ipynb_spec.lua            -- read/write round-trip, output preservation,
                            -- raw cells, attachments, dup-id detection,
                            -- nbformat_minor bump, byte-identical roundtrip
  notebook_spec.lua         -- cell scanning, id assignment, reconciliation,
                            -- id-rename side-table migration, _with_mutation
                            -- error recovery, tag deletion from separator
  cell_ops_spec.lua         -- new/delete/merge/move/convert
  output_spec.lua           -- virt_lines layout, collapse, image stacking math
  kernel_spec.lua           -- bridge protocol with a fake bridge process
  kernel_framing_spec.lua   -- partial-line / channel-lines framing
  kernel_restart_spec.lua   -- restart/interrupted/dead lifecycle
  kernel_stop_spec.lua      -- graceful shutdown order: shutdown → jobwait → chanclose → jobstop
  kernel_select_spec.lua    -- select_kernel for name / python / spec_path; mutually exclusive
  discover_spec.lua         -- python interpreter discovery from env vars and project tree
  latex_spec.lua            -- rasterizer dispatch + cache key
  multi_image_spec.lua      -- multi-image stacking math
  integration_spec.lua      -- BufReadCmd / BufWriteCmd / drain / MercuryAttached
  new_file_spec.lua         -- new/empty/malformed .ipynb handling
  extras_spec.lua           -- separator extras round-trip via mercury_extras
  keymaps_spec.lua          -- normal + insert mode bindings; <cmd> dispatch
  mtime_spec.lua            -- BufWriteCmd refuses to clobber external mods; :w! overrides
  util_spec.lua             -- coalesce, short_id, gc_cache_dir
  lsp_view_spec.lua         -- masking preserves line + column counts
  lsp_spec.lua              -- notify patching + diagnostic safety-net filter
  health_spec.lua           -- health.lua loads and check() runs without raising
  fixtures/
    simple.ipynb
  python/
    test_bridge.py          -- python unittest specs for bridge.py;
                            -- restart-seq abort path, task_q drain on restart
```

The kernel tests use a Lua-driven fake Python bridge that speaks the JSONL
protocol — no real `ipykernel` needed in CI. The python tests stub out
`kc` / `km` and exercise the restart-abort path directly; they're
pure-stdlib unittests, no `jupyter_client` required.

- `make test` runs lua specs (plenary) then python specs (unittest).
- `make test-lua` / `make test-python` run them independently.
- `make test-file FILE=tests/<spec>.lua` runs a single lua spec.

## Dependencies

- Required: Neovim ≥ 0.10, Python ≥ 3.9 with `jupyter_client` and `ipykernel`.
- Optional: `image.nvim` (kitty graphics protocol) — without it, image
  outputs render as `[image/png]` placeholder lines (the bytes are still
  preserved across save/reload).
- Optional: a LaTeX rasterizer (`pdflatex+pdftoppm`, `tex2png`, or `katex`)
  for `text/latex` outputs.
