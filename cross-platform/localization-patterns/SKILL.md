---
name: localization-patterns
description: Localization patterns for mobile - string resources, plurals, RTL support, Compose localization, KMP shared strings, and locale management.
---

# Localization Patterns for Mobile

## Android

### strings.xml Resources

```xml
<!-- res/values/strings.xml (default - English) -->
<resources>
    <string name="app_name">MyApp</string>
    <string name="welcome_message">Welcome, %1$s!</string>
    <string name="price_format">%1$s %2$.2f</string>

    <string-array name="categories">
        <item>Electronics</item>
        <item>Clothing</item>
        <item>Books</item>
    </string-array>

    <plurals name="items_count">
        <!-- "zero"/"two" only apply where the language's CLDR rules define
             them (e.g. Arabic). For English, count 0 resolves to "other". -->
        <item quantity="one">%d item</item>
        <item quantity="other">%d items</item>
    </plurals>
</resources>

<!-- res/values-es/strings.xml (Spanish) -->
<resources>
    <string name="app_name">MiApp</string>
    <string name="welcome_message">Bienvenido, %1$s!</string>

    <plurals name="items_count">
        <item quantity="one">%d elemento</item>
        <item quantity="other">%d elementos</item>
    </plurals>
</resources>

<!-- res/values-ar/strings.xml (Arabic - RTL) -->
<resources>
    <string name="welcome_message">%1$s ,مرحبًا</string>

    <plurals name="items_count">
        <item quantity="zero">لا عناصر</item>
        <item quantity="one">عنصر واحد</item>
        <item quantity="two">عنصران</item>
        <item quantity="few">%d عناصر</item>
        <item quantity="many">%d عنصرًا</item>
        <item quantity="other">%d عنصر</item>
    </plurals>
</resources>
```

### String Formatting with Arguments

```kotlin
// Positional arguments: %1$s = first string, %2$d = second integer
// strings.xml: <string name="greeting">Hello %1$s, you have %2$d new messages</string>

val formatted = context.getString(R.string.greeting, userName, messageCount)

// Plurals
val itemsText = context.resources.getQuantityString(
    R.plurals.items_count,
    count,  // quantity selector
    count   // format argument
)
```

### Compose Localization

```kotlin
@Composable
fun WelcomeScreen(userName: String, itemCount: Int) {
    Column {
        Text(text = stringResource(R.string.welcome_message, userName))
        Text(text = pluralStringResource(R.plurals.items_count, itemCount, itemCount))
    }
}
```

### Per-App Language Preference (API 33+)

```xml
<!-- AndroidManifest.xml -->
<application android:localeConfig="@xml/locales_config" ...>

<!-- res/xml/locales_config.xml -->
<?xml version="1.0" encoding="utf-8"?>
<locale-config xmlns:android="http://schemas.android.com/apk/res/android">
    <locale android:name="en" />
    <locale android:name="es" />
    <locale android:name="ar" />
    <locale android:name="ja" />
</locale-config>
```

```kotlin
// Preferred: AppCompat path works on ALL API levels (delegates to the
// framework on 33+). Requires appcompat 1.6.0+; for persistence pre-33 add
// the AppLocalesMetadataHolderService entry with autoStoreLocales=true.
AppCompatDelegate.setApplicationLocales(
    LocaleListCompat.forLanguageTags("es")
)

// Framework API (33+ only)
val localeManager = context.getSystemService(LocaleManager::class.java)
localeManager.applicationLocales = LocaleList(Locale.forLanguageTag("es"))
```

### RTL Layout Support

```xml
<!-- AndroidManifest.xml -->
<application android:supportsRtl="true" ...>

<!-- Use start/end instead of left/right -->
<TextView
    android:layout_marginStart="16dp"
    android:layout_marginEnd="8dp"
    android:paddingStart="12dp"
    android:textAlignment="viewStart" />
```

