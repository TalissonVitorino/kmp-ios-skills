# VisionKit — SwiftUI wrappers & streaming patterns

VisionKit's controllers are UIKit. Bridge them into SwiftUI with
`UIViewControllerRepresentable` / `UIViewRepresentable` (see the
`swiftui-uikit-interop` skill). **Every live-camera path needs
`NSCameraUsageDescription` in Info.plist.**

## DataScannerViewController in SwiftUI

```swift
import SwiftUI
import VisionKit

struct LiveScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr, .pdf417]), .text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        try? vc.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        // Continuous streaming as items enter the frame:
        func dataScanner(_ s: DataScannerViewController, didAdd added: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in added {
                switch item {
                case .barcode(let b): b.payloadStringValue.map(onScan)
                case .text(let t):    onScan(t.transcript)
                @unknown default:     break
                }
            }
        }
        func dataScanner(_ s: DataScannerViewController, didTapOn item: RecognizedItem) { /* … */ }
        func dataScanner(_ s: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { /* … */ }
    }
}
```

- **Gate before presenting:** `DataScannerViewController.isSupported` (A12+ Neural Engine) **and** `.isAvailable` (camera present and authorized). If either is false, fall back to the photo picker (`photokit`) + still-image `RecognizeTextRequest`/`VNRecognizeTextRequest`.
- Delegate callbacks: `didAdd:allItems:`, `didUpdate:allItems:`, `didRemove:allItems:` for streaming; `didTapOn:` for selection; `becameUnavailableWithError:` for runtime loss (e.g. permission revoked).
- `RecognizedItem` cases: `.text(RecognizedItem.Text)` → `.transcript`; `.barcode(RecognizedItem.Barcode)` → `.payloadStringValue` (and `.observation` for the underlying Vision observation).
- Draw custom highlights via `vc.overlayContainerView`; `recognizesMultipleItems: true` to track several codes at once.

## VNDocumentCameraViewController in SwiftUI

```swift
struct DocumentScanner: UIViewControllerRepresentable {
    let onPages: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPages: onPages) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onPages: ([UIImage]) -> Void
        init(onPages: @escaping ([UIImage]) -> Void) { self.onPages = onPages }

        func documentCameraViewController(_ c: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }   // deskewed UIImages
            c.dismiss(animated: true) { self.onPages(pages) }
        }
        func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) {
            c.dismiss(animated: true)
        }
        func documentCameraViewController(_ c: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            c.dismiss(animated: true)
        }
    }
}
```

- `VNDocumentCameraScan`: `pageCount`, `imageOfPage(at:)`, `title`. Each returned page is already edge-detected and perspective-corrected — ideal input for OCR.
- Then OCR each page with `RecognizeTextRequest` (iOS 18+) or `VNRecognizeTextRequest` (earlier).

## ImageAnalyzer / ImageAnalysisInteraction — Live Text over a static image

Lets users select recognized text and tap data detectors (phone/URL/address) on an
image you display — e.g. copy an account number off a shared screenshot.

```swift
let analyzer = ImageAnalyzer()
let config = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
let analysis = try await analyzer.analyze(uiImage, configuration: config)

// UIKit host (UIImageView):
let interaction = ImageAnalysisInteraction()
interaction.preferredInteractionTypes = .automatic      // .textSelection / .dataDetectors / .imageSubject
interaction.analysis = analysis
imageView.addInteraction(interaction)
```

- `ImageAnalyzer.isSupported` gates availability. Reuse **one** `ImageAnalyzer` instance (it is expensive to create); it serializes concurrent `analyze` calls.
- `preferredInteractionTypes`: `.automatic`, `.textSelection`, `.dataDetectors`, `.imageSubject` (lift subject, iOS 17+), or `[]` to disable.
- Query results: `interaction.hasActiveTextSelection`, `interaction.selectedText`, `interaction.subject(at:)` / `interaction.subjects` (async, iOS 17+).
- SwiftUI: host the `UIImageView` + interaction in a `UIViewRepresentable`; there is no first-party pure-SwiftUI view for `ImageAnalysisInteraction`.
