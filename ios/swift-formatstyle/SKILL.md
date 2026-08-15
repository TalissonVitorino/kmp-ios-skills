---
name: swift-formatstyle
description: "Locale-aware value formatting and parsing on iOS/macOS with Foundation's FormatStyle / ParseableFormatStyle protocols — the modern replacement for NumberFormatter / DateFormatter / DateComponentsFormatter subclasses. Covers number styles (IntegerFormatStyle / FloatingPointFormatStyle via .number with .precision / .grouping / .rounded / .sign), Decimal.FormatStyle.Currency (.currency(code:)) and .percent, Date.FormatStyle (.dateTime with .year()/.month()/.day()) and Date.RelativeFormatStyle (.relative), Duration (.units / .time), Measurement.FormatStyle, ListFormatStyle (.list(type:)), ByteCountFormatStyle, PersonNameComponents.FormatStyle, custom FormatStyle / ParseableFormatStyle conformance, parseStrategy, .locale(_:) injection, and SwiftUI Text(_:format:). Use when displaying or parsing money, dates, durations, units, percentages, or lists on the iOS side. For the shared KMP money model and rounding rules use kmp-money; for i18n/RTL strategy use localization-patterns; for chart axis/value labels use swift-charts."
---

# Swift FormatStyle (iOS / macOS)

Locale-aware, value-to-string formatting (and string-to-value parsing) built on
Foundation's `FormatStyle` protocol. This is the modern, type-safe replacement
for `NumberFormatter`, `DateFormatter`, `DateComponentsFormatter`, and friends —
prefer it for all new code.

- **Baseline availability:** `FormatStyle`, number/date/list/measurement/person-name styles are **iOS 15+**. `Duration` styles (`.units` / `.time`) and the `FormatStyle`-based `ByteCountFormatStyle` (`.byteCount`) are **iOS 16+**.
- **KMP boundary:** keep the numeric value (a `Decimal`, `Date`, or `Money`) in shared code; format only at the iOS presentation layer. Never hand a `Double` across the boundary for money — see `kmp-money`.
- **Two entry points**, equivalent:
  - `value.formatted(style)` — call on the value.
  - `style.format(value)` — call on the style (useful when the style is stored/reused).

## Contents

