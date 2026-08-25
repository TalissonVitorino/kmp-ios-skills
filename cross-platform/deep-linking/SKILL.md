---
name: deep-linking
description: Deep linking patterns for mobile - Android App Links, iOS Universal Links, intent filters, URI handling, deferred deep links, and navigation integration.
---

# Deep Linking Patterns for Mobile

## URI Scheme Design

Design a consistent URI scheme before implementation:

```
myapp://                          # App root
myapp://home                      # Home screen
myapp://product/{id}              # Product detail
myapp://profile/{userId}          # User profile
myapp://settings/notifications    # Nested settings
myapp://search?q={query}          # Query parameters
```

Keep paths RESTful, lowercase, and predictable. Use path segments for hierarchy and query params for filters.

Custom schemes are neither unique nor secure — any app can register `myapp://`. Use them only as an internal/fallback channel; user-facing links should be verified HTTPS App Links (Android) / Universal Links (iOS). Note the parsing asymmetry: in `myapp://product/123` the "product" part is the URI **host**, while in `https://www.myapp.com/product/123` it is the first **path segment** — normalize before routing (see handlers below).

---

## Android

### Intent Filter in AndroidManifest.xml

```xml
<activity
    android:name=".MainActivity"
    android:exported="true">

    <!-- Custom URI scheme: matches every myapp:// URI.
         Adding android:host would restrict to one host, e.g. myapp://product/... -->
    <intent-filter>
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="myapp" />
    </intent-filter>

    <!-- App Links (HTTPS, verified via assetlinks.json) -->
    <intent-filter android:autoVerify="true">
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data
            android:scheme="https"
            android:host="www.myapp.com"
            android:pathPrefix="/product" />
    </intent-filter>
</activity>
```

Since Android 12, `https` intent filters only open the app if `autoVerify` succeeds against `assetlinks.json`; unverified web links go to the browser unless the user manually approves the domain in Settings → Apps → *Open by default*. Custom-scheme filters are unaffected.

### App Links with assetlinks.json

Host at `https://www.myapp.com/.well-known/assetlinks.json`:

```json
[{
  "relation": ["delegate_permission/common.handle_all_urls"],
  "target": {
    "namespace": "android_app",
    "package_name": "com.myapp.android",
    "sha256_cert_fingerprints": [
      "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
    ]
  }
}]
```

Get your certificate fingerprint:
```bash
keytool -list -v -keystore my-release-key.keystore -alias my-key-alias
```

With Play App Signing (the default), Google re-signs releases — use the **app signing key** fingerprint from Play Console → Test and release → App integrity → Play app signing, not your upload key. Play Console can also generate the full `assetlinks.json` there. Include both fingerprints if debug builds must verify too.

### Handling Deep Links in Activity

```kotlin
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleDeepLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent) // keep getIntent() current for later reads
        handleDeepLink(intent)
    }

    private fun handleDeepLink(intent: Intent) {
        val uri = intent.data ?: return
        // Normalize: myapp://product/123 → host="product", path="/123";
        // https://www.myapp.com/product/123 → path="/product/123"
        val isWebLink = uri.scheme == "https" || uri.scheme == "http"
        val segments = buildList<String> {
            if (!isWebLink) uri.host?.let { add(it) }
            addAll(uri.pathSegments)
        }

        when (segments.firstOrNull()) {
            "product" -> navigateToProduct(segments.getOrNull(1))
            "profile" -> navigateToProfile(segments.getOrNull(1))
        }
    }
}
```

`onNewIntent` only fires for an already-running Activity with `launchMode="singleTop"` (or `singleTask`/`FLAG_ACTIVITY_SINGLE_TOP`); otherwise a new instance is created and only `onCreate` runs.

### Compose Navigation Deep Link Integration

```kotlin
NavHost(navController, startDestination = "home") {
    composable(
        route = "product/{productId}",
        arguments = listOf(navArgument("productId") { type = NavType.StringType }),
        deepLinks = listOf(
            navDeepLink { uriPattern = "myapp://product/{productId}" },
            navDeepLink { uriPattern = "https://www.myapp.com/product/{productId}" }
        )
    ) { backStackEntry ->
        val productId = backStackEntry.arguments?.getString("productId")
        ProductScreen(productId = productId)
    }
}
```

With the default `standard` launch mode the NavController consumes the launching intent by itself; with `singleTop`/`singleTask` you must forward it via `navController.handleDeepLink(intent)` inside `onNewIntent`, otherwise links arriving at a running Activity are dropped.

### Deferred Deep Links (Install Attribution)

> ⚠️ **Firebase Dynamic Links is gone.** Deprecated in 2023, console read-only since May 2024, **fully shut down on 25 Aug 2025** — `page.link` / `app.goo.gl` URLs now 404. Do not use `Firebase.dynamicLinks`; migrate to a maintained alternative.

