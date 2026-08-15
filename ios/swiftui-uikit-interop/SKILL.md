---
name: swiftui-uikit-interop
description: "Bridge UIKit and SwiftUI in both directions on iOS 26. Covers UIViewRepresentable / UIViewControllerRepresentable (makeUIView/updateUIView, makeUIViewController/updateUIViewController, Coordinator + makeCoordinator for delegate/target-action, sizeThatFits(_:uiView:context:) with ProposedViewSize, dismantleUIView), UIHostingController (sizingOptions, addChild embedding) and UIHostingConfiguration cells (iOS 16+), automatic @Observable observation tracking in UIKit views/controllers (iOS 18 opt-in via UIObservationTrackingEnabled, default iOS 26), and wrapping MFMailComposeViewController / UIActivityViewController / PHPickerViewController / PDFView. Use when embedding a UIKit view or controller inside SwiftUI, hosting SwiftUI inside a UIKit app, or incrementally migrating UIKit → SwiftUI. For @Observable models see swiftui-observation; for quick SwiftUI layout/nav see swiftui-patterns and swiftui-expert-skill; photo picking depth in photokit, PDF rendering in pdfkit, contact picker in contacts-framework, web content in swiftui-webkit; @MainActor/async delegate bridging in swift-concurrency; shipping the shared KMP module to a hosting UIViewController in kmp-ios-integration."
---

# SwiftUI ↔ UIKit interop (iOS 26)

Bridge the two UI frameworks in both directions. Grounded in Apple's SwiftUI and
UIKit documentation.

- **SwiftUI wraps UIKit:** `UIViewRepresentable`, `UIViewControllerRepresentable`.
- **UIKit hosts SwiftUI:** `UIHostingController`, `UIHostingConfiguration` (cells).
- **Migration bridge:** run both in one app; move screen-by-screen.

## Contents

