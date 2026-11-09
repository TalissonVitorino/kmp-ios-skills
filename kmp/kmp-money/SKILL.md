---
name: kmp-money
description: Model and compute money/currency/decimal amounts in Kotlin Multiplatform shared code (commonMain). Covers the never-use-Double rule, minor-units (Long) vs arbitrary-precision decimal (com.ionspin.kotlin:bignum, since java.math.BigDecimal is JVM-only), a Money value type with ISO-4217 currency, banker's rounding, cent-safe allocation, kotlinx.serialization as string/minor-units, and expect/actual currency formatting + locale-aware parsing. Use when introducing prices, balances, totals, or a Money type in KMP. For iOS-side locale formatting use swift-formatstyle; for domain-model serialization patterns use shared-models.
---

# Money in KMP (commonMain)

## Cardinal rule

- **Never use `Double`/`Float` for money.** Binary floating point cannot represent `0.10`; sums drift and rounding is undefined. This applies to storage, arithmetic, serialization, and equality.
- **`java.math.BigDecimal` is JVM-only** — unavailable in `commonMain`. That is *why* KMP needs either integer minor units or a multiplatform bignum.
- Pick one representation and keep it at the boundary:
  - **Minor units (`Long` cents)** — simplest, exact, fast. Good default for a fintech ledger where every currency has a fixed exponent. Watch for overflow on very large aggregates and awkward sub-cent intermediate math (interest, FX).
  - **Arbitrary-precision decimal** — use `com.ionspin.kotlin:bignum` when you need sub-minor-unit precision, FX rates, or percentages. Pure-Kotlin `BigDecimal`, works on Android + iOS + JS/Wasm.

## Dependencies

```kotlin
// shared/build.gradle.kts
plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization") version "2.4.0"
}
sourceSets {
    commonMain.dependencies {
        implementation("com.ionspin.kotlin:bignum:0.3.10")            // multiplatform BigDecimal/BigInteger
        // optional ready-made serializers (BigDecimal/BigInteger):
        // implementation("com.ionspin.kotlin:bignum-serialization-kotlinx:0.3.10")
        implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0")
    }
}
```

## ionspin BigDecimal essentials

```kotlin
import com.ionspin.kotlin.bignum.decimal.BigDecimal
import com.ionspin.kotlin.bignum.decimal.DecimalMode
import com.ionspin.kotlin.bignum.decimal.RoundingMode
import com.ionspin.kotlin.bignum.decimal.toBigDecimal

// Construct from String only (never fromDouble — reintroduces binary error):
val a = BigDecimal.parseString("19.99")
val b = "0.07".toBigDecimal()

// + - * are exact and need no mode.
val sum = a + b            // 20.06

// Division / non-terminating results REQUIRE a DecimalMode or they throw:
val mode = DecimalMode(decimalPrecision = 20, roundingMode = RoundingMode.ROUND_HALF_TO_EVEN, scale = 2)
val share = a.divide(3.toBigDecimal(), mode)   // 6.66

// Round to a fixed number of fraction digits (money):
val rounded = a.roundToDigitPositionAfterDecimalPoint(2, RoundingMode.ROUND_HALF_TO_EVEN)

// toStringExpanded() gives plain decimal ("20.06"); toString() may use E-notation.
```

- **Banker's rounding = `RoundingMode.ROUND_HALF_TO_EVEN`.** Prefer it for financial correctness — it removes the upward bias of half-up over many transactions. Use `ROUND_HALF_AWAY_FROM_ZERO` only when a spec (e.g. tax authority) mandates half-up.
- Equality caveat: like Java, `BigDecimal.equals` is scale-sensitive (`2.0` vs `2.00`). Compare numeric value with `compareTo(...) == 0`, or normalize scale before comparing/storing.
- `RoundingMode.NONE` throws on non-terminating division — never use it for divides.

## Money value type

A `Money` = amount + currency, with arithmetic that refuses to mix currencies.

