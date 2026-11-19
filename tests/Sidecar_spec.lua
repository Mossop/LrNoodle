local lr = require("lr_stubs")
local catalog = require("lr_catalog")
local Utils = require("Utils")
local Sidecar = require("Sidecar")

local newKeyword = catalog.newKeyword

local function newPhoto(raw, formatted)
  local photo = { raw = raw or {}, formatted = formatted or {} }

  function photo:getRawMetadata(key)
    return self.raw[key]
  end
  function photo:getFormattedMetadata(key)
    return self.formatted[key]
  end

  return photo
end

local function photoWithPerson()
  local people = newKeyword("People")
  return newPhoto({
    keywords = {
      newKeyword("Alice Smith", people, true, "person", { "Ali" }),
      newKeyword("bike"),
    },
  }, {
    keywordTagsForExport = "Alice Smith, Ali, People, bike",
  })
end

local function fullPhoto()
  local places = newKeyword("Places")
  local france = newKeyword("France", places)
  local private = newKeyword("Private", nil, false)

  return newPhoto({
    -- 2001-01-02T01:00:00Z
    dateTimeOriginal = 90000,
    rating = 4,
    gps = { latitude = 48.8584, longitude = -2.2945 },
    keywords = { newKeyword("Paris", france), newKeyword("Secret", private) },
  }, {
    title = "Eiffel & friends",
    caption = 'A "tall" <tower>',
    keywordTagsForExport = "Paris, France, Places",
  })
end

local function contains(xmp, text)
  return string.find(xmp, text, 1, true) ~= nil
end

describe("Sidecar", function()
  before_each(function()
    lr.reset()
  end)

  it("includes all the metadata", function()
    local xmp = Sidecar.build(fullPhoto(), {
      LR_embeddedMetadataOption = "all",
      LR_metadata_keywordOptions = "lightroomHierarchical",
    })

    assert.is_truthy(xmp)
    assert.is_true(contains(xmp, "<exif:DateTimeOriginal>2001-01-02T01:00:00Z</exif:DateTimeOriginal>"))
    assert.is_true(contains(xmp, '<rdf:li xml:lang="x-default">Eiffel &amp; friends</rdf:li>'))
    assert.is_true(contains(xmp, '<rdf:li xml:lang="x-default">A &quot;tall&quot; &lt;tower&gt;</rdf:li>'))
    assert.is_true(contains(xmp, "<xmp:Rating>4</xmp:Rating>"))
    assert.is_true(contains(xmp, "<exif:GPSLatitude>48,51.504000N</exif:GPSLatitude>"))
    assert.is_true(contains(xmp, "<exif:GPSLongitude>2,17.670000W</exif:GPSLongitude>"))
    assert.is_true(contains(xmp, "<rdf:li>Paris</rdf:li>"))
    assert.is_true(contains(xmp, "<rdf:li>Places</rdf:li>"))
    assert.is_true(contains(xmp, "<rdf:li>Places|France|Paris</rdf:li>"))
    assert.is_false(contains(xmp, "Secret"))
  end)

  it("writes flat keywords only when chosen", function()
    local xmp = Sidecar.build(fullPhoto(), { LR_metadata_keywordOptions = "flat" })

    assert.is_true(contains(xmp, "<dc:subject>"))
    assert.is_false(contains(xmp, "lr:hierarchicalSubject"))
  end)

  it("leaves out the location when asked", function()
    local xmp = Sidecar.build(fullPhoto(), { LR_removeLocationMetadata = true })

    assert.is_false(contains(xmp, "GPS"))
    assert.is_true(contains(xmp, "xmp:Rating"))
  end)

  it("includes people by default", function()
    local xmp = Sidecar.build(photoWithPerson(), { LR_metadata_keywordOptions = "lightroomHierarchical" })

    assert.is_true(contains(xmp, "<rdf:li>Alice Smith</rdf:li>"))
    assert.is_true(contains(xmp, "<rdf:li>Ali</rdf:li>"))
    assert.is_true(contains(xmp, "<rdf:li>People|Alice Smith</rdf:li>"))
  end)

  it("leaves out people when asked", function()
    local xmp = Sidecar.build(photoWithPerson(), {
      LR_removeFaceMetadata = true,
      LR_metadata_keywordOptions = "lightroomHierarchical",
    })

    assert.is_false(contains(xmp, "Alice"))
    assert.is_false(contains(xmp, "<rdf:li>Ali</rdf:li>"))
    -- Like Lightroom the parents of person keywords are left out too.
    assert.is_false(contains(xmp, "People"))
    assert.is_true(contains(xmp, "<rdf:li>bike</rdf:li>"))
  end)

  it("keeps a person keyword's parent that another keyword needs", function()
    local places = newKeyword("Places")
    local photo = newPhoto({
      keywords = {
        newKeyword("Alice Smith", places, true, "person"),
        newKeyword("Paris", places),
      },
    }, {
      keywordTagsForExport = "Alice Smith, Paris, Places",
    })

    local xmp = Sidecar.build(photo, { LR_removeFaceMetadata = true })

    assert.is_false(contains(xmp, "Alice"))
    assert.is_true(contains(xmp, "<rdf:li>Places</rdf:li>"))
    assert.is_true(contains(xmp, "<rdf:li>Paris</rdf:li>"))
  end)

  it("leaves out a location marked private", function()
    local photo = fullPhoto()
    photo.raw.locationIsPrivate = true

    assert.is_false(contains(Sidecar.build(photo, {}), "GPS"))
  end)

  it("includes nothing for the copyright options", function()
    assert.is_nil(Sidecar.build(fullPhoto(), { LR_embeddedMetadataOption = "copyrightOnly" }))
    assert.is_nil(Sidecar.build(fullPhoto(), { LR_embeddedMetadataOption = "copyrightAndContactOnly" }))
  end)

  it("includes everything for the other all options", function()
    local xmp = Sidecar.build(fullPhoto(), { LR_embeddedMetadataOption = "allExceptCameraAndCameraRawInfo" })
    assert.is_true(contains(xmp, "xmp:Rating"))
  end)

  it("falls back to the digitized date", function()
    local xmp = Sidecar.build(newPhoto({ dateTimeDigitized = 0 }), {})
    assert.is_true(contains(xmp, "<exif:DateTimeOriginal>2001-01-01T00:00:00Z</exif:DateTimeOriginal>"))
  end)

  it("returns nothing when there is no metadata", function()
    assert.is_nil(Sidecar.build(newPhoto({ rating = 0 }, { title = "", keywordTagsForExport = "" }), {}))
  end)

  it("writes sidecars to files", function()
    local path = os.tmpname()

    assert.is_true(Sidecar.write(path, "<xmp/>"))

    local file = assert(io.open(path, "r"))
    assert.are.equal("<xmp/>", file:read("*a"))
    file:close()
    os.remove(path)
  end)

  it("reports failures writing files", function()
    local result = Sidecar.write("/nonexistent/directory/file.xmp", "<xmp/>")

    assert.is_true(Utils.isError(result))
    assert.are.equal("sidecarWrite", Utils.error(result).code)
  end)
end)
