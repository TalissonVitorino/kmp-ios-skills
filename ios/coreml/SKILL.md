---
name: coreml
description: "On-device ML inference with Core ML on iOS/iPadOS 26. Covers model formats (.mlmodel/.mlpackage/.mlmodelc), the Xcode auto-generated model class + Input/Output, MLModel loading (async load / compileModel), MLFeatureProvider / MLFeatureValue, MLModelConfiguration.computeUnits (.all/.cpuOnly/.cpuAndGPU/.cpuAndNeuralEngine), single/async/batch prediction (MLBatchProvider, MLPredictionOptions, output backings), stateful models (MLState), MLTensor (iOS 18+), MLComputePlan profiling, VNCoreMLRequest / iOS-18 Vision CoreMLRequest, and on-device personalization (MLUpdateTask). Use when loading a Core ML model, running predictions, picking compute units, profiling model cost, or wiring image models through Vision. To choose an on-device runtime (Foundation Models vs Core ML vs MLX) or convert/compress a model with coremltools, use `apple-on-device-ai`; for OCR/barcode/face requests use `vision-framework`; for text/embeddings use `natural-language`; to expose the model behind a KMP interface see `expect-actual` and `kmp-ios-integration`."
---

# Core ML (on-device inference, iOS 26)

Load and run trained ML models on device with the Neural Engine / GPU / CPU. Core
ML is the **inference & fine-tune runtime** — it does not convert or train models
from scratch.

- **Runtime choice / model conversion:** picking Core ML vs Foundation Models vs MLX, or converting a PyTorch/TF model with `coremltools` → `apple-on-device-ai`.
- **Image analysis (OCR, barcodes, faces, saliency):** Vision's own requests → `vision-framework`. Use Core ML directly only for your *custom* model.
- **KMP boundary:** keep the model + prediction in `iosMain`; expose a `commonMain interface Classifier` and bind an `actual`. Marshal plain types (arrays, floats) across — never a Core ML object. See `expect-actual`, `kmp-ios-integration`.

## Contents