```kotlin
// commonMain/kotlin/money/Currency.kt
import kotlinx.serialization.Serializable

@Serializable
data class Currency(val code: String, val fractionDigits: Int) {
    init { require(code.length == 3) { "ISO-4217 code must be 3 letters: $code" } }
    companion object {
        // Seed from a real ISO-4217 table; exponents shown for illustration.
        val USD = Currency("USD", 2)
        val EUR = Currency("EUR", 2)
        val JPY = Currency("JPY", 0)   // no minor unit
        val BHD = Currency("BHD", 3)   // 3 decimal places
    }
}
```

```kotlin
// commonMain/kotlin/money/Money.kt
import com.ionspin.kotlin.bignum.decimal.BigDecimal
import com.ionspin.kotlin.bignum.decimal.RoundingMode

class Money private constructor(
    val amount: BigDecimal,     // always normalized to currency.fractionDigits
    val currency: Currency,
) {
    operator fun plus(other: Money) = of(amount + other.sameCurrency(this).amount, currency)
    operator fun minus(other: Money) = of(amount - other.sameCurrency(this).amount, currency)
    operator fun times(factor: BigDecimal) = of(amount * factor, currency)   // e.g. tax/qty; re-rounds
    operator fun unaryMinus() = of(amount * NEG_ONE, currency)

    operator fun compareTo(other: Money): Int =
        amount.compareTo(other.sameCurrency(this).amount)

    fun isNegative() = amount.compareTo(ZERO) < 0
    fun isZero() = amount.compareTo(ZERO) == 0

    /** Smallest-unit integer, e.g. cents. Safe for storage/serialization. */
    fun toMinorUnits(): Long =
        amount.moveDecimalPoint(currency.fractionDigits).longValue(exactRequired = true)

    private fun sameCurrency(other: Money): Money {
        require(currency == other.currency) {
            "Cross-currency operation: ${currency.code} vs ${other.currency.code}"
        }
        return this
    }

    override fun equals(other: Any?) =
        other is Money && currency == other.currency && amount.compareTo(other.amount) == 0
    override fun hashCode() = 31 * currency.hashCode() + amount.toStringExpanded().hashCode()
    override fun toString() = "${amount.toStringExpanded()} ${currency.code}"

    companion object {
        private val ZERO = BigDecimal.fromLong(0)
        private val NEG_ONE = BigDecimal.fromLong(-1)

        fun of(amount: BigDecimal, currency: Currency): Money =
            Money(amount.roundToDigitPositionAfterDecimalPoint(
                currency.fractionDigits.toLong(), RoundingMode.ROUND_HALF_TO_EVEN), currency)

        fun parse(amount: String, currency: Currency): Money =
            of(BigDecimal.parseString(amount), currency)

        fun ofMinorUnits(minor: Long, currency: Currency): Money =
            of(BigDecimal.fromLong(minor).moveDecimalPoint(-currency.fractionDigits), currency)

        fun zero(currency: Currency) = ofMinorUnits(0, currency)
    }
}
```

- Every constructor path routes through `of(...)`, which re-rounds to the currency's scale with banker's rounding — no un-normalized amounts escape.
- `times` re-rounds (needed for tax/percentage/quantity). For splitting a total across N without losing cents, use allocation, not division.

## Allocation (never lose a cent)

Dividing then rounding each part drops or invents cents. Distribute the remainder deterministically (largest-remainder).

```kotlin
// Split evenly into n parts; the first `remainder` parts get one extra minor unit.
fun Money.allocate(n: Int): List<Money> {
    require(n > 0)
    val total = toMinorUnits()
    val base = total / n
    val remainder = (total - base * n).toInt()   // 0..n-1
    return (0 until n).map { i ->
        Money.ofMinorUnits(base + if (i < remainder) 1 else 0, currency)
    }
}

// Split by integer ratios (e.g. 1:1:1 or fees 70:30). Sum always equals the original.
fun Money.allocateByRatios(ratios: List<Int>): List<Money> {
    val total = toMinorUnits()
    val sum = ratios.sum().toLong()
    var allocated = 0L
    val parts = ratios.map { r -> (total * r / sum).also { allocated += it } }
    var remainder = (total - allocated).toInt()
    return parts.mapIndexed { i, p ->
        Money.ofMinorUnits(p + if (i < remainder) 1 else 0, currency)
    }
}
```

