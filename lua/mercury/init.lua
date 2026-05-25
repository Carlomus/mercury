local Cfg = require("mercury.config")
local Ipynb = require("mercury.ipynb")
local Notebook = require("mercury.notebook")
local UI = require("mercury.ui")
local Kernel = require("mercury.kernel")
local Output = require("mercury.output")
local Util = require("mercury.util")

local M = {}

-- foldexpr: each cell folds at its `# %%` separator line.
function M.foldexpr(lnum)
  lnum = lnum or vim.v.lnum
  local line = vim.fn.getline(lnum)
  if line:match("^#%s*%%%%") then return ">1" end
  return "1"
end

local WO_KEYS = { "foldmethod", "foldexpr", "foldtext", "conceallevel", "concealcursor" }

local function setup_folding(buf)
  -- Save and restore window-local opts so leaving the notebook in the same
  -- window doesn't leak foldexpr/conceal to the next buffer.
  --
  -- Save-once on entry; restore on leave. The order BufLeave-on-old →
  -- BufEnter-on-new in nvim means:
  --   * leaving mercury A: restore() flips wo back to user defaults and
  --     clears the saved snapshot.
  --   * entering mercury B: snapshot is nil → save the (now user-default)
  --     wo, apply mercury values.
  -- This keeps the snapshot pointing at the USER'S real defaults across
  -- arbitrary cycles between mercury buffers. We additionally re-check
  -- against the WO_KEYS' current values during save to avoid capturing
  -- mercury defaults if some weird code path enters a mercury buffer
  -- without firing BufLeave on the prior one (`:tabnew` patterns) — by
  -- detecting that the current wo already looks mercury-shaped and
  -- skipping the snapshot in that case (the prior buffer's snapshot, if
  -- inherited via window-local var inheritance, will be honored).
  local function _looks_mercury(wo)
    return wo.foldmethod == "expr"
      and tostring(wo.foldexpr or ""):find("mercury", 1, true) ~= nil
  end
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
    buffer = buf,
    callback = function()
      if vim.w._mercury_saved_wo == nil and not _looks_mercury(vim.wo) then
        local saved = {}
        for _, k in ipairs(WO_KEYS) do saved[k] = vim.wo[k] end
        vim.w._mercury_saved_wo = saved
      end
      vim.wo.foldmethod = "expr"
      vim.wo.foldexpr = "v:lua.require('mercury').foldexpr(v:lnum)"
      vim.wo.foldtext = "v:lua.require('mercury').foldtext()"
      vim.wo.conceallevel = 2
      vim.wo.concealcursor = ""
    end,
  })
  local function restore()
    local saved = vim.w._mercury_saved_wo
    if not saved then return end
    for _, k in ipairs(WO_KEYS) do vim.wo[k] = saved[k] end
    vim.w._mercury_saved_wo = nil
  end
  vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, callback = restore })
  -- BufLeave doesn't fire on :bd / :bw, so a window left holding a wiped
  -- mercury buffer would keep mercury's foldexpr / conceallevel applied to
  -- whatever buffer nvim swapped in. Restore on wipeout too. We use a
  -- different group so the per-buffer BufWipeout in attach_buffer (which
  -- detaches the notebook) can keep its callback.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      -- Restore opts in EVERY window that's currently saved — there may be
      -- more than one if the user had the notebook open in splits.
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
          local saved = pcall(vim.api.nvim_win_get_var, win, "_mercury_saved_wo")
          if saved then
            local ok, wo = pcall(vim.api.nvim_win_get_var, win, "_mercury_saved_wo")
            if ok and type(wo) == "table" then
              for _, k in ipairs(WO_KEYS) do
                pcall(function() vim.wo[win][k] = wo[k] end)
              end
              pcall(vim.api.nvim_win_del_var, win, "_mercury_saved_wo")
            end
          end
        end
      end
    end,
  })
end

function M.foldtext()
  local first = vim.fn.getline(vim.v.foldstart)
  local lines = vim.v.foldend - vim.v.foldstart + 1
  return ("%s  ── %d lines"):format(first, lines)
end

