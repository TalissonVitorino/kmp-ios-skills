# AVFoundation capture — depth

Full custom-camera pipeline for guided capture (KYC selfie, ID/cheque scan). Read alongside
the `photokit` SKILL. Requires `NSCameraUsageDescription`, plus `NSMicrophoneUsageDescription`
when recording audio. For OCR / document-rectangle / barcode on the captured frame, hand the
result to `vision-framework`.

## Authorization

```swift
switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized: break
case .notDetermined:
    let granted = await AVCaptureDevice.requestAccess(for: .video)   // async Bool
    guard granted else { /* route to Settings */ return }
case .denied, .restricted: /* route to Settings; do not re-prompt */ return
@unknown default: return
}
```

## Session assembly

```swift
import AVFoundation

let session = AVCaptureSession()
let sessionQueue = DispatchQueue(label: "camera.session")   // serialize all session mutations

sessionQueue.async {
    session.beginConfiguration()
    session.sessionPreset = .photo                          // .photo | .high | .hd1920x1080 | .inputPriority ...

    // Input
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input) else { session.commitConfiguration(); return }
    session.addInput(input)

    // Photo output
    let photoOutput = AVCapturePhotoOutput()
    guard session.canAddOutput(photoOutput) else { session.commitConfiguration(); return }
    session.addOutput(photoOutput)
    photoOutput.maxPhotoQualityPrioritization = .quality

    session.commitConfiguration()
    session.startRunning()                                  // blocks — never on the main thread
}
```

- Wrap **all** input/output changes in `beginConfiguration()` / `commitConfiguration()` so they apply atomically.
- Query `canAddInput`/`canAddOutput` before adding; adding an incompatible I/O throws or is silently dropped.
- `startRunning()`/`stopRunning()` are blocking — always on your `sessionQueue`, never the main actor.
- Choose the device deliberately: `.builtInWideAngleCamera` (default), `.builtInUltraWideCamera`, `.builtInTrueDepthCamera` (front, for depth). Use `AVCaptureDevice.DiscoverySession` to enumerate.

## SwiftUI preview layer

```swift
import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
```

## Still capture

```swift
final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    let output: AVCapturePhotoOutput
    var onImage: ((Data) -> Void)?

    func capture() {
        // Fresh settings each shot; reusing one crashes.
        let settings: AVCapturePhotoSettings
        if output.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()   // JPEG fallback
        }
        settings.flashMode = .auto
        settings.photoQualityPrioritization = .quality
        output.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        onImage?(data)     // self-contained HEIC/JPEG with metadata embedded
    }
}
```

- `fileDataRepresentation()` yields a ready-to-write/upload container (metadata embedded). For raw pixels use `photo.pixelBuffer` / `photo.cgImageRepresentation()`.
- Keep the delegate alive until the callback fires (retain the `PhotoCapture` instance).

## Orientation (iOS 17+) — RotationCoordinator

`AVCaptureConnection.videoOrientation` is deprecated. Use `AVCaptureDevice.RotationCoordinator`:

```swift
// Retain the coordinator; it KVO-updates its angle properties as the device rotates.
let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)

// Preview:
if let c = previewLayer.connection {
    c.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
}
// Photo output at capture time:
if let c = photoOutput.connection(with: .video) {
    c.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
}
```

- Angle values differ by device generation and camera position — **read them from the coordinator**, never hardcode 90/180/270.
- Observe the coordinator's `videoRotationAngleForHorizonLevel...` properties (KVO) to update the connection as the device turns.

## Video recording

```swift
// During configuration, add audio input + a movie output:
if let mic = AVCaptureDevice.default(for: .audio),
   let audioInput = try? AVCaptureDeviceInput(device: mic),
   session.canAddInput(audioInput) { session.addInput(audioInput) }

let movieOutput = AVCaptureMovieFileOutput()
if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

// Start/stop:
let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip.mov")
movieOutput.startRecording(to: url, recordingDelegate: self)   // self: AVCaptureFileOutputRecordingDelegate
// ...later...
movieOutput.stopRecording()

func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                from connections: [AVCaptureConnection], error: Error?) {
    // error may be non-nil yet the file still usable — check AVErrorRecordingSuccessfullyFinishedKey in error.userInfo.
}
```

## Interruptions & lifecycle

- Observe `AVCaptureSession.wasInterruptedNotification` / `interruptionEndedNotification` (phone call, control-center camera, being backgrounded) and `runtimeErrorNotification`; the `reason` distinguishes audio-in-use, video-not-available-in-background, multiple-foreground-apps.
- Stop the session (`stopRunning`) when the capture UI disappears; restart on reappear. Configure/tear down on the `sessionQueue`.
- Torch/zoom/focus: `lockForConfiguration()` on the `AVCaptureDevice`, set `torchMode`/`videoZoomFactor`/`focusPointOfInterest`, then `unlockForConfiguration()`.

## Fintech notes

- For ID/cheque capture, overlay a guide rectangle and use `vision-framework` (`VNDetectDocumentSegmentationRequest` / rectangle + `VNRecognizeTextRequest`) on the captured `Data`/`CGImage`; don't ship the raw camera roll into your KYC flow.
- Do **not** auto-save KYC/document captures to the photo library. Keep bytes in memory or an encrypted store (`swift-security`); never log image data.
