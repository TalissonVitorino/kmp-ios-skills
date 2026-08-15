# Two-way JavaScript bridge (WebPage)

Native↔JS in the WebKit-for-SwiftUI world has two directions:

- **Native → JS:** `await page.callJavaScript(_:arguments:in:contentWorld:)`.
- **JS → native:** a script message handler registered on `WebPage.Configuration`.

## Native → JS

```swift
// Read a value out of the page.
let href = try await page.callJavaScript("return window.location.href") as? String

// Call into a page-defined function with typed, escaped arguments.
_ = try await page.callJavaScript(
    "return window.app.setBalance(amount, currency)",
    arguments: ["amount": "1234.56", "currency": "USD"]     // pass money as String, never Double
)

// Run in an isolated world so the page can't shadow your helpers.
let token = try await page.callJavaScript(
    "return sessionStorage.getItem('csrf')",
    contentWorld: .defaultClient
) as? String
```

- Never interpolate untrusted values into `functionBody`; route them through
  `arguments`. Interpolation is a script-injection vector.
- Return values arrive as `Any?` (`nil` = no return, `NSNull` = JS `null`). Cast and
  validate; treat page output as untrusted input.
- Money/decimals: pass and receive as strings, parse into a `Money`/`Decimal` on the
  Swift side (see `kmp-money` / `swift-formatstyle`) — never marshal through `Double`.

## JS → native (message handlers)

Configure a handler on `WebPage.Configuration` so page JS can post messages to your
app. The precise handler-registration API on `WebPage.Configuration` is evolving
across the iOS 26 SDK seeds — confirm the exact symbol
(`userContentController` / add-script-message-handler equivalent) against the
installed WebKit SwiftUI headers before wiring it, and validate every inbound
`message.body` against an expected schema before acting on it.

```js
// page side
window.webkit.messageHandlers.<name>.postMessage({ type: "checkout", id: "42" });
```

Security rules for JS→native bridges (fintech):

- Expose the **narrowest** possible surface — one handler, an explicit `type` switch,
  no generic "eval this" or "open this URL" primitive.
- Validate/whitelist every field; reject unknown `type`s.
- Only register the bridge on pages you control (your own origin / custom scheme),
  gated by the `NavigationDeciding` allowlist — never on arbitrary remote content.
- Run privileged bridge scripts in a dedicated `WKContentWorld`, isolated from the
  page's own scripts.
```