- [Model formats](#formats)
- [Add a model & the generated class](#generated)
- [Loading MLModel](#loading)
- [Compute units](#compute-units)
- [Predictions (generated class vs raw MLFeatureProvider)](#predictions)
- [Async & batch prediction](#async-batch)
- [Images & MLFeatureValue](#images)
- [MLTensor (iOS 18+)](#mltensor)
- [Stateful models (MLState)](#state)
- [Profiling with MLComputePlan](#computeplan)
- [Downloaded models & on-device personalization](#download-personalize)
- [Correctness checklist](#checklist)
- References: `references/predictions-and-batching.md`, `references/vision-and-images.md`, `references/profiling-and-personalization.md`

<a id="formats"></a>
## Model formats

| Extension | What it is | Where it comes from |
|---|---|---|
| `.mlmodel` | Legacy neural-network / tree / pipeline source model | `coremltools` convert (older) |
| `.mlpackage` | **ML Program** package (weights + spec); the modern default, needed for float16 weights, compression, iOS-18 features | `coremltools` convert (`convert_to="mlprogram"`) |
| `.mlmodelc` | **Compiled** model directory the runtime actually loads | Xcode build, or `MLModel.compileModel(at:)` at runtime |

- Drop `.mlmodel`/`.mlpackage` into the Xcode project → Xcode **compiles it to `.mlmodelc`** at build time and generates a Swift class.
- A model **downloaded at runtime** arrives as `.mlmodel`/`.mlpackage` and must be compiled on-device before use (see [below](#download-personalize)).
- `.mlmodelc` is a folder, not a file — copy the whole directory when moving it.

<a id="generated"></a>
## Add a model & the generated class

Adding `MobileNetV2.mlpackage` generates a `MobileNetV2` class plus `MobileNetV2Input` / `MobileNetV2Output` feature wrappers.

```swift
let config = MLModelConfiguration()
config.computeUnits = .all
let model = try MobileNetV2(configuration: config)   // wraps the underlying MLModel

let output = try model.prediction(image: pixelBuffer) // typed input(s) → typed output
print(output.classLabel, output.classLabelProbs)      // named exactly as the model's outputs
```

- The generated `prediction(...)` is **synchronous and throwing** — call it off the main thread for anything non-trivial.
- Reach the underlying `MLModel` via `model.model` when you need raw APIs (batch, state, `modelDescription`).
- Inspect I/O names/types/constraints at runtime with `model.model.modelDescription` (`inputDescriptionsByName`, `outputDescriptionsByName`) — do this before hand-building feature providers.

<a id="loading"></a>
## Loading MLModel

```swift
// From a compiled model already in the bundle:
let url = Bundle.main.url(forResource: "MobileNetV2", withExtension: "mlmodelc")!
let model = try MLModel(contentsOf: url, configuration: config)

// Preferred on iOS 16+: async load keeps the UI responsive (loading can be slow / Neural-Engine warm-up).
let model = try await MLModel.load(contentsOf: url, configuration: config)
```

- Use the **async `load(contentsOf:configuration:)`** in app code — synchronous `init` blocks while the model compiles for the target compute unit.
- Loading is expensive; **load once and reuse** the instance. Do not re-instantiate per prediction.
- An `MLModel` is **not** safe for concurrent use — serialize calls on one instance, or make one instance per queue (see [async & batch](#async-batch)).

<a id="compute-units"></a>
## Compute units

`MLModelConfiguration.computeUnits: MLComputeUnits` controls which processors are eligible:

| Case | Uses | When |
|---|---|---|
| `.all` | CPU + GPU + Neural Engine (OS picks) | **Default.** Best perf/efficiency for most models |
| `.cpuOnly` | CPU only | Deterministic/reproducible output, background work, debugging ANE divergence |
| `.cpuAndGPU` | CPU + GPU | Large vision/generative models; parallel with other ANE work |
| `.cpuAndNeuralEngine` | CPU + ANE | Force ANE path, exclude GPU |

- The OS may still fall back across devices — `.all` is a permission set, not a guarantee. Confirm the *actual* placement with `MLComputePlan` ([below](#computeplan)), not by assuming.
- ANE requires an ML Program (`.mlpackage`) with a supported precision (typically float16). float32-only models run on CPU/GPU.
- Numeric results can differ slightly between compute units — pin `.cpuOnly` in tests that assert exact values.
- Set `config.computeUnits` **before** loading; changing it needs a reload.

<a id="predictions"></a>
## Predictions (generated class vs raw MLFeatureProvider)

`MLModel` speaks `MLFeatureProvider` (a dictionary of named `MLFeatureValue`s). The generated `*Input`/`*Output` classes are just typed conveniences over it.

```swift
// Raw path — build a feature provider yourself (needed for downloaded / dynamically-loaded models):
let input = try MLDictionaryFeatureProvider(dictionary: [
    "image": MLFeatureValue(pixelBuffer: pixelBuffer),
    "iouThreshold": MLFeatureValue(double: 0.45),
])
let out: MLFeatureProvider = try model.prediction(from: input)
let probs = out.featureValue(for: "classLabelProbs")?.dictionaryValue  // [AnyHashable: NSNumber]
let label = out.featureValue(for: "classLabel")?.stringValue
```

- `MLFeatureValue` variants: `.multiArrayValue`, `.dictionaryValue`, `.stringValue`, `.imageBufferValue`, `.doubleValue`, `.int64Value`, `.sequenceValue`. Read the one matching the output's `MLFeatureType`.
- `MLDictionaryFeatureProvider(dictionary:)` throws if a value's type/shape violates the model's input constraint — a fast way to catch shape bugs.
- For a custom provider type, conform to `MLFeatureProvider` (`featureNames`, `featureValue(for:)`).

<a id="async-batch"></a>
## Async & batch prediction

```swift
// Async single prediction (Swift concurrency) — respects task cancellation.
let out = try await model.prediction(from: input)

// Batch: one call, many inputs. Far faster than a loop — lets Core ML pipeline the ANE.
let batch = MLArrayBatchProvider(array: inputs)          // [MLFeatureProvider]
let results: MLBatchProvider = try model.predictions(from: batch, options: MLPredictionOptions())
for i in 0..<results.count { let r = results.features(at: i) /* ... */ }
```

- **Prefer batch over a `for` loop** of single predictions when you have N inputs ready — it amortizes setup and keeps the Neural Engine busy.
- The async form dispatches off the caller; a cancelled `Task` surfaces as `MLModelError.Code.predictionCancelled`. Handle it, don't treat it as a real failure.
- For a stream of concurrent predictions, give **each worker its own `MLModel`** (thread-unsafe per instance) or serialize on a dedicated queue/actor.
- `MLPredictionOptions.outputBackings` lets you supply pre-allocated `MLMultiArray`/`CVPixelBuffer` to write results into — avoids per-call allocation in hot loops. Full pattern + concurrency notes in `references/predictions-and-batching.md`.

<a id="images"></a>
## Images & MLFeatureValue

For image inputs you either feed Core ML directly or go through Vision (Vision handles crop/scale/color-match for you — usually the right call).

```swift
// Direct: build an image feature value honoring the model's input constraint.
let constraint = model.model.modelDescription.inputDescriptionsByName["image"]!.imageConstraint!
let fv = try MLFeatureValue(cgImage: cgImage,
                            orientation: .up,
                            constraint: constraint,      // enforces required WxH & pixel format
                            options: nil)
```

- `imageConstraint` gives the model's required `pixelsWide`/`pixelsHigh`/`pixelFormatType` — build inputs from it instead of hardcoding sizes.
- Convenience inits also take `pixelBuffer:`, `imageAtURL:...`, or `cgImage:pixelsWide:pixelsHigh:pixelFormatType:`. Mismatched size/format throws.
- **Vision path (recommended for images):** `VNCoreMLRequest` (classic) or the iOS-18 Swift `CoreMLRequest` — Vision resizes and color-matches automatically. See [Vision integration](#vision) and `references/vision-and-images.md`.

<a id="mltensor"></a>
## MLTensor (iOS 18+)

`MLTensor` is a multi-dimensional array with a familiar, differentiable-free math API — use it to express **pre/post-processing or glue between models** without dropping to `MLMultiArray` index math.

```swift
import CoreML

let logits = MLTensor(shapedArray: outputShapedArray)      // from a model output
let probs = logits.softmax(alongAxis: -1)
let topIndex = probs.argmax(alongAxis: -1)

// Tensors are lazy — materialize with await:
let result = await probs.shapedArray(of: Float.self)       // MLShapedArray<Float>
```

- Operations are **lazy and async**: nothing computes until you `await` a materializer (`shapedArray(of:)`, `scalar(of:)`, etc.). Batch your ops, materialize once.
- Bridges: `MLTensor(shapedArray:)` and `MLShapedArray(_:)` ↔ `MLMultiArray(_:)` convert without manual copies.
- Runs on the compute units the enclosing context allows; good for chaining model outputs (e.g. NMS, normalization) on-device. iOS 18.0+ / iPadOS 18.0+.

<a id="state"></a>
## Stateful models (MLState)

Stateful models (e.g. transformer KV-cache) keep buffers **between** predictions instead of re-feeding them each call.

```swift
let state = model.makeState()                              // buffers zero-initialized
let out = try await model.prediction(from: input, using: state)   // pass same state each step
// Seed / inspect a buffer:
state.withMultiArray(for: "kvCache") { buf in buf[0] = 1.0 }
```

- Create **one `MLState` per independent sequence**; do not share a single state across concurrent predictions — that's undefined behavior.
- Only models authored as stateful expose named state buffers; check `modelDescription.stateDescriptionsByName`.

<a id="computeplan"></a>
## Profiling with MLComputePlan

Before shipping, verify *where* each operation runs and its relative cost. Debug-time only — don't call it on every launch.

```swift
let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: config)
guard case let .program(program) = plan.modelStructure,
      let main = program.functions["main"] else { return }

for op in main.block.operations {
    let device = plan.deviceUsage(for: op)?.preferred        // .cpu / .gpu / .neuralEngine
    let cost = plan.estimatedCost(of: op)?.weight             // 0...1 relative
    // Flag ops that fell back off the Neural Engine.
}
```

- Use it to catch ops silently falling back to CPU/GPU (a common cause of "why is my ANE model slow"). ML Program models only.
- Pair with the Core ML Instrument in Instruments for wall-clock timing. See `references/profiling-and-personalization.md` and, for method-level profiling, `debugging-instruments`.

<a id="download-personalize"></a>
## Downloaded models & on-device personalization

### Compile a model fetched at runtime

```swift
// modelURL points to a downloaded .mlmodel / .mlpackage on disk.
let compiledURL = try MLModel.compileModel(at: modelURL)     // -> .mlmodelc; slow, off main thread
let model = try MLModel(contentsOf: compiledURL, configuration: config)
```

- `compileModel(at:)` is **synchronous and expensive** — run it on a background queue/`Task.detached`.
- The returned `.mlmodelc` lives in a temp location — **move it into Application Support** and load from there; don't recompile every launch.
- Downloaded model files can be large and sensitive — for a fintech app, verify integrity (hash/signature) before compiling, and store under an appropriate data-protection class (see `swift-security`).

### On-device updates (updatable models)

An **updatable** Core ML model can be fine-tuned on device with labeled examples via `MLUpdateTask` — e.g. personalizing a classifier to one user without sending data off device.

```swift
let updateTask = try MLUpdateTask(
    forModelAt: compiledModelURL,          // MUST be a .mlmodelc
    trainingData: trainingBatch,           // MLBatchProvider of input+expected-output features
    configuration: config,
    completionHandler: { context in
        try? context.model.write(to: newModelURL)   // persist the updated .mlmodelc
    })
updateTask.resume()
```

- Only a **compiled `.mlmodelc`** authored as updatable can be updated; check `modelDescription.isUpdatable`.
- Training data is an `MLBatchProvider` pairing each input with its target output feature.
- Persist the result with `context.model.write(to:)` and load the new model going forward; the original bundle model is unchanged.
- Full update flow (progress handlers, `MLUpdateProgressHandlers`, hyper-params) in `references/profiling-and-personalization.md`.

<a id="vision"></a>
## Vision integration (image models)

For image-in models, Vision handles resize/crop/color-matching so you don't hand-prep pixel buffers.

```swift
// Classic (iOS 11+):
let vnModel = try VNCoreMLModel(for: model.model)            // wrap the MLModel
let request = VNCoreMLRequest(model: vnModel) { req, _ in
    guard let top = (req.results as? [VNClassificationObservation])?.first else { return }
    // top.identifier, top.confidence
}
request.imageCropAndScaleOption = .centerCrop               // .scaleFit / .scaleFill
try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
```

- Result types: `VNClassificationObservation` (classify), `VNRecognizedObjectObservation` (detect + boxes), `VNPixelBufferObservation` / `VNCoreMLFeatureValueObservation` (image-to-image / raw).
- `imageCropAndScaleOption` **must match how the model was trained** or accuracy drops.
- iOS 18+ offers the modern Swift Vision API — `CoreMLRequest(model:)` over a `CoreMLModelContainer`, `perform(on:)` returning typed observations with async/await. Prefer it on new iOS-18+ code; details in `references/vision-and-images.md`. For non-Core-ML Vision requests (text, faces, barcodes) use `vision-framework`.

<a id="checklist"></a>
## Correctness checklist

- [ ] Model is `.mlpackage` (ML Program) for float16 / Neural-Engine / iOS-18 features; `.mlmodel` only for legacy.
- [ ] `MLModel` loaded **once** with async `load(contentsOf:configuration:)`, reused — not re-created per prediction.
- [ ] `computeUnits` set **before** load; `.all` default, `.cpuOnly` for reproducible test assertions.
- [ ] Predictions run **off the main thread**; UI updates hop back to `@MainActor`.
- [ ] N inputs use **batch** (`predictions(from:)` + `MLArrayBatchProvider`), not a single-prediction loop.
- [ ] One `MLModel` instance is not shared across threads; concurrent work uses per-worker instances or a serializing actor/queue.
- [ ] Image inputs built from the model's `imageConstraint` (or routed through Vision); `imageCropAndScaleOption` matches training.
- [ ] Cancellation (`MLModelError.predictionCancelled`) handled, not logged as an error.
- [ ] Stateful models: one `MLState` per sequence, never shared concurrently.
- [ ] `MLComputePlan` used pre-ship to confirm ops land on the intended device (no silent CPU fallback).
- [ ] Runtime-downloaded models compiled off-main-thread, moved out of temp, integrity-checked before use.
- [ ] On-device updates target a `.mlmodelc` with `isUpdatable == true`; updated model persisted with `write(to:)`.