local function attach_buffer(buf, opts)
  opts = opts or {}
  local nb = Notebook.attach(buf, opts)
  local renderer = UI.new(nb)
  nb:set_renderer(renderer)
  -- Kernel selection priority on open (SPEC § "Kernel selection UI" closing
  -- paragraph):
  --   1. explicit setup{kernel={...}} — user config wins
  --   2. metadata.mercury_kernel.{python,spec_path} — mercury's override
  --   3. metadata.kernelspec.name — standard nbformat field
  local kernel_opts = vim.deepcopy(Cfg.get().kernel or {})
  local meta = nb.meta or {}
  if meta and type(meta) == "table" then
    if not kernel_opts.python and not kernel_opts.spec_path and not kernel_opts.name then
      local mk = meta.mercury_kernel
      if type(mk) == "table" then
        if mk.python then kernel_opts.python = mk.python
        elseif mk.spec_path then kernel_opts.spec_path = mk.spec_path end
      end
      if not kernel_opts.python and not kernel_opts.spec_path then
        local ks = meta.kernelspec
        if type(ks) == "table" and ks.name then kernel_opts.name = ks.name end
      end
    end
  end
  -- Coalesce render triggers to one per event-loop tick. A streaming output
  -- (tqdm, watch loops) emits one on_change per chunk; without coalescing
  -- we'd render thousands of times per second. SPEC Invariant 7.
  --
  -- A single shared coalesce wrapper drives BOTH the kernel's on_change
  -- callback AND the notebook-mutation on_change. Two separate wrappers
  -- would each maintain their own pending flag, so a kernel frame and a
  -- buffer mutation arriving in the same tick would produce two renders.
  -- Sharing the wrapper makes "one render per tick" hold across the union
  -- of all render triggers, not just within a single source.
  local on_change = Util.coalesce(function() renderer:render() end)
  local kernel = Kernel.new(nb, {
    kernel = kernel_opts,
    on_change = on_change,
  })
  nb:set_kernel(kernel)
  -- Surface the active selector (whichever of python/spec_path/name is set)
  -- as b:mercury_kernel_name so lualine / user hooks can render the current
  -- selection. SPEC § "Kernel selection UI".
  vim.b[buf].mercury_kernel_name =
    kernel_opts.python or kernel_opts.spec_path or kernel_opts.name
  nb._on_change = on_change

  nb:rescan()
  renderer:render()

  -- Pre-warm the bridge so the first Shift-Enter doesn't pay the startup cost.
  if kernel_opts and kernel_opts.eager then
    vim.schedule(function() pcall(function() kernel:_ensure_started() end) end)
  end

  -- Debounce is intentionally short. The previous 30 ms value was tuned
  -- for performance during rapid typing, but it produced visible
  -- flicker when adding lines to a cell that has image output: nvim
  -- auto-scrolls the buffer to keep the cursor visible, image.nvim's
  -- WinScrolled handler re-renders each cached image at the OLD
  -- body_end anchor (which we pinned with right_gravity=false so it
  -- doesn't track the line insertion), and Mercury's re-render that
  -- moves the anchor to the NEW body_end is held for 30 ms — the
  -- image is rendered at the wrong row for that window, visible as
  -- "img jumps up then scrolls down to original position". 3 ms is
  -- short enough to be sub-frame even at 200+ fps and still gives
  -- coalescing across single keystrokes that emit multiple
  -- TextChanged events.
  local debounced = Util.debounce(3, function()
    if not vim.api.nvim_buf_is_loaded(buf) then return end
    if nb._suppress_rescan then return end
    nb:rescan()
    renderer:render()
  end)

  -- Per-buffer augroup so :e! (which detaches + reattaches) doesn't stack
  -- duplicate TextChanged / BufWinEnter / BufWipeout handlers closing over a
  -- now-stale Notebook/Renderer. clear=true wipes the previous attach's
  -- autocmds before the fresh set lands.
  local buf_aug = vim.api.nvim_create_augroup("MercuryBuf_" .. buf,
    { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = buf_aug,
    buffer = buf,
    callback = function()
      if nb._suppress_rescan then return end
      debounced()
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = buf_aug,
    buffer = buf,
    callback = function() Notebook.detach(buf) end,
  })

  -- Re-render on BufWinEnter so images reappear when the buffer is revealed
  -- in a new window. We do NOT force-invalidate the image cache here —
  -- image.nvim's `clear()` isn't always a clean teardown of the terminal
  -- placement, so clear-then-recreate produced visible duplicates ("2 slots
  -- per image, image shows in either depending on scroll"). The cached
  -- handles survive the buffer-revisit and image.nvim re-paints them
  -- through its own redraw machinery.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = buf_aug,
    buffer = buf,
    callback = function()
      if not vim.api.nvim_buf_is_loaded(buf) then return end
      renderer:render()
      -- With window=nil mode (SPEC I18), image.nvim doesn't redraw
      -- our images on its own when the buffer becomes visible again.
      -- redraw_all re-emits each handle's kitty placement using the
      -- in-memory transmitted bytes (no disk read).
      if renderer.image and renderer.image.redraw_all then
        renderer.image:redraw_all()
      end
    end,
  })

  -- Tab / window switches: re-run the renderer AND redraw images.
  -- Same rationale as BufWinEnter — no force-invalidate, no
  -- duplicates; the cached handles still have valid geometry.
  vim.api.nvim_create_autocmd({ "TabEnter", "WinEnter" }, {
    group = buf_aug,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      if not vim.api.nvim_buf_is_loaded(buf) then return end
      local wins = vim.fn.win_findbuf(buf) or {}
      if #wins == 0 then return end
      renderer:render()
      if renderer.image and renderer.image.redraw_all then
        renderer.image:redraw_all()
      end
    end,
  })

  -- Terminal resize: the cell pixel size genuinely changed, so cached
  -- handles point at stale geometry. THIS is the one case where
  -- force-invalidating is appropriate — image.nvim has to recompute
  -- the placement at the new pixel scale. Without invalidation, cached
  -- handles render at the old size on the resized terminal.
  vim.api.nvim_create_autocmd("VimResized", {
    group = buf_aug,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      if not vim.api.nvim_buf_is_loaded(buf) then return end
      local wins = vim.fn.win_findbuf(buf) or {}
      if #wins == 0 then return end
      if renderer.image and renderer.image.force_invalidate_all then
        renderer.image:force_invalidate_all()
      end
      renderer:render()
    end,
  })

  -- WinScrolled hook: reposition every cached image to body_end's
  -- current screen row. Mercury sets `window = nil` on every image
  -- (SPEC I18), so image.nvim's own WinScrolled handler skips our
  -- images via its window-filter; we MUST do this here ourselves or
  -- images stay at their previous geometry across scrolls.
  --
  -- Synchronous, not coalesced — coalescing would reintroduce the
  -- "image lags the scroll" perception. Per-scroll cost is small:
  -- linear iteration of cached cells, a screenpos query per cell, at
  -- most one image:move() per handle. No disk read.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = buf_aug,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      if not vim.api.nvim_buf_is_loaded(buf) then return end
      local wins = vim.fn.win_findbuf(buf) or {}
      if #wins == 0 then return end
      if renderer.image and renderer.image.reposition_for_scroll then
        renderer.image:reposition_for_scroll()
      end
    end,
  })

  -- BufLeave / WinLeave / BufHidden: clear kitty graphics pixels for
  -- our images. With window = nil, image.nvim's own BufLeave/WinClosed/
  -- TabEnter cleanup (init.lua:296-339) skips our images via the
  -- `if current_image.window then` guard at line 312, so without this
  -- hook the pixels stay on the terminal after the user switches
  -- buffer/tab/window. clear_pixels_only does a shallow clear that
  -- keeps the handle object alive so we can redraw cheaply on return.
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = buf_aug,
    buffer = buf,
    callback = function()
      if renderer.image and renderer.image.clear_pixels_only then
        renderer.image:clear_pixels_only()
      end
    end,
  })

  M._setup_buffer_keymaps(buf)
  setup_folding(buf)

  -- Tell render-markdown.nvim to attach to this buffer if installed.
  -- pcall'd because the plugin's per-buffer API has shifted across
  -- versions; the shim is defensive but we don't want a probe error to
  -- block the attach. SPEC § "Markdown rendering".
  pcall(function() require("mercury.render_markdown").enable_buffer(buf) end)

  -- Let users hook into post-attach setup (statusline refresh, lazy keymaps,
  -- per-buffer LSP wiring, etc.) without monkey-patching Mercury. Fire
  -- ONCE per buffer — :e! reloads detach + reattach the notebook many
  -- times in a session, but post-attach hooks (LSP wiring, keymap install,
  -- statusline) are typically idempotent-but-expensive and the user
  -- expects "this happens when the notebook opens", not "every time it
  -- reloads". Guard via b:mercury_user_attached_seen.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if vim.b[buf].mercury_user_attached_seen then return end
    vim.b[buf].mercury_user_attached_seen = true
    pcall(vim.api.nvim_exec_autocmds, "User",
      { pattern = "MercuryAttached", modeline = false,
        data = { buf = buf } })
  end)

  return nb
