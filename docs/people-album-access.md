# Can Hearth use the Photos "People & Pets" album?

**Date:** 2026-07-21
**Question:** Photos already identifies people (and pets). Can a third-party app read that
instead of rebuilding face clustering from scratch?

**Answer: No.** Verified against the iOS 26.5 SDK and confirmed by an official Apple
statement. This is enforced, not merely undocumented.

---

## What Apple says

An Apple DTS Engineer, on the Developer Forums (Dec 2022):

> "There is no api to access the People album, please file a feature request using
> Feedback Assistant."

An earlier thread has Apple staff confirming the same, with the added detail that Apple
**actively blocks even private APIs** for this — so there is no undocumented back door,
and attempting one would fail review regardless.

## What's actually in the SDK

Grepping `Photos.framework` in the iOS 26.5 SDK for person/face terms returns exactly two
constants, both of which look promising and neither of which is the People album:

| Constant | What it really is |
|---|---|
| `PHAssetCollectionSubtypeAlbumSyncedFaces` (4) | Faces synced from **iPhoto/Aperture via iTunes** |
| `PHCollectionListSubtypeSmartFolderFaces` (201) | Same legacy iPhoto sync path |

The enum layout settles it. `AlbumSyncedFaces = 4` sits inside the block commented
`// PHAssetCollectionTypeAlbum regular subtypes`, between `AlbumSyncedEvent = 3` and
`AlbumSyncedAlbum = 5` — the iTunes-sync family. The modern People album is a *smart*
album (subtypes 200–220), so a constant in the synced-album group structurally cannot
address it. iTunes photo syncing from iPhoto is long dead, so these are empty on any
current device.

Notably the smart-album enum is still actively maintained — `SmartAlbumSpatial` arrived in
iOS 18 — so the absence of a People subtype is a deliberate choice, not neglect.

## Routes checked and ruled out

- **iOS 17 "People & Pets"** shipped as a user-facing feature with **no API surface at
  all**. No pet-recognition API exists in any framework.
- **`PHPickerViewController`** has no person filter. Every `PHPickerFilter` is a media-type
  filter (images, videos, bursts, panoramas, …). And the picker runs out-of-process
  returning opaque `NSItemProvider`s — by default the app gets no `PHAsset` and no
  `localIdentifier`, so there is no user-mediated path either.
- **`PHAsset` properties** expose nothing face-related. `localIdentifier` is an opaque
  UUID.
- **EXIF face rectangles.** A widely-repeated forum claim says Apple stores face rects in
  image metadata. `CGImageProperties.h` has no public Apple face keys — the only
  person-related constants are IPTC Extension fields for *manually authored* credits,
  empty on ordinary iPhone photos. **Do not build on this.**
- **Vision.** Does detection, never identification. `RecognizeAnimalsRequest` classifies
  species (cat vs. dog), not individual pets. `GeneratePersonInstanceMaskRequest` segments
  a person from the background without saying who they are.
- **Entitlements / partner access.** None found. DTS pointing to Feedback Assistant is
  what Apple says when no gated path exists.

Apple's face-identity embeddings live in the Photos daemon's sandbox (`libfaceCore.tbd`
ships in the SDK with no public headers) and never surface to third-party apps.

## What this means for Hearth

The only supported architecture is what we already built: **our own Vision detection, our
own clustering, our own naming, on assets the user explicitly grants us.** We are
rebuilding the People album, not reading it.

Two consequences worth stating plainly:

1. **Our labels will not match Apple's.** A user who has carefully named 40 people in
   Photos gets none of that. They must name people again inside Hearth. That is
   unavoidable, and it is the biggest onboarding cost in the product.
2. **We cannot match Apple's accuracy for free.** Photos uses a private, purpose-built
   face-recognition model. We have a general-purpose image descriptor
   ([vision-findings.md](./vision-findings.md) §2) or a licensable third-party model
   ([core-ml-comparison.md](./core-ml-comparison.md)).

## Runtime check

Rather than leaving "these constants are empty" as inference, it was measured. Fetching
both subtypes against a photo library on iOS 26 returns:

```
Synced-faces albums:       0
Smart-folder faces lists:  0
```

Matching the header analysis. The same probe is wired into the app's **Diagnostics**
screen (`probeLegacyFacesCollections()`), so it can be re-confirmed on a real device with
a real library — useful if a future iOS release changes anything. It reads collection
titles and counts only, never photo content.
