local LrHttp = import("LrHttp")
local LrPasswords = import("LrPasswords")

local Utils = require("Utils")

local logger = require("Logging")("API")

-- Seconds to wait during each phase of an upload. Videos can be large.
local UPLOAD_TIMEOUT = 300

---@alias HttpMethod
---| "GET"
---| "POST"
---| "PUT"
---| "PATCH"
---| "DELETE"

---@class API
---@field private baseUrl string
---@field private apiUrl string
---@field private apiKey string
local API = {}

---@param body string?
---@param headers table?
---@return any | Error
local function parseResponse(body, headers)
  if not headers or not headers.status then
    local error = headers and headers.error or {}
    local name = error.name or "unknown"
    logger:error("Connection to server failed", error.errorCode, name)

    if error.errorCode == "badURL" then
      return Utils.throw("invalidUrl", { name })
    elseif error.errorCode == "cannotFindHost" then
      return Utils.throw("unknownHost", { name })
    end

    return Utils.throw("connection", { name })
  end

  local status = headers.status

  if status >= 200 and status < 300 then
    if not body or body == "" then
      return true
    end

    return Utils.jsonDecode(logger, body)
  end

  if status == 401 or status == 403 then
    return Utils.throw("badApiKey")
  end

  if status == 404 then
    return Utils.throw("notFound")
  end

  local message = tostring(status)
  if body and body ~= "" then
    local decoded = Utils.jsonDecode(logger, body) --[[@as any]]
    if Utils.isSuccess(decoded) and type(decoded) == "table" and decoded.message then
      if type(decoded.message) == "table" then
        -- Validation errors give a list of messages.
        ---@type string[]
        local messages = {}
        for _, m in ipairs(decoded.message) do
          table.insert(messages, tostring(m))
        end
        message = table.concat(messages, "; ")
      else
        message = tostring(decoded.message)
      end
    end
  end

  -- The server reports some missing items, such as deleted assets, as a bad
  -- request rather than not found.
  if status == 400 and string.match(message, "^Not found") then
    logger:debug("Server reported item not found", body)
    return Utils.throw("notFound")
  end

  logger:error("Error response from server", status, body)
  return Utils.throw("serverError", { message })
end

---@private
---@param method HttpMethod
---@param path string
---@param body table?
---@return any | Error
function API:request(method, path, body)
  local url = self.apiUrl .. path
  logger:trace(method, url)

  local headers = {
    { field = "x-api-key", value = self.apiKey },
    { field = "Accept", value = "application/json" },
  }

  if method == "GET" then
    return parseResponse(LrHttp.get(url, headers))
  end

  local encoded = "{}"
  if body then
    local result = Utils.jsonEncode(logger, body)
    if Utils.isError(result) then
      return result
    end
    encoded = result --[[@as string]]
  end

  table.insert(headers, { field = "Content-Type", value = "application/json" })

  return parseResponse(LrHttp.post(url, encoded, headers, method))
end

---@private
---@param path string
---@param chunks table[]
---@return any | Error
function API:multipart(path, chunks)
  local url = self.apiUrl .. path
  logger:trace("MULTIPART", url)

  local headers = {
    { field = "x-api-key", value = self.apiKey },
    { field = "Accept", value = "application/json" },
  }

  return parseResponse(LrHttp.postMultipart(url, chunks, headers, UPLOAD_TIMEOUT))
end

---@return User | Error
function API:checkConnection()
  return self:request("GET", "/users/me")
end

---@param id string
---@return Asset | Error
function API:getAsset(id)
  return self:request("GET", "/assets/" .. id)
end

--- Checks that an asset exists on the server, restoring it from the trash if
--- necessary.
---@param id string
---@return boolean | Error # False if the asset does not exist.
function API:ensureAsset(id)
  local asset = self:getAsset(id)
  if Utils.isError(asset) then
    if Utils.error(asset).code == "notFound" then
      logger:debug("Asset", id, "does not exist")
      return false
    end

    return Utils.error(asset)
  end

  if Utils.result(asset).isTrashed then
    logger:info("Restoring asset from the trash", id)
    local restored = self:restoreAssets({ id })
    if Utils.isError(restored) then
      return Utils.error(restored)
    end
  else
    logger:debug("Asset", id, "exists")
  end

  return true
