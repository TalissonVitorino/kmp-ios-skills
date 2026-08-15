# PhotoKit asset management — depth

Fetching, caching, change observation, and library mutation with the **Photos** framework.
Read alongside the `photokit` SKILL. All of this requires `PHPhotoLibrary` authorization
(`.readWrite` to read/enumerate, `.addOnly` to save only) and the matching Info.plist string.

## PHFetchOptions in depth

```swift
let opts = PHFetchOptions()
opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
opts.fetchLimit = 200                                  // bound the cursor
opts.includeHiddenAssets = false
opts.includeAllBurstAssets = false
// Media-type / subtype predicates:
opts.predicate = NSPredicate(
    format: "mediaType == %d AND (mediaSubtypes & %d) == 0",
    PHAssetMediaType.image.rawValue,
    PHAssetMediaSubtype.photoScreenshot.rawValue)      // exclude screenshots
```

- Common `PHAsset` keys usable in predicates/sorts: `creationDate`, `modificationDate`, `mediaType`, `mediaSubtypes`, `pixelWidth`, `pixelHeight`, `duration`, `isFavorite`, `burstIdentifier`.
- `PHAssetMediaSubtype` bit flags: `.photoPanorama`, `.photoHDR`, `.photoScreenshot`, `.photoLive`, `.photoDepthEffect`, `.videoHighFrameRate`, `.videoTimelapse`, `.videoCinematic`.

## Fetch entry points

```swift
PHAsset.fetchAssets(with: opts)                                  // all assets
PHAsset.fetchAssets(with: .image, options: opts)                 // by media type
PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)     // from picker assetIdentifiers
PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
    subtype: .smartAlbumUserLibrary, options: nil)               // albums, then fetchAssets(in:options:)
```

- `PHFetchResult<PHAsset>` is a live, lazily-evaluated cursor. Use `count`, `object(at:)`, `enumerateObjects(_:)`, `index(of:)`. Do **not** eagerly map it to `[PHAsset]` for large libraries.
- Keep the `PHFetchResult` around if you register a change observer — you update it with `changeDetails.fetchResultAfterChanges`.

## PHImageManager — sizing, iCloud, progress

```swift
let opts = PHImageRequestOptions()
opts.deliveryMode = .highQualityFormat   // .opportunistic | .highQualityFormat | .fastFormat
opts.resizeMode = .exact                 // .none | .fast | .exact
opts.isNetworkAccessAllowed = true       // allow iCloud download (otherwise iCloud-only asset → nil image)
opts.isSynchronous = false               // never true on the main thread
opts.progressHandler = { progress, error, stop, info in
    // iCloud download progress 0...1 — deliver to UI on @MainActor
}

let id = PHImageManager.default().requestImage(
    for: asset,
    targetSize: PHImageManagerMaximumSize,   // or a point size * screen scale for thumbnails
    contentMode: .aspectFit,
    options: opts) { image, info in
        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
        if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }
        if info?[PHImageErrorKey] != nil { /* handle */ }
        // With .opportunistic: first call may be a low-res placeholder (degraded == true), then full-res.
}
// Cancel a stale request (e.g. cell reused) with the returned id:
PHImageManager.default().cancelImageRequest(id)
```

- Multiply point sizes by `UIScreen.main.scale` (or the view's `displayScale`) to request pixel-accurate thumbnails.
- For full-fidelity original bytes (upload, EXIF): `requestImageDataAndOrientation(for:options:resultHandler:)` returns `Data` + `orientation`.
- For video: `requestAVAsset(forVideo:options:resultHandler:)` or `requestPlayerItem(...)`.

### PHCachingImageManager for grids

```swift
let cache = PHCachingImageManager()
let size = CGSize(width: 200, height: 200)
let mode: PHImageContentMode = .aspectFill

// Prefetch a window ahead of scroll:
cache.startCachingImages(for: assetsAboutToAppear, targetSize: size, contentMode: mode, options: opts)
cache.stopCachingImages(for: assetsThatLeft, targetSize: size, contentMode: mode, options: opts)
// Reset everything (e.g. on library change):
cache.stopCachingImagesForAllAssets()
```

- **Cache key = (asset, targetSize, contentMode, options).** Your later `requestImage` calls must use the *same* `targetSize`/`contentMode`/`options` or you get cache misses and redundant decodes.
- Drive `start`/`stop` from your collection view's prefetch APIs (`UICollectionViewDataSourcePrefetching`) or `LazyVGrid` visibility.

## Observing library changes

```swift
final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    var assets: PHFetchResult<PHAsset>

    init(assets: PHFetchResult<PHAsset>) {
        self.assets = assets
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let details = changeInstance.changeDetails(for: assets) else { return }
        let updated = details.fetchResultAfterChanges
        Task { @MainActor in
            self.assets = updated
            if details.hasIncrementalChanges {
                // Apply details.removedIndexes / insertedIndexes / changedIndexes to your collection view
                // in the order: delete, insert, reload, then details.enumerateMoves.
            } else {
                // Full reload.
            }
        }
    }
}
```

- `photoLibraryDidChange` is delivered on an arbitrary queue — marshal all state/UI updates to the main actor.
- Fires when the user edits their **limited** selection, so a `.limited` app should observe and refresh.

## Writing / mutating

```swift
// Create from data with a resource (control filename, UTI, orientation via options):
try await PHPhotoLibrary.shared().performChanges {
    let req = PHAssetCreationRequest.forAsset()
    let resourceOptions = PHAssetResourceCreationOptions()
    resourceOptions.originalFilename = "receipt.heic"
    req.addResource(with: .photo, data: heicData, options: resourceOptions)
}

// Capture the new asset's id:
var placeholder: PHObjectPlaceholder?
try await PHPhotoLibrary.shared().performChanges {
    let req = PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
    placeholder = req.placeholderForCreatedAsset
}
let newId = placeholder?.localIdentifier   // fetch with fetchAssets(withLocalIdentifiers:)

// Delete (system shows a confirmation alert):
try await PHPhotoLibrary.shared().performChanges {
    PHAssetChangeRequest.deleteAssets([asset] as NSArray)
}

// Favorite / edit metadata:
try await PHPhotoLibrary.shared().performChanges {
    let req = PHAssetChangeRequest(for: asset)
    req.isFavorite = true
}
```

- Every mutation MUST be inside `performChanges`; direct property sets on a `PHAsset` are read-only and unsupported.
- Album management: `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`, then `addAssets(_:)` inside the same block.
- Editing pixels (filters/crops): request content with `PHContentEditingInputRequestOptions`, produce a `PHContentEditingOutput`, and set `request.contentEditingOutput` — full flow is beyond attachment use cases.

## Common failure modes

- iCloud-only asset returns a `nil` image because `isNetworkAccessAllowed` was left `false`.
- Treating `.opportunistic` degraded callbacks as final → blurry thumbnail sticks; check `PHImageResultIsDegradedKey`.
- Cache misses from mismatched `targetSize`/options between `startCachingImages` and `requestImage`.
- Assuming a full library under `.limited` — always design for the subset and observe changes.
- Forgetting `unregisterChangeObserver` → retain/leak of the observer.
