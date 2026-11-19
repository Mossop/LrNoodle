---@meta

---@class PublishSettings
---@field url string The base address of the gallery.
---@field apiKey string? An API key for the gallery. Only present while editing the settings, otherwise it is
---retrieved from the password storage.

---@class PluginPrefs : LrObservableTable
---@field debugLogging boolean? Whether to log debugging output.

---@class User
---@field id string
---@field name string
---@field email string

---@class Asset
---@field id string
---@field isTrashed boolean

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