Invariant to test: `original.allocate(n).reduce(Money::plus) == original` for all `n`.

## Serialization (kotlinx.serialization)

Serialize as a **string** (or minor-units), **never a JSON number** — a JSON parser may re-read it as a double.

```kotlin
// commonMain/kotlin/money/MoneySerializer.kt
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*

@Serializable
private data class MoneySurrogate(val amount: String, val currency: String)

object MoneySerializer : KSerializer<Money> {
    override val descriptor: SerialDescriptor =
        buildClassSerialDescriptor("Money") {
            element<String>("amount")
            element<String>("currency")
        }

    override fun serialize(encoder: Encoder, value: Money) {
        // amount as plain decimal string; currency as ISO code
        encoder.encodeSerializableValue(
            MoneySurrogate.serializer(),
            MoneySurrogate(value.amount.toStringExpanded(), value.currency.code),
        )
    }

    override fun deserialize(decoder: Decoder): Money {
        val s = decoder.decodeSerializableValue(MoneySurrogate.serializer())
        val currency = CurrencyRegistry.of(s.currency)   // your ISO-4217 lookup
        return Money.parse(s.amount, currency)
    }
}
```

- Apply with `@Serializable(with = MoneySerializer::class) val price: Money`.
- Wire-alternative: emit integer `minorUnits` + `currency` — smaller, unambiguous, but the reader must know each currency's exponent. Pick one convention per API and document it (see `shared-models`).
- The `bignum-serialization-kotlinx` artifact ships serializers for raw `BigDecimal`/`BigInteger` if you serialize those directly.

## Formatting & parsing (expect/actual)

Currency *display* and *input parsing* are locale-specific and live per platform. Keep the numeric value in `Money`; convert to/from a plain string at the boundary — never pass a `Double` across it.

```kotlin
// commonMain
expect fun formatMoney(money: Money, localeTag: String? = null): String
expect fun parseMoney(input: String, currency: Currency, localeTag: String? = null): Money?
```

- **Android** actual: `NumberFormat.getCurrencyInstance(locale)` with `currency = java.util.Currency.getInstance(code)`, feeding `java.math.BigDecimal(money.amount.toStringExpanded())`; parse with `DecimalFormat.isParseBigDecimal = true` to avoid double round-trips.
- **iOS** actual: `NSNumberFormatter` (`NSNumberFormatterCurrencyStyle`) with `NSDecimalNumber(string:)`; parse with `generatesDecimalNumbers = true`.
- Full platform bodies (imports, locale handling, safe parsing) are in `references/platform-formatting.md`.
- On the Swift side prefer `Decimal.formatted(.currency(code:))` (`FormatStyle`) — see the **swift-formatstyle** skill. Kotlin only needs to hand Swift a `Decimal`/string, not format it.

## Testing

- Property-based (kotest-property / jqwik): `allocate(n)` and `allocateByRatios` sum back to the original for random amounts and `n`.
- Rounding edge cases: `2.5 -> 2`, `3.5 -> 4` under HALF_TO_EVEN; negative amounts; zero-exponent (JPY) and 3-exponent (BHD) currencies.
- Cross-currency ops throw; serialize→deserialize is lossless (round-trip equality).
- Assert amounts, never format strings, in logic tests — formatting is locale-dependent and belongs in platform tests.

## Pitfalls

- `BigDecimal.fromDouble(0.1)` reintroduces float error — parse strings instead.
- Comparing with `equals` instead of `compareTo` (scale sensitivity) → false inequality.
- Dividing a total by N and rounding each part → lost/created cents. Use `allocate`.
- Serializing amounts as JSON numbers → silent precision loss downstream.
- Assuming 2 decimal places — JPY has 0, BHD/KWD have 3. Always drive scale from the currency.
