-- Stand-ins for the catalog objects Lightroom passes to the publish service
-- provider: photos, published photos, collections, the publish service,
-- renditions and the export context.

local lr = require("lr_stubs")

local M = {}

function M.newKeyword(name, parent, includeOnExport, keywordType, synonyms)
  local keyword = {
    name = name,
    parent = parent,
    includeOnExport = includeOnExport ~= false,
    keywordType = keywordType,
    synonyms = synonyms or {},
  }

  function keyword:getName()
    return self.name
  end
  function keyword:getParent()
    return self.parent
  end
  function keyword:getAttributes()
    return { includeOnExport = self.includeOnExport, keywordType = self.keywordType }
  end
  function keyword:getSynonyms()
    return self.synonyms
  end

  return keyword
end

-- Raw metadata defaults to a capture time of 2001-01-01T00:00:00Z and a last
-- edit of 2001-01-02T01:00:00Z.
function M.newPhoto(id, metadata)
  local photo = {
    localIdentifier = id,
    metadata = metadata or { dateTimeOriginal = 0, lastEditTime = 90000 },
  }

  function photo:getRawMetadata(key)
    return self.metadata[key]
  end

  function photo:getFormattedMetadata(key)
    return (self.metadata.formatted or {})[key]
  end

  return photo
end

function M.newPublishedPhoto(photo, remoteId, edited)
  local published = { photo = photo, remoteId = remoteId, edited = edited or false }

  function published:getPhoto()
    return self.photo
  end
  function published:getRemoteId()
    return self.remoteId
  end
  function published:setRemoteId(id)
    self.remoteId = id
  end
  function published:setRemoteUrl(url)
    self.remoteUrl = url
  end
  function published:getEditedFlag()
    return self.edited
  end
  function published:setEditedFlag(edited)
    self.edited = edited
  end

  return published
end

function M.newCollection(id, name, remoteId, publishedPhotos)
  local collection = {
    localIdentifier = id,
    name = name,
    remoteId = remoteId,
    publishedPhotos = publishedPhotos or {},
  }

  function collection:getName()
    return self.name
  end
  function collection:getRemoteId()
    return self.remoteId
  end
  function collection:getPublishedPhotos()
    return self.publishedPhotos
  end
  function collection:getCollectionInfoSummary()
    return { isDefaultCollection = false, name = self.name }
  end
  function collection:getService()
    return self.service
  end

  return collection
end

function M.newService(collections)
  local service = { collections = collections }

  for _, collection in ipairs(collections) do
    collection.service = service
  end

  function service:getChildCollectionSets()
    return {}
  end
  function service:getChildCollections()
    return self.collections
  end

  return service
end

function M.newRendition(photo, publishedPhotoId)
  local rendition = {
    photo = photo,
    publishedPhotoId = publishedPhotoId,
    skipped = false,
    renderSuccess = true,
  }

  function rendition:skipRender()
    self.skipped = true
  end
  function rendition:waitForRender()
    if self.skipped then
      return false, "skipped"
    end
    if not self.renderSuccess then
      return false, "render failed"
    end
    return true, self.path or ("/tmp/render/photo" .. self.photo.localIdentifier .. ".jpg")
  end
  function rendition:recordPublishedPhotoId(id)
    self.recordedId = id
  end
  function rendition:recordPublishedPhotoUrl(url)
    self.recordedUrl = url
  end
  function rendition:uploadFailed(message)
    self.failure = message
  end

  return rendition
end

function M.newExportContext(service, collection, renditions, settings)
  local session = { renditionList = renditions }

  function session:countRenditions()
    return #self.renditionList
  end
  function session:renditions()
    return ipairs(self.renditionList)
  end
  function session:recordRemoteCollectionId(id)
    self.remoteCollectionId = id
  end
  function session:recordRemoteCollectionUrl(url)
    self.remoteCollectionUrl = url
  end

  local exportContext = {
    exportSession = session,
    propertyTable = settings,
    publishService = service,
    publishedCollection = collection,
  }

  function exportContext:configureProgress(params)
    return lr.newProgressScope(params)
  end
  function exportContext:startRendering()
    self.started = true
  end

  return exportContext
end

-- Marks a photo edited in every collection of the service, as Lightroom does
-- when the photo changes.
function M.editPhoto(service, photo)
  for _, collection in ipairs(service.collections) do
    for _, published in ipairs(collection.publishedPhotos) do
      if published.photo == photo and published.remoteId then
        published.edited = true
      end
    end
  end
end

-- Applies what the provider recorded during a publish, as Lightroom does once
-- the publish ends. The collection gets its recorded remote ID. Each photo
-- with a recorded ID gets that ID and URL and moves to published, so it is no
-- longer edited.
function M.applyPublish(exportContext)
  local session = exportContext.exportSession
  local collection = exportContext.publishedCollection

  if session.remoteCollectionId then
    collection.remoteId = session.remoteCollectionId
  end

  for _, rendition in ipairs(session.renditionList) do
    if rendition.recordedId then
      local published = nil
      for _, candidate in ipairs(collection.publishedPhotos) do
        if candidate.photo == rendition.photo then
          published = candidate
        end
      end

      if not published then
        published = M.newPublishedPhoto(rendition.photo)
        table.insert(collection.publishedPhotos, published)
      end

      published.remoteId = rendition.recordedId
      published.remoteUrl = rendition.recordedUrl
      published.edited = false
    end
  end
end

return M
