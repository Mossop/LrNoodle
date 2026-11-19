local lr = require("lr_stubs")
local Logging = require("Logging")

describe("Logging", function()
  before_each(function()
    lr.reset()
  end)

  it("prefixes every level with the logger name", function()
    local logger = Logging("Test")

    for _, level in ipairs({ "trace", "debug", "info", "warn", "error" }) do
      logger[level](logger, "message", 1, true)
    end

    assert.are.equal(5, #lr.logs)
    for i, level in ipairs({ "trace", "debug", "info", "warn", "error" }) do
      assert.are.equal(level, lr.logs[i].level)
      assert.are.same({ n = 4, "Test", "message", 1, true }, lr.logs[i].args)
    end
  end)

  it("only logs warnings and errors when debug logging is off", function()
    lr.prefs.debugLogging = false
    local logger = Logging("Test")

    for _, level in ipairs({ "trace", "debug", "info", "warn", "error" }) do
      logger[level](logger, "message")
    end

    assert.are.equal(2, #lr.logs)
    assert.are.equal("warn", lr.logs[1].level)
    assert.are.equal("error", lr.logs[2].level)
  end)

  it("follows changes to the setting", function()
    local logger = Logging("Test")

    lr.prefs.debugLogging = false
    logger:debug("hidden")
    lr.prefs.debugLogging = true
    logger:debug("shown")

    assert.are.equal(1, #lr.logs)
    assert.are.same({ n = 2, "Test", "shown" }, lr.logs[1].args)
  end)

  it("keeps arguments after a nil", function()
    Logging("Test"):debug("a", nil, "b")

    assert.are.same({ n = 4, "Test", "a", nil, "b" }, lr.logs[1].args)
  end)

  it("keeps loggers independent", function()
    Logging("One"):info("a")
    Logging("Two"):info("b")

    assert.are.same({ n = 2, "One", "a" }, lr.logs[1].args)
    assert.are.same({ n = 2, "Two", "b" }, lr.logs[2].args)
  end)
end)
