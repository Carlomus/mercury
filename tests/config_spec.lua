-- Config validation catches the common copy-paste mistakes before they
-- propagate into runtime crashes (string where a number is expected, etc.).
-- Validation is non-fatal: setup() still completes with the user's opts
-- merged onto defaults, but it surfaces errors via vim.notify(WARN).

local Cfg = require("mercury.config")

describe("config validation", function()
  it("accepts a valid config without complaints", function()
    local errs = Cfg._validate({
      kernel = { mode = "local", name = "python3" },
      output = { image_max_height_rows = 30, cell_width_px = 8 },
      lsp = { mask_markdown_cells = true },
    })
    assert.equals(0, #errs)
  end)

  it("rejects a non-table opts argument", function()
    local errs = Cfg._validate("not a table")
    assert.equals(1, #errs)
    assert.matches("expected table", errs[1])
  end)

  it("rejects wrong-typed scalar (string where number expected)", function()
    local errs = Cfg._validate({
      output = { image_max_height_rows = "thirty" },
    })
    assert.equals(1, #errs)
    assert.matches("image_max_height_rows: expected number", errs[1])
  end)

  it("rejects wrong-typed scalar (string where boolean expected)", function()
    local errs = Cfg._validate({
      lsp = { mask_markdown_cells = "yes" },
    })
    assert.matches("mask_markdown_cells: expected boolean", errs[1])
  end)

  it("rejects a value below the min", function()
    local errs = Cfg._validate({
      output = { image_max_height_rows = 0 },
    })
    assert.matches("< min", errs[1])
  end)

  it("rejects enum violations", function()
    local errs = Cfg._validate({
      kernel = { mode = "remote" },  -- not in {local, existing}
    })
    assert.matches("not in", errs[1])
  end)

  it("rejects a string at the kernel-level when a table is expected", function()
    -- Common user mistake: kernel = "python3" instead of kernel = { name = "python3" }
    local errs = Cfg._validate({ kernel = "python3" })
    assert.matches("kernel: expected table", errs[1])
  end)

  it("accepts arbitrary highlight keys (free-form group names)", function()
    -- highlights is documented as a free-form table; we don't enumerate
    -- each color key in the schema.
    local errs = Cfg._validate({
      highlights = { custom_thing = "#abc123", another = "#fedcba" },
    })
    assert.equals(0, #errs)
  end)

  it("setup still applies defaults when validation reports errors", function()
    -- We capture the warning to verify it fired but don't fail setup.
    local warnings = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
      if type(msg) == "string" and msg:find("config invalid") then
        warnings[#warnings + 1] = { msg = msg, level = level }
      end
    end

    local values = Cfg.setup({ output = { image_max_height_rows = "bad" } })
    vim.wait(20, function() return #warnings >= 1 end)
    vim.notify = orig

    -- setup didn't crash and returned a values table.
    assert.is_table(values)
    -- The bad value DID land in values (deep_extend doesn't validate),
    -- but the user got a warning explaining why their config is wrong.
    assert.equals(1, #warnings)
    assert.equals(vim.log.levels.WARN, warnings[1].level)
  end)
end)
