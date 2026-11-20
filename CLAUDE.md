# LrNoodle

A Lightroom Classic publish service plugin for Noodle Gallery, a fork of Immich. The server API is
Immich compatible; the spec is at `https://gallery.clantownsend.com/api/spec.json`.

## Layout

- `LrNoodle.lrdevplugin/`
  - `Provider.lua`: the publish service provider. Lightroom callbacks, the settings dialog, and the
    publishing, deletion and album logic.
  - `API.lua`: all server communication. Every call returns `T | Error`.
  - `Sidecar.lua`: builds XMP sidecars for videos from Lightroom metadata, filtered by the publish settings,
    and tag-only sidecars for photos with people.
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
  identical file. That asset may not have been uploaded by the plugin, so the upload that matched it uses
  it as is: nothing is copied over it and it isn't deleted. Once it is recorded as a photo's asset it is
  treated like any other (see the user decisions below).
- Tags come from a `digiKam:TagsList` if there is one, otherwise from the union of `HierarchicalSubject` and
  `Keywords`. A sidecar's values override the embedded ones key by key, but an empty `TagsList` is ignored.
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
- A replacement uploads a new asset, then copies the old asset's details to it with `copyFromAsset`. The
  copy doesn't include shared spaces, so `copySpaces` adds the new asset to any space that showed the old
  asset but doesn't show the new one (spaces linked to albums already show it, since albums are copied).
  It doesn't include the visibility (archived, hidden, locked) either, so `copyFromAsset` sets that.
- After publishing, an asset's metadata should match Lightroom's as closely as possible. Lightroom's
  metadata (description, rating, capture date, location, keywords as tags) comes from the new upload and
  wins over anything set in the gallery, even where Lightroom has no value. Only details the gallery alone
  has (albums, favourite, shared links, stack, visibility, shared spaces) are copied from the old asset.
- `publishAndRecord` protects everything from the upload until `recordPublishedPhotoId`. If anything fails,
  including exceptions and cancellation, an asset created by the upload is permanently deleted.
- Only after the new ID is recorded does `finishPublish` clean up the assets previously used for the photo.
  It also queues updates pointing the other copies at the new asset and marking them edited.
  - The replaced asset (only set when the upload created an asset and its details were copied) is always
    permanently deleted.
  - Every other previously seen ID (this collection's old ID, the other copies' IDs, or the previous asset
    when the upload matched a duplicate) is permanently deleted unless `withoutAssetsUsedElsewhere` finds
    it in a shared space or an album that isn't published from one of the service's collections.
  - When one of these other IDs is deleted, every published photo in the service still referencing it
    (e.g. an identical virtual copy matched as a duplicate) is marked edited so it is republished. The
    photo being published is skipped.
  - The replaced asset could also be another photo's asset; that case is accepted and not handled.
- Catalog updates are batched and applied in one write transaction when publishing ends, even if it is
  interrupted.
- A deleted album is recreated empty, then the collection's unedited assets are added in bulk. Photos
  whose assets are rejected are marked edited.
- Removing photos or deleting a collection moves assets to the trash only if no other photo in any
  collection of the service still uses them, and `withoutAssetsUsedElsewhere` finds them in no shared space
  and no album other than the collection's own. If those checks fail the assets are kept.

## Immich compatibility

The plugin must keep working with plain Immich, though it has only been tested with Noodle Gallery. Noodle
only endpoints (currently just shared spaces: `POST /assets/spaces`, `POST /shared-spaces/{id}/assets`)
must degrade gracefully: Immich returns 404 for them, which `getAssetSpaces` treats as no spaces.

## User decisions to respect

- API key auth (`x-api-key`), stored with `LrPasswords` keyed by the gallery URL, never in the preset
  fields. Only https URLs are allowed.
- Stale and replaced assets are permanently deleted. Orphans from removing photos or collections go to the
  trash.
- Videos get an XMP sidecar on upload rather than metadata set through the API. It mirrors Lightroom's
  export behaviour: "Remove Person Info" drops person keywords and their parents; "Export Containing
  Keywords" affects the flat list but not the hierarchical paths.
- When `replacePeopleTags` is set and the export settings include people, photos with exported person
  keywords are uploaded with a sidecar holding only a `digiKam:TagsList` of their other tags plus the
  optional replacement tag (`peopleReplacementTag`), so people come from the face regions alone. An empty
  replacement tag is allowed and only warned about in the settings dialog. Videos do the same only when
  `replacePeopleInVideos` is also set.
- The Person Tags section is at the bottom of the dialog, since plug-in sections can't go next to Metadata.
  Its controls are disabled, not hidden, when the metadata settings exclude people, since Lightroom can't
  hide a whole section. The rows below the main checkbox are hidden while it is unchecked. Rows and columns
  don't accept `visible`, so anything that hides is wrapped in an `f:view`. State that depends on several
  settings comes from plain properties
  set by observers in `startDialog` (e.g. `includesPeople`), since a multi-key `bind` didn't work.
- Published photo URLs are `<gallery>/photos/<assetId>`.
- An asset recorded for a photo through a duplicate upload response, e.g. one uploaded by the gallery's
  mobile app, is replaced and permanently deleted like a plugin-uploaded asset if the photo later changes.
  The plugin can't tell the two apart since only the asset ID is stored, and this is accepted, including
  losing the asset's original file. README.md documents it.
- Problems caused by virtual copies that render byte-identical files, and so share one asset through a
  duplicate upload response, are intentionally ignored. Don't raise them, propose fixes for them or ask
  about them.
- The user manages version control (jj). Don't commit.
