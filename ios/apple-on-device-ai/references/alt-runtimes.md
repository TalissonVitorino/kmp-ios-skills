# Alternative local runtimes — Core ML, MLX Swift, llama.cpp

Use these when Foundation Models doesn't fit: you need a specific/larger/newer model, a device
without Apple Intelligence, a non-language model, or aggressive quantization. Pin versions —
these ecosystems move fast.

## Core ML (pointer)

Core ML runs **your** converted model on CPU/GPU/Neural Engine. This skill only covers the
conversion side; **Swift-side loading, `MLModelConfiguration`/compute units, generated prediction
classes, `MLTensor`, and `VNCoreMLRequest` all live in the `coreml` skill.**

Convert from PyTorch/other with `coremltools` (Python, offline):

```python
import coremltools as ct
import torch

traced = torch.jit.trace(model, example_input)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=example_input.shape)],
    minimum_deployment_target=ct.target.iOS18,   # or newer
)
# Shrink for on-device: palettization / linear quantization.
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights,
)
config = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric"))
mlmodel = linear_quantize_weights(mlmodel, config)
mlmodel.save("Model.mlpackage")
```

- Ship the `.mlpackage`; Xcode compiles it to `.mlmodelc` and generates a typed class.
- For LLMs specifically, Core ML is workable but MLX/llama.cpp usually give a better
  quantization-and-KV-cache story on-device.

## MLX Swift

Apple's open array/ML framework for Apple Silicon. Run open LLMs via `mlx-swift-examples`.

- Packages: `github.com/ml-explore/mlx-swift` (core) and
  `github.com/ml-explore/mlx-swift-examples` (products `MLXLLM`, `MLXVLM`, `MLXLMCommon`,
  `MLXEmbedders`, …).
- Model constants moved from `ModelConfiguration` to **`ModelRegistry`**; loading moved to
  `LLMModelFactory.shared.loadContainer(configuration:)` (older `LLM.loadModelContainer` is
  deprecated). Verify against the release you pin.

```swift
import MLXLLM
import MLXLMCommon

let container = try await LLMModelFactory.shared.loadContainer(
    configuration: ModelRegistry.qwen2_5_1_5b        // or a custom ModelConfiguration(id:)
)

let output = try await container.perform { context in
    let input = try await context.processor.prepare(input: .init(prompt: "Explain APR."))
    return try MLXLMCommon.generate(
        input: input,
        parameters: GenerateParameters(temperature: 0.6),
        context: context
    ) { tokens in
        // Return .more to continue or .stop to end; stream tokens to UI here.
        .more
    }
}
```

- First run downloads weights from Hugging Face — gate on Wi-Fi, show progress, cache to disk.
- **iPhone RAM is the ceiling.** Prefer 3–4-bit quantized small models (1–4B). Test peak
  memory and thermals on the oldest target device; the OS will jetsam a runaway process.
- Custom model: build a `ModelConfiguration(id: "org/repo")` pointing at an MLX-format HF repo,
  or a local directory of weights + tokenizer.
- `MLXVLM` for vision-language, `MLXEmbedders` for embeddings, and the examples repo also has
  LoRA fine-tuning and Stable Diffusion targets.

## llama.cpp

Mature C/C++ inference for **GGUF** quantized models; best portability and quantization control.

- Bring in `llama.cpp` (build with Metal: `LLAMA_METAL=1` / the CMake Metal option) as a static
  library or SwiftPM/xcframework wrapper; expose `llama.h` to Swift via a module map / bridging
  header.
- Ship a `.gguf` (e.g. Q4_K_M) in the bundle or download it on first launch.

Outline of the Swift-facing loop (via the C API):

```c
// Pseudocode across the C boundary:
llama_backend_init();
llama_model *model = llama_model_load_from_file(path, model_params);
llama_context *ctx  = llama_init_from_model(model, ctx_params);   // set n_ctx, n_threads
// tokenize prompt -> llama_decode(ctx, batch) -> sample next token
// (llama_sampler_chain: top-k / top-p / temperature) -> detokenize -> repeat until EOS
llama_free(ctx); llama_model_free(model); llama_backend_free();
```

- Wrap this in an actor on the Swift side; run inference off the main thread and stream
  detokenized pieces back to `@MainActor` UI.
- API names in `llama.h` change between releases — pin a commit and re-check symbols after bumps.
- Same memory discipline as MLX: small quantized models on iPhone, validate on device.

## Picking between them

- **Language task, Apple-Intelligence device, want private + guided output, no download** →
  Foundation Models (see the main skill), not these.
- **Need a specific open LLM / newer weights / research / fine-tune on Apple Silicon** → MLX Swift.
- **Need max portability, smallest quant, or an existing GGUF pipeline** → llama.cpp.
- **A discrete trained model (vision/audio/tabular/custom)** → Core ML (`coreml` skill).
