-- Sets up the test server started by `mise r integration`: creates the admin
-- user and an API key, then hands out API instances using that key.

local lr = require("lr_stubs")
local http = require("curl_http")
local json = require("json")

local M = {}

M.url = os.getenv("NOODLE_URL") or "http://localhost:2284"
M.email = "admin@example.com"
M.password = "password"

-- The permissions README.md tells users to give the API key.
M.permissions = {
  "asset.read",
  "asset.update",
  "asset.delete",
  "asset.statistics",
  "asset.share",
  "asset.view",
  "asset.download",
  "asset.upload",
  "asset.copy",
  "asset.derive",
  "asset.edit.get",
  "asset.edit.create",
  "asset.edit.delete",
  "album.create",
  "album.read",
  "album.update",
  "album.delete",
  "album.statistics",
  "album.share",
  "album.download",
  "albumAsset.create",
  "albumAsset.delete",
  "user.read",
  "sharedSpaceAsset.create",
}

-- The key the plugin's API calls use, with only M.permissions.
---@type string?
local apiKey

-- A key with every permission, for setting up test data the plugin never
-- creates itself.
---@type string?
local setupApiKey

---@param path string
---@param body table
---@param token string?
---@return number, any
local function post(path, body, token)
  local headers = {
    { field = "Content-Type", value = "application/json" },
    { field = "Accept", value = "application/json" },
  }
  if token then
    table.insert(headers, { field = "Authorization", value = "Bearer " .. token })
  end

  local response, responseHeaders = http.post(M.url .. "/api" .. path, json.encode(body), headers)
  if not responseHeaders.status then
    error("Cannot reach the test server at " .. M.url .. ". Run the tests with `mise r integration`.")
  end

  local decoded = nil
  if response and response ~= "" then
    decoded = json.decode(response)
  end
  return responseHeaders.status, decoded
end

---@param token string
---@param name string
---@param permissions string[]
---@return string
local function createApiKey(token, name, permissions)
  local status, key = post("/api-keys", { name = name, permissions = permissions }, token)
  assert(status == 201, "Creating the " .. name .. " API key failed: " .. tostring(status))
  return key.secret
end

-- Creates the admin user and the API keys the first time it is called.
local function createApiKeys()
  if apiKey then
    return
  end

  -- This fails if the admin already exists, which is fine.
  post("/auth/admin-sign-up", { email = M.email, password = M.password, name = "Admin" })

  local status, login = post("/auth/login", { email = M.email, password = M.password })
  assert(status == 201, "Login failed: " .. tostring(status))

  apiKey = createApiKey(login.accessToken, "plugin", M.permissions)
  setupApiKey = createApiKey(login.accessToken, "test setup", { "all" })
end

local photoCount = 0

-- Writes a copy of the fixture photo to a temporary file and returns its path.
-- Each copy has different trailing bytes so the server doesn't treat them as
-- duplicates. The caller should remove the file.
---@return string
function M.photo()
  local source = assert(io.open("tests/integration/fixtures/photo.jpg", "rb"))
  local content = source:read("*a")
  source:close()

  photoCount = photoCount + 1
  local path = os.tmpname()
  local file = assert(io.open(path, "wb"))
  file:write(content, "unique " .. os.time() .. " " .. photoCount)
  file:close()

  return path
end

-- Resets the Lightroom stubs, keeping the real LrHttp, and returns two APIs
-- connected to the test server: one using the plugin's API key and one with
-- every permission for setting up test data. Call this in before_each.
---@return API, API
function M.reset()
  lr.reset()
  http.install()
  createApiKeys()

  local API = require("API")
  return API.new({ url = M.url, apiKey = apiKey }), API.new({ url = M.url, apiKey = setupApiKey })
end

return M
