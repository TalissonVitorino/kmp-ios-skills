---
name: vision-framework
description: "On-device image analysis for an iOS fintech app with Apple's Vision + VisionKit. Covers the modern Swift Vision API (iOS 18+: RecognizeTextRequest OCR, DetectFaceRectanglesRequest, DetectBarcodesRequest, DetectDocumentSegmentationRequest, GenerateForegroundInstanceMaskRequest, TrackObjectRequest, CoreMLRequest, all with async .perform(on:) and ImageRequestHandler), the legacy VNRequest + VNImageRequestHandler + VNRecognizeTextRequest path for iOS 17 and earlier, VisionKit live capture (DataScannerViewController, VNDocumentCameraViewController, ImageAnalyzer/ImageAnalysisInteraction Live Text), normalized-coordinate/orientation handling, and custom-model VNCoreMLRequest. Use for scanning ID/cards/cheques, KYC document capture, barcode/QR reading, receipt OCR, or face-rectangle detection. For loading the Core ML model itself use coreml; for post-OCR text tagging/translation use natural-language; for the camera/photo pipeline feeding frames use photokit; to wrap a scanner UIViewController in SwiftUI use swiftui-uikit-interop; to expose results to shared KMP code use kmp-ios-integration."
---

# Vision & VisionKit (iOS)

On-device computer vision for a fintech app: OCR of cards/cheques/IDs, barcode/QR
scanning, document capture for KYC, and custom Core ML inference. Everything here
runs **on device** — no image ever leaves the phone, which is the right posture
for KYC/PII. Grounded in Apple's Vision and VisionKit frameworks.

- **Two Vision APIs coexist.** The **modern Swift API** (`RecognizeTextRequest`, `struct`/`class` requests with `async .perform(on:)`) needs **iOS 18+**. The **legacy API** (`VNRecognizeTextRequest` + `VNImageRequestHandler`) works back to iOS 13 and is still the path when you support iOS 17 or earlier. Same ML models underneath; different surface.
- **VisionKit** is a separate framework for *UI*: full-screen live scanners and Live Text overlays. Reach for it before hand-rolling an `AVCaptureSession` + Vision loop.
- **Do NOT confuse with visionOS.** This skill is Apple's image-analysis `Vision`, unrelated to the Apple Vision Pro platform.

## Contents

