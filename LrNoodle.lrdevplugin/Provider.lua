local LrApplication = import("LrApplication")
local LrDate = import("LrDate")
local LrExportSettings = import("LrExportSettings")
local LrErrors = import("LrErrors")
local LrFileUtils = import("LrFileUtils")
local LrFunctionContext = import("LrFunctionContext")
local LrView = import("LrView")
local LrColor = import("LrColor")
local LrPathUtils = import("LrPathUtils")

local API = require("API")
local Utils = require("Utils")
local ProgressScope = require("ProgressScope")
local Sidecar = require("Sidecar")

local logger = require("Logging")("Provider")

local bind = LrView.bind

local Provider = {}

Provider.supportsIncrementalPublish = "only"

Provider.canExportVideo = true

Provider.small_icon = "icon.png"

Provider.hideSections = {
  "exportLocation",
  "fileNaming",
}

-- The API key is kept in Lightroom's encrypted password storage rather than in
-- the settings.
Provider.exportPresetFields = {
  { key = "url", default = "" },
  { key = "replacePeopleTags", default = false },
  { key = "peopleReplacementTag", default = "" },
  { key = "replacePeopleInVideos", default = false },
  { key = "serviceId", default = "" },
}

Provider.publish_fallbackNameBinding = "url"

Provider.titleForGoToPublishedCollection = LOC("$$$/LrNoodle/GoToCollection=Show in Noodle Gallery")

---@param publishSettings PublishSettings
---@return boolean
function Provider.canAddCommentsToService(publishSettings) -- luacheck: ignore publishSettings
  return false
end

---@param publishSettings PublishSettings
---@return table
function Provider.getCollectionBehaviorInfo(publishSettings) -- luacheck: ignore publishSettings
  return {
    defaultCollectionName = LOC("$$$/LrNoodle/DefaultCollection=Photos"),
    defaultCollectionCanBeDeleted = true,
    canAddCollection = true,
  }
end

--- Treats an album that no longer exists on the server as success.
---@generic T
---@param result T | Error
---@return T | true | Error
local function ignoreMissingAlbum(result)
  if Utils.isError(result) and Utils.error(result).code == "notFound" then
    logger:info("Album no longer exists on the server")
    return true
  end

  return result
end

---@param publishSettings PublishSettings
---@param info table
function Provider.renamePublishedCollection(publishSettings, info)
  if not info.remoteId then
    return
  end

  local api = API.new(publishSettings)
  logger:debug("Renaming album", info.remoteId, "to", info.name)
  local result = ignoreMissingAlbum(api:renameAlbum(tostring(info.remoteId), info.name))
  if Utils.isError(result) then
    error(Utils.errorString(result))
  end
end

------------------------ Publishing

---@class RenditionPlan
---@field assetId string? The existing asset for this photo, if any.
---@field needsUpload boolean Whether the image data must be uploaded.
---@field others LrPublishedPhoto[] Published copies of this photo in the service's other collections.
---@field error Error? Set if the photo cannot be published.

--- A change to a published photo, applied to the catalog once publishing is
--- complete.
---@class PublishedPhotoUpdate
---@field published LrPublishedPhoto
---@field remoteId string? The new remote ID, if it is changing.
---@field remoteUrl string? The new remote URL, if it is changing.
---@field edited boolean? The new edited flag, if it is changing.

--- Applies the collected updates in a single catalog write.
---@param updates PublishedPhotoUpdate[]
local function applyUpdates(updates)
  if #updates == 0 then
    return
  end

  Utils.runWithWriteAccess(logger, "Update Published Photos", function()
    for _, update in ipairs(updates) do
      if update.remoteId then
        update.published:setRemoteId(update.remoteId)
      end
      if update.remoteUrl then
        update.published:setRemoteUrl(update.remoteUrl)
      end
      if update.edited ~= nil then
        update.published:setEditedFlag(update.edited)
      end
    end
  end)
end

--- Adds the collection's unedited published photos to a recreated album. Any
--- the server rejects are marked as edited so they will be republished.
---@param api API
---@param albumId string
---@param collection LrPublishedCollection
---@param updates PublishedPhotoUpdate[]
local function restoreAlbumContents(api, albumId, collection, updates)
  ---@type { [string]: LrPublishedPhoto[] }
  local byAsset = {}
  ---@type string[]
  local assetIds = {}

  for _, published in ipairs(collection:getPublishedPhotos()) do
    local remoteId = published:getRemoteId()
    if remoteId and not published:getEditedFlag() then
      local id = tostring(remoteId)
      if not byAsset[id] then
        byAsset[id] = {}
        table.insert(assetIds, id)
      end
      table.insert(byAsset[id], published)
    end
  end

  if #assetIds == 0 then
    return
  end

  ---@param id string
  ---@param reason string
  local function republish(id, reason)
    logger:debug("Asset", id, "could not be added to the recreated album", reason, "so marking it edited")
    for _, published in ipairs(byAsset[id]) do
      table.insert(updates, { published = published, edited = true })
    end
  end

  logger:debug("Adding existing assets to the recreated album", table.concat(assetIds, ", "))
  local added = api:addAssetsToAlbum(albumId, assetIds)
  if Utils.isError(added) then
    logger:warn("Failed to add existing assets to the recreated album", Utils.errorString(added))
    for _, id in ipairs(assetIds) do
      republish(id, Utils.errorString(added))
    end
    return
  end

  for _, result in ipairs(Utils.result(added)) do
    if not result.success and result.error ~= "duplicate" and byAsset[result.id] then
      republish(result.id, tostring(result.error))
    end
  end
end

