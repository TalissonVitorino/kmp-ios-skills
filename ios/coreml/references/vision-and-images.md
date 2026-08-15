# Vision integration & image inputs

Deep reference for `coreml`. For non-Core-ML Vision requests (text/OCR, barcodes, faces, saliency, hand pose) use the `vision-framework` skill — this file only covers running a **custom Core ML model** through Vision, plus direct image feature values.

## Classic API — VNCoreMLRequest (iOS 11+)

```swift
import Vision

final class ImageClassifier {
    private let request: VNCoreMLRequest

    init(model: MLModel) throws {
        let vnModel = try VNCoreMLModel(for: model)
        request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .centerCrop      // match training preprocessing
    }

    func classify(_ cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [VNClassificationObservation] {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        try handler.perform([request])
        return request.results as? [VNClassificationObservation] ?? []
    }
}
```

- Wrap the underlying `MLModel` (e.g. `generatedModel.model`) in `VNCoreMLModel`.
- Vision auto-resizes and color-matches the input to the model's `imageConstraint`, so you skip manual `CVPixelBuffer` prep.
- `VNImageRequestHandler` variants: `init(cgImage:)`, `init(ciImage:)`, `init(cvPixelBuffer:)`, `init(url:)`, each with an `orientation:` overload. For camera frames feed the `CVPixelBuffer` from the sample buffer.
- Reuse the `VNCoreMLRequest`; create a fresh `VNImageRequestHandler` per image.

### imageCropAndScaleOption

| Option | Behavior |
|---|---|
| `.centerCrop` | Scale to fill, crop to center (keeps aspect, loses edges) |
| `.scaleFit` | Scale to fit, letterbox (keeps whole image, adds padding) |
| `.scaleFill` | Stretch to fill (distorts aspect) |

Must match how the model was trained, or accuracy silently degrades.

### Result observation types

- `VNClassificationObservation` — `identifier`, `confidence` (classifiers).
- `VNRecognizedObjectObservation` — `boundingBox` (normalized, origin bottom-left) + `labels` (detectors, e.g. YOLO-style).
- `VNPixelBufferObservation` — image-to-image models (style transfer, segmentation, super-res).
- `VNCoreMLFeatureValueObservation` — raw `MLFeatureValue` when the output isn't a standard image/classification.

Normalized bounding boxes → view coords: `VNImageRectForNormalizedRect(box, width, height)` (flip Y for UIKit).

## Modern Swift Vision API (iOS 18+)

iOS 18 introduced a Swift-native, async/await Vision API. For Core ML models the pieces are `CoreMLModelContainer` (wraps the model) and `CoreMLRequest`:

```swift
import Vision

let container = try CoreMLModelContainer(model: mlModel)   // wraps an MLModel
var request = CoreMLRequest(model: container)
request.cropAndScaleAction = .centerCrop                   // Swift-enum equivalent of the classic option

let observations = try await request.perform(on: cgImage)  // typed results, async — no completion handler
```

- Requests are value types you configure and `perform(on:)` against an image source (`CGImage`, `CVPixelBuffer`, `CIImage`, `URL`, `Data`).
- `perform` is `async throws` and returns strongly-typed observations — no `req.results as?` casting.
- Prefer this on new iOS-18+ code; keep `VNCoreMLRequest` for back-deployment. Confirm exact property/enum names against the current Vision docs for your SDK, as this API is still evolving.

## Direct image feature values (no Vision)

When you feed Core ML directly (e.g. you already have a correctly-sized buffer), build the feature value from the model's constraint:

```swift
let desc = model.modelDescription.inputDescriptionsByName["image"]!
let constraint = desc.imageConstraint!                     // required WxH + pixelFormatType
let fv = try MLFeatureValue(cgImage: cgImage, orientation: .up, constraint: constraint, options: nil)
let input = try MLDictionaryFeatureProvider(dictionary: ["image": fv])
```

- `imageConstraint` exposes `pixelsWide`, `pixelsHigh`, `pixelFormatType`, `sizeConstraint` (some models accept flexible/enumerated sizes).
- For raw `CVPixelBuffer` inputs, the buffer's format must match `pixelFormatType` (commonly `kCVPixelFormatType_32BGRA` or `..._OneComponent8`). Vision does this conversion for you — hand-prep only when you must.
- `MLFeatureValue(pixelBuffer:)` skips resizing entirely — the buffer must already be the exact required size.

## Camera frames (AVFoundation)

- Get `CVPixelBuffer` from `CMSampleBufferGetImageBuffer(sampleBuffer)` in your capture delegate.
- Pass it to `VNImageRequestHandler(cvPixelBuffer:orientation:)` — Vision handles scaling to the model.
- Throttle: run at most one in-flight request; drop frames while busy (a `flag`/actor) to avoid backing up the ANE. For the capture pipeline itself see `photokit` (iOS) / `camerax` (Android/KMP).