end

M._attach_buffer = attach_buffer

local function blank_notebook()
  return {
    meta = {
      kernelspec = { name = "python3", display_name = "Python 3", language = "python" },
      language_info = { name = "python" },
    },
    nbformat = 4,
    nbformat_minor = 5,
    cells = {
      { id = Util.short_id(), kind = "code", source = {}, outputs = {}, metadata = {} },
    },
  }
end

local function decode_ipynb_or_blank(path)
  local data = Util.read_file(path)
  if not data or data:gsub("%s", "") == "" then
    return blank_notebook(), true   -- fresh: file missing or empty
  end
  local nb = Ipynb.decode(data)
  if not nb then
    -- Parse failed: caller shows raw bytes readonly so we don't clobber a
    -- broken-but-recoverable file. SPEC Invariant H13.
    return nil, false
  end
  if not nb.cells or #nb.cells == 0 then
    -- File parsed, but the cell list is empty (e.g., a "Clear All" tool wrote
    -- `{"cells":[], "metadata":{...}}`). Preserve the original metadata
    -- (kernelspec, language_info, etc.) and add a single empty placeholder
    -- cell so the user has somewhere to edit. Crucially: NOT marked fresh,
    -- so the buffer is unmodified — a casual :w with no edits doesn't
    -- overwrite the original file. The placeholder is purely visual until
    -- the user actually types something.
    nb.cells = {
      { id = Util.short_id(), kind = "code", source = {},
        outputs = {}, metadata = {} },
    }
    nb.nbformat = nb.nbformat or 4
    nb.nbformat_minor = nb.nbformat_minor or 5
    return nb, false
  end
  return nb, false
end

