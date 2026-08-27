# Multi-Engine Design

**Status:** draft — Phases 1–2 settled, Phase 3 onward expected to shift
**Last updated:** 2026-08-26 (revised after an independent design review; see §14)

This is a living document. Phase 1 and 2 are specified tightly enough to implement.
Phase 3 onward records intent and the decisions we know we owe ourselves, not a
contract — expect to revise it as earlier phases teach us things.

§14 records which review findings were accepted and which were not, so the reasoning
does not have to be re-litigated.

---

## 1. Goal

Mochi should support several independent image-generation backends side by side.
Each one brings its own model list, its own set of meaningful options, and its own
metadata contract. Selecting a backend filters the model picker and reshapes the
sidebar so only options that backend actually honors are shown.

Backends in scope, in rough order of intended arrival:

| Backend | Kind | Notes |
|---|---|---|
| Core ML Stable Diffusion | local | exists today; fixed input size per model, ControlNet, schedulers |
| Iris (FLUX.2 Klein, Z-Image-Turbo) | local | exists today; no ControlNet, pinned step count and scheduler |
| OpenAI image generation | hosted | model-derived option set, no step progress or previews |
| Draw Things MediaGenerationKit | local + LAN + cloud | see §13 for maturity and licensing findings |

## 2. Terminology

We use **Engine** in both code and UI.

Rejected alternatives:

- *Provider* implies a vendor with an account. That fits OpenAI but reads oddly for
  "Core ML Stable Diffusion," which is a runtime, not a supplier.
- *Pipeline* and *Generator* are already taken in this codebase (`GenerationPipeline`,
  `ImageGenerator`) and both are being reshaped by this work.
- *Backend* is accurate in code but nobody wants a UI picker labelled "Backend."

A second axis is worth keeping distinct from the engine itself:

**Connection** — how we reach the engine: in-process, a LAN host, or an API account.
This is where API keys, hostnames and per-engine paths live. Keeping it separate avoids
"Draw Things" and "Draw Things Remote" becoming sibling entries in the engine picker.
Connection is not modelled in Phase 1; it arrives with per-engine settings in Phase 3
and only really earns its keep in Phase 5.

## 3. What already exists

More of the seam is in place than a first read suggests:

- `MochiModelConfig` ([Model/MochiModel.swift](Mochi%20Diffusion/Model/MochiModel.swift))
  already pairs capabilities with a per-model `metadataFields` set.
- `MetadataField` already lets each model declare its own metadata contract, and the
  import path tracks "what was actually present" separately, so generated and imported
  images share one interpretation path.
- `GenerationCapabilities` exists as an `OptionSet`. It is consumed only by
  [Views/JobQueueView.swift](Mochi%20Diffusion/Views/JobQueueView.swift); the sidebar
  ignores it entirely. `AGENTS.md` already lists aligning the sidebar to it as a known gap.
- The project is already in Swift 6 language mode with complete concurrency checking, and
  the principal services are actors. The remaining concurrency work (§11) is hardening,
  not migration.

So this work is largely *finishing* a refactor that was started, plus one genuinely new
axis: hosted generation over the network.

## 4. What blocks adding a third engine

Four closed sum types that must be edited in lockstep for every new engine:

1. `GenerationPipeline` — an enum of `.sd` / `.iris` with roughly ten switch-based
   accessors (`mlComputeUnit`, `controlNets`, `reduceMemory`, `effectiveStepCount`, …).
   Every accessor is a question a hosted engine has no answer to.
   ([Support/GenerationRequest.swift](Mochi%20Diffusion/Support/GenerationRequest.swift))
2. `PipelineModelAdapter` — restates the same taxonomy a second time.
   ([Support/GenerationController.swift](Mochi%20Diffusion/Support/GenerationController.swift))
3. Generator selection — `switch request.pipeline` with all generators eagerly held as
   stored properties. ([Support/GenerationService.swift](Mochi%20Diffusion/Support/GenerationService.swift))
4. Model discovery — a hard-coded sniffing chain over a single directory that throws
   `noModelsFound` globally rather than per engine.
   ([Support/ModelRepository.swift](Mochi%20Diffusion/Support/ModelRepository.swift))

And three structural mismatches:

- **`MochiModel.id` is a `URL`.** Hosted models have no URL.
- **`GenerationRequest` is a flat 23-field struct** merging every engine's options.
  Quality, aspect ratio, moderation and LoRAs would each widen it further.
- **`ConfigStore` is a flat `@AppStorage` bag** with a single `prompt`/`steps`/`width`/
  `height` for everything, and a verbose `access`/`withMutation` pair per key. It cannot
  express per-engine values or dynamic keys.

## 5. Target architecture

