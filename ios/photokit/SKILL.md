---
name: photokit
description: "iOS photo and camera capture for a fintech app — SwiftUI PhotosPicker + PhotosPickerItem (loadTransferable), UIKit PHPickerViewController, PhotoKit library access (PHPhotoLibrary.requestAuthorization(for: .readWrite/.addOnly), .limited library + presentLimitedLibraryPicker, PHPhotoLibraryChangeObserver), asset access (PHAsset / PHFetchResult / PHFetchOptions, PHImageManager / PHCachingImageManager, PHAssetChangeRequest / PHAssetCreationRequest), and custom AVFoundation capture (AVCaptureSession, AVCapturePhotoOutput, AVCaptureMovieFileOutput, AVCaptureVideoPreviewLayer, RotationCoordinator), plus the required Info.plist privacy strings. Use when picking images/videos, reading or saving to the photo library, gating on photo/camera permissions, or building a KYC/document-capture camera. For OCR / barcode / document scanning of the captured image use vision-framework; for on-device image ML use coreml; for permission-manifest / App Store review use app-store-review; for the KMP boundary see expect-actual."
---

# PhotoKit & AVFoundation Capture (iOS)

Photo-library picking, library access, and custom camera capture for a fintech iOS app
(document/ID capture, receipt attachments, avatars). Grounded in Apple's **PhotosUI**,
**Photos** (PhotoKit), and **AVFoundation** frameworks; targets the iOS 26 era.

- **Decision:** need a plain image/video pick with **no library permission**? Use `PhotosPicker` (SwiftUI) or `PHPickerViewController` (UIKit) — both run **out of process** and hand back only chosen items. Need to **enumerate/organize** the library, observe changes, or fetch by metadata? That requires `PHPhotoLibrary` authorization and PhotoKit. Need **live camera** (KYC selfie, ID/cheque scan)? Use AVFoundation.
- **Cross-refs:** OCR / barcode / MRZ / document rectangle detection on a captured frame → `vision-framework`; on-device image models → `coreml`; permission strings & privacy manifest for submission → `app-store-review`; if a KMP `commonMain` screen needs the picker, expose an `expect` capture interface bound to an `iosMain` `actual` → `expect-actual`.

## Contents

