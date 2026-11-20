local lr = require("lr_stubs")
local catalog = require("lr_catalog")
local json = require("json")
local Provider = require("Provider")

local settings = { url = "https://gallery.example.com", apiKey = "secret" }

local function newPropertyTable(values)
  local properties = { observers = {} }
  for k, v in pairs(values) do
    properties[k] = v
  end

  function properties:addObserver(key, func)
    self.observers[key] = func
  end

  return properties
end

local newPhoto = catalog.newPhoto
local newPublishedPhoto = catalog.newPublishedPhoto
local newCollection = catalog.newCollection
local newService = catalog.newService
local newRendition = catalog.newRendition

local function newExportContext(service, collection, renditions)
  return catalog.newExportContext(service, collection, renditions, settings)
end

local function publish(exportContext)
  lr.modules.LrFunctionContext.pcallWithContext("test", function(context)
    Provider.processRenderedPhotos(context, exportContext)
  end)
end

local function calls()
  local result = {}
  for _, request in ipairs(lr.http.requests) do
    local path = request.url:gsub("^https://gallery.example.com/api", "")
    table.insert(result, request.method .. " " .. path)
  end
  return result
end

local function requestBody(index)
  return json.decode(lr.http.requests[index].body)
end

-- Finds a multipart chunk in a recorded request.
local function chunk(index, name)
  for _, c in ipairs(lr.http.requests[index].chunks) do
    if c.name == name then
      return c
    end
  end
  return nil
end

-- Responds to the check that the collection's album exists.
local function albumExists()
  lr.respondJson(200, { id = "album", albumName = "Holiday" })
end

-- Responds to a shared spaces lookup finding no spaces.
local function noSpaces()
  lr.respondJson(200, { assets = {} })
end

