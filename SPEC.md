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
| `markdown.lua` | Markdown TS highlighting via `parser:set_included_regions` for markdown CELLS (real buffer lines). |
| `markdown_out.lua` | Pure styler for `text/markdown` OUTPUTS. `chunks(text)` returns one virt_lines entry per source line, pre-tagged with `@markup.heading.N.markdown`, `@markup.strong`, `@markup.emphasis`, `@markup.raw.markdown*`, `@markup.list.markdown`, `@markup.quote.markdown`. Regex-based; tracks fenced-code state across lines. |
| `render_markdown.lua` | Optional shim for `render-markdown.nvim`: probes the plugin's per-buffer enable API across v5/v6/v7 surfaces and appends `python` to its filetype list. Decorative; failures are silent. Used only for markdown CELLS; outputs are styled by `markdown_out.lua`. |
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
9. **Cancellation policy matches the Jupyter kernel-protocol semantics.**
   Interrupt cancels *only* the running cell (SIGINT → `KeyboardInterrupt`);
   queued cells continue. Restart / stop / `kernel_dead` / unexpected
   bridge exit cancel both the running cell *and* the queue. See
   "Execution → Cancellation policy".

   This intentionally diverges from JupyterLab's UI-level behavior, which
   *also* drops the frontend queue when the user hits Interrupt. Mercury
   keeps the queue running because (a) the kernel's shell channel already
   buffers the queued execute_requests by the time the interrupt arrives,
   so dropping them client-side would only stop the next-to-run requests,
   not the ones already in flight; and (b) "interrupt this cell, not all
   of them" is what the verb `interrupt` literally means in the protocol.
   To drop the queue too, use `:NotebookKernelRestart` or
   `:NotebookKernelStop`.
10. **Terminal output statuses are sticky against downgrades, with two
    documented carve-outs.** Once a cell's `out.status` reaches `error` or
    `killed`, NO subsequent path may *downgrade* it (e.g., an interrupt
    arriving after an iopub `error` must not flip the error pill to
    `killed`; a `kernel_dead` arriving after an `error` must not erase the
    error signal). Implemented via `_is_terminal(status)` guards in
    `_cancel_running`, `_cancel_queue`, and `execute_done`.

    Two writes are deliberately unguarded:

    (a) `_apply_item` for an iopub `error` frame sets `out.status = "error"`
    unconditionally. This is an *upgrade* (`killed` → `error`): an
    interrupt-triggered cell typically produces an iopub `error`
    afterwards, and we want the error signal to win over the placeholder
    `killed` from the interrupt path. The sticky rule applies to
    downgrades only.

    (b) `_pump` sets `out.status = "running"` when transitioning a cell
    from `queued` to `running`. This is the re-execute path: the user
    requested a fresh run of a cell whose previous run errored, and the
    new run must produce a new live pill. The sticky rule applies within
    a single execute, not across them.
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
    handles are keyed by `content_hash` and compared via `same_placement`
    (anchor row `y`, column index `x`, width, `render_offset_top`,
    `with_virtual_padding`, target `window`). A re-render with the same
    content at the same place is a no-op. Without this, every
    TextChanged-debounced rescan recreates every handle — flicker during
    streaming output.
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
22. **Saves are atomic AND durable, with loud fsync failure modes.**
    `save_ipynb` writes via `Util.atomic_write_file` which writes to
    `<path>.mercury_save_tmp`, fsyncs the tempfile, `rename(2)`s into
    place, then fsyncs the parent directory. POSIX rename is atomic within
    a single filesystem, so an observer (another process, or a future
    `:e!` after a crash) sees either the previous complete contents or
    the new complete contents — never a torn partial write. The parent-
    directory fsync is required for durability: rename alone is atomic but
    not synchronous w.r.t. the directory entry, and a power loss between
    rename and the dirent flush can leave the entry pointing at the old
    inode (or unresolved). jupyter-server, git, sqlite, and other
    durability-sensitive writers all do the parent-dir fsync. Critical for
    a notebook editor where a `kill -9` / power loss during `:w` would
    otherwise corrupt the user's work. The tempfile lives next to the
    target so the rename stays intra-filesystem. `fs_fsync` failures on
    the tempfile are surfaced (`return false, err`) instead of being
    silently swallowed, so a disk-full / hardware error doesn't quietly
    downgrade atomicity. The parent-dir fsync is best-effort (some
    platforms don't permit `open()` on a directory) — failure is logged
    but doesn't fail the save, on the theory that "the file is on disk
    but the dirent may be lost on power loss" is still strictly better
    than "the save failed and we don't know how much state to roll back."
    A cross-filesystem rename (EXDEV — only possible if the target path's
    directory itself is on a different filesystem than where the tempfile
    landed, which is unusual since the tempfile is
    `<path>.mercury_save_tmp`) is reported with a clear error rather than
    silently falling back to a non-atomic copy.

    The write step ALSO checks `f:write`'s return value, not just whether
    it threw. Lua's `io.write` reports short writes (disk-full ENOSPC, IO
    errors) by returning `nil, err` — which a bare `pcall` does not catch.
    Without this check, a disk-full during the write step would let
    `fs_fsync` succeed on the truncated bytes and `rename` clobber the
    original notebook with a partial file. The tempfile is removed on
    failure so the next save isn't tripped by a stale `.mercury_save_tmp`.

23. **`set_kind` is a structural mutation and obeys five rules.**
    Single source-of-truth for code↔markdown↔raw conversion. The function:
    (a) refuses when the cell is busy (`cell_is_busy(id)` — SPEC
    Invariant 18 made concrete); (b) drops `outputs[id]` when the new
    kind is not `code`; (c) drops `cell_attachments[id]` when the new
    kind is not `markdown`; (d) preserves `cell_metadata[id]` fields
    other than `tags` (which the separator overwrites); (e) round-trips
    `mercury_extras` by passing the parsed `extras` table through to
    `format_separator`. Direct text-edit conversions (user edits the
    separator by hand) reach the same end-state via the `rescan` path
    (SPEC Invariant 20); `set_kind` is the menu-driven path and must
    behave symmetrically.

24. **`execute_done` honours `_live_code_cell`.** Like the `output` branch
    in `kernel.lua:_handle_msg`, the `execute_done` branch must not
    `ensure_output` for a cell that no longer exists or is no longer
    `code`. If the cell vanished mid-execution, `execute_done` still
    clears `self.running` and calls `_pump` so the queue advances, but
    it must not resurrect a writable output side-table entry that rescan
    would then have to clean up. SPEC Invariant 19 extended.

25. **Execute is blocked during the restart window.** Between
    `Kernel:restart` being called and the bridge replying with
    `restarted`, new `:NotebookExec` calls are refused with a notify.
    Mirrors Invariant 13's `_stopping` handling: without this, a
    `<S-CR>` landing in the restart window would call `_send({execute})`
    on the old kernel — the bridge's `_restart_seq` epoch keeps the
    result from being reported, but the kernel may still execute the
    code with side effects the user didn't expect.