--- Finds the album for the collection, creating it if it doesn't exist.
---@param api API
---@param exportContext LrExportContext
---@param updates PublishedPhotoUpdate[]
---@return string | Error
local function ensureAlbum(api, exportContext, updates)
  local collection = exportContext.publishedCollection
  local albumId = collection:getRemoteId()
  local recreating = false

  if albumId then
    local existing = api:getAlbum(tostring(albumId))
    if Utils.isSuccess(existing) then
      logger:debug("Using existing album", albumId)
      return tostring(albumId)
    end

    if Utils.error(existing).code ~= "notFound" then
      return Utils.error(existing)
    end

    logger:warn("Album no longer exists on the server, creating a new one", albumId)
    recreating = true
  end

  local album = api:createAlbum(collection:getName())
  if Utils.isError(album) then
    return Utils.error(album)
  end

  local newAlbumId = Utils.result(album).id
  logger:debug("Created album", newAlbumId)
  exportContext.exportSession:recordRemoteCollectionId(newAlbumId)
  exportContext.exportSession:recordRemoteCollectionUrl(api:albumUrl(newAlbumId))

  if recreating then
    restoreAlbumContents(api, newAlbumId, collection, updates)
  end

  return newAlbumId
end

--- Lists the published copies of photos in all of the service's collections
--- except the one given, keyed by the photo's local identifier. Photos that
--- have never been published are ignored.
---@param publishService LrPublishService
---@param exclude LrPublishedCollection
---@return { [number]: LrPublishedPhoto[] }
local function publishedPhotosElsewhere(publishService, exclude)
  ---@type { [number]: LrPublishedPhoto[] }
  local result = {}

  for _, collection in ipairs(Utils.listCollections(publishService)) do
    if collection.localIdentifier ~= exclude.localIdentifier then
      for _, published in ipairs(collection:getPublishedPhotos()) do
        if published:getRemoteId() then
          local localId = published:getPhoto().localIdentifier
          local list = result[localId]
          if not list then
            list = {}
            result[localId] = list
          end
          table.insert(list, published)
        end
      end
    end
  end

  return result
end

--- Checks assets on the server, remembering the results so each asset is only
--- checked once.
---@param api API
---@return fun(id: string): boolean | Error ensure Checks an asset exists, restoring it from the trash.
---@return fun(id: string): boolean | Error exists Checks an asset exists without restoring it.
local function assetChecker(api)
  -- Assets checked and, if necessary, restored.
  ---@type { [string]: boolean }
  local ensured = {}
  -- Assets checked without restoring them.
  ---@type { [string]: boolean }
  local found = {}

  local function ensure(id)
    if ensured[id] == nil then
      local exists = api:ensureAsset(id)
      if Utils.isError(exists) then
        return Utils.error(exists)
      end
      ensured[id] = Utils.result(exists) --[[@as boolean]]
    end

    return ensured[id]
  end

  local function exists(id)
    if ensured[id] ~= nil then
      return ensured[id]
    end

    if found[id] == nil then
      local result = api:assetExists(id)
      if Utils.isError(result) then
        return Utils.error(result)
      end
      found[id] = Utils.result(result) --[[@as boolean]]
    end

    return found[id]
  end

  return ensure, exists
end

---@param rendition LrExportRendition
---@param others LrPublishedPhoto[]
---@param assetExists fun(id: string): boolean | Error
---@return RenditionPlan
local function planRendition(rendition, others, assetExists)
  local photoId = rendition.photo.localIdentifier

  ---@type string[]
  local otherDescriptions = {}
  for _, other in ipairs(others) do
    table.insert(otherDescriptions, tostring(other:getRemoteId()) .. (other:getEditedFlag() and " (edited)" or ""))
  end
  logger:debug(
    "Planning photo",
    photoId,
    "current asset",
    rendition.publishedPhotoId,
    "copies elsewhere",
    table.concat(otherDescriptions, ", ")
  )

  ---@param id string
  ---@param needsUpload boolean
  ---@return RenditionPlan?
  local function tryAsset(id, needsUpload)
    local exists = assetExists(id)
    if Utils.isError(exists) then
      logger:warn("Photo", photoId, "failed to check asset", id, Utils.errorString(exists))
      return { needsUpload = needsUpload, others = others, error = Utils.error(exists) }
    end

    if exists then
      return { assetId = id, needsUpload = needsUpload, others = others }
    end

    logger:warn("Photo", photoId, "asset", id, "does not exist on the server")
    return nil
  end

  -- If another copy is unedited the image on the server is already up to date.
  -- This collection's record of the asset may be stale so use the other copy's.
  for _, other in ipairs(others) do
    if not other:getEditedFlag() then
      local plan = tryAsset(tostring(other:getRemoteId()), false)
      if plan then
        if not plan.error then
          logger:debug("Photo", photoId, "reusing unedited asset", plan.assetId, "without uploading")
        end
        return plan
      end
    end
  end

  ---@type string[]
  local candidates = {}
  if rendition.publishedPhotoId then
    table.insert(candidates, tostring(rendition.publishedPhotoId))
  end
  for _, other in ipairs(others) do
    table.insert(candidates, tostring(other:getRemoteId()))
  end

  for _, id in ipairs(candidates) do
    local plan = tryAsset(id, true)
    if plan then
      if not plan.error then
        logger:debug("Photo", photoId, "will upload and replace existing asset", plan.assetId)
      end
      return plan
    end
  end

  logger:debug("Photo", photoId, "has no existing asset, will upload a new asset")
  return { needsUpload = true, others = others }
end

