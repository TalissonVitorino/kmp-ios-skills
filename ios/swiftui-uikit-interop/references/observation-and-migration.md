# @Observable in UIKit + incremental migration

Depth for the two hardest parts of a mixed codebase: making the **UIKit side** react
to shared state, and sequencing a UIKit → SwiftUI migration safely.

## Automatic observation tracking in UIKit

The Observation framework (`@Observable`, iOS 17+) is the same store SwiftUI observes.
UIKit can auto-refresh from it — but the *auto-tracking* in UIKit ships later than the
framework itself.

### Version gate (important)

| iOS | Observation framework | UIKit auto-tracking |
|---|---|---|
| 17 | yes (`@Observable`, `withObservationTracking`) | no — manual only |
| 18 | yes | **opt-in**: `Info.plist` `UIObservationTrackingEnabled = true` |
| 26 | yes | **on by default**; `updateProperties()` available |

### Where reads are tracked

Reading an observable property inside these methods registers a dependency; a later
change invalidates the method and UIKit re-runs it:

- `UIView`: `updateProperties()` (iOS 26), `layoutSubviews()`, `draw(_:)`.
- `UIViewController`: `updateProperties()` (iOS 26), `viewWillLayoutSubviews()`.

`updateProperties()` runs *before* layout — set text/colors/images/visibility there;
keep frame arithmetic in `layoutSubviews`/`viewWillLayoutSubviews`.

```swift
@Observable final class AccountStore {
    var balance: Decimal = 0
    var isHidden = false
}

final class BalanceViewController: UIViewController {
    let store: AccountStore
    private let label = UILabel()
    init(store: AccountStore) { self.store = store; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    // iOS 26: re-runs automatically when balance/isHidden change.
    override func updateProperties() {
        super.updateProperties()
        label.text = store.isHidden ? "••••" : store.balance.formatted(.currency(code: "USD"))
    }
}
```

### Manual fallback (below iOS 26, or when off)

Use `withObservationTracking` for a one-shot observation, and re-arm it each time —
or bridge through Combine (**combine-framework**):

```swift
func observeBalance() {
    withObservationTracking {
        _ = store.balance          // read to register dependency
    } onChange: { [weak self] in
        Task { @MainActor in
            self?.setNeedsUpdateProperties()   // or setNeedsLayout()
            self?.observeBalance()             // re-arm: onChange fires once
        }
    }
}
```

- `onChange` fires **once** per tracked read set and runs synchronously *before* the value settles — hop to the main actor and re-register.
- `setNeedsUpdateProperties()` (iOS 26) / `setNeedsLayout()` coalesce into the next update pass.

## Sharing one source of truth across the boundary

- Create the `@Observable` store once; inject it into SwiftUI via `.environment(store)` and read it with `@Environment` or `@Bindable`.
- Hand the *same* instance to UIKit controllers by initializer. Both sides observe the same object → no manual syncing, no duplicated state.
- Do **not** mirror state into a separate UIKit model and try to keep them equal — that reintroduces the bugs Observation removes.

## Migration sequencing

1. **Inventory & pick direction per screen.** New screens: build in SwiftUI, present a `UIHostingController`. Existing screens: replace leaves first.
2. **Leaf replacement.** Swap a cell/subview for `UIHostingConfiguration` (cells) or an embedded `UIHostingController` (arbitrary subviews). The surrounding UIKit screen is untouched.
3. **Whole-screen replacement.** Push/present a `UIHostingController<NewScreen>` from the existing `UINavigationController`. Navigation still owned by UIKit.
4. **Flip navigation ownership** only once a contiguous flow is fully SwiftUI — then a `NavigationStack` owns it end-to-end. Never split one flow across `UINavigationController` and `NavigationStack` simultaneously.
5. **Collapse nesting.** Interim `SwiftUI → Representable(UIKit) → UIHostingController(SwiftUI)` sandwiches work but add measurement passes and can jitter sizing — remove the middle UIKit layer as soon as the leaf is native SwiftUI.

## Common interop pitfalls

- **Feedback loop:** writing a `@Binding`/`@State` synchronously inside `updateUIView` → re-entrant update → hang/flicker. Route writes through the Coordinator (delegate callback timing) or defer a runloop.
- **Stale closures:** the representable struct is recreated each update but the Coordinator persists — if you don't refresh `coordinator.parent` in `update…`, delegate callbacks fire old closures/bindings.
- **Collapsed/oversized wrapped views:** no `sizeThatFits` and a view without a good `intrinsicContentSize` → zero or infinite size. Implement `sizeThatFits` (iOS 16+).
- **Missing containment:** adding a hosting controller's `.view` without `addChild`/`didMove` breaks safe area, trait collection, and `viewWillAppear` propagation.
- **iPad share crash:** `UIActivityViewController` with no popover `sourceView`/`sourceItem` on regular-width.
- **Mail crash:** presenting `MFMailComposeViewController` without `canSendMail()`.
- **Off-main mutation:** `NSItemProvider.loadObject` / URLSession callbacks touching SwiftUI state without hopping to `@MainActor`.
