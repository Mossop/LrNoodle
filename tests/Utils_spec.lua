local lr = require("lr_stubs")
local Utils = require("Utils")
local Logging = require("Logging")

local logger = Logging("Test")

local function collection(name)
  return { name = name }
end

local function collectionSet(sets, collections)
  return {
    getChildCollectionSets = function()
      return sets
    end,
    getChildCollections = function()
      return collections
    end,
  }
end

local function names(collections)
  local result = {}
  for _, c in ipairs(collections) do
    table.insert(result, c.name)
  end
  return result
end

describe("Utils", function()
  before_each(function()
    lr.reset()
  end)

  describe("errors", function()
    it("distinguishes errors from results", function()
      local err = Utils.throw("boom", { "a" })

      assert.is_true(Utils.isError(err))
      assert.is_false(Utils.isSuccess(err))
      assert.are.equal("boom", Utils.error(err).code)
      assert.are.same({ "a" }, Utils.error(err).args)

      for _, value in ipairs({ "str", 1, true, { code = "boom", args = {} } }) do
        assert.is_false(Utils.isError(value))
        assert.is_true(Utils.isSuccess(value))
        assert.are.equal(value, Utils.result(value))
      end

      assert.is_true(Utils.isSuccess(nil))
    end)

    it("defaults args to empty", function()
      assert.are.same({}, Utils.throw("boom").args)
    end)

    it("throws when accessing the wrong side", function()
      assert.has_error(function()
        Utils.error("ok")
      end, "Unexpected error access on success")
      assert.has_error(function()
        Utils.result(Utils.throw("boom"))
      end, "Unexpected result access on error")
    end)

    it("describes unknown errors", function()
      assert.are.equal("Unknown Error (boom)", Utils.errorString(Utils.throw("boom", { "x" })))
    end)
  end)

  describe("safeCall", function()
    it("returns the result", function()
      local context
      local result = Utils.safeCall(logger, "action", function(ctx)
        context = ctx
        return "value"
      end)

      assert.are.equal("value", result)
      assert.is_not_nil(context)
      assert.are.equal(0, #lr.logs)
    end)

    it("converts exceptions to errors", function()
      local result = Utils.safeCall(logger, "action", function()
        error("bad", 0)
      end)

      assert.is_true(Utils.isError(result))
      assert.are.equal("exception", result.code)
      assert.are.same({ "bad" }, result.args)

      local errors = lr.logsAt("error")
      assert.are.equal(1, #errors)
      assert.are.same({ n = 3, "Test", "action", "bad" }, errors[1].args)
    end)

    it("rethrows cancellation", function()
      local ok, err = pcall(Utils.safeCall, logger, "action", function()
        lr.modules.LrErrors.throwCanceled()
      end)

      assert.is_false(ok)
      assert.are.equal(lr.CANCELED, err)
      assert.are.equal(0, #lr.logs)
    end)
  end)

  describe("json", function()
    it("encodes and decodes", function()
      assert.are.equal("[1,2]", Utils.jsonEncode(logger, { 1, 2 }))
      assert.are.same({ a = 1 }, Utils.jsonDecode(logger, '{"a":1}'))
    end)

    it("returns invalidJson errors", function()
      local encoded = Utils.jsonEncode(logger, { 1, nil, 3 })
      assert.is_true(Utils.isError(encoded))
      assert.are.equal("invalidJson", encoded.code)

      local decoded = Utils.jsonDecode(logger, "{")
      assert.is_true(Utils.isError(decoded))
      assert.are.equal("invalidJson", decoded.code)
      assert.are.equal(1, #decoded.args)
    end)
  end)

  describe("logFailures", function()
    local function failWith(err)
      lr.modules.LrFunctionContext.pcallWithContext("action", function(context)
        Utils.logFailures(context, logger, "action")
        error(err, 0)
      end)
    end

    it("logs errors", function()
      failWith("bad")

      local errors = lr.logsAt("error")
      assert.are.equal(1, #errors)
      assert.are.same({ n = 3, "Test", "action", "bad" }, errors[1].args)
    end)

    it("logs cancellation as info", function()
      failWith(lr.CANCELED)

      assert.are.equal(0, #lr.logsAt("error"))
      local infos = lr.logsAt("info")
      assert.are.equal(1, #infos)
      assert.are.same({ n = 3, "Test", "action", "User cancelled" }, infos[1].args)
    end)
  end)

  describe("runWithWriteAccess", function()
    it("requests write access when it doesn't have it", function()
      local hadAccess
      Utils.runWithWriteAccess(logger, "action", function()
        hadAccess = lr.catalog.hasWriteAccess
      end)

      assert.is_true(hadAccess)
      assert.are.same({ "action" }, lr.catalog.writeActions)
    end)

    it("logs failures inside write access", function()
      pcall(Utils.runWithWriteAccess, logger, "action", function()
        error("bad", 0)
      end)

      local errors = lr.logsAt("error")
      assert.are.equal(1, #errors)
      assert.are.same({ n = 3, "Test", "action", "bad" }, errors[1].args)
    end)

    it("calls directly when it already has write access", function()
      lr.catalog.hasWriteAccess = true

      local called = false
      Utils.runWithWriteAccess(logger, "action", function()
        called = true
      end)

      assert.is_true(called)
      assert.are.same({}, lr.catalog.writeActions)
    end)

    it("logs and raises failures when it already has write access", function()
      lr.catalog.hasWriteAccess = true

      assert.has_error(function()
        Utils.runWithWriteAccess(logger, "action", function()
          error("bad", 0)
        end)
      end, "bad")

      local errors = lr.logsAt("error")
      assert.are.equal(1, #errors)
      assert.are.same({ n = 3, "Test", "action", "bad" }, errors[1].args)
    end)
  end)

  describe("runAsync", function()
    it("runs the function", function()
      local called = false
      Utils.runAsync(logger, "action", function()
        called = true
      end)

      assert.is_true(called)
    end)

    it("logs failures", function()
      Utils.runAsync(logger, "action", function()
        error("bad", 0)
      end)

      local errors = lr.logsAt("error")
      assert.are.equal(1, #errors)
      assert.are.same({ n = 3, "Test", "action", "bad" }, errors[1].args)
    end)
  end)

  describe("collections", function()
    local service

    before_each(function()
      service = collectionSet({
        collectionSet({ collectionSet({}, { collection("deep") }) }, { collection("nested") }),
      }, { collection("default"), collection("top") })
    end)

    it("lists all collections depth first", function()
      assert.are.same({ "deep", "nested", "default", "top" }, names(Utils.listCollections(service)))
    end)
  end)

  describe("tables", function()
    it("counts every key", function()
      assert.are.equal(0, Utils.length({}))
      assert.are.equal(3, Utils.length({ 1, 2, 3 }))
      assert.are.equal(3, Utils.length({ 1, a = 2, [5] = 3 }))
    end)
  end)
end)