---@param photo LrPhoto
---@return AssetDates
local function photoDates(photo)
  local created = photo:getRawMetadata("dateTimeOriginal")
    or photo:getRawMetadata("dateTimeDigitized")
    or photo:getRawMetadata("dateTime")
    or LrDate.currentTime()

  return {
    created = created,
    modified = photo:getRawMetadata("lastEditTime") or created,
  }
end

--- Lightroom doesn't embed metadata in videos so writes a sidecar holding it.
--- Photos with people get a sidecar holding their tags without the people.
--- Returns the sidecar's path, or nil if there is no sidecar to upload.
---@param rendition LrExportRendition
---@param path string The rendered file.
---@param settings MetadataSettings
---@return string | Error | nil
local function writeSidecar(rendition, path, settings)
  ---@type string?
  local xmp
  if rendition.photo:getRawMetadata("isVideo") then
    xmp = Sidecar.build(rendition.photo, settings)
  else
    xmp = Sidecar.buildTags(rendition.photo, settings)
  end

  if not xmp then
    logger:debug("Photo", rendition.photo.localIdentifier, "has no metadata for a sidecar")
    return nil
  end

  local sidecarPath = path .. ".xmp"
  local written = Sidecar.write(sidecarPath, xmp)
  if Utils.isError(written) then
    return Utils.error(written)
  end

  logger:debug("Photo", rendition.photo.localIdentifier, "uploading with sidecar", xmp)
  return sidecarPath
end

--- Copying an asset doesn't copy its shared spaces. Spaces that show the asset
--- through a linked album show the replacement already since its albums were
--- copied, but the replacement must be added to any others directly.
---@param api API
---@param photoId number
---@param oldId string
---@param newId string
---@return true | Error
local function copySpaces(api, photoId, oldId, newId)
  local spaces = api:getAssetSpaces({ oldId, newId })
  if Utils.isError(spaces) then
    return Utils.error(spaces)
  end
  spaces = Utils.result(spaces) --[[@as { [string]: string[] }]]

  ---@type { [string]: boolean }
  local alreadyShown = {}
  for _, spaceId in ipairs(spaces[newId] or {}) do
    alreadyShown[spaceId] = true
  end

  for _, spaceId in ipairs(spaces[oldId] or {}) do
    if not alreadyShown[spaceId] then
      logger:debug("Photo", photoId, "adding replacement asset", newId, "to shared space", spaceId)
      local added = api:addAssetsToSpace(spaceId, { newId })
      if Utils.isError(added) then
        return Utils.error(added)
      end
    end
  end

  return true
end

--- Tracks an asset uploaded while publishing a photo that the photo doesn't
--- reference yet. If publishing fails it must be deleted so it isn't left
--- orphaned on the server.
---@class UploadTracker
---@field uploadedId string?

---@class UploadedRendition
---@field assetId string
---@field replacedId string? An asset whose details were all copied to the new asset.

---@param api API
---@param rendition LrExportRendition
---@param plan RenditionPlan
---@param path string
---@param settings MetadataSettings
---@param tracker UploadTracker
---@return UploadedRendition | Error
local function uploadRendition(api, rendition, plan, path, settings, tracker)
  local photoId = rendition.photo.localIdentifier
  local fileName = LrPathUtils.leafName(path)
  local dates = photoDates(rendition.photo)

  local sidecar = writeSidecar(rendition, path, settings)
  if Utils.isError(sidecar) then
    return Utils.error(sidecar)
  end
  local sidecarPath = Utils.result(sidecar) --[[@as string?]]

  ---@type UploadSource
  local source = {
    publishService = (settings --[[@as PublishSettings]]).serviceId --[[@as string]],
    photoUuid = rendition.photo:getRawMetadata("uuid") --[[@as string]],
  }

  local uploaded = api:uploadAsset(path, fileName, dates, source, sidecarPath)

  if Utils.isSuccess(uploaded) and Utils.result(uploaded).status == "created" then
    -- A duplicate may be an asset we don't own so is never tracked for deletion.
    tracker.uploadedId = Utils.result(uploaded).id
  end

  if sidecarPath then
    local deleted, reason = LrFileUtils.delete(sidecarPath)
    if not deleted then
      logger:warn("Photo", photoId, "failed to delete sidecar", sidecarPath, reason)
    end
  end

  if Utils.isError(uploaded) then
    logger:debug("Photo", photoId, "failed to upload", Utils.errorString(uploaded))
    return Utils.error(uploaded)
  end

  local result = Utils.result(uploaded) --[[@as UploadResult]]
  logger:debug("Photo", photoId, "uploaded as asset", result.id, result.status)

  ---@type UploadedRendition
  local uploadedRendition = { assetId = result.id }

  if plan.assetId and plan.assetId ~= result.id then
    if result.status == "duplicate" then
      -- The server already has an identical file, possibly one we don't own,
      -- so use it as it is rather than copying over it.
      logger:debug("Photo", photoId, "using existing asset", result.id, "without copying", plan.assetId)
    else
      local copied = api:copyFromAsset(plan.assetId, result.id)
      if Utils.isError(copied) then
        logger:debug("Photo", photoId, "failed to replace asset", plan.assetId, Utils.errorString(copied))
        return Utils.error(copied)
      end

      local spaces = copySpaces(api, photoId, plan.assetId, result.id)
      if Utils.isError(spaces) then
        logger:debug("Photo", photoId, "failed to copy shared spaces", plan.assetId, Utils.errorString(spaces))
        return Utils.error(spaces)
      end

      logger:debug("Photo", photoId, "replaced asset", plan.assetId, "with", result.id)
      uploadedRendition.replacedId = plan.assetId
    end
  end

  return uploadedRendition
end

