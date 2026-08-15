# Translation framework — batch, availability, downloads, errors

Depth for `natural-language`. The `Translation` framework is on-device and
**SwiftUI-driven**: you obtain a `TranslationSession` only inside a
`.translationTask` closure — it cannot be constructed directly.

## Configuration & triggering

```swift
import Translation
import SwiftUI

@State private var config: TranslationSession.Configuration?

// nil source → auto-detect. nil target → user's system/region default.
config = TranslationSession.Configuration(
    source: Locale.Language(identifier: "fr"),
    target: Locale.Language(identifier: "en"))
```

- The task runs when `config` becomes non-nil and **re-runs whenever you assign a new `Configuration`**. To repeat with the same languages, call `config?.invalidate()`.
- Two modifier forms: `.translationTask(_ configuration:action:)` (you own the `Configuration` state) and `.translationTask(source:target:action:)` (framework manages it).

## Single translation

```swift
.translationTask(config) { session in
    do {
        let response = try await session.translate("Votre solde est de 42 €")
        // response.targetText, response.sourceLanguage, response.targetLanguage
        translated = response.targetText
    } catch {
        // handle TranslationError (below)
    }
}
```

## Batch translation

For multiple strings sharing a source language, batch instead of looping — one
setup, parallelized, one download prompt.

```swift
let requests = memos.enumerated().map { index, text in
    TranslationSession.Request(sourceText: text, clientIdentifier: "\(index)")
}

.translationTask(config) { session in
    // (a) Wait for all, returned together:
    let responses = try await session.translations(from: requests)

    // (b) Or stream as each completes (order NOT guaranteed):
    for try await response in session.translate(batch: requests) {
        if let id = response.clientIdentifier {
            results[id] = response.targetText     // match back via the id you set
        }
    }
}
```

- **Responses are unordered.** Always set and read `clientIdentifier` to map a response to its request; never rely on array position with the streaming form.
- `TranslationSession.BatchResponse` provides async access to the streamed responses.

## Availability & pre-download

Language packs may not be installed. Check before translating, and pre-download
so the first translation isn't a surprise.

```swift
let availability = LanguageAvailability()
let status = await availability.status(
    from: Locale.Language(identifier: "fr"),
    to:   Locale.Language(identifier: "en"))

switch status {
case .installed:                     break                     // ready, fully offline
case .supported:                     try await session.prepareTranslation()  // prompts download
case .unsupported:                   showUnsupportedUI()
@unknown default:                    break
}
```

- `LanguageAvailability().supportedLanguages` lists installable languages.
- `session.prepareTranslation()` downloads/prepares the pack **without** translating — call it up front (it can throw `TranslationError.unableToIdentifyLanguage` if source is `nil` and there's no text to sniff). The system shows its own download consent sheet.
- Downloads need connectivity the first time; translation itself is offline afterward.

## Errors

`session.translate` / `prepareTranslation` throw `TranslationError`. Handle at least:

- `.unableToIdentifyLanguage` — auto-detect failed (empty/ambiguous input); provide an explicit `source`.
- unsupported language pairing — reflect the `.unsupported` availability status in UI.
- Cancellation — the task is tied to the view; the session invalidates when the view/config goes away. Don't retain a `TranslationSession` beyond the closure.

## System UI (no result handling)

```swift
.translationPresentation(isPresented: $show, text: memo)          // iOS 17.4+
// optional replacement action when user taps "Replace with translation":
.translationPresentation(isPresented: $show, text: memo) { replacement in
    memo = replacement
}
```

- Presents Apple's built-in translation sheet. Use when you only need to *show* a translation or offer a replace action — not when you need the string programmatically (use `translate`).

## UIKit

There is no direct UIKit translation API. Host the SwiftUI `translationTask` /
`translationPresentation` modifiers inside a `UIHostingController` and bridge
results out via a binding/closure — see `swiftui-uikit-interop`.

## Fintech notes

- Keep the **original** memo/merchant text as source of truth; store translations as a display-layer cache keyed by target language.
- Do not translate amounts/currency — format those with `swift-formatstyle`; translate only free-text descriptions.
- Translation is a UI concern; keep it out of shared KMP logic (see the KMP boundary note in the main skill).