describe("Provider", function()
  before_each(function()
    lr.reset()
  end)

  it("allows the default collection to be deleted", function()
    local info = Provider.getCollectionBehaviorInfo(settings)
    assert.is_true(info.defaultCollectionCanBeDeleted)
    assert.is_true(info.canAddCollection)
    assert.are.equal("Photos", info.defaultCollectionName)
  end)

  describe("settings", function()
    before_each(function()
      lr.passwords["apiKey:https://gallery.example.com"] = "secret"
    end)

    it("rejects an invalid url", function()
      local properties = newPropertyTable({ url = "gallery" })
      Provider.startDialog(properties)

      assert.are.equal("You must enter a valid https gallery address", properties.LR_cantExportBecause)
      assert.are.equal(properties.LR_cantExportBecause, properties.error)
      assert.are.equal(0, #lr.http.requests)
    end)

    it("rejects an http url", function()
      local properties = newPropertyTable({ url = "http://gallery.example.com" })
      Provider.startDialog(properties)

      assert.are.equal("You must enter a valid https gallery address", properties.LR_cantExportBecause)
      assert.are.equal(0, #lr.http.requests)
    end)

    it("requires an api key", function()
      lr.passwords = {}
      local properties = newPropertyTable({ url = "https://gallery.example.com" })
      Provider.startDialog(properties)

      assert.are.equal("", properties.apiKey)
      assert.are.equal("You must enter an API key", properties.LR_cantExportBecause)
      assert.are.equal(0, #lr.http.requests)
    end)

    it("loads the stored api key and accepts working settings", function()
      lr.respondJson(200, { id = "user" })

      local properties = newPropertyTable({ url = "https://gallery.example.com" })
      Provider.startDialog(properties)

      assert.are.equal("secret", properties.apiKey)
      assert.is_nil(properties.LR_cantExportBecause)
      assert.are.equal("", properties.error)
      assert.are.equal("https://gallery.example.com/api/users/me", lr.http.requests[1].url)
      assert.are.equal("secret", lr.header(lr.http.requests[1], "x-api-key"))
    end)

    it("reports connection errors", function()
      lr.respond({ status = 401 })

      local properties = newPropertyTable({ url = "https://gallery.example.com" })
      Provider.startDialog(properties)

      assert.are.equal("The API key was rejected by the gallery.", properties.LR_cantExportBecause)
      assert.are.equal(properties.LR_cantExportBecause, properties.error)
    end)

    it("enables the person tag settings only when people are exported", function()
      local properties = newPropertyTable({ url = "gallery" })
      Provider.startDialog(properties)
      assert.is_true(properties.includesPeople)

      properties.LR_removeFaceMetadata = true
      properties.observers.LR_removeFaceMetadata(properties)
      assert.is_false(properties.includesPeople)

      properties.LR_removeFaceMetadata = false
      properties.LR_embeddedMetadataOption = "copyrightOnly"
      properties.observers.LR_embeddedMetadataOption(properties)
      assert.is_false(properties.includesPeople)
    end)

    it("warns about a missing replacement tag only when replacing people", function()
      local properties = newPropertyTable({ url = "gallery", peopleReplacementTag = "" })
      Provider.startDialog(properties)
      assert.is_false(properties.peopleTagMissing)

      properties.replacePeopleTags = true
      properties.observers.replacePeopleTags(properties)
      assert.is_true(properties.peopleTagMissing)

      properties.peopleReplacementTag = "  "
      properties.observers.peopleReplacementTag(properties)
      assert.is_true(properties.peopleTagMissing)

      properties.peopleReplacementTag = "Has people"
      properties.observers.peopleReplacementTag(properties)
      assert.is_false(properties.peopleTagMissing)
    end)

    it("rechecks when settings change", function()
      lr.respond({ status = 401 })
      local properties = newPropertyTable({ url = "https://gallery.example.com" })
      Provider.startDialog(properties)

      lr.respondJson(200, { id = "user" })
      properties.apiKey = "better"
      properties.observers.apiKey(properties)

      assert.is_nil(properties.LR_cantExportBecause)
      assert.are.equal("better", lr.header(lr.http.requests[2], "x-api-key"))
    end)

    it("ignores results from outdated checks", function()
      -- Hold the async checks so they can be completed out of order.
      local tasks = {}
      lr.modules.LrFunctionContext.postAsyncTaskWithContext = function(_, func)
        table.insert(tasks, func)
      end

      local properties = newPropertyTable({ url = "https://gallery.example.com" })
      Provider.startDialog(properties)

      properties.apiKey = "better"
      properties.observers.apiKey(properties)

      local function run(task)
        lr.modules.LrFunctionContext.pcallWithContext("task", task)
      end

      -- The newer check finishes first and succeeds.
      lr.respondJson(200, { id = "user" })
      run(tasks[2])
      assert.is_nil(properties.LR_cantExportBecause)

      -- The older check finishes last and fails, but is ignored.
      lr.respond({ status = 401 })
      run(tasks[1])
      assert.is_nil(properties.LR_cantExportBecause)
      assert.are.equal("", properties.error)
    end)

    it("stores the api key when the dialog is accepted", function()
      local properties = newPropertyTable({ url = "https://other.example.com/", apiKey = "newkey" })

      Provider.endDialog(properties, "cancel")
      assert.is_nil(lr.passwords["apiKey:https://other.example.com"])

      Provider.endDialog(properties, "ok")
      assert.are.equal("newkey", lr.passwords["apiKey:https://other.example.com"])
    end)

    it("supports video", function()
      assert.is_true(Provider.canExportVideo)
    end)

    it("has an icon that exists", function()
      assert.are.equal("icon.png", Provider.small_icon)
      local file = io.open("LrNoodle.lrdevplugin/" .. Provider.small_icon, "rb")
      assert.is_truthy(file)
      if file then
        file:close()
      end
    end)

    it("defaults new services to JPEG at 90% and h.264 High video", function()
      local properties = newPropertyTable({ url = "https://gallery.example.com" })
      lr.respondJson(200, { id = "user" })
      Provider.startDialog(properties)

      assert.are.equal("JPEG", properties.LR_format)
      assert.are.equal(0.9, properties.LR_jpeg_quality)
      assert.is_true(properties.LR_includeVideoFiles)
      assert.are.same({ format = "h.264", name = "High" }, properties.LR_videoPreset)
    end)

    it("leaves the format settings alone when editing a service", function()
      local properties = newPropertyTable({
        url = "https://gallery.example.com",
        LR_editingExistingPublishConnection = true,
        LR_format = "PNG",
        LR_jpeg_quality = 0.5,
        LR_includeVideoFiles = false,
      })
      lr.respondJson(200, { id = "user" })
      Provider.startDialog(properties)

      assert.are.equal("PNG", properties.LR_format)
      assert.are.equal(0.5, properties.LR_jpeg_quality)
      assert.is_false(properties.LR_includeVideoFiles)
      assert.is_nil(properties.LR_videoPreset)
    end)

    it("doesn't keep the api key in the settings", function()
      for _, field in ipairs(Provider.exportPresetFields) do
        assert.are_not.equal("apiKey", field.key)
      end
    end)
  end)

  describe("renamePublishedCollection", function()
    it("renames the album", function()
      lr.respondJson(200, { id = "album", albumName = "New" })

      Provider.renamePublishedCollection(settings, { remoteId = "album", name = "New" })

      local request = lr.http.requests[1]
      assert.are.equal("PATCH", request.method)
      assert.are.equal("https://gallery.example.com/api/albums/album", request.url)
      assert.are.same({ albumName = "New" }, json.decode(request.body))
    end)

    it("does nothing when there is no album yet", function()
      Provider.renamePublishedCollection(settings, { name = "New" })
      assert.are.equal(0, #lr.http.requests)
    end)

    it("ignores an album missing from the server", function()
      lr.respond({ status = 404 })

      Provider.renamePublishedCollection(settings, { remoteId = "album", name = "New" })

      assert.are.equal(1, #lr.http.requests)
    end)

    it("throws on failure so Lightroom reverts", function()
      lr.respond({ status = 500 })

      assert.has_error(function()
        Provider.renamePublishedCollection(settings, { remoteId = "album", name = "New" })
      end, "The gallery returned an error: 500")
    end)
  end)

  describe("processRenderedPhotos", function()
    it("creates the album and uploads new photos", function()
      local photo = newPhoto(1)
      local collection = newCollection(10, "Holiday", nil)
      local rendition = newRendition(photo, nil)
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      lr.respondJson(201, { id = "album", albumName = "Holiday" })
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.same({ "POST /albums", "MULTIPART /assets", "PUT /albums/album/assets" }, calls())
      assert.are.same({ albumName = "Holiday" }, requestBody(1))
      assert.are.equal("/tmp/render/photo1.jpg", chunk(2, "assetData").filePath)
      assert.are.equal("photo1.jpg", chunk(2, "assetData").fileName)
      assert.are.equal("2001-01-01T00:00:00Z", chunk(2, "fileCreatedAt").value)
      assert.are.equal("2001-01-02T01:00:00Z", chunk(2, "fileModifiedAt").value)
      assert.is_nil(chunk(2, "sidecarData"))
      assert.are.same({ ids = { "asset" } }, requestBody(3))

      assert.are.equal("album", exportContext.exportSession.remoteCollectionId)
      assert.are.equal("https://gallery.example.com/albums/album", exportContext.exportSession.remoteCollectionUrl)
      assert.is_true(exportContext.started)
      assert.is_false(rendition.skipped)
      assert.are.equal("asset", rendition.recordedId)
      assert.are.equal("https://gallery.example.com/photos/asset", rendition.recordedUrl)
      assert.is_nil(rendition.failure)
    end)

    describe("sidecars", function()
      local render

      -- A video rendition rendered to a real file so the sidecar can be
      -- written next to it.
      local function newVideo(metadata, publishedPhotoId)
        metadata.isVideo = true
        local rendition = newRendition(newPhoto(1, metadata), publishedPhotoId)
        render = os.tmpname()
        function rendition:waitForRender()
          return true, render
        end
        return rendition
      end

      -- The same for a photo.
      local function newImage(metadata)
        local rendition = newVideo(metadata)
        metadata.isVideo = false
        return rendition
      end

      local function contextFor(rendition, metadataSettings)
        local collection = newCollection(10, "Holiday", "album")
        local exportContext = newExportContext(newService({ collection }), collection, { rendition })
        local properties = { url = settings.url, apiKey = settings.apiKey }
        for k, v in pairs(metadataSettings) do
          properties[k] = v
        end
        exportContext.propertyTable = properties
        return exportContext
      end

      after_each(function()
        os.remove(render)
        os.remove(render .. ".xmp")
      end)

      it("uploads videos with a sidecar of their metadata", function()
        local rendition = newVideo({ dateTimeOriginal = 0, rating = 3, formatted = { caption = "Waves" } })
        local exportContext = contextFor(rendition, { LR_embeddedMetadataOption = "all" })

        albumExists()
        lr.respondJson(201, { id = "asset", status = "created" })
        lr.respondJson(200, { { id = "asset", success = true } })

        publish(exportContext)

        local sidecar = chunk(2, "sidecarData")
        assert.are.equal(render .. ".xmp", sidecar.filePath)
        assert.is_truthy(string.find(sidecar.content, "<xmp:Rating>3</xmp:Rating>", 1, true))
        assert.is_truthy(string.find(sidecar.content, "Waves", 1, true))
        assert.is_truthy(
          string.find(sidecar.content, "<exif:DateTimeOriginal>2001-01-01T00:00:00Z</exif:DateTimeOriginal>", 1, true)
        )
        assert.are.equal("asset", rendition.recordedId)

        -- The sidecar is removed once uploaded.
        assert.is_nil(io.open(render .. ".xmp", "r"))
      end)

      it("uploads a sidecar when replacing a video without copying the old one", function()
        local rendition = newVideo({ rating = 2 }, "old")
        local exportContext = contextFor(rendition, {})

        albumExists()
        lr.respondJson(200, { id = "old", isTrashed = false })
        lr.respondJson(201, { id = "new", status = "created" })
        lr.respondJson(200, { id = "old" })
        lr.respond({ status = 204 })
        noSpaces()
        lr.respondJson(200, { { id = "new", success = true } })
        lr.respond({ status = 204 })

        publish(exportContext)

        assert.is_truthy(string.find(chunk(3, "sidecarData").content, "<xmp:Rating>2</xmp:Rating>", 1, true))
        assert.are.same({ sourceId = "old", targetId = "new", sidecar = false }, requestBody(5))
        assert.are.equal("new", rendition.recordedId)
      end)

      it("uploads photos with people with a sidecar of their tags", function()
        local rendition = newImage({
          keywords = { catalog.newKeyword("Alice", nil, true, "person"), catalog.newKeyword("bike") },
          formatted = { keywordTagsForExport = "Alice, bike" },
        })
        local exportContext = contextFor(rendition, { replacePeopleTags = true, peopleReplacementTag = "Has people" })

        albumExists()
        lr.respondJson(201, { id = "asset", status = "created" })
        lr.respondJson(200, { { id = "asset", success = true } })

        publish(exportContext)

        local sidecar = chunk(2, "sidecarData")
        assert.are.equal(render .. ".xmp", sidecar.filePath)
        assert.is_truthy(string.find(sidecar.content, "<digiKam:TagsList>", 1, true))
        assert.is_truthy(string.find(sidecar.content, "<rdf:li>Has people</rdf:li>", 1, true))
        assert.is_falsy(string.find(sidecar.content, "Alice", 1, true))
        assert.are.equal("asset", rendition.recordedId)
        assert.is_nil(io.open(render .. ".xmp", "r"))
      end)

      it("doesn't upload a sidecar when the settings exclude the metadata", function()
        local rendition = newVideo({ rating = 3 })
        local exportContext = contextFor(rendition, { LR_embeddedMetadataOption = "copyrightOnly" })

        albumExists()
        lr.respondJson(201, { id = "asset", status = "created" })
        lr.respondJson(200, { { id = "asset", success = true } })

        publish(exportContext)

        assert.is_nil(chunk(2, "sidecarData"))
        assert.are.equal("asset", rendition.recordedId)
      end)
    end)

    it("falls back through the photo's dates", function()
      local photo = newPhoto(1, { dateTimeDigitized = 3600 })
      local collection = newCollection(10, "Holiday", "album")
      local exportContext = newExportContext(newService({ collection }), collection, { newRendition(photo, nil) })

      albumExists()
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.equal("2001-01-01T01:00:00Z", chunk(2, "fileCreatedAt").value)
      assert.are.equal("2001-01-01T01:00:00Z", chunk(2, "fileModifiedAt").value)
    end)

    it("uses an existing album", function()
      local collection = newCollection(10, "Holiday", "album")
      local exportContext = newExportContext(newService({ collection }), collection, { newRendition(newPhoto(1), nil) })

      albumExists()
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.same({ "GET /albums/album", "MULTIPART /assets", "PUT /albums/album/assets" }, calls())
      assert.is_nil(exportContext.exportSession.remoteCollectionId)
    end)

    it("recreates an album missing from the server with its unedited photos", function()
      local missing = newPublishedPhoto(newPhoto(5), "missing", false)
      local edited = newPublishedPhoto(newPhoto(3), "edited", true)
      local collection = newCollection(10, "Holiday", "gone", {
        newPublishedPhoto(newPhoto(2), "unedited", false),
        edited,
        newPublishedPhoto(newPhoto(4), nil, false),
        missing,
      })
      local exportContext = newExportContext(newService({ collection }), collection, { newRendition(newPhoto(1), nil) })

      lr.respond({ status = 404 })
      lr.respondJson(201, { id = "album", albumName = "Holiday" })
      lr.respondJson(200, {
        { id = "unedited", success = true },
        { id = "missing", success = false, error = "not_found" },
      })
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.same({
        "GET /albums/gone",
        "POST /albums",
        "PUT /albums/album/assets",
        "MULTIPART /assets",
        "PUT /albums/album/assets",
      }, calls())
      assert.are.same({ albumName = "Holiday" }, requestBody(2))
      assert.are.same({ ids = { "unedited", "missing" } }, requestBody(3))
      assert.are.equal("album", exportContext.exportSession.remoteCollectionId)

      -- The rejected photo is republished next time.
      assert.is_true(missing.edited)
      assert.are.same({ "Update Published Photos" }, lr.catalog.writeActions)
    end)

    it("marks every photo edited when restoring a recreated album fails", function()
      local published = newPublishedPhoto(newPhoto(2), "unedited", false)
      local collection = newCollection(10, "Holiday", "gone", { published })
      local exportContext = newExportContext(newService({ collection }), collection, { newRendition(newPhoto(1), nil) })

      lr.respond({ status = 404 })
      lr.respondJson(201, { id = "album", albumName = "Holiday" })
      lr.respond({ status = 400, body = json.encode({ message = "Bad request" }) })
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.is_true(published.edited)
      assert.are.equal("album", exportContext.exportSession.remoteCollectionId)
    end)

    it("creates a new album without photos", function()
      local collection = newCollection(10, "Holiday", nil, {
        newPublishedPhoto(newPhoto(2), nil, false),
      })
      local exportContext = newExportContext(newService({ collection }), collection, { newRendition(newPhoto(1), nil) })

      lr.respondJson(201, { id = "album", albumName = "Holiday" })
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.same({ albumName = "Holiday" }, requestBody(1))
    end)

    it("reuses an unedited asset from another collection without uploading", function()
      local photo = newPhoto(1)
      local other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(photo, "asset", false) })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, nil)
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "asset", isTrashed = false })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.same({ "GET /albums/album", "GET /assets/asset", "PUT /albums/album/assets" }, calls())
      assert.are.same({ ids = { "asset" } }, requestBody(3))
      assert.is_true(rendition.skipped)
      assert.are.equal("asset", rendition.recordedId)
      assert.are.same({}, lr.catalog.writeActions)
    end)

    it("restores a trashed asset before reusing it", function()
      local photo = newPhoto(1)
      local other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(photo, "asset", false) })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, nil)
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "asset", isTrashed = true })
      lr.respond({ status = 204 })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.same(
        { "GET /albums/album", "GET /assets/asset", "POST /trash/restore/assets", "PUT /albums/album/assets" },
        calls()
      )
      assert.are.same({ ids = { "asset" } }, requestBody(3))
      assert.is_true(rendition.skipped)
      assert.are.equal("asset", rendition.recordedId)
    end)

    it("prefers the unedited copy's asset and deletes this collection's previous asset", function()
      local photo = newPhoto(1)
      local otherPublished = newPublishedPhoto(photo, "current", false)
      local other = newCollection(11, "Other", "otherAlbum", { otherPublished })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, "previous")
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "current", isTrashed = false })
      lr.respondJson(200, { { id = "current", success = false, error = "duplicate" } })
      lr.respondJson(200, { id = "previous", isTrashed = false })
      noSpaces()
      lr.respondJson(200, { { id = "album", albumName = "Holiday" } })
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/current",
        "PUT /albums/album/assets",
        "GET /assets/previous",
        "POST /assets/spaces",
        "GET /albums?assetId=previous",
        "DELETE /assets",
      }, calls())
      assert.are.same({ ids = { "previous" }, force = true }, requestBody(7))
      assert.is_true(rendition.skipped)
      assert.are.equal("current", rendition.recordedId)
      assert.is_nil(rendition.failure)

      -- The other copy already had the right asset so is left alone.
      assert.is_false(otherPublished.edited)
      assert.are.same({}, lr.catalog.writeActions)
    end)

    it("marks other photos using a deleted old asset as edited", function()
      local photo = newPhoto(1)
      local virtualCopy = newPhoto(2)
      local own = newPublishedPhoto(photo, "previous", false)
      local sharing = newPublishedPhoto(virtualCopy, "previous", false)
      local other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(photo, "current", false) })
      local collection = newCollection(10, "Holiday", "album", { own, sharing })
      local rendition = newRendition(photo, "previous")
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "current", isTrashed = false })
      lr.respondJson(200, { { id = "current", success = true } })
      lr.respondJson(200, { id = "previous", isTrashed = false })
      noSpaces()
      lr.respondJson(200, { { id = "album", albumName = "Holiday" } })
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.same({ ids = { "previous" }, force = true }, requestBody(7))
      -- The virtual copy must be republished but this photo isn't touched.
      assert.is_true(sharing.edited)
      assert.is_false(own.edited)
      assert.are.same({ "Update Published Photos" }, lr.catalog.writeActions)
    end)

    it("doesn't mark photos edited when deleting the old asset fails", function()
      local photo = newPhoto(1)
      local sharing = newPublishedPhoto(newPhoto(2), "previous", false)
      local other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(photo, "current", false) })
      local collection = newCollection(10, "Holiday", "album", { sharing })
      local rendition = newRendition(photo, "previous")
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "current", isTrashed = false })
      lr.respondJson(200, { { id = "current", success = true } })
      lr.respondJson(200, { id = "previous", isTrashed = false })
      noSpaces()
      lr.respondJson(200, {})
      lr.respond({ status = 500 })

      publish(exportContext)

      assert.is_false(sharing.edited)
      assert.are.same({}, lr.catalog.writeActions)
    end)

    it("keeps this collection's asset when it is still the one in use", function()
      local photo = newPhoto(1)
      local other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(photo, "current", false) })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, "current")
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "current", isTrashed = false })
      lr.respondJson(200, { { id = "current", success = false, error = "duplicate" } })

      publish(exportContext)

      assert.are.same({ "GET /albums/album", "GET /assets/current", "PUT /albums/album/assets" }, calls())
      assert.are.equal("current", rendition.recordedId)
    end)

    it("republishes a photo deleted from the server that is in two collections", function()
      local photo = newPhoto(1)
      local otherPublished = newPublishedPhoto(photo, "deleted", false)
      local other = newCollection(11, "Other", "otherAlbum", { otherPublished })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, "deleted")
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respond({ status = 400, body = json.encode({ message = "Not found or no asset.read access" }) })
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/deleted",
        "MULTIPART /assets",
        "PUT /albums/album/assets",
      }, calls())
      assert.is_nil(rendition.failure)
      assert.are.equal("asset", rendition.recordedId)
      assert.are.equal("asset", otherPublished.remoteId)
      assert.is_true(otherPublished.edited)
    end)

    it("uploads when the unedited copy's asset is missing from the server", function()
      local photo = newPhoto(1)
      local otherPublished = newPublishedPhoto(photo, "gone", false)
      local other = newCollection(11, "Other", "otherAlbum", { otherPublished })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, nil)
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respond({ status = 404 })
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.same({ "GET /albums/album", "GET /assets/gone", "MULTIPART /assets", "PUT /albums/album/assets" }, calls())
      assert.is_false(rendition.skipped)
      assert.are.equal("asset", rendition.recordedId)

      -- The other collection now shares the new asset but must be republished
      -- to add it to that album.
      assert.are.equal("asset", otherPublished.remoteId)
      assert.are.equal("https://gallery.example.com/photos/asset", otherPublished.remoteUrl)
      assert.is_true(otherPublished.edited)
    end)

    it("deletes stray assets referenced by other copies", function()
      local photo = newPhoto(1)
      local current = newPublishedPhoto(photo, "current", false)
      local stray = newPublishedPhoto(photo, "stray", true)
      local first = newCollection(11, "First", "firstAlbum", { current })
      local second = newCollection(12, "Second", "secondAlbum", { stray })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, nil)
      local exportContext = newExportContext(newService({ first, second, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "current", isTrashed = false })
      lr.respondJson(200, { { id = "current", success = true } })
      lr.respondJson(200, { id = "stray", isTrashed = false })
      noSpaces()
      -- Only in published albums so it can be deleted.
      lr.respondJson(200, { { id = "secondAlbum", albumName = "Second" } })
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/current",
        "PUT /albums/album/assets",
        "GET /assets/stray",
        "POST /assets/spaces",
        "GET /albums?assetId=stray",
        "DELETE /assets",
      }, calls())
      assert.are.same({ ids = { "stray" }, force = true }, requestBody(7))
      assert.are.equal("current", rendition.recordedId)

      assert.are.equal("current", stray.remoteId)
      assert.is_true(stray.edited)
      assert.is_false(current.edited)
    end)

    it("deletes a stray asset already in the trash without restoring it", function()
      local photo = newPhoto(1)
      local stray = newPublishedPhoto(photo, "stray", true)
      local first = newCollection(11, "First", "firstAlbum", { newPublishedPhoto(photo, "current", false) })
      local second = newCollection(12, "Second", "secondAlbum", { stray })
      local collection = newCollection(10, "Holiday", "album")
      local exportContext =
        newExportContext(newService({ first, second, collection }), collection, { newRendition(photo, nil) })

      albumExists()
      lr.respondJson(200, { id = "current", isTrashed = false })
      lr.respondJson(200, { { id = "current", success = true } })
      lr.respondJson(200, { id = "stray", isTrashed = true })
      noSpaces()
      lr.respondJson(200, {})
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/current",
        "PUT /albums/album/assets",
        "GET /assets/stray",
        "POST /assets/spaces",
        "GET /albums?assetId=stray",
        "DELETE /assets",
      }, calls())
      assert.are.same({ ids = { "stray" }, force = true }, requestBody(7))
    end)

    describe("keeps stray assets used outside Lightroom", function()
      local stray, exportContext

      before_each(function()
        local photo = newPhoto(1)
        stray = newPublishedPhoto(photo, "stray", true)
        local first = newCollection(11, "First", "firstAlbum", { newPublishedPhoto(photo, "current", false) })
        local second = newCollection(12, "Second", "secondAlbum", { stray })
        local collection = newCollection(10, "Holiday", "album")
        exportContext =
          newExportContext(newService({ first, second, collection }), collection, { newRendition(photo, nil) })

        albumExists()
        lr.respondJson(200, { id = "current", isTrashed = false })
        lr.respondJson(200, { { id = "current", success = true } })
        lr.respondJson(200, { id = "stray", isTrashed = false })
      end)

      it("in a shared space", function()
        lr.respondJson(200, { assets = { { assetId = "stray", spaceIds = { "family" } } } })

        publish(exportContext)

        assert.are.equal("POST /assets/spaces", calls()[5])
        assert.are.equal(5, #lr.http.requests)
        -- The copy is still pointed at the asset being used.
        assert.are.equal("current", stray.remoteId)
      end)

      it("in an album not published from Lightroom", function()
        noSpaces()
        lr.respondJson(200, { { id = "secondAlbum", albumName = "Second" }, { id = "handmade", albumName = "Favourites" } })

        publish(exportContext)

        assert.are.equal("GET /albums?assetId=stray", calls()[6])
        assert.are.equal(6, #lr.http.requests)
        assert.is_truthy(lr.logged("not published from Lightroom"))
      end)
    end)

    it("marks copies with a stray missing asset as edited", function()
      local photo = newPhoto(1)
      local current = newPublishedPhoto(photo, "current", false)
      local stray = newPublishedPhoto(photo, "stray", false)
      local first = newCollection(11, "First", "firstAlbum", { current })
      local second = newCollection(12, "Second", "secondAlbum", { stray })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, nil)
      local exportContext = newExportContext(newService({ first, second, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "current", isTrashed = false })
      lr.respondJson(200, { { id = "current", success = true } })
      lr.respond({ status = 404 })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/current",
        "PUT /albums/album/assets",
        "GET /assets/stray",
      }, calls())
      assert.are.equal("current", stray.remoteId)
      assert.is_true(stray.edited)
    end)

    it("ignores unpublished copies in other collections", function()
      local photo = newPhoto(1)
      local other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(photo, nil, false) })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, nil)
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })

      publish(exportContext)

      assert.are.same({ "GET /albums/album", "MULTIPART /assets", "PUT /albums/album/assets" }, calls())
      assert.is_false(rendition.skipped)
    end)

    it("replaces edited assets and updates the other collections", function()
      local photo = newPhoto(1)
      local otherPublished = newPublishedPhoto(photo, "old", true)
      local other = newCollection(11, "Other", "otherAlbum", { otherPublished })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, "old")
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "old", isTrashed = false })
      lr.respondJson(201, { id = "new", status = "created" })
      lr.respondJson(200, { id = "old" })
      lr.respond({ status = 204 })
      noSpaces()
      lr.respondJson(200, { { id = "new", success = false, error = "duplicate" } })
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/old",
        "MULTIPART /assets",
        "GET /assets/old",
        "PUT /assets/copy",
        "POST /assets/spaces",
        "PUT /albums/album/assets",
        "DELETE /assets",
      }, calls())
      assert.are.same({ sourceId = "old", targetId = "new", sidecar = false }, requestBody(5))
      assert.are.same({ assetIds = { "old", "new" } }, requestBody(6))
      assert.are.same({ ids = { "old" }, force = true }, requestBody(8))

      assert.are.equal("new", rendition.recordedId)
      assert.is_nil(rendition.failure)

      assert.are.equal("new", otherPublished.remoteId)
      assert.are.equal("https://gallery.example.com/photos/new", otherPublished.remoteUrl)
      assert.is_true(otherPublished.edited)
      assert.are.same({ "Update Published Photos" }, lr.catalog.writeActions)
    end)

    describe("shared spaces when replacing", function()
      local rendition, exportContext

      before_each(function()
        local collection = newCollection(10, "Holiday", "album")
        rendition = newRendition(newPhoto(1), "old")
        exportContext = newExportContext(newService({ collection }), collection, { rendition })

        albumExists()
        lr.respondJson(200, { id = "old", isTrashed = false })
        lr.respondJson(201, { id = "new", status = "created" })
        lr.respondJson(200, { id = "old" })
        lr.respond({ status = 204 })
      end)

      it("adds the replacement to spaces it isn't already shown in", function()
        -- The old asset is in two spaces. The replacement is already shown in
        -- one through a linked album that the copy carried over.
        lr.respondJson(200, {
          assets = {
            { assetId = "old", spaceIds = { "direct", "linked" } },
            { assetId = "new", spaceIds = { "linked" } },
          },
        })
        lr.respond({ status = 204 })
        lr.respondJson(200, { { id = "new", success = true } })
        lr.respond({ status = 204 })

        publish(exportContext)

        assert.are.same({
          "GET /albums/album",
          "GET /assets/old",
          "MULTIPART /assets",
          "GET /assets/old",
          "PUT /assets/copy",
          "POST /assets/spaces",
          "POST /shared-spaces/direct/assets",
          "PUT /albums/album/assets",
          "DELETE /assets",
        }, calls())
        assert.are.same({ assetIds = { "new" } }, requestBody(7))
        assert.are.equal("new", rendition.recordedId)
      end)

      it("carries on when the server doesn't support shared spaces", function()
        lr.respond({ status = 404 })
        lr.respondJson(200, { { id = "new", success = true } })
        lr.respond({ status = 204 })

        publish(exportContext)

        assert.is_nil(rendition.failure)
        assert.are.equal("new", rendition.recordedId)
      end)

      it("fails without losing anything when adding to a space fails", function()
        lr.respondJson(200, { assets = { { assetId = "old", spaceIds = { "direct" } } } })
        lr.respond({ status = 500 })
        lr.respond({ status = 204 })

        publish(exportContext)

        -- The replacement is deleted and the old asset is left alone.
        assert.are.equal("The gallery returned an error: 500", rendition.failure)
        assert.are.same({ ids = { "new" }, force = true }, requestBody(8))
        assert.are.equal(8, #lr.http.requests)
      end)
    end)

    it("replaces the first asset from the other collections that exists", function()
      local photo = newPhoto(1)
      local missing = newPublishedPhoto(photo, "gone", true)
      local existing = newPublishedPhoto(photo, "old", true)
      local first = newCollection(11, "First", "firstAlbum", { missing })
      local second = newCollection(12, "Second", "secondAlbum", { existing })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, nil)
      local exportContext = newExportContext(newService({ first, second, collection }), collection, { rendition })

      albumExists()
      lr.respond({ status = 404 })
      lr.respondJson(200, { id = "old", isTrashed = false })
      lr.respondJson(201, { id = "new", status = "created" })
      lr.respondJson(200, { id = "old" })
      lr.respond({ status = 204 })
      noSpaces()
      lr.respondJson(200, { { id = "new", success = true } })
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/gone",
        "GET /assets/old",
        "MULTIPART /assets",
        "GET /assets/old",
        "PUT /assets/copy",
        "POST /assets/spaces",
        "PUT /albums/album/assets",
        "DELETE /assets",
      }, calls())
      assert.are.same({ ids = { "old" }, force = true }, requestBody(9))
      assert.are.same({ sourceId = "old", targetId = "new", sidecar = false }, requestBody(6))
      assert.are.equal("new", rendition.recordedId)
      assert.are.equal("new", missing.remoteId)
      assert.are.equal("new", existing.remoteId)
    end)

    it("reports errors checking for an existing asset", function()
      local photo = newPhoto(1)
      local other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(photo, "asset", false) })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, nil)
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respond({ status = 500 })

      publish(exportContext)

      assert.are.same({ "GET /albums/album", "GET /assets/asset" }, calls())
      assert.is_true(rendition.skipped)
      assert.are.equal("The gallery returned an error: 500", rendition.failure)
      assert.is_nil(rendition.recordedId)
    end)

    it("reports upload failures", function()
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(newPhoto(1), nil)
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respond({ status = 500, body = json.encode({ message = "Disk full" }) })

      publish(exportContext)

      assert.are.equal("The gallery returned an error: Disk full", rendition.failure)
      assert.is_nil(rendition.recordedId)
    end)

    it("reports failures adding to the album", function()
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(newPhoto(1), nil)
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = false, error = "no_permission" } })
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.equal("Could not add the photo to the album: no_permission", rendition.failure)
      assert.is_nil(rendition.recordedId)

      -- The uploaded asset isn't left orphaned.
      assert.are.same({ "GET /albums/album", "MULTIPART /assets", "PUT /albums/album/assets", "DELETE /assets" }, calls())
      assert.are.same({ ids = { "asset" }, force = true }, requestBody(4))
    end)

    it("deletes the uploaded asset when an unexpected error occurs", function()
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(newPhoto(1), nil)
      function rendition:recordPublishedPhotoId()
        error("catalog exploded")
      end
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.same({ "GET /albums/album", "MULTIPART /assets", "PUT /albums/album/assets", "DELETE /assets" }, calls())
      assert.are.same({ ids = { "asset" }, force = true }, requestBody(4))
      assert.is_truthy(string.find(rendition.failure, "catalog exploded", 1, true))
    end)

    it("deletes the uploaded asset when replacing fails", function()
      local photo = newPhoto(1)
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, "old")
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "old", isTrashed = false })
      lr.respondJson(201, { id = "new", status = "created" })
      lr.respondJson(200, { id = "old" })
      lr.respond({ status = 500 })
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/old",
        "MULTIPART /assets",
        "GET /assets/old",
        "PUT /assets/copy",
        "DELETE /assets",
      }, calls())
      assert.are.same({ ids = { "new" }, force = true }, requestBody(6))
      assert.are.equal("The gallery returned an error: 500", rendition.failure)
    end)

    it("never deletes a duplicate asset when publishing fails", function()
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(newPhoto(1), nil)
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "phone", status = "duplicate" })
      lr.respondJson(200, { { id = "phone", success = false, error = "no_permission" } })

      publish(exportContext)

      assert.are.same({ "GET /albums/album", "MULTIPART /assets", "PUT /albums/album/assets" }, calls())
      assert.is_truthy(rendition.failure)
    end)

    it("deletes the uploaded asset when cancelled and still cancels", function()
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(newPhoto(1), nil)
      function rendition:recordPublishedPhotoId()
        lr.modules.LrErrors.throwCanceled()
      end
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })
      lr.respond({ status = 204 })

      local ok, err = lr.modules.LrFunctionContext.pcallWithContext("test", function(context)
        Provider.processRenderedPhotos(context, exportContext)
      end)

      assert.is_false(ok)
      assert.are.equal(lr.CANCELED, err)
      assert.are.same({ ids = { "asset" }, force = true }, requestBody(4))
    end)

    it("applies updates to other collections when publishing is interrupted", function()
      local first = newPhoto(1)
      local otherPublished = newPublishedPhoto(first, "old", true)
      local other = newCollection(11, "Other", "otherAlbum", { otherPublished })
      local collection = newCollection(10, "Holiday", "album")
      local cancelled = newRendition(newPhoto(2), nil)
      function cancelled:recordPublishedPhotoId()
        lr.modules.LrErrors.throwCanceled()
      end
      local renditions = { newRendition(first, "old"), cancelled }
      local exportContext = newExportContext(newService({ other, collection }), collection, renditions)

      albumExists()
      -- The first photo replaces the asset the other collection uses.
      lr.respondJson(200, { id = "old", isTrashed = false })
      lr.respondJson(201, { id = "new", status = "created" })
      lr.respondJson(200, { id = "old" })
      lr.respond({ status = 204 })
      noSpaces()
      lr.respondJson(200, { { id = "new", success = true } })
      lr.respond({ status = 204 })
      -- The second photo is cancelled.
      lr.respondJson(201, { id = "second", status = "created" })
      lr.respondJson(200, { { id = "second", success = true } })
      lr.respond({ status = 204 })

      local ok, err = lr.modules.LrFunctionContext.pcallWithContext("test", function(context)
        Provider.processRenderedPhotos(context, exportContext)
      end)

      assert.is_false(ok)
      assert.are.equal(lr.CANCELED, err)

      -- The old asset was deleted so the other collection must reference the
      -- new one.
      assert.are.same({ ids = { "old" }, force = true }, requestBody(8))
      assert.are.equal("new", otherPublished.remoteId)
      assert.is_true(otherPublished.edited)
      assert.are.same({ "Update Published Photos" }, lr.catalog.writeActions)

      -- The cancelled photo's upload was removed.
      assert.are.same({ ids = { "second" }, force = true }, requestBody(11))
    end)

    it("doesn't delete old assets until the photo references the new one", function()
      local photo = newPhoto(1)
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, "old")
      local recordedBeforeDelete = false
      function rendition:recordPublishedPhotoId(id)
        self.recordedId = id
      end
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "old", isTrashed = false })
      lr.respondJson(201, { id = "new", status = "created" })
      lr.respondJson(200, { id = "old" })
      lr.respond({ status = 204 })
      noSpaces()
      lr.respondJson(200, { { id = "new", success = true } })
      lr.respond({ status = 204 })

      local post = lr.modules.LrHttp.post
      lr.modules.LrHttp.post = function(url, body, headers, method)
        if method == "DELETE" and url:match("/assets$") then
          recordedBeforeDelete = rendition.recordedId == "new"
        end
        return post(url, body, headers, method)
      end

      publish(exportContext)

      assert.are.same({ ids = { "old" }, force = true }, requestBody(8))
      assert.is_true(recordedBeforeDelete)
    end)

    it("reports photos that failed to render", function()
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(newPhoto(1), nil)
      rendition.renderSuccess = false
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()

      publish(exportContext)

      assert.are.same({ "GET /albums/album" }, calls())
      assert.are.equal("render failed", rendition.failure)
      assert.is_nil(rendition.recordedId)
    end)

    it("keeps old assets when adding to the album fails", function()
      local photo = newPhoto(1)
      local otherPublished = newPublishedPhoto(photo, "old", true)
      local other = newCollection(11, "Other", "otherAlbum", { otherPublished })
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, "old")
      local exportContext = newExportContext(newService({ other, collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "old", isTrashed = false })
      lr.respondJson(201, { id = "new", status = "created" })
      lr.respondJson(200, { id = "old" })
      lr.respond({ status = 204 })
      noSpaces()
      lr.respondJson(200, { { id = "new", success = false, error = "no_permission" } })
      lr.respond({ status = 204 })

      publish(exportContext)

      -- Only the new upload is deleted.
      assert.are.same({
        "GET /albums/album",
        "GET /assets/old",
        "MULTIPART /assets",
        "GET /assets/old",
        "PUT /assets/copy",
        "POST /assets/spaces",
        "PUT /albums/album/assets",
        "DELETE /assets",
      }, calls())
      assert.are.same({ ids = { "new" }, force = true }, requestBody(8))
      assert.are.equal("Could not add the photo to the album: no_permission", rendition.failure)
      assert.are.equal("old", otherPublished.remoteId)
      assert.are.same({}, lr.catalog.writeActions)
    end)

    it("uses a duplicate asset returned when replacing", function()
      local photo = newPhoto(1)
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(photo, "old")
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "old", isTrashed = false })
      lr.respondJson(200, { id = "phone", status = "duplicate" })
      lr.respondJson(200, { { id = "phone", success = true } })
      noSpaces()
      lr.respondJson(200, { { id = "album", albumName = "Holiday" } })
      lr.respond({ status = 204 })

      publish(exportContext)

      -- Nothing was copied from the old asset so it is checked before deleting.
      assert.are.same({
        "GET /albums/album",
        "GET /assets/old",
        "MULTIPART /assets",
        "PUT /albums/album/assets",
        "POST /assets/spaces",
        "GET /albums?assetId=old",
        "DELETE /assets",
      }, calls())
      assert.are.same({ ids = { "old" }, force = true }, requestBody(7))
      assert.are.equal("phone", rendition.recordedId)
    end)

    it("keeps an old asset not copied to a duplicate when it is used outside Lightroom", function()
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(newPhoto(1), "old")
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "old", isTrashed = false })
      lr.respondJson(200, { id = "phone", status = "duplicate" })
      lr.respondJson(200, { { id = "phone", success = true } })
      noSpaces()
      lr.respondJson(200, { { id = "album", albumName = "Holiday" }, { id = "handmade", albumName = "Favourites" } })

      publish(exportContext)

      assert.are.equal(6, #lr.http.requests)
      assert.are.equal("phone", rendition.recordedId)
    end)

    it("always deletes a replaced asset even when it is used outside Lightroom", function()
      -- Its albums and spaces were all copied to the new asset.
      local collection = newCollection(10, "Holiday", "album")
      local rendition = newRendition(newPhoto(1), "old")
      local exportContext = newExportContext(newService({ collection }), collection, { rendition })

      albumExists()
      lr.respondJson(200, { id = "old", isTrashed = false })
      lr.respondJson(201, { id = "new", status = "created" })
      lr.respondJson(200, { id = "old" })
      lr.respond({ status = 204 })
      lr.respondJson(200, {
        assets = {
          { assetId = "old", spaceIds = { "family" } },
          { assetId = "new", spaceIds = { "family" } },
        },
      })
      lr.respondJson(200, { { id = "new", success = true } })
      lr.respond({ status = 204 })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/old",
        "MULTIPART /assets",
        "GET /assets/old",
        "PUT /assets/copy",
        "POST /assets/spaces",
        "PUT /albums/album/assets",
        "DELETE /assets",
      }, calls())
      assert.are.same({ ids = { "old" }, force = true }, requestBody(8))
    end)

    it("logs the decision made for each photo", function()
      local first = newPhoto(1)
      local second = newPhoto(2)
      local other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(second, "existing", false) })
      local collection = newCollection(10, "Holiday", "album")
      local renditions = { newRendition(first, nil), newRendition(second, nil) }
      local exportContext = newExportContext(newService({ other, collection }), collection, renditions)

      albumExists()
      lr.respondJson(200, { id = "existing", isTrashed = false })
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })
      lr.respondJson(200, { { id = "existing", success = true } })

      publish(exportContext)

      local messages = {}
      for _, entry in ipairs(lr.logsAt("debug")) do
        local parts = {}
        for i = 2, entry.args.n do
          table.insert(parts, tostring(entry.args[i]))
        end
        table.insert(messages, table.concat(parts, " "))
      end

      local function logged(message)
        for _, m in ipairs(messages) do
          if m == message then
            return true
          end
        end
        return false
      end

      assert.is_true(logged("Photo 1 has no existing asset, will upload a new asset"))
      assert.is_true(logged("Photo 1 uploaded as asset asset created"))
      assert.is_true(logged("Photo 1 published as asset asset in album album"))
      assert.is_true(logged("Photo 2 reusing unedited asset existing without uploading"))
      assert.is_true(logged("Photo 2 published as asset existing in album album"))
    end)

    it("handles several photos", function()
      local first = newPhoto(1)
      local second = newPhoto(2)
      local other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(second, "existing", false) })
      local collection = newCollection(10, "Holiday", "album")
      local renditions = { newRendition(first, nil), newRendition(second, nil) }
      local exportContext = newExportContext(newService({ other, collection }), collection, renditions)

      albumExists()
      lr.respondJson(200, { id = "existing", isTrashed = false })
      lr.respondJson(201, { id = "asset", status = "created" })
      lr.respondJson(200, { { id = "asset", success = true } })
      lr.respondJson(200, { { id = "existing", success = true } })

      publish(exportContext)

      assert.are.same({
        "GET /albums/album",
        "GET /assets/existing",
        "MULTIPART /assets",
        "PUT /albums/album/assets",
        "PUT /albums/album/assets",
      }, calls())
      assert.are.equal("asset", renditions[1].recordedId)
      assert.are.equal("existing", renditions[2].recordedId)
      assert.are.equal(0, #lr.logsAt("warn"))
    end)
  end)

  describe("deletePhotosFromPublishedCollection", function()
    local shared, orphan, collection, other

    before_each(function()
      shared = newPhoto(1)
      orphan = newPhoto(2)
      collection = newCollection(10, "Holiday", "album", {
        newPublishedPhoto(shared, "sharedAsset"),
        newPublishedPhoto(orphan, "orphanAsset"),
      })
      other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(shared, "sharedAsset") })
      newService({ collection, other })

      lr.catalog.getPublishedCollectionByLocalIdentifier = function(_, id)
        assert.are.equal(10, id)
        return collection
      end
    end)

    it("removes from the album and deletes orphaned assets", function()
      lr.respondJson(200, { { id = "sharedAsset", success = true }, { id = "orphanAsset", success = true } })
      noSpaces()
      lr.respondJson(200, {})
      lr.respond({ status = 204 })

      local deleted = {}
      Provider.deletePhotosFromPublishedCollection(settings, { "sharedAsset", "orphanAsset" }, function(id)
        table.insert(deleted, id)
      end, 10)

      assert.are.same({
        "DELETE /albums/album/assets",
        "POST /assets/spaces",
        "GET /albums?assetId=orphanAsset",
        "DELETE /assets",
      }, calls())
      assert.are.same({ ids = { "sharedAsset", "orphanAsset" } }, requestBody(1))
      assert.are.same({ assetIds = { "orphanAsset" } }, requestBody(2))
      assert.are.same({ ids = { "orphanAsset" }, force = false }, requestBody(4))
      assert.are.same({ "sharedAsset", "orphanAsset" }, deleted)
    end)

    describe("keeps assets in use outside Lightroom", function()
      local function remove()
        local deleted = {}
        Provider.deletePhotosFromPublishedCollection(settings, { "orphanAsset" }, function(id)
          table.insert(deleted, id)
        end, 10)
        return deleted
      end

      before_each(function()
        lr.respondJson(200, { { id = "orphanAsset", success = true } })
      end)

      it("in a shared space", function()
        lr.respondJson(200, { assets = { { assetId = "orphanAsset", spaceIds = { "family" } } } })

        assert.are.same({ "orphanAsset" }, remove())
        assert.are.same({ "DELETE /albums/album/assets", "POST /assets/spaces" }, calls())
      end)

      it("in an album not published from Lightroom", function()
        noSpaces()
        lr.respondJson(200, { { id = "handmade", albumName = "Favourites" } })

        assert.are.same({ "orphanAsset" }, remove())
        assert.are.same(
          { "DELETE /albums/album/assets", "POST /assets/spaces", "GET /albums?assetId=orphanAsset" },
          calls()
        )
        assert.is_truthy(lr.logged("not published from Lightroom"))
      end)

      it("in a published album whose collection doesn't contain the photo", function()
        noSpaces()
        lr.respondJson(200, { { id = "otherAlbum", albumName = "Other" } })

        assert.are.same({ "orphanAsset" }, remove())
        assert.are.equal(3, #lr.http.requests)
        assert.is_truthy(lr.logged("but not in its collection"))
      end)

      it("when the checks fail", function()
        lr.respond({ status = 500 })

        assert.are.same({ "orphanAsset" }, remove())
        assert.are.equal(2, #lr.http.requests)
      end)

      it("unless the album is the collection's own", function()
        -- The album may still list the asset, e.g. if removing it failed.
        noSpaces()
        lr.respondJson(200, { { id = "album", albumName = "Holiday" } })
        lr.respond({ status = 204 })

        remove()

        assert.are.same({ ids = { "orphanAsset" }, force = false }, requestBody(4))
      end)

      it("but carries on when the server doesn't support shared spaces", function()
        lr.respond({ status = 404 })
        lr.respondJson(200, {})
        lr.respond({ status = 204 })

        remove()

        assert.are.same({ ids = { "orphanAsset" }, force = false }, requestBody(4))
      end)
    end)

    it("keeps assets used elsewhere", function()
      lr.respondJson(200, { { id = "sharedAsset", success = true } })

      local deleted = {}
      Provider.deletePhotosFromPublishedCollection(settings, { "sharedAsset" }, function(id)
        table.insert(deleted, id)
      end, 10)

      assert.are.same({ "DELETE /albums/album/assets" }, calls())
      assert.are.same({ "sharedAsset" }, deleted)
    end)

    it("keeps assets used by another photo in the same collection", function()
      local copy = newPhoto(3)
      table.insert(collection.publishedPhotos, newPublishedPhoto(copy, "orphanAsset"))

      lr.respondJson(200, { { id = "orphanAsset", success = true } })

      local deleted = {}
      Provider.deletePhotosFromPublishedCollection(settings, { "orphanAsset" }, function(id)
        table.insert(deleted, id)
      end, 10)

      assert.are.same({ "DELETE /albums/album/assets" }, calls())
      assert.are.same({ "orphanAsset" }, deleted)
    end)

    it("deletes an asset when every photo in the collection using it is removed", function()
      local copy = newPhoto(3)
      table.insert(collection.publishedPhotos, newPublishedPhoto(copy, "orphanAsset"))

      lr.respondJson(200, { { id = "orphanAsset", success = true } })
      noSpaces()
      lr.respondJson(200, {})
      lr.respond({ status = 204 })

      Provider.deletePhotosFromPublishedCollection(settings, { "orphanAsset", "orphanAsset" }, function() end, 10)

      assert.are.same({ ids = { "orphanAsset" }, force = false }, requestBody(4))
    end)

    it("ignores a missing album", function()
      lr.respond({ status = 404 })
      noSpaces()
      lr.respondJson(200, {})
      lr.respond({ status = 204 })

      local deleted = {}
      Provider.deletePhotosFromPublishedCollection(settings, { "orphanAsset" }, function(id)
        table.insert(deleted, id)
      end, 10)

      assert.are.equal("DELETE /assets", calls()[4])
      assert.are.same({ "orphanAsset" }, deleted)
    end)

    it("throws on failure", function()
      lr.respond({ status = 500 })

      local deleted = {}
      assert.has_error(function()
        Provider.deletePhotosFromPublishedCollection(settings, { "orphanAsset" }, function(id)
          table.insert(deleted, id)
        end, 10)
      end, "The gallery returned an error: 500")
      assert.are.same({}, deleted)
    end)
  end)

  describe("deletePublishedCollection", function()
    local collection, other, service

    before_each(function()
      local shared = newPhoto(1)
      local orphan = newPhoto(2)
      collection = newCollection(10, "Holiday", "album", {
        newPublishedPhoto(shared, "sharedAsset"),
        newPublishedPhoto(orphan, "orphanAsset"),
      })
      other = newCollection(11, "Other", "otherAlbum", { newPublishedPhoto(shared, "sharedAsset") })
      service = newService({ collection, other })
    end)

    local function info()
      return {
        publishService = service,
        publishedCollection = collection,
        remoteId = "album",
      }
    end

    it("deletes orphaned assets and the album", function()
      noSpaces()
      -- The asset is still in the album being deleted, which doesn't count.
      lr.respondJson(200, { { id = "album", albumName = "Holiday" } })
      lr.respond({ status = 204 })
      lr.respond({ status = 204 })

      Provider.deletePublishedCollection(settings, info())

      assert.are.same({
        "POST /assets/spaces",
        "GET /albums?assetId=orphanAsset",
        "DELETE /assets",
        "DELETE /albums/album",
      }, calls())
      assert.are.same({ ids = { "orphanAsset" }, force = false }, requestBody(3))
    end)

    it("keeps assets that are also in another album", function()
      noSpaces()
      lr.respondJson(200, { { id = "album", albumName = "Holiday" }, { id = "handmade", albumName = "Favourites" } })
      lr.respond({ status = 204 })

      Provider.deletePublishedCollection(settings, info())

      assert.are.same({ "POST /assets/spaces", "GET /albums?assetId=orphanAsset", "DELETE /albums/album" }, calls())
    end)

    it("only deletes the album when every asset is shared", function()
      lr.respond({ status = 204 })

      collection.publishedPhotos = { newPublishedPhoto(newPhoto(1), "sharedAsset") }
      Provider.deletePublishedCollection(settings, info())

      assert.are.same({ "DELETE /albums/album" }, calls())
    end)

    it("does nothing for a collection that was never published", function()
      collection.publishedPhotos = { newPublishedPhoto(newPhoto(2), nil) }
      Provider.deletePublishedCollection(settings, {
        publishService = service,
        publishedCollection = collection,
      })

      assert.are.equal(0, #lr.http.requests)
    end)

    it("ignores an album already deleted from the server", function()
      noSpaces()
      lr.respondJson(200, {})
      lr.respond({ status = 204 })
      lr.respond({ status = 404 })

      Provider.deletePublishedCollection(settings, info())

      assert.are.equal(4, #lr.http.requests)
    end)

    it("throws on failure so Lightroom reverts", function()
      noSpaces()
      lr.respondJson(200, {})
      lr.respond({ status = 401 })

      assert.has_error(function()
        Provider.deletePublishedCollection(settings, info())
      end, "The API key was rejected by the gallery.")
      assert.are.equal(3, #lr.http.requests)
    end)
  end)
end)
