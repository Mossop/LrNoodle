local server = require("server")
local lr = require("lr_stubs")
local catalog = require("lr_catalog")
local Provider = require("Provider")
local Utils = require("Utils")

describe("Provider against a real server", function()
  -- Uses the API key with only the permissions the plugin needs.
  ---@type API
  local api
  -- Uses an API key with every permission, for setting up test data.
  ---@type API
  local setup

  -- Asserts that a result is not an error and returns it.
  local function ok(result)
    if Utils.isError(result) then
      error("Unexpected error: " .. Utils.errorString(result), 2)
    end
    return Utils.result(result)
  end

  ---@param ids string[]
  ---@return string[]
  local function sorted(ids)
    local copy = { unpack(ids) }
    table.sort(copy)
    return copy
  end

  -- Publish settings for the test server with any extra settings.
  local function publishSettings(extra)
    local settings = server.settings()
    for key, value in pairs(extra or {}) do
      settings[key] = value
    end
    return settings
  end

  -- Publishes the collection's new and edited photos like Lightroom does:
  -- renders each one to a new file, runs the provider and then applies what it
  -- recorded. Fails if any photo fails to publish.
  --
  -- options.files gives the rendered file for a photo by its local ID, which
  -- is otherwise a new unique photo. options.settings adds publish settings.
  local function publish(service, collection, options)
    options = options or {}
    local files = options.files or {}

    local renditions = {}
    for _, published in ipairs(collection.publishedPhotos) do
      if not published.remoteId or published.edited then
        local rendition = catalog.newRendition(published.photo, published.remoteId)
        rendition.path = files[published.photo.localIdentifier] or server.photo()
        table.insert(renditions, rendition)
      end
    end

    local exportContext = catalog.newExportContext(service, collection, renditions, publishSettings(options.settings))
    local success, message = lr.modules.LrFunctionContext.pcallWithContext("publish", function(context)
      Provider.processRenderedPhotos(context, exportContext)
    end)

    for _, rendition in ipairs(renditions) do
      os.remove(rendition.path)
    end

    assert(success, "Publishing failed: " .. tostring(message))
    for _, rendition in ipairs(renditions) do
      assert(not rendition.failure, "Photo failed to publish: " .. tostring(rendition.failure))
    end

    catalog.applyPublish(exportContext)
    return renditions
  end

  -- Removes published photos from a collection like Lightroom does, removing
  -- each from the collection once the provider reports it deleted.
  local function removePhotos(collection, publishedPhotos)
    local ids = {}
    for _, published in ipairs(publishedPhotos) do
      table.insert(ids, published.remoteId)
    end

    lr.catalog.getPublishedCollectionByLocalIdentifier = function(_, id)
      assert.equals(collection.localIdentifier, id)
      return collection
    end

    Provider.deletePhotosFromPublishedCollection(server.settings(), ids, function(id)
      for i, published in ipairs(collection.publishedPhotos) do
        if published.remoteId == id then
          table.remove(collection.publishedPhotos, i)
          return
        end
      end
    end, collection.localIdentifier)
  end

  -- Deletes a collection like Lightroom does.
  local function deleteCollection(service, collection)
    Provider.deletePublishedCollection(server.settings(), {
      publishService = service,
      publishedCollection = collection,
      name = collection.name,
      remoteId = collection.remoteId,
    })

    for i, candidate in ipairs(service.collections) do
      if candidate == collection then
        table.remove(service.collections, i)
      end
    end
  end

  -- The IDs of the albums an asset is in.
  ---@param assetId string
  ---@return string[]
  local function albumsFor(assetId)
    local ids = {}
    for _, album in ipairs(ok(api:getAlbumsForAsset(assetId))) do
      table.insert(ids, album.id)
    end
    return sorted(ids)
  end

  ---@param assetId string
  ---@return boolean
  local function isTrashed(assetId)
    return ok(api:getAsset(assetId)).isTrashed
  end

  ---@param name string
  ---@return string
  local function createSpace(name)
    return ok(setup:request("POST", "/shared-spaces", { name = name })).id
  end

  before_each(function()
    api, setup = server.reset()
  end)

  describe("publishing", function()
    it("replaces an edited photo with a new asset that keeps its details", function()
      local photo = catalog.newPhoto(1)
      local published = catalog.newPublishedPhoto(photo)
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      local service = catalog.newService({ collection })

      publish(service, collection)

      local oldId = published.remoteId
      assert.is_string(oldId)
      assert.is_string(collection.remoteId)
      assert.same({ collection.remoteId }, albumsFor(oldId))
      ok(setup:request("PUT", "/assets", { ids = { oldId }, isFavorite = true }))

      catalog.editPhoto(service, photo)
      publish(service, collection)

      local newId = published.remoteId
      assert.is_string(newId)
      assert.not_equals(oldId, newId)
      assert.is_false(published.edited)
      assert.equals(server.url .. "/photos/" .. newId, published.remoteUrl)
      assert.is_true(ok(api:getAsset(newId)).isFavorite)
      assert.same({ collection.remoteId }, albumsFor(newId))
      server.waitUntilDeleted(api, oldId)
    end)

    it("records the publish service and photo in uploaded assets", function()
      local photo = catalog.newPhoto(1)
      local published = catalog.newPublishedPhoto(photo)
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      local service = catalog.newService({ collection })

      publish(service, collection)

      local metadata = ok(api:request("GET", "/assets/" .. published.remoteId .. "/metadata/LrNoodle"))
      assert.equals("LrNoodle", metadata.key)
      assert.same({ publishService = server.settings().serviceId, photoUuid = "uuid-1" }, metadata.value)
    end)

    it("uses one asset for a photo in two collections", function()
      local photo = catalog.newPhoto(1)
      local first = catalog.newPublishedPhoto(photo)
      local second = catalog.newPublishedPhoto(photo)
      local firstCollection = catalog.newCollection(1, "First", nil, { first })
      local secondCollection = catalog.newCollection(2, "Second", nil, { second })
      local service = catalog.newService({ firstCollection, secondCollection })

      publish(service, firstCollection)
      local renditions = publish(service, secondCollection)

      local oldId = first.remoteId
      assert.equals(oldId, second.remoteId)
      assert.is_true(renditions[1].skipped)
      assert.same(sorted({ firstCollection.remoteId, secondCollection.remoteId }), albumsFor(oldId))

      -- Republishing one copy replaces the asset and points the other at it.
      catalog.editPhoto(service, photo)
      publish(service, firstCollection)

      local newId = first.remoteId
      assert.not_equals(oldId, newId)
      assert.equals(newId, second.remoteId)
      assert.is_true(second.edited)
      server.waitUntilDeleted(api, oldId)

      renditions = publish(service, secondCollection)

      assert.is_true(renditions[1].skipped)
      assert.equals(newId, second.remoteId)
      assert.is_false(second.edited)
      assert.same(sorted({ firstCollection.remoteId, secondCollection.remoteId }), albumsFor(newId))
    end)

    it("uses an identical asset already on the server as it is", function()
      local photo = catalog.newPhoto(1)
      local published = catalog.newPublishedPhoto(photo)
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      local service = catalog.newService({ collection })

      publish(service, collection)
      local oldId = published.remoteId
      ok(setup:request("PUT", "/assets", { ids = { oldId }, isFavorite = true }))

      -- The same file uploaded some other way, e.g. from a phone.
      local file = server.photo()
      local existing = ok(setup:uploadAsset(file, "phone.jpg", { created = 0, modified = 0 }))
      assert.equals("created", existing.status)

      catalog.editPhoto(service, photo)
      publish(service, collection, { files = { [1] = file } })

      assert.equals(existing.id, published.remoteId)
      assert.same({ collection.remoteId }, albumsFor(existing.id))
      -- Nothing is copied over the existing asset.
      assert.is_false(ok(api:getAsset(existing.id)).isFavorite)
      server.waitUntilDeleted(api, oldId)
    end)

    it("replaces an identical asset already on the server once the photo changes", function()
      -- The same file uploaded some other way, e.g. from a phone.
      local file = server.photo()
      local existing = ok(setup:uploadAsset(file, "phone.jpg", { created = 0, modified = 0 }))
      assert.equals("created", existing.status)
      ok(setup:request("PUT", "/assets", { ids = { existing.id }, isFavorite = true }))

      local photo = catalog.newPhoto(1)
      local published = catalog.newPublishedPhoto(photo)
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      local service = catalog.newService({ collection })

      publish(service, collection, { files = { [1] = file } })

      assert.equals(existing.id, published.remoteId)
      assert.same({ collection.remoteId }, albumsFor(existing.id))

      catalog.editPhoto(service, photo)
      publish(service, collection)

      -- The existing asset is treated like one the plugin uploaded: its details
      -- are copied to the new asset and it is permanently deleted.
      local newId = published.remoteId
      assert.not_equals(existing.id, newId)
      assert.is_true(ok(api:getAsset(newId)).isFavorite)
      assert.same({ collection.remoteId }, albumsFor(newId))
      server.waitUntilDeleted(api, existing.id)
    end)

    it("recreates an album deleted on the server", function()
      local first = catalog.newPublishedPhoto(catalog.newPhoto(1))
      local collection = catalog.newCollection(1, "Holiday", nil, { first })
      local service = catalog.newService({ collection })

      publish(service, collection)
      local oldAlbum = collection.remoteId
      ok(setup:deleteAlbum(oldAlbum))

      local second = catalog.newPublishedPhoto(catalog.newPhoto(2))
      table.insert(collection.publishedPhotos, second)
      publish(service, collection)

      assert.is_string(collection.remoteId)
      assert.not_equals(oldAlbum, collection.remoteId)
      assert.same({ collection.remoteId }, albumsFor(first.remoteId))
      assert.same({ collection.remoteId }, albumsFor(second.remoteId))
    end)

    it("restores a trashed asset rather than uploading again", function()
      local photo = catalog.newPhoto(1)
      local first = catalog.newPublishedPhoto(photo)
      local firstCollection = catalog.newCollection(1, "First", nil, { first })
      local secondCollection = catalog.newCollection(2, "Second", nil, {})
      local service = catalog.newService({ firstCollection, secondCollection })

      publish(service, firstCollection)
      local id = first.remoteId
      ok(setup:deleteAssets({ id }))
      assert.is_true(isTrashed(id))

      local second = catalog.newPublishedPhoto(photo)
      table.insert(secondCollection.publishedPhotos, second)
      local renditions = publish(service, secondCollection)

      assert.is_true(renditions[1].skipped)
      assert.equals(id, second.remoteId)
      assert.is_false(isTrashed(id))
      assert.same(sorted({ firstCollection.remoteId, secondCollection.remoteId }), albumsFor(id))
    end)

    it("adds a replacement to the shared spaces the old asset was in", function()
      local photo = catalog.newPhoto(1)
      local published = catalog.newPublishedPhoto(photo)
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      local service = catalog.newService({ collection })

      publish(service, collection)
      local oldId = published.remoteId

      local direct = createSpace("Direct")
      ok(setup:addAssetsToSpace(direct, { oldId }))
      local linked = createSpace("Linked")
      ok(setup:request("PUT", "/shared-spaces/" .. linked .. "/albums/" .. collection.remoteId))

      catalog.editPhoto(service, photo)
      publish(service, collection)

      local newId = published.remoteId
      assert.not_equals(oldId, newId)
      assert.same(sorted({ direct, linked }), sorted(ok(api:getAssetSpaces({ newId }))[newId]))
      server.waitUntilDeleted(api, oldId)
    end)

    it("uploads videos with their metadata in a sidecar", function()
      local places = catalog.newKeyword("Places")
      local france = catalog.newKeyword("France", places)
      local photo = catalog.newPhoto(1, {
        isVideo = true,
        -- 2001-01-02T01:00:00Z
        dateTimeOriginal = 90000,
        lastEditTime = 90000,
        rating = 4,
        gps = { latitude = 48.8584, longitude = -2.2945 },
        keywords = { catalog.newKeyword("Paris", france) },
        formatted = { caption = "A tall tower", keywordTagsForExport = "Paris, France, Places" },
      })
      local published = catalog.newPublishedPhoto(photo)
      local collection = catalog.newCollection(1, "Videos", nil, { published })
      local service = catalog.newService({ collection })

      local video = server.video()
      publish(service, collection, {
        files = { [1] = video },
        settings = { LR_metadata_keywordOptions = "lightroomHierarchical" },
      })

      local file = io.open(video .. ".xmp")
      assert.is_nil(file, "The sidecar was not deleted")

      -- The server reads the sidecar in the background.
      local asset
      for _ = 1, 50 do
        asset = ok(api:getAsset(published.remoteId))
        if asset.exifInfo and asset.exifInfo.rating and asset.tags and #asset.tags > 0 then
          break
        end
        os.execute("sleep 0.2")
      end

      assert.equals("VIDEO", asset.type)
      assert.equals(4, asset.exifInfo.rating)
      assert.equals("A tall tower", asset.exifInfo.description)
      assert.equals("2001-01-02T01:00:00+00:00", asset.exifInfo.dateTimeOriginal)
      assert.equals(48.8584, asset.exifInfo.latitude)
      assert.equals(-2.2945, asset.exifInfo.longitude)

      local tags = {}
      for _, tag in ipairs(asset.tags or {}) do
        table.insert(tags, tag.value)
      end
      assert.same(sorted({ "France", "Paris", "Places", "Places/France/Paris" }), sorted(tags))
    end)
  end)

  describe("person tags", function()
    -- Matches the keywords and face region embedded in the people fixture.
    local function photoWithPeople()
      return catalog.newPhoto(1, {
        dateTimeOriginal = 0,
        lastEditTime = 90000,
        keywords = {
          catalog.newKeyword("Alice Example", catalog.newKeyword("People"), true, "person"),
          catalog.newKeyword("bike"),
        },
        formatted = { keywordTagsForExport = "Alice Example, People, bike" },
      })
    end

    -- Sets whether the server creates people from face regions. The config is
    -- edited as text since decoding and encoding it again turns its empty
    -- arrays into objects, which the server rejects.
    ---@param faces boolean
    local function importFaces(faces)
      local http = require("curl_http")
      local url = setup.apiUrl .. "/system-config"
      local headers = {
        { field = "x-api-key", value = setup.apiKey },
        { field = "Content-Type", value = "application/json" },
      }

      local config = http.get(url, headers)
      local changed, count = string.gsub(config, '"faces":{"import":%a+}', '"faces":{"import":' .. tostring(faces) .. "}")
      assert.equals(1, count)

      local _, response = http.post(url, changed, headers, "PUT")
      assert.equals(200, response.status)
    end

    -- Waits for the server to read the asset's tags and people, then returns
    -- their names.
    ---@param assetId string
    ---@return string[], string[]
    local function tagsAndPeople(assetId)
      local asset = server.waitFor("the tags and people of " .. assetId, function()
        local asset = ok(api:getAsset(assetId))
        if asset.tags and #asset.tags > 0 and asset.people and #asset.people > 0 then
          return asset
        end
      end)

      local tags = {}
      for _, tag in ipairs(asset.tags) do
        table.insert(tags, tag.value)
      end
      local people = {}
      for _, person in ipairs(asset.people) do
        table.insert(people, person.name)
      end
      return sorted(tags), sorted(people)
    end

    before_each(function()
      importFaces(true)
    end)

    after_each(function()
      importFaces(false)
    end)

    it("are kept unless asked to replace them", function()
      local published = catalog.newPublishedPhoto(photoWithPeople())
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      local service = catalog.newService({ collection })

      publish(service, collection, {
        files = { [1] = server.photo("people") },
        settings = { peopleReplacementTag = "Has people" },
      })

      local tags, people = tagsAndPeople(published.remoteId)
      assert.same({ "Alice Example", "People", "bike" }, tags)
      assert.same({ "Alice Example" }, people)
    end)

    it("are replaced when uploading a photo", function()
      local published = catalog.newPublishedPhoto(photoWithPeople())
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      local service = catalog.newService({ collection })

      publish(service, collection, {
        files = { [1] = server.photo("people") },
        settings = { replacePeopleTags = true, peopleReplacementTag = "Has people" },
      })

      local tags, people = tagsAndPeople(published.remoteId)
      assert.same({ "Has people", "bike" }, tags)
      assert.same({ "Alice Example" }, people)
    end)

    it("are replaced when replacing a photo", function()
      local photo = photoWithPeople()
      local published = catalog.newPublishedPhoto(photo)
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      local service = catalog.newService({ collection })

      publish(service, collection, {
        files = { [1] = server.photo("people") },
        settings = { replacePeopleTags = true, peopleReplacementTag = "Has people" },
      })
      local oldId = published.remoteId
      tagsAndPeople(oldId)

      catalog.editPhoto(service, photo)
      publish(service, collection, {
        files = { [1] = server.photo("people") },
        settings = { replacePeopleTags = true, peopleReplacementTag = "Family" },
      })

      local newId = published.remoteId
      assert.not_equals(oldId, newId)
      local tags, people = tagsAndPeople(newId)
      -- Nothing from the old asset's tags is kept.
      assert.same({ "Family", "bike" }, tags)
      assert.same({ "Alice Example" }, people)
      server.waitUntilDeleted(api, oldId)
    end)
  end)

  describe("removing photos", function()
    it("trashes the asset of a photo used nowhere else", function()
      local published = catalog.newPublishedPhoto(catalog.newPhoto(1))
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      catalog.newService({ collection })

      publish(collection.service, collection)
      local id = published.remoteId
      removePhotos(collection, { published })

      assert.equals(0, #collection.publishedPhotos)
      assert.same({}, albumsFor(id))
      assert.is_true(isTrashed(id))
    end)

    it("keeps the asset of a photo published in another collection", function()
      local photo = catalog.newPhoto(1)
      local first = catalog.newPublishedPhoto(photo)
      local second = catalog.newPublishedPhoto(photo)
      local firstCollection = catalog.newCollection(1, "First", nil, { first })
      local secondCollection = catalog.newCollection(2, "Second", nil, { second })
      local service = catalog.newService({ firstCollection, secondCollection })

      publish(service, firstCollection)
      publish(service, secondCollection)
      local id = first.remoteId
      removePhotos(firstCollection, { first })

      assert.same({ secondCollection.remoteId }, albumsFor(id))
      assert.is_false(isTrashed(id))
    end)

    it("keeps the asset of a photo in an album not published from Lightroom", function()
      local published = catalog.newPublishedPhoto(catalog.newPhoto(1))
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      catalog.newService({ collection })

      publish(collection.service, collection)
      local id = published.remoteId
      local album = ok(setup:createAlbum("Made in the gallery"))
      ok(setup:addAssetsToAlbum(album.id, { id }))

      removePhotos(collection, { published })

      assert.same({ album.id }, albumsFor(id))
      assert.is_false(isTrashed(id))
    end)

    it("keeps the asset of a photo in a shared space", function()
      local published = catalog.newPublishedPhoto(catalog.newPhoto(1))
      local collection = catalog.newCollection(1, "Holiday", nil, { published })
      catalog.newService({ collection })

      publish(collection.service, collection)
      local id = published.remoteId
      ok(setup:addAssetsToSpace(createSpace("Family"), { id }))

      removePhotos(collection, { published })

      assert.same({}, albumsFor(id))
      assert.is_false(isTrashed(id))
    end)
  end)

  describe("deleting collections", function()
    it("deletes the album and trashes assets used nowhere else", function()
      local shared = catalog.newPhoto(1)
      local orphan = catalog.newPublishedPhoto(catalog.newPhoto(2))
      local kept = catalog.newPublishedPhoto(shared)
      local collection = catalog.newCollection(1, "Holiday", nil, { orphan, kept })
      local other = catalog.newCollection(2, "Other", nil, { catalog.newPublishedPhoto(shared) })
      local service = catalog.newService({ collection, other })

      publish(service, collection)
      publish(service, other)
      local albumId = collection.remoteId

      deleteCollection(service, collection)

      assert.equals("notFound", Utils.error(api:getAlbum(albumId)).code)
      assert.is_true(isTrashed(orphan.remoteId))
      assert.is_false(isTrashed(kept.remoteId))
      assert.same({ other.remoteId }, albumsFor(kept.remoteId))
    end)
  end)
end)