- [Core protocol & the `.formatted` entry points](#core)
- [Numbers — integer & floating-point](#numbers)
- [Currency](#currency)
- [Percent](#percent)
- [Dates & times](#dates)
- [Relative dates](#relative)
- [Duration](#duration)
- [Measurement](#measurement)
- [Lists](#lists)
- [Byte counts](#bytecount)
- [Person names](#names)
- [Locale injection](#locale)
- [Parsing (ParseableFormatStyle / parseStrategy)](#parsing)
- [SwiftUI `Text(_:format:)`](#swiftui)
- [Custom FormatStyle](#custom)
- [Replacing legacy `Formatter` subclasses](#legacy)
- [Correctness checklist](#checklist)
- Depth: `references/recipes.md`

<a id="core"></a>
## Core protocol & the `.formatted` entry points

A `FormatStyle` maps `FormatInput → FormatOutput` (usually `String`) via
`format(_:)`, and applies locale conventions automatically. Every built-in style
is a value type you build with dot-chained modifiers.

```swift
import Foundation

let n = 1234.5
n.formatted()                                   // "1,234.5"  (current locale)
n.formatted(.number.precision(.fractionLength(2)))   // "1,234.50"
(0.75).formatted(.percent)                      // "75%"
Date.now.formatted(.dateTime.year().month().day())   // "Aug 3, 2026" (en_US)
```

- Bare `.formatted()` on `Int`/`Double`/`Decimal`/`Date` uses a sensible default style for that type.
- Styles are **immutable and composable**; each modifier returns a new style. Build once, reuse.

<a id="numbers"></a>
## Numbers — integer & floating-point

`.number` resolves to `IntegerFormatStyle` for integer types and
`FloatingPointFormatStyle` for `Double`/`Float`/`Decimal`.

```swift
(1234567).formatted(.number)                    // "1,234,567"
(1234567).formatted(.number.grouping(.never))   // "1234567"

// Precision — fraction length, significant digits, integer length:
(3.14159).formatted(.number.precision(.fractionLength(2)))       // "3.14"
(3.14159).formatted(.number.precision(.fractionLength(0...2)))   // "3.14"  (up to 2)
(3.1).formatted(.number.precision(.fractionLength(2...2)))       // "3.10"  (exactly 2)
(1234.5).formatted(.number.precision(.significantDigits(3)))     // "1,230"
(7).formatted(.number.precision(.integerLength(3)))              // "007"

// Rounding (rule + optional increment) — a bare rule only rounds at the
// displayed precision, so pin the precision (or pass an increment) to see it:
(2.5).formatted(.number.precision(.fractionLength(0)).rounded(rule: .toNearestOrEven))  // "2"  (banker's; default rule gives "3")
(2.567).formatted(.number.rounded(rule: .up, increment: 0.05))   // "2.6"

// Sign display and notation:
(42).formatted(.number.sign(strategy: .always()))               // "+42"
(1_200_000).formatted(.number.notation(.scientific))            // "1.2E6"
(1_200_000).formatted(.number.notation(.compactName))          // "1.2M"
```

- `.precision` strategies: `.fractionLength(Int | Range)`, `.significantDigits(Int | Range)`, `.integerLength(Int | Range)`, `.integerAndFractionLength(...)`.
- `.grouping(.automatic | .never)`; `.decimalSeparator(strategy: .always | .automatic)`.
- For **money**, use `.currency`, not `.number` — it drives fraction digits and symbol from the currency, not the locale's default.

<a id="currency"></a>
## Currency

`.currency(code:)` takes an **ISO-4217** code and produces
`Decimal.FormatStyle.Currency` (or the `Double`/`Int` variant). The fraction
digits come from the currency (USD → 2, JPY → 0, BHD → 3), and the symbol +
placement come from the locale.

```swift
let price = Decimal(1234.5)
price.formatted(.currency(code: "USD"))                     // "$1,234.50"  (en_US)
price.formatted(.currency(code: "EUR").locale(Locale(identifier: "de_DE")))  // "1.234,50 €"
Decimal(1000).formatted(.currency(code: "JPY"))             // "¥1,000"     (0 fraction digits)

// Accounting/parentheses for negatives, and symbol presentation:
(-50).formatted(.currency(code: "USD").sign(strategy: .accounting))   // "($50.00)"
price.formatted(.currency(code: "USD").presentation(.isoCode))        // "USD 1,234.50"
price.formatted(.currency(code: "USD").presentation(.fullName))       // "1,234.50 US dollars"
```

- Prefer `Decimal` (or an integer minor-unit value) as the input — **never `Double`** for money. See `kmp-money` for why and for the shared model.
- Do **not** hardcode the symbol or fraction digits; the currency code + locale decide them.
- `.currency` on an `Int` treats the value as **major units** (e.g. `1234 → $1,234.00`), not cents. Convert minor units to a `Decimal` first if you store cents.

<a id="percent"></a>
## Percent

`.percent` **multiplies by 100** and appends the locale's percent sign.

```swift
(0.075).formatted(.percent)                                  // "7.5%"
(0.075).formatted(.percent.precision(.fractionLength(1)))    // "7.5%"
(7).formatted(.percent.scale(1))                             // "7%"  (input already ×100)
```

- Input is a **fraction**: `0.07` → `"7%"` (the style multiplies by 100 by default). If your value is already `7` (a "7 percent" number), disable the multiplier with `.percent.scale(1)`.
- `Decimal.FormatStyle.Percent` for `Decimal` inputs — preferred for exact rates.

<a id="dates"></a>
## Dates & times

`.dateTime` is `Date.FormatStyle`; add field modifiers to opt fields in. Order of
modifiers does **not** matter — the locale controls field ordering.

```swift
let d = Date.now
d.formatted(.dateTime.year().month().day())                  // "Aug 3, 2026"
d.formatted(.dateTime.month(.wide).day().year())             // "August 3, 2026"
d.formatted(.dateTime.hour().minute())                       // "2:30 PM"
d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))  // "Mon, Aug 3"
d.formatted(.dateTime.hour().minute().second().timeZone())   // "2:30:15 PM GMT"

// Compact presets (locale-driven), instead of hand-picking fields:
d.formatted(date: .abbreviated, time: .shortened)           // "Aug 3, 2026 at 2:30 PM"
d.formatted(date: .long, time: .omitted)                    // "August 3, 2026"

// ISO-8601 (fixed, locale-independent) — for wire formats, never for UI:
d.formatted(.iso8601)                                        // "2026-08-03T14:30:15Z"
```

- Field-width enums: `.month(.wide | .abbreviated | .narrow | .defaultDigits | .twoDigits)`, `.day(.defaultDigits | .twoDigits | .ordinalOfDayInMonth)`, `.year(.defaultDigits | .twoDigits | .padded(_:))`, `.weekday(.wide | .abbreviated | .narrow)`, `.hour(.defaultDigits(amPM:) ...)`.
- For a **fixed machine format**, use `.iso8601` or `Date.ISO8601FormatStyle` — not `.dateTime`, which is locale-variable by design.
- `.dateTime` conforms to `ParseableFormatStyle` → it round-trips (see [Parsing](#parsing)).

<a id="relative"></a>
## Relative dates

`Date.RelativeFormatStyle` renders "2 days ago" / "in 3 hours" relative to a
reference date (default: now).

```swift
let earlier = Date.now.addingTimeInterval(-3600)
earlier.formatted(.relative(presentation: .named))          // "1 hour ago"  (or "yesterday" etc.)
earlier.formatted(.relative(presentation: .numeric))        // "1 hour ago"

// Explicit style + reference date:
let style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide)
style.format(earlier)                                        // "1 hour ago"
```

- `.named` prefers words like "yesterday"/"tomorrow" when available; `.numeric` always uses "N units ago/in N units".
- `unitsStyle`: `.wide` ("1 hour ago"), `.abbreviated`, `.narrow`, `.spellOut`.
- Relative strings are **not stable** — the value drifts with wall-clock time. For a live-updating label in SwiftUI use `Text(_:style:)` (`.relative` / `.timer`) instead, which re-renders itself.

<a id="duration"></a>
## Duration (iOS 16+)

`Duration` (Swift standard library; its format styles live in Foundation) has two format styles.

```swift
let dur: Duration = .seconds(3_725)   // 1h 2m 5s

// .time — clock style, from a pattern:
dur.formatted(.time(pattern: .hourMinuteSecond))            // "1:02:05"
dur.formatted(.time(pattern: .minuteSecond))                // "62:05"
dur.formatted(.time(pattern: .hourMinute(padHourToLength: 2)))  // "01:02"

// .units — natural-language units:
dur.formatted(.units(allowed: [.hours, .minutes], width: .wide))       // "1 hour, 2 minutes"
dur.formatted(.units(allowed: [.hours, .minutes, .seconds],
                     width: .abbreviated))                              // "1 hr, 2 min, 5 sec"
dur.formatted(.units(allowed: [.hours, .minutes], width: .narrow,
                     maximumUnitCount: 1))                              // "1h"
```

- `.time` pattern factories: `.hourMinute`, `.hourMinuteSecond`, `.minuteSecond` — each takes padding / `fractionalSecondsLength` / rounding / grouping options.
- `.units(allowed:width:maximumUnitCount:fractionalPart:zeroValueUnits:...)`; `width` ∈ `.wide | .abbreviated | .narrow | .condensedAbbreviated`.
- `Duration` is the modern replacement for `TimeInterval`-based `DateComponentsFormatter`. It represents a **length of time**, not a point — for "2 days ago" use `.relative` instead.

<a id="measurement"></a>
## Measurement

`Measurement<Unit>.FormatStyle` formats a quantity + unit, honoring the locale's
measurement system (metric vs. US) and can auto-convert via `usage`.

```swift
import Foundation

let dist = Measurement(value: 5, unit: UnitLength.kilometers)
dist.formatted()                                            // "5 km"  (or "3.1 mi" in en_US w/ usage)
dist.formatted(.measurement(width: .wide))                  // "5 kilometers"
dist.formatted(.measurement(width: .abbreviated,
                            usage: .road))                  // "3.1 mi" (en_US) — auto system + rounding

let mass = Measurement(value: 72.5, unit: UnitMass.kilograms)
mass.formatted(.measurement(width: .abbreviated, usage: .personWeight))  // "160 lb" (en_US)
```

- `usage` (`MeasurementFormatUnitUsage`) lets the system pick the natural unit for the locale (`.road`, `.person`, `.personWeight`, `.rainfall`, `.asProvided` to keep your unit).
- `numberFormatStyle:` parameter customizes the numeric part, e.g. `.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1)))`.

<a id="lists"></a>
## Lists

`ListFormatStyle` joins a collection into a grammatical list with locale-correct
conjunctions and separators.

```swift
["USD", "EUR", "GBP"].formatted(.list(type: .and))          // "USD, EUR, and GBP"
["USD", "EUR", "GBP"].formatted(.list(type: .or))           // "USD, EUR, or GBP"
["USD", "EUR"].formatted(.list(type: .and, width: .short))  // "USD & EUR"

// Format each element with an inner style:
[1999, 2599].formatted(.list(memberStyle: .currency(code: "USD"), type: .and))
                                                            // "$1,999.00 and $2,599.00"
```

- `type`: `.and`, `.or`, `.unit` (plain enumeration, no conjunction).
- `width`: `.standard`, `.short`, `.narrow`.

<a id="bytecount"></a>
## Byte counts (iOS 16+)

`ByteCountFormatStyle` via `.byteCount(style:)` — the modern replacement for
`ByteCountFormatter`.

```swift
(1_500_000).formatted(.byteCount(style: .file))             // "1.5 MB"
(1_500_000).formatted(.byteCount(style: .memory))           // "1.4 MB" (binary/1024)
(1_500_000).formatted(.byteCount(style: .file, allowedUnits: .gb))   // "0.0015 GB"
```

- `style`: `.file` (decimal, SI), `.memory` (binary, 1024-based), `.decimal`, `.binary`.
- Input is a byte count as an integer type (e.g. `Int64`).

<a id="names"></a>
## Person names

`PersonNameComponents.FormatStyle` renders a name honoring locale ordering
(given/family order varies by culture).

```swift
var name = PersonNameComponents()
name.givenName = "Ada"
name.familyName = "Lovelace"

name.formatted(.name(style: .long))                         // "Ada Lovelace"
name.formatted(.name(style: .short))                        // "Ada"
name.formatted(.name(style: .abbreviated))                  // "AL"  (initials/monogram)
```

- `style`: `.short`, `.medium`, `.long`, `.abbreviated`.
- Never string-concatenate `given + " " + family` — order and spacing are locale-specific; this style handles it.

<a id="locale"></a>
## Locale injection

Every built-in style has a `.locale(_:)` modifier. The style otherwise resolves
against `Locale.current` **at format time**.

```swift
let de = Locale(identifier: "de_DE")
(1234.5).formatted(.number.locale(de))                      // "1.234,5"
Decimal(9.99).formatted(.currency(code: "EUR").locale(de))  // "9,99 €"
Date.now.formatted(.dateTime.year().month().day().locale(de))  // "3. Aug. 2026"
```

- Inject an explicit locale in **tests** and in server/export code so output doesn't depend on device settings.
- In SwiftUI, `Text(_:format:)` picks up the environment `\.locale` automatically — prefer that over hardcoding for UI.

<a id="parsing"></a>
## Parsing (ParseableFormatStyle / parseStrategy)

Styles that conform to `ParseableFormatStyle` expose a `.parseStrategy` and can
initialize a value **from** a string — the inverse of formatting.

```swift
// Currency round-trip:
let money = try Decimal("$1,234.50", format: .currency(code: "USD"))   // 1234.5
let n = try Double("1,234.5", format: .number)                          // 1234.5

// Date parsing with an explicit strategy:
let strategy = Date.FormatStyle(date: .numeric, time: .omitted, locale: Locale(identifier: "en_US"))
let date = try Date("8/3/2026", strategy: strategy)

// A dedicated fixed-format parser (locale-independent) for wire data:
let iso = try Date("2026-08-03T14:30:15Z", strategy: .iso8601)
```

- Parseable styles include `.number`, `.currency`, `.percent`, `Date.FormatStyle`, `.iso8601`, `URL.FormatStyle`, and any custom `ParseableFormatStyle`.
- Parsing **throws** — treat user input as fallible; wrap in `try?`/`do-catch` and surface a validation error.
- For **user money input**, parse with a `.currency`/`.number` strategy under an explicit or environment locale rather than hand-rolling; hand the parsed `Decimal` to your `Money` type (`kmp-money`).

<a id="swiftui"></a>
## SwiftUI `Text(_:format:)`

`Text` has an initializer that takes a value + a `FormatStyle`, re-formatting on
locale/environment changes.

```swift
import SwiftUI

Text(price, format: .currency(code: "USD"))
Text(Date.now, format: .dateTime.year().month().day())
Text(distance, format: .measurement(width: .abbreviated, usage: .road))
Text(tags, format: .list(type: .and))                       // tags: [String]

// Live-updating relative/timer text (self-refreshing, distinct from .relative style):
Text(eventDate, style: .relative)                           // "3 minutes"
Text(eventDate, style: .timer)                              // counts down/up
```

- `Text(_:format:)` reads `\.locale` from the environment — do not also pass `.locale(_:)` unless you deliberately override it.
- `Text(_:style:)` (`.relative`, `.timer`, `.date`, `.time`, `.offset`) auto-refreshes on a timer; `Text(_:format: .relative(...))` is a one-shot snapshot.

<a id="custom"></a>
## Custom FormatStyle

Conform to `FormatStyle` for a domain type. Make it `Codable`, `Hashable`, and
`Sendable`; expose an ergonomic static factory via a constrained extension.

```swift
struct AccountMaskStyle: FormatStyle {
    var visibleDigits: Int = 4

    func format(_ value: String) -> String {
        let tail = value.suffix(visibleDigits)
        return "•••• " + tail
    }
}

// Ergonomic call site: value.formatted(.accountMask())
extension FormatStyle where Self == AccountMaskStyle {
    static func accountMask(visibleDigits: Int = 4) -> AccountMaskStyle {
        AccountMaskStyle(visibleDigits: visibleDigits)
    }
}

"4111111111111234".formatted(.accountMask())               // "•••• 1234"
```

- For a **two-way** custom style, also conform to `ParseableFormatStyle` and provide a `parseStrategy: some ParseStrategy` whose `parse(_:) throws` inverts `format`.
- Compose built-ins inside `format(_:)` rather than reimplementing number/date logic (call `Decimal.formatted(...)` internally).
- Full `ParseableFormatStyle` + `ParseStrategy` example (a masked-money style) is in `references/recipes.md`.

<a id="legacy"></a>
## Replacing legacy `Formatter` subclasses

| Legacy `Formatter` | Modern `FormatStyle` |
|---|---|
| `NumberFormatter` (`.decimal`) | `.number` (`IntegerFormatStyle` / `FloatingPointFormatStyle`) |
| `NumberFormatter` (`.currency`) | `.currency(code:)` (`Decimal.FormatStyle.Currency`) |
| `NumberFormatter` (`.percent`) | `.percent` |
| `DateFormatter` | `Date.FormatStyle` (`.dateTime`) / `Date.ISO8601FormatStyle` |
| `RelativeDateTimeFormatter` | `Date.RelativeFormatStyle` (`.relative`) |
| `DateComponentsFormatter` | `Duration.UnitsFormatStyle` / `.TimeFormatStyle` |
| `MeasurementFormatter` | `Measurement.FormatStyle` (`.measurement`) |
| `ListFormatter` | `ListFormatStyle` (`.list(type:)`) |
| `ByteCountFormatter` | `ByteCountFormatStyle` (`.byteCount`) |
| `PersonNameComponentsFormatter` | `PersonNameComponents.FormatStyle` (`.name`) |

- `FormatStyle` values are **cheap value types** — no need to cache them the way you cached `NumberFormatter` instances (allocating an `NSNumberFormatter` per call was the classic perf bug; `.formatted` has no such cost).
- Legacy formatters are mutable, reference-typed, and not `Sendable` — a shared `DateFormatter` across threads is a data-race. `FormatStyle` values are `Sendable` and safe to share.
- Keep `ISO8601DateFormatter` / `.iso8601` for wire formats; migrate only the **display** formatters to locale-aware styles.

<a id="checklist"></a>
## Correctness checklist

- [ ] Money formats with `.currency(code:)` on a `Decimal`/minor-unit value, never `.number` on a `Double`.
- [ ] Currency fraction digits and symbol come from the code + locale, not hardcoded (JPY=0, BHD=3, not always 2).
- [ ] `.percent` input is a fraction (`0.07 → 7%`); values already ×100 use `.number` or `.scale(...)`.
- [ ] UI dates use locale-aware `.dateTime` / presets; **wire** dates use `.iso8601` (fixed), never a locale style.
- [ ] Relative "N ago" that must stay current uses `Text(_:style:.relative)`, not a one-shot `.relative` snapshot.
- [ ] `Duration` used for lengths of time; `.relative` used for points in time — not swapped.
- [ ] Person names go through `.name(style:)`, never `given + " " + family` concatenation.
- [ ] Tests and export code inject an explicit `.locale(_:)`; UI relies on the environment locale.
- [ ] Parsing (`try Decimal(_, format:)`, `try Date(_, strategy:)`) is wrapped in `try?`/`do-catch` — input is fallible.
- [ ] Custom styles conform to `FormatStyle` (+ `ParseableFormatStyle` if two-way), are `Codable`/`Hashable`/`Sendable`, and expose a static factory.
- [ ] Legacy `NumberFormatter`/`DateFormatter` shared across threads replaced with `Sendable` `FormatStyle` values.