- [Which tool](#which-tool)
- [UIViewRepresentable](#uiviewrepresentable)
- [Coordinator (delegates / target-action)](#coordinator)
- [sizeThatFits — sizing into the SwiftUI layout system](#sizethatfits)
- [UIViewControllerRepresentable](#uiviewcontrollerrepresentable)
- [Wrapping system controllers (mail / share / photos / PDF)](#wrapping)
- [UIHostingController — SwiftUI inside UIKit](#uihostingcontroller)
- [UIHostingConfiguration — SwiftUI in cells (iOS 16+)](#uihostingconfiguration)
- [@Observable observation tracking in UIKit (iOS 17/18/26)](#observation)
- [Incremental migration](#migration)
- [Correctness checklist](#checklist)
- References: `references/wrapping-system-controllers.md`, `references/observation-and-migration.md`

<a id="which-tool"></a>
## Which tool

| Direction | You have | Use |
|---|---|---|
| UIKit → SwiftUI | a `UIView` | `UIViewRepresentable` |
| UIKit → SwiftUI | a `UIViewController` (modal pickers, page VC) | `UIViewControllerRepresentable` |
| SwiftUI → UIKit | a `View` to drop in a UIKit hierarchy | `UIHostingController` |
| SwiftUI → UIKit | a `View` inside a `UICollectionView`/`UITableView` cell | `UIHostingConfiguration` (iOS 16+) |

- Prefer the **controller** variant when the UIKit type is a `UIViewController` (e.g. `PHPickerViewController`, `MFMailComposeViewController`) — don't reach into `.view`.
- All representable methods are `@MainActor @preconcurrency`. Treat the struct as a lightweight, recreated-often config value; keep mutable/reference state in the `Coordinator`.

<a id="uiviewrepresentable"></a>
## UIViewRepresentable

Required: `makeUIView(context:)` (once) and `updateUIView(_:context:)` (on every relevant state change). `UIViewType` is inferred from `makeUIView`'s return.

```swift
import SwiftUI
import UIKit

struct ProgressRing: UIViewRepresentable {
    var progress: Double            // SwiftUI-owned state flows in

    func makeUIView(context: Context) -> RingView {
        RingView()                  // create + one-time config only
    }

    func updateUIView(_ uiView: RingView, context: Context) {
        uiView.progress = progress  // push current SwiftUI values into the view
    }

    // Optional static cleanup before removal (remove observers, cancel work).
    static func dismantleUIView(_ uiView: RingView, coordinator: Coordinator) {}
}
```

- `makeUIView` runs **once**; do all recurring work in `updateUIView`. Do not create the view or add gesture recognizers again inside `updateUIView`.
- `updateUIView` is called for external SwiftUI invalidation — read every SwiftUI value the view depends on and apply it idempotently. Guard against redundant writes (`if uiView.x != x`) to avoid animation/layout thrash and feedback loops.
- Never mutate SwiftUI `@State`/`Binding` *synchronously inside* `updateUIView` — it re-enters the update pass. Defer to the next runloop or route changes through the Coordinator.
- `dismantleUIView` is a **static** type method; it can't capture instance state — reach shared state via the passed `coordinator`.
- `context.environment` exposes the SwiftUI environment (`.colorScheme`, `.layoutDirection`, `.dynamicTypeSize`, `.isEnabled`, …); apply the relevant ones so the wrapped view honors SwiftUI context.

<a id="coordinator"></a>
## Coordinator (delegates / target-action)

A `Coordinator` is your bridge for **UIKit → SwiftUI** callbacks: delegate methods, target-action, `NSObject` selectors. SwiftUI calls `makeCoordinator()` **before** `makeUIView`, then hands it back via `context.coordinator`.

```swift
struct SearchField: UIViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.delegate = context.coordinator          // wire delegate to the coordinator
        return bar
    }

    func updateUIView(_ uiView: UISearchBar, context: Context) {
        context.coordinator.parent = self            // refresh the captured struct
        if uiView.text != text { uiView.text = text }
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func searchBar(_ searchBar: UISearchBar, textDidChange s: String) {
            parent.text = s                          // write back into the SwiftUI Binding
        }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            parent.onSubmit()
        }
    }
}
```

- The representable struct is recreated on every SwiftUI update; the **Coordinator persists** across updates. Refresh its `parent` in `updateUIView` so callbacks see fresh closures/bindings.
- Coordinator writing to a `@Binding` from a delegate is the canonical UIKit→SwiftUI data path. That write happens during a UIKit event, not inside `updateUIView`, so it's safe.
- Watch for retain cycles: the Coordinator holds `parent` (a value type — fine), but if you stash the `UIView`/closures, avoid strong cycles back to the Coordinator.

<a id="sizethatfits"></a>
## sizeThatFits — sizing into the SwiftUI layout system

By default a wrapped view sizes via Auto Layout / `intrinsicContentSize`, which often collapses or over-expands. On **iOS 16+** implement `sizeThatFits(_:uiView:context:)` to participate in SwiftUI layout directly (mirrors the `Layout` protocol).

```swift
func sizeThatFits(_ proposal: ProposedViewSize,
                  uiView: UITextView,
                  context: Context) -> CGSize? {
    // proposal dimensions may be nil (unspecified), 0, or .infinity.
    let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
    let fitting = uiView.sizeThatFits(
        CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: fitting.height)   // e.g. self-sizing text
}
```

- May be called **multiple times per layout pass** with different proposals — keep it pure and cheap.
- Return `nil` to fall back to SwiftUI's default sizing algorithm for that proposal.
- `ProposedViewSize.width`/`.height` are `CGFloat?`; `nil` = "unspecified", `.zero`/`.infinity` probe min/max. Handle all three.
- The same method exists on `UIViewControllerRepresentable` as `sizeThatFits(_:uiViewController:context:)` (iOS 16+).
- Prefer this over hacks like fixing `.frame(height:)` from outside or toggling `translatesAutoresizingMaskIntoConstraints`.

<a id="uiviewcontrollerrepresentable"></a>
## UIViewControllerRepresentable

Same shape, for a `UIViewController`. Required: `makeUIViewController(context:)` and `updateUIViewController(_:context:)`.

```swift
struct PageController: UIViewControllerRepresentable {
    @Binding var index: Int
    var pages: [UIViewController]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll,
                                       navigationOrientation: .horizontal)
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        pvc.setViewControllers([pages[index]], direction: .forward, animated: true)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource,
                             UIPageViewControllerDelegate {
        var parent: PageController
        init(_ parent: PageController) { self.parent = parent }
        // dataSource/delegate methods write parent.index back…
    }
}
```

- Also has an optional static `dismantleUIViewController(_:coordinator:)`.
- Presenting UIKit modals: don't `present(...)` from inside these methods. Drive presentation with a SwiftUI `.sheet`/`.fullScreenCover` wrapping the representable, and dismiss via `@Environment(\.dismiss)` or a Coordinator callback + `@Binding var isPresented`.

<a id="wrapping"></a>
## Wrapping system controllers (mail / share / photos / PDF)

Standard pattern: wrap the UIKit controller, use a Coordinator as its delegate, and dismiss from the delegate callback. Full bodies in `references/wrapping-system-controllers.md`.

- **MFMailComposeViewController** (`import MessageUI`): **must** gate on `MFMailComposeViewController.canSendMail()` first — presenting when it's `false` (no Mail account; always `false` on Mac/Simulator) fails/crashes. Coordinator conforms to `MFMailComposeViewControllerDelegate`; call `controller.dismiss` in `didFinishWith`. Provide a `mailto:` fallback when `canSendMail()` is false.
- **UIActivityViewController** (share sheet): init with `activityItems:` (+ optional `applicationActivities:`). On iPad it presents in a popover — set `popoverPresentationController?.sourceView`/`sourceItem` or it crashes on regular-width. Read the outcome via `completionWithItemsHandler`. Often simpler to use SwiftUI's native `ShareLink` when the payload is a `Transferable`; wrap only for custom activities.
- **PHPickerViewController** (`import PhotosUI`): build `PHPickerConfiguration(photoLibrary: .shared())` (so results carry `assetIdentifier`), set `.filter` (`.images`, `.videos`, `.livePhotos`, combine with `.any(of:)`) and `.selectionLimit`. Coordinator is the `PHPickerViewControllerDelegate`; load results off `PHPickerResult.itemProvider` (`loadObject(ofClass: UIImage.self)`), then hop to `@MainActor` before touching SwiftUI state. No photo-library permission prompt is needed for the picker itself. Deeper photo work → **photokit**.
- **PDFView** (`import PDFKit`) is a `UIView` → wrap with `UIViewRepresentable`; set `document = PDFDocument(url:)`, `autoScales = true`, `displayMode`. Rendering/annotation depth → **pdfkit**.
- **CNContactPickerViewController** → wrap likewise; picker delegate depth → **contacts-framework**.
- **Web content:** on iOS 26 prefer SwiftUI's native `WebView`/`WebPage` (→ **swiftui-webkit**) over wrapping `WKWebView` yourself.

<a id="uihostingcontroller"></a>
## UIHostingController — SwiftUI inside UIKit

`UIHostingController<Content>` is a `UIViewController` hosting a SwiftUI `Content`.

```swift
import SwiftUI

let host = UIHostingController(rootView: BalanceCard(account: account))

// Embed as a child view controller (correct containment):
addChild(host)
host.view.translatesAutoresizingMaskIntoConstraints = false
view.addSubview(host.view)
NSLayoutConstraint.activate([
    host.view.topAnchor.constraint(equalTo: view.topAnchor),
    host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
])
host.didMove(toParent: self)
```

- Always do full VC containment: `addChild` → add subview → `didMove(toParent:)`. Skipping it breaks safe-area, trait, and appearance propagation.
- **Self-sizing (iOS 16+):** set `host.sizingOptions = .intrinsicContentSize` so the host's view drives Auto Layout from the SwiftUI content's ideal size (great for cells/stack views); `.preferredContentSize` updates the VC's `preferredContentSize` (popovers/sheets). Sizing has a per-update cost — the host measures ideal size on every change.
- Update the content by reassigning `host.rootView` (Content is a value type; store the host, swap the view).
- `push`/`present` a `UIHostingController` like any VC to route from a UIKit navigation stack into a SwiftUI screen.
- KMP: a Compose-Multiplatform screen reaches iOS via `ComposeUIViewController`, not `UIHostingController`. To host the shared module in an iOS app shell, see **kmp-ios-integration**.

<a id="uihostingconfiguration"></a>
## UIHostingConfiguration — SwiftUI in cells (iOS 16+)

Host SwiftUI directly in a `UICollectionViewCell`/`UITableViewCell` via `contentConfiguration` — no child-VC bookkeeping, and list APIs (swipe actions, separators) bridge automatically.

```swift
cell.contentConfiguration = UIHostingConfiguration {
    HStack {
        Image(systemName: "star").foregroundStyle(.purple)
        Text("Favorites"); Spacer()
    }
}
.background(Color(.systemBackground))
.margins(.all, 12)          // override default cell margins
.minSize(width: 0, height: 0)   // allow full compression
```

- Conforms to `UIContentConfiguration`. Ideal for adopting SwiftUI cells inside an existing `UICollectionView`/diffable data source without rewriting the whole screen.
- Use in a cell registration closure so it re-evaluates on state change; capture the item value, not mutable outer state.
- `.margins(...)` overrides the default insets; `.minSize(...)` controls how small the cell may shrink.

<a id="observation"></a>
## @Observable observation tracking in UIKit (iOS 17 / 18 / 26)

The Observation framework (`@Observable`, iOS 17+) lets **UIKit** views/controllers auto-refresh when observed model properties they read change — no manual `setNeedsLayout()`.

- **Model:** annotate with `@Observable` (→ **swiftui-observation** for the model side).
- **Where tracking works:** properties read inside a `UIView`'s `updateProperties()` / `layoutSubviews()` and a `UIViewController`'s `updateProperties()` / `viewWillLayoutSubviews()` are tracked; a change invalidates that method and UIKit re-runs it.
- **`updateProperties()`** (iOS 26) runs *before* layout — the recommended place to set text/colors/visibility from your model; keep frame math in `layoutSubviews`.
- **Availability gate:**
  - iOS 17: Observation framework exists, but UIKit auto-tracking does **not**.
  - iOS 18: auto-tracking is **opt-in** — add `UIObservationTrackingEnabled = true` to `Info.plist`.
  - iOS 26: **on by default**.
- Without/below these, fall back to manual invalidation (`setNeedsLayout()` / `setNeedsUpdateProperties()` on a Combine/`withObservationTracking` change) — see **combine-framework**.
- This is orthogonal to representables: it's how the *UIKit side* of a mixed screen reacts to a shared `@Observable` store the SwiftUI side also observes.

<a id="migration"></a>
## Incremental migration (UIKit → SwiftUI)

- **Leaf-first:** replace individual cells/subviews with `UIHostingConfiguration` / `UIHostingController` while the surrounding screen stays UIKit.
- **Screen-first:** push/present a `UIHostingController` for whole new screens; keep the existing `UINavigationController` stack.
- **Shared state across the boundary:** put an `@Observable` store in the environment for SwiftUI (`.environment`) and read it in UIKit via observation tracking (above) — one source of truth, both frameworks react.
- **Two-way during transition:** SwiftUI can host UIKit (`…Representable`) that itself hosts SwiftUI (`UIHostingController`); works but adds measurement passes — flatten once the leaf is fully SwiftUI.
- Navigation ownership must sit on one side at a time; don't mix `NavigationStack` and `UINavigationController` for the *same* flow. Route the migration plan through **navigation** and **swift-architecture**.

<a id="checklist"></a>
## Correctness checklist

- [ ] `makeUIView`/`makeUIViewController` does one-time creation only; all recurring updates live in `updateUIView`/`updateUIViewController`.
- [ ] `updateUIView` is idempotent and guards redundant writes; it never mutates SwiftUI `@State`/`@Binding` synchronously.
- [ ] UIKit→SwiftUI callbacks go through a `Coordinator` (delegate/target-action); `parent` refreshed in `update…`.
- [ ] `makeCoordinator()` present whenever a delegate/data-source/target-action is wired.
- [ ] Custom sizing uses `sizeThatFits(_:uiView:context:)` (iOS 16+) and handles `nil`/`0`/`.infinity` proposals; no external `.frame` hacks.
- [ ] Relevant `context.environment` values (colorScheme, dynamicTypeSize, layoutDirection, isEnabled) applied to the wrapped view.
- [ ] `MFMailComposeViewController.canSendMail()` checked before presenting; `mailto:` fallback provided.
- [ ] `UIActivityViewController` popover source set for iPad/regular-width.
- [ ] `PHPickerConfiguration(photoLibrary: .shared())`; results loaded off the item provider, then hopped to `@MainActor`.
- [ ] `UIHostingController` embedded with full containment (`addChild` → subview → `didMove`); `sizingOptions` set when it must self-size.
- [ ] `@Observable` UIKit tracking gated by version: iOS 18 needs `UIObservationTrackingEnabled`; manual invalidation fallback below iOS 26.
- [ ] No retain cycle between a Coordinator and the view/controller it owns.
```
