# Coordinates, orientation & performance

## Vision's coordinate space

- All bounding boxes are **normalized** to `0…1` of the image, with the **origin at
  the bottom-left** and +Y pointing **up**. UIKit/SwiftUI use a **top-left** origin
  with +Y pointing **down** — you must flip Y before drawing.
- Convert normalized → image pixels with the free functions:

```swift
import Vision

// normalized rect → pixel CGRect in an image of the given size
let pixelRect = VNImageRectForNormalizedRect(obs.boundingBox, imageWidth, imageHeight)
// and back:
let normRect = VNNormalizedRectForImageRect(pixelRect, imageWidth, imageHeight)
// single points:
let pt = VNImagePointForNormalizedPoint(normalizedPoint, imageWidth, imageHeight)
```

- Manual flip when mapping a Vision normalized rect into a **top-left** view space:

```swift
func viewRect(from vision: CGRect, in size: CGSize) -> CGRect {
    CGRect(x: vision.minX * size.width,
           y: (1 - vision.minY - vision.height) * size.height,   // flip Y
           width: vision.width * size.width,
           height: vision.height * size.height)
}
```

- **Modern API:** observations expose `boundingBox: NormalizedRect`; use its conversion helpers to produce an image-space `CGRect`. Spatial observations that conform to `QuadrilateralProviding` give `topLeft/topRight/bottomLeft/bottomRight` corner points — use these (not the axis-aligned box) to draw a tight overlay on a **skewed** card or document.

## Orientation

- Pass a `CGImagePropertyOrientation` that matches how the pixels are laid out, or
  detection silently degrades (rotated/mirrored input → missed text/faces).
- `UIImage` carries an `imageOrientation`; map it to `CGImagePropertyOrientation` when handing the underlying `CGImage` to Vision. Passing the `UIImage`'s `cgImage` with `.up` while the photo is actually rotated is the classic "OCR finds nothing" bug.
- A raw `CVPixelBuffer` from `AVCaptureVideoDataOutput` has **no** orientation metadata. Derive it from the capture connection's `videoRotationAngle` (or device orientation) and the camera position (front camera is mirrored), then pass it explicitly.

```swift
extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up: self = .up;            case .upMirrored: self = .upMirrored
        case .down: self = .down;        case .downMirrored: self = .downMirrored
        case .left: self = .left;        case .leftMirrored: self = .leftMirrored
        case .right: self = .right;      case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
```

## Performance

- **Off the main thread.** Modern requests are `async` — `await` them off `@MainActor`. Legacy `handler.perform(_:)` is synchronous and *blocking* — dispatch it to a background queue.
- **One handler per frame.** Build a single `ImageRequestHandler` (modern) / `VNImageRequestHandler` (legacy) and pass multiple requests to it so the image is decoded once.
- **Live video:** process only the latest `CMSampleBuffer` and drop the backlog — never queue frames faster than you analyze them, or latency compounds. Use `.fast` OCR, restrict `symbologies` and `recognitionLanguages`, and consider a lower `qualityLevel` on `DataScannerViewController`.
- **Downscale** large photo-library images before analysis; past a resolution ceiling extra pixels add time without accuracy. `RecognizeTextRequest.minimumTextHeight` also lets Vision skip tiny regions.
- **Reuse expensive objects:** a single `ImageAnalyzer` (VisionKit) and a compiled `VNCoreMLModel` / `CoreMLModelContainer` should be created once and kept, not rebuilt per call.
- **Memory:** release `CVPixelBuffer`/`CGImage` references promptly; captured KYC frames are large and are PII — don't retain or log them.
