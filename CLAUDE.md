# LrNoodle

A Lightroom Classic publish service plugin for Noodle Gallery, a fork of Immich. The server API is
Immich compatible; the spec is at `https://gallery.clantownsend.com/api/spec.json`.

## Layout

- `LrNoodle.lrdevplugin/`
  - `Provider.lua`: the publish service provider. Lightroom callbacks, the settings dialog, and the
    publishing, deletion and album logic.
  - `API.lua`: all server communication. Every call returns `T | Error`.
  - `Sidecar.lua`: builds XMP sidecars for videos from Lightroom metadata, filtered by the publish settings.
  - `PluginInfo.lua`: the Plug-in Manager section (the debug logging checkbox).
  - `Types.lua`: `---@meta` type definitions for server responses and settings.
  - `Utils.lua`, `Logging.lua`, `ProgressScope.lua`, `json.lua`: shared helpers provided by the user. Ask
    before making broad changes to them.
- `tests/`: busted specs, one per module. `lr_stubs.lua` stands in for the Lightroom SDK.

## Commands

Use mise tasks, not the tools directly: `mise r test`, `mise r stylua`, `mise r luacheck`,
`mise r typecheck`. All four must pass after every change. The typecheck only covers the plugin, so the
LuaLS warnings about busted globals in `tests/` are expected and can be ignored.

## Conventions

- Functions that can fail return `T | Error` using `Utils.throw`, `Utils.isError`, `Utils.error` and
  `Utils.result`. LuaLS doesn't narrow types through `Utils.isError`, so use `Utils.error(x)` /
  `Utils.result(x)` or `--[[@as T]]` casts rather than returning the union directly.
- Annotate function parameters and returns with LuaLS types.
- Add user facing error messages to `ERROR_CODES` in `Utils.lua`.
- Log every decision about a photo at debug level, including asset IDs, so problems can be diagnosed from
  the log. Use warn for problems that don't stop publishing. trace, debug and info are only written when
  debug logging is enabled in the Plug-in Manager.

## Lightroom environment gotchas

- Lightroom runs Lua 5.1: no `goto`, no integer division and so on.
- Lightroom doesn't provide `os.remove`. Use `LrFileUtils.delete`. `os.date` and `io.open` are available.
  The tests run on plain Lua, so they won't catch a missing Lightroom global. Check the SDK before using
  any `os` or `io` function.
- `LrPrefs`, `LrPasswords` and similar modules are stubbed in `tests/lr_stubs.lua`. Add a stub there when
  using a new SDK module, and call `lr.reset()` in `before_each`.
- The SDK docs are in `/Users/dave/workspace/lightroom-lua/LrC_16.0_202611041403-7ac14c66.release_SDK` and
  the LuaLS definitions in `/Users/dave/workspace/lightroom-lua/library`.

## Server quirks

- Missing assets and albums are sometimes reported as `400 {"message":"Not found ..."}` rather than 404.
  `parseResponse` maps these to `notFound`.
- Uploads return `status = "duplicate"` with an existing asset's ID when the server already has an
  identical file. That asset may not belong to the plugin, so it is used as is: never copied over or
  deleted.
- `PUT /assets/copy` copies the sidecar by default. The plugin always sends `sidecar = false` so a new
  sidecar isn't overwritten.
- `DELETE /assets` moves to the trash unless `force = true`.
- Validation errors return `message` as an array of strings.

## Publishing design

- A photo's asset ID is stored as the `LrPublishedPhoto` remote ID in each collection. There is no separate
  storage, so the existing asset for a photo is found by looking at its copies in the service's other
  collections.
- Planning a photo checks candidate assets on the server (restoring trashed ones), in this order:
  1. An unedited copy elsewhere: reuse its asset without uploading.
  2. This collection's ID, then the other copies' IDs: replace the first that exists.
  3. Otherwise upload a new asset.
- A replacement uploads a new asset, then copies the old asset's details to it with `copyFromAsset`.
- `publishAndRecord` protects everything from the upload until `recordPublishedPhotoId`. If anything fails,
  including exceptions and cancellation, an asset created by the upload is permanently deleted.
- Only after the new ID is recorded does `finishPublish` permanently delete every other asset previously
  used for the photo (the replaced asset, this collection's old ID and the other copies' IDs). It also
  queues updates pointing the other copies at the new asset and marking them edited.
- Catalog updates are batched and applied in one write transaction when publishing ends, even if it is
  interrupted.
- A deleted album is recreated empty, then the collection's unedited assets are added in bulk. Photos
  whose assets are rejected are marked edited.
- Removing photos or deleting a collection moves assets to the trash only if no other photo in any
  collection of the service still uses them.

## User decisions to respect

- API key auth (`x-api-key`), stored with `LrPasswords` keyed by the gallery URL, never in the preset
  fields. Only https URLs are allowed.
- Stale and replaced assets are permanently deleted. Orphans from removing photos or collections go to the
  trash.
- Videos get an XMP sidecar on upload rather than metadata set through the API. It mirrors Lightroom's
  export behaviour: "Remove Person Info" drops person keywords and their parents; "Export Containing
  Keywords" affects the flat list but not the hierarchical paths.
- Published photo URLs are `<gallery>/photos/<assetId>`.
- The user manages version control (jj). Don't commit.
