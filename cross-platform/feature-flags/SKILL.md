---
name: feature-flags
description: Feature flag patterns - LaunchDarkly, Firebase Remote Config, local feature flags, A/B testing, gradual rollouts, and KMP shared flag evaluation.
---

# Feature Flag Patterns

## Architecture

### FeatureFlagProvider Interface (Kotlin)

```kotlin
interface FeatureFlagProvider {
    fun getBooleanFlag(key: String, default: Boolean = false): Boolean
    fun getStringFlag(key: String, default: String = ""): String
    fun getIntFlag(key: String, default: Int = 0): Int
    fun getDoubleFlag(key: String, default: Double = 0.0): Double
    suspend fun refresh()
}
```

### Type-Safe Flag Definitions

```kotlin
sealed class FeatureFlag<T>(
    val key: String,
    val defaultValue: T
) {
    // Boolean flags
    object NewOnboarding : FeatureFlag<Boolean>("new_onboarding_v2", false)
    object DarkModeEnabled : FeatureFlag<Boolean>("dark_mode_enabled", true)
    object ChatFeature : FeatureFlag<Boolean>("chat_feature", false)

    // String flags
    object CheckoutButtonText : FeatureFlag<String>("checkout_button_text", "Buy Now")
    object HomeLayoutVariant : FeatureFlag<String>("home_layout_variant", "control")

    // Numeric flags
    object MaxCartItems : FeatureFlag<Int>("max_cart_items", 50)
    object SearchDebounceMs : FeatureFlag<Int>("search_debounce_ms", 300)
}

// Type-safe evaluation
class FeatureFlagManager(private val provider: FeatureFlagProvider) {
    fun isEnabled(flag: FeatureFlag<Boolean>): Boolean {
        return provider.getBooleanFlag(flag.key, flag.defaultValue)
    }

    fun getString(flag: FeatureFlag<String>): String {
        return provider.getStringFlag(flag.key, flag.defaultValue)
    }

    fun getInt(flag: FeatureFlag<Int>): Int {
        return provider.getIntFlag(flag.key, flag.defaultValue)
    }
}
```

---

## Firebase Remote Config

### Setup and Initialization

Dependency: `com.google.firebase:firebase-config` via the Firebase BoM (34.18.0 → firebase-config 23.1.0). KTX APIs moved into the main module in BoM 32.5.0 and the `-ktx` artifacts were removed in BoM 34.0.0 — depend on `firebase-config`, never `firebase-config-ktx`.

```kotlin
class FirebaseFeatureFlagProvider : FeatureFlagProvider {
    private val remoteConfig = Firebase.remoteConfig.apply {
        val configSettings = remoteConfigSettings {
            minimumFetchIntervalInSeconds = if (BuildConfig.DEBUG) 0 else 3600
        }
        setConfigSettingsAsync(configSettings)
        setDefaultsAsync(R.xml.remote_config_defaults)
    }

    // getBoolean/getDouble have no per-call default — a key absent from the
    // XML defaults returns false/0.0. Register every flag in the defaults XML.
    override fun getBooleanFlag(key: String, default: Boolean): Boolean {
        return remoteConfig.getBoolean(key)
    }

    override fun getStringFlag(key: String, default: String): String {
        return remoteConfig.getString(key).ifEmpty { default }
    }

    override fun getIntFlag(key: String, default: Int): Int {
        return remoteConfig.getLong(key).toInt()
    }

    override fun getDoubleFlag(key: String, default: Double): Double {
        return remoteConfig.getDouble(key)
    }

    override suspend fun refresh() {
        remoteConfig.fetchAndActivate().await()
    }
}
```

For server-pushed updates without polling, use the real-time listener (firebase-config 21.3.0+):

```kotlin
remoteConfig.addOnConfigUpdateListener(object : ConfigUpdateListener {
    override fun onUpdate(configUpdate: ConfigUpdate) {
        remoteConfig.activate() // configUpdate.updatedKeys lists changed flags
    }
    override fun onError(error: FirebaseRemoteConfigException) { /* log */ }
})
```

### Default Values (res/xml/remote_config_defaults.xml)

```xml
<?xml version="1.0" encoding="utf-8"?>
<defaultsMap>
    <entry>
        <key>new_onboarding_v2</key>
        <value>false</value>
    </entry>
    <entry>
        <key>dark_mode_enabled</key>
        <value>true</value>
    </entry>
    <entry>
        <key>checkout_button_text</key>
        <value>Buy Now</value>
    </entry>
</defaultsMap>
```

### iOS Firebase Remote Config

```swift
final class FirebaseFeatureFlagProvider: FeatureFlagProvider {
    private let remoteConfig = RemoteConfig.remoteConfig()

    init() {
        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = 3600
        #endif
        remoteConfig.configSettings = settings
        remoteConfig.setDefaults(fromPlist: "RemoteConfigDefaults")
    }

    func getBooleanFlag(key: String, defaultValue: Bool) -> Bool {
        remoteConfig.configValue(forKey: key).boolValue
    }

    func getStringFlag(key: String, defaultValue: String) -> String {
        // stringValue is non-optional since Firebase Apple SDK 11
        let value = remoteConfig.configValue(forKey: key).stringValue
        return value.isEmpty ? defaultValue : value
    }

    func refresh() async throws {
        _ = try await remoteConfig.fetchAndActivate()
    }
}
```

---

## LaunchDarkly

### Android SDK Initialization

Dependency: `com.launchdarkly:launchdarkly-android-client-sdk` 5.x (5.14.x current; SDK 5.x uses `LDContext`, the 4.x `LDUser` API is gone).

