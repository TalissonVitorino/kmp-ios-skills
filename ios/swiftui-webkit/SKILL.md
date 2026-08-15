---
name: swiftui-webkit
description: "Embed web content in SwiftUI with the native WebKit-for-SwiftUI API (iOS/macOS 26+) — WebView(url:) and WebView(_:) driven by an @Observable WebPage (load(_:URLRequest)/load(html:baseURL:), observable url/title/isLoading/estimatedProgress, the navigations event stream, serverTrust), WebPage.NavigationDeciding policy control, callJavaScript native↔JS bridging, custom URLSchemeHandler schemes, and back/forward via backForwardList. Includes the WKWebView UIViewRepresentable fallback for < iOS 26. Use when showing a web page, in-app browser, OAuth/payment web flow, or JS bridge in a SwiftUI fintech app. For the general UIKit↔SwiftUI bridge see swiftui-uikit-interop; for @Observable state see swiftui-observation; for TLS/SPKI pinning and serverTrust evaluation see swift-security; for opening system browser / Universal Links see deep-linking."
---

# WebKit for SwiftUI (iOS / macOS 26+)

Native SwiftUI web content: no `UIViewRepresentable`, no `WKWebView` bridging.
`WebView` is the on-screen view; `WebPage` (an `@Observable` model) loads, observes,
and controls the content. Grounded in Apple's WebKit-for-SwiftUI framework.

