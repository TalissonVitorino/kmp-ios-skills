---
name: natural-language
description: "On-device text intelligence for an iOS fintech app with Apple's NaturalLanguage + Translation frameworks — language ID (NLLanguageRecognizer, languageHints/constraints), tokenization (NLTokenizer word/sentence), linguistic tagging (NLTagger with .lexicalClass/.nameType/.lemma, enumerateTags, tagHypotheses, setLanguage), on-device sentiment (.sentimentScore), custom Create ML text classifiers (NLModel), term lookup (NLGazetteer), word/sentence semantic similarity (NLEmbedding distance/neighbors), and in-app translation (translationTask, TranslationSession.translate + batch, LanguageAvailability, .translationPresentation). Use to categorize/redact/search transaction memos, detect a message's language, score support-ticket sentiment, or translate merchant text — all offline. For the Core ML runtime behind NLModel use `coreml`; for generative/LLM features use `apple-on-device-ai`; for OCR that produces the text use `vision-framework`; for locale display use `localization-patterns` + `swift-formatstyle`. KMP boundary: wrap behind a commonMain interface (see `expect-actual`)."
---

# NaturalLanguage & Translation (iOS)

On-device, offline text processing for a fintech iOS app. Nothing leaves the
device — safe for transaction memos, support messages, and PII. Grounded in
Apple's `NaturalLanguage` and `Translation` frameworks (iOS 26 era).

- **Everything here runs locally.** No network, no per-call cost, works in airplane mode. Ideal for sensitive financial text.
- **Not generative.** For summarization, rewriting, or chat use Foundation Models via `apple-on-device-ai`. NaturalLanguage *analyzes* text; it does not author it.
- **Underlying runtime:** custom `NLModel`s are Core ML models — see `coreml` for training/compute-unit details. Text often comes from OCR (`vision-framework`) or user input.

## Contents