--- The outcome of publishing a photo. Cleaning up after it must wait until
--- the photo references the new asset.
---@class PublishResult
---@field assetId string
---@field replacedId string? An asset whose details were all copied to the new asset.
---@field staleIds string[] Other assets previously used for the photo.
---@field changed LrPublishedPhoto[] Copies in other collections that reference a different asset.

---@param api API
---@param albumId string
---@param rendition LrExportRendition
---@param plan RenditionPlan
---@param path string?
---@param settings MetadataSettings
---@param tracker UploadTracker
---@return PublishResult | Error
local function publishRendition(api, albumId, rendition, plan, path, settings, tracker)
  local photoId = rendition.photo.localIdentifier
  local assetId = plan.assetId
  ---@type string?
  local replacedId

  if plan.needsUpload then
    if not path then
      return Utils.throw("renderFailed")
    end

    local uploaded = uploadRendition(api, rendition, plan, path, settings, tracker)
    if Utils.isError(uploaded) then
      return Utils.error(uploaded)
    end
    local result = Utils.result(uploaded) --[[@as UploadedRendition]]
    assetId = result.assetId
    replacedId = result.replacedId
  end

  if not assetId then
    return Utils.throw("renderFailed")
  end

  local added = api:addAssetsToAlbum(albumId, { assetId })
  if Utils.isError(added) then
    logger:debug("Photo", photoId, "failed to add asset", assetId, "to album", albumId, Utils.errorString(added))
    return Utils.error(added)
  end

  for _, result in ipairs(Utils.result(added)) do
    if not result.success and result.error ~= "duplicate" then
      logger:debug("Photo", photoId, "album", albumId, "rejected asset", assetId, result.error)
      return Utils.throw("albumAdd", { tostring(result.error) })
    end
  end

  logger:debug("Photo", photoId, "published as asset", assetId, "in album", albumId)

  -- Once the photo references this asset every other published copy of the
  -- photo must reference it too and any other asset previously used for the
  -- photo must be removed.

  ---@type { [string]: boolean }
  local stale = {}

  ---@param id string
  local function seen(id)
    if id ~= assetId and id ~= replacedId then
      stale[id] = true
    end
  end

  -- An asset the photo previously used that wasn't replaced, e.g. because the
  -- upload matched an existing asset.
  if plan.assetId then
    seen(plan.assetId)
  end

  -- This collection's previous asset if the photo now uses a different one.
  if rendition.publishedPhotoId then
    seen(tostring(rendition.publishedPhotoId))
  end

  ---@type LrPublishedPhoto[]
  local changed = {}
  for _, other in ipairs(plan.others) do
    local otherId = tostring(other:getRemoteId())
    if otherId ~= assetId then
      table.insert(changed, other)
      seen(otherId)
    end
  end

  ---@type string[]
  local staleIds = {}
  for id in pairs(stale) do
    table.insert(staleIds, id)
  end
  table.sort(staleIds)

  return {
    assetId = assetId,
    replacedId = replacedId,
    staleIds = staleIds,
    changed = changed,
  }
end

--- The published photos in all of the service's collections, keyed by the
--- asset they reference.
---@param publishService LrPublishService
---@return { [string]: LrPublishedPhoto[] }
local function publishedPhotosByAsset(publishService)
  ---@type { [string]: LrPublishedPhoto[] }
  local byAsset = {}
  for _, collection in ipairs(Utils.listCollections(publishService)) do
    for _, published in ipairs(collection:getPublishedPhotos()) do
      local remoteId = published:getRemoteId()
      if remoteId then
        local id = tostring(remoteId)
        byAsset[id] = byAsset[id] or {}
        table.insert(byAsset[id], published)
      end
    end
  end
  return byAsset
end

--- The albums published from the service's collections, mapped to the
--- collection's name.
---@param publishService LrPublishService
---@return { [string]: string }
local function publishedAlbums(publishService)
  ---@type { [string]: string }
  local albums = {}
  for _, collection in ipairs(Utils.listCollections(publishService)) do
    local albumId = collection:getRemoteId()
    if albumId then
      albums[tostring(albumId)] = collection:getName()
    end
  end
  return albums
end

--- Filters out assets that are in use somewhere Lightroom doesn't control, so
--- they are never deleted: in a shared space, or in an album other than those
--- allowed. If the checks fail the assets are kept.
---@param api API
---@param assetIds string[]
---@param allowedAlbums { [string]: any } Albums an asset may be in and still be deleted.
---@param collectionForAlbum { [string]: string } The published albums, for explaining decisions in the log.
---@return string[] # The assets that can be deleted.
local function withoutAssetsUsedElsewhere(api, assetIds, allowedAlbums, collectionForAlbum)
  if #assetIds == 0 then
    return assetIds
  end

  local spaces = api:getAssetSpaces(assetIds)
  if Utils.isError(spaces) then
    logger:warn("Keeping assets since checking shared spaces failed", Utils.errorString(spaces))
    return {}
  end
  spaces = Utils.result(spaces) --[[@as { [string]: string[] }]]

  ---@type string[]
  local deletable = {}
  for _, id in ipairs(assetIds) do
    local keep = false

    if spaces[id] and #spaces[id] > 0 then
      logger:debug("Keeping asset", id, "which is in shared spaces", table.concat(spaces[id], ", "))
      keep = true
    else
      local albums = api:getAlbumsForAsset(id)
      if Utils.isError(albums) then
        logger:warn("Keeping asset", id, "since checking its albums failed", Utils.errorString(albums))
        keep = true
      else
        for _, album in
          ipairs(Utils.result(albums) --[[@as Album[] ]])
        do
          if not allowedAlbums[album.id] then
            local collectionName = collectionForAlbum[album.id]
            if collectionName then
              logger:debug(
                "Keeping asset",
                id,
                "which is in album",
                album.albumName,
                "but not in its collection",
                collectionName
              )
            else
              logger:debug("Keeping asset", id, "which is in album", album.albumName, "not published from Lightroom")
            end
            keep = true
            break
          end
        end
      end
    end

    if not keep then
      table.insert(deletable, id)
    end
  end

  return deletable