### 5.1 Identity

```swift
nonisolated struct EngineID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String   // "coreml-sd", "iris", "openai"
}

nonisolated struct ModelID: Hashable, Codable, Sendable {
    let engine: EngineID
    let key: String   // local: path relative to that engine's model dir
                      // hosted: the API model name, e.g. "gpt-image-1"
}
```

`ModelID` must be `Codable` — it is persisted as the per-engine model selection.
Using a path *relative* to the engine's model directory means moving or renaming the
models folder does not orphan the selection.

Because `ModelID.key` is persisted data, its normalization rules need to be specified and
tested rather than left to whatever `URL` happens to do:

- Reject keys that escape the configured root (`../`).
- Decide and pin symlink policy — resolve, or preserve as written.
- Decide case sensitivity explicitly, given a case-insensitive default filesystem.

### 5.2 Models

`MochiModel` becomes `EngineModel`:

```swift
nonisolated protocol EngineModel: Identifiable, Sendable {
    var id: ModelID { get }
    var name: String { get }
    var url: URL? { get }                        // nil for hosted models
    var constraints: OptionConstraints { get }
    var metadataFields: Set<MetadataField> { get }
    var promptTokenLimit: Int? { get }
}
```

`tokenizerModelDir` comes off the shared protocol — it is an Iris/SD implementation
detail and does not belong in a contract a hosted engine has to satisfy. It moves onto
those engines' own concrete model types, which their own code can see.

### 5.3 Engines: immutable descriptor, stateful runtime

The engine is split into two roles rather than one protocol. The UI reads constraints and
display names constantly; forcing every sidebar lookup through an actor hop to a type that
also owns loaded pipelines would be both slow and hard to reason about.

**Descriptor / planner** — immutable, `Sendable`, cheap to read from the main actor:

```swift
nonisolated protocol GenerationEngineDescriptor: Sendable {
    associatedtype Model: EngineModel
    associatedtype Payload: Sendable

    static var id: EngineID { get }
    var displayName: String { get }

    func availability(_ settings: EngineSettings) async -> EngineAvailability
    func discoverModels(_ settings: EngineSettings) async throws -> [Model]

    /// Synchronous, deterministic, side-effect free.
    func plan(draft: GenerationDraft, model: Model, settings: EngineSettings) throws -> Payload
}

nonisolated enum EngineAvailability: Sendable {
    case ready
    case needsConfiguration(String)   // user-facing reason, shown in the picker
    case unreachable(String)
}
```

**Runtime** — stateful, owns loaded pipelines, caches, the active session, and cancellation.
Its shape is specified in §11.2 because it is inseparable from the concurrency work.

