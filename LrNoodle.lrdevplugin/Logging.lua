local LrLogger = import("LrLogger")
local LrPrefs = import("LrPrefs")

local lrLogger = LrLogger("LrNoodle")
lrLogger:enable("logfile")

local prefs = LrPrefs.prefsForPlugin() --[[@as PluginPrefs]]

--- Whether debugging output (trace, debug and info) should be logged. Warnings
--- and errors are always logged.
---@return boolean
local function debugEnabled()
  return prefs.debugLogging == true
end

---@class Logger
---@field name string
local Logger = {}

---@param ... any
function Logger:trace(...)
  if debugEnabled() then
    lrLogger:trace(self.name, ...)
  end
end

---@param ... any
function Logger:debug(...)
  if debugEnabled() then
    lrLogger:debug(self.name, ...)
  end
end

---@param ... any
function Logger:info(...)
  if debugEnabled() then
    lrLogger:info(self.name, ...)
  end
end

---@param ... any
function Logger:warn(...)
  lrLogger:warn(self.name, ...)
end

---@param ... any
function Logger:error(...)
  lrLogger:error(self.name, ...)
end

---@param name string
---@return Logger
local function create(name)
  local logger = { name = name }
  setmetatable(logger, { __index = Logger })
  return logger
end

return create