end

--- Deletes an asset uploaded for a photo that failed to publish.
---@param api API
---@param photoId number
---@param tracker UploadTracker
local function discardUpload(api, photoId, tracker)
  local id = tracker.uploadedId
  if not id then
    return
  end

  logger:warn("Photo", photoId, "failed to publish, permanently deleting its uploaded asset", id)
  local deleted = api:deleteAssets({ id }, true)
  if Utils.isError(deleted) then
    logger:error("Photo", photoId, "failed to delete uploaded asset", id, Utils.errorString(deleted))
  end
end

--- Cleans up once the photo references its new asset: deletes the assets the
--- photo previously used and points the photo's other published copies at the
--- new asset.
---@param api API
---@param photoId number
---@param result PublishResult
---@param assetExists fun(id: string): boolean | Error
---@param updates PublishedPhotoUpdate[]
---@param albums { [string]: string } The albums published from the service's collections.
---@param photosByAsset { [string]: LrPublishedPhoto[] } The service's published photos keyed by asset.
local function finishPublish(api, photoId, result, assetExists, updates, albums, photosByAsset)
  local assetId = result.assetId

  ---@type string[]
  local stale = {}
  for _, id in ipairs(result.staleIds) do
    local exists = assetExists(id)
    if Utils.isError(exists) then
      logger:warn("Photo", photoId, "failed to check stale asset", id, Utils.errorString(exists))
    elseif exists then
      table.insert(stale, id)
    else
      logger:debug("Photo", photoId, "stale asset", id, "is already gone from the server")
    end
  end

  -- Nothing was copied from these so keep any that are used somewhere
  -- Lightroom doesn't control.
  local staleToDelete = withoutAssetsUsedElsewhere(api, stale, albums, albums)

  ---@type string[]
  local toDelete = {}
  -- Everything was copied from a replaced asset so it is always deleted.
  if result.replacedId then
    table.insert(toDelete, result.replacedId)
  end
  for _, id in ipairs(staleToDelete) do
    table.insert(toDelete, id)
  end

  if #toDelete > 0 then
    logger:debug("Photo", photoId, "permanently deleting stale assets", table.concat(toDelete, ", "))
    local deleted = api:deleteAssets(toDelete, true)
    if Utils.isError(deleted) then
      logger:warn("Photo", photoId, "failed to delete stale assets", Utils.errorString(deleted))
    else
      -- Other photos may still reference a deleted asset, e.g. a virtual copy
      -- that matched it as a duplicate, so they must be republished. This
      -- photo's own copies are handled below.
      for _, id in ipairs(staleToDelete) do
        for _, published in ipairs(photosByAsset[id] or {}) do
          if published:getPhoto().localIdentifier ~= photoId then
            logger:debug(
              "Photo",
              published:getPhoto().localIdentifier,
              "used deleted asset",
              id,
              "so marking it edited"
            )
            table.insert(updates, { published = published, edited = true })
          end
        end
      end
    end
  end

  -- The new asset may not be in the other collections' albums so they need to
  -- be republished.
  for _, other in ipairs(result.changed) do
    logger:debug(
      "Photo",
      photoId,
      "changing copy elsewhere from asset",
      other:getRemoteId(),
      "to",
      assetId,
      "and marking it edited"
    )
    table.insert(updates, {
      published = other,
      remoteId = assetId,
      remoteUrl = api:assetUrl(assetId),
      edited = true,
    })
  end
end

--- Publishes a photo and records its asset. Any asset uploaded is deleted if
--- anything fails, including an unexpected error, before the photo references
--- it.
---@param api API
---@param albumId string
---@param rendition LrExportRendition
---@param plan RenditionPlan
---@param path string?
---@param settings MetadataSettings
---@return PublishResult | Error
local function publishAndRecord(api, albumId, rendition, plan, path, settings)
  local photoId = rendition.photo.localIdentifier

  ---@type UploadTracker
  local tracker = {}

  local success, result = LrFunctionContext.pcallWithContext("publishPhoto", function()
    local published = publishRendition(api, albumId, rendition, plan, path, settings, tracker)
    if Utils.isError(published) then
      return published
    end

    local assetId = Utils.result(published).assetId
    rendition:recordPublishedPhotoId(assetId)
    -- The photo now references the asset so it must not be deleted.
    tracker.uploadedId = nil
    rendition:recordPublishedPhotoUrl(api:assetUrl(assetId))

    return published
  end)

  if success and Utils.isSuccess(result) then
    return result
  end

  discardUpload(api, photoId, tracker)

  if success then
    return result
  end

  if LrErrors.isCanceledError(result) then
    LrErrors.throwCanceled()
  end

  logger:error("Photo", photoId, "failed to publish", result)
  return Utils.throw("exception", { tostring(result) })
end