end

--- Checks whether an asset exists on the server, including in the trash,
--- without restoring it.
---@param id string
---@return boolean | Error
function API:assetExists(id)
  local asset = self:getAsset(id)
  if Utils.isError(asset) then
    if Utils.error(asset).code == "notFound" then
      logger:debug("Asset", id, "does not exist")
      return false
    end

    return Utils.error(asset)
  end

  logger:debug("Asset", id, Utils.result(asset).isTrashed and "is in the trash" or "exists")
  return true
end

---@param ids string[]
---@return true | Error
function API:restoreAssets(ids)
  return self:request("POST", "/trash/restore/assets", { ids = ids })
end

---@param filePath string
---@param fileName string
---@param dates AssetDates
---@param source UploadSource? Stored as the asset's "LrNoodle" metadata. The server only stores it when the
---upload creates an asset, not for a duplicate.
---@param sidecarPath string? An XMP sidecar file with metadata for the asset.
---@return UploadResult | Error
function API:uploadAsset(filePath, fileName, dates, source, sidecarPath)
  local chunks = {
    { name = "fileCreatedAt", value = Utils.formatTimestamp(dates.created) },
    { name = "fileModifiedAt", value = Utils.formatTimestamp(dates.modified) },
    {
      name = "assetData",
      fileName = fileName,
      filePath = filePath,
      contentType = "application/octet-stream",
    },
  }

  if source then
    local metadata = Utils.jsonEncode(logger, { { key = "LrNoodle", value = source } })
    if Utils.isError(metadata) then
      return Utils.error(metadata)
    end
    table.insert(chunks, { name = "metadata", value = Utils.result(metadata) })
  end

  if sidecarPath then
    table.insert(chunks, {
      name = "sidecarData",
      fileName = fileName .. ".xmp",
      filePath = sidecarPath,
      contentType = "application/rdf+xml",
    })
  end

  return self:multipart("/assets", chunks)
end

--- Copies everything except the sidecar from one asset to another. The
--- sidecar is not copied since any sidecar for the new asset is newer.
---@param sourceId string
---@param targetId string
---@return true | Error
function API:copyAsset(sourceId, targetId)
  return self:request("PUT", "/assets/copy", { sourceId = sourceId, targetId = targetId, sidecar = false })
end

---@param ids string[]
---@param force boolean? Delete permanently instead of moving to the trash.
---@return true | Error
function API:deleteAssets(ids, force)
  logger:debug(force and "Permanently deleting assets" or "Trashing assets", table.concat(ids, ", "))
  return self:request("DELETE", "/assets", { ids = ids, force = force or false })
end

--- Since the server cannot change an asset's file, a changed file is uploaded
--- as a new asset. This copies everything from the asset being replaced to the
--- new one. Nothing is copied if the old asset no longer exists. The caller is
--- responsible for deleting the old asset, and the new one if this fails.
---@param oldId string
---@param newId string
---@return true | Error
function API:copyFromAsset(oldId, newId)
  local old = self:getAsset(oldId)
  if Utils.isError(old) then
    if Utils.error(old).code == "notFound" then
      logger:info("Asset to replace no longer exists", oldId)
      return true
    end

    return Utils.error(old)
  end

  logger:debug("Copying asset", oldId, "to", newId)
  local copied = self:copyAsset(oldId, newId)
  if Utils.isError(copied) then
    logger:warn("Failed to copy asset", oldId, "to", newId, Utils.errorString(copied))
    return Utils.error(copied)
  end

  -- The copy doesn't include the visibility, which only the gallery sets. A
  -- new asset is on the timeline.
  local visibility = Utils.result(old).visibility
  if visibility and visibility ~= "timeline" then
    logger:debug("Setting visibility of asset", newId, "to", visibility)
    local updated = self:request("PUT", "/assets", { ids = { newId }, visibility = visibility })
    if Utils.isError(updated) then
      logger:warn("Failed to copy visibility of asset", oldId, "to", newId, Utils.errorString(updated))
      return Utils.error(updated)
    end
  end

  return true
