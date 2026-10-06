# Photoshopper3000 for iPhone

A native client for [Photoshopper3000](https://github.com/MCDuckler): review, edit and
publish your RAWs from the phone, and carry the photos you pick into a Photos album so
iCloud Photos has them on every device.

## Review, edit, publish

- **Review tab.** One photo at a time over any album, folder or rating filter. Swipe right
  to keep (★5 by default), left to reject, up to skip; slide across the stars to grade.
  Press and hold the photo to lift it, then drop it on an album. Pinch or double-tap to
  check focus. Works offline: ratings and album changes queue on the phone and reach the
  server (last writer wins) when it is back.
- **Editor.** Light, Color, Effects, Looks and Crop, with the same pipeline as the server:
  exposure through vignette on ruler dials, tone curve, colour mix per hue band, B&W mixer,
  split toning, film looks (LUTs) with favourites, light leaks, borders, date stamp, crop
  with aspect lock and rotate. A Metal shader mirrors the server's maths for instant
  feedback; the server render fades in a moment later. Hold the photo for the original,
  swipe for the next one. Autosaves, undo/redo, presets, copy/paste edits, auto, histogram,
  share or save the full render.
- **Library.** Justified grid by month, sort, rating filter; select to rate, file into
  albums, paste edits, apply a preset, export or share. Albums can be created, renamed,
  deleted and published as web galleries (share link, QR, sync).

## Phone album

- **Only what you select.** In Photoshopper: Library › Select › *Phone* › *Sync to phone*
  (full quality or web size). The app syncs exactly that set, nothing implicit.
- **Re-edits replace.** Edit a synced photo again and the next sync puts the new render in
  the album and removes the old one (iOS asks once per sync to confirm deletions).
- **Deselect removes.** *Remove from phone* takes it out of Photos on the next sync.
- **Capture date kept.** Photos land at the moment they were shot, not at import time.
- **Reinstall-safe.** Every exported JPEG carries an XMP tag with its Photoshopper id and
  edit hash; Settings › *Re-scan album* rebuilds the sync record from the album.
- Syncs when opened, on pull-to-refresh, and in the background (iOS decides when, usually
  on the charger). LAN only: the phone must reach the Photoshopper server.

## Install

1. Install [SideStore](https://sidestore.io).
2. SideStore › Sources › add `https://mcduckler.github.io/photoshopper-ios/apps.json`
   (or open https://mcduckler.github.io/photoshopper-ios/ on the phone).
3. Install *Photoshopper3000*, open it, pick your server (it is found automatically on
   the same Wi-Fi), allow Photos access (Full Access).

SideStore re-signs the app every 7 days with your Apple ID and offers updates when a new
build is published.

## Build

`.github/workflows/build.yml` builds on a macOS runner, unsigned (no certificates or
Apple credentials anywhere), attaches the `.ipa` to a GitHub Release and regenerates the
SideStore source on the `gh-pages` branch. Run it from the Actions tab or push a `v*` tag.

Locally on a Mac: `brew install xcodegen && xcodegen && open Photoshopper3000.xcodeproj`.

## Server API used

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | reachability |
| `GET /api/sync/set` | selected photos with their current recipe hash |
| `POST /api/sync/prepare` | render the set ahead of the phone |
| `GET /api/photos/{id}/export?variant=full\|web&hash=` | rendered JPEG with XMP tag; 409 if the edit changed |
| `POST /api/ops` | queued ratings, album and edit changes from the phone |
| `GET/PUT/DELETE /api/photos/{id}/edit`, `POST …/preview_edit`, `POST …/render` | editor |
| `/api/presets`, `/api/luts`, `/api/overlays/*`, `/api/edits/batch` | looks, presets, batch edits |
| `/api/albums`, `/api/publish/targets` | albums and galleries |

Bundle id `dance.duckduck.p3k`, iOS 17+, SwiftUI, no third-party packages.