--- Publishes the photos in the export, collecting the changes needed to other
--- published photos.
---@param exportContext LrExportContext
---@param scope ProgressScope
---@param updates PublishedPhotoUpdate[]
local function publishPhotos(exportContext, scope, updates)
  local exportSession = exportContext.exportSession
  local photoCount = exportSession:countRenditions()

  local settings = exportContext.propertyTable --[[@as PublishSettings]]

  -- Lightroom only saves the settings from the settings dialog, so a service
  -- created before the ID existed must have its settings saved first.
  if (settings.serviceId or "") == "" then
    logger:warn("The publish service has no ID")
    error(Utils.errorString(Utils.throw("noServiceId")))
  end

  local api = API.new(settings)

  local album = ensureAlbum(api, exportContext, updates)
  if Utils.isError(album) then
    error(Utils.errorString(album))
  end
  local albumId = Utils.result(album) --[[@as string]]

  local elsewhere = publishedPhotosElsewhere(exportContext.publishService, exportContext.publishedCollection)

  -- The collection's album may have just been created so isn't recorded yet.
  local albums = publishedAlbums(exportContext.publishService)
  albums[albumId] = exportContext.publishedCollection:getName()

  local photosByAsset = publishedPhotosByAsset(exportContext.publishService)

  scope:advance()

  ---@type { [number]: RenditionPlan }
  local plans = {}
  -- Assets that may be used are restored from the trash but assets being
  -- cleaned up are not, since they will be permanently deleted.
  local ensureAsset, assetExists = assetChecker(api)

  scope:childScope(photoCount, function(renditionScope)
    for _, rendition in renditionScope:iter(exportSession:renditions()) do
      local plan = planRendition(rendition, elsewhere[rendition.photo.localIdentifier] or {}, ensureAsset)
      plans[rendition.photo.localIdentifier] = plan

      if plan.error or not plan.needsUpload then
        rendition:skipRender()
      end
    end
  end)

  exportContext:startRendering()

  scope:childScope(photoCount, function(renditionScope)
    for _, rendition in renditionScope:iter(exportSession:renditions()) do
      local plan = plans[rendition.photo.localIdentifier]

      local success, pathOrMessage = rendition:waitForRender()

      if plan.error then
        rendition:uploadFailed(Utils.errorString(plan.error))
      elseif plan.needsUpload and not success then
        logger:debug("Photo", rendition.photo.localIdentifier, "failed to render", pathOrMessage)
        rendition:uploadFailed(pathOrMessage or Utils.errorString(Utils.throw("renderFailed")))
      else
        local path = success and pathOrMessage or nil
        local result =
          publishAndRecord(api, albumId, rendition, plan, path, exportContext.propertyTable --[[@as MetadataSettings]])

        if Utils.isError(result) then
          rendition:uploadFailed(Utils.errorString(result))
        else
          finishPublish(
            api,
            rendition.photo.localIdentifier,
            Utils.result(result),
            assetExists,
            updates,
            albums,
            photosByAsset
          )
        end
      end
    end
  end)
end

---@param context LrFunctionContext
---@param exportContext LrExportContext
function Provider.processRenderedPhotos(context, exportContext)
  Utils.logFailures(context, logger, "processRenderedPhotos")

  local photoCount = exportContext.exportSession:countRenditions()

  local title = photoCount > 1
      and LOC("$$$/LrNoodle/Publish/Progress=Publishing ^1 photos to Noodle Gallery", photoCount)
    or LOC("$$$/LrNoodle/Publish/ProgressOne=Publishing one photo to Noodle Gallery")

  -- Changes to published photos are applied once publishing ends, even if it
  -- is interrupted, so the catalog matches what is on the server.
  ---@type PublishedPhotoUpdate[]
  local updates = {}

  local success, failure = LrFunctionContext.pcallWithContext("publishPhotos", function()
    ProgressScope.forExportContext(title, 3, exportContext, function(scope)
      publishPhotos(exportContext, scope, updates)
    end)
  end)

  if success then
    applyUpdates(updates)
    return
  end

  -- Don't let a failure applying the updates hide the original failure.
  local applied, message = LrFunctionContext.pcallWithContext("applyUpdates", function()
    applyUpdates(updates)
  end)
  if not applied then
    logger:error("Failed to apply updates to published photos", message)
  end

  error(failure, 0)
end

------------------------ Deleting

--- Finds the assets used by any of the service's collections except the one
--- given.
---@param publishService LrPublishService
---@param exclude LrPublishedCollection
---@return { [string]: boolean }
local function assetsUsedElsewhere(publishService, exclude)
  ---@type { [string]: boolean }
  local used = {}

  for _, list in pairs(publishedPhotosElsewhere(publishService, exclude)) do
    for _, published in ipairs(list) do
      used[tostring(published:getRemoteId())] = true
    end
  end

  return used
end

--- Deletes the assets for photos being removed from a collection that are not
--- used by any of the collection's remaining photos or by the service's other
--- collections.
---@param api API
---@param publishService LrPublishService
---@param collection LrPublishedCollection
---@param assetIds string[] The asset for each photo being removed.
---@return true | Error
local function deleteOrphanedAssets(api, publishService, collection, assetIds)
  local used = assetsUsedElsewhere(publishService, collection)

  -- Count how many of this collection's photos will still use each asset.
  ---@type { [string]: number }
  local remaining = {}
  for _, published in ipairs(collection:getPublishedPhotos()) do
    local remoteId = published:getRemoteId()
    if remoteId then
      local id = tostring(remoteId)
      remaining[id] = (remaining[id] or 0) + 1
    end
  end
  for _, id in ipairs(assetIds) do
    remaining[id] = (remaining[id] or 1) - 1
  end

  ---@type string[]
  local orphans = {}
  ---@type { [string]: boolean }
  local seen = {}
  for _, id in ipairs(assetIds) do
    if not seen[id] then
      seen[id] = true

      if used[id] then
        logger:debug("Keeping asset", id, "which is used by another collection")
      elseif remaining[id] > 0 then
        logger:debug("Keeping asset", id, "which is used by another photo in this collection")
      else
        table.insert(orphans, id)
      end
    end
  end

  -- No published photo uses these assets, so any album other than the
  -- collection's own is either not published from Lightroom or its collection
  -- doesn't contain the photo.
  ---@type { [string]: boolean }
  local allowed = {}
  local ownAlbum = collection:getRemoteId()
  if ownAlbum then
    allowed[tostring(ownAlbum)] = true
  end
  orphans = withoutAssetsUsedElsewhere(api, orphans, allowed, publishedAlbums(publishService))

  if #orphans == 0 then
    return true
  end

  logger:debug("Moving orphaned assets to the trash", table.concat(orphans, ", "))
  return api:deleteAssets(orphans)
