# Money formatting & parsing — platform actuals

`Money` holds an exact `com.ionspin.kotlin.bignum.decimal.BigDecimal`. At the platform
boundary convert it to a plain decimal **string** and hand that to the native decimal
type. Never cross the boundary as a `Double`.

Common declarations (`commonMain`):

```kotlin
expect fun formatMoney(money: Money, localeTag: String? = null): String
expect fun parseMoney(input: String, currency: Currency, localeTag: String? = null): Money?
```

## Android (`androidMain`)

```kotlin
import java.math.BigDecimal as JavaBigDecimal
import java.text.DecimalFormat
import java.text.NumberFormat
import java.util.Currency as JavaCurrency
import java.util.Locale

actual fun formatMoney(money: Money, localeTag: String?): String {
    val locale = localeTag?.let { Locale.forLanguageTag(it) } ?: Locale.getDefault()
    val nf = NumberFormat.getCurrencyInstance(locale).apply {
        currency = JavaCurrency.getInstance(money.currency.code)
        // Honor the ISO exponent (JPY=0, BHD=3) rather than the locale default:
        minimumFractionDigits = money.currency.fractionDigits
        maximumFractionDigits = money.currency.fractionDigits
    }
    // toStringExpanded() = plain decimal; safe to hand to java.math.BigDecimal.
    return nf.format(JavaBigDecimal(money.amount.toStringExpanded()))
}

actual fun parseMoney(input: String, currency: Currency, localeTag: String?): Money? {
    val locale = localeTag?.let { Locale.forLanguageTag(it) } ?: Locale.getDefault()
    val df = (NumberFormat.getNumberInstance(locale) as DecimalFormat).apply {
        isParseBigDecimal = true   // returns java.math.BigDecimal, no double round-trip
    }
    val parsed = runCatching { df.parse(input.trim()) as? JavaBigDecimal }.getOrNull() ?: return null
    // Rebuild via string so we go through Money's rounding/normalization:
    return Money.parse(parsed.toPlainString(), currency)
}
```

Notes:
- `isParseBigDecimal = true` is essential — without it `parse` yields a `Double` and reintroduces float error.
- Use the currency's `fractionDigits` for min/max fraction digits so JPY shows no decimals and BHD shows three.

## iOS (`iosMain`, Kotlin/Native)

```kotlin
import platform.Foundation.NSDecimalNumber
import platform.Foundation.NSLocale
import platform.Foundation.NSNumberFormatter
import platform.Foundation.NSNumberFormatterCurrencyStyle
import platform.Foundation.NSNumberFormatterDecimalStyle
import platform.Foundation.currentLocale

actual fun formatMoney(money: Money, localeTag: String?): String {
    val formatter = NSNumberFormatter().apply {
        numberStyle = NSNumberFormatterCurrencyStyle
        currencyCode = money.currency.code
        locale = localeTag?.let { NSLocale(localeIdentifier = it) } ?: NSLocale.currentLocale
        minimumFractionDigits = money.currency.fractionDigits.toULong()
        maximumFractionDigits = money.currency.fractionDigits.toULong()
    }
    // NSDecimalNumber is exact base-10; construct from the plain string.
    val decimal = NSDecimalNumber(string = money.amount.toStringExpanded())
    return formatter.stringFromNumber(decimal) ?: money.amount.toStringExpanded()
}

actual fun parseMoney(input: String, currency: Currency, localeTag: String?): Money? {
    val formatter = NSNumberFormatter().apply {
        numberStyle = NSNumberFormatterDecimalStyle
        generatesDecimalNumbers = true   // numberFromString returns an NSDecimalNumber
        locale = localeTag?.let { NSLocale(localeIdentifier = it) } ?: NSLocale.currentLocale
    }
    val number = formatter.numberFromString(input.trim()) as? NSDecimalNumber ?: return null
    return Money.parse(number.stringValue, currency)
}
```

Notes:
- `generatesDecimalNumbers = true` makes `numberFromString` return an `NSDecimalNumber` (exact), not a double-backed `NSNumber`.
- `NSDecimalNumber.stringValue` is a plain, locale-neutral decimal string — feed it straight back into `Money.parse`.

## Swift side (out of scope for Kotlin)

If SwiftUI formats the value directly, expose the amount as a Swift `Decimal` (or the
plain string) across the KMP boundary and format with `FormatStyle`:

```swift
let text = amount.formatted(.currency(code: money.currency.code))
```

See the **swift-formatstyle** skill for `.currency`, locale handling, and
`ParseableFormatStyle` input. Keep formatting on one side only — don't double-format.
