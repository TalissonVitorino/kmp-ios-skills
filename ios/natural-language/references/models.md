# Custom models: classifiers, word taggers, gazetteers, embeddings

Depth for `natural-language`. All models are trained with **Create ML** (the
`CreateML` framework or Create ML.app) and consumed at runtime by
`NaturalLanguage`. The runtime is Core ML — see the `coreml` skill for compute
units, `.mlpackage` vs `.mlmodelc`, and on-device updates.

## Text classifier (whole-string labels)

Use for transaction categorization, ticket routing, multi-class emotion.

```swift
import CreateML
import TabularData

// Labeled data: columns "text" and "label".
let data = try MLDataTable(contentsOf: URL(fileURLWithPath: "transactions.json"))
let (train, test) = data.randomSplit(by: 0.8, seed: 42)

let classifier = try MLTextClassifier(trainingData: train,
                                      textColumn: "text",
                                      labelColumn: "label")

let trainAcc = (1.0 - classifier.trainingMetrics.classificationError) * 100
let valAcc   = (1.0 - classifier.validationMetrics.classificationError) * 100
let evalAcc  = (1.0 - classifier.evaluation(on: test,
                        textColumn: "text", labelColumn: "label").classificationError) * 100

try classifier.write(to: URL(fileURLWithPath: "TxnCategoryClassifier.mlmodel"))
```

Runtime:

```swift
import NaturalLanguage
import CoreML

let model = try NLModel(mlModel: TxnCategoryClassifier(configuration: MLModelConfiguration()).model)
let label = model.predictedLabel(for: "UBER EATS AMSTERDAM")
let ranked = model.predictedLabelHypotheses(for: memo, maximumCount: 3)  // [String: Double]
```

- JSON training shape: an array of `{ "text": "...", "label": "..." }`.
- `MLDataTable` is the legacy Create ML table; recent Create ML deprecates it in favor of `TabularData.DataFrame` (which `MLTextClassifier`/`evaluation(on:)` also accept). The flow is identical — load a `DataFrame`, split, and pass it to the same initializers.
- `MLTextClassifier.ModelParameters` lets you pick the algorithm (`.maxEnt`, `.crf`, `.transferLearning`, `.dynamicEmbedding`) and validation split. Transfer learning gives the best accuracy on small datasets but larger models.
- Balance classes; report **evaluation** accuracy on a held-out `test` split, not just training/validation.

## Word tagger (per-token labels)

Labels each token — custom entity extraction (e.g. tagging product SKUs,
account references inside a memo).

```swift
// Training data is token arrays + matching label arrays (MLDataTable with
// "tokens" and "labels" list columns), then:
let tagger = try MLWordTagger(trainingData: data,
                              tokenColumn: "tokens",
                              labelColumn: "labels")
try tagger.write(to: URL(fileURLWithPath: "MemoEntityTagger.mlmodel"))
```

Runtime — attach the `NLModel` to a tagger scheme and enumerate:

```swift
let entityModel = try NLModel(contentsOf: compiledModelURL)   // .mlmodelc
let tagger = NLTagger(tagSchemes: [.nameType])
tagger.setModels([entityModel], for: .nameType)
tagger.string = memo
tagger.enumerateTags(in: memo.startIndex..<memo.endIndex,
                     unit: .word, scheme: .nameType, options: [.omitWhitespace]) { tag, r in
    if let tag { print("\(memo[r]) → \(tag.rawValue)") }
    return true
}
```

## Gazetteer (deterministic term → label)

Precedence over statistical taggers; ideal for fixed brand/entity lists.

```swift
// Runtime dictionary → data → gazetteer:
let data = try NLGazetteer.data(fromDictionary: [
    "card_network": ["visa", "mastercard", "amex", "american express"],
    "wallet":       ["apple pay", "google pay", "paypal", "venmo"],
], language: .english)
let gazetteer = try NLGazetteer(data: data)
gazetteer.label(for: "american express")   // "card_network"

// Or compile in Create ML and load:
//   let g = try MLGazetteer(dictionary: [...], language: "en")
//   try g.write(to: url)      // produces a compiled gazetteer file
let compiled = try NLGazetteer(contentsOf: url)
tagger.setGazetteers([compiled], for: .nameType)
```

- `NLGazetteer.language` reports the language it was built for; `NLGazetteer.data(fromDictionary:language:)` is the reusable serialized form to ship in your bundle.
- Terms are normalized to lowercase; matching is whole-token, not substring.

## Custom & contextual embeddings

### Domain word/sentence embedding (Create ML)

Ship your own finance-tuned embedding when the built-in vocabulary misses jargon:

```swift
// Build from vectors (Dictionary<String, [Double]> of equal-length vectors):
let ml = try MLWordEmbedding(dictionary: termVectors)
try ml.write(to: URL(fileURLWithPath: "FinanceEmbedding.mlmodel"))

// Runtime:
let embedding = try NLEmbedding(contentsOf: compiledURL)
let d = embedding.distance(between: "apr", and: "interest")
```

### `NLContextualEmbedding` (iOS 17+)

Dynamic, context-aware token embeddings (the whole sentence informs each token's
vector) — stronger than static `NLEmbedding` for semantic tasks, at higher cost.

```swift
guard let model = NLContextualEmbedding(language: .english) else { return }
if !model.hasAvailableAssets {
    try await model.requestAssets()   // downloads the model assets on first use
}
try model.load()
let result = try model.embeddingResult(for: sentence, language: .english)
result.enumerateTokenVectors(in: sentence.startIndex..<sentence.endIndex) { vector, range in
    // `vector` is [Float] for the token at `range`
    return true
}
```

- Assets are downloaded on demand — guard `hasAvailableAssets` / `requestAssets()` and handle offline first-run.
- Query multiple scripts/languages with the same model where supported; check `NLContextualEmbedding` availability per language.
- Heavier than static embeddings — reserve for quality-sensitive semantic search/clustering; reuse a single loaded instance.

## Model hygiene

- Version your models (embed a `metadata` version string); gate predictions on the model version so a stale bundled model can be replaced via `NLModel(contentsOf:)` from a downloaded `.mlmodelc`.
- Evaluate on a fresh held-out split before shipping; watch for class imbalance and data leakage between train/test.
- Keep a confidence floor at the call site; map low-confidence outputs to an explicit "unknown" label rather than the top guess.