- [Which API to use](#which-api)
- [Modern request lifecycle (iOS 18+)](#modern-lifecycle)
- [Text recognition (OCR)](#ocr)
- [Barcode / QR detection](#barcodes)
- [Face rectangles](#faces)
- [Document segmentation & foreground mask](#document)
- [Object tracking (stateful)](#tracking)
- [Custom Core ML models](#coreml)
- [VisionKit — live capture UI](#visionkit)
- [Coordinates & orientation](#coordinates)
- [KMP boundary](#kmp)
- [Performance & privacy](#performance)
- [Correctness checklist](#checklist)
- References: `references/legacy-vnrequest.md`, `references/visionkit.md`, `references/coordinates-performance.md`

<a id="which-api"></a>
## Which API to use

| You need… | Use | Min iOS |
|---|---|---|
| Still-image OCR / detection, new code, iOS 18+ only | Modern Vision (`RecognizeTextRequest`, …) | 18 |
| Same, but supporting iOS 17 or earlier | Legacy Vision (`VNRecognizeTextRequest` + `VNImageRequestHandler`) | 13 |
| Full-screen **live** camera scanner (text + codes), minimal code | VisionKit `DataScannerViewController` | 16 |
| Guided multi-page **document scan** (edge detect, deskew, capture) | VisionKit `VNDocumentCameraViewController` | 13 |
| **Live Text** selection/data-detectors over a static image | VisionKit `ImageAnalyzer` + `ImageAnalysisInteraction` | 16 |
| Run your own trained classifier/detector | `CoreMLRequest` (modern) / `VNCoreMLRequest` (legacy) | 18 / 11 |

- For a shipping app with a wide deployment target, a common shape is: **VisionKit for the capture UI**, **legacy `VNImageRequestHandler`** for any still-image analysis you do yourself until your floor reaches iOS 18.
- The modern requests are value/reference types (`struct RecognizeTextRequest`, `struct CoreMLRequest`, `final class TrackObjectRequest`) that conform to `VisionRequest`; there is **no** `VN`-prefixed handler in the modern path.

<a id="modern-lifecycle"></a>
## Modern request lifecycle (iOS 18+)

Every modern request exposes `perform(on:orientation:)` **and** can be batched through an `ImageRequestHandler`.

```swift
import Vision

// A) One request, one image — the request performs itself.
let request = RecognizeTextRequest()
let observations = try await request.perform(on: imageData)   // [RecognizedTextObservation]

// B) Several requests, one decode of the image — use a handler.
let handler = ImageRequestHandler(cgImage)                     // or Data/URL/CVPixelBuffer/CIImage/CMSampleBuffer
let text = try await handler.perform(RecognizeTextRequest())
// Independent request types → performAll returns an async sequence of results.
for try await result in handler.performAll([RecognizeTextRequest(), DetectBarcodesRequest()]) {
    switch result {
    case .recognizeText(_, let obs): handle(text: obs)
    case .detectBarcodes(_, let obs): handle(codes: obs)
    default: break
    }
}
```

- `perform(on:)` accepts `Data`, `URL`, `CGImage`, `CGImageSource`, `CVPixelBuffer`, `CMSampleBuffer`, or `CIImage`, each with an optional `CGImagePropertyOrientation`.
- Prefer a single **`ImageRequestHandler`** when you run multiple requests on the same frame — it decodes the image once.
- Requests are `Sendable` value types; create fresh ones freely. Stateful ones (tracking) are the exception — see below.
- All observations conform to `VisionObservation`; spatial ones conform to `BoundingBoxProviding` (`.boundingBox: NormalizedRect`) and often `QuadrilateralProviding` (four corners).

<a id="ocr"></a>
## Text recognition (OCR)

The workhorse for cards, cheques, statements, IDs.

```swift
import Vision

func recognizeText(in image: CGImage) async throws -> [String] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate          // .fast for live/low-latency
    request.usesLanguageCorrection = true
    request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
    // Domain hints raise accuracy on jargon / non-dictionary tokens:
    request.customWords = ["IBAN", "SWIFT", "CVV"]
    request.minimumTextHeight = 0.02              // ignore tiny noise (fraction of image height)

    let observations = try await request.perform(on: image)     // [RecognizedTextObservation]
    return observations.compactMap { $0.topCandidates(1).first?.string }
}
```

- `topCandidates(_:)` returns up to _n_ `RecognizedText` candidates sorted by descending `confidence` (0…1). Take `.first` for the best; keep several when you post-validate (e.g. checksum an account number).
- Each `RecognizedText` gives `.string`, `.confidence`, and `boundingBox(for: range)` to locate a substring — useful to highlight the detected IBAN on screen.
- **`.accurate` vs `.fast`:** `.accurate` for capture-and-confirm still images; `.fast` for live per-frame scanning where latency matters.
- Set `automaticallyDetectsLanguage = true` only when the language is unknown; otherwise pin `recognitionLanguages` — it is faster and less error-prone.
- Vision does **layout-blind** OCR: observations come in no guaranteed reading order. Sort by bounding-box position (top-to-bottom, then left-to-right) if you need lines/columns.
- Vision recognizes text; it does **not** understand it. Parse structured fields (amounts, dates, account numbers) with your own regex/validation, or hand the strings to `natural-language`. Never treat OCR output as trusted/validated financial data — always checksum and have the user confirm.

Legacy equivalent (iOS 13–17) in `references/legacy-vnrequest.md`.

<a id="barcodes"></a>
## Barcode / QR detection

```swift
import Vision

var request = DetectBarcodesRequest()
request.symbologies = [.qr, .ean13, .pdf417, .code128, .aztec]   // restrict → faster, fewer false hits
let barcodes = try await request.perform(on: image)              // [BarcodeObservation]

for code in barcodes {
    let payload = code.payloadString            // decoded text (nil for undecodable binary)
    let kind = code.symbology                   // BarcodeSymbology
    let box = code.boundingBox                  // NormalizedRect
}
```

- `payloadString` is `nil` for binary payloads — fall back to `payloadData`.
- `.pdf417` and `.aztec` are the symbologies on boarding passes, cheques, and many national IDs; `.qr` covers most payment/UPI codes.
- Always constrain `symbologies` to what you expect — the default scans all and is slower.
- For a **live** scanner UI, prefer VisionKit `DataScannerViewController` (below) over rolling your own capture loop.

<a id="faces"></a>
## Face rectangles

`DetectFaceRectanglesRequest` returns bounding boxes + pose only — enough for a "position your face in the oval" liveness/framing UX in KYC. It is **not** face recognition or identity matching.

```swift
let request = DetectFaceRectanglesRequest()
let faces = try await request.perform(on: pixelBuffer)   // [FaceObservation]
for face in faces {
    let box = face.boundingBox        // NormalizedRect
    let roll = face.roll, yaw = face.yaw, pitch = face.pitch   // each a non-optional Measurement<UnitAngle>; .converted(to: .radians).value for radians
}
```

- `face.landmarks` is **`nil`** here — populate it with `DetectFaceLandmarksRequest` (eyes/nose/mouth points) when you need feature geometry.
- Do not use this for authentication. Biometric identity on iOS is Face ID via `LocalAuthentication` — see `swift-security`.

<a id="document"></a>
## Document segmentation & foreground mask

- **`DetectDocumentSegmentationRequest`** → a `DetectedDocumentObservation` whose quadrilateral you use to crop/deskew a document (cheque, ID card) out of a cluttered background. For an end-user *capture* flow, `VNDocumentCameraViewController` (VisionKit) already does edge-detect + perspective-correct for you — reach for the request only when you process an image you already hold.
- **`GenerateForegroundInstanceMaskRequest`** → per-instance masks to lift the subject off its background.

```swift
let request = GenerateForegroundInstanceMaskRequest()
guard let observation = try await request.perform(on: image).first else { return nil }
let handler = ImageRequestHandler(image)
// Composite just the foreground instances onto a transparent background:
let masked = try observation.generateMaskedImage(
    for: observation.allInstances, imageFrom: handler, croppedToInstancesExtent: false)
```

<a id="tracking"></a>
## Object tracking (stateful)

`TrackObjectRequest` is **stateful** — reuse the *same* instance across consecutive frames; do not create a new one per frame.

```swift
// Seed from a prior detection's observation (anything BoundingBoxProviding & VisionObservation).
let request = TrackObjectRequest(detectedObject: seedObservation)
for await frame in cameraFrames {                       // CVPixelBuffer / CMSampleBuffer per frame
    let tracked = try await request.perform(on: frame)  // updated observation(s)
    update(overlay: tracked.first?.boundingBox)
}
```

- Legacy tracking uses `VNTrackObjectRequest` performed through a **`VNSequenceRequestHandler`** (not `VNImageRequestHandler`) — see `references/legacy-vnrequest.md`.

<a id="coreml"></a>
## Custom Core ML models

Run your own Create ML / converted model (transaction-category classifier, custom document detector) through Vision so it handles resizing, color, and orientation to the model's input spec.

```swift
import Vision
import CoreML

let container = try CoreMLModelContainer(model: try MyClassifier(configuration: .init()).model)
var request = CoreMLRequest(model: container)
let results = try await request.perform(on: image)   // [ClassificationObservation] / [CoreMLFeatureValueObservation] / …
```

- Result type depends on the model: image classifiers → `ClassificationObservation` (`.identifier`, `.confidence`); object detectors emitting boxes → `RecognizedObjectObservation`; everything else → `CoreMLFeatureValueObservation` / `PixelBufferObservation`.
- Legacy path: `VNCoreMLModel(for:)` + `VNCoreMLRequest`, with `imageCropAndScaleOption` (`.centerCrop` / `.scaleFit` / `.scaleFill`) to match training preprocessing.
- **Loading, compiling, compute-unit selection, and raw prediction** of the model itself belong to the `coreml` skill — this skill only covers running it *via Vision*. Use plain Core ML (no Vision) when your input isn't an image.

<a id="visionkit"></a>
## VisionKit — live capture UI

VisionKit ships ready-made UIKit controllers. Wrap them for SwiftUI with `UIViewControllerRepresentable` (see `swiftui-uikit-interop`). **All live-camera capture requires `NSCameraUsageDescription` in Info.plist** or the app crashes on launch of the scanner.

### DataScannerViewController — live text + codes (iOS 16+)

```swift
import VisionKit

guard DataScannerViewController.isSupported,
      DataScannerViewController.isAvailable else { /* no camera / not permitted / unsupported HW */ return }

let scanner = DataScannerViewController(
    recognizedDataTypes: [.text(), .barcode(symbologies: [.qr, .pdf417])],
    qualityLevel: .balanced,
    recognizesMultipleItems: false,
    isHighFrameRateTrackingEnabled: true,
    isPinchToZoomEnabled: true,
    isGuidanceEnabled: true,
    isHighlightingEnabled: true)
scanner.delegate = self
try scanner.startScanning()
```

```swift
extension MyCoordinator: DataScannerViewControllerDelegate {
    func dataScanner(_ s: DataScannerViewController, didTapOn item: RecognizedItem) {
        switch item {
        case .text(let text):       handle(text.transcript)
        case .barcode(let code):    handle(code.payloadStringValue)
        @unknown default:           break
        }
    }
    // Also: didAdd:, didUpdate:, didRemove: for continuous streaming as items enter/leave frame.
}
```

- `isSupported` = device HW (needs A12+ Neural Engine); `isAvailable` = camera present **and** authorized. Gate on **both**.
- `RecognizedItem` is an enum: `.text(RecognizedItem.Text)` (`.transcript`) or `.barcode(RecognizedItem.Barcode)` (`.payloadStringValue`).

### VNDocumentCameraViewController — guided KYC scan (iOS 13+)

Full Apple scanner UI: edge detection, auto-shutter, perspective correction, multi-page.

```swift
func documentCameraViewController(_ c: VNDocumentCameraViewController,
                                  didFinishWith scan: VNDocumentCameraScan) {
    let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }   // [UIImage], deskewed
    // Run OCR on each page with RecognizeTextRequest, then dismiss.
}
```

### ImageAnalyzer + ImageAnalysisInteraction — Live Text (iOS 16+)

Selectable text / tappable data detectors over a *static* image (e.g. let the user copy an account number off a screenshot).

```swift
let analyzer = ImageAnalyzer()
let config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
let analysis = try await analyzer.analyze(uiImage, configuration: config)

let interaction = ImageAnalysisInteraction()
interaction.preferredInteractionTypes = .automatic
interaction.analysis = analysis
imageView.addInteraction(interaction)          // imageView is a UIImageView
```

Deeper SwiftUI wrappers and streaming-delegate patterns: `references/visionkit.md`.

<a id="coordinates"></a>
## Coordinates & orientation

- Vision bounding boxes are **normalized** (`0…1`) in a **bottom-left origin** coordinate space — the opposite of UIKit's top-left. Convert with `VNImageRectForNormalizedRect(_:_:_:)` / `VNNormalizedRectForImageRect(...)`, or flip Y yourself: `y_uikit = 1 - y_vision - height`.
- Always pass the correct `CGImagePropertyOrientation`. A `UIImage` from the camera usually carries orientation metadata; a raw `CVPixelBuffer` does **not** — derive orientation from the capture connection / device orientation or OCR silently fails on rotated frames.
- `NormalizedRect` (modern) exposes helpers to convert to an image-pixel `CGRect`; `QuadrilateralProviding` gives four corner points for tight, rotation-aware overlays (better than an axis-aligned box for skewed cards).
- Full conversion helpers and a SwiftUI overlay example: `references/coordinates-performance.md`.

<a id="kmp"></a>
## KMP boundary

Vision/VisionKit are iOS-only UIKit/AVFoundation APIs — they live entirely in `iosMain` / the Swift app layer, never in `commonMain`.

- Define a `commonMain` `interface DocumentScanner { suspend fun scan(): ScanResult }` (or a `ScanResult` domain model) and bind an `actual`/Swift implementation that drives VisionKit; see `expect-actual` and `kmp-ios-integration`.
- Cross the boundary with **plain data** (recognized strings, decoded payloads, normalized rects as primitives) — never pass `UIImage`, `CGImage`, or `VNObservation` into shared code.
- Do the OCR/scan on the Swift side, validate/parse in shared code. Keep raw document images on-device; if you must persist them, encrypt at rest (`swift-security`).

<a id="performance"></a>
## Performance & privacy

- **Never block the main thread.** Requests are `async` — `await` off the main actor; hop back to `@MainActor` only to update UI.
- Reuse **one `ImageRequestHandler`** per frame across multiple requests; construct requests cheaply.
- For live/streaming, use `.fast` OCR and restrict `symbologies`/`recognitionLanguages`; drop frames rather than queueing — process the latest `CMSampleBuffer`, discard backlog.
- Downscale huge photo-library images before OCR; beyond a point extra pixels cost time without accuracy.
- **Privacy:** all analysis is on-device — no network, so no server ever sees a customer's ID or cheque. Still treat captured images as PII: don't log them, minimize retention, and clear buffers after use. Live camera needs `NSCameraUsageDescription`; the photo picker path is covered by `photokit`.

<a id="checklist"></a>
## Correctness checklist

- [ ] API tier matches deployment target — modern `RecognizeTextRequest`/`.perform(on:)` needs iOS 18; use legacy `VNImageRequestHandler` + `VNRecognizeTextRequest` for iOS 17 and earlier.
- [ ] Not confused with visionOS — this is image-analysis `Vision`.
- [ ] Requests run `async` off the main thread; UI updates hop back to `@MainActor`.
- [ ] One `ImageRequestHandler` reused when running multiple requests on the same image.
- [ ] Correct `CGImagePropertyOrientation` passed (especially for raw `CVPixelBuffer` with no metadata).
- [ ] Bounding boxes converted from Vision's normalized bottom-left space before drawing in UIKit/SwiftUI.
- [ ] OCR: `recognitionLanguages` pinned, `recognitionLevel` chosen (`.accurate` still / `.fast` live), `topCandidates(1).first` taken; results validated/checksummed, never trusted raw.
- [ ] Barcodes: `symbologies` constrained; `payloadString` nil-checked with `payloadData` fallback.
- [ ] `TrackObjectRequest` instance reused across frames (stateful); legacy tracking uses `VNSequenceRequestHandler`.
- [ ] VisionKit gated on both `isSupported` and `isAvailable`; `NSCameraUsageDescription` present for any live capture.
- [ ] Face detection used only for framing/liveness, not identity — Face ID auth lives in `swift-security`.
- [ ] Vision/VisionKit calls kept in `iosMain`/Swift; only plain data crosses into `commonMain`.
- [ ] Captured ID/cheque images treated as PII — not logged, minimized, encrypted if persisted.
