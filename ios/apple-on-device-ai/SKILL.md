---
name: apple-on-device-ai
description: "On-device generative AI on Apple platforms (iOS 26+) — the Foundation Models framework (SystemLanguageModel.availability, LanguageModelSession, respond(to:)/streamResponse, @Generable + @Guide guided generation, the Tool protocol for tool-calling, instructions, GenerationOptions, and Guardrails), plus choosing among Core ML, MLX Swift, and llama.cpp as alternative local runtimes, and Apple Intelligence surface integration. Use when adding a private on-device chatbot/summarizer/classifier, doing structured LLM output or tool-calling with the system model, running your own LLM on Apple Silicon, or picking a local inference backend. For Swift Core ML model loading/prediction code use `coreml`; for OCR/vision use `vision-framework`; for tokenize/tag/embeddings/translation use `natural-language`; to expose actions to Siri/Apple Intelligence use `app-intents`."
---

# Apple on-device AI (iOS 26+)

Private, no-network generative AI on iPhone/iPad/Mac. This skill routes between the
four local runtimes and covers the **Foundation Models** framework in depth.

- **Core ML model loading/prediction, compute units, MLTensor, `.mlpackage`** → `coreml`.
- **OCR, barcode/face/text detection, image segmentation** → `vision-framework`.
- **Tokenization, POS/NER tagging, sentiment, word embeddings, on-device translation** → `natural-language`.
- **Expose app actions/entities to Siri, Spotlight, and Apple Intelligence** → `app-intents`.
- Fintech note: the system model runs **fully on-device** — no prompt or user data leaves the phone, which is what makes it usable for balances/transactions. Still treat model output as untrusted (see [Safety](#safety)).

## Contents
- [Choosing a runtime](#choosing)
- [Foundation Models: availability](#availability)
- [Sessions, respond & stream](#sessions)
- [Guided generation (@Generable / @Guide)](#generable)
- [Tool calling](#tools)
- [Generation options](#options)
- [Safety, guardrails & errors](#safety)
- [Context window & performance](#context)
- [Core ML / MLX Swift / llama.cpp](#alt-runtimes)
- [Apple Intelligence integration](#apple-intelligence)
- [Checklist](#checklist)
- References: `references/foundation-models.md`, `references/alt-runtimes.md`

<a id="choosing"></a>
## Choosing a runtime

| Runtime | Model | Best for | Cost / caveats |
|---|---|---|---|
| **Foundation Models** | Apple's built-in ~3B on-device LLM (powers Apple Intelligence) | Chat, summarize, classify, extract, tool-calling — general language tasks with **zero model download** and guided/structured output | Apple-Intelligence devices only (see availability); not customizable beyond instructions + optional LoRA adapters; text-focused |
| **Core ML** | Your converted model (`.mlpackage`) | Shipping a specific trained model — vision, audio, tabular, or a custom/quantized LLM — with Neural Engine acceleration | You convert & bundle the model; you own updates/size. See `coreml`. |
| **MLX Swift** | Any MLX/HF LLM you load | Running larger or newer open LLMs (Llama/Qwen/Mistral/Phi) on **Apple Silicon**, research, fine-tuning, custom sampling | GPU-heavy; large downloads; iPhone RAM limits model size; you manage weights |
| **llama.cpp** | GGUF quantized models | Max portability / a mature C++ stack, aggressive quantization (Q4/Q5), reuse across platforms | C/Obj-C++ bridging; you manage the binary, weights, and Metal build |

Decision order for a **language** feature: try **Foundation Models** first (no download, private, guided output); fall back to **MLX/llama.cpp** only when you need a specific/larger model or a device without Apple Intelligence; use **Core ML** when the task is a discrete trained model (vision/audio/custom). Always provide a non-AI fallback path for unsupported devices.

<a id="availability"></a>
## Foundation Models: availability

`import FoundationModels`. **Always gate on availability** — the model is absent on
older/ineligible hardware, when Apple Intelligence is off, or while assets download.

```swift
import FoundationModels

let model = SystemLanguageModel.default   // the general-purpose system model

switch model.availability {
case .available:
    // Safe to create sessions.
case .unavailable(.deviceNotEligible):
    // Hardware without Apple Intelligence support.
case .unavailable(.appleIntelligenceNotEnabled):
    // Ask the person to turn on Apple Intelligence in Settings.
case .unavailable(.modelNotReady):
    // Downloading / not ready yet — retry later; do not block UI.
case .unavailable(let other):
    // Unknown reason — degrade gracefully.
}
```

- `model.isAvailable` is a convenience `Bool` for a quick guard.
- In SwiftUI, read `SystemLanguageModel.default` and switch on `availability` to pick the UI (feature vs. explainer vs. hidden).
- Specialized models: `SystemLanguageModel(useCase: .contentTagging)` for a model tuned to emit tags/topics; the default use case is general text.

<a id="sessions"></a>
## Sessions, respond & stream

A `LanguageModelSession` is **stateful** — it retains the running transcript across calls.
`instructions` set the model's role/rules once; per-turn user input is the `prompt`.

```swift
let session = LanguageModelSession(
    instructions: """
        You are a concise financial assistant. Explain terms in plain language. \
        Never give personalized investment advice. Keep answers under 60 words.
        """
)

// One-shot text.
let response = try await session.respond(to: "What is an APR?")
print(response.content)   // String
```

Stream tokens for responsive UI. Each element of the async sequence is the **cumulative
snapshot** so far, not a delta:

```swift
let stream = session.streamResponse(to: "Summarize my spending this month.")
for try await partial in stream {
    liveText = partial.content   // replace, don't append — it's the full text so far
}
```

- `respond` / `streamResponse` also accept a **prompt builder** closure and `PromptRepresentable` values, so you can interleave text and your own types:
  ```swift
  let r = try await session.respond {
      "Summarize this transaction for the user:"
      transaction   // a type conforming to PromptRepresentable
  }
  ```
- `session.isResponding` is `true` while a turn is in flight — don't start a second request on the same session concurrently; serialize or use a fresh session.
- **Background work:** prefer non-streaming `respond(to:)` over `streamResponse` in the background to reduce the chance of `rateLimited` errors.
- Persist `session.transcript` to resume a conversation later: `LanguageModelSession(transcript: saved)`.

<a id="generable"></a>
## Guided generation (@Generable / @Guide)

Get **typed** output instead of parsing free text. `@Generable` derives a schema from your
Swift type and the framework constrains sampling to it; `@Guide` adds per-field descriptions
and constraints.

```swift
@Generable
struct ExpenseInsight {
    @Guide(description: "A short, friendly headline under 8 words.")
    var headline: String

    @Guide(description: "Spending category.")
    var category: Category

    @Guide(description: "Whole-dollar amount, non-negative.", .range(0...100_000))
    var amountUSD: Int

    @Guide(.count(3))                       // exactly three tips
    var tips: [String]

    @Generable
    enum Category: String {
        case dining, transport, shopping, bills, other
    }
}

let result = try await session.respond(
    to: "Summarize this month's dining spend.",
    generating: ExpenseInsight.self
)
let insight: ExpenseInsight = result.content   // fully typed, no JSON parsing
```

- `@Guide` constraints include `.count(_)` / `.minimumCount(_)`…`.maximumCount(_)` for arrays, `.range(_)` for numbers, `.anyOf([...])` and `.pattern(_)` (regex) for strings, plus a free-text `description`.
- Supported field types: `String`, `Bool`, `Int`, `Double`, arrays, other `@Generable` types, and `@Generable` enums (great for closed classification sets).
- **Streaming structured output:** `streamResponse(to:generating:)` yields `PartiallyGenerated` snapshots whose fields are optional and fill in progressively — bind them to UI as they arrive.
- Use `GenerationID` for a property when you need stable identity across partial updates of generated collections.

<a id="tools"></a>
## Tool calling

Conform to `Tool` to let the model call **your** code (fetch data, perform an action) mid-generation. The model decides when to call it and incorporates the `Output` into its answer.

```swift
struct AccountBalanceTool: Tool {
    let name = "get_account_balance"
    let description = "Look up the current balance for one of the user's accounts."

    @Generable
    struct Arguments {
        @Guide(description: "Which account to check.")
        let account: AccountKind
    }
    @Generable
    enum AccountKind: String { case checking, savings, credit }

    func call(arguments: Arguments) async throws -> String {
        let cents = try await ledger.balance(for: arguments.account)
        return "\(arguments.account.rawValue): \(Money.cents(cents).formatted())"
    }
}

let session = LanguageModelSession(
    tools: [AccountBalanceTool()],
    instructions: "Answer account questions. Use tools for any live balance."
)
let r = try await session.respond(to: "How much is in my savings?")
```

- `Arguments` must conform to `ConvertibleFromGeneratedContent` — the `@Generable` macro provides it. `Output` must be `PromptRepresentable` (`String` qualifies).
- `call(arguments:)` is `async throws` — do real I/O here (network, DB). Keep it fast; the model waits.
- The framework injects each tool's `name`/`description`/parameter schema into the session, so write them like documentation the model reads. Tool calls can run in **parallel** and the model may call a tool multiple times per turn.
- Make tools **read-mostly** or idempotent; never let a tool move money or mutate irreversibly without a separate user confirmation step outside the model loop.

<a id="options"></a>
## Generation options

Pass `GenerationOptions` to tune sampling per request:

```swift
let options = GenerationOptions(
    temperature: 0.3          // lower = more deterministic; good for extraction/classification
)
let r = try await session.respond(to: prompt, options: options)
```

- `temperature` (≈0–2): low for structured/factual tasks, higher for creative copy.
- `GenerationOptions` also exposes sampling controls (e.g. a `sampling` mode such as greedy or top-p/top-k) and a cap on response length — see `references/foundation-models.md` for the exact fields, which are evolving. Prefer low temperature + `@Generable` for anything a fintech UI displays as fact.

<a id="safety"></a>
## Safety, guardrails & errors

The system model applies **built-in guardrails** to prompts and output. Handle violations
and treat all model text as untrusted.

```swift
do {
    let r = try await session.respond(to: userText)
    render(r.content)
} catch let error as LanguageModelSession.GenerationError {
    switch error {
    case .guardrailViolation:
        // Prompt or output tripped safety filters — tell the user, offer to rephrase.
    case .exceededContextWindowSize:
        // Conversation too long — start a fresh session (see Context window).
    case .rateLimited:
        // Back off / switch to non-streaming; common for background work.
    default:
        // .unsupportedLanguageOrLocale, .assetsUnavailable, decoding failures, etc.
    }
}
```

- Guardrails default to `Guardrails.default`; `SystemLanguageModel(useCase:guardrails:)` lets you request a stricter configuration for sensitive input/output. Do not assume you can disable them.
- **Never trust output blindly** in a fintech context: don't execute tool side-effects, SQL, or navigation directly from generated text; validate against your own domain rules. Prompt-inject-hostile content (a transaction memo, a pasted message) is *data*, not instructions.
- Localize the "AI unavailable / rephrase" states; these are common, not edge cases.
- `LanguageModelSession.GenerationError` case names are beta and shift between OS releases — switch defensively with a `default` branch rather than exhaustively.

<a id="context"></a>
## Context window & performance

- The model has a **finite context window**; long conversations eventually throw `exceededContextWindowSize`. Recover by starting a new `LanguageModelSession`, optionally seeding it with a short summary of the old transcript (ask the model to summarize before you discard).
- **Prewarm** to cut first-token latency when you know a request is coming:
  ```swift
  session.prewarm()                                   // warm instructions/tools
  session.prewarm(promptPrefix: "Suggest a recipe using")  // also warm a stable prefix
  ```
- Reuse a session's stable **instructions + tools prefix** across turns so its KV cache is reused; put the variable part in the per-turn prompt.
- Keep instructions tight; every token in instructions/tools is recomputed if it changes.

<a id="alt-runtimes"></a>
## Core ML / MLX Swift / llama.cpp

When Foundation Models doesn't fit, pick a self-hosted runtime. Deep setup in `references/alt-runtimes.md`.

**Core ML** — for a discrete trained model you convert and bundle. Convert from PyTorch with
`coremltools` (`ct.convert(...)`, `ct.optimize` for palettization/quantization), producing an
`.mlpackage`; load and predict in Swift. **Full Swift-side loading, compute-unit config, and
`MLTensor` usage live in the `coreml` skill.**

**MLX Swift** — Apple's array framework for Apple Silicon; run open LLMs (Llama/Qwen/Phi) via
the `mlx-swift-examples` packages (`MLXLLM`, `MLXLMCommon`).

```swift
// SwiftPM: add https://github.com/ml-explore/mlx-swift-examples (products MLXLLM, MLXLMCommon)
import MLXLLM
import MLXLMCommon

let container = try await LLMModelFactory.shared.loadContainer(
    configuration: ModelRegistry.qwen2_5_1_5b   // model constants live in ModelRegistry
)
let text = try await container.perform { context in
    try MLXLMCommon.generate(
        input: try await context.processor.prepare(input: .init(prompt: "Hello")),
        parameters: .init(temperature: 0.6),
        context: context
    ) { _ in .more }
}
```
- Downloads weights from Hugging Face on first run — mind size vs. device RAM; prefer 4-bit quantized variants on iPhone. GPU-bound; verify thermals and memory on real hardware. APIs (`ModelRegistry` constants, `generate` signature) change between releases — pin a version.

**llama.cpp** — GGUF models via the C API bridged into Swift; best for aggressive quantization
and cross-platform reuse. Build with Metal enabled; bridge `llama.h` through a module map. See
`references/alt-runtimes.md` for the bridging + sampling loop outline.

<a id="apple-intelligence"></a>
## Apple Intelligence integration

Foundation Models is one piece; you can also plug into system Apple Intelligence surfaces
without running a model yourself:

- **App Intents** expose your actions/entities to Siri, Spotlight, Shortcuts, and Apple Intelligence — the primary way the assistant *acts on* your app. → `app-intents`.
- **Writing Tools** (rewrite/proofread/summarize) apply automatically to standard `UITextView`/`TextEditor`; customize behavior with the Writing Tools APIs. Content-heavy views can opt into affected ranges.
- **Genmoji / Image Playground** — offer image generation via `ImagePlayground` / the Genmoji APIs where a creative image is appropriate; not for factual fintech UI.
- **Smart replies / entity highlighting** surface automatically from well-structured content.

For most fintech apps the high-value integrations are **App Intents** (assistant actions) and
**Foundation Models** (in-app private summarize/classify/extract) — not image generation.

<a id="checklist"></a>
## Correctness checklist
- [ ] Gate every Foundation Models use on `SystemLanguageModel.default.availability`; ship a non-AI fallback for ineligible devices.
- [ ] `instructions` set once on the session; per-turn text goes in the `prompt`.
- [ ] Streaming consumers **replace** with each snapshot (`partial.content` is cumulative), not append.
- [ ] Prefer `@Generable` + `@Guide` for anything parsed/displayed — no ad-hoc JSON parsing of free text.
- [ ] Low `temperature` for extraction/classification/facts; reserve higher for creative copy.
- [ ] Tools are `async throws`, read-mostly/idempotent; money-moving actions require explicit user confirmation outside the model loop.
- [ ] Handle `guardrailViolation`, `exceededContextWindowSize`, and `rateLimited`; use a `default` branch (case names are beta).
- [ ] Treat all model output and any pasted/user content as untrusted data — never execute tool side-effects, queries, or navigation straight from generated text.
- [ ] Recover from context-window overflow by starting a fresh session seeded with a summary; `prewarm()` before expected requests.
- [ ] Don't run two concurrent requests on one session; check `isResponding`.
- [ ] For self-hosted runtimes (MLX/llama.cpp): pin package versions, prefer 4-bit quant on iPhone, and validate RAM/thermals on device.
- [ ] Core ML specifics (loading, compute units, MLTensor) → use `coreml`, not this skill.
