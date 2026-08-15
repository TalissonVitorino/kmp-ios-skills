# Profiling (MLComputePlan) & on-device personalization (MLUpdateTask)

Deep reference for `coreml`. Grounded in Apple's `MLComputePlan`, `MLModel.compileModel`, and `MLUpdateTask` docs (iOS 26).

## MLComputePlan — where do ops run & what do they cost

ML Program (`.mlpackage`/`.mlmodelc` from an mlprogram) only. Debug/pre-ship, not a per-launch call.

```swift
let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: config)

guard case let .program(program) = plan.modelStructure,
      let main = program.functions["main"] else {
    fatalError("Not an ML Program, or missing main function.")
}

for op in main.block.operations {
    let usage = plan.deviceUsage(for: op)                 // MLComputePlan.DeviceUsage?
    let preferred = usage?.preferred                      // the device Core ML will use
    let supported = usage?.supported                      // devices this op *could* run on
    let cost = plan.estimatedCost(of: op)?.weight         // Double 0...1, relative
    // Flag ops whose `preferred` is CPU when you expected .neuralEngine.
}
```

- `modelStructure` is an enum: `.program(_)` (ML Program), `.neuralNetwork(_)` (legacy NN), `.pipeline(_)`, `.unsupported`. Match the case you expect.
- `deviceUsage(for:)` accepts either a `Program.Operation` or a `NeuralNetwork.Layer` depending on structure.
- `estimatedCost(of:)` returns relative weights, not milliseconds — use it to rank the heaviest ops, then confirm wall-clock with the **Core ML Instrument**.
- Common finding: an op sequence forces a CPU/GPU fallback that breaks an otherwise ANE-resident model. Restructure the model (in `coremltools`, see `apple-on-device-ai`) or accept the fallback.

### Instruments

- Product ▸ Profile ▸ **Core ML** template: per-prediction timeline, compute-unit breakdown, load vs prediction, ANE residency.
- Pair with the **Neural Engine** and **GPU** instruments to see contention. For method-level and hang profiling see `debugging-instruments`; for production telemetry see `metrickit`.

## Runtime compilation

```swift
// Off the main thread — compilation is CPU-heavy and can take seconds.
let compiledTmpURL = try MLModel.compileModel(at: downloadedModelURL)   // -> .mlmodelc (temp)

// Move out of temp into a durable location before loading.
let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
    in: .userDomainMask, appropriateFor: nil, create: true)
let dest = appSupport.appendingPathComponent("MyModel.mlmodelc")
try? FileManager.default.removeItem(at: dest)
try FileManager.default.moveItem(at: compiledTmpURL, to: dest)

let model = try await MLModel.load(contentsOf: dest, configuration: config)
```

- There is also an async `compileModel(at:completionHandler:)` — use it to avoid manual queue hopping.
- Cache the compiled `.mlmodelc` keyed by a model version; recompile only when the source changes.
- `.mlmodelc` is a **directory** — copy/move recursively.
- Fintech: validate a downloaded model's signature/hash before compiling (never compile untrusted bytes), and store under a data-protection class via `swift-security`.

## On-device personalization (MLUpdateTask)

Fine-tune an **updatable** model with user-specific labeled data, entirely on device.

### 1. Confirm the model is updatable

```swift
guard model.modelDescription.isUpdatable else { /* not fine-tunable */ return }
```

- Updatability is baked in at conversion time (`coremltools` marks specific layers updatable + defines loss/optimizer). You cannot make an arbitrary model updatable at runtime.

### 2. Build training data as an MLBatchProvider

Each item pairs the input feature(s) with the **expected output** feature (the label), named to match the model's training inputs.

```swift
let examples: [MLFeatureProvider] = samples.map { s in
    try! MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(pixelBuffer: s.pixelBuffer),
        "label": MLFeatureValue(string: s.label),          // name must match the model's target
    ])
}
let trainingData = MLArrayBatchProvider(array: examples)
```

### 3. Run the update task

```swift
let progress = MLUpdateProgressHandlers(
    forEvents: [.trainingBegin, .epochEnd],
    progressHandler: { ctx in
        let metrics = ctx.metrics[.lossValue]              // observe loss per epoch
    },
    completionHandler: { ctx in
        guard ctx.task.state == .completed else { return }
        try? ctx.model.write(to: updatedModelURL)          // persist the new .mlmodelc
    })

let task = try MLUpdateTask(forModelAt: compiledModelURL,  // MUST be .mlmodelc & updatable
                            trainingData: trainingData,
                            configuration: config,
                            progressHandlers: progress)
task.resume()
```

- `forModelAt:` must be a **compiled** `.mlmodelc`. Passing a `.mlmodel`/`.mlpackage` fails.
- Tune via `MLModelConfiguration.parameters` (e.g. `.epochs`, learning rate) when the model exposes them; read available keys from `modelDescription.trainingInputDescriptionsByName` / the model's parameter descriptions.
- Persist with `context.model.write(to:)` (the model conforms to `MLWritable`). Load the updated `.mlmodelc` for subsequent predictions; the bundled original is untouched.
- Keep updates off the main thread and consider running them in the background (`background-processing`) so a long fine-tune doesn't block the UI.
- Privacy win: raw user data never leaves the device — a strong fit for fintech personalization. Still store the resulting model securely.

### Update lifecycle

- `task.resume()` starts it; there is no separate `start`. Observe `task.state` (`.suspended`, `.running`, `.completed`, `.failed`, `.cancelling`, `.cancelled`).
- Errors surface as `MLModelError.Code.update` / `.parameters` in the completion context.
