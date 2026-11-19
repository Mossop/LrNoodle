-- Stand-ins for the parts of the Lightroom SDK the plugin uses, so plugin modules
-- can be loaded with plain Lua. Requiring this module installs the `import` and
-- `LOC` globals. Call `reset()` before each test to restore the default
-- behaviour and clear anything recorded.
--
-- Plugin modules hold on to the tables `import` returns, so `reset()` refills the
-- same tables rather than replacing them. Tests can override individual fields.

local M = {}

-- The value LrErrors.throwCanceled raises.
M.CANCELED = setmetatable({}, {
  __tostring = function()
    return "canceled"
  end,
})

---@type table<string, table>
M.modules = {
  LrApplication = {},
  LrErrors = {},
  LrFunctionContext = {},
  LrLocalization = {},
  LrLogger = {},
  LrProgressScope = {},
  LrTasks = {},
}

local function encodeUtf8(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  elseif code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end

  return string.char(
    0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40,
    0x80 + code % 0x40
  )
end

local function newContext()
  local context = { failureHandlers = {}, cleanupHandlers = {} }

  function context:addFailureHandler(handler)
    table.insert(self.failureHandlers, handler)
  end

  function context:addCleanupHandler(handler)
    table.insert(self.cleanupHandlers, handler)
  end

  return context
end

-- Calls func with a new function context. Returns pcall style results after
-- running the context's failure and cleanup handlers.
local function runWithContext(func, ...)
  local context = newContext()
  local results = { n = 0 }

  local function pack(...)
    results = { n = select("#", ...), ... }
  end

  local args = { n = select("#", ...), ... }
  pack(pcall(function()
    return func(context, unpack(args, 1, args.n))
  end))

  if not results[1] then
    for _, handler in ipairs(context.failureHandlers) do
      handler(false, results[2])
    end
  end

  for _, handler in ipairs(context.cleanupHandlers) do
    handler(results[1], results[2])
  end

  return unpack(results, 1, results.n)
end

local function newLogger(name)
  local logger = { name = name }

  function logger:enable(target)
    self.enabled = target
  end

  for _, level in ipairs({ "trace", "debug", "info", "warn", "error" }) do
    logger[level] = function(self, ...)
      table.insert(M.logs, { logger = self.name, level = level, args = { n = select("#", ...), ... } })
    end
  end

  return logger
end

---@param params table
function M.newProgressScope(params)
  local scope = { params = params, positions = {}, canceled = false, cancelable = false }

  function scope:setPortionComplete(done, total)
    table.insert(self.positions, done / total)
  end

  function scope:setCancelable(cancelable)
    self.cancelable = cancelable
  end

  function scope:isCanceled()
    return self.canceled
  end

  function scope:cancel()
    self.canceled = true
  end

  function scope:done()
    self.isDone = true
  end

  table.insert(M.progressScopes, scope)
  return scope
end

-- Everything logged through LrLogger at the given level.
---@param level string
function M.logsAt(level)
  local result = {}
  for _, entry in ipairs(M.logs) do
    if entry.level == level then
      table.insert(result, entry)
    end
  end
  return result
end

function M.reset()
  -- Log entries: { logger, level, args }
  M.logs = {}
  -- Every progress scope created through LrProgressScope.
  M.progressScopes = {}
  M.state = {
    canYield = false,
    yields = 0,
  }

  M.catalog = {
    hasWriteAccess = false,
    writeActions = {},
  }

  function M.catalog:withWriteAccessDo(action, func)
    table.insert(self.writeActions, action)
    self.hasWriteAccess = true
    local results = { runWithContext(func) }
    self.hasWriteAccess = false

    if not results[1] then
      error(results[2], 0)
    end
  end

  local modules = M.modules

  modules.LrApplication.activeCatalog = function()
    return M.catalog
  end

  modules.LrErrors.throwCanceled = function()
    error(M.CANCELED)
  end
  modules.LrErrors.isCanceledError = function(err)
    return err == M.CANCELED
  end

  modules.LrFunctionContext.pcallWithContext = function(_, func, ...)
    return runWithContext(func, ...)
  end
  modules.LrFunctionContext.callWithContext = function(_, func, ...)
    local results = { runWithContext(func, ...) }
    if not results[1] then
      error(results[2], 0)
    end
    return unpack(results, 2)
  end
  -- Runs synchronously. Like Lightroom, errors are not propagated to the caller.
  modules.LrFunctionContext.postAsyncTaskWithContext = function(_, func)
    runWithContext(func)
  end

  modules.LrLocalization.encodeUtf8Character = encodeUtf8

  setmetatable(modules.LrLogger, {
    __call = function(_, name)
      return newLogger(name)
    end,
  })

  setmetatable(modules.LrProgressScope, {
    __call = function(_, params)
      return M.newProgressScope(params)
    end,
  })

  modules.LrTasks.canYield = function()
    return M.state.canYield
  end
  modules.LrTasks.yield = function()
    M.state.yields = M.state.yields + 1
  end
end

function import(name) -- luacheck: ignore
  local module = M.modules[name]
  if not module then
    error("No stub for Lightroom module " .. name, 2)
  end
  return module
end

function LOC(str, ...) -- luacheck: ignore
  local value = str:match("^%$%$%$/[^=]*=(.*)$") or str
  local args = { ... }
  return (value:gsub("%^(%d)", function(n)
    return tostring(args[tonumber(n)] or "")
  end))
end

M.reset()

return M