end

---@param publishSettings PublishSettings
---@param arrayOfPhotoIds (string | number)[]
---@param deletedCallback fun(id: string | number)
---@param localCollectionId number
function Provider.deletePhotosFromPublishedCollection(
  publishSettings,
  arrayOfPhotoIds,
  deletedCallback,
  localCollectionId
)
  local api = API.new(publishSettings)
  local catalog = LrApplication.activeCatalog()
  local collection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionId) --[[@as LrPublishedCollection]]

  ---@type string[]
  local ids = {}
  for _, id in ipairs(arrayOfPhotoIds) do
    table.insert(ids, tostring(id))
  end

  local albumId = collection:getRemoteId()
  if albumId then
    logger:debug("Removing assets", table.concat(ids, ", "), "from album", albumId)
    local removed = ignoreMissingAlbum(api:removeAssetsFromAlbum(tostring(albumId), ids))
    if Utils.isError(removed) then
      error(Utils.errorString(removed))
    end
  end

  local deleted = deleteOrphanedAssets(api, collection:getService(), collection, ids)
  if Utils.isError(deleted) then
    error(Utils.errorString(deleted))
  end

  for _, id in ipairs(arrayOfPhotoIds) do
    deletedCallback(id)
  end
end

---@param publishSettings PublishSettings
---@param info table
function Provider.deletePublishedCollection(publishSettings, info)
  local api = API.new(publishSettings)

  ---@type LrPublishedCollection
  local collection = info.publishedCollection

  ---@type string[]
  local ids = {}
  for _, published in ipairs(collection:getPublishedPhotos()) do
    local remoteId = published:getRemoteId()
    if remoteId then
      table.insert(ids, tostring(remoteId))
    end
  end

  logger:debug("Deleting collection", info.name, "with assets", table.concat(ids, ", "))

  local deleted = deleteOrphanedAssets(api, info.publishService, collection, ids)
  if Utils.isError(deleted) then
    error(Utils.errorString(deleted))
  end

  if info.remoteId then
    logger:debug("Deleting album", info.remoteId)
    local result = ignoreMissingAlbum(api:deleteAlbum(tostring(info.remoteId)))
    if Utils.isError(result) then
      error(Utils.errorString(result))
    end
  end
end

------------------------ UI

--- Only https is allowed since the API key is sent with every request.
---@param url string
---@return boolean
local function isValidUrl(url)
  return string.match(url, "^https://.+") ~= nil
end

-- The most recent connection check started for each settings dialog. Results
-- from older checks are ignored.
---@type { [table]: number }
local latestCheck = setmetatable({}, { __mode = "k" })

---@param propertyTable table
local function verifySettings(propertyTable)
  local check = (latestCheck[propertyTable] or 0) + 1
  latestCheck[propertyTable] = check

  ---@param message string?
  local function setError(message)
    propertyTable.error = message or ""
    propertyTable.LR_cantExportBecause = message
  end

  if not isValidUrl(propertyTable.url or "") then
    setError(LOC("$$$/LrNoodle/Settings/Url/Invalid=You must enter a valid https gallery address"))
    return
  end

  if (propertyTable.apiKey or "") == "" then
    setError(LOC("$$$/LrNoodle/Settings/ApiKey/Empty=You must enter an API key"))
    return
  end

  propertyTable.error = ""
  propertyTable.LR_cantExportBecause = LOC("$$$/LrNoodle/Settings/Checking=Checking connection to the gallery")

  ---@type PublishSettings
  local settings = { url = propertyTable.url, apiKey = propertyTable.apiKey }

  Utils.runAsync(logger, "verifySettings", function()
    local result = API.new(settings):checkConnection()

    if latestCheck[propertyTable] ~= check then
      logger:debug("Ignoring result of an outdated connection check for", settings.url)
      return
    end

    if Utils.isError(result) then
      setError(Utils.errorString(result))
    else
      setError(nil)
    end
  end)
end

--- Updates the properties the person tags section enables controls and shows
--- the warning with, since they depend on several settings.
---@param propertyTable table
local function updatePeopleSettings(propertyTable)
  propertyTable.includesPeople = Sidecar.includesPeople(propertyTable)
  propertyTable.peopleTagMissing = propertyTable.replacePeopleTags == true
    and string.match(propertyTable.peopleReplacementTag or "", "^%s*$") ~= nil
end