26. **Interrupt in `mode="existing"` attempts the control-channel
    `interrupt_request`; restart in `mode="existing"` is explicitly
    unsupported.**

    For **interrupt** in existing mode: the bridge constructs and sends
    a control-channel `interrupt_request` directly via
    `kc.session.msg("interrupt_request", {})` + `kc.control_channel.send(...)`.
    This is the Jupyter messaging spec's standard path for kernels that
    advertise `interrupt_mode: "message"` in their kernelspec (Windows
    kernels, kernels running in containers, kernels managed by
    Jupyter Server). The send is fire-and-forget — control-channel
    replies are observable but Mercury doesn't wait on them; the actual
    interrupt outcome propagates via the next iopub frame (typically an
    `error` carrying KeyboardInterrupt). Signal-mode kernels silently
    drop the `interrupt_request` (no error, no kernel response) — the
    user sees Mercury's `interrupted` notification but the kernel keeps
    running. That matches JupyterLab's behavior against a non-
    interruptible kernel; we can't do better without owning the
    subprocess.

    For **restart** in existing mode: the bridge rejects with
    `kernel_error{kind="unsupported"}`. `BlockingKernelClient.shutdown(
    restart=True)` only asks the kernel itself to exit, and from a
    connection-file transport Mercury has no path to the kernel's
    supervisor (Jupyter Server's `KernelManager`, systemd, etc.) to make
    it come back. The 30-second `wait_for_ready` would time out almost
    every time. Restart through the supervisor's own UI/API, then
    `:NotebookKernelSelect` to reconnect. A future Jupyter-Server
    HTTP/WebSocket transport would handle both via the REST endpoints;
    that's out of scope (see "Non-goals").

27. **`ExecuteTime` metadata uses JupyterLab's dotted-leaf-keys shape
    with microsecond-precision ISO-8601 timestamps.** Mercury writes:

    ```json
    "metadata": {
      "execution": {
        "iopub.execute_input": "2024-01-01T12:00:00.123456Z",
        "shell.execute_reply": "2024-01-01T12:00:01.789012Z"
      }
    }
    ```

    The keys `"iopub.execute_input"` and `"shell.execute_reply"` are
    *literal dotted strings* — they are NOT a nested object path. This
    matches JupyterLab's `@jupyterlab/celltags-extension`/ExecuteTime
    extension exactly so notebooks round-trip Lab ↔ Mercury without losing
    the timing field. Microsecond precision (`.123456Z`) comes from
    `vim.uv.gettimeofday()` (or its legacy `vim.loop` alias); the previous
    Mercury implementation hardcoded `.000000Z` and lost sub-second
    information. The `iopub.execute_input` timestamp is sourced from the
    kernel's iopub `execute_input` frame `header.date` when available
    (i.e., the exact moment the kernel started executing); Mercury falls
    back to its own clock if the bridge can't extract that field.

28. **mtime guard uses nanosecond precision.** `vim.b.mercury_file_mtime`
    stores `{sec, nsec}`; the W12-style refusal compares both. Two
    external writes within the same second on a fast filesystem would
    otherwise leave the second one undetected. Falls back to seconds
    only when `nsec` is unavailable from `fs_stat`.

29. **LSP formatting can't shift markdown prose.** A formatter sees the
    masked view (markdown lines prefixed with `# `). When it returns
    `textDocument/formatting` / `textDocument/rangeFormatting` edits,
    Mercury drops any edit whose range intersects a markdown cell — the
    real buffer doesn't have those `# ` prefixes and applying the edit
    verbatim would shift the prose by 2 columns. Code-cell edits pass
    through unchanged.

30. **`Notebook.detach` clears the per-buffer augroup.** Without this,
    `:bd` (which fires `BufWipeout` → `detach`) leaves
    `MercuryBuf_<bufnr>` autocmds registered; a recycled bufnr would
    inherit them. `attach_buffer`'s `clear = true` only fires on the
    *next* attach to the same bufnr, so the gap can leak callbacks
    closing over a dead notebook.

31. **`mask_lines` normalises CRLF in markdown bodies.** A `\r\n`
    line-ending on a markdown line would otherwise turn into `# prose\r\n`
    in the masked text. Most LSP servers tolerate it, but pyright is
    known to misalign positions on CR-terminated lines. Trailing `\r` is
    stripped before the `# ` prefix is added.

32. **Diagnostic filter passes diagnostics with no `range`.** A
    server-emitted whole-document diagnostic (e.g., pyright's "could not
    parse file") has `range = nil`. The previous behaviour defaulted
    `start_row` / `end_row` to 0, which suppressed those diagnostics when
    row 0 happened to be a markdown header. The filter now keeps any
    diagnostic without a `range`.

33. **`text/markdown` outputs are styled inline via the standard
    markdown treesitter highlight groups.** `mercury.markdown_out` walks
    each line of the payload and emits virt_lines chunks with the
    matching `@markup.heading.N.markdown`, `@markup.strong`,
    `@markup.emphasis`, `@markup.raw.markdown_inline`,
    `@markup.raw.markdown` (fenced blocks), `@markup.list.markdown`, or
    `@markup.quote.markdown` group. `MercuryMarkdownOut` is the base
    fallback for plain prose. We do NOT use render-markdown.nvim's
    rendering for outputs: that plugin's decorations live as extmark
    virt_text + conceal on the source buffer, and those decorations
    cannot be relayed across buffers as virt_lines (extmarks attach to
    a single buffer). The hl groups we emit are the same ones markdown
    themes already style, so the visual result inherits the user's
    chosen palette; on a bare terminal, `ui.lua` provides sane defaults
    (Title for headings, bold/italic attrs for emphasis, Special for
    inline code).

34. **`application/vnd.jupyter.widget-view+json` mime is rendered as a
    single `[widget unsupported]` line.** ipywidgets are out of scope
    (see Non-goals); recognising the mime explicitly keeps it from
    falling through to the unknown-mime branch that would render
    `[empty output]` whenever no `text/plain` accompanies it.

35. **Markdown-cell attachments emit a one-shot load notify.** When a
    notebook's cells carry non-empty `attachments`, `load_ipynb` notifies
    once that `attachment:` references won't render inline. Prevents the
    silent "where did my pasted image go?" UX cliff.

36. **Stream items merge consecutive same-name runs on BOTH the render
    side AND the save side.** The render walks live items and groups
    consecutive `name == "stdout"` (and `name == "stderr"`) into single
    virtual blocks — even when the in-memory side-table has a
    stdout/stderr/stdout interleave — matching JupyterLab's visual
    grouping. On save, `Ipynb._merge_stream_items` runs over the
    denormalized output list and collapses runs of same-name streams
    into single entries with concatenated text, matching the canonical
    form produced by `nbformat.v4.normalize`. Without the save-side
    merge, files Mercury writes re-shape on the next pass through any
    nbformat-aware tool (Jupyter Server, nbconvert, nbdime, papermill),
    producing meaningless diffs. The stdout/stderr/stdout interleave
    survives the merge as three separate entries (stdout, stderr,
    stdout) because the rule is *consecutive same-name*, not *all of
    the same name*.

37. **`_restart_pending` is cleared on every restart-exit path.** SPEC
    Invariant 25 closes the *entry* to the restart window (executes
    refused while pending). This is the *exit* side: `_restart_pending`
    must be cleared not only by the `restarted` reply but also by
    `kernel_error` (non-`unsupported`), `kernel_dead`, an unexpected
    `on_exit`, and `Kernel:stop()`. Without these clears, a restart that
    failed (kernel didn't come back, bridge died mid-restart, transport
    rejected) wedges every subsequent `:NotebookExec` into the
    "kernel is restarting" notify forever. The `unsupported` kind is
    explicitly excluded — that's a soft warning unrelated to whether
    the restart itself landed.

38. **`_expected_exit_for` is pinned to a specific job_id.** Replaces
    the prior Kernel-level `_expected_exit` boolean. `Kernel:stop()`
    records the job_id it is tearing down; `_handle_exit(job_id)` only
    treats the exit as expected when its argument matches the pin. The
    race the pin closes: stop() runs synchronously, then a fast
    execute() spawns a NEW bridge before the OLD bridge's on_exit has
    fired; if the NEW bridge dies instantly (bad python path, missing
    module), its on_exit would otherwise consume the OLD stop()'s
    expected signal and silently swallow the new failure. With the pin,
    only the matching job_id releases — the OLD on_exit can still
    consume on a later tick, the NEW death is reported as unexpected.

39. **Tags containing `,`, whitespace, or `]` are dropped on serialize
    with a one-shot warn on load.** `format_separator` filters the tags
    list to those that survive `parse_meta`'s `tags=([^%s%]]+)` value
    class plus the `,` value-separator. `to_buffer_lines` walks every
    cell's `metadata.tags` on load and emits a WARN naming each invalid
    tag and the reason (`contains ','`, `contains whitespace`, etc.),
    so the user can fix the JSON before the next save bakes in the
    silent loss. nbformat lets tags be arbitrary strings; this is a
    documented round-trip lossiness.

    Mercury's `tags=foo,bar` grammar is a deliberate simplification of
    jupytext's richer percent-format syntax (which supports a JSON-array
    literal like `tags=["foo bar", "baz,qux"]`). Adopting jupytext's
    array form would round-trip tags with whitespace / commas / brackets,
    at the cost of a more complex separator grammar; for now Mercury
    accepts the loss and surfaces it loudly. Users who need arbitrary
    tag content should edit `metadata.tags` in the JSON directly and
    leave the separator's `tags=` token off — `mercury_extras` will not
    overwrite a JSON-only tag list since the separator is authoritative
    only for what it explicitly mentions.

40. **`delete_cell` interrupts the kernel for a running cell.** If the
    deleted cell is currently `self.kernel.running`, `Kernel:interrupt`
    is sent so the kernel raises `KeyboardInterrupt` and the queued
    work continues (Jupyter SIGINT semantics — see Invariant 9). For a
    cell that's merely queued, no interrupt is sent — the subsequent
    rescan drops it from `kernel.queue` and interrupting would cancel
    the unrelated running cell instead. Cell outputs are dropped
    either way (Invariant 18 covers the conversion case; this is the
    deletion counterpart). Side effects already produced by the running
    cell are NOT rewound — the user accepts that by choosing delete.

41. **`display_id` round-trips through save / load under
    `metadata.mercury.display_id`.** Mercury's in-memory output table
    tracks it as `_display_id`; the encoder writes it under
    `metadata.mercury.display_id` on `display_data` / `execute_result`
    outputs. The decoder reads it back from either that canonical
    location OR the legacy `transient.display_id` sibling that older
    Mercury releases (and a tiny number of in-the-wild tools) wrote.

    Why not the sibling `transient.display_id` shape: `transient` is a
    Jupyter messaging-protocol concept, not an nbformat output field.
    The nbformat v4 schema for `display_data` / `execute_result` does
    NOT list `transient` as a sibling; strict nbformat validators reject
    the shape, and `nbformat.write` (the canonical writer) never emits
    it. The Mercury-namespaced location under `metadata` is the right
    place for any Mercury-specific extension data; nbformat tolerates
    unknown keys under `metadata` by design.

    Without this round-trip, saving then reopening a notebook silently
    decoupled outputs from the display_id that other cells use to
    update them — the next `update_display(display_id=…)` call would
    fail to find a matching block and the update would be lost. The
    kernel-side `update_display_data` walker keys on `_display_id` for
    live outputs (`kernel.lua:_apply_item`); the disk and live state
    stay in lockstep through the canonical metadata location.

42. **`Kernel:restart{ clear = true }` defers the clear until `restarted`
    arrives.** A synchronous `nb:clear_all_outputs()` in `restart()`
    raced iopub frames from the dying old kernel — those frames hit
    `ensure_output` and resurrected the cleared cells before the bridge
    finished draining `parent_to_cell` (which is the moment after which
    no more old-kernel frames can be processed). The deferred-clear
    flag (`_restart_clear_pending`) is consumed by the `restarted`
    handler; on failed-restart paths (`kernel_error`, `kernel_dead`,
    unexpected exit, `stop()`) the flag is cleared without running
    the clear — outputs stay where they are, and the user can re-run
    RestartClear after the next successful restart.

    In `mode="existing"`, the deferred-clear is irrelevant: the bridge
    rejects restart entirely with `kernel_error{kind="unsupported"}`
    (Invariant 26), so `restarted` never arrives and `_restart_clear_pending`
    is cleared by the `kernel_error` path. The clear's "wait for the
    parent_to_cell drain" rationale only applies to the local-mode path
    where the drain is observable.

43. **JSON encode is fully deterministic: sorted keys, 1-space indent.**
    `Ipynb.encode` routes through `_encode_pretty` (which alphabetizes
    keys at every nesting level) rather than `vim.json.encode + reindent`
    (which preserves Lua iteration order). Without the sorted path,
    saving the same notebook twice could shuffle keys — generating
    diffs that are pure churn. Strengthens Invariant 3 (which already
    promised "sorted keys" but was not enforced in the live code path).

44. **Empty nbformat object fields serialize as `{}` not `[]`, including
    nested per-mime values.** Top-level `metadata`, cell-level
    `metadata`, output-level `metadata`, output-level `data`, AND each
    per-mime value inside `data` (e.g., an empty `application/json`
    payload, an empty `application/vnd.foo+json` object) are all routed
    through `_ensure_dict`, which converts an empty Lua table to
    `vim.empty_dict()` so the encoder emits `{}`. nbformat declares these
    fields as objects; emitting `[]` is a hard schema violation that
    nbformat validators reject.

    The nested coverage matters in practice: `IPython.display.JSON({})`
    emits an `application/json` value of `{}` which Mercury must
    preserve as an object. Without the per-mime empty-dict wrap, the
    Lua-side empty table would re-emit as `[]` on the next save.
    Strengthens Invariant 4 (which covered the in-memory sentinel path
    for empty objects loaded *from disk*; this covers the symmetric
    path for empty tables created *in memory* — fresh code cells whose
    kernel didn't emit metadata, fresh display_data with no metadata
    block, IPython.display.JSON({}), etc.).

45. **`Kernel:interrupt` and `Kernel:restart` refuse during the
    stop/restart teardown windows.** `_stopping` and `_restart_pending`
    are checked at entry. Without these guards, hammering `:NotebookKernelInterrupt`
    during the 500ms `jobwait` window would write to a channel that's
    being torn down (visible misbehavior: confusing notifies, the
    interrupt may or may not reach the dying kernel before SIGKILL);
    hammering `:NotebookKernelRestart` during the same window would
    re-enter the restart state machine on a half-dead transport.
    Symmetric with Invariant 13 (which already guarded `_ensure_started`)
    and Invariant 25 (which already guarded the execute path).

46. **`_skipped_at_save` is populated on every save with at least one
    in-flight cell.** `to_ipynb_struct` writes the in-flight set to
    `self._skipped_at_save` so the kernel's `execute_done` branch can
    mark the buffer modified when the cell finally finishes. Without
    this population pass, the read-side flush logic in
    `kernel.lua:_handle_msg` was dead code: the user could save during
    a long-running cell, wait for it to finish, run `:w` again — and
    the cell's output would silently never land on disk because vim
    tracks `modified` on text changes only. Closes a real data-loss
    hole in Invariant 14's "save again to flush" contract.

47. **Rescan id-rename migration covers both equal-length and
    unequal-length cell-set transitions.** Two code paths:

    (a) `#prev_cells == #self.cells`: position-aligned walk. For each
    position `i` whose id changed AND the previous id has no surviving
    cell anywhere in the new set, migrate the side tables (`outputs`,
    `cell_metadata`, `cell_attachments`), the kernel pointers
    (`self.kernel.running.cell_id`, every matching
    `self.kernel.queue[i].cell_id`), and the save-bookkeeping
    (`self._skipped_at_save`).

    (b) `#prev_cells ~= #self.cells`: position alignment is broken by
    the insert / delete, so we fall back to set arithmetic. If exactly
    ONE previously-known id has vanished from the new set AND that id
    had side-table entries AND exactly ONE id in the new set is fresh
    (no side-table entries), the pairing is unambiguous — migrate. Any
    ambiguity (multiple vanished, multiple new) leaves the side tables
    to GC, on the conservative principle that a rename heuristic gone
    wrong silently corrupts the user's data while a missing rename
    just makes the user re-execute.

    Without (a), the rename left kernel pointers pointing at the dead
    id: `_live_code_cell` dropped every subsequent iopub frame (silent
    output loss on the running cell). Without (b), a rename + unrelated
    delete in the same edit batch would lose the renamed cell's
    outputs. Strengthens Invariant 4 ("ids are stable across edits")
    by making the kernel state and the unequal-length case both honor
    the migration.

48. **`_cancel_running` resets transient execution fields on the output.**
    `out._pending_clear` and `out._started_iso` are cleaned up alongside
    the status flip. Without this reset, a re-execute of the same cell
    after `:NotebookKernelInterrupt` would silently wipe the first chunk
    of new output (because `_pending_clear` from the killed run carries
    over and gets honored by the next `_apply_item`); and a stale
    `_started_iso` would land in the cell_metadata.execution block on
    the next `execute_done`, producing an ExecuteTime "start" without a
    matching "end" timestamp. Sticky-terminal status semantics
    (Invariant 10) are preserved — `error` doesn't downgrade to
    `killed` — but the transient bookkeeping fields are unconditionally
    cleared.

49. **`merge_below` refuses on a busy cell.** Symmetric with `set_kind`
    (Invariant 18) and `delete_cell` (Invariant 40): if either the
    current cell OR the cell being merged into it is in `kernel.running`
    or `kernel.queue`, the merge is refused with a notify. Without this,
    a merge would silently drop the merged-away cell's id from
    `nb.cells`; iopub frames for that id are then dropped by
    `_live_code_cell` (Invariant 19) while the kernel keeps executing
    the code with side effects (file writes, network calls) that the
    user can no longer observe. The conservative choice is to refuse —
    the user can `:NotebookKernelInterrupt` then retry.

50. **`load_ipynb` preserves a parsed-but-empty-cells file.** When the
    JSON parses but `cells: []`, the load path keeps the original
    `metadata` (kernelspec, language_info, etc.) and synthesizes a
    single placeholder code cell so the user has somewhere to edit. The
    buffer is NOT marked modified, so a casual `:w` with no edits won't
    fire `BufWriteCmd` and won't overwrite the original file. Pre-fix:
    mercury replaced the parsed empty notebook with `blank_notebook()`
    and marked the buffer `fresh=true`, silently rewriting the file
    with hard-coded default metadata on the next save. Pairs with
    Invariant H13 (malformed JSON → readonly raw bytes) — different
    failure mode, same protect-user-data principle.

51. **`Kernel:execute` strips the trailing visual-gap blank line from
    the body before sending to the bridge.** `to_buffer_lines` inserts
    a blank line between cells for visual separation; `cell_body_lines`
    includes it because `body_end` covers it. The kernel must not see
    this blank — it's purely a UI artifact, never typed by the user,
    and `to_ipynb_struct` already strips it on save (Invariant for
    "Trailing blank lines on non-last cells"). Without this trim, a
    `%timeit foo` magic with a trailing blank could be interpreted
    differently, and `??`-style source introspection would display
    spurious trailing whitespace. Symmetric: the visible gap is the
    same idea on both sides — display-only.

52. **`_apply_item update_display_data` fires `on_change` when the
    update mutates a DIFFERENT cell's items.** Defense in depth: the
    same-cell case is covered by the caller's existing `on_change` (in
    `_handle_msg`'s `output` branch); the cross-cell case must not
    depend on the caller's discipline because a missing render here
    means the update lands in state without ever reaching the screen.
    `on_change` is coalesced (Invariant 7) so a redundant call collapses
    into the same tick — no double-render cost. Strengthens
    cross-cell `update_display(display_id=…)` semantics.

53. **`rescan` interrupts the kernel when a busy code cell is converted
    to non-code via direct text edit.** `set_kind` already refuses on
    busy (Invariant 18), but a user hand-editing the separator from
    `# %% id=X` to `# %% id=X [markdown]` bypasses `set_kind` — the
    conversion lands via the rescan path. Without an interrupt, the
    kernel keeps executing the original code (side effects continue)
    while iopub frames are silently dropped by `_live_code_cell`
    (Invariant 19). When `rescan` detects that `kernel.running.cell_id`
    now points at a cell whose kind has flipped away from `code`, it
    calls `kernel:interrupt()` so the kernel work stops in a
    user-observable way. Symmetric with `delete_cell`'s interrupt
    path (Invariant 40); queued-only cells need no interrupt because
    rescan's "no longer code" queue filter evicts them and there's
    no live execution to SIGINT.

54. **`Output.to_plain_text` mirrors what `build_virt_lines` shows.**
    The copy text (`:NotebookOutputCopy`) and the scratch view
    (`:NotebookOutputView`) must reflect the rendered output, not the
    raw mime payload. Concretely:

    - The status pill is emitted as a leading line: `Out[N]  142 ms  ✓`
      for ok, `Out[N]  ✗` for error (the same `0 ms` suppression that
      the visible pill uses applies here), `running…` / `queued` /
      `killed` for the in-flight statuses. Fresh-cell idle outputs emit
      no pill (matches the visible render).
    - `text/html` is stripped through `html_to_text` (same as the inline
      render).
    - `text/markdown` keeps its raw source (the inline render styles it
      but the underlying text is what the user wrote).
    - `application/vnd.*+json` and `application/json` JSON-encode for
      human readability.
    - The `widget-view+json` mime emits `[widget unsupported]`.
    - An output with no recognizable mime emits `[empty output]` (mirrors
      the visible render's same placeholder).
    - True binary payloads (`image/*`, `application/octet-stream`) emit
      the `[mime, N bytes]` placeholder.

    Without this, "what you see" and "what you copy" diverged for the
    most common HTML-only output — e.g., a pandas DataFrame's
    `_repr_html_` would render as stripped text on screen but copy as
    raw `<table>…` markup.

55. **`Kernel:list_kernels` has a bounded timeout.** If the bridge
    accepts the request but never replies (bridge bug, wedged kernel
    spec manager), the registered callbacks fire after 5 seconds with
    an empty list and a WARN. Without this, the picker would never
    open and the user would have no recovery short of
    `:NotebookKernelStop`. The timer is cancelled on the legitimate
    reply, on `Kernel:stop()`, and on bridge exit; multiple in-flight
    `list_kernels` calls share the one timer (matching the existing
    callback-queue fan-out).

56. **Image renderer prefers the currently-focused window showing the
    buffer, falling back to the first valid one.** `vim.fn.win_findbuf`
    enumerates windows in tab/creation order, which often doesn't match
    user focus when the buffer is open in multiple splits. Mercury's
    selection rule:

    1. If the currently-focused window shows this buffer, use it.
    2. Otherwise walk the win_findbuf list and pick the first valid one.
    3. If no valid window exists, return early WITHOUT touching the
       per-cell handle cache — image.nvim's render path requires a live
       window, and the `BufWinEnter` autocmd in `init.lua` re-runs
       `renderer:render()` when the buffer is revealed, so cached
       handles survive the gap and the next render reuses them cheaply
       via `same_placement()`.

    Without rule (1), a user with the notebook open in two splits saw
    images render into whichever split happened to be enumerated first
    by `win_findbuf` — typically a background split, leaving the
    focused split visually empty. Rule (2) is the stale-window guard:
    `win_findbuf` can return a handle that closed between the kernel
    emitting `output` and the coalesced render firing.

57. **nbformat v3 is refused on load with a clear migration hint.**
    nbformat v3 has a completely different schema (`worksheets`,
    `prompt_number` instead of `execution_count`, etc.). Reading it as
    v4 silently produces a notebook with no cells, and a casual `:w`
    then overwrites the original with Mercury's placeholder —
    destroying the user's data. The decoder refuses with
    `"nbformat v3 is not supported by Mercury (reads v4 only). Run:
    jupyter nbconvert --to notebook --inplace <file>"` so the user can
    upgrade in place before Mercury touches the file. Forward-incompat
    versions (a hypothetical nbformat v5) are also refused for the
    same reason.

58. **Multiline text mimes and stream text serialize as
    arrays-of-strings on save.** `nbformat.write` canonical form for
    multiline `text/*` mimes and stream `text` is an array of strings,
    one per source line, with `"\n"` retained on all but optionally the
    last (`text.splitlines(keepends=True)`). Mercury holds these as a
    single string in memory for ease of edit / render and converts back
    to array form via `Ipynb._to_multiline_strings` on save. Without
    this, files Mercury writes diff loudly against files Jupyter Lab /
    nbconvert / nbformat.write produce, and "byte-stable round-trip"
    (Invariant 3's spirit) fails for any notebook that came from
    upstream tooling. A single-line value stays a plain string —
    nbformat accepts both forms.

59. **`_denest_mime_value` is scoped to `text/*` mimes.** nbformat's
    multilineString form (string OR array-of-strings, joined on read)
    applies *only* to text mimes; for `application/json` and
    `application/vnd.*+json` payloads, an array of strings is
    legitimate data (e.g., a Plotly trace's categorical axis labels,
    a JSON-Schema enum, a Vega-Lite spec field). The pre-fix denest
    joined every string-array payload, silently corrupting
    JSON-mime arrays to a single concatenated string. The fix passes
    the mime key to the denester and skips the join for non-text mimes.

60. **Unknown `cell_type` values round-trip losslessly.** The decoder
    renders any cell_type other than `code` / `markdown` / `raw` as
    `code` internally (Mercury can't display a hypothetical `sql` or
    `julia` cell type), but stashes the original cell_type under
    `metadata.mercury_original_cell_type`. The encoder restores it on
    save and strips the stash so the file looks identical to its
    pre-Mercury form. nbformat is a living format; this avoids data
    loss as new cell types are added by upstream specs.

61. **`update_display_data` for a stale display_id is silently dropped.**
    When `IPython.display.update_display(display_id=X)` fires and no
    output anywhere in the notebook holds display_id `X` (because the
    cell that created it was deleted, or its outputs were cleared),
    JupyterLab silently drops the update. Mercury matches: in
    `_apply_item`'s `update_display_data` branch, if `did` is non-nil
    and no items were updated, we return without inserting a phantom
    display_data block in the calling cell. The previous fallthrough
    created a ghost output in the wrong cell.

62. **`stop_on_error=True` on every `execute_request`.** Matches
    JupyterLab's "Run cells" semantics: if the running cell errors,
    any execute_requests already buffered on the shell channel are
    skipped by the kernel rather than running through. Mercury's
    client-side queue is one-at-a-time so this mostly matters as a
    belt-and-braces guard against any future path that submits
    multiple requests in flight; aligning with Lab's default also
    keeps notebook behavior consistent for users who switch between
    the two clients.

63. **`execute_input` is forwarded from iopub for live `In[N]`.** The
    kernel publishes `execute_input` on iopub the moment it pulls the
    request off the shell channel; this is what JupyterLab / VS Code
    use to bind the `In[N]` prompt eagerly, well before
    `execute_reply` lands. The bridge forwards a synthesized
    `execute_input` message with `cell_id`, `exec_count`, and
    `started_iso` (taken from the iopub header's `date` field — the
    canonical kernel-side timestamp); Mercury's Lua side binds
    `out.exec_count` and `out._started_iso` immediately. ExecuteTime
    metadata (Invariant 27) then reflects the kernel's start
    timestamp rather than Mercury's `_pump`-time estimate.

64. **`clear_output(wait=True)` preserves prior output at end-of-cell.**
    `IPython.display.clear_output(wait=True)` documented semantics: defer
    the clear until the next output arrives; if no output follows before
    the cell finishes, the prior content stays. This is what keeps
    tqdm's final progress-bar frame visible after the loop exits. The
    `execute_done` handler clears the deferred-clear flag (so a
    re-execute of the same cell starts clean) but does NOT wipe
    `out.items` — matching JupyterLab / VS Code / classic Notebook
    behavior.

65. **Collapsed output state persists across save/load under JupyterLab's
    canonical metadata locations.** Mercury writes BOTH
    `cell.metadata.collapsed = true` (classic-Notebook key, still
    tolerated by Lab) AND `cell.metadata.jupyter.outputs_hidden = true`
    (Lab/VS Code's modern key) when a cell's output is collapsed.
    Reading: either key collapses the output on load. Toggling expand
    explicitly clears both. Without this, the collapse state was
    in-memory-only and reopening the notebook always showed every
    output expanded.

66. **LSP `reset_server_view` runs before any LspAttach can fire.**
    `load_ipynb` calls `attach_buffer(buf)` (which registers the
    notebook in `Notebook._registry`) *before* assigning
    `vim.bo[buf].filetype = "python"`. Setting filetype synchronously
    fires `FileType` and Neovim's auto-attach handler then fires
    `LspAttach` — by which point `Notebook.get(buf)` returns a live
    notebook and Mercury's LspAttach handler can call
    `reset_server_view(buf)` with the masked text. Without this
    ordering, the very first didOpen reached pyright / ruff / mypy
    with the raw markdown lines, and those servers cached a parse
    that diverged silently from Mercury's mask. On `:e!` reloads, an
    already-attached LSP client doesn't fire LspAttach again;
    `load_ipynb` explicitly schedules a `reset_server_view` for those
    clients so the new file's masked text reaches the server
    immediately.

67. **mtime guard path comparison resolves symlinks.** Both the
    loaded path (stored on the buffer) and the save target are passed
    through `vim.loop.fs_realpath` before string-comparison.
    Without this, an `:e` via `/var/folders/...` and a later `:w` via
    `/private/var/folders/...` (macOS's typical symlinked temp dirs)
    would compare unequal, the guard would short-circuit on
    "different file (saveas semantics)", and external modifications
    to the actual file would not trigger the W12-style refusal.

68. **`format_separator` id-assignment is a splice, not a rebuild.**
    When `scan_lines` flags a cell as missing an id, `_apply_id_assignments`
    splices `id=<new>` into the existing header line via a regex
    substitution — preserving any non-token text the user typed (e.g.,
    `# %% Cell title` becomes `# %% id=abc12345 Cell title`). For
    `dup_rewrite` cells (a yank-and-paste that duplicated an id), only
    the `id=` token is replaced, leaving the rest of the header line
    text intact. The full `format_separator` rebuild is reserved for
    paths that genuinely synthesize a fresh separator (e.g.,
    `:NotebookCellNewBelow`) where there is no existing line text to
    preserve.

69. **`_skipped_at_save` is cleared on unexpected bridge exit.** The
    table tracks cells that were in-flight at the last `:w` so a later
    `execute_done` can mark the buffer modified (so the user's next
    `:w` captures the now-finished output — Invariant 14). If the
    bridge dies before the cell finishes, the cell never emits
    `execute_done`; without clearing `_skipped_at_save` the table would
    grow unboundedly across crashes and the "save again to flush"
    contract would silently break. `_handle_exit`'s unexpected-exit
    path clears the table.

70. **`MercuryAttached` fires once per buffer, not once per reload.**
    `:e!` and similar reload paths detach + reattach the notebook
    repeatedly across a session, but `User MercuryAttached` consumers
    (statusline refresh, lazy keymap install, per-buffer LSP wiring)
    are typically idempotent-but-expensive and the user expects "this
    runs when I open the notebook." Mercury sets
    `vim.b[buf].mercury_user_attached_seen` after the first emit; the
    autocmd doesn't fire again for the same buffer. (Other internal
    re-attach paths — augroup recreation, rescan, render — still run
    every reload as before.)

71. **Window-local opts (foldmethod / foldexpr / conceallevel) are
    saved against the user's pre-mercury values, not mercury values.**
    The BufEnter handler that snapshots the previous wo state skips
    the save when it detects that the window already shows mercury
    wo (foldexpr containing "mercury"). Without this, switching
    between two mercury notebooks in the same window — A → B → A —
    could snapshot mercury's own foldexpr as the restore target;
    leaving the window then leaked mercury's fold/conceal to the next
    non-mercury buffer.

72. **LSP responses with positions inside markdown cells are filtered.**
    The diagnostic filter (Invariant 32) already does this for
    `textDocument/publishDiagnostics`. Mercury extends the same idea to
    `textDocument/inlayHint` and `textDocument/codeLens` responses:
    any hint / lens whose `position.line` (or `range.start.line`) falls
    inside a markdown cell is dropped before vim renders it. The
    motivating case is pyright's type-comment matcher: a markdown line
    containing prose like `"the type: int parameter"` becomes
    `"# the type: int parameter"` in the masked view, which pyright
    pattern-matches as a `# type:` type-comment and emits an inlay hint
    on it. Without the filter, the hint surfaces on top of the user's
    prose — confusing and misleading. With the filter, markdown rows are
    silently dropped from every position-bearing proactive response,
    matching the "markdown cells are invisible to the LSP" contract.

73. **Queued cells display their 1-based position in the kernel queue.**
    When a cell is queued, its status pill renders `⏸ queued #N` where N
    is the position in `kernel.queue` (1-indexed). The position is
    derived in the UI render pass on every tick — not stored on `out` —
    so an enqueue / dequeue elsewhere in the queue updates every
    queued cell's pill in lockstep with the next render. Falls back to
    bare "queued" when no position is supplied (non-UI callers /
    pre-attach state).

74. **`kernel.auto_install` controls dependency-install policy.** Before
    the bridge spawns, Mercury probes the resolved python for
    `jupyter_client` and `ipykernel` (single `python -c` exec, cached
    per python path). On missing modules the behavior is:

    * `auto_install = "ask"` (default) — prompt the user once via
      `vim.ui.select` to confirm install. On confirm, run
      `<python> -m pip install <modules>` asynchronously.
    * `auto_install = true` — run the same install with no prompt.
    * `auto_install = false` — emit an error notify with the exact
      `pip install` command and refuse to launch.

    All three paths are non-blocking. The install kicks off async and
    the user re-triggers `:NotebookExec` once Mercury notifies that the
    install landed. Concurrent installs are gated by `_install_pending`;
    a second execute while one is in flight emits an INFO notify and
    bails.

    `:NotebookKernelSelect` does NOT trigger this prompt — it calls
    `_ensure_started({ silent_deps_check = true })` so the picker opens
    immediately even with missing deps, populated from discovered
    pythons + manual entry. The picker is itself the recovery path
    (switch to a venv with deps installed), so blocking it on the
    install prompt would create a deadlock.

    **Prompt frequency.** The probe is gated by the bridge lifecycle —
    once the bridge is running successfully, subsequent executes return
    from `_ensure_started`'s "is the job alive?" early-exit and don't
    re-probe. The `ask`-policy modal prompt itself is further gated:
    after the user picks "Cancel" once for a given python, mercury
    records `_install_declined[python] = true` and surfaces a terse
    error notify (manual `pip install` command + a
    `:NotebookKernelSelect` hint) on subsequent executes — no further
    modal dialogs. `select_kernel` clears the declined map because the
    new python's deps state is the user's call again.

75. **Image rendering — locked invariants.** This invariant exists
    after three failed redesigns; future changes must satisfy all of
    these or the cell becomes visually broken in one of the documented
    ways. Each invariant has a single source of truth and a pin in
    `tests/image_interleave_spec.lua`.

    **I1 — Image SIZE.** Render width in editor cells =
    `min(floor(window_cols * 0.85), ceil(image_pixel_width / cell_width_px))`.
    `cell_width_px` is the Mercury config default (8) — NOT queried
    from image.nvim at runtime. Querying image.nvim returned values
    larger than 8 on common terminals, which shrank images visibly;
    users had configured around the 8-px assumption and the
    "image looks much smaller" regression was real. Users on terminals
    with materially different cell widths override via `setup()`.

    **I2 — Document-order interleave.** Output items render top-to-
    bottom in the order they appear in `out.items`. For
    `[stream, image, stream, image]`, the visible cell is:
    `pill → stream1 → image1 → stream2 → image2`. Notebook design
    parity (JupyterLab / VS Code) is non-negotiable.

    **I3 — No pill / text overlap.** The Out[N] pill renders above all
    images. Text items emitted before an image render above that
    image; text items emitted after render below that image.

    **I4 — No inter-image overlap.** Multiple images in one cell stack
    vertically (cumulative `render_offset_top`), each fully visible,
    separated by a 1-row visual gap.

    **I5 — Best-effort cell-spill safety via matched row math.**
    Mercury's reservation aims to match image.nvim's actual render
    via I14 (runtime cell sizes) plus a 1-row gap below each image.
    There is NO image.nvim backstop — `with_virtual_padding = true`
    is no longer used (see I16). On terminals where the runtime
    cell query is unreachable AND cell aspect deviates >1 row
    from 8×16, the last image's bottom row may bleed into the next
    cell. Users on such terminals override `output.cell_height_px`
    via `setup()`.

    **I6 — Per-image height: NO safety margin.** Each image's reserved
    virt_lines = `image_row_height(...)`, clamped to
    `image_max_height_rows`. The +1 gap row that
    `Output.build_virt_lines` adds AFTER every non-trailing image
    absorbs any 1-row sub-cell drift between Mercury's math and
    image.nvim's actual render. Adding a separate per-image safety
    bump on top double-counted that buffer and produced the visible
    blank row below every image (the "too many lines between
    sequential images" regression).

    Runtime-query-fallback path (`image.utils.term` not available
    → static 8×16): drift can exceed 1 row for terminals whose cell
    aspect isn't 1:2. The trailing image's
    `with_virtual_padding=true` + `overlap=render_offset_top`
    (SPEC I15) provides the cell-spill backstop in all cases. For
    non-trailing images on a divergent terminal, drift may bleed
    into the next item — users on such terminals should override
    `output.cell_height_px` via `setup()`.

    **I7 — Image-blank rows bypass `max_preview_lines`.** Truncating a
    cell to N lines must apply only to TEXT rows. Image-blank rows
    are reservation, not preview content; truncating them lets
    image.nvim render past Mercury's reservation and paint over the
    next cell. The hidden-lines marker counts only suppressed text.

    **I8 — Single extmark for the cell's virt_lines.** ONE extmark
    per cell at `cell.body_end` carries pill + text + image-blank
    rows in document order. Image placements live in a parallel
    cache (managed by image.nvim) keyed by content hash. Multi-extmark
    layouts (one extmark per text segment + one per image) were
    tried twice and produced two distinct visual failure modes:
    (a) image.nvim's `inline=true` anchored each image at the
    extmark's buffer row regardless of `render_offset_top`, so every
    image rendered at `cell.body_end` and stacked over the pill;
    (b) `clear()` not fully tearing down image.nvim's terminal
    placement on cache invalidation, producing duplicate "slots."
    Single-extmark + cumulative offsets is the only configuration
    that satisfies I2–I5 simultaneously.

    **I9 — `with_virtual_padding = false` on EVERY image.** image.nvim's
    per-image virtual padding stacks additively with our virt_lines
    and double-reserves rows below every image. Combined with I16
    below: Mercury's virt_lines are the sole row reservation; image.nvim
    only paints the pixels.

    **I10 — `same_placement` invalidation fields.** A cached
    image.nvim handle is reused only when ALL of these match: window
    id, anchor row (`y`), extmark column (`x`), width, render offset
    top, and the virtual-padding flag. Anything else mutates → clear
    + recreate via `from_file`. No `handle:render()` is called on a
    cache hit; some image.nvim versions treat repeat `render()` as a
    second placement, which previously produced the
    "single image renders twice" regression.

    **I11 — `force_invalidate_all` only fires on `VimResized`.** That
    is the one event where the terminal's cell pixel dimensions
    actually change, invalidating image.nvim's geometry. Wiring it to
    `BufWinEnter` / `TabEnter` / `WinEnter` produced the duplicate-
    placement bug under I10 — clear-then-recreate left both the old
    and new placement visible. On those events Mercury just re-runs
    the renderer; cached handles survive and image.nvim's own redraw
    machinery repaints them.

    **I12 — `height` is NOT passed to `image.nvim`'s `from_file`.**
    Real image.nvim builds render nothing when both `width` and
    `height` are forced. Only `width` is passed; image.nvim derives
    height from the on-disk pixel dimensions plus its own terminal
    cell-size measurement.

    **I13 — `render_offset_top = virt_line_index + 1`.** image.nvim's
    `renderer.lua` computes the image's on-screen position as:

    ```
    absolute_y = screenpos(window, y+1, x+1).row + render_offset_top
    ```

    `screenpos.row` returns the screen row of `body_end` ITSELF, not
    the row below it. The first virt_line that any extmark anchored
    at `body_end` attaches to that row displays at
    `body_end_screen + 1`. So if Mercury wants the image to land at
    its reserved virt_line index `K` (0-indexed within our virt_lines
    stack), `render_offset_top` MUST be `K + 1`.

    `Output.build_virt_lines` returns `image_offsets[i]` as the
    0-indexed virt_line index. `Image:render` adds the `+1` when
    setting `opts.render_offset_top`. Forgetting this conversion
    makes the image render exactly one row too high — the first
    image ends up on the pill row (the "image overlaps Out[N]"
    regression), and subsequent images each shift one row earlier
    than their reserved blanks (the "image overlaps text" regression).
    The +1 lives in `image.lua` so future refactors of the
    output-builder cannot reintroduce the off-by-one without also
    changing the image renderer.

    The conversion is sourced from image.nvim's
    [`renderer.lua`](https://github.com/3rd/image.nvim/blob/master/lua/image/renderer.lua)
    (the `screenpos + render_offset_top` block) and
    [`image.lua`](https://github.com/3rd/image.nvim/blob/master/lua/image/image.lua)
    (the extmark-creation block that anchors virt_lines below the
    queried row).

    **I14 — Row reservation must use image.nvim's runtime cell sizes.**
    image.nvim's height formula (from
    [`renderer.lua`](https://github.com/3rd/image.nvim/blob/master/lua/image/renderer.lua)
    + [`utils/term.lua`](https://github.com/3rd/image.nvim/blob/master/lua/image/utils/term.lua))
    is:

    ```
    target_w_px  = img_cols * runtime_cell_w
    scaled_h_px  = h_px * (target_w_px / w_px)
    rendered_rows = ceil(scaled_h_px / runtime_cell_h)
    ```

    `runtime_cell_w` and `runtime_cell_h` come from `TIOCGWINSZ`
    ioctl at image.nvim startup (8×16 fallback only when the terminal
    doesn't report). Mercury MUST use those same values when
    computing the row count to reserve in virt_lines — otherwise the
    reservation underflows for any terminal whose cell aspect ratio
    isn't 1:2, and the image paints over the row below it.

    The width side (I1) deliberately keeps Mercury's static 8, since
    that controls `natural_cols` and therefore the user-visible image
    size. The height side (I14) uses image.nvim's values, so we
    reserve exactly what image.nvim will draw. The `+25% +3` safety
    margin from I6 stays on top of the runtime-based row count to
    catch a failed query (image.nvim API drift / mock environment)
    or any future image.nvim scaling pass we haven't yet modelled.

    Field names are `cell_width` and `cell_height` on the table
    returned by `require("image.utils.term").get_size()`. The
    `_runtime_cell_size()` helper in `image.lua` is the single
    source of truth; it returns `nil, nil` on any failure path so
    the caller's config-default fallback runs.

    **I16 — Mercury's virt_lines are the SOLE row reservation.**
    No `with_virtual_padding`. image.nvim only paints pixels at
    `screenpos + render_offset_top`; the row count comes from
    `build_virt_lines` pushing image-blank rows for every image,
    period.

    `with_virtual_padding = true` was tried and discarded: it
    duplicates the `render_offset_top + image_height` reservation on
    top of our virt_lines, producing visible "empty space till end of
    screen" below every image.

    `overlap` IS now set (large constant — see SPEC I18) for a
    different reason: steering image.nvim's scroll-past-anchor path.
    Setting `overlap` does NOT reintroduce padding because we keep
    `with_virtual_padding = false` — `get_reserved_lines` is only
    consulted when padding is on.

    Trade-off accepted by I16: cell-spill safety becomes
    "best-effort matched math" (I14 + the 1-row gap in I6's
    formula) rather than a hard image.nvim backstop. On terminals
    where the runtime cell-size query fails AND the cell aspect
    deviates from 8×16 by more than one row of drift, the last
    image's bottom row may visually bleed into the next cell. The
    1-row gap below every image absorbs typical drift; users on
    unusual terminals override `output.cell_height_px` via setup().

    **I17 — Mercury fully REMOVES images from image.nvim's registry,
    not just clears them.** `Image:clear()` deletes the buffer
    extmark and clears the terminal pixels, but does NOT remove the
    Image object from image.nvim's `state.images` table. image.nvim's
    `WinScrolled` / `WinResized` autocmds iterate that table and
    call `render()` on every entry — recreating extmarks and
    re-painting cleared images. The user-visible bug:
    `:NotebookKernelRestartClear` would clear outputs and Mercury's
    image handles, but the images would reappear on the next scroll
    event because image.nvim's registry still held them.

    image.nvim doesn't expose a public removal API. Mercury reaches
    into `image.global_state.images[image.id] = nil` after calling
    `Image:clear()`. This is a bounded internal-state hack — if
    image.nvim ever ships a public `api.destroy(id)`, swap to that.

    Applied at three sites in `image.lua`:
      * `_clear_handles(cell_id)` — when a cell is deleted, merged,
        or its output cleared.
      * Cache-eviction loop inside `Renderer:render` — when an
        image's hash disappears from the current render's image set
        (cell re-execution producing different output).
      * Cache-miss replacement inside the render loop — when a new
        image replaces an old one at the same cell.

    **I18 — Every image gets `overlap = 1000` to route image.nvim's
    scroll-past-anchor path through `get_overlap_scroll_position`
    (per-image position) instead of the diff branch (same row for
    same-height images = visible overlap).**

    The bug. image.nvim's renderer, when the anchor row goes off the
    top of the viewport (`screenpos` returns 0,0), has three
    branches:

    ```lua
    if original_y + 1 == win_info.topline then
      absolute_y = win_info.winrow                              -- lock
    else
      overlap_absolute_y = get_overlap_scroll_position(...)
      if overlap_absolute_y then
        absolute_y = overlap_absolute_y                         -- good
      else
        ...
        absolute_y = win_info.winrow - height + diff - 1        -- diff
      end
    end
    ```

    The `diff` branch computes `absolute_y` from `height` only —
    `render_offset_top` is NOT added (line 348's `if not
    is_partial_scroll` skips the addition). For a Mercury cell with
    two same-height images (e.g., two matplotlib plots) and a shared
    anchor row (single-extmark interleave, SPEC I8), BOTH images
    compute the SAME `absolute_y` here. They paint on top of each
    other; the later-rendered image wins. User report:
    "image 1 snaps to image 2's position and displays on top."

    The fix. `get_overlap_scroll_position` returns
    `winrow + render_offset_top - scrolled_lines` — a per-image
    position because each image has its own `render_offset_top`.
    Setting `overlap = LARGE` keeps the
    `if scrolled_lines >= overlap_lines then return nil` cap
    inside `get_overlap_scroll_position` from firing, so the
    function reaches the `visible_height = height + offset_top`
    check; that check naturally returns nil (→ hide) only when the
    image is fully off the top.

    Value choice. Any constant larger than `max(height +
    offset_top)` across all images would work. 1000 is well above
    any reasonable viewport, costs nothing at runtime, and stays
    cap-inactive even for very tall cells. Earlier failed attempt
    used `overlap = render_offset_top` (typically 2-30) — the cap
    tripped after a few scroll lines and the diff branch took over.

    Why setting `overlap` doesn't reintroduce I16's old problem.
    `overlap` affects two places in image.nvim:
      * `get_reserved_lines` — only consulted when
        `with_virtual_padding = true`. Mercury keeps it `false`
        (SPEC I16), so no row duplication.
      * `get_overlap_scroll_position` — the scroll path we WANT to
        steer into.

    Companion: `Renderer:rerender_all_handles()`. image.nvim's
    WinScrolled handler defers its render through `vim.schedule`
    (`render_scheduler.lua`), so there's one event-loop tick of lag
    between the scroll and the image moving. The per-buffer
    WinScrolled autocmd in `init.lua` calls
    `rerender_all_handles()` inline to re-emit each cached handle's
    kitty placement on the same tick, eliminating the perceived
    lag. No disk read (image.nvim's `transmitted_images` cache
    holds the bytes), no coalescing (would reintroduce the lag).

    Earlier failed attempts (formerly I18 / I19): `window = nil` +
    manual `image:move` on WinScrolled (broke layout entirely:
    images overlapped, floated, persisted on screen). Lock-zone
    pre-clear (vanished images during scroll instead of fixing
    the diff-branch root cause). Both REVERTED.

    Marker storage detail: the blank-row marker lives in a parallel
    `body_blank[i]` array, NOT as a field on the chunk table.
    Attaching `_image_blank = true` to a `{ text, hl }` chunk made
    Neovim's strict `virt_lines` extmark converter reject the table
    ("Invalid 'virt_lines': Cannot convert given Lua table") — chunks
    must be pure 2-element arrays.

76. **Cached image handles are re-painted on every render call.** When
    `same_placement` confirms a cached handle matches the new opts,
    Mercury still calls `handle:render()` again rather than treating the
    cache hit as a no-op. `image.nvim`'s `render()` is idempotent (no
    disk read, no decode — just re-emits the kitty graphics protocol
    bytes against the current window), so the cost is negligible. The
    motivating case: switching tabs and returning leaves image.nvim's
    terminal-side state cleared even though the Lua handle survives;
    re-painting on every render brings the image back. Mercury also
    registers `TabEnter` / `WinEnter` / `VimResized` autocmds on the
    per-buffer augroup to trigger re-renders when those events fire (the
    callback bails when no window shows the buffer, so global events
    only cost a render when relevant).

77. **Orphan output extmarks are explicitly deleted on cell removal.**
    When a cell vanishes from `nb.cells` (separator line deleted, cell
    merged away), `Renderer:render` calls `nvim_buf_del_extmark` on the
    cell's `_marks[id]` entry in addition to GC'ing the Lua table. The
    extmark itself does NOT disappear with the deleted separator line —
    nvim relocates it to an adjacent row — so the cell's pill + body
    would otherwise stay rendered against the merged cell with no way
    to clear it (`:NotebookOutputClear` operates by cell-id at cursor,
    and the orphan's id is unreachable). Symmetric pattern: the image
    GC in `Image:gc` already calls `:clear()` on each handle for
    deleted cells (Invariant 17); this extends the same lifecycle to
    output virt_lines.

78. **`Kernel:restart({clear=true})` clears outputs even when the bridge
    is dormant.** The user's intent — wipe what's on the page and start
    over — should not be tied to whether the kernel happened to be
    running. On a freshly-opened notebook (bridge never started, outputs
    loaded from disk), `restart({clear=true})` calls
    `notebook:clear_all_outputs()` synchronously and notifies, instead
    of bailing out with "kernel is not running". Plain `restart()`
    (no clear flag) keeps the bail-out behavior since there's nothing
    to bounce.

79. **`:NotebookKernelInfo` is the single source of truth for "which
    kernel am I on?".** The command notifies a multi-line summary
    produced by `Kernel:info()` — mode, active selector
    (python/spec_path/name in resolve-order), connection_file (for
    existing-mode), bridge state, currently-executing cell, and queue
    length. The lualine `kernel` component shows the same selector but
    abbreviated via `Discover.short_label` for absolute python paths;
    `Kernel:info()` always shows the full path. Default keymap is
    `<leader>k?` to match the `<leader>k*` kernel-action prefix.

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
- **ipywidgets / interactive comms.** Mercury does not subscribe to the
  Jupyter `comm_open` / `comm_msg` / `comm_close` channels and does not
  render `application/vnd.jupyter.widget-view+json`. A widget mime in the
  output is rendered as a single `[widget unsupported]` placeholder line.
  When the kernel emits widget output alongside a `text/plain` repr the
  text repr renders as usual (per the mime priority list). Supporting
  widgets would require both the comm protocol and an in-buffer
  interactive-widget renderer; both are out of scope.
- Inline rendering of markdown-cell `attachments:` (paste-image-into-prose).
  Attachments are preserved verbatim across save/load — see "Cell
  attachments" — but `attachment:<filename>` references in markdown body
  remain literal text. Mercury notifies once on load when a notebook
  contains any non-empty attachments so the user understands why pasted
  images don't appear inline. Adding inline rendering would require
  image.nvim positioning math we don't do for inline-prose content today.

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

Round-trip discipline: an unknown `cell_type` on disk is rendered as
`code` in the buffer (Mercury can't display a hypothetical `sql` /
`julia` / future cell type), but the original `cell_type` is stashed
under `cell.metadata.mercury_original_cell_type` and restored on save
— so the file is byte-equivalent to its pre-Mercury form. `raw` is
recognized natively and preserved verbatim. SPEC Invariant 60.

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
  reads the document's `width`/`height` attributes and converts to
  pixels — `px` (or unitless, which SVG defaults to px) passes through;
  `pt` converts at the SVG-default 96 DPI (1pt = 4/3 px, so 72pt → 96px);
  relative units (`%`, `em`, …) and unknown absolute units (`in`, `cm`,
  …) return nil so the `viewBox` wins. Matplotlib emits SVGs in pt, so
  the conversion is load-bearing: without it, plots rendered at ~75% of
  their intended size. SVGs that declare no resolvable intrinsic size
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

1. `image/svg+xml`
2. `image/png`
3. `image/jpeg`
4. `text/markdown`
5. `text/latex` (rasterized; renders as image)
6. `text/plain`
7. `text/html` (lowest priority — pandas etc. always emit text/plain
   alongside; html_to_text is naive and loses table structure)

This order matches Jupyter Lab's `rendermime` ordering for the formats
Mercury renders, with two documented divergences for a terminal UI:

- `text/plain` ranks ABOVE `text/html`. Most rich `_repr_html_` outputs
  (pandas DataFrame, sklearn estimator, etc.) also emit a `text/plain`
  companion; our `html_to_text` mangles tables, so we'd rather surface
  the plain repr than a flattened HTML version. Documented divergence
  from Jupyter Lab / nbviewer.
- `text/latex` ranks BELOW `text/markdown`. Latex rasterizes to an
  image (heavy, no interactivity); markdown styles inline via the
  markdown treesitter highlight groups. When both are present, the
  markdown rendering is the better terminal experience.

SVG ranks above PNG and JPEG (matplotlib commonly emits both when its
`svg` backend is enabled; SVG is sharper at any size) — this matches
Jupyter Lab. The intra-image order (`svg > png > jpeg`) is uniform
across Lab / VS Code / Mercury.

`application/vnd.jupyter.widget-view+json` is recognised explicitly and
rendered as a single `[widget unsupported]` line — never falls through to
the unknown-mime path that would otherwise emit `[empty output]` when no
`text/plain` accompanies it. See "Non-goals" for the rationale.

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
   connects to a kernel that's already running, locally or via
   SSH-tunneled ports. **Interrupt** sends a control-channel
   `interrupt_request` directly via the Jupyter messaging Session API —
   works for kernels that advertise `interrupt_mode: "message"` in their
   kernelspec (Windows kernels, container-managed kernels). For
   signal-mode kernels the request is silently dropped by the kernel
   itself; the user sees Mercury's `interrupted` notification but the
   kernel keeps running (no way to do better without owning the
   subprocess — matches JupyterLab's behavior against the same kernel).
   **Restart is NOT supported** — the bridge has no path to whatever
   supervisor owns the kernel process; restart the kernel through that
   supervisor and `:NotebookKernelSelect` to reconnect. SPEC
   Invariant 26.

Wire framing: the bridge writes one JSON message per line, but Neovim's
`channel-lines` callback may slice a single message across multiple
callbacks (large outputs cross OS pipe-buffer boundaries). The Lua client
honors that protocol: each callback's first list element extends the
previous tail, and the last element is a pending partial until the next
callback completes it. This is what keeps inline-image outputs from being
silently dropped.

Requests: `init`, `execute`, `interrupt`, `restart`, `shutdown`, `list_kernels`.

Responses: `execute_start`, `execute_input`, `output`, `execute_done`,
`interrupted`, `restarted`, `kernel_dead`, `kernel_error`, `kernels_listed`.

The `execute_input` response forwards the kernel's iopub
`execute_input` frame as soon as the kernel pulls the request off its
shell channel. Lua binds `out.exec_count` (so the live `In[N]` prompt
appears immediately, matching JupyterLab / VS Code) and `out._started_iso`
(so the ExecuteTime metadata reflects the kernel's actual start
timestamp — `header.date` — rather than Mercury's `_pump`-time
estimate). SPEC Invariant 63.

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

`IPython.display.clear_output(wait=True)` semantics: defer the clear
until the *next* output arrives — used by tqdm to atomically replace its
progress bar with the next frame. Mercury implements this as a
`_pending_clear` flag on the output state.

End-of-cell handling: if `_pending_clear` is set when `execute_done`
arrives (i.e. the cell finished without emitting further output after
the deferred-clear request), Mercury PRESERVES the prior output — it
clears `_pending_clear` so the next execute starts clean, but leaves
`out.items` untouched. This matches the documented IPython behavior
and what JupyterLab / VS Code / classic Notebook all do: tqdm's final
progress-bar frame stays visible after the loop exits. Earlier Mercury
releases incorrectly flushed the items at `execute_done`, diverging
from every other notebook UI. SPEC Invariant 64.

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
  reaps the kernel subprocess (SIGTERM, then SIGKILL if needed via
  jupyter_client's `now=True` flag — *not* a direct SIGKILL) and starts
  a fresh one on the same ports. The Lua side receives `restarted` and
  cancels both running and queued cells (the new kernel doesn't know
  about them).
- **Existing mode (`self.km is None`).** The bridge rejects restart
  with `kernel_error{kind="unsupported"}`. From a connection-file
  transport, `BlockingKernelClient` has no path to the kernel's
  upstream supervisor (Jupyter Server's `KernelManager`, systemd,
  etc.) — `kc.shutdown(restart=True)` only asks the kernel to exit and
  hopes someone else respawns it on the same ports. The 30-second
  `wait_for_ready` would time out almost every time. Mercury surfaces
  the rejection as a soft WARN (kind=unsupported is non-fatal:
  running/queue state is preserved, the connection stays up); the
  user must restart the kernel through the supervisor's own UI/API
  and then `:NotebookKernelSelect` to reconnect. A future
  Jupyter-Server HTTP/WebSocket transport would handle this via the
  REST `/api/kernels/<id>/restart` endpoint; that's out of scope.
  SPEC Invariants 26, 42.

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

### Markdown rendering

Markdown rendering inside the notebook has TWO surfaces, with different
mechanisms because they live in different host contexts (real lines vs.
virt_lines).

1. **Markdown cells (real buffer lines).** Cell bodies live in a
   `filetype = "python"` buffer, but their lines parse as markdown via
   the treesitter included-regions wiring in `markdown.lua`. Mercury's
   setup detects `render-markdown.nvim` and, on every notebook attach,
   tries the plugin's enable-for-buffer API (`buf_enable` if exposed)
   and adds `python` to the plugin's `filetypes` list if it isn't
   already there. The user-visible effect: prose in a markdown cell is
   styled (headings, lists, emphasis) the same way it would be in a
   `.md` file in their editor — render-markdown's icon substitutions,
   conceals, and virt_text decorations all attach because the cell
   body is real buffer text.

2. **`text/markdown` outputs (virt_lines, styled by `mercury.markdown_out`).**
   render-markdown.nvim's decorations only attach to real buffer lines;
   they can't be relayed across buffers as virt_lines (extmarks attach
   to a single buffer). So for `IPython.display.Markdown("# H")` —
   which lives inside an extmark under the cell anchor — Mercury parses
   the markdown source itself in `mercury.markdown_out` and emits
   virt_lines chunks pre-tagged with the standard markdown treesitter
   highlight groups (`@markup.heading.N.markdown`, `@markup.strong`,
   `@markup.emphasis`, `@markup.raw.markdown_inline`,
   `@markup.raw.markdown` for fenced blocks, `@markup.list.markdown`,
   `@markup.quote.markdown`). A modern colorscheme already styles those
   groups; `ui.lua` provides fallbacks (Title for headings, bold/italic
   attrs for emphasis, Special for inline code) so the result is
   visibly styled even on a bare terminal. The parser is regex-based
   and intentionally conservative: common formats (headings 1–6, ATX
   only; bullet/ordered lists; fenced code; **bold**; *italic*; `code`;
   `> quote`; `---` rule) render correctly. Exotic markdown
   (reference-style links, raw HTML, deeply nested emphasis) degrades
   to plain prose, not corrupted text.

Mercury does not vendor or ship `render-markdown.nvim`; it's optional.
Without it, markdown cells still parse as markdown via treesitter and
get syntax-highlighted prose; markdown OUTPUTS are unaffected (they
never depended on render-markdown).

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

### Position-bearing response filters

Mercury also wraps two proactive position-bearing response handlers:

- `textDocument/inlayHint` — pyright emits inlay hints on `# type:`
  type-comment patterns; the markdown mask can accidentally synthesize
  these from user prose like `"the type: int parameter"`. The filter
  drops any hint whose `position.line` (or `range.start.line`) falls
  inside a markdown cell.
- `textDocument/codeLens` — same filter principle for proactive code
  lenses, though pyright/ruff don't currently emit code lenses on
  comment-like content. Defensive belt against future LSP features.

Both wraps live in `M.filter_positioned_items` and use the same
`Notebook.cell_at_row` + `kind == "markdown"` predicate as the
diagnostic filter. Code-cell hints/lenses pass through unchanged.
SPEC Invariant 72.

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
top-level meta, AND each per-mime value inside `data`) so empty
defaults serialize correctly. SPEC Invariant 44.

### Canonical multilineString serialization

`nbformat.write`'s canonical form for multiline `text/*` mime values and
stream `text` is an **array of strings** — one element per source line,
with the trailing `"\n"` retained on all but optionally the last
(matches Python's `text.splitlines(keepends=True)`). Mercury holds these
as a single string in memory for ease of edit / render and converts back
to array form via `Ipynb._to_multiline_strings` on save.

Without the conversion, files Mercury writes diff loudly against files
Jupyter Lab / nbconvert / nbformat.write produce. With it, a notebook
authored in JupyterLab and saved through Mercury is byte-identical (or
within a one-blank-line tolerance, see "Trailing blank lines" above) to
the original. SPEC Invariant 58.

A single-line value stays a plain string — nbformat accepts both forms.
Non-text mimes (`application/json`, `application/vnd.*+json`,
`image/*`) pass through verbatim because their array form is real data,
not a string-array splitting artifact. SPEC Invariant 59.

### Output schema notes

A few schema details Mercury enforces that aren't obvious from the
in-memory shape:

- **`display_id` location**: under `metadata.mercury.display_id` on
  `display_data` / `execute_result` outputs. NOT as a sibling
  `transient.display_id` (which is a Jupyter messaging-protocol concept,
  not an nbformat output field). The decoder accepts both shapes for
  backwards-compat with older Mercury files. SPEC Invariant 41.
- **Stream items**: consecutive same-name stream items are merged on
  save into single entries with concatenated text, matching the
  canonical form produced by `nbformat.v4.normalize`. SPEC Invariant 36.
- **Unknown `cell_type`**: rendered as `code` in the buffer; the
  original cell_type is stashed under `cell.metadata.mercury_original_cell_type`
  and restored on save. Lossless round-trip even for cell types
  nbformat does not yet define. SPEC Invariant 60.
- **Collapsed output state**: persisted as BOTH
  `cell.metadata.collapsed = true` (classic-Notebook key) AND
  `cell.metadata.jupyter.outputs_hidden = true` (Lab/VS Code key).
  Either is honored on load. SPEC Invariant 65.
- **`nbformat` version**: only v4 is supported. v3 (worksheets schema)
  and hypothetical v5 are refused at decode with a clear migration
  hint. SPEC Invariant 57.

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
  markdown_out_spec.lua     -- text/markdown output styling: headings, lists,
                            -- bold/italic, inline code, fenced blocks, blockquotes
  audit_fixes_spec.lua      -- regression tests for SPEC Invariants 23–40
                            -- (set_kind contract, restart-pending clears in all
                            -- exit paths, expected-exit per-job-id, tag filter,
                            -- delete_cell interrupt, ExecuteTime metadata, …)
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