```kotlin
// Compose RTL
@Composable
fun AdaptiveLayout() {
    Row(
        modifier = Modifier.padding(start = 16.dp, end = 8.dp)
        // start/end automatically flip in RTL
    ) {
        // AutoMirrored icons flip themselves in RTL — no manual check.
        // (Icons.Default.ArrowBack/ArrowForward are deprecated in their favor.)
        Icon(
            imageVector = Icons.AutoMirrored.Filled.ArrowForward,
            contentDescription = null
        )
        Text(text = stringResource(R.string.next))
    }
    // For assets with no AutoMirrored variant:
    // val isRtl = LocalLayoutDirection.current == LayoutDirection.Rtl
}
```

---

## iOS

### Localizable.strings

```
/* Localizable.strings (English) */
"app_name" = "MyApp";
"welcome_message" = "Welcome, %@!";
"price_format" = "%@ %.2f";
"settings_title" = "Settings";
```

```
/* Localizable.strings (Spanish) */
"app_name" = "MiApp";
"welcome_message" = "Bienvenido, %@!";
"settings_title" = "Configuración";
```

### String Catalogs (.xcstrings - Xcode 15+)

String Catalogs (`.xcstrings`) are the standard format: a single JSON file replacing `.strings` and `.stringsdict`. Xcode auto-extracts localizable strings from code at build time and handles plurals natively ("Vary by Plural" on a string). Xcode migrates legacy files via Editor > Migrate to String Catalog. Prefer this for new code; `.strings`/`.stringsdict` below remain valid for existing projects.

### String(localized:) and NSLocalizedString

```swift
// Modern (iOS 15+)
let welcome = String(localized: "welcome_message")

// With arguments
let greeting = String(localized: "Welcome, \(userName)!")

// Legacy
let title = NSLocalizedString("settings_title", comment: "Title for settings screen")
```

### SwiftUI Text with LocalizedStringKey

```swift
struct WelcomeView: View {
    let userName: String

    var body: some View {
        VStack {
            // Automatically uses Localizable.strings
            Text("settings_title")

            // With interpolation
            Text("Welcome, \(userName)!")

            // Explicit localized key
            Text(LocalizedStringKey("welcome_message"))
        }
    }
}
```

### Plural Rules with .stringsdict

```xml
<!-- Localizable.stringsdict -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<dict>
    <key>items_count</key>
    <dict>
        <key>NSStringLocalizedFormatKey</key>
        <string>%#@count@</string>
        <key>count</key>
        <dict>
            <key>NSStringFormatSpecTypeKey</key>
            <string>NSStringPluralRuleType</string>
            <key>NSStringFormatValueTypeKey</key>
            <string>d</string>
            <key>zero</key>
            <string>No items</string>
            <key>one</key>
            <string>%d item</string>
            <key>other</key>
            <string>%d items</string>
        </dict>
    </dict>
</dict>
</plist>
```

```swift
let text = String(format: NSLocalizedString("items_count", comment: ""), itemCount)
```

### RTL Support in SwiftUI

```swift
struct AdaptiveRow: View {
    var body: some View {
        HStack {
            // leading/trailing automatically respect RTL
            Text("Label")
            Spacer()
            // Use direction-aware SF Symbols (.forward/.backward) —
            // they flip automatically in RTL. chevron.right does not.
            Image(systemName: "chevron.forward")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        // For custom assets: read @Environment(\.layoutDirection)
        // or use .flipsForRightToLeftLayoutDirection(true)
    }
}
```

---

## KMP Shared Strings

### Common Interface with expect/actual

