local lr = require("lr_stubs")
local json = require("json")
local Utils = require("Utils")
local API = require("API")

-- Lightroom timestamps: 2001-01-01T00:00:00Z and 2001-01-02T01:00:00Z.
local dates = { created = 0, modified = 90000 }

local source = { publishService = "service", photoUuid = "photo" }

local function newApi()
  return API.new({ url = "https://gallery.example.com/", apiKey = "secret" })
end

local function request(index)
  return lr.http.requests[index]
end

local function body(index)
  return json.decode(request(index).body)
end

---@return any
local function chunk(req, name)
  for _, c in ipairs(req.chunks) do
    if c.name == name then
      return c
    end
  end
  return nil
end

describe("API", function()
  before_each(function()
    lr.reset()
  end)

  describe("requests", function()
    it("sends GET requests with the api key", function()
      lr.respondJson(200, { id = "user", name = "Dave", email = "d@example.com" })

      local result = newApi():checkConnection()

      assert.are.same({ id = "user", name = "Dave", email = "d@example.com" }, result)
      assert.are.equal("GET", request(1).method)
      assert.are.equal("https://gallery.example.com/api/users/me", request(1).url)
      assert.are.equal("secret", lr.header(request(1), "x-api-key"))
    end)

    it("sends JSON bodies with the right method", function()
      lr.respondJson(200, { id = "album", albumName = "New" })

      local result = newApi():renameAlbum("album", "New")

      assert.are.same({ id = "album", albumName = "New" }, result)
      assert.are.equal("PATCH", request(1).method)
      assert.are.equal("https://gallery.example.com/api/albums/album", request(1).url)
      assert.are.equal("application/json", lr.header(request(1), "Content-Type"))
      assert.are.same({ albumName = "New" }, body(1))
    end)

    it("treats empty successful responses as true", function()
      lr.respond({ status = 204 })

      assert.is_true(newApi():deleteAlbum("album"))
      assert.are.equal("DELETE", request(1).method)
      assert.are.equal("https://gallery.example.com/api/albums/album", request(1).url)
    end)

    it("calls the album and asset endpoints", function()
      local api = newApi()

      lr.respondJson(201, { id = "album", albumName = "Name" })
      api:createAlbum("Name")
      lr.respondJson(200, { { id = "a", success = true } })
      api:addAssetsToAlbum("album", { "a" })
      lr.respondJson(200, { { id = "a", success = true } })
      api:removeAssetsFromAlbum("album", { "a" })
      lr.respond({ status = 204 })
      api:deleteAssets({ "a", "b" })
      lr.respond({ status = 204 })
      api:copyAsset("a", "b")
      lr.respondJson(200, { id = "a" })
      api:getAsset("a")
      lr.respondJson(200, { id = "album" })
      api:getAlbum("album")
      lr.respond({ status = 204 })
      api:restoreAssets({ "a" })
      lr.respond({ status = 204 })
      api:deleteAssets({ "a" }, true)

      local calls = {}
      for _, req in ipairs(lr.http.requests) do
        table.insert(calls, req.method .. " " .. req.url)
      end

      assert.are.same({
        "POST https://gallery.example.com/api/albums",
        "PUT https://gallery.example.com/api/albums/album/assets",
        "DELETE https://gallery.example.com/api/albums/album/assets",
        "DELETE https://gallery.example.com/api/assets",
        "PUT https://gallery.example.com/api/assets/copy",
        "GET https://gallery.example.com/api/assets/a",
        "GET https://gallery.example.com/api/albums/album",
        "POST https://gallery.example.com/api/trash/restore/assets",
        "DELETE https://gallery.example.com/api/assets",
      }, calls)

      assert.are.same({ albumName = "Name" }, body(1))
      assert.are.same({ ids = { "a" } }, body(2))
      assert.are.same({ ids = { "a" } }, body(3))
      assert.are.same({ ids = { "a", "b" }, force = false }, body(4))
      assert.are.same({ sourceId = "a", targetId = "b", sidecar = false }, body(5))
      assert.are.same({ ids = { "a" } }, body(8))
      assert.are.same({ ids = { "a" }, force = true }, body(9))
    end)

    it("uploads assets as multipart", function()
      lr.respondJson(201, { id = "asset", status = "created" })

      local result = newApi():uploadAsset("/tmp/photo.jpg", "photo.jpg", dates, source)

      assert.are.same({ id = "asset", status = "created" }, result)
      local req = request(1)
      assert.are.equal("MULTIPART", req.method)
      assert.are.equal("https://gallery.example.com/api/assets", req.url)
      assert.are.equal("secret", lr.header(req, "x-api-key"))

      local data = chunk(req, "assetData")
      assert.are.equal("/tmp/photo.jpg", data.filePath)
      assert.are.equal("photo.jpg", data.fileName)

      assert.are.equal("2001-01-01T00:00:00Z", chunk(req, "fileCreatedAt").value)
      assert.are.equal("2001-01-02T01:00:00Z", chunk(req, "fileModifiedAt").value)

      assert.are.same(
        { { key = "LrNoodle", value = { publishService = "service", photoUuid = "photo" } } },
        json.decode(chunk(req, "metadata").value)
      )
    end)

    it("uploads a sidecar when given one", function()
      lr.respondJson(201, { id = "asset", status = "created" })

      newApi():uploadAsset("/tmp/video.mp4", "video.mp4", dates, source, "/tmp/video.mp4.xmp")

      local sidecar = chunk(request(1), "sidecarData")
      assert.are.equal("/tmp/video.mp4.xmp", sidecar.filePath)
      assert.are.equal("video.mp4.xmp", sidecar.fileName)
      assert.are.equal("application/rdf+xml", sidecar.contentType)
    end)

    it("doesn't upload a sidecar by default", function()
      lr.respondJson(201, { id = "asset", status = "created" })

      newApi():uploadAsset("/tmp/photo.jpg", "photo.jpg", dates, source)

      assert.is_nil(chunk(request(1), "sidecarData"))
    end)

    it("allows time for large uploads such as videos", function()
      lr.respondJson(201, { id = "asset", status = "created" })

      newApi():uploadAsset("/tmp/video.mp4", "video.mp4", dates, source)

      assert.are.equal(300, request(1).timeout)
      assert.are.equal("video.mp4", chunk(request(1), "assetData").fileName)
    end)

    it("uses the stored api key when the settings don't include one", function()
      API.storeApiKey("https://gallery.example.com/", "stored")
      assert.are.equal("stored", lr.passwords["apiKey:https://gallery.example.com"])

      lr.respondJson(200, { id = "user" })
      API.new({ url = "https://gallery.example.com" }):checkConnection()

      assert.are.equal("stored", lr.header(request(1), "x-api-key"))
      assert.are.equal("stored", API.retrieveApiKey("https://gallery.example.com//"))
    end)

    it("builds urls", function()
      local api = newApi()
      assert.are.equal("https://gallery.example.com/photos/a", api:assetUrl("a"))
      assert.are.equal("https://gallery.example.com/albums/b", api:albumUrl("b"))
    end)
  end)

  describe("errors", function()
    local function errorFor(response)
      lr.respond(response)
      local result = newApi():getAsset("a")
      assert.is_true(Utils.isError(result))
      return Utils.error(result)
    end

    it("maps connection failures", function()
      assert.are.same(
        { code = "invalidUrl", args = { "bad" } },
        errorFor({ error = { errorCode = "badURL", name = "bad" } })
      )
      assert.are.same(
        { code = "unknownHost", args = { "host" } },
        errorFor({ error = { errorCode = "cannotFindHost", name = "host" } })
      )
      assert.are.same(
        { code = "connection", args = { "other" } },
        errorFor({ error = { errorCode = "timedOut", name = "other" } })
      )
    end)

    it("maps status codes", function()
      assert.are.equal("badApiKey", errorFor({ status = 401 }).code)
      assert.are.equal("badApiKey", errorFor({ status = 403 }).code)
      assert.are.equal("notFound", errorFor({ status = 404 }).code)
      assert.are.equal(
        "notFound",
        errorFor({ status = 400, body = json.encode({ message = "Not found or no asset.read access" }) }).code
      )
    end)

    it("includes the server message", function()
      local err = errorFor({ status = 400, body = json.encode({ message = "Bad things" }) })
      assert.are.same({ code = "serverError", args = { "Bad things" } }, err)

      err = errorFor({ status = 400, body = json.encode({ message = { "first", "second" } }) })
      assert.are.same({ code = "serverError", args = { "first; second" } }, err)

      err = errorFor({ status = 500, body = "not json" })
      assert.are.same({ code = "serverError", args = { "500" } }, err)
    end)

    it("reports invalid JSON", function()
      assert.are.equal("invalidJson", errorFor({ status = 200, body = "{" }).code)
    end)
  end)

  describe("assetExists", function()
    it("reports existing assets, including those in the trash, without restoring them", function()
      lr.respondJson(200, { id = "a", isTrashed = false })
      lr.respondJson(200, { id = "b", isTrashed = true })

      assert.is_true(newApi():assetExists("a"))
      assert.is_true(newApi():assetExists("b"))
      assert.are.equal(2, #lr.http.requests)
    end)

    it("reports missing assets", function()
      lr.respond({ status = 404 })

      assert.is_false(newApi():assetExists("a"))
    end)

    it("returns other errors", function()
      lr.respond({ status = 500 })

      assert.is_true(Utils.isError(newApi():assetExists("a")))
    end)
  end)

  describe("findAsset", function()
    it("returns assets, including those in the trash, without restoring them", function()
      lr.respondJson(200, { id = "a", isTrashed = true })

      assert.are.same({ id = "a", isTrashed = true }, newApi():findAsset("a"))
      assert.are.equal(1, #lr.http.requests)
      assert.are.equal("https://gallery.example.com/api/assets/a", request(1).url)
    end)

    it("reports missing assets", function()
      lr.respond({ status = 404 })

      assert.is_false(newApi():findAsset("a"))
    end)

    it("reports deleted assets the server rejects as a bad request", function()
      lr.respond({ status = 400, body = json.encode({ message = "Not found or no asset.read access" }) })

      assert.is_false(newApi():findAsset("a"))
    end)

    it("returns other errors", function()
      lr.respond({ status = 500 })

      local result = newApi():findAsset("a")
      assert.is_true(Utils.isError(result))
      assert.are.equal("serverError", Utils.error(result).code)
    end)
  end)

  describe("shared spaces", function()
    it("looks up the spaces showing assets", function()
      lr.respondJson(200, { assets = { { assetId = "a", spaceIds = { "s1", "s2" } } } })

      local spaces = newApi():getAssetSpaces({ "a", "b" })

      assert.are.same({ a = { "s1", "s2" } }, spaces)
      assert.are.equal("POST", request(1).method)
      assert.are.equal("https://gallery.example.com/api/assets/spaces", request(1).url)
      assert.are.same({ assetIds = { "a", "b" } }, body(1))
    end)

    it("looks up large numbers of assets in batches", function()
      local ids = {}
      for i = 1, 1500 do
        table.insert(ids, "a" .. i)
      end
      lr.respondJson(200, { assets = { { assetId = "a1", spaceIds = { "s" } } } })
      lr.respondJson(200, { assets = { { assetId = "a1500", spaceIds = { "t" } } } })

      local spaces = newApi():getAssetSpaces(ids)

      assert.are.same({ a1 = { "s" }, a1500 = { "t" } }, spaces)
      assert.are.equal(1000, #body(1).assetIds)
      assert.are.equal(500, #body(2).assetIds)
    end)

    it("reports no spaces when the server doesn't support them", function()
      lr.respond({ status = 404 })

      assert.are.same({}, newApi():getAssetSpaces({ "a" }))
    end)

    it("only asks once when the server doesn't support them", function()
      lr.respond({ status = 404 })

      local api = newApi()
      assert.are.same({}, api:getAssetSpaces({ "a" }))
      assert.are.same({}, api:getAssetSpaces({ "b" }))
      assert.are.equal(1, #lr.http.requests)
    end)

    it("returns other errors", function()
      lr.respond({ status = 500 })

      assert.is_true(Utils.isError(newApi():getAssetSpaces({ "a" })))
    end)

    it("rejects unexpected responses", function()
      lr.respond({ status = 204 })

      assert.is_true(Utils.isError(newApi():getAssetSpaces({ "a" })))
    end)

    it("adds assets to a space", function()
      lr.respond({ status = 204 })

      assert.is_true(newApi():addAssetsToSpace("space", { "a" }))
      assert.are.equal("https://gallery.example.com/api/shared-spaces/space/assets", request(1).url)
      assert.are.same({ assetIds = { "a" } }, body(1))
    end)
  end)

  it("finds the albums containing an asset", function()
    lr.respondJson(200, { { id = "album", albumName = "Holiday" } })

    local albums = newApi():getAlbumsForAsset("asset")

    assert.are.same({ { id = "album", albumName = "Holiday" } }, albums)
    assert.are.equal("GET", request(1).method)
    assert.are.equal("https://gallery.example.com/api/albums?assetId=asset", request(1).url)
  end)

  describe("deleteAssetsIfExists", function()
    it("deletes the assets in one request", function()
      lr.respond({ status = 204 })

      assert.is_true(newApi():deleteAssetsIfExists({ "a", "b" }, true))

      assert.are.equal(1, #lr.http.requests)
      assert.are.same({ ids = { "a", "b" }, force = true }, body(1))
    end)

    it("deletes only the assets that still exist when some are gone", function()
      lr.respondJson(400, { message = "Not found or no asset.delete access" })
      lr.respond({ status = 404 })
      lr.respondJson(200, { id = "b" })
      lr.respond({ status = 204 })

      assert.is_true(newApi():deleteAssetsIfExists({ "a", "b" }, true))

      assert.are.equal(4, #lr.http.requests)
      assert.are.equal("https://gallery.example.com/api/assets/a", request(2).url)
      assert.are.equal("https://gallery.example.com/api/assets/b", request(3).url)
      assert.are.same({ ids = { "b" }, force = true }, body(4))
    end)

    it("succeeds when every asset is gone", function()
      lr.respondJson(400, { message = "Not found or no asset.delete access" })
      lr.respond({ status = 404 })

      assert.is_true(newApi():deleteAssetsIfExists({ "a" }))
      assert.are.equal(2, #lr.http.requests)
    end)

    it("returns errors checking the assets", function()
      lr.respondJson(400, { message = "Not found or no asset.delete access" })
      lr.respond({ status = 500 })

      local result = newApi():deleteAssetsIfExists({ "a" })

      assert.is_true(Utils.isError(result))
      assert.are.equal("serverError", Utils.error(result).code)
      assert.are.equal(2, #lr.http.requests)
    end)

    it("returns other delete failures", function()
      lr.respond({ status = 500 })

      local result = newApi():deleteAssetsIfExists({ "a" })

      assert.is_true(Utils.isError(result))
      assert.are.equal("serverError", Utils.error(result).code)
      assert.are.equal(1, #lr.http.requests)
    end)
  end)

  describe("copyFromAsset", function()
    it("copies everything except the sidecar from the old asset", function()
      lr.respond({ status = 204 })

      assert.is_true(newApi():copyFromAsset({ id = "old", isTrashed = false }, "new"))

      assert.are.equal(1, #lr.http.requests)
      assert.are.equal("https://gallery.example.com/api/assets/copy", request(1).url)
      assert.are.same({ sourceId = "old", targetId = "new", sidecar = false }, body(1))
    end)

    it("copies the visibility, which the copy leaves out", function()
      lr.respond({ status = 204 })
      lr.respond({ status = 204 })

      assert.is_true(newApi():copyFromAsset({ id = "old", isTrashed = false, visibility = "archive" }, "new"))

      assert.are.equal(2, #lr.http.requests)
      assert.are.equal("PUT", request(2).method)
      assert.are.equal("https://gallery.example.com/api/assets", request(2).url)
      assert.are.same({ ids = { "new" }, visibility = "archive" }, body(2))
    end)

    it("leaves a new asset on the timeline", function()
      lr.respond({ status = 204 })

      assert.is_true(newApi():copyFromAsset({ id = "old", isTrashed = false, visibility = "timeline" }, "new"))
      assert.are.equal(1, #lr.http.requests)
    end)

    it("returns failures copying the visibility", function()
      lr.respond({ status = 204 })
      lr.respond({ status = 403 })

      local result = newApi():copyFromAsset({ id = "old", isTrashed = false, visibility = "locked" }, "new")

      assert.is_true(Utils.isError(result))
      assert.are.equal("badApiKey", Utils.error(result).code)
    end)

    it("returns copy failures without deleting anything", function()
      lr.respond({ status = 500 })

      local result = newApi():copyFromAsset({ id = "old", isTrashed = false }, "new")

      assert.is_true(Utils.isError(result))
      assert.are.equal("serverError", Utils.error(result).code)
      assert.are.equal(1, #lr.http.requests)
    end)
  end)
end)
