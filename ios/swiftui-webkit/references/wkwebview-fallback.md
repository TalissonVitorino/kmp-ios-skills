# WKWebView fallback (deployment target < iOS 26)

Full `UIViewRepresentable` bridge for targets that can't use `WebView`/`WebPage`.
Mirror the native-API behaviors (progress, navigation policy, JS bridge) so callers
above and below iOS 26 behave the same. General bridging rules: `swiftui-uikit-interop`.

## View model + representable

```swift
import SwiftUI
import WebKit

@MainActor @Observable
final class LegacyWebModel {
    var title = ""
    var estimatedProgress = 0.0
    var isLoading = false
    var url: URL?
    let allowedHosts: Set<String>

    init(allowedHosts: Set<String> = []) { self.allowedHosts = allowedHosts }
}

@available(iOS, deprecated: 26.0, message: "Use WebView/WebPage on iOS 26+")
struct LegacyWebView: UIViewRepresentable {
    @Bindable var model: LegacyWebModel
    let request: URLRequest

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // JS→native bridge: page calls window.webkit.messageHandlers.native.postMessage(...)
        config.userContentController.add(context.coordinator, name: "native")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.observe(webView)     // KVO: progress / title / url / loading
        webView.load(request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != request.url, context.coordinator.lastRequestedURL != request.url {
            context.coordinator.lastRequestedURL = request.url
            webView.load(request)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    // WKWebView keeps a strong ref to observations; drop them on teardown.
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tokens.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "native")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: LegacyWebModel
        var tokens: [NSKeyValueObservation] = []
        var lastRequestedURL: URL?

        init(model: LegacyWebModel) { self.model = model }

        func observe(_ webView: WKWebView) {
            tokens = [
                webView.observe(\.estimatedProgress, options: [.new]) { [model] wv, _ in
                    Task { @MainActor in model.estimatedProgress = wv.estimatedProgress }
                },
                webView.observe(\.title, options: [.new]) { [model] wv, _ in
                    Task { @MainActor in model.title = wv.title ?? "" }
                },
                webView.observe(\.url, options: [.new]) { [model] wv, _ in
                    Task { @MainActor in model.url = wv.url }
                },
                webView.observe(\.isLoading, options: [.new]) { [model] wv, _ in
                    Task { @MainActor in model.isLoading = wv.isLoading }
                },
            ]
        }

        // Host allowlist — same policy as the native NavigationDeciding.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard !model.allowedHosts.isEmpty else { return .allow }
            guard let host = navigationAction.request.url?.host else { return .cancel }
            return model.allowedHosts.contains(host) ? .allow : .cancel
        }

        // JS→native messages.
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "native" else { return }
            // handle message.body (validate before acting)
        }
    }
}
```

## Notes

- KVO on `estimatedProgress` / `title` / `url` / `isLoading` reproduces the native
  observable properties. Hop to `@MainActor` before mutating the model.
- Keep the `NSKeyValueObservation` tokens alive for the view's lifetime and clear
  them in `dismantleUIView` to avoid leaks / dangling observers.
- `removeScriptMessageHandler(forName:)` on teardown breaks the retain cycle between
  the content controller and the coordinator.
- For `evaluateJavaScript`, the legacy async form is
  `func evaluateJavaScript(_:) async throws -> Any?`; the function-body form is
  `callAsyncJavaScript(_:arguments:in:contentWorld:)` (note: the native SwiftUI model
  renamed this to `callJavaScript`).
```
