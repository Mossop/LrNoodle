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
  LrColor = {},
  LrDate = {},
  LrErrors = {},
  LrExportSettings = {},
  LrFileUtils = {},
  LrFunctionContext = {},
  LrHttp = {},
  LrLocalization = {},
  LrLogger = {},
  LrPasswords = {},
  LrPathUtils = {},
  LrPrefs = {},
  LrProgressScope = {},
  LrTasks = {},
  LrView = {},
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

-- Queues a response for the next LrHttp request. `response` is either
-- { status = number, body = string? } or { error = { errorCode, name } } for a
-- connection failure.
---@param response table
function M.respond(response)
  table.insert(M.http.responses, response)
end

-- Queues a successful response with a JSON encoded body.
---@param status number
---@param body any
function M.respondJson(status, body)
  local json = require("json")
  M.respond({ status = status, body = json.encode(body) })
end

local function httpResponse(request)
  table.insert(M.http.requests, request)

  local response = table.remove(M.http.responses, 1)
  if not response then
    error("Unexpected HTTP request " .. request.method .. " " .. request.url)
  end

  if response.error then
    return nil, { error = response.error }
  end

  return response.body or "", { status = response.status }
end

-- Finds the value of a header in a recorded request.
---@param request table
---@param field string
---@return string?
function M.header(request, field)
  for _, header in ipairs(request.headers or {}) do
    if header.field == field then
      return header.value
    end
  end
  return nil
end

-- Whether any log entry contains the given text.
---@param text string
---@return boolean
function M.logged(text)
  for _, entry in ipairs(M.logs) do
    local parts = {}
    for i = 1, entry.args.n do
      table.insert(parts, tostring(entry.args[i]))
    end
    if string.find(table.concat(parts, " "), text, 1, true) then
      return true
    end
  end
  return false
end

function M.reset()
  -- Log entries: { logger, level, args }
  M.logs = {}
  -- requests: every LrHttp request made, { method, url, body, headers, chunks }
  -- responses: queued responses, see M.respond
  M.http = { requests = {}, responses = {} }
  -- Every progress scope created through LrProgressScope.
  M.progressScopes = {}
  M.state = {
    canYield = false,
    yields = 0,
    currentTime = 0,
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

  modules.LrHttp.get = function(url, headers)
    return httpResponse({ method = "GET", url = url, headers = headers })
  end
  modules.LrHttp.post = function(url, body, headers, method)
    return httpResponse({ method = method or "POST", url = url, body = body, headers = headers })
  end
  modules.LrHttp.postMultipart = function(url, chunks, headers, timeout)
    -- Record the contents of any files that exist, since they may be removed
    -- after the request.
    for _, chunk in ipairs(chunks) do
      if chunk.filePath then
        local file = io.open(chunk.filePath, "r")
        if file then
          chunk.content = file:read("*a")
          file:close()
        end
      end
    end

    return httpResponse({ method = "MULTIPART", url = url, chunks = chunks, headers = headers, timeout = timeout })
  end

  modules.LrLocalization.encodeUtf8Character = encodeUtf8

  -- The available video export presets, as { format, name } pairs. Applying a
  -- preset records it in the settings as LR_videoPreset.
  M.videoPresets = {
    { format = "h.264", name = "Medium" },
    { format = "h.264", name = "High" },
    { format = "DPX", name = "High" },
  }
  modules.LrExportSettings.videoExportPresets = function()
    local presets = {}
    for _, definition in ipairs(M.videoPresets) do
      table.insert(presets, {
        definition = definition,
        formatID = function()
          return definition.format
        end,
        name = function()
          return definition.name
        end,
      })
    end
    return presets
  end
  modules.LrExportSettings.applyVideoExportPreset = function(settings, preset)
    settings.LR_videoPreset = preset.definition
  end

  -- Lightroom timestamps count from 2001-01-01 rather than 1970-01-01.
  modules.LrDate.timeToPosixDate = function(time)
    return time + 978307200
  end
  modules.LrDate.currentTime = function()
    return M.state.currentTime
  end

  setmetatable(modules.LrColor, {
    __call = function(_, ...)
      return { ... }
    end,
  })

  -- The plugin's preferences. Modules keep hold of this table so it is cleared
  -- rather than replaced. Debug logging is on by default so tests can check it.
  M.prefs = M.prefs or {}
  for key in pairs(M.prefs) do
    M.prefs[key] = nil
  end
  M.prefs.debugLogging = true
  modules.LrPrefs.prefsForPlugin = function()
    return M.prefs
  end

  -- Stored passwords, keyed by key string.
  M.passwords = {}
  modules.LrPasswords.store = function(key, password)
    M.passwords[key] = password
  end
  modules.LrPasswords.retrieve = function(key)
    return M.passwords[key]
  end

  -- Lightroom doesn't provide os.remove so plugins must use this instead.
  modules.LrFileUtils.delete = function(path)
    local deleted, reason = os.remove(path)
    return deleted ~= nil, reason
  end

  modules.LrPathUtils.leafName = function(path)
    return (path:match("([^/]+)$"))
  end

  modules.LrView.bind = function(key)
    return { bind = key }
  end
  modules.LrView.share = function(key)
    return { share = key }
  end

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

---@diagnostic disable-next-line: lowercase-global
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