---@param propertyTable table
function Provider.startDialog(propertyTable)
  propertyTable.error = ""

  -- Defaults for new services.
  if not propertyTable.LR_editingExistingPublishConnection then
    propertyTable.LR_format = "JPEG"
    propertyTable.LR_jpeg_quality = 0.9

    propertyTable.LR_includeVideoFiles = true
    for _, preset in ipairs(LrExportSettings.videoExportPresets()) do
      if preset:formatID() == "h.264" and preset:name() == "High" then
        LrExportSettings.applyVideoExportPreset(propertyTable, preset)
        break
      end
    end
  end

  -- Identifies the assets this service uploads. It is only kept if the
  -- settings are saved.
  if (propertyTable.serviceId or "") == "" then
    propertyTable.serviceId = Utils.generateUuid()
  end

  if propertyTable.url and propertyTable.url ~= "" then
    propertyTable.apiKey = API.retrieveApiKey(propertyTable.url) or ""
  else
    propertyTable.apiKey = ""
  end

  verifySettings(propertyTable)

  propertyTable:addObserver("url", verifySettings)
  propertyTable:addObserver("apiKey", verifySettings)

  updatePeopleSettings(propertyTable)
  for _, key in ipairs({
    "LR_embeddedMetadataOption",
    "LR_removeFaceMetadata",
    "replacePeopleTags",
    "peopleReplacementTag",
  }) do
    propertyTable:addObserver(key, updatePeopleSettings)
  end
end

---@param propertyTable table
---@param why string
function Provider.endDialog(propertyTable, why)
  if why == "ok" and isValidUrl(propertyTable.url or "") then
    API.storeApiKey(propertyTable.url, propertyTable.apiKey or "")
  end
end

---@param f LrViewFactory
---@param propertyTable table
---@return table[]
function Provider.sectionsForTopOfDialog(f, propertyTable) -- luacheck: ignore propertyTable
  return {
    {
      title = LOC("$$$/LrNoodle/Settings/Title=Noodle Gallery"),

      synopsis = bind("url"),

      f:column({
        fill_horizontal = 1,
        spacing = f:control_spacing(),

        f:row({
          fill_horizontal = 1,
          spacing = f:label_spacing(),

          f:static_text({
            title = LOC("$$$/LrNoodle/Settings/Url/Label=Gallery address:"),
            alignment = "right",
            width = LrView.share("label_width"),
          }),

          f:edit_field({
            width_in_chars = 40,
            tooltip = LOC("$$$/LrNoodle/Settings/Url/Tooltip=The address of the gallery"),
            value = bind("url"),
          }),
        }),

        f:row({
          fill_horizontal = 1,
          spacing = f:label_spacing(),

          f:static_text({
            title = LOC("$$$/LrNoodle/Settings/ApiKey/Label=API key:"),
            alignment = "right",
            width = LrView.share("label_width"),
          }),

          f:password_field({
            width_in_chars = 40,
            tooltip = LOC("$$$/LrNoodle/Settings/ApiKey/Tooltip=An API key created in the gallery's account settings"),
            value = bind("apiKey"),
          }),
        }),

        -- Rows don't support visible, so a view wraps the row to hide.
        f:view({
          fill_horizontal = 1,
          visible = bind({
            key = "error",
            transform = function(value)
              return value ~= nil and value ~= ""
            end,
          }),

          f:row({
            fill_horizontal = 1,
            spacing = f:label_spacing(),

            f:spacer({
              width = LrView.share("label_width"),
            }),

            f:static_text({
              fill_horizontal = 1,
              text_color = LrColor(1, 0, 0),
              title = bind("error"),
              alignment = "left",
            }),
          }),
        }),
      }),
    },
  }
end

---@param f LrViewFactory
---@param propertyTable table
---@return table[]
function Provider.sectionsForBottomOfDialog(f, propertyTable) -- luacheck: ignore propertyTable
  return {
    {
      title = LOC("$$$/LrNoodle/Settings/People/Title=Person Tags"),

      f:column({
        fill_horizontal = 1,
        spacing = f:control_spacing(),

        f:checkbox({
          title = LOC(
            "$$$/LrNoodle/Settings/People/Replace=Leave people out of photo tags. Face regions still identify them."
          ),
          value = bind("replacePeopleTags"),
          enabled = bind("includesPeople"),
        }),

        -- Rows and columns don't support visible, so a view wraps the rows to hide.
        f:view({
          fill_horizontal = 1,
          visible = bind("replacePeopleTags"),

          f:column({
            fill_horizontal = 1,
            spacing = f:control_spacing(),

            f:row({
              fill_horizontal = 1,
              spacing = f:label_spacing(),

              f:static_text({
                title = LOC("$$$/LrNoodle/Settings/People/Tag/Label=Replacement tag:"),
                alignment = "right",
                width = LrView.share("label_width"),
              }),

              f:edit_field({
                width_in_chars = 40,
                immediate = true,
                enabled = bind("includesPeople"),
                tooltip = LOC(
                  "$$$/LrNoodle/Settings/People/Tag/Tooltip=Added to photos with people instead. Use / to nest tags."
                ),
                value = bind("peopleReplacementTag"),
              }),
            }),

            f:view({
              fill_horizontal = 1,
              visible = bind("peopleTagMissing"),

              f:row({
                fill_horizontal = 1,
                spacing = f:label_spacing(),

                f:spacer({
                  width = LrView.share("label_width"),
                }),

                f:static_text({
                  fill_horizontal = 1,
                  text_color = LrColor(1, 0, 0),
                  title = LOC(
                    "$$$/LrNoodle/Settings/People/Tag/Empty=Without one, photos with only people keep them as tags."
                  ),
                }),
              }),
            }),

            f:row({
              fill_horizontal = 1,
              spacing = f:label_spacing(),

              f:spacer({
                width = LrView.share("label_width"),
              }),

              f:checkbox({
                title = LOC("$$$/LrNoodle/Settings/People/Videos=Leave people out of video tags too"),
                value = bind("replacePeopleInVideos"),
                enabled = bind("includesPeople"),
              }),
            }),
          }),
        }),
      }),
    },
  }
end

return Provider
