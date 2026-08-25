---
name: analytics-patterns
description: Analytics integration patterns - event tracking, screen tracking, user properties, Firebase Analytics, custom analytics providers, and privacy compliance.
---

# Analytics Integration Patterns

## Architecture

### AnalyticsProvider Interface (Kotlin)

```kotlin
interface AnalyticsProvider {
    fun logEvent(name: String, params: Map<String, Any> = emptyMap())
    fun setUserProperty(name: String, value: String)
    fun setUserId(userId: String?)
    fun logScreenView(screenName: String, screenClass: String? = null)
}
```

### AnalyticsProvider Protocol (Swift)

```swift
protocol AnalyticsProvider {
    func logEvent(_ name: String, parameters: [String: Any])
    func setUserProperty(_ value: String?, forName name: String)
    func setUserId(_ userId: String?)
    func logScreenView(screenName: String, screenClass: String?)
}
```

### Multi-Provider Analytics Manager

```kotlin
class AnalyticsManager(
    private val providers: List<AnalyticsProvider>,
    private val consentManager: ConsentManager
) {
    fun logEvent(name: String, params: Map<String, Any> = emptyMap()) {
        if (!consentManager.hasAnalyticsConsent()) return
        providers.forEach { it.logEvent(name, params) }
    }

    fun setUserProperty(name: String, value: String) {
        if (!consentManager.hasAnalyticsConsent()) return
        providers.forEach { it.setUserProperty(name, value) }
    }

    fun setUserId(userId: String?) {
        providers.forEach { it.setUserId(userId) }
    }

    fun logScreenView(screenName: String, screenClass: String? = null) {
        if (!consentManager.hasAnalyticsConsent()) return
        providers.forEach { it.logScreenView(screenName, screenClass) }
    }

    fun logEvent(event: AnalyticsEvent) = logEvent(event.name, event.params)
}
```

### Event Data Classes

```kotlin
sealed class AnalyticsEvent(
    val name: String,
    val params: Map<String, Any> = emptyMap()
) {
    // E-commerce
    class ViewProduct(productId: String, category: String) : AnalyticsEvent(
        name = "view_product",
        params = mapOf("product_id" to productId, "category" to category)
    )

    class AddToCart(productId: String, price: Double, quantity: Int) : AnalyticsEvent(
        name = "add_to_cart",
        params = mapOf("product_id" to productId, "price" to price, "quantity" to quantity)
    )

    class Purchase(transactionId: String, value: Double, currency: String) : AnalyticsEvent(
        name = "purchase",
        params = mapOf("transaction_id" to transactionId, "value" to value, "currency" to currency)
    )

    // Engagement
    class Search(query: String, resultCount: Int) : AnalyticsEvent(
        name = "search",
        params = mapOf("search_term" to query, "result_count" to resultCount)
    )

    class ShareContent(contentType: String, itemId: String) : AnalyticsEvent(
        name = "share_content",
        params = mapOf("content_type" to contentType, "item_id" to itemId)
    )
}

// Usage
analytics.logEvent(AnalyticsEvent.ViewProduct("sku-123", "electronics"))
```

`add_to_cart`, `purchase`, and `search` are Firebase predefined events — keep their standard parameter names (`value`, `currency`, `transaction_id`, `search_term`) or built-in reports (revenue, e-commerce funnels) will not populate. `view_product` and `share_content` above are custom names; the predefined equivalents are `view_item` and `share` (params `content_type`, `item_id`, `method`). The full e-commerce schema additionally expects an `items` array (`FirebaseAnalytics.Param.ITEMS`, a `Bundle[]` capped at 200 entries).

---

## Android / Firebase Analytics

### Setup and Initialization

```kotlin
class FirebaseAnalyticsProvider(context: Context) : AnalyticsProvider {
    private val firebaseAnalytics = FirebaseAnalytics.getInstance(context)

    override fun logEvent(name: String, params: Map<String, Any>) {
        val bundle = Bundle().apply {
            params.forEach { (key, value) ->
                // Bundle params accept String, Long, Double, Bundle, and Bundle[] (ITEMS) only
                when (value) {
                    is String -> putString(key, value)
                    is Int -> putLong(key, value.toLong())
                    is Long -> putLong(key, value)
                    is Double -> putDouble(key, value)
                    is Boolean -> putLong(key, if (value) 1L else 0L)
                }
            }
        }
        firebaseAnalytics.logEvent(name, bundle)
    }

    override fun setUserProperty(name: String, value: String) {
        firebaseAnalytics.setUserProperty(name, value)
    }

    override fun setUserId(userId: String?) {
        firebaseAnalytics.setUserId(userId)
    }

    override fun logScreenView(screenName: String, screenClass: String?) {
        val bundle = Bundle().apply {
            putString(FirebaseAnalytics.Param.SCREEN_NAME, screenName)
            screenClass?.let { putString(FirebaseAnalytics.Param.SCREEN_CLASS, it) }
        }
        firebaseAnalytics.logEvent(FirebaseAnalytics.Event.SCREEN_VIEW, bundle)
    }
}
```

### Screen Tracking with Lifecycle Observer

```kotlin
// androidx.lifecycle:lifecycle-runtime-compose
@Composable
fun TrackScreen(screenName: String, analytics: AnalyticsManager) {
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        analytics.logScreenView(screenName)
    }
}

// Usage in a screen composable
@Composable
fun ProductListScreen(analytics: AnalyticsManager) {
    TrackScreen("product_list", analytics)
    // Screen content...
}
```

Firebase also collects `screen_view` automatically (per Activity on Android, per UIViewController on iOS), so manual logging double-counts. Disable automatic reporting when you log screens yourself: `<meta-data android:name="google_analytics_automatic_screen_reporting_enabled" android:value="false" />` in `<application>`, and `FirebaseAutomaticScreenReportingEnabled = NO` (Boolean) in `Info.plist`.

