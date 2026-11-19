-- A real LrHttp for the integration tests, making requests with curl. Requiring
-- this module replaces the stubbed LrHttp functions from lr_stubs. Only the
-- response status is returned in the headers table.

local lr = require("lr_stubs")

local M = {}

---@param value string
---@return string
local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param path string
---@return string
local function readFile(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

---@param path string
---@param content string
local function writeFile(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

-- Runs curl with the given arguments and returns the response like LrHttp.
---@param url string
---@param headers table?
---@param args string[]
---@param timeout number?
---@return string?, table
local function curl(url, headers, args, timeout)
  local bodyFile = os.tmpname()

  local command = { "curl", "--silent", "--output", quote(bodyFile), "--write-out", "'%{http_code}'" }
  table.insert(command, "--max-time")
  table.insert(command, tostring(timeout or 30))

  for _, header in ipairs(headers or {}) do
    table.insert(command, "--header")
    table.insert(command, quote(header.field .. ": " .. header.value))
  end

  for _, arg in ipairs(args) do
    table.insert(command, arg)
  end
  table.insert(command, quote(url))

  local process = assert(io.popen(table.concat(command, " ")))
  local status = tonumber(process:read("*a"))
  process:close()

  local body = readFile(bodyFile)
  os.remove(bodyFile)

  if not status or status == 0 then
    return nil, { error = { errorCode = "networkConnectionLost", name = "curl request to " .. url .. " failed" } }
  end

  return body, { status = status }
end

---@param url string
---@param headers table?
function M.get(url, headers)
  return curl(url, headers, {})
end

---@param url string
---@param body string
---@param headers table?
---@param method string?
function M.post(url, body, headers, method)
  local bodyFile = os.tmpname()
  writeFile(bodyFile, body)

  local result, responseHeaders =
    curl(url, headers, { "--request", method or "POST", "--data-binary", quote("@" .. bodyFile) })

  os.remove(bodyFile)
  return result, responseHeaders
end

---@param url string
---@param chunks table[]
---@param headers table?
---@param timeout number?
function M.postMultipart(url, chunks, headers, timeout)
  local args = {}

  for _, chunk in ipairs(chunks) do
    if chunk.filePath then
      local form = chunk.name .. "=@" .. chunk.filePath
      if chunk.fileName then
        form = form .. ";filename=" .. chunk.fileName
      end
      if chunk.contentType then
        form = form .. ";type=" .. chunk.contentType
      end
      table.insert(args, "--form")
      table.insert(args, quote(form))
    else
      table.insert(args, "--form-string")
      table.insert(args, quote(chunk.name .. "=" .. chunk.value))
    end
  end

  return curl(url, headers, args, timeout)
end

-- Installs the curl functions in place of the stubbed LrHttp. lr.reset()
-- restores the stubs, so call this again after it.
function M.install()
  lr.modules.LrHttp.get = M.get
  lr.modules.LrHttp.post = M.post
  lr.modules.LrHttp.postMultipart = M.postMultipart
end

return M