`plan` is the important addition. Today the UI's raw values travel all the way into the
generator, which then quietly overrides some of them. `plan` resolves a `GenerationDraft`
(the UI's current values) against the model's constraints *before* enqueue and produces an
engine-typed payload. After `plan`, nothing is renegotiated — in particular, generators
must not silently reinterpret values, and metadata is written from the resolved plan rather
than reconstructed independently in each generator.

No network access, pipeline loading, or mutable cache state in `plan`. Anything that needs
those belongs in `availability`, `discoverModels`, or the runtime.

### 5.4 Requests

```swift
nonisolated struct GenerationRequest: Sendable, Identifiable {
    let id: UUID
    let modelID: ModelID
    let displayName: String
    let core: CoreOptions          // prompt, resolved size, seed, count — what the queue UI shows
    let payload: any Sendable      // engine-typed; downcast once, inside AnyGenerationEngine
    let output: OutputSettings     // imageDir, imageType
    let metadataFields: Set<MetadataField>
}
```

**Known cost:** `payload: any Sendable` gives up compile-time checking at the queue
boundary. It is contained to a single downcast in the erasure wrapper. The alternative —
making `GenerationService` generic over the engine — is worse, because the queue is
heterogeneous by definition.

The erasure wrapper must:

- Preserve the pairing between engine ID, concrete model type, and payload type.
- Validate the payload *before* mutating queue or runtime state.
- Report a mismatch as an internal invariant failure naming the request and engine IDs —
  never as a user configuration error.
- Never expose the opaque payload to the UI or gallery.

`CoreOptions` exists so the queue and job list never touch `payload`. `JobQueueView`
currently reaches into pipeline internals; it should read `core` and `metadataFields` only.

### 5.5 Registry and discovery

An `EngineRegistry` actor owns the engine list and discovery:

```swift
func discoverAll() async -> [EngineID: Result<[any EngineModel], Error>]
```

Per-engine, failure-isolated. A missing OpenAI key or an unreachable LAN host must not
wipe the local model list — today `noModelsFound` throws globally and takes everything
with it.

**Engines discover independently. There is no ownership arbitration.** Each engine scans
its own configured source and applies only its own recognition rules. If both Core ML SD
and Iris recognize the same directory, both return a model, and the two remain distinct
because `ModelID` carries the `EngineID`. The registry aggregates without cross-engine
de-duplication, and registration order affects presentation order only — never ownership
or validity.

An earlier draft proposed a per-engine `claims(url:)` with the registry breaking ties by
registration order. That was wrong: it couples engines that should know nothing about each
other, and it makes a model resource exclusive for no reason. Model resources are not
exclusive.

One practical consequence: after migration both local engines point at the same directory
by default (§7), so each folder-monitor event triggers two independent scans of the same
tree. Coalesce discovery per directory, or debounce at the registry, rather than letting
scan cost scale with engine count.

## 6. Constraints, not capability booleans

A boolean `.stepCount` flag cannot express "this model's size is fixed at 512×768,"
"steps are pinned to 4," or "this engine takes aspect ratios rather than pixel sizes."
The `OptionSet` is replaced by a per-option constraint struct:

```swift
nonisolated struct OptionConstraints: Sendable {
    var negativePrompt: Supported
    var size: SizeConstraint                     // .pinned([CGSize]) / .freeform(range, step) / .aspectRatios([...])
    var steps: NumericConstraint                 // .unsupported / .pinned(Int) / .range(ClosedRange<Int>)
    var guidanceScale: RangeConstraint<Double>
    var scheduler: ChoiceConstraint<Scheduler>
    var startingImage: StartingImageConstraint   // carries an optional strength range
    var controlNet: ControlNetConstraint
    var quality: ChoiceConstraint<QualityID>
    var numberOfImages: NumericConstraint
}
```

Constraints resolve **per model**, not per engine — Core ML SD input sizes are a property
of the individual model.

Choice constraints carry **stable IDs plus a separate display label**. No localized or
display string may be used as a persisted or wire value for quality, scheduler, aspect
ratio, or anything similar.

Three distinct presentations, and the distinction should stay visible:

- **Unsupported** — the control is hidden.
- **Pinned** — the control may be shown disabled, when seeing the effective value helps
  explain what the engine will actually do.
- **Editable** — validated and normalized at `plan` time, before enqueue.

This is what lets us delete `IrisModelFamily.effectiveStepCount` and
`effectiveScheduler`. Today the app accepts a user-entered step count, ignores it, and
substitutes the real value when writing metadata — so the sidebar shows one number and
the image records another. With constraints the value is correct before enqueue and the
UI stops lying. The same change removes the `as? SDModel` downcasts in
[Views/SidebarControls/SizeView.swift](Mochi%20Diffusion/Views/SidebarControls/SizeView.swift)
and the model-name-prefix orientation hack in `GenerationController.setSize`.

Engine-specific long-tail options (Draw Things will have many) are deferred to Phase 7 as
a declarative `[OptionSpec]` bag. We deliberately do *not* start there: a fully
declarative sidebar would cost us `SizeView`'s swap button, the ControlNet image wells,
and straightforward localization.

## 7. Persistence and migration

```
SelectedEngine                 -> EngineID
Engine.<id>.SelectedModel      -> ModelID (encoded)
Engine.<id>.ModelDir           -> String
Engine.<id>.Options            -> JSON blob of engine-specific values
```

Shared, and deliberately **not** namespaced: `Prompt`, `NegativePrompt`, `Seed`,
`NumberOfImages`, `ImageDir`, `ImageType`. A prompt should survive an engine switch.

`Width`/`Height` become per-engine, because Core ML SD pins them per model while other
engines offer their own fixed sets.

`ConfigStore`'s one-property-per-key pattern cannot express dynamic keys, so add an
`@Observable EngineSettingsStore` reading and writing `UserDefaults` under a prefix.
`ConfigStore` keeps the genuinely global values.

### Migration

This is the highest-risk small detail in the whole plan. The existing `Model` key holds a
`URL`; `ModelDir` and `ControlNetDir` hold user-chosen folders. On first launch after
upgrade:

1. Read the legacy `Model` URL and classify it with a **frozen one-time compatibility
   classifier** that reproduces today's sniff order (Iris/Klein first, then Core ML SD).
2. Write `SelectedEngine` and `Engine.<id>.SelectedModel` accordingly.
3. Seed **both** local engines' `ModelDir` from the legacy `ModelDir`, since they
   currently share a directory.
4. If the URL no longer resolves, fall back to the first engine with any model, exactly
   as `loadModels` does today.

The classifier is migration-only code with a single caller, and it is deleted once the
migration window closes. It must not become a permanent registry rule — the registry
itself does no arbitration (§5.5).

Get this wrong and every existing user re-picks their folders on upgrade.

## 8. UI

The sidebar gains an explicit engine picker directly above the model picker, since the
engine filters the model list:

```
Prompt
Engine   [picker + availability badge]
Model    [picker, filtered to the selected engine]
… constraint-driven controls …
```

The engine picker lists **all registered engines, including unconfigured ones**, with the
reason inline from `EngineAvailability` ("No models found", "API key required"). Hiding
unavailable engines would make OpenAI undiscoverable — nobody finds a backend that only
appears once it is already configured.

Empty-engine case: engine selected, no models available → disable Generate and show the
reason. Do not silently fall back to another engine's model.

`Views/SettingsView.swift` grows a per-engine section for paths, keys, hosts, and compute
units. Exact shape TBD in Phase 3 — likely a list of engines rather than the current
fixed tabs.

## 9. Metadata

### 9.1 The codec is broken today, and it crashes

Two defects in the current export/import path, both in scope **before** the metadata
contract is widened for more engines:

**Truncation.** `SDImage.metadata(including:)` joins pairs with `"; "` and
`parseMetadataInfo` splits on the same sequence, with no escaping. A prompt like
`"a cat; wearing a hat"` is silently truncated on import. `Input Images` has the same
problem one level down, using `", "` to separate filenames that may contain commas.

**A hard crash.** In `parseMetadataInfo`
([Support/Functions.swift](Mochi%20Diffusion/Support/Functions.swift)):

```swift
let valueIndex = field.index(separatorIndex, offsetBy: 2)
guard valueIndex <= field.endIndex else { continue }
```

When a *recognized* key is followed by a bare colon at the end of a field — caption
`"Include in Image: a cat; Model:"` — `index(_:offsetBy: 2)` runs past `endIndex` and
traps with "String index is out of bounds". The `guard` on the next line is dead code: the
trap happens while constructing the index it is meant to validate. Verified against
Swift 6.3.3.

This is reachable from any imported PNG, since the caption is arbitrary third-party data.
It is a crash on untrusted input, so the codec fix is a bug fix that should land ahead of
the engine work rather than as part of it.

Hosted engines make this urgent for a second reason: OpenAI returns a *revised prompt*
written by a model, and model-written prose contains semicolons and colons routinely.

### 9.2 Codec fix (implemented)

`MetadataCodec` ([Support/MetadataCodec.swift](Mochi%20Diffusion/Support/MetadataCodec.swift))
owns both directions. Version 2 of the format:

```
Metadata Version: 2
Include in Image: a cat; wearing a hat
Exclude from Image: blurry\nlow quality
Model: sd-1.5_512x512
Input Images: one.png
Input Images: two.png
Generator: Mochi Diffusion 6.0
```

- **Fields are separated by newlines**, one `Key: value` per line.
- **Values escape** `\` as `\\`, LF as `\n`, and CR as `\r`. Semicolons and colons
  need no escaping at all, so ordinary prose prompts are untouched.
- **Escaping happens at the unicode-scalar level, not the character level.** `"\r\n"` is a
  single Swift `Character` — one extended grapheme cluster — so a character-by-character
  switch silently passes CRLF through unescaped, which then splits the caption apart on
  import. The adversarial test matrix caught this; it is not obvious from reading the code.
- **Arrays repeat their key** rather than using a comma sub-format, so a filename may
  contain any character.
- **The version marker is written first**, so detection never has to infer the format from
  the shape of the rest of the caption. That matters because a version 2 value may
  legitimately contain `"; "`, which version 1 used as its field separator.
- **Absence of the marker means version 1**, parsed with the legacy rules: split on
  `"; "`, no unescaping, comma-separated input images.
- **A version higher than we know is read with version 2 rules** rather than rejected, so
  a future field never costs us the fields we do understand.
- **Malformed input never traps.** Key/value splitting uses only in-bounds index
  arithmetic.
- The app version continues to travel in `Generator:` and still gates import through
  `isSupportedGeneratedVersion`. The format version is deliberately separate.

#### Accepted costs of newline separation

Chosen knowingly over keeping `"; "` with escaped semicolons:

- **Images written from now on are invisible to older Mochi builds.** An older parser
  splits on `"; "`, so a version 2 caption collapses into one field, never yields a
  `Generator:` key, fails the version gate, and returns nil — and
  [Support/ImageRepository.swift](Mochi%20Diffusion/Support/ImageRepository.swift) skips
  nil records entirely. The image does not appear in the gallery at all. This affects
  downgrades and folders shared with users on older versions.
- **Multi-line prompts now carry literal `\n` escapes** in the caption. The prompt field
  is a `TextEditor`, so multi-line prompts are ordinary. They round-tripped by accident
  under version 1 because newlines were not the separator; under version 2 they work only
  because the codec escapes them. Pinned by a test.

In exchange the format is materially cleaner to read for single-line prompts and needs no
semicolon escaping, and the array sub-format problem disappears.

### 9.3 New fields

- `.engine` — engine identity
- `.modelKey` — the engine-qualified model key, alongside the existing human-readable
  `.model` name for display
- `.aspectRatio` — for engines that express geometry that way
- `.revisedPrompt` — OpenAI rewrites prompts and returns the revision
- `.host` — for remote generation

Existing images carry no `Engine` key, and its absence must mean "legacy, infer from the
other fields," never "corrupt."

### 9.4 `setModel(_ name:)` across engines

`copyModelToPrompt` matches models by display-name string. With multiple engines:

- Prefer an explicit engine ID or model key in the metadata when present.
- Otherwise search the **currently selected engine first**.
- If there is no match in the current engine and exactly one other engine matches, switch
  to it and make the switch visible.
- If several engines match an unqualified legacy name, do not switch.

The middle case is a UX judgement, not a rule: refusing to switch when there is exactly
one unambiguous match makes "Copy model to prompt" appear to do nothing at all, which is
worse than switching. Revisit with the picker in front of us.

## 10. Phases

Confidence labels are honest signals about how much these should be trusted.

| Phase | Scope | User-visible | Confidence |
|---|---|---|---|
| 0 | Test target (see §12) | none | done |
| 1 | `MetadataCodec`: fix the import crash and the separator defect; versioned encoding | crash fix | **done** |
| 2 | Engine descriptor/registry, `EngineID`/`ModelID`, independent discovery, migration | none | settled |
| 3 | Engine runtime and session boundaries; request-scoped cancellation; remove serialization-assumption `@unchecked Sendable` | more reliable cancel | settled |
| 4 | Constraints model; `plan` as the sole resolution point; sidebar driven from constraints | unsupported controls hide; step count stops lying | settled |
| 5 | Engine picker, per-engine settings store, Settings restructure | the feature as described | likely |
| 6 | OpenAI engine: Keychain, indeterminate progress, richer errors | first hosted engine | sketch |
| 7 | MediaGenerationKit prototype, then local/remote integration | | direction only |
| 8 | Declarative long-tail options | | direction only |

### Release gating

Every phase must leave `main` green — building, all tests passing, `swift format lint`
clean — and must be reviewable on its own. That is not the same as every phase being a
release.

- **Phases 1 and 4 are independently releasable and should ship when ready.** The codec
  crash is a bug fix. The constraint-driven sidebar is a real user-visible improvement on
  its own: today Klein models show a ControlNet section that does nothing, a guidance
  slider that is ignored, and an editable step count that is silently overridden. Shipping
  that before any new engine exists also gets the constraint model in front of real usage
  while it is still cheap to change.
- **Phases 2 and 3 are invisible internally** and carry no release of their own.
- **The engine picker (Phase 5) should not ship with only one engine behind it.** It
  releases together with Phase 6, or with Phase 5 plus the two existing engines if the
  picker demonstrably improves the experience on its own.

The review proposed treating all phases as one unreleasable multi-engine change gated on
a new engine working end to end. That bundles a crash fix, a concurrency refactor and a
UI feature into a single long-lived branch, which is the shape that produces six-month
integration debt. The narrower gate above gets the same safety.

### Definition of done

The multi-engine foundation is complete when:

- Engines discover models independently; no ownership arbitration or sniffer precedence
  remains anywhere.
- Every persisted model identity is engine-qualified.
- Legacy preferences migrate without losing configured folders or silently changing the
  user's effective model selection.
- Sidebar controls derive from the selected model's constraints.
- Requests carry resolved values, and no generator silently overrides them.
- One engine's discovery, configuration, or runtime failure does not disable another.
- No `@unchecked Sendable` remains whose justification is an external serialization
  assumption (§11.3).
- Cancellation is request-scoped and stays responsive during synchronous local generation.
- Stale progress or preview events cannot reach a later request.
- Long-lived observation tasks and streams terminate with their owners.
- Arbitrary metadata strings and arrays round-trip losslessly under a versioned codec,
  malformed input never traps, and legacy images stay readable.
- The test target defaults to nonisolated, with `@MainActor` only where required.
- The project builds, all tests pass, and `swift format lint -p -r ./` is clean.

## 11. Concurrency

### 11.1 Baseline

Already in place: Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY = complete`,
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, actors for `GenerationService`,
`ModelRepository`, `ImageRepository` and `FolderMonitorService`, and `Sendable` domain
values. This is hardening, not a migration.

### 11.2 An actor alone does not make cancellation work

Core ML and Iris generation calls are synchronous and long-running. If an engine runtime
actor executes the whole call on its own executor, `cancel()` cannot enter the actor until
generation returns — cancellation would silently stop working. This is the reason the
current generators are `@unchecked Sendable` with a lock around one Bool.

Runtime shape:

- A runtime actor owns admission, pipeline/session state, and the current request.
- It starts one **request-scoped session** on an execution context suited to the blocking
  API.
- The session owns or exclusively borrows all non-`Sendable` pipeline and C context state.
- A small thread-safe cancellation token is readable synchronously from Core ML progress
  callbacks and writable without waiting on the blocked runtime.
- `cancel(requestID:)` verifies it is cancelling the session it intends to.
- Completion returns to the runtime actor, which tears down that exact session before
  admitting another.

Unstructured tasks are not used to silence isolation errors. Any that remain need an
explicit owner, cancellation path, and join point.

### 11.3 `@unchecked Sendable` policy

The two generator conformances
([Support/SDImageGenerator.swift](Mochi%20Diffusion/Support/SDImageGenerator.swift),
[Support/IrisFluxKleinImageGenerator.swift](Mochi%20Diffusion/Support/IrisFluxKleinImageGenerator.swift))
are justified today by a comment asserting that `GenerationService` serializes generation.
That is an invariant the compiler cannot see and the per-engine-lane work would silently
break.

The rule is therefore **not** "zero `@unchecked Sendable`". It is:

> No `@unchecked Sendable` justified by an external serialization assumption.

`@unchecked Sendable` remains the right tool at a synchronous C callback boundary where
the C API genuinely offers no safe alternative — as long as the comment states the
invariant the *type itself* enforces, not one some other type is assumed to provide.
The Iris C library exposes process-global callback slots with no caller-supplied context
pointer, so its runtime must enforce single-flight explicitly; a checked wrapper that
lies would be worse than an honest unchecked one.

### 11.4 Iris callback routing

The C callbacks create unstructured Swift tasks that later reach a singleton
`FluxStepImageBridge`. A callback emitted near teardown can be scheduled after the bridge
has been reconfigured for the next request, delivering a stale event to the wrong job.

Callbacks must synchronously snapshot request-scoped routing state, or carry a
session/epoch token checked before delivery.

### 11.5 Generation events

The current generator protocol has four separate async callbacks — `onState`,
`onProgress`, `onPreview`, `onResult`. They work, but callback lifetime, ordering, and
stale-event rejection all have to be reasoned about four times, and every one of them is
a place an Iris callback can arrive late (§11.4).

The endpoint for the runtime refactor is one stream per session:

```swift
nonisolated enum GenerationEvent: Sendable {
    case state(GenerationStatus)
    case progress(GenerationProgress)
    case preview(CGImage)
    case result(GenerationResult)
}
```

Every event is associated with a request/session ID, either on the event or on the session
that produced it, so a late event from a finished request is dropped at one checkpoint
instead of four. State and preview events may use bounded newest-value buffering; results
must never be dropped, because a dropped result is a lost image.

This is not required for the identity work in Phase 2 and should not gate it. It belongs
with Phase 3, and it is also what makes indeterminate hosted progress (§13.1) natural
rather than a fifth special case.

### 11.6 Observation task lifecycle

`GenerationController`'s update/result loops iterate infinite streams and keep consuming
after the controller is gone. The folder-monitor loops in both `GenerationController` and
`GalleryController` promote `self` to a strong reference before entering an infinite loop,
so task and controller retain each other until something explicitly cancels.

Provide one explicit shutdown path per controller that cancels every owned observation and
debounce task. Loops exit on cancellation; stream termination removes its continuation
promptly.

For latest-state streams such as queue snapshots, use bounded newest-value buffering so a
suspended UI cannot accumulate obsolete snapshots. Results need reliable delivery and a
different policy — a dropped result means a lost image.

### 11.7 Concurrency is an engine property

Phase 6 keeps the globally serial queue. If concurrency is added later, model it as
runtime capacity rather than baking lanes into the registry protocol:

- Iris local: one session, because of process-global C state.
- Core ML: one session until pipeline thread-safety is established.
- OpenAI: possibly several, subject to cancellation, cost and rate limits.
- MediaGenerationKit: determine from documented guarantees and observed behavior.

### 11.8 Effort

Unestimated. The dominant uncertainty is runtime validation of cancellation and callback
teardown against real Core ML and Iris generations, which is not predictable from reading
code. Deliberately no day figure here — one would get quoted back as a commitment.

## 12. Tests

The Swift Testing target exists and passes: 154 test-case executions, one remaining
`withKnownIssue` (`IrisModelFamily.fallbackDisplayName` is unreachable), `swift format
lint` clean. It uses current idioms correctly: `@Test`, parameterized `arguments:`,
`#expect`/`#require`, per-test temporary directories, and no XCTest.

Changes needed before it becomes the contract for the new architecture:

0. **Still outstanding.** `MetadataCodecTests` is declared `nonisolated` as a local
   workaround, because `@Test(arguments:)` cannot read a main-actor-isolated `static let`
   from its macro expansion. That is a symptom of item 1, not a fix for it.

1. **Drop the Main Actor default for the test target.** It currently inherits
   `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` from the app target, which serializes pure
   domain tests onto the main actor and hides exactly the actor-crossing problems §11 is
   about. Default the target to nonisolated and annotate `@MainActor` only where a suite
   touches genuinely main-actor types (`MetadataRoundTripTests` currently qualifies).
2. **Delete `kleinTakesPrecedenceOverCoreML`.** It pins sniffer precedence, which §5.5
   removes. Replace it with a test that both engines can expose the same directory under
   distinct `ModelID`s.
3. **Fix the sharded Klein fixture or rename it.** It writes an index naming a two-shard
   layout but creates one shard. Production `hasSafetensorWeights` intentionally checks
   only for an index plus any matching shard, and that shallowness is defensible for a
   *picker* — parsing every index for every model on every folder-change event would put
   real I/O on the discovery path. So rename the fixture to say it is minimal, or make the
   index name one shard. Deep validation belongs at load time, where failure is already
   handled — not in discovery.
4. **Rename or extend "Every required Klein config file is required."** It parameterizes
   5 of the 12 required paths. Either drive it from the shared fixture list or drop the
   word "every".
5. ~~**Turn the separator known-issue into a passing parameterized test.**~~ Done in
   Phase 1: `MetadataCodecTests` covers `"; "`, bare semicolons, backslashes, colons, key-lookalike strings, newlines,
   Unicode, empty strings, filenames containing commas and semicolons, legacy unescaped
   captions, and unknown future keys alongside escaped known values, plus the crash case
   from §9.1 and a golden encoded-shape assertion in both the codec and image suites.

New behavioral tests to add before the old pipeline switches are deleted:

- Two engines may expose the same underlying local resource under distinct IDs.
- One engine's discovery failure does not erase another's models.
- `ModelID`s stay stable when the configured local root moves.
- `plan` resolves pinned values and rejects unsupported ones before enqueue.
- A payload can only be executed by its originating engine.
- Cancellation applies only to the matching request.
- Stale callbacks from a completed request are ignored.
- Availability distinguishes unconfigured, unreachable, and ready.
- Stream termination removes subscriptions and monitors.
- Queue ordering is deterministic.

Use `confirmation` for callback-style events, or consume event streams with bounded test
helpers. No timing-based sleeps.

## 13. Hosted and third-party engines

### 13.1 What hosted generation breaks

The app is **not** sandboxed (`MochiDiffusion.entitlements` is empty), so no network
entitlement is required. Everything else needs work:

- **No progress or preview frames.** `GenerationState.Progress` and the `onPreview`
  stream assume step-by-step denoising. An indeterminate mode is needed.
- **Cancellation differs.** Cancelling local waiting may not cancel remote computation or
  avoid a charge. The UI wording must be honest about that.
- **API keys belong in the Keychain**, and out of persisted requests, logs, metadata, and
  test fixtures.
- **Distinct error classes**: content-policy refusal, authentication failure, rate limit,
  transient service error. `GeneratorError` is currently a small filesystem-shaped enum.
  A refusal must read as a message, not as a crash.
- **LAN discovery** needs `NSLocalNetworkUsageDescription` and Bonjour service types on
  macOS 15+, even unsandboxed.

### 13.2 OpenAI

Do not hard-code an assumption about aspect ratios versus concrete sizes; the constraint
vocabulary in §6 covers both, and model capabilities change independently of our release
schedule. Treat model IDs and model-specific options as API-derived engine data where
practical, and revalidate allowed models, sizes, quality levels, output formats and edit
inputs against current official documentation at implementation time.

### 13.3 MediaGenerationKit

Verified 2026-08-26 against `drawthingsai/media-generation-kit`:

- **License: LGPL-3.0.** Mochi Diffusion is GPLv3, and LGPL-3.0 links cleanly into a
  GPLv3 work, so there is **no additional licensing obligation** here beyond what GPLv3
  already imposes. This does not need further legal review.
- **Maturity is the actual risk.** The repository was created 2026-03-30, last pushed
  2026-07-14, has ~25 stars and two tags. That is a very young package with minimal
  external adoption, and its installation guidance pins a specific revision. Depending on
  it for a shipping feature carries genuine churn risk — pin a revision, and expect to
  track breaking changes.

Reported capabilities to verify in the prototype: local pipelines, LAN remote generation
by host and port, Draw Things cloud compute, previews in progress callbacks, and local
model catalog helpers. Remote *model listing* is reportedly absent from the public API, so
the initial remote UI may need the user to enter a known model identifier or reuse a local
catalog.

Keep "Draw Things" as **one** engine with a Connection setting (§2), not several sibling
entries.

Do not assume in advance that MediaGenerationKit replaces Core ML SD or Iris. Overlap is
likely; preserving the existing runtimes as separate engines stays valid where model
formats, performance, or user expectations differ.

## 14. Review disposition

An independent review of the first draft was folded in here and the review document
retired, so this section is the only surviving record of it. Claims were verified against
the code where checkable.

**Accepted:**

- Independent per-engine discovery; `claims(url:)` and registration-order precedence
  removed (§5.5). The review was right — with `EngineID` in `ModelID`, exclusivity buys
  nothing and couples engines.
- Frozen one-time migration classifier instead of a permanent registry rule (§7).
- Descriptor/runtime split; `plan` synchronous and side-effect free (§5.3).
- Erasure-wrapper obligations, including payload validation before state mutation (§5.4).
- Stable IDs rather than display strings in choice constraints (§6).
- Metadata codec fix, versioned, promoted out of the non-goals and to Phase 1 (§9).
- Engine ID and engine-qualified model key in new metadata (§9.3).
- `setModel` searches the current engine first (§9.4, with one amendment).
- Session-scoped cancellation token; an actor alone does not fix synchronous generation
  (§11.2).
- Iris stale-callback routing (§11.4) and observation task lifecycle (§11.6).
- Concurrency as engine capacity rather than registry-level lanes (§11.7).
- Test target should not default to Main Actor (§12.1) — verified in `project.pbxproj`.
- Drop the sniffer-precedence test (§12.2); tighten the Klein fixtures (§12.3–4).
- Do not hard-code OpenAI geometry assumptions (§13.2).
- A unified per-session `GenerationEvent` stream replacing the four callbacks (§11.5),
  scheduled with Phase 3 rather than gating Phase 2.
- An explicit definition of done for the foundation (§10).

**Not accepted as written:**

- *"Phases are not independently releasable; release is gated on at least one new engine
  working end to end."* Partly disagree. Phase 1 is a crash fix and Phase 4 is a
  standalone user-visible improvement; both should ship without waiting for OpenAI. What
  survives is the narrower and correct point: the engine picker should not ship with one
  engine behind it. See §10.
- *"Zero `@unchecked Sendable` in generator/runtime code"* as a definition of done. Too
  absolute, and in tension with the review's own §3.2. The Iris C API has global callback
  slots and no context pointer; an honest unchecked conformance documenting a
  self-enforced invariant beats a checked one that lies. The rule is about *serialization
  assumptions*, not the annotation. See §11.3.
- *"Three to six focused engineering days."* Dropped. The review names runtime validation
  as the main uncertainty, which is precisely the unestimable part. See §11.8.
- *"Decide whether discovery is intentionally shallow"* for sharded weights. It is, and
  that is correct for a picker. Fix the fixture, not production. See §12.3.
- *`setModel` should never switch engines without an explicit engine ID.* Amended: switch
  when exactly one other engine matches unambiguously, since the alternative is a menu
  command that appears to do nothing. See §9.4.

**Added, not in the review:**

- The `parseMetadataInfo` **crash** on a recognized key with a bare trailing colon, with
  the dead `guard` that fails to prevent it (§9.1). Verified by reproduction. This is the
  strongest reason to do the codec work first.
- MediaGenerationKit **licensing is a non-issue** (LGPL-3.0 into GPLv3), while its
  **maturity** is the real risk — created five months ago, ~25 stars (§13.3).
- Duplicated directory scans once both local engines share a model dir (§5.5).
- `ModelID.key` normalization rules — traversal, symlinks, case sensitivity (§5.1).

## 15. Non-goals

- Reworking the gallery, filtering, or inspector beyond the new metadata fields.
- Model downloading or conversion for any engine.
- A wholesale switch to an opaque metadata format. The format stays human-readable
  `Key: value` lines; §9.2 changed the separator and added escaping and a version marker,
  and additive keys remain in scope.
- Multi-engine batching within a single request.
- A separate "Swift Concurrency migration" project. The remaining hardening rides along
  with the engine runtime work in Phase 3.
