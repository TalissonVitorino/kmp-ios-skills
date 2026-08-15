# Foundation Models — depth

`import FoundationModels`. Introduced in iOS 26; APIs marked beta evolve across releases —
verify symbol names against current Apple documentation before shipping.

## Availability, in full

```swift
let model = SystemLanguageModel.default

// Boolean fast path.
guard model.isAvailable else { showFallback(); return }

// Detailed reason for tailored UI.
switch model.availability {
case .available: break
case .unavailable(.deviceNotEligible):        // no Apple Intelligence hardware
case .unavailable(.appleIntelligenceNotEnabled): // user turned it off
case .unavailable(.modelNotReady):            // assets still downloading
case .unavailable(let other): _ = other       // future/unknown reasons
}
```

- Devices: Apple-Intelligence-capable hardware only (recent iPhone Pro / Apple-silicon iPad & Mac). Never assume presence.
- `.modelNotReady` is transient — poll/retry later, keep the feature discoverable but disabled.

## Specialized system models

```swift
// A model variant tuned for emitting topics/tags rather than prose.
let tagger = SystemLanguageModel(useCase: .contentTagging)

// Request stricter guardrails for sensitive input/output.
let strict = SystemLanguageModel(useCase: .general, guardrails: .default)
```

- `SystemLanguageModel.UseCase` selects a task-tuned variant; `.general` is the default.
- `SystemLanguageModel.Guardrails` configures content filtering; `Guardrails.default` is the baseline. Do not assume guardrails can be turned off.

## Sessions

```swift
// Fresh session with a role.
let session = LanguageModelSession(instructions: "You are ...")

// With tools.
let s2 = LanguageModelSession(tools: [MyTool()], instructions: "...")

// Rehydrate from a saved conversation.
let s3 = LanguageModelSession(model: .default, tools: [MyTool()], transcript: savedTranscript)
```

- `instructions` are the stable system prompt: role, rules, output constraints. Set once.
- `session.transcript` is the running history; persist and restore it to continue a chat.
- `session.isResponding: Bool` — one in-flight request per session; serialize or spin up another session for concurrency.

### respond / streamResponse overloads

- `respond(to: String, options:contextOptions:metadata:) async throws -> Response<String>`
- `respond(to:generating: T.self, ...) -> Response<T>` — guided/typed output.
- `respond(options:contextOptions:metadata:) { /* prompt builder */ }` — build a `Prompt` from text + `PromptRepresentable` values.
- `streamResponse(...)` mirrors each of the above, returning an async sequence of **cumulative** snapshots. For guided output the element is a `PartiallyGenerated` value with optional fields that fill in over time.
- `Response<Content>` exposes `.content` (the value) and transcript/metadata; grab `.content` for the result.

Background guidance: use non-streaming `respond` in the background — `streamResponse` is more
likely to hit `rateLimited` off the foreground.

## Guided generation details

```swift
@Generable
struct Receipt {
    @Guide(description: "Merchant name as printed.")
    var merchant: String

    @Guide(description: "ISO-4217 code.", .pattern("[A-Z]{3}"))
    var currency: String

    @Guide(.minimumCount(1))
    var lineItems: [LineItem]

    @Generable
    struct LineItem {
        var id: GenerationID          // stable identity across partial updates
        var label: String
        @Guide(.range(0...1_000_000))
        var cents: Int
    }
}

// Non-streaming typed result.
let receipt = try await session.respond(to: text, generating: Receipt.self).content

// Streaming partials (fields optional until filled).
for try await partial in session.streamResponse(to: text, generating: Receipt.self) {
    draft.merchant = partial.content.merchant    // may be nil early
}
```

`@Guide` options seen in Apple docs: `description`, `.count(_)`, `.minimumCount(_)`,
`.maximumCount(_)`, `.range(_)` (numeric), `.pattern(_)` (regex on strings), `.anyOf([...])`
(closed set). `@Generable` enums model closed classification sets cleanly.

## Tool protocol

```swift
protocol Tool<Arguments, Output>: Sendable {
    associatedtype Arguments: ConvertibleFromGeneratedContent
    associatedtype Output: PromptRepresentable
    var name: String { get }
    var description: String { get }
    var parameters: GenerationSchema { get }             // synthesized from @Generable Arguments
    var includesSchemaInInstructions: Bool { get }        // default true
    func call(arguments: Arguments) async throws -> Output
}
```

- Give `name` a stable machine identifier (`get_account_balance`) and `description` a clear
  natural-language "when to use me". The model reads these.
- `Arguments` is typically a nested `@Generable struct` (with `@Guide`d fields); the macro
  supplies `ConvertibleFromGeneratedContent` and the `parameters` schema.
- Tools may be invoked in parallel and multiple times per turn. Keep `call` fast and side-effect-light; gate irreversible actions behind explicit user confirmation outside the model.
- A tool can itself hold an `@Observable` state object if it needs to surface progress to UI.

## Generation options

```swift
let opts = GenerationOptions(temperature: 0.2)
```

- `temperature` is the main knob. `GenerationOptions` additionally carries sampling-mode and a
  maximum-response-length control; exact property names are in flux across betas — check current
  docs before pinning them. For factual/structured tasks: low temperature + `@Generable`.

## Errors (`LanguageModelSession.GenerationError`, beta)

Confirmed cases: `.guardrailViolation(_)`, `.exceededContextWindowSize(_)`, `.rateLimited(_)`.
Others reported across betas include unsupported-language/locale, unavailable-assets, and
decoding failures. Because names change, switch with a `default` fallback:

```swift
catch let e as LanguageModelSession.GenerationError {
    switch e {
    case .guardrailViolation:       offerRephrase()
    case .exceededContextWindowSize: restartSessionWithSummary()
    case .rateLimited:              backOffAndRetryNonStreaming()
    default:                        showGenericAIError()
    }
}
```

## Context window & KV cache

- Long transcripts throw `exceededContextWindowSize`. Strategy: summarize the old session with
  the model, discard it, seed a new `LanguageModelSession` with that summary.
- `session.prewarm()` warms instructions/tools; `session.prewarm(promptPrefix:)` also warms a
  stable prefix — call ~1–2s before the expected request.
- Keep the instructions + tools prefix identical across turns so the KV cache is reused; vary
  only the per-turn prompt.

## Custom adapters (advanced)

Apple supports training LoRA-style adapters for the system model for specialized tasks
(offline, via Apple's toolchain) and loading them through the framework. This is heavyweight —
prefer instructions + `@Generable` first; reach for an adapter only when prompt engineering
plateaus. Verify current adapter APIs and tooling against Apple docs before committing.
