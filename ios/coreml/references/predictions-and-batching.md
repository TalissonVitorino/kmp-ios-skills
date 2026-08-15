# Predictions, batching, options & concurrency

Deep reference for `coreml`. Grounded in Apple's `MLModel` / `MLPredictionOptions` / `MLBatchProvider` docs (iOS 26).

## Prediction method matrix

| Method | Sync/async | Input | Use |
|---|---|---|---|
| `prediction(from:)` | sync throws | one `MLFeatureProvider` | simplest single call (off main thread) |
| `prediction(from:options:)` | sync throws | one + options | supply output backings / cpu-only |
| `prediction(from:)` (async) | `async throws` | one | Swift concurrency; honors cancellation |
| `prediction(from:using:)` / `...using:options:` | async/sync | one + `MLState` | stateful models |
| `predictions(from:options:)` | sync throws | `MLBatchProvider` | many inputs, one call |
| `predictions(fromBatch:)` | sync throws | `MLBatchProvider` | batch, default options |

The generated `MyModel.prediction(...)` wraps `prediction(from:)` with typed I/O.

## Batch providers

```swift
// Build a batch from an array of feature providers.
let providers: [MLFeatureProvider] = images.map { pb in
    try! MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
}
let batch = MLArrayBatchProvider(array: providers)

let out = try model.predictions(from: batch, options: MLPredictionOptions())
for i in 0..<out.count {
    let features = out.features(at: i)                 // MLFeatureProvider per input, index-aligned
    let label = features.featureValue(for: "classLabel")?.stringValue
}
```

- `MLArrayBatchProvider(array:)` and `MLArrayBatchProvider(featureProviderArray:)` both exist; the outputs are index-aligned with inputs.
- Conform your own type to `MLBatchProvider` (`count`, `features(at:)`) to stream inputs without materializing an array.
- Batch amortizes Neural Engine setup — measurably faster than looping `prediction(from:)` for N ≥ ~a handful of inputs.

## MLPredictionOptions

```swift
let options = MLPredictionOptions()
// Pre-allocate the output buffer Core ML writes into (avoids per-call allocation in hot loops):
let backing = try MLMultiArray(shape: [1, 1000], dataType: .float32)
options.outputBackings = ["classLabelProbs": backing]
let out = try model.prediction(from: input, options: options)
// `backing` now holds the result; reuse it next call.
```

- `outputBackings`: map output feature name → a pre-allocated `MLMultiArray` or `CVPixelBuffer`. Core ML writes in place. Great for real-time video where you reuse buffers.
- The backing's shape/type must match the output description exactly, else it throws.
- `usesCPUOnly` on `MLPredictionOptions` is **deprecated** — set `configuration.computeUnits = .cpuOnly` at load time instead.

## Async & cancellation

```swift
func classify(_ input: MLFeatureProvider) async throws -> String {
    do {
        let out = try await model.prediction(from: input)
        return out.featureValue(for: "classLabel")?.stringValue ?? "?"
    } catch let e as MLModelError where e.code == .predictionCancelled {
        throw CancellationError()                       // task was cancelled — not a real failure
    }
}
```

- The async prediction runs off the calling thread; cancelling the enclosing `Task` propagates and surfaces as `MLModelError.Code.predictionCancelled`.
- Other `MLModelError.Code` values worth handling: `.modelDecryptionKeyFetch`, `.modelCollection`, `.update`, `.parameters`, `.generic`.

## Thread safety

- **One `MLModel` instance is not safe for concurrent prediction.** Serialize calls, or create one instance per thread/queue.
- Clean pattern — wrap the model in an `actor`:

```swift
actor Classifier {
    private let model: MyModel
    init(config: MLModelConfiguration) throws { model = try MyModel(configuration: config) }
    func predict(_ pb: CVPixelBuffer) throws -> MyModelOutput { try model.prediction(image: pb) }
}
```

- For true parallelism (multiple ANE-eligible predictions at once), instantiate N models and round-robin — the actor serializes, which is correct but not parallel.

## Feature value cheat-sheet

| Output `MLFeatureType` | Read with |
|---|---|
| `.string` | `.stringValue` |
| `.int64` | `.int64Value` |
| `.double` | `.doubleValue` |
| `.multiArray` | `.multiArrayValue` → `MLMultiArray` |
| `.dictionary` | `.dictionaryValue` → `[AnyHashable: NSNumber]` |
| `.image` | `.imageBufferValue` → `CVPixelBuffer` |
| `.sequence` | `.sequenceValue` → `MLSequence` |

Check `outputDescriptionsByName[name].type` when you don't control the model.
