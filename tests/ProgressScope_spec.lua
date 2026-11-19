local lr = require("lr_stubs")
local ProgressScope = require("ProgressScope")

-- The positions reported to the most recently created Lightroom progress scope.
local function positions()
  return lr.progressScopes[#lr.progressScopes].positions
end

local function assertPositions(expected)
  local actual = positions()
  assert.are.equal(#expected, #actual, "Expected " .. #expected .. " positions but saw " .. #actual)
  for i = 1, #expected do
    assert.is_true(math.abs(expected[i] - actual[i]) < 1e-9, "Position " .. i .. " was " .. actual[i])
  end
end

-- The messages of everything ProgressScope logged as a warning.
local function warnings()
  local result = {}
  for _, entry in ipairs(lr.logsAt("warn")) do
    table.insert(result, entry.args[2])
  end
  return result
end

describe("ProgressScope", function()
  before_each(function()
    lr.reset()
  end)

  describe("new", function()
    it("creates a cancelable Lightroom progress scope", function()
      local functionContext
      ProgressScope.new("Title", 1, function(_, context)
        functionContext = context
      end)

      local scope = lr.progressScopes[1]
      assert.are.equal("Title", scope.params.title)
      assert.are.equal(functionContext, scope.params.functionContext)
      assert.is_true(scope.cancelable)
    end)

    it("returns the result of the function", function()
      assert.are.equal(
        "result",
        ProgressScope.new("Title", 1, function()
          return "result"
        end)
      )
    end)

    it("rethrows errors", function()
      assert.has_error(function()
        ProgressScope.new("Title", 1, function()
          error("bad", 0)
        end)
      end)
    end)
  end)

  describe("forExportContext", function()
    it("uses the export context's progress scope", function()
      local exportContext = {
        configureProgress = function(_, params)
          return lr.newProgressScope(params)
        end,
      }

      local result = ProgressScope.forExportContext("Export", 2, exportContext, function(scope)
        scope:advance()
        return "result"
      end)

      assert.are.equal("result", result)
      assert.are.equal("Export", lr.progressScopes[1].params.title)
      assert.is_true(lr.progressScopes[1].cancelable)
      assertPositions({ 0.5 })
    end)
  end)

  describe("advance", function()
    it("reports the portion complete", function()
      ProgressScope.new("Title", 4, function(scope)
        scope:advance()
        scope:advance(2)
        scope:advanceTo(4)
      end)

      assertPositions({ 0.25, 0.75, 1 })
      assert.are.same({}, warnings())
    end)

    it("warns and clamps when advancing past the total", function()
      ProgressScope.new("Title", 4, function(scope)
        scope:advance(5)
      end)

      assertPositions({ 1 })
      assert.are.same({ "Advanced past total" }, warnings())
    end)

    it("warns when progress goes backwards", function()
      ProgressScope.new("Title", 4, function(scope)
        scope:advance(2)
        scope:advanceTo(1)
      end)

      assertPositions({ 0.5, 0.25 })
      assert.are.same({ "Reversed progress" }, warnings())
    end)

    it("yields unless told not to", function()
      lr.state.canYield = true

      ProgressScope.new("Title", 4, function(scope)
        scope:advance()
        scope:advance(1, true)
      end)

      assert.are.equal(1, lr.state.yields)
    end)

    it("doesn't yield when it can't", function()
      ProgressScope.new("Title", 4, function(scope)
        scope:advance()
      end)

      assert.are.equal(0, lr.state.yields)
    end)
  end)

  describe("childScope", function()
    it("maps child progress into one step of the parent", function()
      ProgressScope.new("Title", 4, function(scope)
        scope:childScope(2, function(child)
          child:advance()
          child:advance()
        end)
      end)

      assertPositions({ 0, 0.125, 0.25, 0.25 })
      assert.are.same({}, warnings())
    end)

    it("supports nesting", function()
      ProgressScope.new("Title", 2, function(scope)
        scope:childScope(2, function(child)
          child:childScope(2, function(grandchild)
            grandchild:advance()
            grandchild:advance()
          end)
          child:advance()
        end)
      end)

      assertPositions({ 0, 0, 0.125, 0.25, 0.25, 0.5, 0.5 })
      assert.are.same({}, warnings())
    end)

    it("returns the result of the function", function()
      local result
      ProgressScope.new("Title", 1, function(scope)
        result = scope:childScope(1, function(child)
          child:advance()
          return "result"
        end)
      end)

      assert.are.equal("result", result)
    end)

    it("warns when the child doesn't complete", function()
      ProgressScope.new("Title", 2, function(scope)
        scope:childScope(3, function(child)
          child:advance()
        end)
      end)

      assertPositions({ 0, 1 / 6, 0.5 })
      assert.are.same({ "Scope ended before completing" }, warnings())
      assert.are.same({ n = 5, "ProgressScope", "Scope ended before completing", 1, 1, 3 }, lr.logsAt("warn")[1].args)
    end)

    it("warns when the parent advances while a child is active", function()
      ProgressScope.new("Title", 2, function(scope)
        scope:childScope(1, function(child)
          scope:advance()
          child:advance()
        end)
      end)

      assert.are.same({ "Advancing parent scope with active child" }, warnings())
    end)

    it("doesn't yield when starting", function()
      lr.state.canYield = true

      ProgressScope.new("Title", 1, function(scope)
        scope:childScope(1, function() end)
      end)

      -- Only when the parent moves on after the child scope.
      assert.are.equal(1, lr.state.yields)
    end)
  end)

  describe("ipairs", function()
    it("visits every item and advances after each", function()
      local visited = {}
      ProgressScope.new("Title", 1, function(scope)
        scope:ipairs({ "a", "b", "c" }, function(_, index, item)
          table.insert(visited, { index, item })
        end)
      end)

      assert.are.same({ { 1, "a" }, { 2, "b" }, { 3, "c" } }, visited)
      assertPositions({ 0, 0, 1 / 3, 2 / 3, 1, 1 })
      assert.are.same({}, warnings())
    end)

    it("handles empty tables", function()
      local called = false
      ProgressScope.new("Title", 1, function(scope)
        scope:ipairs({}, function()
          called = true
        end)
      end)

      assert.is_false(called)
    end)
  end)

  describe("cancellation", function()
    it("throws a cancellation error when the user cancels", function()
      local canceled
      local ok, err = pcall(ProgressScope.new, "Title", 2, function(scope)
        scope:childScope(1, function(child)
          lr.progressScopes[1]:cancel()
          canceled = child:isCanceled()
          child:advance()
        end)
      end)

      assert.is_true(canceled)
      assert.is_false(ok)
      assert.is_true(lr.modules.LrErrors.isCanceledError(err))
    end)
  end)
end)