```kotlin
// commonMain. expect/actual *classes* are still Beta: the compiler warns unless
// -Xexpect-actual-classes is set (a plain interface + platform impls avoids it).
// No constructor is declared, so common code cannot call StringProvider() —
// K2 rejects it with "does not have default constructor". Inject it instead.
expect class StringProvider {
    fun getString(key: String): String
    fun getString(key: String, vararg args: Any): String
    fun getPluralString(key: String, quantity: Int, vararg args: Any): String
}

// androidMain
actual class StringProvider(private val context: Context) {
    actual fun getString(key: String): String {
        val resId = context.resources.getIdentifier(key, "string", context.packageName)
        return if (resId != 0) context.getString(resId) else key
    }

    actual fun getString(key: String, vararg args: Any): String {
        val resId = context.resources.getIdentifier(key, "string", context.packageName)
        return if (resId != 0) context.getString(resId, *args) else key
    }

    actual fun getPluralString(key: String, quantity: Int, vararg args: Any): String {
        val resId = context.resources.getIdentifier(key, "plurals", context.packageName)
        return if (resId != 0) context.resources.getQuantityString(resId, quantity, *args) else key
    }
}

// iosMain — String.format is JVM-only; it does not exist in Kotlin/Native.
// Use NSString.stringWithFormat. Caveat: Kotlin cannot spread an array into
// an ObjC variadic (KT-42925), so dispatch on arity. iOS templates use
// ObjC specifiers (%@, %d) — not Java's %1$s. This specifier mismatch is
// the main reason to prefer moko-resources, which formats in commonMain.
import platform.Foundation.NSBundle
import platform.Foundation.NSString
import platform.Foundation.stringWithFormat

actual class StringProvider {
    actual fun getString(key: String): String {
        return NSBundle.mainBundle.localizedStringForKey(key, value = key, table = null)
    }

    actual fun getString(key: String, vararg args: Any): String {
        val template = getString(key)
        return when (args.size) {
            0 -> template
            1 -> NSString.stringWithFormat(template, args[0])
            2 -> NSString.stringWithFormat(template, args[0], args[1])
            3 -> NSString.stringWithFormat(template, args[0], args[1], args[2])
            else -> error("Unsupported arg count ${args.size}")
        }
    }

    actual fun getPluralString(key: String, quantity: Int, vararg args: Any): String {
        // Plural selection happens inside stringWithFormat when the key
        // resolves through a .stringsdict / String Catalog plural rule.
        return getString(key, quantity, *args)
    }
}
```

### moko-resources Library Pattern

```kotlin
// build.gradle.kts — or prefer Compose Multiplatform resources (see compose-resources)
plugins {
    id("dev.icerock.mobile.multiplatform-resources") version "0.26.4"
}

kotlin.sourceSets.commonMain.dependencies {
    api("dev.icerock.moko:resources:0.26.4") // api, so the iOS framework exports MR
}

multiplatformResources {
    resourcesPackage.set("com.example.shared") // required
}

// Since 0.24: src/commonMain/moko-resources/base/strings.xml (default locale)
//             src/commonMain/moko-resources/es/strings.xml
// (older versions used commonMain/resources/MR/)
// Access from commonMain via StringDesc (no direct getString() in common code):
//   MR.strings.welcome_message.desc()          -> StringDesc
//   MR.strings.welcome_message.format(name)    -> formatted StringDesc
//   MR.plurals.items_count.format(count, count) -> plural StringDesc
// Resolve per platform: stringDesc.toString(context) on Android, .localized() on iOS.
```

---

## Testing

### Pseudo-Localization

Android: pseudo-locales are AAPT-generated (never hand-author `values-en-rXA`). Enable per build type, then pick `English (XA)` (accented, ~30% longer) or `Arabic (XB)` (RTL) in Settings > System > Languages:

```kotlin
// build.gradle.kts
android {
    buildTypes {
        getByName("debug") { isPseudoLocalesEnabled = true }
    }
}
```

```bash
# Switch emulator system locale (emulator/userdebug builds only)
adb shell "setprop persist.sys.locale ar-SA; stop; sleep 2; start"
```

iOS: Edit Scheme > Run > Options > App Language — "Double-Length Pseudolanguage" (expansion) or "Right-to-Left Pseudolanguage" (RTL).

### Layout Testing with Long Strings

German and Finnish text runs typically 30-40% longer than English — test with pseudo-locales or a forced locale.

```kotlin
// Compose UI test with a forced locale. Override LocalContext with a
// locale-scoped context — providing LocalConfiguration alone does NOT
// re-resolve string resources.
@Test
fun longGermanStringsDoNotOverflow() {
    composeTestRule.setContent {
        val base = LocalContext.current
        val config = Configuration(base.resources.configuration)
            .apply { setLocale(Locale.GERMAN) }
        CompositionLocalProvider(
            LocalContext provides base.createConfigurationContext(config),
            LocalConfiguration provides config
        ) {
            WelcomeScreen(userName = "Maximilian Schwarzenegger", itemCount = 5)
        }
    }
    // Verify no text truncation or overflow
}
```
