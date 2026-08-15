# Wrapping system UIKit controllers in SwiftUI

Full `UIViewControllerRepresentable` / `UIViewRepresentable` bodies for the common
system controllers. All use the Coordinator-as-delegate + dismiss-on-callback pattern.

## Mail compose (MFMailComposeViewController)

```swift
import SwiftUI
import MessageUI

struct MailComposer: UIViewControllerRepresentable {
    let subject: String
    let recipients: [String]
    let body: String
    var onFinish: (MFMailComposeResult) -> Void = { _ in }

    // Call this before presenting; fall back to a mailto: link when false.
    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setSubject(subject)
        vc.setToRecipients(recipients)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: MailComposer
        init(_ parent: MailComposer) { self.parent = parent }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            parent.onFinish(result)
            controller.dismiss(animated: true)
        }
    }
}
```

Usage (gate first):

```swift
if MailComposer.canSend {
    showMail = true             // drive a .sheet { MailComposer(...) }
} else if let url = URL(string: "mailto:support@example.com") {
    openURL(url)                // @Environment(\.openURL)
}
```

- `canSendMail()` is `false` when no Mail account is configured, and always `false` on Simulator and Mac. Presenting anyway fails.
- Third-party mail apps (Gmail/Outlook) are not reported by `canSendMail()` — use the `mailto:` fallback to reach them.

## Share sheet (UIActivityViewController)

```swift
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var activities: [UIActivity]? = nil
    var onComplete: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items,
                                          applicationActivities: activities)
        vc.completionWithItemsHandler = { _, completed, _, _ in
            onComplete(completed)
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
```

- iPad / regular width presents in a **popover** — set the anchor or it crashes:
  `vc.popoverPresentationController?.sourceView = someView` (and `sourceRect`), or
  `.sourceItem = barButtonItem`.
- For a plain `Transferable` payload, SwiftUI's native `ShareLink` is simpler and adopts the system look — wrap `UIActivityViewController` only for custom `UIActivity` or non-`Transferable` items.

## Photo picker (PHPickerViewController)

```swift
import SwiftUI
import PhotosUI

struct PhotoPicker: UIViewControllerRepresentable {
    @Binding var images: [UIImage]
    var selectionLimit: Int = 1

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images                 // .videos, .livePhotos, .any(of:[...])
        config.selectionLimit = selectionLimit  // 0 = unlimited
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController,
                    didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            for result in results {
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    guard let image = object as? UIImage else { return }
                    Task { @MainActor in          // load callback is off the main actor
                        self.parent.images.append(image)
                    }
                }
            }
        }
    }
}
```

- The picker runs out-of-process; it needs **no** `NSPhotoLibraryUsageDescription` and shows no permission prompt for selection.
- Passing `photoLibrary: .shared()` makes `PHPickerResult.assetIdentifier` non-nil so you can later fetch the `PHAsset` (that fetch *does* need authorization).
- `loadObject` completion runs on a background queue — hop to `@MainActor` before mutating SwiftUI state. See **swift-concurrency**.
- Rich asset handling, live photos, ordering, and `PHPhotoLibrary` authorization live in **photokit**.

## PDF viewer (PDFView, PDFKit)

`PDFView` is a `UIView`, so use `UIViewRepresentable`:

```swift
import SwiftUI
import PDFKit

struct PDFViewer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)   // reload only when the URL changes
        }
    }
}
```

- Guard the reload so `updateUIView` doesn't rebuild the document on every SwiftUI pass (resets scroll position).
- Annotation, text selection, thumbnails, and page navigation → **pdfkit**.

## Contact picker (CNContactPickerViewController)

Same shape: wrap the controller, set `.delegate = context.coordinator`, conform the
Coordinator to `CNContactPickerDelegate`, dismiss in the selection callback. Field
selection, `CNContact` mapping, and permissions → **contacts-framework**.