- [Privacy strings (required)](#privacy)
- [PhotosPicker (SwiftUI)](#photospicker)
- [PHPickerViewController (UIKit)](#phpicker)
- [Library authorization & limited access](#authorization)
- [Fetching assets (PHAsset)](#fetching)
- [Requesting images (PHImageManager)](#images)
- [Writing to the library (change requests)](#writing)
- [Custom camera capture (AVFoundation)](#capture)
- [Fintech guidance](#fintech)
- [Correctness checklist](#checklist)
- References: `references/asset-management.md` (fetch/caching/change-request depth), `references/av-capture.md` (full capture pipeline)

<a id="privacy"></a>
## Privacy strings (required)

Missing a required key = **hard crash** the moment the API is touched. Add to `Info.plist`:

| Key | When needed |
|---|---|
| `NSPhotoLibraryUsageDescription` | Read/write library access (`.readWrite`), `PHAsset` fetches, `PHImageManager`. |
| `NSPhotoLibraryAddUsageDescription` | Add-only access (`.addOnly`) — saving without ever reading. Prefer this when you only save. |
| `NSCameraUsageDescription` | Any `AVCaptureSession` with a camera input; also `PHPickerViewController`/`PhotosPicker` do **not** need it. |
| `NSMicrophoneUsageDescription` | Video capture **with audio** (adding an audio `AVCaptureDeviceInput`). |

- **`PhotosPicker` / `PHPickerViewController` need NONE of these** — that is the point of the out-of-process picker. Only reach for authorization + a usage string when you genuinely need library or camera APIs.
- Optional: `PHPhotoLibraryPreventAutomaticLimitedAccessAlert = YES` suppresses the once-per-launch limited-library reminder so you can drive `presentLimitedLibraryPicker` from your own UI.
- Write specific, honest strings ("Attach a photo of your ID to verify your identity") — vague strings are a common App Store rejection.

<a id="photospicker"></a>
## PhotosPicker (SwiftUI, iOS 16+)

Default for SwiftUI. No permission prompt, no usage string. Binds selected `PhotosPickerItem`(s); you load bytes with `loadTransferable`.

```swift
import SwiftUI
import PhotosUI

struct AttachmentPicker: View {
    @State private var item: PhotosPickerItem?
    @State private var imageData: Data?

    var body: some View {
        PhotosPicker(
            selection: $item,
            matching: .images,              // .images / .videos / .livePhotos / .screenshots; combine with .any(of:) / .not(_:)
            photoLibrary: .shared()
        ) {
            Label("Attach photo", systemImage: "paperclip")
        }
        .onChange(of: item) { _, newItem in
            Task {
                // loadTransferable is async and can return nil (user picked, then item unavailable / iCloud fetch failed).
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    imageData = data
                }
            }
        }
    }
}
```

- **Multiple selection:** `PhotosPicker(selection: $items, maxSelectionCount: 5, matching: .images)` where `items: [PhotosPickerItem]`. `maxSelectionCount` omitted or `0` ⇒ unlimited.
- **`loadTransferable(type:)`** accepts any `Transferable`. Use **`Data.self`** for robustness (then build `UIImage(data:)`); `Image.self` only succeeds when the item's `supportedContentTypes` includes PNG, so it often returns `nil` for HEIC/JPEG — do not rely on it. For custom formats implement your own `Transferable` with the right `UTType`.
- Prefer the `matching:` filter to constrain types up front (e.g. `.any(of: [.images, .not(.screenshots)])`).
- `PhotosPickerItem.itemIdentifier` is non-nil only when `photoLibrary: .shared()` is passed; use it to correlate back to a `PHAsset`.
- **iOS 26 embedded picker:** the inline/embedded `PhotosPicker` presentation styles let the grid live inside your view instead of a sheet — the `selection` binding contract is unchanged.

<a id="phpicker"></a>
## PHPickerViewController (UIKit, iOS 14+)

Same out-of-process, permission-free picker for UIKit or when wrapping in `UIViewControllerRepresentable`.

```swift
import PhotosUI

var config = PHPickerConfiguration(photoLibrary: .shared())  // pass a library to get asset identifiers back
config.selectionLimit = 1                                    // 0 = unlimited
config.filter = .any(of: [.images, .livePhotos])             // .images / .videos / .livePhotos
config.preferredAssetRepresentationMode = .current           // avoid transcoding when possible

let picker = PHPickerViewController(configuration: config)
picker.delegate = self
present(picker, animated: true)
```

```swift
func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    for result in results {
        let provider = result.itemProvider               // NSItemProvider
        if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { object, error in
                // Delivered on a background queue — hop to the main actor for UI.
                guard let image = object as? UIImage else { return }
                Task { @MainActor in /* use image */ }
            }
        }
        // result.assetIdentifier is a PHAsset localIdentifier when a shared library was configured.
    }
}
```

- Dismiss the picker yourself in the delegate; an empty `results` array means the user cancelled.
- For raw file data (e.g. to preserve original bytes/EXIF), use `provider.loadFileRepresentation(forTypeIdentifier:)` or `loadDataRepresentation(forTypeIdentifier: UTType.image.identifier)` instead of `loadObject`.

<a id="authorization"></a>
## Library authorization & limited access

Only needed for **PhotoKit** APIs (`PHAsset`, `PHImageManager`, change requests) — **not** for the pickers above.

```swift
import Photos

// Request the minimum level you need: .addOnly if you only save, .readWrite to read/enumerate.
let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
switch status {
case .authorized:    break              // full access
case .limited:       break              // user granted a subset (readWrite only); PhotoKit sees only those assets
case .denied, .restricted: break        // route the user to Settings; do not re-prompt
case .notDetermined: break              // should not occur right after requesting
@unknown default:    break
}

// Non-blocking check without prompting:
let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
```

- **Ask for the least access.** `.addOnly` needs only `NSPhotoLibraryAddUsageDescription` and never exposes the user's library. Requesting `.readWrite` when you only save is a rejection risk.
- **`.limited` (iOS 14+)** applies only to `.readWrite`. All `PHAsset` fetches then return **only** the user-selected subset — design for a partial library, never assume you can see everything.
- Let the user **expand** their limited selection on demand:

```swift
// From a view controller, in response to an explicit user action (e.g. "Select more photos"):
PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)
```

- Observe library changes (assets added/removed, limited selection edited) by conforming to `PHPhotoLibraryChangeObserver` and registering with `PHPhotoLibrary.shared().register(self)`; apply deltas via `changeInstance.changeDetails(for:)`. See `references/asset-management.md`.

<a id="fetching"></a>
## Fetching assets (PHAsset)

```swift
let options = PHFetchOptions()
options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
options.fetchLimit = 100                 // cap work; PHFetchResult is lazy but bound the query

let result: PHFetchResult<PHAsset> = PHAsset.fetchAssets(with: options)
result.enumerateObjects { asset, index, stop in
    // asset.localIdentifier, .creationDate, .pixelWidth/Height, .mediaType, .mediaSubtypes
}
```

- `PHFetchResult` is **lazy and dynamic** — index into it (`result.object(at:)`, `result.count`) rather than materializing an array; it reflects an efficient database cursor.
- Fetch by identifiers from a picker result: `PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)`.
- Under `.limited`, fetches are automatically scoped to the granted subset — a smaller `count` is expected, not an error.

<a id="images"></a>
## Requesting images (PHImageManager)

An asset is metadata; you request a rendered image/video asynchronously (it may download from iCloud).

```swift
let manager = PHImageManager.default()
let opts = PHImageRequestOptions()
opts.deliveryMode = .highQualityFormat   // or .opportunistic (may call the handler multiple times)
opts.isNetworkAccessAllowed = true       // permit iCloud download; without this an iCloud-only asset returns nil
opts.resizeMode = .exact

manager.requestImage(
    for: asset,
    targetSize: CGSize(width: 300, height: 300),   // .zero + .aspectFit for full-res
    contentMode: .aspectFill,
    options: opts
) { image, info in
    // With .opportunistic this fires more than once (degraded → full). Check info[PHImageResultIsDegradedKey].
    // info[PHImageErrorKey] / info[PHImageCancelledKey] report failure/cancel.
}
```

- **Scrolling grids:** use `PHCachingImageManager`; call `startCachingImages(for:targetSize:contentMode:options:)` ahead of the visible window and `stopCachingImages(...)` as it leaves. Keep `targetSize` and options **identical** to your later `requestImage` calls or the cache misses.
- `.opportunistic` can invoke the handler multiple times (fast degraded image first, then full) — guard against downgrading a good image and always hop to `@MainActor` for UI.
- Full sizing/caching/iCloud-progress patterns in `references/asset-management.md`.

<a id="writing"></a>
## Writing to the library (change requests)

All mutations run inside a `performChanges` block. Needs `.addOnly` (to save) or `.readWrite` (to edit/delete).

```swift
// Save a captured JPEG as a new asset (async form, iOS 15+).
try await PHPhotoLibrary.shared().performChanges {
    let request = PHAssetCreationRequest.forAsset()
    request.addResource(with: .photo, data: jpegData, options: nil)
    // or from a file URL: PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
}
```

- Completion-handler form: `PHPhotoLibrary.shared().performChanges(_:completionHandler:)`; the async `throws` variant is cleaner where available.
- Other requests inside the block: `PHAssetChangeRequest(for:)` to edit, `PHAssetChangeRequest.deleteAssets(_:)` (prompts the user for confirmation), `PHAssetCollectionChangeRequest` for albums.
- To keep a reference to the created asset, capture its `placeholderForCreatedAsset?.localIdentifier` inside the block, then fetch it after the block succeeds.
- **Never** mutate the library outside `performChanges` — direct changes are unsupported and throw.

<a id="capture"></a>
## Custom camera capture (AVFoundation)

Use only when the system pickers/`UIImagePickerController` are insufficient — e.g. a guided KYC/ID/cheque capture with overlays. Requires `NSCameraUsageDescription` (and `NSMicrophoneUsageDescription` for audio).

Pipeline: **`AVCaptureSession`** ← inputs (`AVCaptureDeviceInput`) → outputs (`AVCapturePhotoOutput` / `AVCaptureMovieFileOutput`), previewed with `AVCaptureVideoPreviewLayer`.

```swift
import AVFoundation

let session = AVCaptureSession()
session.sessionPreset = .photo

// Configure atomically inside begin/commit; run start/stop off the main thread.
session.beginConfiguration()
guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input) else { session.commitConfiguration(); return }
session.addInput(input)

let photoOutput = AVCapturePhotoOutput()
if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
session.commitConfiguration()

// startRunning blocks — dispatch off the main actor.
Task.detached { session.startRunning() }
```

```swift
// Capture. AVCapturePhotoSettings is single-use — make a fresh one each shot.
let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
settings.flashMode = .auto
photoOutput.capturePhoto(with: settings, delegate: self)

func photoOutput(_ output: AVCapturePhotoOutput,
                 didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard error == nil, let data = photo.fileDataRepresentation() else { return }
    // `data` is a self-contained HEIC/JPEG (metadata embedded) — hand to Vision, or save via performChanges.
}
```

- **Authorize first:** `AVCaptureDevice.requestAccess(for: .video)` (async `Bool`); check `authorizationStatus(for:)` before building the session.
- **Orientation (iOS 17+):** `AVCaptureConnection.videoOrientation` is deprecated. Drive `connection.videoRotationAngle` from an **`AVCaptureDevice.RotationCoordinator`** (`videoRotationAngleForHorizonLevelCapture` for the photo output, `...HorizonLevelPreview` for the preview layer). Rotation values differ across device generations — read them from the coordinator, never hardcode.
- **Video:** add `AVCaptureMovieFileOutput`, an audio `AVCaptureDeviceInput`, then `startRecording(to: url, recordingDelegate:)`; finalize in `fileOutput(_:didFinishRecordingTo:from:error:)`.
- Preview: wrap `AVCaptureVideoPreviewLayer(session:)` in a `UIViewRepresentable`; set `videoGravity = .resizeAspectFill`.
- Full session lifecycle, interruptions, rotation coordinator, and video recording in `references/av-capture.md`.

<a id="fintech"></a>
## Fintech guidance

- **Prefer the out-of-process picker** for receipts/attachments — no library permission, smaller privacy surface, less to justify in App Store review.
- **Custom camera only for guided KYC/ID/cheque** flows that need overlays or edge detection; pair with `vision-framework` (document rectangle, MRZ/OCR, barcode) rather than shipping the raw camera roll.
- Treat captured ID/document images as **sensitive**: do not auto-save KYC captures to the user's photo library (avoid `PHAssetCreationRequest` for them), strip/avoid embedding location, and keep bytes in memory or an encrypted store — see `swift-security` for at-rest encryption. Never log image data or asset identifiers.
- Request the **minimum access level** (`.addOnly` over `.readWrite`) and design every fetch path to work under `.limited`.
- Uploading? Hand the raw `Data` to your networking layer over TLS; don't stage sensitive captures in a shared/temp location.

<a id="checklist"></a>
## Correctness checklist

- [ ] Required usage string present for every API touched (`NSPhotoLibraryUsageDescription` / `NSPhotoLibraryAddUsageDescription` / `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`) — else it crashes.
- [ ] Plain image/video pick uses `PhotosPicker`/`PHPickerViewController` (no permission), not PhotoKit authorization.
- [ ] `loadTransferable(type: Data.self)` (not `Image.self`) and handle the `nil`/throw case.
- [ ] Request the **least** access level; `.readWrite` only when you actually enumerate/edit.
- [ ] Handle `.limited` — fetches see only the granted subset; offer `presentLimitedLibraryPicker` to expand.
- [ ] `.denied`/`.restricted` routes to Settings; never loop re-prompting.
- [ ] `PHImageManager` requests set `isNetworkAccessAllowed` for iCloud assets; `.opportunistic` handler may fire multiple times.
- [ ] `PHCachingImageManager` uses matching `targetSize`/options for cache hits; stop caching off-screen.
- [ ] All library mutations inside `performChanges`; capture `placeholderForCreatedAsset` for the new id.
- [ ] Camera: authorize with `AVCaptureDevice.requestAccess`; `begin/commitConfiguration` around setup; `startRunning`/`stopRunning` off the main thread.
- [ ] Fresh `AVCapturePhotoSettings` per shot; use `AVCaptureDevice.RotationCoordinator` for orientation (not deprecated `videoOrientation`).
- [ ] Callbacks (`PHImageManager`, `NSItemProvider`, capture delegates) hop to `@MainActor` before touching UI.
- [ ] Sensitive KYC/ID captures are not written to the photo library and not logged.
