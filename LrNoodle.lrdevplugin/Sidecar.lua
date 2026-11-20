-- Builds XMP sidecar files carrying a photo's metadata. Lightroom embeds
-- metadata in rendered photos but not in videos, so videos are uploaded with a
-- sidecar that the gallery reads instead. Rendered photos with people get a
-- sidecar too, holding just their tags without the people's names, since the
-- gallery prefers a sidecar's tags to the embedded keywords.

local Utils = require("Utils")

local logger = require("Logging")("Sidecar")

---@class Sidecar
local Sidecar = {}

--- The parts of the publish settings that control which metadata is exported.
---@class MetadataSettings
---@field LR_embeddedMetadataOption string? Which metadata to include, e.g. "all" or "copyrightOnly".
---@field LR_removeLocationMetadata boolean? True to leave out the location.
---@field LR_removeFaceMetadata boolean? True to leave out people.
---@field LR_metadata_keywordOptions string? "flat" or "lightroomHierarchical".
---@field replacePeopleTags boolean? True to remove people from the tags of photos.
---@field peopleReplacementTag string? A tag added in place of the people removed from the tags.
---@field replacePeopleInVideos boolean? True to remove people from the tags of videos too.

local ESCAPES = {
  ["&"] = "&amp;",
  ["<"] = "&lt;",
  [">"] = "&gt;",
  ['"'] = "&quot;",
}

---@param str string
---@return string
local function escape(str)
  return (string.gsub(str, '[&<>"]', ESCAPES))
end

--- Formats a coordinate the way XMP expects, e.g. "51,30.123456N".
---@param value number
---@param positive string
---@param negative string
---@return string
local function formatCoordinate(value, positive, negative)
  local reference = value < 0 and negative or positive
  local absolute = math.abs(value)
  local degrees = math.floor(absolute)
  local minutes = (absolute - degrees) * 60
  return string.format("%d,%.6f%s", degrees, minutes, reference)
end

---@param name string
---@param value string
---@return string
local function simple(name, value)
  return string.format("   <%s>%s</%s>", name, escape(value), name)
end

---@param name string
---@param value string
---@return string
local function langAlt(name, value)
  return string.format(
    '   <%s>\n    <rdf:Alt>\n     <rdf:li xml:lang="x-default">%s</rdf:li>\n    </rdf:Alt>\n   </%s>',
    name,
    escape(value),
    name
  )
end

---@param name string
---@param container string "rdf:Bag" or "rdf:Seq".
---@param values string[]
---@return string
local function array(name, container, values)
  ---@type string[]
  local items = {}
  for _, value in ipairs(values) do
    table.insert(items, string.format("     <rdf:li>%s</rdf:li>", escape(value)))
  end
  return string.format(
    "   <%s>\n    <%s>\n%s\n    </%s>\n   </%s>",
    name,
    container,
    table.concat(items, "\n"),
    container,
    name
  )
end

---@param name string
---@param values string[]
---@return string
local function bag(name, values)
  return array(name, "rdf:Bag", values)
end

---@param properties string[]
---@return string
local function wrap(properties)
  return table.concat({
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">',
    ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">',
    '  <rdf:Description rdf:about=""',
    '    xmlns:dc="http://purl.org/dc/elements/1.1/"',
    '    xmlns:xmp="http://ns.adobe.com/xap/1.0/"',
    '    xmlns:exif="http://ns.adobe.com/exif/1.0/"',
    '    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"',
    '    xmlns:digiKam="http://www.digikam.org/ns/1.0/">',
    table.concat(properties, "\n"),
    "  </rdf:Description>",
    " </rdf:RDF>",
    "</x:xmpmeta>",
    "",
  }, "\n")
end