Current options for deferred deep links that survive app install:
- **Third-party attribution SDKs** — Branch, AppsFlyer, or Adjust (each exposes a callback delivering the deferred link on first launch).
- **Google Play Install Referrer API** (`com.android.installreferrer:installreferrer`) — read the `install_referrer` string (your own encoded path) right after install and route from it.
- **App Links + a landing page** — an https App Link that, when the app isn't installed, sends the user to a web page that stores the intended destination (e.g. via the Play referrer) and resumes it post-install.

```kotlin
// com.android.installreferrer:installreferrer:2.2
// Deferred routing without a third-party SDK
val client = InstallReferrerClient.newBuilder(context).build()
client.startConnection(object : InstallReferrerStateListener {
    override fun onInstallReferrerSetupFinished(responseCode: Int) {
        if (responseCode == InstallReferrerClient.InstallReferrerResponse.OK) {
            val referrer = client.installReferrer.installReferrer // e.g. "deeplink=%2Fproduct%2F42"
            parseDeferredDestination(referrer)?.let { uri: Uri -> navigateTo(uri) }
        }
        client.endConnection() // always close; the referrer is fixed until reinstall
    }
    override fun onInstallReferrerServiceDisconnected() { /* retry on next request */ }
})
```

Call this once, on the first launch after install — Play keeps the referrer for 90 days and it never changes until the app is reinstalled.

---

## iOS

### Universal Links with apple-app-site-association

Host at `https://www.myapp.com/.well-known/apple-app-site-association`:

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["TEAMID.com.myapp.ios"],
        "components": [
          { "/": "/product/*" },
          { "/": "/profile/*" },
          { "/": "/settings/*" },
          { "/": "/help/*", "exclude": true }
        ]
      }
    ]
  }
}
```

Use the iOS 13+ format above (`appIDs` array + `components`); the legacy `paths` key still parses but is ignored whenever `components` is present. Serve the file over HTTPS with `Content-Type: application/json`, no redirects, no file extension, under 128 KB. Since iOS 14, devices fetch it through Apple's CDN — not your server directly — so propagation can lag; for development, toggle "Associated Domains Development" in Settings → Developer and use `applinks:www.myapp.com?mode=developer` to bypass the CDN.

Enable Associated Domains in Xcode (Signing & Capabilities): `applinks:www.myapp.com`

### URL Schemes in Info.plist

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>myapp</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.myapp.ios</string>
    </dict>
</array>
```

### Handling in AppDelegate / SceneDelegate

```swift
// SceneDelegate — app already running
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    DeepLinkRouter.shared.handle(url: url)
}

// Universal Links — app already running
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL else { return }
    DeepLinkRouter.shared.handle(url: url)
}

// Cold start: the link arrives in connectionOptions, NOT the methods above
func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
    if let url = connectionOptions.urlContexts.first?.url {
        DeepLinkRouter.shared.handle(url: url)
    } else if let url = connectionOptions.userActivities.first?.webpageURL {
        DeepLinkRouter.shared.handle(url: url)
    }
}
```

### SwiftUI .onOpenURL

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    DeepLinkRouter.shared.handle(url: url)
                }
        }
    }
}
```

In the SwiftUI App lifecycle, `.onOpenURL` receives both custom-scheme URLs and Universal Links (cold start included) — no SceneDelegate needed.

---

## Deep Link Routing Architecture

```swift
// iOS Router
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var destination: Destination?

    enum Destination: Equatable {
        case product(id: String)
        case profile(userId: String)
        case settings
    }

    func handle(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return }
        // Normalize: myapp://product/123 → host="product", path="/123";
        // https://www.myapp.com/product/123 → path="/product/123"
        var segments = components.path.split(separator: "/").map(String.init)
        let isWebLink = components.scheme == "https" || components.scheme == "http"
        if !isWebLink, let host = components.host {
            segments.insert(host, at: 0)
        }

        switch segments.first {
        case "product":
            destination = .product(id: segments.dropFirst().first ?? "")
        case "profile":
            destination = .profile(userId: segments.dropFirst().first ?? "")
        default:
            break
        }
    }
}
```

---

## Testing Deep Links

```bash
# Android - test custom scheme
adb shell am start -a android.intent.action.VIEW -d "myapp://product/123"

# Android - test App Links
adb shell am start -a android.intent.action.VIEW -d "https://www.myapp.com/product/123"

# Android 12+ - check App Links verification state
adb shell pm get-app-links com.myapp.android

# Force re-verification: reset the stored state first, then re-verify
adb shell pm set-app-links --package com.myapp.android 0 all
adb shell pm verify-app-links --re-verify com.myapp.android

# iOS Simulator - test URL scheme
xcrun simctl openurl booted "myapp://product/123"

# iOS Simulator - test Universal Link
xcrun simctl openurl booted "https://www.myapp.com/product/123"
```

## Analytics Tracking for Deep Links

Track deep link opens with source attribution:

```kotlin
fun trackDeepLinkOpen(uri: Uri, source: String) {
    analytics.logEvent("deep_link_opened") {
        param("uri", uri.toString())
        param("source", source) // "notification", "email", "social", "qr_code"
        param("path", uri.path ?: "")
        param("has_referrer", (uri.getQueryParameter("ref") != null).toString())
    }
}
```
