-- Verifies that queued cells display their 1-based position in the kernel
-- queue (e.g. `⏸ queued #2`) so users with many cells fired off can see how
-- far they are from running. SPEC Invariant 73.

local Output = require("mercury.output")

describe("queue position indicator", function()
  it("renders ⏸ queued #N when opts.queue_pos is set", function()
    local virt = Output.build_virt_lines({
      status = "queued", items = {},
    }, { queue_pos = 3 })
    local rendered = virt[1][1][1]
    assert.matches("queued", rendered)
    assert.matches("#3", rendered)
  end)

  it("renders bare 'queued' when no position is supplied", function()
    -- Tests / non-UI callers can build virt_lines without computing a
    -- position. Pin the pre-queue-position behavior so old callers don't
    -- start crashing.
    local virt = Output.build_virt_lines({
      status = "queued", items = {},
    }, {})
    local rendered = virt[1][1][1]
    assert.matches("queued", rendered)
    assert.is_nil(rendered:match("#"),
      "no '#' should appear when queue_pos is unset")
  end)

  it("renders bare 'queued' when queue_pos is 0 (defensive)", function()
    -- 0 is a sentinel value that means "I looked but didn't find this cell
    -- in the queue" — don't render `#0`, which would be misleading.
    local virt = Output.build_virt_lines({
      status = "queued", items = {},
    }, { queue_pos = 0 })
    local rendered = virt[1][1][1]
    assert.is_nil(rendered:match("#"),
      "queue_pos=0 must not render #0")
  end)

  it("to_plain_text mirrors the queue-position indicator", function()
    -- SPEC Invariant 54: to_plain_text must reflect what build_virt_lines
    -- shows on screen.
    local lines = Output.to_plain_text({
      status = "queued", items = {},
    }, { queue_pos = 5 })
    assert.matches("queued #5", lines[1])
  end)

  it("to_plain_text shows bare 'queued' when no position supplied", function()
    local lines = Output.to_plain_text({
      status = "queued", items = {},
    })
    assert.matches("queued", lines[1])
    assert.is_nil(lines[1]:match("#"))
  end)

  -- End-to-end: ui.render_cell_output threads kernel.queue position
  -- through to build_virt_segments (the multi-extmark pipeline's
  -- segment builder). We intercept that and verify each queued cell
  -- sees its 1-based slot.
  it("ui.render passes the cell's queue index through to build_virt_segments", function()
    package.loaded["image"] = {
      is_enabled = function() return false end,
      from_file = function() return {} end,
    }
    local Notebook = require("mercury.notebook")
    local UI = require("mercury.ui")
    require("mercury.config").setup()

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# %% id=qfirst11", "print('a')",
      "# %% id=qsecond1", "print('b')",
      "# %% id=qthird11", "print('c')",
    })
    vim.api.nvim_set_current_buf(buf)
    local nb = Notebook.attach(buf); nb:rescan()
    nb:set_renderer(UI.new(nb))

    nb:set_kernel({
      running = { cell_id = "qfirst11" },
      queue = {
        { cell_id = "qsecond1", code = "" },
        { cell_id = "qthird11", code = "" },
      },
    })
    nb:ensure_output("qsecond1").status = "queued"
    nb:ensure_output("qthird11").status = "queued"

    local seen_opts_by_cell = {}
    local orig = Output.build_virt_segments
    Output.build_virt_segments = function(out, opts)
      for cid, o in pairs(nb.outputs) do
        if o == out then
          seen_opts_by_cell[cid] = opts; break
        end
      end
      return orig(out, opts)
    end
    nb._renderer:render()
    Output.build_virt_segments = orig

    assert.equals(1, seen_opts_by_cell["qsecond1"].queue_pos)
    assert.equals(2, seen_opts_by_cell["qthird11"].queue_pos)

    Notebook.detach(buf)
    package.loaded["image"] = nil
  end)
end)