end

---@param id string
---@return Album | Error
function API:getAlbum(id)
  return self:request("GET", "/albums/" .. id)
end

--- The albums that contain an asset.
---@param assetId string
---@return Album[] | Error
function API:getAlbumsForAsset(assetId)
  return self:request("GET", "/albums?assetId=" .. assetId)
end

-- The most assets the server accepts in one spaces lookup.
local SPACES_BATCH = 1000

--- The shared spaces that show each of the given assets, by any route. Only
--- Noodle Gallery has shared spaces; an Immich server reports none.
---@param assetIds string[]
---@return { [string]: string[] } | Error # Space IDs keyed by asset ID. Assets in no spaces are left out.
function API:getAssetSpaces(assetIds)
  ---@type { [string]: string[] }
  local spaces = {}

  for first = 1, #assetIds, SPACES_BATCH do
    ---@type string[]
    local batch = {}
    for i = first, math.min(first + SPACES_BATCH - 1, #assetIds) do
      table.insert(batch, assetIds[i])
    end

    local result = self:request("POST", "/assets/spaces", { assetIds = batch })
    if Utils.isError(result) then
      if Utils.error(result).code == "notFound" then
        logger:debug("Server doesn't support shared spaces")
        return {}
      end
      return Utils.error(result)
    end

    local response = Utils.result(result)
    if type(response) ~= "table" or type(response.assets) ~= "table" then
      return Utils.throw("serverError", { "unexpected shared spaces response" })
    end

    for _, item in ipairs(response.assets) do
      spaces[item.assetId] = item.spaceIds
    end
  end

  return spaces
end

---@param spaceId string
---@param assetIds string[]
---@return true | Error
function API:addAssetsToSpace(spaceId, assetIds)
  return self:request("POST", "/shared-spaces/" .. spaceId .. "/assets", { assetIds = assetIds })
end

---@param name string
---@return Album | Error
function API:createAlbum(name)
  return self:request("POST", "/albums", { albumName = name })
end

---@param id string
---@param name string
---@return Album | Error
function API:renameAlbum(id, name)
  return self:request("PATCH", "/albums/" .. id, { albumName = name })
end

---@param id string
---@return true | Error
function API:deleteAlbum(id)
  return self:request("DELETE", "/albums/" .. id)
end

---@param albumId string
---@param ids string[]
---@return BulkIdResult[] | Error
function API:addAssetsToAlbum(albumId, ids)
  return self:request("PUT", "/albums/" .. albumId .. "/assets", { ids = ids })
end

---@param albumId string
---@param ids string[]
---@return BulkIdResult[] | Error
function API:removeAssetsFromAlbum(albumId, ids)
  return self:request("DELETE", "/albums/" .. albumId .. "/assets", { ids = ids })
end

---@param id string
---@return string
function API:assetUrl(id)
  return self.baseUrl .. "/photos/" .. id
end

---@param id string
---@return string
function API:albumUrl(id)
  return self.baseUrl .. "/albums/" .. id
end

---@param url string
---@return string
local function normalizeUrl(url)
  return (string.gsub(url, "/+$", ""))
end

---@param url string
---@return string
local function apiKeyStorageKey(url)
  return "apiKey:" .. normalizeUrl(url)
end

--- Stores the API key for a gallery in Lightroom's encrypted password storage.
---@param url string
---@param apiKey string
function API.storeApiKey(url, apiKey)
  LrPasswords.store(apiKeyStorageKey(url), apiKey)
end

--- Retrieves the stored API key for a gallery.
---@param url string
---@return string?
function API.retrieveApiKey(url)
  return LrPasswords.retrieve(apiKeyStorageKey(url))
end

--- Creates an API for the gallery. If the settings don't include an API key
--- the stored key for the gallery is used.
---@param settings PublishSettings
---@return API
function API.new(settings)
  local baseUrl = normalizeUrl(settings.url or "")

  ---@type API
  local api = {
    baseUrl = baseUrl,
    apiUrl = baseUrl .. "/api",
    apiKey = settings.apiKey or API.retrieveApiKey(baseUrl) or "",
  }
  setmetatable(api, { __index = API })

  return api
end

return API