```kotlin
// LDClient.init requires the Application, not a Context, and blocks up to
// startWaitSeconds — call it once from Application.onCreate, off the hot path.
class LaunchDarklyProvider(application: Application) : FeatureFlagProvider {
    private val client: LDClient

    init {
        val ldConfig = LDConfig.Builder(LDConfig.Builder.AutoEnvAttributes.Enabled)
            .mobileKey("mob-your-mobile-key")
            .build()
        val ldContext = LDContext.builder(ContextKind.DEFAULT, "user-id-123")
            .set("email", "user@example.com")
            .set("plan", "premium")
            .build()
        client = LDClient.init(application, ldConfig, ldContext, 5)
    }

    override fun getBooleanFlag(key: String, default: Boolean): Boolean {
        return client.boolVariation(key, default)
    }

    override fun getStringFlag(key: String, default: String): String {
        return client.stringVariation(key, default)
    }

    override fun getIntFlag(key: String, default: Int): Int {
        return client.intVariation(key, default)
    }

    override fun getDoubleFlag(key: String, default: Double): Double {
        return client.doubleVariation(key, default)
    }

    override suspend fun refresh() {
        // LaunchDarkly uses streaming by default, manual refresh not needed
    }

    fun registerFlagChangeListener(key: String, listener: (Boolean) -> Unit) {
        client.registerFeatureFlagListener(key) { flagKey ->
            listener(client.boolVariation(flagKey, false))
        }
    }
}
```

---

## Local Feature Flags

### BuildConfig-Based Flags

```kotlin
// build.gradle.kts
android {
    buildFeatures { buildConfig = true } // off by default since AGP 8
    buildTypes {
        debug {
            buildConfigField("boolean", "ENABLE_DEV_TOOLS", "true")
            buildConfigField("boolean", "MOCK_API", "true")
        }
        release {
            buildConfigField("boolean", "ENABLE_DEV_TOOLS", "false")
            buildConfigField("boolean", "MOCK_API", "false")
        }
    }
}

// Usage
if (BuildConfig.ENABLE_DEV_TOOLS) {
    showDevMenu()
}
```

### Debug Menu Toggle

Layer debug overrides over a real provider. Interface delegation (`by delegate`) supplies
the members you do not override — a class that declares `: FeatureFlagProvider` and
implements only `getBooleanFlag` does not compile.

```kotlin
class LocalFeatureFlagProvider(
    private val prefs: SharedPreferences,
    private val delegate: FeatureFlagProvider
) : FeatureFlagProvider by delegate {

    override fun getBooleanFlag(key: String, default: Boolean): Boolean =
        if (prefs.contains("flag_$key")) prefs.getBoolean("flag_$key", default)
        else delegate.getBooleanFlag(key, default)

    fun overrideFlag(key: String, value: Boolean) {
        prefs.edit().putBoolean("flag_$key", value).apply()
    }

    // edit().clear() would wipe every preference in the file, not just the overrides
    fun clearOverrides() {
        val editor = prefs.edit()
        prefs.all.keys.filter { it.startsWith("flag_") }.forEach(editor::remove)
        editor.apply()
    }
}
```

---

## KMP Shared Flags

Use GitLive's Firebase Kotlin SDK (`dev.gitlive:firebase-config:2.6.0` in commonMain) — one implementation for both platforms, no expect/actual. It wraps the native Android and iOS Remote Config SDKs.

```kotlin
// commonMain
import dev.gitlive.firebase.Firebase
import dev.gitlive.firebase.remoteconfig.remoteConfig
import kotlin.time.Duration.Companion.hours

class SharedFeatureFlags {
    private val remoteConfig = Firebase.remoteConfig

    suspend fun init() {
        remoteConfig.settings { minimumFetchInterval = 1.hours }
        remoteConfig.setDefaults("new_onboarding_v2" to false, "checkout_button_text" to "Buy Now")
        remoteConfig.fetchAndActivate()
    }

    fun isEnabled(key: String): Boolean = remoteConfig.getValue(key).asBoolean()
    fun getString(key: String): String = remoteConfig.getValue(key).asString()
    fun getLong(key: String): Long = remoteConfig.getValue(key).asLong()
}
```

If you write the iosMain side against the native SDK instead (via CocoaPods cinterop), the class is exposed as `FIRRemoteConfig` — not `RemoteConfig` — and `stringValue` is non-optional.

---

## Gradual Rollout Pattern

Prefer server-side percentage conditions (Firebase "random percentile", LaunchDarkly percentage rollouts) — they bucket consistently across platforms and let you dial rollouts without a release. Client-side bucketing is a fallback for locally-defined flags:

```kotlin
class GradualRollout(private val userId: String) {
    fun isInRollout(flagKey: String, percentage: Int): Boolean {
        // toLong() before absoluteValue: Int.MIN_VALUE.absoluteValue overflows
        val hash = "$flagKey-$userId".hashCode().toLong().absoluteValue
        return (hash % 100) < percentage
    }
}

// Server-side targeting in Firebase Remote Config:
// Condition: "10% of users" -> random percentile <= 10
// Condition: "Premium users" -> user property "tier" == "premium"
```

## A/B Testing: Variant Assignment

```kotlin
data class Experiment(
    val name: String,
    val variant: String // "control", "variant_a", "variant_b"
)

fun getExperimentVariant(flagManager: FeatureFlagManager): Experiment {
    val variant = flagManager.getString(FeatureFlag.HomeLayoutVariant)
    analytics.logEvent("experiment_assigned", mapOf(
        "experiment_name" to "home_layout",
        "variant" to variant
    ))
    return Experiment("home_layout", variant)
}
```
