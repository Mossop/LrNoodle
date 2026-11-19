# LrNoodle

A Lightroom Classic plugin supporting publishing photos to [Noodle Gallery](https://opennoodle.de/) and
[Immich](https://immich.app/).

Each publish collection becomes an album in the gallery. A photo is stored in the gallery once, no matter
how many collections it is published in, and is added to the album for each of them.

## Requirements

- Lightroom Classic 16 or later.
- A Noodle Gallery or Immich server reachable over https.
- An API key for your gallery account.

## Compatibility

The plugin works with both Noodle Gallery and Immich. It only uses features Immich also has, apart from
Noodle Gallery's shared spaces, which it handles where present and skips on Immich. It has only been
tested with Noodle Gallery so far. If you use it with Immich, please report any problems.

## Installation

1. Download `LrNoodle.zip` and unzip it to get `LrNoodle.lrplugin`.
2. In Lightroom choose File → Plug-in Manager, click Add and select `LrNoodle.lrplugin`.

## Setting up

1. In the gallery, open your account settings and create an API key with the permissions listed below.
2. In Lightroom's Publish Services panel click the + next to Noodle Gallery (or Set Up) to open the Publish
   Manager.
3. Enter your gallery's address (it must start with `https://`) and the API key. The plugin checks the
   connection and shows any problem in red below the fields.
4. Choose your export settings and click Save.

New services default to JPEG at 90% quality for photos and H.264 High for videos, with videos included. You
can change these like any other export setting.

The API key is stored in Lightroom's encrypted password storage, not in the publish settings or presets. If
you change the gallery address you will need to enter the key again.

### API key permissions

The API key can be given every permission, or limited to just the ones the plugin needs:

- every `asset` permission (`asset.read`, `asset.upload`, `asset.update`, `asset.delete`, `asset.copy` and
  the rest),
- every `album` permission (`album.read`, `album.create`, `album.update`, `album.delete` and the rest),
- `albumAsset.create` and `albumAsset.delete`,
- `user.read`,
- `sharedSpaceAsset.create` (Noodle Gallery only), so a changed photo's new asset can be added to the shared
  spaces the old one was in.

## Publishing

- **Collections and albums**: each publish collection publishes to an album with the same name. The album
  is created the first time the collection is published. Renaming the collection renames the album.
- **Photos in several collections**: a photo is uploaded once and the same gallery asset is added to every
  album it is published to. Adding an already published photo to another collection just adds it to that
  album without uploading it again.
- **Changed photos**: the gallery can't replace an asset's file, so a changed photo is uploaded as a new
  asset. Everything is copied over from the old asset (albums, favourites, shared links and so on, and on
  Noodle Gallery its shared spaces) and the old asset is permanently deleted. Copies of the photo in other
  collections are marked to be republished so they pick up the new asset.
- **Photos deleted in the gallery**: if a photo or album has been deleted in the gallery it is uploaded or
  created again the next time you publish. Assets in the gallery's trash are restored.
- **Duplicates**: if the gallery already has an identical file, for example one uploaded from your phone,
  that asset is used as it is instead of uploading another copy. If you later change the photo in
  Lightroom, that asset is replaced like any other: the new upload takes over its albums, favourite and so
  on, and the existing asset, including its original file, is permanently deleted.
- **Errors**: if publishing a photo fails part way through, anything uploaded for it is removed again so
  nothing is left behind in the gallery.

## Removing photos and collections

- Removing a photo from a collection removes it from that collection's album.
- Deleting a collection deletes its album.

A photo is only moved to the gallery's trash if nothing else is using it. It is kept if it is:

- still in another published collection,
- in an album that isn't published from Lightroom, or in a published album you added it to in the gallery
  without it being in the matching collection,
- in a shared space (Noodle Gallery only).

If the plugin can't check, it keeps the photo rather than risk trashing something still in use.

## Videos

Lightroom doesn't embed metadata in exported videos, so the plugin uploads videos with an XMP sidecar file
holding their metadata. It follows the Metadata section of the publish settings:

- Capture date, title, caption and rating.
- GPS location, unless "Remove Location Info" is checked or the location is marked private.
- Keywords, following each keyword's "Include on Export" and "Export Containing Keywords" settings and the
  choice of flat or hierarchical keywords. With "Remove Person Info" checked, person keywords and their
  parents are left out.
- Nothing is included if the metadata setting is "Copyright Only" or "Copyright & Contact Info Only".

### Known limitations

- Changing only a video's metadata may not update the gallery. The video file itself is unchanged, so the
  gallery treats the upload as a duplicate and may ignore the new metadata.
- The gallery has no title field, so a video's title is not shown.

## Troubleshooting

The plugin writes a log file, `LrNoodle.log`, to Lightroom's log folder (on macOS
`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/`). By default only warnings and errors are logged. To log
details of every decision the plugin makes while publishing, check "Enable debug logging" for Noodle Gallery
in the Plug-in Manager.

## Development

Use [mise](https://mise.jdx.dev/) tasks to perform checks and packaging. Run `mise tasks` to see what is
available:

- `mise r setup` installs luacheck and busted.
- `mise r test` runs the tests.
- `mise r integration` runs the integration tests against a Noodle Gallery server it starts in Docker. It
  needs Docker and curl.
- `mise r stylua`, `mise r luacheck` and `mise r typecheck` format, lint and type check the plugin.
- `mise r package` runs the checks and builds `LrNoodle.zip` for distribution.

The type check uses the Lightroom SDK type definitions from
[lightroom-lua](https://github.com/Mossop/lightroom-lua); `.luarc.json` points at a local checkout.