- [Pick the tool](#pick)
- [Language identification](#language-id)
- [Tokenization](#tokenization)
- [Linguistic tagging (POS / names / lemma)](#tagging)
- [Sentiment](#sentiment)
- [Custom classification (NLModel)](#nlmodel)
- [Gazetteers (term lists)](#gazetteer)
- [Embeddings (semantic similarity)](#embeddings)
- [Translation framework](#translation)
- [Threading & performance](#performance)
- [KMP boundary](#kmp)
- [Correctness checklist](#checklist)
- References: `references/models.md`, `references/translation.md`

<a id="pick"></a>
## Pick the tool

| Goal | API | Unit / scheme |
|---|---|---|
| Which language is this? | `NLLanguageRecognizer` | — |
| Split into words/sentences | `NLTokenizer` | `.word` / `.sentence` |
| Part of speech | `NLTagger` | `.lexicalClass` |
| People / places / orgs (redaction) | `NLTagger` | `.nameType` |
| Dictionary root form | `NLTagger` | `.lemma` |
| Positive/negative score | `NLTagger` | `.sentimentScore` |
| Categorize with your own labels | `NLModel` (Create ML) | — |
| Match known terms/brands | `NLGazetteer` | — |
| "Is X similar in meaning to Y?" | `NLEmbedding` | word or sentence |
| Translate text | `Translation` (`translationTask`) | — |

<a id="language-id"></a>
## Language identification

```swift
import NaturalLanguage

// One-shot: dominant language of a string.
let lang = NLLanguageRecognizer.dominantLanguage(for: "Votre solde est de 42 €")
// -> Optional(NLLanguage.french)
```

For ranked guesses, mixed-language text, or a known candidate set, use an
instance (reusable — call `reset()` between strings):

```swift
let recognizer = NLLanguageRecognizer()
recognizer.languageConstraints = [.english, .french, .portuguese, .spanish]  // only these
recognizer.languageHints = [.portuguese: 0.6, .english: 0.4]                 // prior probabilities
recognizer.processString(memo)

let dominant = recognizer.dominantLanguage                    // NLLanguage?
let ranked   = recognizer.languageHypotheses(withMaximum: 3)  // [NLLanguage: Double] confidences
recognizer.reset()
```

- `NLLanguage` is a struct of ISO-639 codes (`.english`, `.french`, …); get the raw tag via `lang.rawValue` ("en") and rebuild with `NLLanguage(rawValue:)`.
- Accuracy drops on very short strings — a 2-word memo may be ambiguous. Use `languageHints`/`languageConstraints` (e.g. from the user's `Locale`) to bias it.
- Feed the detected `NLLanguage` into `NLTokenizer.setLanguage` / `NLTagger.setLanguage` so downstream analysis uses the right model.

<a id="tokenization"></a>
## Tokenization

```swift
let tokenizer = NLTokenizer(unit: .word)          // .word, .sentence, .paragraph, .document
tokenizer.string = text
tokenizer.setLanguage(.japanese)                  // optional; essential for CJK/Thai (no spaces)

// Ranges (String.Index) of each token:
let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)

// Or enumerate — return false to stop early:
tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, attributes in
    let token = text[range]
    if attributes.contains(.numeric) { /* amount-like token */ }
    return true
}
```

- `attributes` is `NLTokenizer.Attributes` — `.numeric`, `.symbolic`, `.emoji`. Useful to skip amounts/emoji when indexing memo text.
- Tokenizer yields **ranges**, never copies — slice the original `String` with them.
- `.word` respects language-specific rules (contractions, CJK segmentation) far better than `split(separator:)`.

<a id="tagging"></a>
## Linguistic tagging (POS / names / lemma)

One `NLTagger` handles multiple schemes. Declare them up front:

```swift
let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .lemma])
tagger.string = text
tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)   // optional hint

let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
```

- `.omitWhitespace` / `.omitPunctuation` / `.omitOther` skip noise tokens.
- `.joinNames` merges "New York" into one `.nameType` token instead of two.
- `.joinContractions` keeps "don't" whole.

### Named entities → redaction (PII scrubbing before logging)

```swift
tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                     unit: .word, scheme: .nameType, options: options) { tag, range in
    switch tag {
    case .personalName, .placeName, .organizationName:
        redactionRanges.append(range)     // strip before sending to logs/analytics
    default:
        break
    }
    return true
}
```

- `.nameType` tags are `.personalName`, `.placeName`, `.organizationName` (plus `.otherWord`, `.whitespace`, `.punctuation`). Combine with a `.nameTypeOrLexicalClass` scheme to get both in one pass.

### Part of speech and lemma

```swift
// Lexical class: .noun, .verb, .adjective, .determiner, .preposition, .number, …
tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: options) { tag, r in
    print("\(text[r]) → \(tag?.rawValue ?? "?")")
    return true
}

// Lemma (dictionary form): "payments" → "payment", "paid" → "pay" — great for search indexing.
let (lemma, _) = tagger.tag(at: text.startIndex, unit: .word, scheme: .lemma)
```

- Single-token lookup: `tag(at:unit:scheme:)` returns `(NLTag?, Range<String.Index>)`.
- Multiple ranked guesses with confidence: `tagHypotheses(at:unit:scheme:maximumCount:)` → `([String: Double], Range<String.Index>)`. Use it when a single best tag isn't confident enough.
- Attach a custom `NLModel` or `NLGazetteer` to a scheme with `setModels(_:for:)` / `setGazetteers(_:for:)` (below) to override the built-in tagger for that scheme.

<a id="sentiment"></a>
## Sentiment

A built-in scheme scoring `-1.0` (negative) … `+1.0` (positive) — no training
needed. Only valid at `.paragraph` unit.

```swift
let tagger = NLTagger(tagSchemes: [.sentimentScore])
tagger.string = review
let (sentiment, _) = tagger.tag(at: review.startIndex, unit: .paragraph, scheme: .sentimentScore)
let score = Double(sentiment?.rawValue ?? "") ?? 0     // NLTag wraps a stringified Double
```

- The tag's `rawValue` is a **string** — parse to `Double`. Missing/neutral → treat as `0`.
- Score per sentence by iterating sentences with an `NLTokenizer(unit: .sentence)` and scoring each `.paragraph` slice — the model looks at whole paragraphs, so per-sentence scoring needs per-sentence ranges.
- Good for triaging support tickets or flagging angry review text; for nuanced multi-class emotion, train an `NLModel`.

<a id="nlmodel"></a>
## Custom classification (NLModel)

Train a text classifier in Create ML (labeled examples → `.mlmodel`), then load
it with `NLModel`. Runs on Core ML — see `coreml`.

```swift
import CoreML

// From a Create ML-generated class (compiled into the app):
let model = try NLModel(mlModel: TxnCategoryClassifier(configuration: MLModelConfiguration()).model)

let label = model.predictedLabel(for: "UBER EATS AMSTERDAM")          // e.g. "food_delivery"
let ranked = model.predictedLabelHypotheses(for: memo, maximumCount: 3) // [String: Double]
```

- `NLModel(mlModel:)` for a bundled model; `NLModel(contentsOf:)` for a compiled `.mlmodelc` URL (downloaded/updatable model).
- Two model kinds: a **classifier** labels whole strings (`predictedLabel(for:)`); a **word tagger** labels each token — plug it into a tagger with `tagger.setModels([model], for: .nameType)` and enumerate.
- Keep a confidence floor: if the top `predictedLabelHypotheses` value is low, fall back to "uncategorized" rather than mislabeling a transaction.
- Training data prep, revision/versioning, and word-tagger models: `references/models.md`.

<a id="gazetteer"></a>
## Gazetteers (term lists)

A gazetteer maps known **terms → labels** and takes precedence over a statistical
tagger. Perfect for a fixed vocabulary — card networks, wallet brands, merchant
aliases — where you want exact, deterministic hits.

```swift
// Build at runtime from a dictionary (label → terms):
let data = try NLGazetteer.data(fromDictionary: [
    "card_network": ["visa", "mastercard", "amex", "american express"],
    "wallet":       ["apple pay", "google pay", "paypal"],
], language: .english)
let gazetteer = try NLGazetteer(data: data)

gazetteer.label(for: "amex")          // "card_network"  (nil if no match)

// Or attach a Create ML-compiled gazetteer to a tagger scheme:
let compiled = try NLGazetteer(contentsOf: modelURL)
tagger.setGazetteers([compiled], for: .nameType)
```

- Matching is case-insensitive and whole-token; terms are normalized to lowercase for the given language.
- Prefer a gazetteer over regex for brand/entity lists — it composes with the tagger and respects tokenization.

<a id="embeddings"></a>
## Embeddings (semantic similarity)

Map words/sentences to vectors so you can measure *meaning* distance — powers
"find similar memos", synonym expansion, and lightweight on-device semantic
search. Distance is **cosine** by default: smaller = more similar.

```swift
// Word-level (per language):
guard let word = NLEmbedding.wordEmbedding(for: .english) else { return }
let d = word.distance(between: "refund", and: "chargeback")     // NLDistance (0 = identical)
let similar = word.neighbors(for: "invoice", maximumCount: 5)   // [(String, NLDistance)] nearest first
let vec = word.vector(for: "payment")                          // [Double]? raw embedding

// Sentence-level (semantic search over free-text memos):
guard let sentence = NLEmbedding.sentenceEmbedding(for: .english) else { return }
let sd = sentence.distance(between: "monthly rent", and: "apartment lease payment")  // small → related
```

- `wordEmbedding(for:)` / `sentenceEmbedding(for:)` return `nil` when the language is unsupported — always guard.
- `neighbors(for:maximumCount:)` only returns words in the built-in vocabulary (OOV terms have no neighbors); `distance` works on any in-vocabulary pair.
- For a searchable memo index, precompute `vector(for:)` per item and rank by cosine distance to the query vector.
- Ship your own domain embedding (finance jargon) built in Create ML: `references/models.md`. For richer contextual embeddings, `NLContextualEmbedding` (iOS 17+) is covered there.

<a id="translation"></a>
## Translation framework

On-device translation, **SwiftUI-only**, driven by the `.translationTask`
modifier — you never construct a `TranslationSession` directly.

```swift
import Translation
import SwiftUI

struct MemoTranslationView: View {
    let memo: String
    @State private var config: TranslationSession.Configuration?
    @State private var translated = ""

    var body: some View {
        VStack {
            Text(translated.isEmpty ? memo : translated)
            Button("Translate") {
                // Set/replace the config to (re)trigger the task. nil source = auto-detect.
                config = .init(source: nil, target: Locale.Language(identifier: "en"))
            }
        }
        .translationTask(config) { session in
            do {
                let response = try await session.translate(memo)
                translated = response.targetText
            } catch { /* TranslationError — see references/translation.md */ }
        }
    }
}
```

- Assigning a **new** `TranslationSession.Configuration` re-runs the task; call `config?.invalidate()` to force a re-run with the same languages.
- `session.translate(_:)` → a `Response` with `targetText`, `sourceLanguage`, `targetLanguage`.
- **Batch** many strings (same source language) instead of looping — `session.translations(from:)` waits for all; `session.translate(batch:)` streams as ready. Responses are unordered — match via `clientIdentifier`. See `references/translation.md`.
- **Check availability / pre-download** with `LanguageAvailability().status(from:to:)` (`.installed` / `.supported` / `.unsupported`) and `session.prepareTranslation()` to prompt the language download up front.

### System UI (no session, iOS 17.4+)

For a quick built-in translation sheet with zero result handling:

```swift
.translationPresentation(isPresented: $showTranslation, text: memo)
```

- Use this when you just want to *show* a translation; use `translationTask` when you need the translated **string** back (to store, index, or display inline).
- UIKit has no direct API — host the SwiftUI modifiers in a `UIHostingController` (see `swiftui-uikit-interop`).

<a id="performance"></a>
## Threading & performance

- `NLTagger` / `NLTokenizer` / `NLEmbedding` are **not thread-safe** — one instance per thread; don't share across a `TaskGroup`.
- **Reuse** taggers/tokenizers/embeddings across calls; construction (esp. loading an embedding) is the expensive part. Set `.string` per input.
- Run large-batch tagging off the main actor; keep instances inside the background context. Hop back to `@MainActor` only to publish results.
- Loading `NLEmbedding` pulls a sizable model into memory — load lazily, hold a single shared instance, and release under memory pressure.
- Translation and `prepareTranslation()` may block on a language-pack download the first time — always handle the "supported but not installed" path.

<a id="kmp"></a>
## KMP boundary

NaturalLanguage and Translation are **iOS-only** (no Android/`commonMain`
equivalent). Keep shared code framework-agnostic:

- Define a `commonMain` `interface TextIntelligence { fun categorize(memo: String): String; fun detectLanguage(text: String): String? }` and bind an `iosMain` `actual` that calls these APIs; the Android `actual` uses ML Kit / its own models. See `expect-actual` (depth: `android-skills:kmp-boundaries`).
- Return plain domain types (labels, scores, ISO language codes) across the boundary — never `NLTag`/`NLLanguage`. Model them with `shared-models`.
- Don't put translation in shared logic; it's a UI-layer, SwiftUI-bound concern on iOS.

<a id="checklist"></a>
## Correctness checklist

- [ ] Detected `NLLanguage` fed into `setLanguage` on tokenizer/tagger before analysis.
- [ ] `languageHints`/`languageConstraints` set for short or mixed-language text; `reset()` between reuses of a recognizer.
- [ ] Tokenizer used for word/sentence splitting (not `split`) — language set for CJK/Thai.
- [ ] Tagger schemes declared in the initializer; `.omitWhitespace`/`.omitPunctuation`/`.joinNames` set as needed.
- [ ] `.sentimentScore` read at `.paragraph` unit and parsed `Double(tag.rawValue)`, neutral defaulted to 0.
- [ ] Name-type tagging used to redact PII before any logging/analytics.
- [ ] `NLModel` predictions guarded by a confidence floor (`predictedLabelHypotheses`), with an "uncategorized" fallback.
- [ ] `NLEmbedding.wordEmbedding/sentenceEmbedding` results `nil`-checked; single shared instance reused.
- [ ] Instances reused, one per thread; heavy work off the main actor; embeddings loaded lazily.
- [ ] Translation availability checked (`LanguageAvailability`) and `prepareTranslation()` handles first-run downloads; batch API used for multiple strings; results matched by `clientIdentifier`.
- [ ] NaturalLanguage/Translation kept behind an iOS `actual`; only plain domain types cross the KMP boundary.
