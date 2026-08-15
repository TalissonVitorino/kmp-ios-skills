# FormatStyle — deep recipes

Companion depth for `swift-formatstyle`. Load when you need the full
two-way custom style, attributed output, or fintech-specific patterns.

## 1. Two-way custom style (`ParseableFormatStyle` + `ParseStrategy`)

A style that both formats and parses a masked account number. `format` and
`parseStrategy.parse` must be exact inverses on valid input.

```swift
import Foundation

struct MaskedPAN: Codable, Hashable, Sendable {
    var digits: String   // canonical, unformatted
}

// Formatter: FormatStyle producing a grouped, masked string.
struct MaskedPANStyle: ParseableFormatStyle {
    var visible: Int = 4

    func format(_ value: MaskedPAN) -> String {
        let tail = value.digits.suffix(visible)
        return "•••• •••• •••• " + tail
    }

    var parseStrategy: MaskedPANStrategy { MaskedPANStrategy() }
}

// Parser: ParseStrategy turning a display string back into the value.
struct MaskedPANStrategy: ParseStrategy {
    enum ParseError: Error { case noDigits }

    func parse(_ value: String) throws -> MaskedPAN {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { throw ParseError.noDigits }
        return MaskedPAN(digits: digits)
    }
}

extension FormatStyle where Self == MaskedPANStyle {
    static func maskedPAN(visible: Int = 4) -> MaskedPANStyle { .init(visible: visible) }
}

// Usage
let pan = MaskedPAN(digits: "4111111111111234")
let shown = pan.formatted(.maskedPAN())               // "•••• •••• •••• 1234"
let back  = try MaskedPANStyle().parseStrategy.parse(shown)   // MaskedPAN(digits: "1234")  ← only visible tail survives; see note
```

- **Lossy vs. lossless:** the mask hides digits, so parsing a masked string cannot recover them. Only claim `ParseableFormatStyle` when the output truly round-trips (e.g. a non-masking style). If lossy, keep it a plain `FormatStyle`.
- Give the `ParseStrategy` its own typed error and throw on malformed input; callers use `try?`.

## 2. Reusing a stored style

`FormatStyle` values are cheap and `Sendable`, so store the exact style you want
and call `.format` — handy for a formatting layer or a table column.

```swift
struct AmountColumn {
    let style: Decimal.FormatStyle.Currency

    init(currencyCode: String, locale: Locale) {
        style = Decimal.FormatStyle.Currency(code: currencyCode).locale(locale)
    }
    func text(_ amount: Decimal) -> String { style.format(amount) }
}
```

## 3. Attributed output for styled runs

Number and date styles have an `.attributed` variant returning
`AttributedString` whose runs are tagged with `AttributeScopes.FoundationAttributes`
(e.g. `.numberSymbol`, `.numberPart`, `.dateField`). Use it to color the currency
symbol or de-emphasize cents.

```swift
import Foundation

let attr = Decimal(1234.50).formatted(.currency(code: "USD").attributed)
// Iterate runs and restyle, e.g. shrink the fractional part:
var out = attr
for run in out.runs {
    if run.numberPart == .fraction {
        out[run.range].foregroundColor = .secondary
    }
}
// In SwiftUI: Text(AttributedString) — Text(out)
```

- Run attributes live under `run.numberPart`, `run.numberSymbol`, `run.dateField`, `run.measurementValue`, etc.
- Only reach for `.attributed` when you need per-run styling; a plain `String` is cheaper.

## 4. Fintech display patterns

```swift
// Signed transaction amount with accounting-style negatives:
func txnLabel(_ amount: Decimal, code: String) -> String {
    amount.formatted(
        .currency(code: code)
            .sign(strategy: .accounting)             // "$50.00" / "($50.00)"
    )
}
// Force a leading + on positives instead: .sign(strategy: .always())

// Compact balances for tight UI ("$1.2M"):
Decimal(1_250_000).formatted(.currency(code: "USD").notation(.compactName))  // "$1.25M"

// Interest rate from a fraction, exactly 2 dp:
Decimal(0.0725).formatted(.percent.precision(.fractionLength(2)))            // "7.25%"

// FX pair as a locale list:
["USD", "EUR"].formatted(.list(type: .and, width: .narrow))                 // "USD, EUR"
```

- Route all money through the shared `Money`/`Decimal` model (`kmp-money`); this file only formats it.
- Keep a single source of truth for the display locale (environment `\.locale` in SwiftUI) so every amount, date, and percent agrees.

## 5. Parsing user money input safely

```swift
func parseAmount(_ input: String, code: String, locale: Locale) -> Decimal? {
    // Currency-aware parse: tolerates grouping separators & symbol for the locale.
    let style = Decimal.FormatStyle.Currency(code: code).locale(locale)
    return try? Decimal(input, format: style)
}
```

- Prefer parsing under the **same** locale you display in, so a user who sees `1.234,50 €` can type it back.
- Validate the parsed `Decimal` against your currency's scale before constructing `Money` — don't trust the string's fraction count.

## 6. Availability quick-reference

| API | Available |
|---|---|
| `FormatStyle`, `.number`, `.currency`, `.percent`, `.dateTime`, `.relative`, `.measurement`, `.list`, `.name` | iOS 15 / macOS 12 |
| `Duration.UnitsFormatStyle` (`.units`), `Duration.TimeFormatStyle` (`.time`) | iOS 16 / macOS 13 |
| `ByteCountFormatStyle` (`.byteCount`) | iOS 16 / macOS 13 |
| `.attributed` number/date/currency variants | iOS 15 / macOS 12 |

Guard styles that exceed your deployment target with `if #available`, or gate the whole formatting helper.