local function load_ipynb(buf, path)
  -- Detach any prior notebook on this buf so :e! doesn't leak the old
  -- kernel + renderer (and the per-buf augroup gets cleared cleanly by the
  -- next attach_buffer).
  if Notebook.get(buf) then Notebook.detach(buf) end
  local doc, fresh = decode_ipynb_or_blank(path)
  if not doc then
    -- Parsing failed: show the raw bytes readonly so the user can diagnose
    -- without us clobbering their file.
    local raw = Util.read_file(path) or ""
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(raw, "\n", { plain = true }))
    vim.api.nvim_buf_set_name(buf, path)
    vim.bo[buf].modified = false
    vim.bo[buf].modifiable = false
    vim.notify("[mercury] could not parse " .. path
      .. " (showing raw bytes readonly; fix or remove the file)",
      vim.log.levels.ERROR)
    return false
  end
  local lines = Ipynb.to_buffer_lines(doc)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, path)

  -- Record the on-disk mtime AND the load path so :w can detect external
  -- modifications and refuse to clobber them without an explicit :w!. The
  -- guard is path-scoped: :saveas to a different file is writing a copy
  -- and must not be refused on the basis of the original file's mtime
  -- history. SPEC Invariant 21. mtime is stored as {sec, nsec} so two
  -- external writes within the same second on a fast filesystem don't
  -- masquerade as "no change" — SPEC Invariant 28.
  local stat = vim.loop.fs_stat(path)
  if stat then
    vim.b[buf].mercury_file_mtime = {
      sec = stat.mtime.sec,
      nsec = stat.mtime.nsec or 0,
    }
  end
  vim.b[buf].mercury_loaded_path = path

  -- ATTACH FIRST, FILETYPE SECOND. The previous order was:
  --   1. vim.bo[buf].filetype = "python"
  --   2. attach_buffer(...)
  -- Setting filetype synchronously fires `FileType` and Neovim's
  -- auto-attach handler for `python` then fires `LspAttach`. Mercury's
  -- LspAttach autocmd (`lsp.lua:LspAttach`) calls
  -- `reset_server_view(buf)` — which short-circuits when
  -- `Notebook.get(buf)` is nil. Under the old order, attach_buffer
  -- (which calls Notebook.attach) had not yet run, so the server kept
  -- its raw (unmasked, markdown-as-syntax-error) view of the document
  -- and the diagnostic mask silently leaked. SPEC Invariant 6.
  --
  -- By calling attach_buffer before assigning filetype, the notebook is
  -- registered before any LspAttach can fire; the reset path runs
  -- cleanly and the server sees the masked document from the very first
  -- didOpen.
  local nb = attach_buffer(buf, {
    path = path,
    meta = doc.meta,
    nbformat = doc.nbformat,
    nbformat_minor = doc.nbformat_minor,
  })
  vim.bo[buf].filetype = "python"
  vim.bo[buf].modified = fresh   -- mark dirty so :w persists the new file

  -- :e! reload path: any LSP clients already attached to this buffer from
  -- the previous load won't fire LspAttach again on the new content. Their
  -- patched `notify` will mask the next `didChange`, but the document they
  -- last saw is the previous file's text. Force a fresh `reset_server_view`
  -- so the server picks up the new masked document immediately.
  local ok_lsp, Lsp = pcall(require, "mercury.lsp")
  if ok_lsp then
    local clients = (vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = buf }))
      or (vim.lsp.buf_get_clients and vim.lsp.buf_get_clients(buf)) or {}
    if next(clients) and Lsp.reset_server_view then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(Lsp.reset_server_view, buf)
        end
      end)
    end
  end
  -- Seed outputs, cell metadata, and attachments from the loaded ipynb.
  -- Also seed an output record when exec_count is set but outputs are empty
  -- (Jupyter Lab's "Clear All Outputs" leaves execution_count intact). Without
  -- this, the encoder would write "execution_count": null on save and the
  -- next reload would show the cell as never-run — silent data loss.
  local attachment_count = 0
  for _, c in ipairs(doc.cells) do
    nb.cell_metadata[c.id] = c.metadata
    if c.attachments and next(c.attachments) ~= nil then
      nb.cell_attachments[c.id] = c.attachments
      attachment_count = attachment_count + 1
    end
    if (c.outputs and #c.outputs > 0) or c.exec_count then
      local out = nb:ensure_output(c.id)
      out.items = c.outputs or {}
      out.exec_count = c.exec_count
      out.status = "idle"
      -- Restore collapsed state from the canonical JupyterLab metadata
      -- locations. Prefer `metadata.jupyter.outputs_hidden` (modern); fall
      -- back to `metadata.collapsed` (classic). A truthy value in either
      -- collapses the output on first render.
      local meta = c.metadata or {}
      local hidden = false
      if type(meta.jupyter) == "table" and meta.jupyter.outputs_hidden then
        hidden = true
      elseif meta.collapsed then
        hidden = true
      end
      if hidden then out._collapsed = true end
    end
  end
  -- Markdown-cell attachments are preserved across save/load but not
  -- rendered inline (SPEC Non-goals + Invariant 35). Notify once so the
  -- user understands why pasted images aren't appearing. Only emitted for
  -- non-empty attachment tables — the empty-dict round-trip case mustn't
  -- generate a notify.
  if attachment_count > 0 then
    Util.notify(
      ("%d cell%s with markdown attachments preserved verbatim; "
       .. "`attachment:` references won't render inline (use external viewer)")
      :format(attachment_count, attachment_count == 1 and "" or "s"),
      vim.log.levels.INFO)
  end
  if nb._renderer then nb._renderer:render() end

  return true
end

-- Count cells whose execution is in flight (running or queued). Save treats
-- these as "not yet executed" in the JSON — their in-memory partial state is
-- preserved, but it doesn't land on disk until the user saves again after
-- the cell finishes. This is what keeps :w / :wq non-blocking.
local function in_flight_count(nb)
  if not nb.kernel then return 0 end
  local n = 0
  if nb.kernel.running then n = n + 1 end
  n = n + #(nb.kernel.queue or {})
  return n
end

local function save_ipynb(buf, path, force)
  local nb = Notebook.get(buf)
  if not nb then return false, "notebook not attached" end

  -- External-modification guard. Only fires when the save target matches
  -- the originally-loaded path — :saveas to a new file is a copy and must
  -- not be refused based on the original file's mtime history. SPEC 21.
  -- Compares {sec, nsec} so back-to-back writes within the same second
  -- on a fast filesystem still trip the guard. SPEC Invariant 28.
  --
  -- Path comparison uses realpath so symlinks resolve. On macOS the same
  -- temp dir is reachable through `/var/folders/...` and
  -- `/private/var/folders/...`; without realpath, an `:e` via one form
  -- followed by `:w` of the other would silently skip the guard because
  -- the string forms differ. Same problem for any user-symlinked project
  -- (e.g. ~/work → /Users/carlo/Work).
  local loaded = vim.b[buf].mercury_loaded_path
  -- realpath returns nil when a path component is unreachable (broken
  -- symlink, fs unmounted, permission denied). If EITHER side fails to
  -- resolve we can't prove the paths refer to the same file, but we also
  -- can't prove they're different. The previous code silently treated
  -- nil-fallback as "different files" and skipped the mtime guard — that
  -- failure mode would let an externally-edited file get clobbered without
  -- warning. Resolve outcomes are tracked separately so the same-file
  -- branch only fires on a CONFIRMED match.
  local r_loaded = loaded and vim.loop.fs_realpath(loaded) or nil
  local r_path = vim.loop.fs_realpath(path)
  local resolved_match = r_loaded and r_path and r_loaded == r_path
  -- Suspected-same: we can't resolve symlinks but the literal paths agree.
  -- Common case is a brand-new file that doesn't exist yet (fs_realpath
  -- returns nil on a non-existent target); fall through to the mtime guard
  -- which itself bails when no `stat` is available.
  local literal_match = loaded and loaded == path
  -- Realpath inconclusive (one side resolved, the other didn't) — engage
  -- the guard conservatively. The user can :w! to override; that's strictly
  -- safer than the silent-overwrite path the previous code allowed.
  local inconclusive = loaded
    and (loaded ~= path)
    and ((r_loaded == nil) ~= (r_path == nil))
  local saving_same_file = resolved_match or literal_match or inconclusive
  if saving_same_file then
    local stat = vim.loop.fs_stat(path)
    local stored = vim.b[buf].mercury_file_mtime
    if not force and stat and stored then
      -- Accept both the new {sec, nsec} table form and the legacy bare-sec
      -- number form (older buffers loaded before this code path was
      -- updated would otherwise hard-fail on the first save).
      local stored_sec = (type(stored) == "table") and stored.sec or stored
      local stored_nsec = (type(stored) == "table") and (stored.nsec or 0) or 0
      local disk_sec = stat.mtime.sec
      local disk_nsec = stat.mtime.nsec or 0
      local changed = (disk_sec > stored_sec)
        or (disk_sec == stored_sec and disk_nsec > stored_nsec)
      if changed then
        return false, "file changed on disk since load (use :w! to overwrite)"
      end
    end
  end

  -- Snapshot in-flight count BEFORE serializing, so the notify below reflects
  -- the state we actually skipped. to_ipynb_struct reads kernel.running /
  -- kernel.queue to know which cells to write as "not yet executed".
  local skipped = in_flight_count(nb)
  -- Wrap serialization in pcall: a Lua error inside to_ipynb_struct or
  -- encode would otherwise propagate out of BufWriteCmd as a raw stack
  -- trace, leaving the buffer modified, the file untouched, and the user
  -- with no actionable message. Returning (false, err) keeps the failure
  -- mode symmetric with atomic_write_file's error contract, and the user
  -- can decide whether to retry, debug, or save elsewhere. Critically:
  -- atomic_write_file is NEVER reached on a serialize failure, so the
  -- on-disk file remains the previous good content.
  local ok_struct, struct = pcall(function() return nb:to_ipynb_struct() end)
  if not ok_struct then
    return false, "serialize failed: " .. tostring(struct)
  end
  local ok_encode, json = pcall(Ipynb.encode, struct)
  if not ok_encode then
    return false, "encode failed: " .. tostring(json)
  end
  if type(json) ~= "string" or #json == 0 then
    return false, "encode produced empty output"
  end
  -- Atomic save: write to a sibling tempfile, fsync, rename(2). Crash /
  -- power loss during :w then leaves either the old or new file on disk,
  -- never a partial one. SPEC Invariant 22.
  local ok, err = Util.atomic_write_file(path, json)
  if not ok then return false, err end
  vim.bo[buf].modified = false
  if skipped > 0 then
    vim.notify(
      ("[mercury] saved; %d cell%s still running/queued were written without output "
       .. "(save again after they finish to capture)"):format(
        skipped, skipped == 1 and "" or "s"),
      vim.log.levels.INFO)
  end
  local new_stat = vim.loop.fs_stat(path)
  if new_stat then
    vim.b[buf].mercury_file_mtime = {
      sec = new_stat.mtime.sec,
      nsec = new_stat.mtime.nsec or 0,
    }
  else
    vim.b[buf].mercury_file_mtime = { sec = os.time(), nsec = 0 }
  end
  -- :saveas redirected this buffer to a new path. Update the load path so
  -- subsequent saves are guarded against modifications of THIS file, not
  -- the original. Use realpath equivalence so macOS /var vs /private/var
  -- doesn't false-negative the comparison.
  if loaded ~= path then
    local r_loaded = loaded and (vim.loop.fs_realpath(loaded) or loaded)
    local r_path = vim.loop.fs_realpath(path) or path
    if r_loaded ~= r_path then
      vim.b[buf].mercury_loaded_path = path
    end
  end
  return true
end

-- Treesitter predicate `mercury_in_markdown_cell?`: filters `(comment)`
-- captures (from queries/python/injections.scm) down to ones inside a
-- markdown cell, so markdown-prefixed comments get highlighted as markdown.
local function register_ts_predicate()
  local add = vim.treesitter
    and vim.treesitter.query
    and vim.treesitter.query.add_predicate
  if not add then return end
  local handler = function(match, _, source, predicate)
    local buf = (type(source) == "number") and source or vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    if not nb or not nb.cells or #nb.cells == 0 then return false end
    local cap = match[predicate[2]]
    local node = (type(cap) == "table") and cap[1] or cap
    if not node then return false end
    local start_row = node:start()
    for _, c in ipairs(nb.cells) do
      local first = (c.header_row >= 0) and c.header_row or c.body_start
      if start_row >= first and start_row <= c.body_end then
        return c.kind == "markdown"
      end
    end
    return false
  end
  -- Neovim ≥0.10 accepts an opts table; older builds want a boolean.
  if not pcall(add, "mercury_in_markdown_cell?", handler,
               { force = true, all = false }) then
    pcall(add, "mercury_in_markdown_cell?", handler, true)
  end
end

function M.setup(opts)
  Cfg.setup(opts)
  math.randomseed((os.time() * 1000 + (vim.loop.hrtime() % 1000000)) % 2147483647)
  UI.setup_highlights()
  require("mercury.lsp").setup()
  -- Decorative: hand render-markdown.nvim our filetype so it styles
  -- markdown cells the way users expect from a real notebook UI. Silent
  -- no-op when the plugin isn't installed. SPEC § "Markdown rendering".
  pcall(function() require("mercury.render_markdown").ensure_python_filetype() end)

  -- Sweep stale entries from the image / latex caches (>30 days). Both are
  -- keyed by content hash, so eviction never loses data — a future render
  -- recreates the file from source bytes. Scheduled to keep startup fast.
  vim.schedule(function()
    local root = vim.fn.stdpath("cache")
    Util.gc_cache_dir(root .. "/mercury_images")
    Util.gc_cache_dir(root .. "/mercury_latex")
  end)
  register_ts_predicate()

  local aug = vim.api.nvim_create_augroup("Mercury", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = aug,
    callback = UI.setup_highlights,
  })

  vim.api.nvim_create_autocmd({ "BufReadCmd", "BufNewFile" }, {
    group = aug,
    pattern = "*.ipynb",
    callback = function(args)
      local path = vim.fn.fnamemodify(args.match or vim.api.nvim_buf_get_name(args.buf), ":p")
      load_ipynb(args.buf, path)
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = aug,
    pattern = "*.ipynb",
    callback = function(args)
      local path = vim.fn.fnamemodify(args.match or vim.api.nvim_buf_get_name(args.buf), ":p")
      -- v:cmdbang is set by vim to 1 when the matching write was :w! — used
      -- here to bypass the mtime guard the same way it bypasses vim's own
      -- "file changed on disk" refusal.
      local force = vim.v.cmdbang == 1
      local ok, err = save_ipynb(args.buf, path, force)
      if not ok then
        vim.notify("[mercury] save failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end,
  })

  M._register_commands()
end

-- ---------- commands ----------

local function with_nb(fn)
  return function()
    local nb = Notebook.get(vim.api.nvim_get_current_buf())
    if not nb then
      vim.notify("[mercury] no notebook on this buffer", vim.log.levels.WARN)
      return
    end
    fn(nb)
  end
end

function M._register_commands()
  local cmd = vim.api.nvim_create_user_command

  cmd("NotebookExec", with_nb(function(nb)
    local cell = nb:cell_at_row()
    if not cell then return end
    -- Kernel execution only applies to code cells. Markdown / raw cells
    -- treat Shift-Enter as "advance to next cell (or create one of the
    -- same kind below)" — matching JupyterLab's behavior on markdown
    -- cells (render-and-move). Wrap the kernel call so any internal
    -- error path can't block the advance; the user expects the cursor
    -- to move regardless.
    if cell.kind == "code" then
      pcall(function() nb.kernel:execute(cell) end)
    end
    local idx = nb:cell_index(cell.id)
    local nxt = nb.cells[idx + 1]
    if not nxt then
      -- At the last cell. Create a new cell of the SAME kind as the
      -- one we're advancing from. JupyterLab does this for markdown
      -- (Shift-Enter on the last markdown cell adds a markdown cell);
      -- for code cells the default is also code which is the existing
      -- behavior.
      nxt = nb:new_cell_below(cell, cell.kind)
    end
    if nxt then
      pcall(vim.api.nvim_win_set_cursor, 0, { nxt.body_start + 1, 0 })
    end
  end), {})

  cmd("NotebookExecAlone", with_nb(function(nb)
    local cell = nb:cell_at_row(); if cell then nb.kernel:execute(cell) end
  end), {})

  cmd("NotebookExecAll", with_nb(function(nb)
    for _, c in ipairs(nb.cells) do
      if c.kind == "code" then nb.kernel:execute(c) end
    end
  end), {})

  cmd("NotebookExecAbove", with_nb(function(nb)
    local cell = nb:cell_at_row(); if not cell then return end
    for _, c in ipairs(nb.cells) do
      if c.kind == "code" then nb.kernel:execute(c) end
      if c.id == cell.id then break end
    end
  end), {})

  cmd("NotebookExecBelow", with_nb(function(nb)
    local cell = nb:cell_at_row(); if not cell then return end
    local started = false
    for _, c in ipairs(nb.cells) do
      if c.id == cell.id then started = true end
      if started and c.kind == "code" then nb.kernel:execute(c) end
    end
  end), {})

  cmd("NotebookCellNewBelow",   with_nb(function(nb) nb:new_cell_below() end),  {})
  cmd("NotebookCellNewAbove",   with_nb(function(nb) nb:new_cell_above() end),  {})
  cmd("NotebookCellNext",       with_nb(function(nb) nb:goto_next_cell() end),  {})
  cmd("NotebookCellPrev",       with_nb(function(nb) nb:goto_prev_cell() end),  {})
  cmd("NotebookCellDelete",     with_nb(function(nb) nb:delete_cell() end),     {})
  cmd("NotebookCellMergeBelow", with_nb(function(nb) nb:merge_below() end),     {})
  cmd("NotebookCellMoveUp",     with_nb(function(nb) nb:move_up() end),         {})
  cmd("NotebookCellMoveDown",   with_nb(function(nb) nb:move_down() end),       {})
  cmd("NotebookCellToCode",     with_nb(function(nb) nb:set_kind(nil, "code") end), {})
  cmd("NotebookCellToMarkdown", with_nb(function(nb) nb:set_kind(nil, "markdown") end), {})
  cmd("NotebookCellSelect",     with_nb(function(nb) nb:select_cell() end),     {})
  cmd("NotebookCellCopy",       with_nb(function(nb) nb:copy_cell() end),       {})
  cmd("NotebookCellPaste",      with_nb(function(nb) nb:paste_cell() end),      {})
  cmd("NotebookCellDuplicate",  with_nb(function(nb) nb:duplicate_cell() end),  {})

  cmd("NotebookOutputClear", with_nb(function(nb)
    local cell = nb:cell_at_row(); if cell then nb:clear_output(cell.id); nb._on_change() end
  end), {})

  cmd("NotebookOutputClearAll", with_nb(function(nb)
    nb:clear_all_outputs(); nb._on_change()
  end), {})

  cmd("NotebookOutputToggle", with_nb(function(nb)
    local cell = nb:cell_at_row(); if not cell then return end
    local out = nb.outputs[cell.id]; if not out then return end
    out._collapsed = not out._collapsed
    nb._on_change()
  end), {})

  cmd("NotebookOutputCopy", with_nb(function(nb)
    local cell = nb:cell_at_row(); if not cell then return end
    local out = nb.outputs[cell.id]; if not out then return end
    local lines = Output.to_plain_text(out)
    vim.fn.setreg("+", table.concat(lines, "\n"))
    vim.fn.setreg('"', table.concat(lines, "\n"))
    Util.notify(("copied %d lines"):format(#lines))
  end), {})

  cmd("NotebookOutputView", with_nb(function(nb)
    local cell = nb:cell_at_row(); if not cell then return end
    local out = nb.outputs[cell.id]
    local lines = out and Output.to_plain_text(out) or { "(no output)" }
    vim.cmd("botright new")
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].modifiable = false
    vim.bo[b].filetype = "mercury_output"
  end), {})

  cmd("NotebookKernelSelect", with_nb(function(nb)
    nb.kernel:list_kernels(function(kernels)
      vim.schedule(function()
        local Discover = require("mercury.discover")
        local start_dir = nb._path
          and vim.fn.fnamemodify(nb._path, ":h") or vim.fn.getcwd()
        local pythons = Discover.pythons({ start_dir = start_dir })

        -- Compose a unified picker from three sources. Order is by signal
        -- strength: registered kernelspecs first (the user installed them
        -- intentionally), discovered venvs next (likely-correct guess),
        -- then a manual-entry escape hatch.
        local options = {}
        for _, k in ipairs(kernels or {}) do
          options[#options + 1] = {
            kind = "spec", name = k.name,
            display_name = k.display_name, language = k.language,
          }
        end
        for _, p in ipairs(pythons) do
          options[#options + 1] = {
            kind = "python", python = p.path,
            display_name = Discover.short_label(p.path),
            source = p.source,
          }
        end
        options[#options + 1] = { kind = "browse",
          display_name = "Enter python or kernelspec path…" }

        vim.ui.select(options, {
          prompt = "Select kernel",
          format_item = function(o)
            if o.kind == "spec" then
              return ("[kernelspec] %s (%s)"):format(o.display_name, o.name)
            elseif o.kind == "python" then
              return ("[python] %s — %s"):format(o.display_name, o.source)
            else
              return o.display_name
            end
          end,
        }, function(choice)
          if not choice then return end
          if choice.kind == "browse" then
            vim.ui.input({ prompt = "Path (python exe or kernelspec dir): ",
                           completion = "file" }, function(path)
              if not path or path == "" then return end
              path = vim.fn.expand(path)
              if vim.fn.isdirectory(path) == 1 then
                nb.kernel:select_kernel({ spec_path = path })
                Util.notify("kernel set: spec_path=" .. path)
              else
                nb.kernel:select_kernel({ python = path })
                Util.notify("kernel set: python=" .. path)
              end
            end)
            return
          end
          nb.kernel:select_kernel(choice)
          Util.notify("kernel set: " ..
            (choice.name or choice.python or "?"))
        end)
      end)
    end)
  end), {})

  cmd("NotebookKernelInfo", with_nb(function(nb)
    -- Surface the kernel currently bound to this buffer as a single notify.
    -- Useful when the user wants confirmation of "which interpreter am I
    -- actually running on" without inspecting the lualine glyph or the
    -- notebook's metadata directly. The lines come from Kernel:info() so
    -- the message stays in sync with what other code paths see as the
    -- active selector.
    local info = nb.kernel:info()
    vim.notify("[mercury] kernel\n  " .. table.concat(info, "\n  "),
      vim.log.levels.INFO)
  end), {})

  cmd("NotebookKernelRestart",      with_nb(function(nb) nb.kernel:restart() end), {})
  cmd("NotebookKernelRestartClear", with_nb(function(nb) nb.kernel:restart({ clear = true }) end), {})
  cmd("NotebookKernelInterrupt",    with_nb(function(nb) nb.kernel:interrupt() end), {})
  cmd("NotebookKernelStop",         with_nb(function(nb) nb.kernel:stop() end), {})

  -- Diagnose the kitty unicode-placeholder image rendering path
  -- (SPEC I18 primary). Prints a human-readable report of:
  --   - whether snacks is loaded.
  --   - whether snacks.image is detected and set up.
  --   - termguicolors state (required for placeholder mode).
  --   - what terminal snacks's env detection reports.
  --   - whether placeholders are available.
  --   - per-image cache contents (how many transmitted, which paths).
  -- Useful when "images don't appear" — tells you exactly which
  -- precondition is failing.
  cmd("NotebookDebugImages", function()
    local ok, P = pcall(require, "mercury.placeholder_image")
    if not ok then
      vim.notify("[mercury] placeholder_image module failed to load: "
        .. tostring(P), vim.log.levels.ERROR)
      return
    end
    local report = P.diagnose()
    local lines = {
      "[mercury] image rendering diagnostics",
      ("  snacks_loaded        : %s"):format(tostring(report.snacks_loaded)),
      ("  snacks_image_module  : %s"):format(tostring(report.snacks_image_module)),
      ("  snacks_setup_called  : %s"):format(tostring(report.setup_called)),
      ("  termguicolors        : %s"):format(tostring(report.termguicolors)),
      ("  env_name             : %s"):format(tostring(report.env_name)),
      ("  env_supported        : %s"):format(tostring(report.env_supported)),
      ("  env_placeholders     : %s"):format(tostring(report.env_placeholders)),
      ("  env_remote           : %s"):format(tostring(report.env_remote)),
      ("  available()          : %s"):format(tostring(report.available)),
      ("  cached_images        : %d"):format(#report.cache),
    }
    for _, entry in ipairs(report.cache) do
      lines[#lines + 1] = ("    id=%s  %dx%d  %s"):format(
        tostring(entry.id), entry.width_cells, entry.height_cells,
        entry.path)
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, {})
end

function M._setup_buffer_keymaps(buf)
  if not Cfg.get().keymaps.enabled then return end
  require("mercury.keymaps").apply(buf)
end

return M
