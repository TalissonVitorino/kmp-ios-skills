# Legacy Vision API (VNRequest) — iOS 13–17

The pre-iOS-18 surface. Use this whenever your deployment target is below iOS 18.
Same ML models as the modern API; different types and a completion-handler style.

## Core shape

`VN…Request` (with a completion handler or read `.results` after) performed by a
handler: **`VNImageRequestHandler`** for a single still image, **`VNSequenceRequestHandler`**
for a stream of frames (tracking).

```swift
import Vision

let handler = VNImageRequestHandler(cgImage: cgImage,
                                    orientation: .up,      // CGImagePropertyOrientation
                                    options: [:])
let request = VNRecognizeTextRequest()
try handler.perform([request])                              // synchronous; run off the main thread
let observations = request.results ?? []                    // [VNRecognizedTextObservation]
```

- `perform(_:)` is **synchronous and blocking** — dispatch it to a background queue yourself (`Task.detached` or a utility `DispatchQueue`).
- You may pass several requests in one `perform([...])` call — the handler decodes the image once.
- Handler initializers: `init(cgImage:)`, `init(ciImage:)`, `init(cvPixelBuffer:)`, `init(data:)`, `init(url:)`, each with optional `orientation:` and `options:`.

## OCR

```swift
let request = VNRecognizeTextRequest { request, error in
    guard let obs = request.results as? [VNRecognizedTextObservation] else { return }
    let lines = obs.compactMap { $0.topCandidates(1).first?.string }
    // ...deliver lines (hop to main for UI)
}
request.recognitionLevel = .accurate            // VNRequestTextRecognitionLevel: .fast / .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = ["en-US"]        // plain [String] (not Locale.Language)
request.customWords = ["IBAN", "SWIFT"]
request.minimumTextHeight = 0.02
request.automaticallyDetectsLanguage = false

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])
```

- `VNRecognizedTextObservation.topCandidates(_:)` → `[VNRecognizedText]`, each with `.string`, `.confidence`, and `boundingBox(for: Range<String.Index>)` returning a `VNRectangleObservation?`.
- `VNRecognizeTextRequest.supportedRecognitionLanguages()` lists available languages for the current revision (the `for:revision:` overload is deprecated).
- `observation.boundingBox` is a normalized `CGRect` (bottom-left origin), plus `topLeft/topRight/bottomLeft/bottomRight` corner points on `VNRectangleObservation`.

## Barcodes

```swift
let request = VNDetectBarcodesRequest { req, _ in
    let codes = req.results as? [VNBarcodeObservation] ?? []
    for c in codes { _ = (c.payloadStringValue, c.symbology, c.boundingBox) }
}
request.symbologies = [.qr, .pdf417, .ean13, .code128, .aztec]   // [VNBarcodeSymbology]
try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
```

- Legacy payload accessor is `payloadStringValue` (VisionKit's `RecognizedItem.Barcode` also uses `payloadStringValue`); the *modern* `BarcodeObservation` uses `payloadString`.

## Faces

```swift
let request = VNDetectFaceRectanglesRequest { req, _ in
    let faces = req.results as? [VNFaceObservation] ?? []
    for f in faces { _ = (f.boundingBox, f.roll, f.yaw, f.pitch) }   // roll/yaw/pitch are NSNumber?
}
try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:]).perform([request])
```

- Landmarks: `VNDetectFaceLandmarksRequest` → `VNFaceObservation.landmarks` (`VNFaceLandmarks2D`).

## Object tracking — VNSequenceRequestHandler

Tracking is stateful across frames. Seed from a detected-object observation and
reuse **one** `VNSequenceRequestHandler` and **one** `VNTrackObjectRequest`.

```swift
let sequenceHandler = VNSequenceRequestHandler()
var lastObservation = VNDetectedObjectObservation(boundingBox: initialNormalizedRect)

func track(_ pixelBuffer: CVPixelBuffer) throws -> CGRect? {
    let request = VNTrackObjectRequest(detectedObjectObservation: lastObservation)
    request.trackingLevel = .accurate
    try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
    guard let updated = request.results?.first as? VNDetectedObjectObservation else { return nil }
    lastObservation = updated              // feed forward into the next frame
    return updated.boundingBox
}
```

## Custom Core ML (VNCoreMLRequest)

```swift
let mlModel = try MyClassifier(configuration: MLModelConfiguration()).model
let vnModel = try VNCoreMLModel(for: mlModel)
let request = VNCoreMLRequest(model: vnModel) { req, _ in
    let top = req.results as? [VNClassificationObservation]
    _ = top?.first.map { ($0.identifier, $0.confidence) }
}
request.imageCropAndScaleOption = .centerCrop      // match training preprocessing: .scaleFit / .scaleFill
try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
```

- Result observation types: `VNClassificationObservation` (label + confidence), `VNRecognizedObjectObservation` (detector with `.boundingBox` + `.labels`), `VNCoreMLFeatureValueObservation`, `VNPixelBufferObservation` (image-to-image).

## Migration notes (legacy → modern, iOS 18+)

| Legacy | Modern |
|---|---|
| `VNImageRequestHandler(...).perform([req])` (sync) | `handler.perform(req)` / `req.perform(on:)` (`async`) |
| `req.results as? [VNRecognizedTextObservation]` | typed `[RecognizedTextObservation]` return value |
| `recognitionLanguages: [String]` | `recognitionLanguages: [Locale.Language]` |
| `payloadStringValue` | `payloadString` |
| `VNSequenceRequestHandler` + `VNTrackObjectRequest` | reuse one `TrackObjectRequest` (`.perform(on:)` per frame) |
| completion-handler / KVO `.results` | structured `async` results |
