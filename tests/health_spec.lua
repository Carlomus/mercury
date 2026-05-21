-- The health module's output depends on the environment, so we don't assert
-- on what it reports — only that it loads and runs cleanly without raising.
-- :checkhealth would surface any error from check() to the user anyway.

describe("health module", function()
  it("loads", function()
    local ok, mod = pcall(require, "mercury.health")
    assert.is_true(ok)
    assert.is_function(mod.check)
  end)

  it("check() runs without raising in headless mode", function()
    -- vim.health.* functions write to a results buffer in real checkhealth
    -- runs; in headless we just need them to be callable. Stub them out so
    -- check() can run anywhere.
    local saved = vim.health
    vim.health = {
      start = function() end,
      ok = function() end,
      warn = function() end,
      error = function() end,
    }
    local ok, err = pcall(require("mercury.health").check)
    vim.health = saved
    assert.is_true(ok, "check() raised: " .. tostring(err))
  end)
end)
