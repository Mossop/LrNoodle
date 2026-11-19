local server = require("server")
local API = require("API")
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
    -- A forced deletion isn't always visible straight away on a slow server,
    -- so wait up to 10 seconds for the asset to go.
    ---@param id string
    local function waitUntilDeleted(id)
      for _ = 1, 50 do
        if not ok(api:assetExists(id)) then
          return
        end
        os.execute("sleep 0.2")
      end
      error("Asset " .. id .. " still exists", 2)
    end

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
      waitUntilDeleted(id)
    end)

    it("permanently deletes trashed assets when forced", function()
      local id = upload()

      ok(api:deleteAssets({ id }))
      ok(api:deleteAssets({ id }, true))
      waitUntilDeleted(id)
    end)
  end)

  describe("copying", function()
    it("copies favorites and albums to the new asset", function()
      local old = upload()
      local new = upload()
      local album = ok(api:createAlbum("Copy source"))
      ok(api:addAssetsToAlbum(album.id, { old }))
      ok(setup:request("PUT", "/assets", { ids = { old }, isFavorite = true }))

      assert.is_true(ok(api:copyFromAsset(old, new)))

      assert.is_true(ok(api:getAsset(new)).isFavorite)
      local albums = ok(api:getAlbumsForAsset(new))
      assert.equals(1, #albums)
      assert.equals(album.id, albums[1].id)
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