---

## iOS Analytics

### Firebase Analytics Provider

```swift
final class FirebaseAnalyticsProvider: AnalyticsProvider {
    func logEvent(_ name: String, parameters: [String: Any]) {
        Analytics.logEvent(name, parameters: parameters)
    }

    func setUserProperty(_ value: String?, forName name: String) {
        Analytics.setUserProperty(value, forName: name)
    }

    func setUserId(_ userId: String?) {
        Analytics.setUserID(userId)
    }

    func logScreenView(screenName: String, screenClass: String?) {
        // Omit screen_class when nil — an empty string is an invalid param value
        var parameters: [String: Any] = [AnalyticsParameterScreenName: screenName]
        if let screenClass { parameters[AnalyticsParameterScreenClass] = screenClass }
        Analytics.logEvent(AnalyticsEventScreenView, parameters: parameters)
    }
}
```

### Screen Tracking with SwiftUI

```swift
struct AnalyticsScreenModifier: ViewModifier {
    let screenName: String
    // Note: on iOS 17+ the standard is an @Observable AnalyticsManager injected via
    // @Environment(AnalyticsManager.self) rather than @EnvironmentObject. See swiftui-observation.
    @EnvironmentObject var analytics: AnalyticsManager

    func body(content: Content) -> some View {
        content.onAppear {
            analytics.logScreenView(screenName: screenName)
        }
    }
}

extension View {
    func trackScreen(_ name: String) -> some View {
        modifier(AnalyticsScreenModifier(screenName: name))
    }
}

// Usage
struct ProductListView: View {
    var body: some View {
        List { /* ... */ }
            .trackScreen("product_list")
    }
}
```

### App Tracking Transparency (ATT)

```swift
import AppTrackingTransparency

func requestTrackingPermission() async -> ATTrackingManager.AuthorizationStatus {
    await ATTrackingManager.requestTrackingAuthorization()
}

// Requires NSUserTrackingUsageDescription in Info.plist.
// Call while the app is in the .active state — iOS silently skips the prompt otherwise.
func onAppBecomeActive() {
    Task {
        let status = await requestTrackingPermission()
        switch status {
        case .authorized:
            analytics.enableFullTracking()
        case .denied, .restricted:
            analytics.enableLimitedTracking()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}
```

---

## Event Naming Conventions

| Pattern | Example | Notes |
|---------|---------|-------|
| `noun_verb` | `product_viewed` | Past tense for completed actions |
| `noun_verb` | `cart_item_added` | Include context noun |
| `feature_action` | `search_performed` | Feature-scoped |
| `screen_action` | `settings_opened` | Screen-scoped |

Firebase limits (an offending value is dropped and replaced with a `firebase_error` param — no exception is thrown):
- Use `snake_case`; names start with a letter, alphanumerics + underscores only
- Max 40 characters per event/parameter name; parameter values max 100 characters
- Max 25 parameters per event; 500 distinctly named events per app instance; 25 user properties per project (property name max 24 chars, value max 36 chars)
- Reserved prefixes `firebase_`, `google_`, `ga_` are rejected; automatically collected event names (`first_open`, `app_remove`, ...) cannot be logged manually

## User Property Design

```kotlin
// Set on login
analytics.setUserProperty("subscription_tier", "premium")
analytics.setUserProperty("account_age_days", "365")
analytics.setUserProperty("preferred_language", "en")
```

Properties should be low-cardinality (not unique per user). Use for segmentation, not identification.

---

## Privacy: Consent Management

```kotlin
class ConsentManager(
    private val prefs: SharedPreferences,
    private val firebaseAnalytics: FirebaseAnalytics
) {
    fun hasAnalyticsConsent(): Boolean = prefs.getBoolean("analytics_consent", false)
    fun hasAdConsent(): Boolean = prefs.getBoolean("ad_consent", false)

    fun updateConsent(analytics: Boolean, ads: Boolean) {
        prefs.edit()
            .putBoolean("analytics_consent", analytics)
            .putBoolean("ad_consent", ads)
            .apply()
        // Consent Mode v2 — all four types; persists across app runs
        firebaseAnalytics.setConsent(
            mapOf(
                FirebaseAnalytics.ConsentType.ANALYTICS_STORAGE to analytics.toStatus(),
                FirebaseAnalytics.ConsentType.AD_STORAGE to ads.toStatus(),
                FirebaseAnalytics.ConsentType.AD_USER_DATA to ads.toStatus(),
                FirebaseAnalytics.ConsentType.AD_PERSONALIZATION to ads.toStatus()
            )
        )
        // Hard kill-switch for all collection when analytics consent is revoked
        firebaseAnalytics.setAnalyticsCollectionEnabled(analytics)
    }

    private fun Boolean.toStatus() =
        if (this) FirebaseAnalytics.ConsentStatus.GRANTED
        else FirebaseAnalytics.ConsentStatus.DENIED
}
```

Set consent defaults to denied before any code runs, in `AndroidManifest.xml`:

```xml
<meta-data android:name="google_analytics_default_allow_analytics_storage" android:value="false" />
<meta-data android:name="google_analytics_default_allow_ad_storage" android:value="false" />
<meta-data android:name="google_analytics_default_allow_ad_user_data" android:value="false" />
<meta-data android:name="google_analytics_default_allow_ad_personalization_signals" android:value="false" />
```

GDPR/CCPA checklist:
- Show consent dialog before any tracking
- Allow granular opt-in/opt-out
- Provide data deletion request mechanism
- Do not track until consent is given
- Log consent timestamps for audit
- Respect platform-level tracking preferences (ATT on iOS)