---@param value any
---@return string?
local function nonEmpty(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

---@param keyword LrKeyword
---@return boolean
local function isPerson(keyword)
  return keyword:getAttributes().keywordType == "person"
end

--- Adds the names and synonyms of a keyword and all of its parents to a set.
---@param keyword LrKeyword
---@param names { [string]: boolean }
local function addNamesWithParents(keyword, names)
  ---@type LrKeyword?
  local current = keyword
  while current do
    names[current:getName()] = true
    for _, synonym in ipairs(current:getSynonyms() or {}) do
      names[synonym] = true
    end
    current = current:getParent()
  end
end

--- The names to leave out when removing people. Like Lightroom this includes
--- the parents of person keywords, except where another keyword applied to
--- the photo needs them.
---@param photo LrPhoto
---@return { [string]: boolean }
local function personNames(photo)
  ---@type { [string]: boolean }
  local people = {}
  ---@type { [string]: boolean }
  local others = {}

  for _, keyword in ipairs(photo:getRawMetadata("keywords") or {}) do
    addNamesWithParents(keyword, isPerson(keyword) and people or others)
  end

  for name in pairs(others) do
    people[name] = nil
  end

  return people
end

--- The keywords Lightroom would export, as a flat list.
---@param photo LrPhoto
---@param excludePeople boolean
---@return string[]
local function flatKeywords(photo, excludePeople)
  local excluded = excludePeople and personNames(photo) or {}

  ---@type string[]
  local keywords = {}
  local formatted = nonEmpty(photo:getFormattedMetadata("keywordTagsForExport"))
  if formatted then
    for keyword in string.gmatch(formatted, "[^,]+") do
      local trimmed = string.match(keyword, "^%s*(.-)%s*$")
      if trimmed ~= "" and not excluded[trimmed] then
        table.insert(keywords, trimmed)
      end
    end
  end
  return keywords
end

--- The full path of each keyword that is included on export, e.g.
--- "Places|France|Paris". Keywords with an ancestor that isn't included on
--- export are left out.
---@param photo LrPhoto
---@param excludePeople boolean
---@return string[]
local function hierarchicalKeywords(photo, excludePeople)
  ---@type string[]
  local paths = {}

  for _, keyword in ipairs(photo:getRawMetadata("keywords") or {}) do
    ---@type string[]
    local path = {}
    local included = not (excludePeople and isPerson(keyword))
    ---@type LrKeyword?
    local current = included and keyword or nil
    while current do
      if not current:getAttributes().includeOnExport then
        included = false
        break
      end
      table.insert(path, 1, current:getName())
      current = current:getParent()
    end

    if included then
      table.insert(paths, table.concat(path, "|"))
    end
  end

  table.sort(paths)
  return paths
end

--- Whether the publish settings export keywords at all.
---@param settings MetadataSettings
---@return boolean
local function includesMetadata(settings)
  -- The copyright options don't allow any of the metadata we include.
  return string.match(settings.LR_embeddedMetadataOption or "all", "^all") ~= nil
end

--- Whether the publish settings export people, so person keywords would
--- become tags unless they are replaced.
---@param settings MetadataSettings
---@return boolean
function Sidecar.includesPeople(settings)
  return includesMetadata(settings) and settings.LR_removeFaceMetadata ~= true
end

--- Whether any person keyword would be exported with the photo.
---@param photo LrPhoto
---@return boolean
local function hasPeople(photo)
  return #flatKeywords(photo, false) > #flatKeywords(photo, true)
end

--- Adds the replacement tag to a list of tags if the photo has people and the
--- tag isn't in the list already.
---@param tags string[]
---@param photo LrPhoto
---@param settings MetadataSettings
local function addReplacementTag(tags, photo, settings)
  local tag = nonEmpty(string.match(settings.peopleReplacementTag or "", "^%s*(.-)%s*$"))
  if not tag or not hasPeople(photo) then
    return
  end

  for _, existing in ipairs(tags) do
    if existing == tag then
      return
    end
  end
  table.insert(tags, tag)
end

--- Converts a Lightroom keyword path, e.g. "Places|France|Paris", to the
--- gallery's form, e.g. "Places/France/Paris", the same way the gallery does.
---@param path string
---@return string
local function galleryPath(path)
  ---@type string[]
  local names = {}
  for name in string.gmatch(path, "[^|]+") do
    table.insert(names, (string.gsub(name, "/", "|")))
  end
  return table.concat(names, "/")
end

--- Builds an XMP sidecar for a video containing the metadata the publish
--- settings allow. Returns nil if there is no metadata to include.
---@param photo LrPhoto
---@param settings MetadataSettings
---@return string?
function Sidecar.build(photo, settings)
  if not includesMetadata(settings) then
    logger:debug("Metadata option", settings.LR_embeddedMetadataOption, "excludes the sidecar metadata")
    return nil
  end

  ---@type string[]
  local properties = {}

  local captured = photo:getRawMetadata("dateTimeOriginal") or photo:getRawMetadata("dateTimeDigitized")
  if captured then
    table.insert(properties, simple("exif:DateTimeOriginal", Utils.formatTimestamp(captured)))
  end

  local title = nonEmpty(photo:getFormattedMetadata("title"))
  if title then
    table.insert(properties, langAlt("dc:title", title))
  end

  local caption = nonEmpty(photo:getFormattedMetadata("caption"))
  if caption then
    table.insert(properties, langAlt("dc:description", caption))
  end

  local rating = photo:getRawMetadata("rating")
  if type(rating) == "number" and rating > 0 then
    table.insert(properties, simple("xmp:Rating", tostring(rating)))
  end

  if not settings.LR_removeLocationMetadata and not photo:getRawMetadata("locationIsPrivate") then
    local gps = photo:getRawMetadata("gps")
    if gps and gps.latitude and gps.longitude then
      table.insert(properties, simple("exif:GPSLatitude", formatCoordinate(gps.latitude, "N", "S")))
      table.insert(properties, simple("exif:GPSLongitude", formatCoordinate(gps.longitude, "E", "W")))
    end
  end

  local replacePeople = Sidecar.includesPeople(settings)
    and settings.replacePeopleTags == true
    and settings.replacePeopleInVideos == true
  local excludePeople = settings.LR_removeFaceMetadata == true or replacePeople

  local keywords = flatKeywords(photo, excludePeople)
  if replacePeople then
    addReplacementTag(keywords, photo, settings)
  end
  if #keywords > 0 then
    table.insert(properties, bag("dc:subject", keywords))
  end

  if settings.LR_metadata_keywordOptions == "lightroomHierarchical" then
    local paths = hierarchicalKeywords(photo, excludePeople)
    if #paths > 0 then
      table.insert(properties, bag("lr:hierarchicalSubject", paths))
    end
  end

  if #properties == 0 then
    return nil
  end

  return wrap(properties)
end

--- Builds an XMP sidecar for a rendered photo whose exported keywords include
--- people, if the settings ask for people to be removed from tags. It holds
--- a digiKam:TagsList, which the gallery uses instead of the embedded
--- keywords, listing the tags the gallery would otherwise create without the
--- people, plus the replacement tag. The embedded face regions
--- still identify the people. Returns nil if the photo needs no sidecar, or if
--- the list would be empty since the gallery then ignores it.
---@param photo LrPhoto
---@param settings MetadataSettings
---@return string?
function Sidecar.buildTags(photo, settings)
  if not settings.replacePeopleTags or not Sidecar.includesPeople(settings) then
    return nil
  end

  if not hasPeople(photo) then
    return nil
  end

  ---@type string[]
  local tags = {}
  ---@type { [string]: boolean }
  local seen = {}
  ---@param tag string
  local function add(tag)
    if not seen[tag] then
      seen[tag] = true
      table.insert(tags, tag)
    end
  end

  -- The gallery creates tags from both the hierarchical and flat keywords.
  if settings.LR_metadata_keywordOptions == "lightroomHierarchical" then
    for _, path in ipairs(hierarchicalKeywords(photo, true)) do
      add(galleryPath(path))
    end
  end
  for _, keyword in ipairs(flatKeywords(photo, true)) do
    add(keyword)
  end
  addReplacementTag(tags, photo, settings)

  if #tags == 0 then
    return nil
  end

  return wrap({ array("digiKam:TagsList", "rdf:Seq", tags) })
end

--- Writes a sidecar to a file.
---@param path string
---@param xmp string
---@return true | Error
function Sidecar.write(path, xmp)
  local file, message = io.open(path, "w")
  if not file then
    return Utils.throw("sidecarWrite", { tostring(message) })
  end

  file:write(xmp)
  file:close()
  return true
end

return Sidecar
