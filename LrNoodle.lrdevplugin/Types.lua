---@meta

---@class PublishSettings
---@field url string The base address of the gallery.
---@field apiKey string? An API key for the gallery. Only present while editing the settings, otherwise it is
---retrieved from the password storage.
---@field serviceId string? A random UUID identifying the publish service, created when its settings are first
---opened. Services created before it was added have none until their settings are saved.

---@class UploadSource Recorded in the "LrNoodle" metadata of every uploaded asset.
---@field publishService string The `serviceId` of the publish service that uploaded the asset.
---@field photoUuid string The UUID of the Lightroom photo the asset was rendered from.

---@class PluginPrefs : LrObservableTable
---@field debugLogging boolean? Whether to log debugging output.

---@class User
---@field id string
---@field name string
---@field email string

---@alias AssetVisibility
---| "timeline"
---| "archive"
---| "hidden"
---| "locked"

---@class Asset
---@field id string
---@field isTrashed boolean
---@field visibility AssetVisibility? Missing on servers too old to have it.

---@class AssetDates
---@field created number Lightroom timestamp for when the photo was captured.
---@field modified number Lightroom timestamp for when the photo was last modified.

---@class Album
---@field id string
---@field albumName string

---@class AssetSpaces
---@field assetId string
---@field spaceIds string[]

---@class AssetSpacesResponse
---@field assets AssetSpaces[]

---@alias UploadStatus
---| "created"
---| "duplicate"

---@class UploadResult
---@field id string
---@field status UploadStatus

---@class BulkIdResult
---@field id string
---@field success boolean
---@field error string?