- **Availability:** `WebView` / `WebPage` are **iOS 26 / macOS 26 / visionOS 26+**. For earlier deployment targets wrap `WKWebView` in a `UIViewRepresentable` — see [Fallback](#fallback) and `references/wkwebview-fallback.md`.
- **State:** `WebPage` is a plain `@Observable` class — observe it exactly like any `swiftui-observation` model (`@State private var page = WebPage()`).
- **Security:** the web layer is an attack surface. Restrict navigation with `NavigationDeciding`, never inject unsanitized input into `callJavaScript`, and evaluate `serverTrust` / pin per `swift-security` for money-moving flows.

## Contents

- [WebView — display](#webview)
- [WebPage — the model](#webpage)
- [Loading content](#loading)
- [Navigation events](#events)
- [Deciding navigation policy](#policy)
- [JavaScript bridge](#javascript)
- [Custom URL schemes](#schemes)
- [Back / forward history](#history)
- [TLS / serverTrust](#trust)
- [WKWebView fallback (< iOS 26)](#fallback)
- [Checklist](#checklist)
- References: `references/wkwebview-fallback.md`, `references/javascript-bridge.md`

<a id="webview"></a>
## WebView — display

```swift
import SwiftUI
import WebKit

// 1. Simplest: give it a URL. WebView owns an internal WebPage.
struct SimpleBrowser: View {
    var body: some View {
        WebView(url: URL(string: "https://www.apple.com"))
    }
}

// 2. Drive it with your own WebPage when you need control/observation.
struct ControlledBrowser: View {
    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .navigationTitle(page.title)      // observable, updates live
            .task { page.load(URLRequest(url: URL(string: "https://www.apple.com")!)) }
    }
}
```

- `WebView(url:)` takes an optional `URL?`; assigning a new URL (e.g. via `.onChange`) navigates. A `nil` URL shows blank.
- `WebView(_:)` takes a `WebPage` — use this whenever you need the model's properties, JS calls, or navigation policy.
- Standard SwiftUI layout/modifiers apply. WebKit-specific view modifiers (scroll position, magnification/back-forward gestures, link previews, find-in-page) exist but names vary by SDK — confirm against the installed WebKit SwiftUI headers before relying on a specific one.

<a id="webpage"></a>
## WebPage — the model

`WebPage` is `@MainActor`, `@Observable`. Its key observable properties:

| Property | Type | Notes |
|---|---|---|
| `url` | `URL?` | Current committed URL. |
| `title` | `String` | Document title (empty when none). |
| `isLoading` | `Bool` | A navigation is in flight. |
| `estimatedProgress` | `Double` | 0.0–1.0 — bind to a `ProgressView`. |
| `navigations` | `some AsyncSequence<WebPage.NavigationEvent, any Error>` | Page-wide stream of navigation events (see below). |
| `serverTrust` | `SecTrust?` | Trust object of the current page for evaluation/pinning. |
| `backForwardList` | `WebPage.BackForwardList` | `backList` / `currentItem` / `forwardList`. |

```swift
struct ProgressBrowser: View {
    @State private var page = WebPage()

    var body: some View {
        VStack(spacing: 0) {
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)   // observable
            }
            WebView(page)
        }
        .task { page.load(URL(string: "https://www.apple.com")) }
    }
}
```

Construct with configuration and/or a navigation decider:

```swift
let page = WebPage()                                        // defaults
let configured = WebPage(configuration: config)            // WebPage.Configuration
let policed = WebPage(configuration: config, navigationDecider: MyDecider())
```

<a id="loading"></a>
## Loading content

Every `load` overload is `@MainActor @discardableResult` and returns
`some AsyncSequence<WebPage.NavigationEvent, any Error>` — you may ignore it,
`await` it, or `for try await` its events.

```swift
page.load(URLRequest(url: url))                             // network / local URL request
page.load(url)                                             // convenience for URL?
page.load(html: "<h1>Hello</h1>", baseURL: URL(string: "about:blank")!)
page.load(Data(...), mimeType: "application/pdf",
          characterEncoding: .utf8, baseURL: baseURL)
page.load(backForwardItem)                                 // WebPage.BackForwardList.Item

// Simulated response — render your own bytes under a real request URL
// (useful for offline snapshots / signed content):
page.load(simulatedRequest: URLRequest(url: url), responseHTML: html)
```

- Prefer `URLRequest` over a bare `URL` when you need cache policy, timeouts, or headers.
- `load(html:baseURL:)`: the `baseURL` resolves relative links and — combined with a custom scheme — governs what local resources the page may reach.
- Cancelling the `Task` that owns the returned sequence stops loading all resources.

<a id="events"></a>
## Navigation events

Iterate the sequence returned by `load`, or the page-wide `page.navigations`
sequence, to track a navigation lifecycle without a delegate.

```swift
func open(_ url: URL) async {
    do {
        for try await event in page.load(URLRequest(url: url)) {
            // event: WebPage.NavigationEvent — drive UI off its state transitions
            print("navigation event: \(event)")
        }
        // sequence completes when the navigation finishes
    } catch {
        // navigation failed (network error, policy cancel, etc.)
        showError(error)
    }
}
```

- The concrete `WebPage.NavigationEvent` case set (e.g. started / committed / finished / failed transitions) is defined by the SDK — switch on it against the installed headers rather than hardcoding case names from memory.
- Completion of the async sequence == navigation done; a thrown error == navigation failed. This is the idiomatic replacement for `WKNavigationDelegate`'s `didFinish` / `didFail`.

<a id="policy"></a>
## Deciding navigation policy

Conform a type to `WebPage.NavigationDeciding` to allow/cancel navigations and
inspect responses — the SwiftUI equivalent of `WKNavigationDelegate`'s
`decidePolicyFor`. Both requirements have default implementations returning `.allow`;
implement only what you need.

```swift
struct AllowlistDecider: WebPage.NavigationDeciding {
    let allowedHosts: Set<String>

    // Called before a navigation starts. `preferences` is inout — mutate it to
    // adjust content mode / JS enablement for this navigation.
    @MainActor
    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let host = action.request.url?.host() else { return .cancel }
        return allowedHosts.contains(host) ? .allow : .cancel
    }

    // Called after the response headers arrive.
    @MainActor
    func decidePolicy(
        for response: WebPage.NavigationResponse
    ) async -> WKNavigationResponsePolicy {
        .allow
    }
}

let page = WebPage(navigationDecider: AllowlistDecider(allowedHosts: ["apple.com", "www.apple.com"]))
```

- **Fintech pattern:** allowlist the exact hosts of your OAuth / payment flow and `.cancel` everything else. Route cancelled off-domain links to the system browser (`openURL` / see `deep-linking`) instead of loading them in-app.
- `WKNavigationActionPolicy` is `.allow` / `.cancel` (`.download` where downloads apply); `WKNavigationResponsePolicy` is `.allow` / `.cancel`.
- The decider is passed at init (`WebPage(navigationDecider:)` / `WebPage(configuration:navigationDecider:)`) — it is part of the page's identity, not a settable delegate.

<a id="javascript"></a>
## JavaScript bridge

`callJavaScript` runs a string as an **async function body** and returns its result.

```swift
// Signature (verified):
// func callJavaScript(_ functionBody: String,
//                     arguments: [String: Any] = [:],
//                     in frame: WebPage.FrameInfo? = nil,
//                     contentWorld: WKContentWorld? = nil) async throws -> Any?

let title = try await page.callJavaScript("return document.title") as? String

// Pass typed arguments — never string-interpolate untrusted input into the body:
let sum = try await page.callJavaScript(
    "return a + b",
    arguments: ["a": 20, "b": 22]                          // Numeric/String/Date/collections
) as? Int
```

- **Injection safety:** always pass user/remote data via `arguments`, not string interpolation — interpolating into `functionBody` is a script-injection vector. Treat the return value as untrusted; cast defensively.
- `arguments` values map to JS types (numbers, strings, dates, arrays, dictionaries). The result is bridged back to `Any?` (`nil` for no explicit return, `NSNull` for a JS `null`).
- `contentWorld` isolates your script from page scripts; use a dedicated world (e.g. `.defaultClient`) for privileged bridges so the page can't tamper with your functions.
- For **JS→native** messages (the page calling into your app) use a message handler on the `WebPage.Configuration`; see `references/javascript-bridge.md`.

<a id="schemes"></a>
## Custom URL schemes

Serve app-local resources under your own scheme by conforming to `URLSchemeHandler`
and registering it on the configuration. The handler's `reply(for:)` returns an
async sequence of `URLSchemeTaskResult` values — emit `.response(_:)` first, then
one or more `.data(_:)`.

```swift
struct BundleSchemeHandler: URLSchemeHandler {
    func reply(for request: URLRequest) -> some AsyncSequence<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            guard let url = request.url,
                  let path = localPath(for: url),
                  let data = try? Data(contentsOf: path) else {
                continuation.finish(throwing: URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            continuation.yield(.response(response))          // MUST precede any .data
            continuation.yield(.data(data))
            continuation.finish()
        }
    }
}

var config = WebPage.Configuration()
config.urlSchemeHandlers[URLScheme("app-resource")!] = BundleSchemeHandler()   // URLScheme(_:) is failable
let page = WebPage(configuration: config)
page.load(URLRequest(url: URL(string: "app-resource://index.html")!))
```

- `.response(_:)` must be added **before** any `.data(_:)`, and at least once; throw a `Failure` to report an error.
- You **cannot** register a scheme WebKit already handles (`http`, `https`, `file`, …) — doing so is a programmer error. Use a unique custom scheme.
- Keep handlers read-only against a whitelist of bundle paths; never map a scheme to arbitrary filesystem access derived from page-controlled URLs.

<a id="history"></a>
## Back / forward history

Navigate history through `backForwardList` and `load(_:)` with a list item.

```swift
struct NavBar: View {
    let page: WebPage

    var body: some View {
        HStack {
            Button("Back") {
                if let item = page.backForwardList.backList.last { page.load(item) }
            }
            .disabled(page.backForwardList.backList.isEmpty)

            Button("Forward") {
                if let item = page.backForwardList.forwardList.first { page.load(item) }
            }
            .disabled(page.backForwardList.forwardList.isEmpty)
        }
    }
}
```

- `backForwardList` exposes `backList` / `currentItem` / `forwardList` (`WebPage.BackForwardList.Item`s). `load(item)` navigates to a specific entry.
- `WebView` provides interactive swipe back/forward gestures on its own where the platform supports them; the buttons above are for explicit chrome.

<a id="trust"></a>
## TLS / serverTrust

`page.serverTrust` is the `SecTrust?` of the currently displayed page. For a fintech
in-app browser you can evaluate or SPKI-pin it after a navigation commits.

```swift
if let trust = page.serverTrust {
    var error: CFError?
    guard SecTrustEvaluateWithError(trust, &error) else {
        // untrusted chain — tear down the flow
        return
    }
    // extract leaf key + compare SPKI hash for pinning (see swift-security)
}
```

- Full SPKI-pinning (system-trust-first, correct ASN.1 header, ≥2 pins) belongs in `swift-security` — reuse that logic here rather than re-rolling it.
- Prefer declarative ATS `NSPinnedDomains` for pinning when you don't need per-navigation logic.

<a id="fallback"></a>
## WKWebView fallback (< iOS 26)

If your deployment target is below iOS 26, `WebView`/`WebPage` are unavailable —
bridge `WKWebView` with `UIViewRepresentable`. Gate on availability so you adopt the
native API where present.

```swift
@available(iOS, deprecated: 26.0, message: "Use WebView/WebPage on iOS 26+")
struct LegacyWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url { webView.load(URLRequest(url: url)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            .allow   // apply your allowlist here
        }
    }
}

struct AdaptiveWeb: View {
    let url: URL
    var body: some View {
        if #available(iOS 26, *) {
            WebView(url: url)
        } else {
            LegacyWebView(url: url)
        }
    }
}
```

- Full coordinator (progress KVO, JS message handler, error handling) is in `references/wkwebview-fallback.md`. General bridging guidance: `swiftui-uikit-interop`.

<a id="checklist"></a>
## Correctness checklist

- [ ] `WebView`/`WebPage` gated behind `#available(iOS 26, *)`; `WKWebView` `UIViewRepresentable` fallback for lower targets.
- [ ] `WebPage` held in `@State` (or an `@Observable` owner), not recreated each `body` pass.
- [ ] Navigation restricted with a `NavigationDeciding` host allowlist for auth/payment flows; off-domain links routed to the system browser, not loaded in-app.
- [ ] JS parameters passed via `callJavaScript(_:arguments:)` — never string-interpolated; return values cast defensively.
- [ ] Privileged JS bridges run in a dedicated `WKContentWorld`, not the page world.
- [ ] Custom `URLSchemeHandler` emits `.response(_:)` before `.data(_:)`, uses a unique scheme (not http/https/file), and maps only whitelisted local resources.
- [ ] `serverTrust` evaluated / SPKI-pinned per `swift-security` for money-moving web flows; ATS left enabled.
- [ ] Progress/title/loading UI bound to the observable `estimatedProgress` / `title` / `isLoading` rather than manual polling.
- [ ] `load(...)`'s async sequence consumed (or its owning `Task` retained) so cancellation stops the load; errors surfaced to the user.
