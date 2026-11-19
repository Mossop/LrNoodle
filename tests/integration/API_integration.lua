local server = require("server")
local catalog = require("lr_catalog")
local API = require("API")
local Sidecar = require("Sidecar")
local Utils = require("Utils")

-- Lightroom timestamps: 2001-01-01T00:00:00Z and 2001-01-02T01:00:00Z.
local dates = { created = 0, modified = 90000 }

-- An ID that no asset or album has.
local MISSING_ID = "00000000-0000-4000-8000-000000000000"

describe("API against a real server", function()
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

  -- Asserts that a result is an error with the given code.
  local function fails(code, result)
    assert.is_true(Utils.isError(result), "Expected an error")
    assert.equals(code, Utils.error(result).code)
  end

  ---@param path string
  ---@return UploadResult
  local function uploadFile(path)
    return ok(api:uploadAsset(path, "photo.jpg", dates))
  end

  -- Uploads a new photo and returns its asset ID.
  ---@return string
  local function upload()
    local path = server.photo()
    local result = uploadFile(path)
    os.remove(path)
    assert.equals("created", result.status)
    return result.id
  end

  ---@param ids string[]
  ---@return string[]
  local function sorted(ids)
    local copy = { unpack(ids) }
    table.sort(copy)
    return copy
  end

  before_each(function()
    api, setup = server.reset()
  end)

  describe("connection", function()
    it("connects with the api key", function()
      local user = ok(api:checkConnection())
      assert.equals(server.email, user.email)
    end)

    it("rejects a bad api key", function()
      local bad = API.new({ url = server.url, apiKey = "not a key" })
      fails("badApiKey", bad:checkConnection())
    end)
  end)

  describe("uploads", function()
    it("creates an asset with the given dates", function()
      local id = upload()

      local asset = ok(api:getAsset(id))
      assert.equals(id, asset.id)
      assert.is_false(asset.isTrashed)
      assert.equals("2001-01-01T00:00:00.000Z", asset.fileCreatedAt)
      assert.equals("2001-01-02T01:00:00.000Z", asset.fileModifiedAt)
    end)

    it("reports a duplicate with the existing asset", function()
      local path = server.photo()
      local first = uploadFile(path)
      local second = uploadFile(path)
      os.remove(path)

      assert.equals("created", first.status)
      assert.equals("duplicate", second.status)
      assert.equals(first.id, second.id)
    end)
  end)

  describe("missing items", function()
    it("reports a missing asset as not found", function()
      fails("notFound", api:getAsset(MISSING_ID))
      assert.is_false(ok(api:assetExists(MISSING_ID)))
      assert.is_false(ok(api:ensureAsset(MISSING_ID)))
    end)

    it("reports a missing album as not found", function()
      fails("notFound", api:getAlbum(MISSING_ID))
    end)

    it("reports deleting a missing album as not found", function()
      fails("notFound", api:deleteAlbum(MISSING_ID))
    end)

    it("reports validation errors", function()
      fails("serverError", api:getAsset("not-an-id"))
    end)
  end)

  describe("deletion", function()
    it("moves assets to the trash and restores them", function()
      local id = upload()

      ok(api:deleteAssets({ id }))
      assert.is_true(ok(api:getAsset(id)).isTrashed)
      assert.is_true(ok(api:assetExists(id)))
      assert.is_true(ok(api:getAsset(id)).isTrashed)

      assert.is_true(ok(api:ensureAsset(id)))
      assert.is_false(ok(api:getAsset(id)).isTrashed)
    end)

    it("permanently deletes assets when forced", function()
      local id = upload()

      ok(api:deleteAssets({ id }, true))
      server.waitUntilDeleted(api, id)
    end)

    it("permanently deletes trashed assets when forced", function()
      local id = upload()

      ok(api:deleteAssets({ id }))
      ok(api:deleteAssets({ id }, true))
      server.waitUntilDeleted(api, id)
    end)
  end)

  -- After a replacement the asset's metadata should match Lightroom's as
  -- closely as possible, so Lightroom's metadata wins over anything set in the
  -- gallery. Details only the gallery has are copied from the old asset.
  describe("copying", function()
    -- The details of an asset that copying should either keep or replace.
    ---@param id string
    local function details(id)
      local asset = ok(api:getAsset(id))
      local exif = asset.exifInfo or {}

      local tags = {}
      for _, tag in ipairs(asset.tags or {}) do
        table.insert(tags, tag.value)
      end

      local albums = {}
      for _, album in ipairs(ok(api:getAlbumsForAsset(id))) do
        table.insert(albums, album.id)
      end

      return {
        description = exif.description or "",
        rating = exif.rating,
        dateTimeOriginal = exif.dateTimeOriginal,
        latitude = exif.latitude,
        longitude = exif.longitude,
        tags = sorted(tags),
        isFavorite = asset.isFavorite,
        visibility = asset.visibility,
        albums = sorted(albums),
      }
    end

    -- The server reads metadata in the background, so this waits for the
    -- asset's details to match before asserting them, which shows the
    -- differences if they never do.
    local function assertDetails(expected, id)
      pcall(server.waitFor, "the asset's details", function()
        return (pcall(assert.same, expected, details(id)))
      end)
      assert.same(expected, details(id))
    end

    -- Tag names must be unique on the server.
    local tagCount = 0

    -- Uploads an asset and gives it details in the gallery, checking that the
    -- server stored them. Returns the asset ID and its album.
    ---@return string, string
    local function galleryAsset()
      tagCount = tagCount + 1
      local tagName = "Gallery tag " .. tagCount

      local id = upload()
      -- Let the server read the file's own metadata first so it can't replace
      -- what is set below.
      server.waitFor("the server to read the file's metadata", function()
        local exif = ok(api:getAsset(id)).exifInfo
        return exif and exif.exifImageWidth
      end)

      local album = ok(api:createAlbum("Made in the gallery"))
      ok(api:addAssetsToAlbum(album.id, { id }))
      ok(setup:request("PUT", "/assets/" .. id, {
        description = "Added in the gallery",
        rating = 2,
        dateTimeOriginal = "2010-06-01T12:00:00.000Z",
        latitude = 51.5,
        longitude = -0.12,
        isFavorite = true,
        visibility = "archive",
      }))
      local tag = ok(setup:request("POST", "/tags", { name = tagName }))
      ok(setup:request("PUT", "/tags/" .. tag.id .. "/assets", { ids = { id } }))

      assertDetails({
        description = "Added in the gallery",
        rating = 2,
        dateTimeOriginal = "2010-06-01T12:00:00+00:00",
        latitude = 51.5,
        longitude = -0.12,
        tags = { tagName },
        isFavorite = true,
        visibility = "archive",
        albums = { album.id },
      }, id)

      return id, album.id
    end

    -- A copy of details with some of them changed.
    local function with(base, changes)
      local result = {}
      for key, value in pairs(base) do
        result[key] = value
      end
      for key, value in pairs(changes) do
        result[key] = value
      end
      return result
    end

    -- Uploads a new photo with a sidecar holding a Lightroom photo's metadata,
    -- standing in for the metadata Lightroom embeds in a rendered photo. Checks
    -- that the server has read the expected metadata before returning the
    -- asset ID.
    ---@return string
    local function lightroomAsset(metadata, expected)
      local path = server.photo()
      local sidecarPath = path .. ".xmp"
      ok(Sidecar.write(sidecarPath, assert(Sidecar.build(catalog.newPhoto(1, metadata), {}))))

      local result = ok(api:uploadAsset(path, "photo.jpg", dates, sidecarPath))
      os.remove(path)
      os.remove(sidecarPath)
      assert.equals("created", result.status)

      assertDetails(with(expected, { isFavorite = false, visibility = "timeline", albums = {} }), result.id)

      return result.id
    end

    it("keeps the gallery's details but uses Lightroom's metadata", function()
      local old, album = galleryAsset()
      local lightroom = {
        description = "From Lightroom",
        rating = 4,
        dateTimeOriginal = "2001-01-02T01:00:00+00:00",
        latitude = 48.8584,
        longitude = -2.2945,
        tags = { "Paris" },
      }
      local new = lightroomAsset({
        -- 2001-01-02T01:00:00Z
        dateTimeOriginal = 90000,
        rating = 4,
        gps = { latitude = 48.8584, longitude = -2.2945 },
        keywords = { catalog.newKeyword("Paris") },
        formatted = { caption = "From Lightroom", keywordTagsForExport = "Paris" },
      }, lightroom)

      assert.is_true(ok(api:copyFromAsset(old, new)))

      assertDetails(with(lightroom, { isFavorite = true, visibility = "archive", albums = { album } }), new)
    end)

    it("uses Lightroom's metadata even where Lightroom has none", function()
      local old, album = galleryAsset()
      -- The sidecar's capture date differs from the upload's file dates, so
      -- seeing it shows the server has read the sidecar.
      local lightroom = {
        description = "",
        dateTimeOriginal = "2001-01-02T01:00:00+00:00",
        tags = {},
      }
      local new = lightroomAsset({ dateTimeOriginal = 90000 }, lightroom)

      assert.is_true(ok(api:copyFromAsset(old, new)))

      assertDetails(with(lightroom, { isFavorite = true, visibility = "archive", albums = { album } }), new)
    end)

    it("does nothing when the old asset is missing", function()
      local new = upload()
      assert.is_true(ok(api:copyFromAsset(MISSING_ID, new)))
    end)
  end)

  describe("albums", function()
    it("creates, renames and deletes albums", function()
      local album = ok(api:createAlbum("First name"))
      assert.equals("First name", album.albumName)

      local renamed = ok(api:renameAlbum(album.id, "Second name"))
      assert.equals("Second name", renamed.albumName)
      assert.equals("Second name", ok(api:getAlbum(album.id)).albumName)

      ok(api:deleteAlbum(album.id))
      fails("notFound", api:getAlbum(album.id))
    end)

    it("adds and removes assets", function()
      local first = upload()
      local second = upload()
      local album = ok(api:createAlbum("Assets"))

      local added = ok(api:addAssetsToAlbum(album.id, { first, second }))
      assert.equals(2, #added)
      assert.is_true(added[1].success)
      assert.is_true(added[2].success)

      local albums = ok(api:getAlbumsForAsset(first))
      assert.equals(1, #albums)
      assert.equals(album.id, albums[1].id)

      local removed = ok(api:removeAssetsFromAlbum(album.id, { first }))
      assert.equals(1, #removed)
      assert.is_true(removed[1].success)
      assert.equals(0, #ok(api:getAlbumsForAsset(first)))
      assert.equals(1, #ok(api:getAlbumsForAsset(second)))
    end)

    it("reports assets that can't be added", function()
      local id = upload()
      local album = ok(api:createAlbum("Rejections"))
      ok(api:addAssetsToAlbum(album.id, { id }))

      local added = ok(api:addAssetsToAlbum(album.id, { id, MISSING_ID }))
      assert.equals(2, #added)
      assert.is_false(added[1].success)
      assert.equals("duplicate", added[1].error)
      assert.is_false(added[2].success)
    end)
  end)

  describe("shared spaces", function()
    ---@param name string
    ---@return string
    local function createSpace(name)
      return ok(setup:request("POST", "/shared-spaces", { name = name })).id
    end

    it("reports no spaces for assets in none", function()
      local id = upload()
      assert.same({}, ok(api:getAssetSpaces({ id })))
    end)

    it("reports spaces assets were added to", function()
      local first = upload()
      local second = upload()
      local space = createSpace("Direct")

      ok(api:addAssetsToSpace(space, { first }))

      assert.same({ [first] = { space } }, ok(api:getAssetSpaces({ first, second })))
    end)

    it("reports spaces showing assets through a linked album", function()
      local id = upload()
      local direct = createSpace("Direct")
      local linked = createSpace("Linked")
      local album = ok(api:createAlbum("Linked album"))
      ok(api:addAssetsToAlbum(album.id, { id }))
      ok(api:addAssetsToSpace(direct, { id }))
      ok(setup:request("PUT", "/shared-spaces/" .. linked .. "/albums/" .. album.id))

      local spaces = ok(api:getAssetSpaces({ id }))
      assert.same(sorted({ direct, linked }), sorted(spaces[id]))
    end)
  end)
end)
