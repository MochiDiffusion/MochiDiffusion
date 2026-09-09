# Engine Work: Deferred and Future

**Status:** open, and nothing here is scheduled. This is a parking lot with reasoning
attached, not a plan.
**Created:** 2026-08-28
**Predecessor:** [Multi-Engine-Design.md](Multi-Engine-Design.md), closed the same day with
Phases 0–6 delivered.

**2026-09-06 prototype:** a minimal server-based Draw Things engine is now implemented.
See [Draw-Things-Proof-of-Concept.md](Draw-Things-Proof-of-Concept.md) for setup, scope,
validation, and build limitations. It uses the smaller DT gRPC client rather than MGK;
the full integration and Phase 6.5 work below remain deferred.

## 0. How to use this document

The multi-engine work shipped in six phases: engine-qualified identity, a per-engine
descriptor and runtime, per-model option constraints driving the sidebar, an engine picker
with per-engine settings, and a first hosted engine (OpenAI). That work is done and its
record is closed. This document carries forward only what a future session would otherwise
have to rediscover.

What is here:

- **§1–2** orient a session that has never seen this codebase: the shape the engine layer
  settled into, the invariants that hold it together, and what adding an engine actually
  involves.
- **§3** holds the one deferred item worth keeping — per-engine concurrency — plus two
  standing warnings about code that looks wrong and is not.
- **§4** specifies a change that was designed and deliberately not made (Phase 6.5). It is
  a prerequisite for §5.
- **§5** is roughly four hundred lines of Draw Things / MediaGenerationKit research: license
  chain, dependency weight, the remote-catalog RPC, how its ~90-property configuration maps
  onto our constraint vocabulary, and what still has to be measured. It cost real effort and
  the prototype implements a narrow part of it; the remainder stays deferred.
- **§6** sketches declarative long-tail options, which only Draw Things motivates.

**Cross-reference convention.** §4 and §5 were moved here verbatim, so that their reasoning
is preserved exactly rather than paraphrased. Bare section references inside them — "§6",
"§9.3", "§13.1", "D4" — point into
[Multi-Engine-Design.md](Multi-Engine-Design.md), not into this document. References to
sections of *this* document are written as "§5 of this document".

**Verification, unchanged from the closed record:**

```bash
xcodebuild test -project "Mochi Diffusion.xcodeproj" -scheme "Mochi Diffusion" -destination "platform=macOS" -configuration Debug
```

```bash
swift format lint -p -r ./
```

Both must be clean before anything merges. At close: 502 test-case executions, 0 failures,
no compiler warnings. `AGENTS.md` describes the architecture as shipped and is current;
read it before this document.

## 1. Where the code stands

### The pipeline, end to end

The sidebar's live values become a `GenerationDraft`. The selected model's engine turns that
draft into a `GenerationPlan<Payload>` — synchronously, resolving every option against the
model's `OptionConstraints`. The plan is widened once by `erased()` into a
`GenerationRequest` carrying resolved values plus an opaque `payload`, which
`GenerationService` queues. At dequeue the engine's runtime runs it against a
`GenerationSession` that owns cancellation and a bounded event stream. Results go to
`ImageRepository`, then to the gallery with a per-image metadata field set.

| Concern | Type | File |
|---|---|---|
| Identity | `EngineID`, `ModelID` | `Model/EngineIdentity.swift` |
| Model facts | `EngineModel` | `Model/EngineModel.swift` |
| Option limits | `OptionConstraints`, `SizeConstraint`, `IntConstraint`, `DoubleConstraint`, `ChoiceConstraint`, `SizeLimits` | `Model/OptionConstraints.swift` |
| Engine, immutable half | `GenerationEngineDescriptor`, `AnyGenerationEngine` | `Support/GenerationEngine.swift` |
| Engine, stateful half | `GenerationEngineRuntime` | `Support/GenerationEngine.swift` |
| Per-request state | `GenerationSession`, `GenerationEvent` | `Support/GenerationSession.swift` |
| Registry and discovery | `EngineRegistry` | `Support/EngineRegistry.swift` |
| Queue | `GenerationService` | `Support/GenerationService.swift` |
| Engines | `CoreMLStableDiffusionEngine`, `IrisEngine`, `OpenAIImageEngine` | `Support/LocalEngines.swift`, `Support/OpenAIImageEngine.swift` |
| Runtimes | `CoreMLEngineRuntime`, `IrisEngineRuntime`, `OpenAIEngineRuntime` | same-named files |
| Persistence | `ConfigStore` (global), `EngineSettingsStore` (per-engine) | `Support/` |
| Credentials | `SecretStore`, `KeychainSecretStore` | `Support/SecretStore.swift` |
| Metadata | `MetadataCodec` | `Support/MetadataCodec.swift` |

### Invariants

These are not style preferences. Each one was arrived at by breaking it first, and several
have a test whose only job is to keep it true.

1. **Engines never consult each other.** Each applies its own recognition rules to its own
   source. Two engines may return the same directory; `ModelID` carries `EngineID`, so both
   stay distinct. There is no ownership arbitration and no sniffer precedence anywhere.
   Registration order is presentation order and nothing else.
2. **`plan` is the sole resolution point**, and is synchronous, deterministic and
   side-effect free. No network, no pipeline loading, no cache mutation.
3. **Nothing after `plan` renegotiates a value.** Metadata is written from resolved values.
   A runtime that substitutes its own number reintroduces the bug where the sidebar showed
   one thing and the image recorded another.
4. **The queue never looks inside `payload`.** `AnyGenerationEngine.accepts(payload:)` is
   checked at enqueue, before the request is dequeued and published, because the queue
   cannot un-publish it.
5. **Discovery is per-engine and failure-isolated.** One engine's missing folder or absent
   key must never empty another engine's model list.
6. **No `@unchecked Sendable` justified by an external serialization assumption.** The two
   that remain — `GenerationSession`, `IrisCallbackRouter` — are guarded by their own locks.
   They are correct; do not "fix" them into actors (see §3).
7. **Cancellation is request-scoped and synchronously readable** from a C or progress
   callback. A runtime blocked inside a synchronous generate call cannot accept an
   actor-isolated `cancel`, which is why the flag lives on the session.
8. **Events are lossy; results are not.** Progress, phase and preview share one bounded
   stream and one stale-delivery checkpoint. A result applies back-pressure and can throw.
9. **Credentials never enter a payload, a log, or image metadata.** The runtime reads the
   key at run time from a `SecretStore`.
10. **Metadata is additive and lenient.** New keys are safe, unknown keys are skipped,
    malformed input never traps, and an unrecognised *value* is never silently defaulted to
    a known one.

## 2. Adding an engine

In dependency order. Nothing here requires touching `GenerationService`, the queue, or any
other engine — if it does, something has drifted from §1.

1. **`EngineID` constant** in `Model/EngineIdentity.swift`. Persisted, so never rename a
   shipped raw value.
2. **A model type** conforming to `EngineModel`: `id`, `name`, `constraints`,
   `metadataFields`, `tokenizerModelDir`. There is deliberately no `url` — hosted models
   have no path.
3. **`OptionConstraints`** for each model. Declare `.unsupported` for anything the engine
   cannot honour; do not invent a plausible value. Unsupported hides the control, pinned
   shows it disabled, editable is validated in `plan`.
4. **A payload struct**, `Sendable`, carrying what the runtime needs and no credentials.
5. **A descriptor** conforming to `GenerationEngineDescriptor`: `availability`,
   `discoverModels`, `plan`, `makeRuntime`. `availability` runs on every discovery pass, so
   it must be cheap and must not read a secret.
6. **A runtime** conforming to `GenerationEngineRuntime`. Override `idleTimeout(for:)` if it
   can hang — anything over a network can — and `cancellationMayLeaveWorkBilled` if
   stopping does not stop the charge.
7. **Register it** in `EngineRegistry.defaultEngines`.
8. **Settings** section if it needs configuration, and a `SecretStore` account keyed on the
   engine id if it needs a credential.
9. **Tests**: discovery, `plan` resolution including clamping, payload ownership,
   availability states. Fakes only — nothing in the suite may touch the network or the real
   Keychain.
10. **`CHANGELOG.md`** under `# Unreleased` if any of it is user-visible.

## 3. Deferred work and standing notes

Trimmed on 2026-08-28. Three items that were here are gone, resolved rather than deferred:

- **Localization of the generation status messages** — out of scope for this work; owned
  elsewhere. Marked declined in the closed record rather than carried.
- **The GPT Image 2/2.5 constraint numbers** — accepted as correct. They were read from the
  image generation guide, and `OpenAIImageEngine` carries the date and the derivation of the
  one value that is computed rather than quoted.
- **`OpenAIEngineRuntime`'s unused `logger`** — removed, with a comment recording why the
  runtime has no logging at all: everything it handles is the API key or derived from a
  response authenticated with it, and `GenerationService` already logs the sanitized
  `GenerationError`.

What remains is one piece of real work and two warnings.

### Per-engine concurrency

Moved from §11.7 of the closed record. The queue is globally serial, which is correct while
one engine at a time is the common case. If concurrency is added, model it as runtime
capacity rather than baking lanes into the registry protocol:

- **Iris local:** one session, because the C library's callback slots and cancel flag are
  per process. `IrisSingleFlight` already enforces this and is the pattern to copy.
- **Core ML:** one session until pipeline thread-safety is established.
- **OpenAI:** possibly several, subject to cancellation, cost and rate limits.
- **MediaGenerationKit:** determine from documented guarantees and observed behaviour.

The motivating complaint is that a hosted request holds the serial queue for its whole
duration, so local jobs queue behind a network call. The idle watchdog bounds that at 60s of
silence, so it is bounded rather than unbounded — which is why this stayed deferred.

### Two things that look like bugs and are not

Recorded so a future session does not "fix" them:

- **`GenerationSession` and `IrisCallbackRouter` are `@unchecked Sendable`.** Both guard
  every mutable field with their own lock. Converting either to an actor breaks cancellation:
  a runtime blocked inside a synchronous generate call cannot accept an actor-isolated call,
  and the Iris C callbacks are synchronous with nothing to await into.
- **`EngineSettings.controlNetDirectory` is handed to every engine, including Iris, which
  ignores it.** One shared models folder is a settled decision (§7), so there is no
  per-engine path to scope it to. It is global by design.

## 4. Phase 6.5 — metadata fields resolved, not declared

**Designed, deliberately not built.** Moved verbatim from §6.5 of the closed record. Not a
prerequisite for anything shipped; a prerequisite for all of §5 of this document.

**Not yet true.** This section specifies a change that has not been made. It is scoped as
Phase 6.5 in §10 — deliberately after the OpenAI engine rather than inside it, because it
alters `EngineModel` and `GenerationPlan` and Phase 6 is in flight. Nothing here is a
prerequisite for OpenAI. All of it is a prerequisite for Draw Things (§13.3).

### The problem Draw Things creates

`EngineModel.metadataFields` is satisfied today by a literal set written into each concrete
model type — a computed `var` on `SDModel`, a `static let` on `IrisFluxKleinModel`. That
works while an engine has one model *kind*: thirteen fields for Core ML, nine for Klein, both
maintained by hand.

Draw Things breaks the assumption, and not because it needs several Swift types. It needs
**one** `DrawThingsModel` type whose values differ — constraints and recorded fields
computed from the catalog specification and the recommended configuration (§13.3). A
`kontext` model and an `inpainting` model are two values of one type. Enumerating Draw
Things' model families in our code would forfeit the main reason for using it: upstream owns
the model list, and it grows without us.

### The mechanism already exists, on the import path

`createImageRecordFromURL` ends with:

```swift
record.metadataFields = parsed.presentFields
```

On import the set is **derived from what was actually in the file** — the model may not
exist locally, and no declaration is consulted. On generation the same field on the same
record type comes from a static per-model declaration. One value, two sources.

The declarations are also redundant with what `plan` already resolves. Every field both
engines declare is recoverable:

| Field | Derivable from | Core ML | Iris |
|---|---|---|---|
| prompt, model, engine, modelKey, size, seed | always | ✓ | ✓ |
| negativePrompt | `constraints.supportsNegativePrompt` | ✓ | omitted |
| steps | `plan.stepCount != nil` | ✓ | ✓ |
| scheduler | `plan.scheduler != nil` | ✓ | ✓ |
| guidanceScale | `plan.guidanceScale != nil` | ✓ | omitted |
| mlComputeUnit | `plan.mlComputeUnit != nil` | ✓ | omitted |
| startingImage | `plan.startingImageName != nil` | ✓ | omitted |
| inputImages | `!plan.inputImageNames.isEmpty` | omitted | ✓ |
| controlNetImage | `constraints.controlNet.isSupported` | ✓ | omitted |

`steps` and `scheduler` are only in that group because of `0c9e725`, which made
`GenerationPlan.stepCount` and `.scheduler` optional and dropped `plan`'s fallback to the raw
draft value when a constraint reports `.unsupported`. Before it, both were non-optional and an
engine with no concept of either had to invent a number, with `metadataFields` keeping the
invented value off screen — so there was nothing to derive from, and the declaration was
load-bearing. That commit also aligned the queue's four option rows on the plan optional
rather than on `metadataFields`, which is the same distinction this section applies to the
recorded set.

The `startingImage` and `inputImages` rows carry the argument. "Does this engine record a
starting image or an input-image list?" is *not* derivable from constraints — both engines
declare `startingImage: .supported`. It is derivable from the plan, because `GenerationPlan`
already splits `startingImageName` from `inputImageNames`, and that field's own doc comment
already says "the engine decides which one it fills." The engine decides twice today, in two
places that can drift.

### Decided: `plan` returns the field set

`metadataFields` moves off `EngineModel` and onto `GenerationPlan`. Core ML and Iris return
the constant they declare today, so their output is unchanged and can be pinned as
byte-identical the way the Phase 2 entry gate pinned `buildGenerationRequest`. Draw Things
computes it.

Generation then means the same thing as import: the set on a record is *what this image
records*, never *what this model type could theoretically record*.

**Three fields need the equivalence pinned by a test: `negativePrompt`, `guidanceScale`,
`mlComputeUnit`.** They are the derived rows with no second line of defence — for each,
`metadata(including:)` writes the value on set membership alone. Everything else in the table
is either unconditional or additionally guarded on `!…isEmpty` in both
`metadata(including:)` and `getHumanReadableInfo(including:)`, so a derivation that
disagreed with today's declaration would still produce identical output.

`controlNetImage` is the row that actually *does* disagree — for a Core ML model with no
ControlNets, `constraints.controlNet.isSupported` is false where the declaration says present
— and its guard is exactly why that is safe rather than a regression.

`mlComputeUnit` is the one where the missing guard already bites: `MLComputeUnits.toString`
returns `""` for `nil`, so declaring the field without a resolved value writes
`ML Compute Unit:` with an empty value rather than omitting the key, and the empty value
imports as present. Same shape as the scheduler defect below.

For Draw Things the union is small and stable — `prompt`, `negativePrompt`, `model`,
`engine`, `modelKey`, `size`, `seed`, `steps`, `guidanceScale`, `scheduler`, `startingImage`,
`inputImages` — with membership resolved per generation: no `guidanceScale` when
`is_consistency_model`, no `negativePrompt` when `is_consistency_model` or `guidance_embed`
(the prompt is accepted and inert), `startingImage` or `inputImages` per what the plan
filled, and never `mlComputeUnit`, `controlNetImage` or `quality`.

### Decided: metadata records what the user chose

Draw Things forces a question the two local engines never did. Its recommended configuration
sets some eighty fields we do not expose — `shift`, `teaCache`, `cfgZeroStar`,
`resolutionDependentShift` and the rest (§13.3). None of them were chosen by the user, and
their meaning belongs to upstream.

> Metadata records **what the user chose**, plus enough identity — `engine`, `modelKey`
> — to know whose vocabulary to read it in. It is not a reproduction manifest.

So no `MetadataField` case is added for a value the sidebar does not edit. If exact
reproduction is wanted later, the escape hatch is a single opaque field carrying the resolved
engine configuration as JSON: versioned, never parsed for display, never laid out by the
Inspector. **Deferred, not rejected** — it is purely additive, and shipping it before anyone
round-trips a Draw Things image would commit us to a format for no measured need.

### Rejected: an open field vocabulary

Making `MetadataField` string-keyed or extensible per engine, so each engine names its own
options.

`Metadata`'s raw values *are* the on-disk caption keys. §6 already learned this the expensive
way with `Scheduler`, where a raw value used as display text turned out to be a persisted
identifier. An open vocabulary means the Inspector cannot have a fixed layout, and the keys
can never be reworded or localized, because each one is simultaneously a wire format. The
closed enum plus a derived per-image set gets the flexibility without that trade.

### Prerequisite: the scheduler must be an opaque string on disk

§6 records this as a defect "worth fixing whenever this is touched": `MetadataCodec` parses
the scheduler with `Scheduler(rawValue:)`, and `createImageRecordFromURL` falls back to
`.dpmSolverMultistepScheduler` when that fails — while `presentFields` still records
`.scheduler` as present. An image naming a scheduler this build does not know imports
claiming DPM-Solver++, and the Info panel displays a scheduler the image never used.

Draw Things turns that from a latent defect into the ordinary case. Its recommended
configurations name `DDIMTrailing`, `UniPCTrailing`, `EulerATrailing`, `DPMPP2MAYS` and
`TCDTrailing` (§13.3), none of which exist in our three-case enum, so **every** Draw Things
image would import misattributed. Metadata must carry the scheduler as the string it is on
disk and resolve it to a known case only where one is needed.

This is in Phase 6.5 rather than Phase 6 because OpenAI exposes no sampler — its `scheduler`
constraint is `.unsupported`, so it writes no scheduler key and cannot trip the defect.

### Accepted cost of deferring past Phase 6

The OpenAI engine will land with a hand-declared `metadataFields` and be converted afterwards.
That is the right trade against disturbing work in flight, but name what it leaves behind.

**Two fields the hosted engine must declare by hand, then hand back in Phase 6.5:**

- `.revisedPrompt` (§9.3) is present only when the API returns a revision, so Phase 6
  declares it unconditionally and leans on an `!isEmpty` guard in `metadata(including:)` to
  keep it out of images that have none. That works — it is the guard `startingImage` and
  `controlNetImage` already rely on — but it is precisely the "declared set overstates the
  image" shape this section removes.
- `.quality` needs the whole chain §6 lists as missing: constraint, draft field, plan field,
  sidebar control, metadata wiring. The Draw Things union above says "never
  `mlComputeUnit`, `controlNetImage` or `quality`," which stays true of Draw Things — it has
  no quality tiers — but OpenAI does, so Phase 6 adds `plan.quality` and declares `.quality`
  alongside `.revisedPrompt`. Two fields awaiting conversion, not one.

**Two fields the hosted engine must *not* declare, and this half is not cosmetic.**
`.steps` and `.scheduler` have no `!isEmpty` guard, and `SDImage` defaults them to `28` and
`.dpmSolverMultistepScheduler`. So a hosted engine that declares either while leaving
`plan.stepCount` or `plan.scheduler` nil writes `Steps: 28` and `Scheduler: DPM-Solver++`
into every image it generates — numbers no OpenAI request ever contained, recorded as fact,
and then read back as present on import. Nothing fails, no test notices, and the hazard stays
invisible until someone opens an Info panel and sees a step count for a model that has no
steps. `0c9e725` made leaving both nil expressible for exactly this reason; Phase 6 has to
actually leave them nil.

## 5. Draw Things / MediaGenerationKit

**Full integration research; a limited gRPC prototype now exists (linked above).**
Moved verbatim from §13.3 of the closed record, including
its build-first gate and its open unknowns. Two findings to carry in mind while reading:
the dependency graph is a step change for this project, and the licensing conclusion was
revised once already — read the license note at the revision you actually pin.

Verified 2026-08-26 against `drawthingsai/media-generation-kit` and
`drawthingsai/draw-things-community` at `main`. The option-mapping subsections from
"The configuration surface" onward are a second pass, 2026-08-27, against the same two
repositories at `main` plus the live catalogs at `models.drawthings.ai`.

**Licensing is settled either way, but the earlier reading was too strong.**
MediaGenerationKit's own wrapper is LGPL-3.0, and it is a façade: its single library target
depends on `_MediaGenerationKit`, a product of `drawthingsai/draw-things-community`, whose
repository is GPL-v3. An earlier revision of this section concluded from that graph alone
that "the transitive reality is GPL-3" and that any future relicensing conversation was
therefore foreclosed.

That does not survive reading MGK's own license note. It states that the code and
dependencies which cross from `draw-things-community` into the `media-generation-kit`
distribution are **relicensed under LGPLv3 as part of that package**, and says the intent is
explicitly *not* to force GPLv3-style licensing onto downstream applications. So the
artifact we would link is offered as LGPL-3 over a GPL-3 upstream, not as GPL-3.

Our decision does not change — Mochi Diffusion is GPLv3, and GPL-3 and LGPL-3 are both fine
to link, so this still needs no further legal review. What changes is that the doc must not
assert the stronger claim. Record it as "LGPL-3 as distributed, over a GPL-3 upstream," and
if relicensing ever matters, read the note at the revision we actually pin rather than
inferring from the upstream repository's license file.

**Dependency weight is a first-class risk, alongside maturity.** MGK's `Package.swift`
declares one library target wrapping `_MediaGenerationKit`; the real payload is
`draw-things-community`, a 752-line manifest whose graph includes `ccv` (C), `s4nnc`,
`dflat` and `SQLiteDflat`, `swift-fickling`, `swift-sentencepiece`, `grpc-swift`,
`swift-protobuf`, `swift-nio-ssl`, `swift-crypto`, `swift-png`, and vendored copies of
`SnapKit`, `Nantes`, `SwiftSoup`, `SwiftMath` and `HighlighterSwift`. Bazel is that
project's primary build system; the SwiftPM manifest is a secondary path. Mochi today
builds against Apple's `ml-stable-diffusion` and little else, so this is a step change in
build time, binary size, and exposure to a build path upstream does not dogfood.

**Maturity, restated.** Repository created 2026-03-30, last pushed 2026-07-14, ~25 stars,
two tags. Installation guidance pins a revision because version requirements are not
supported, and MGK in turn pins `draw-things-community` by revision. Pin both, and expect
to track breaking changes.

**Gate the prototype on the build, not the UI.** The first milestone is a clean Xcode
build of Mochi plus MGK on our toolchain, with build time and app size measured before and
after. Everything else in this section is downstream of that number.

### Remote model listing

An earlier draft recorded remote model listing as simply absent. That is true of MGK's
public API and false of the protocol underneath, and the difference changes the design.

MGK's CLI does expose `models list-remote`, and it deliberately fails, because the public
API provides no remote listing. But
`Libraries/GRPC/Models/Sources/imageService/imageService.proto` defines an `Echo` RPC whose
reply carries the catalog:

- `EchoReply.files` — every `*.ckpt` of nonzero size in the server's internal model
  directory plus its first external URL. Non-recursive.
- `EchoReply.override` — a `MetadataOverride` whose `models`, `loras`, `controlNets`,
  `textualInversions` and `upscalers` fields each hold a **JSON-encoded array of
  `*Zoo.Specification`** (snake_case keys), filtered to what is actually downloaded on
  that host.

`ModelZoo.Specification` carries what the picker and the §6 constraints need: `name`,
`file`, `version`, `defaultScale`, `modifier`, `guidanceEmbed`, `isConsistencyModel`,
`hiresFixScale`, `deprecated`, `note`. `ImageGenerationClientWrapper.echo(...)` in
`Libraries/GRPC/Server/Sources` already decodes all of it into a
`(files:, models:, LoRAs:, controlNets:, textualInversions:)` tuple, wrapping each element
in `FailableDecodable` so one unrecognized specification does not discard the whole list.
Copy that tolerance; a catalog from a newer server than our decoder is the normal case,
not the exception.

Two constraints on using this:

1. **The server must opt in.** `ImageGenerationServiceImpl.enableModelBrowsing` defaults to
   `false`, and `gRPCServerCLI` sets it from a `--model-browser` flag. A server started
   without the flag answers `Echo` with an empty `files` and no `override`. "This host does
   not publish its models" is therefore a normal state and must render as an explanatory UI
   state, not a discovery failure. §5.5 already demands the related property — an unhelpful
   remote host must not wipe the local model list.
2. **`GRPCServer` is not reachable from SwiftPM.** `draw-things-community` exports only
   `gRPCServerCLI`, `draw-things-cli`, `LocalCodeApp` and `_MediaGenerationKit` as products.
   `GRPCImageServiceModels` and `GRPCServer` are internal targets, so that client wrapper
   cannot be imported.

So, three tiers, in this order:

1. **Generate our own stubs for `Echo` alone.** We need `EchoRequest`, `EchoReply`,
   `MetadataOverride`, and a *partial* `Codable` mirror of `ModelZoo.Specification`
   covering only the fields the picker uses — decoding the full type would drag in
   `ModelVersion`, `Denoiser` and the rest of the zoo's enum surface. grpc-swift and
   swift-protobuf are already in the transitive graph. Small, independent of upstream, and
   the path to assume when planning.
2. **Catalog plus probe, when browsing is off.** Use
   `MediaGenerationEnvironment.default.downloadableModels()` / `suggestedModels()` for the
   universe of known files, let the user pick or type one, then validate it against the host
   with the `FilesExist` RPC — which also returns hashes — before enabling Generate. This
   replaces the earlier plan of accepting an unvalidated identifier.
3. **Push the gap upstream in parallel.** Either a `GRPCImageServiceModels` SwiftPM product
   or a public `remoteModels()` on MGK. The correct long-term fix; keep it off the critical
   path.

Discovery must run on the async path. MGK's catalog helpers are split: sync overloads are
offline- or cache-only and throw `MediaGenerationKitError.asyncOperationRequired` when they
would need uncached remote catalog data, and `suggestedModels(..., offline: false)` throws
immediately if that data is not already cached.

**Unresolved:** whether `Echo` is meaningful against `.cloudCompute`, where the served
catalog is presumably the official one rather than one host's directory listing. Settle
this in the prototype before designing a single discovery path across all three
connections.

### `MetadataOverride` round-trips

`MetadataOverride` is not only a response field. It is also an input on
`ImageGenerationRequest`, and the client is expected to hand the specification back at
generation time. A remote model is therefore not just a name: whatever we discover through
`Echo` has to retain its specification and replay it in the request.

That couples remote discovery to request construction in a way local discovery does not,
and it is the first case where a §5.4 payload needs data only discovery can supply. The
Draw Things payload type must carry the specification bytes, and the per-engine discovery
result in §5.5 has to outlive the sidebar read that produced it — a model list recomputed
and discarded per read is not sufficient here.

### The configuration surface, and where its defaults come from

`MediaGenerationPipeline.Configuration` carries roughly ninety stored properties. A handful
are ones Mochi already has a control for — `width`, `height`, `seed`, `steps`,
`guidanceScale`, `strength`, `sampler`, `batchCount` — and the rest are not: `shift`,
`resolutionDependentShift`, `clipSkip`, `teaCache` and its four tuning fields, `cfgZeroStar`
and `cfgZeroInitSteps`, `stochasticSamplingGamma`, `causalInference`, tiled diffusion and
tiled decoding with three geometry fields each, hires fix, refiner model and `refinerStart`,
SDXL crop and aesthetic-score conditioning, `speedUpWithGuidanceEmbed` and `guidanceEmbed`,
`separateT5` / `separateClipL` / `separateOpenClipG` and their per-encoder prompt overrides,
`colorCalibration`, `compressionArtifacts`, `expandPromptToJson`. We would expose ten or so
and want sane values for the other eighty.

**Those values exist, and MGK applies them for us.** `fromPretrained(_:backend:)` resolves
the model, then calls `ConfigurationResolver.recommendedTemplate(for:loras:offline:)` and
seeds `configuration` from the result. The template is `GenerationConfiguration.default`
with `startWidth` and `startHeight` set from
`DeviceCapability.defaultScale(ModelZoo.defaultScaleForModel(model))`, merged — as a JSON
dictionary, through `JSGenerationConfiguration` — with a per-model entry from a
*ConfigurationZoo*: builtin
`ConfigurationZoo.community` first, then the bundled `configs.json` package resource, then
`https://models.drawthings.ai/configs.json`.

**The consequence is a hard constraint on how the engine holds configuration.**
`Configuration.runtimeConfiguration(template:)` writes *every* field from the
`Configuration` over the template. The template therefore only ever matters because
`Configuration` was initialized from it inside `fromPretrained`. So:

> The Draw Things engine must not construct a `Configuration` itself, and must not carry one
> across a model switch. It has to start from a model-seeded configuration and overlay only
> the fields Mochi exposes. Otherwise switching from `flux_1_fill_dev` to FLUX.2 Klein
> silently ships Fill's `shift`, `sampler` and `teaCache` settings under Klein's name.

That collides with §5.3: `fromPretrained` is `async` and performs model resolution, so it
cannot run inside `plan`. The resolution is the one §5.5 and the `MetadataOverride`
subsection above already reached for a different reason — **the recommended configuration is
discovery-time data cached on the model**, and `plan` overlays onto a value it already
holds. The Draw Things `EngineModel` therefore carries two things discovery alone can
supply: the `ModelZoo.Specification` to replay, and the resolved recommended configuration.

**Template coverage is partial, and the miss is a normal state.** Measured against the live
catalogs on 2026-08-27: 233 models, 54 configuration entries. Matching runs exact model
file, then model prefix with the quantization suffix stripped (`f16`, `svd`, `q5p`, `q6p`,
`q8p`, `i8x`), then a prefix-of-prefix pass, then `version`, each preferring an entry whose
`loras` are a superset of the request's. That resolves 16 exactly, 45 by prefix, 146 by
version — and leaves **26 models with no entry at all**, falling back to
`GenerationConfiguration.default` plus `defaultScale`. Design for the fallback; do not treat
a missing recommended configuration as an error.

**`runtimeConfiguration` validates before it runs.** It throws
`MediaGenerationKitError.generationFailed` when width or height is not positive or not a
multiple of **64**, when `steps` is not positive, or when `batchCount`/`batchSize` is not
positive. Those are the values `plan` must already have normalized, so they should never be
reachable — an engine whose `plan` respects its own constraints turns each of these into a
wiring bug rather than a user-visible error, which is what §6 asks for.

### Constraints must come from the catalog, not the public API

The public `MediaGenerationResolvedModel` — what `resolveModel`, `inspectModel`,
`suggestedModels` and `downloadableModels` all return — has six fields: `file`, `name`,
`description`, `version`, `huggingFaceLink`, `isDownloaded`. It cannot answer a single
question §6's `OptionConstraints` asks.

**And the same is true of the metadata contract.** A model whose options are described by
upstream data cannot carry a hand-written `metadataFields` set either; §6.5 moves that set out
of `EngineModel` and into what `plan` resolves, and fixes the union for this engine.

`ModelZoo.Specification` can, and the catalog is reachable the same way `configs.json` is:
bundled as a package resource and served at `https://models.drawthings.ai/models.json`. This
is the same tier-1 move already prescribed above for `Echo` — a partial `Codable` mirror of
the fields we use, tolerant of unknown ones — and it should be built once and shared, since
`Echo`'s `MetadataOverride` hands back JSON-encoded arrays of these very specifications.

Field frequency over the 233 catalog entries, which is what tells us whether a field is
usable as a constraint or only as a hint:

| Field | Present | What it constrains |
|---|---|---|
| `default_scale` | 233 | default size, in units of 64px — values 8, 10, 12, 15, 16 |
| `version` | 233 | which sampler/reference behaviour applies |
| `modifier` | 108 | whether the model takes reference images, and how |
| `hires_fix_scale` | 135 | hires-fix geometry, if we ever expose it |
| `note` | 103 | model description text for the picker |
| `padded_text_encoding_length` | 82 | `promptTokenLimit` |
| `guidance_embed` | 29 | guidance is a distilled embedding, not CFG |
| `is_consistency_model` | 15 | distilled/turbo — no CFG at all |
| `deprecated` | 0 | present in the type, unused in the current catalog |

**Guidance scale, specifically — yes, we can tell.** Three signals, and they are not
equivalent:

- `is_consistency_model: true` (15 models: SDXL Turbo, SD3.5 Large Turbo, the Schnell
  derivatives, HiDream Fast) — a *declaration* that there is no CFG. Maps to
  `guidanceScale: .unsupported`.
- `guidance_embed: true` (29 models: the FLUX.1 and FLUX.2 dev families, HunyuanVideo,
  several community Flux merges) — also a declaration, but a different one. CFG is replaced
  by a distilled guidance embedding, so the number still has an effect while the negative
  prompt does not. Maps to a supported `guidanceScale` **plus**
  `supportsNegativePrompt: false`, and it is the case a boolean capability flag cannot
  express.
- ConfigurationZoo `guidanceScale == 1` (FLUX.2 Klein, Z-Image-Turbo) — *not* a declaration.
  It is the recommended value, and it means CFG is effectively off. Treat it as the default
  the sidebar starts at, not as `.unsupported`; a model can be given a real guidance scale
  by a user who knows what they are doing.

**And the range is per-model, in a way our current bounds would corrupt.** Recommended
`guidanceScale` across the 54 entries takes the values 1, 3.5, 4, 4.5, 5, 6, 7 and **50** —
`flux_1_fill_dev` uses 50. `steps` spans 4 to 52. Mochi's Core ML bounds of `1...20` and
`1...50` are descriptions of *those* controls, and reusing them here would clamp Fill's
recommended guidance to 20 while the sidebar showed it. This is precisely the failure §6's
"Learned while building it" was written about, so the Draw Things bounds have to be derived
per model rather than shared.

FLUX.2 Klein 9B is worth writing down as the worked example, since it is the model we
already run through Iris. Catalog: `version: flux2_9b`, `modifier: kontext`,
`default_scale: 16`, `hires_fix_scale: 32`, `padded_text_encoding_length: 512`, and no
`guidance_embed` or `is_consistency_model`. ConfigurationZoo, for
`flux_2_klein_9b_kv_q6p.ckpt`: `guidanceScale: 1`, `steps: 4`, `sampler: 16` (DDIMTrailing),
`shift: 3`, `strength: 1`, `width`/`height: 1024`, `speedUpWithGuidanceEmbed: true`. Note
that `padded_text_encoding_length: 512` is the same limit
[Model/IrisFluxKleinModel.swift](Mochi%20Diffusion/Model/IrisFluxKleinModel.swift) hardcodes
as `promptTokenLimit`, and that here it arrives from discovery. That is a partial answer to
§6's deferred "prompt token counting is not part of this": for this engine the limit is
catalog data, and no tokenizer directory is involved.

### Input images map onto moodboard, and it is not a hack at this layer

`MediaGenerationPipeline.InputRole` is `.image`, `.mask`, `.moodboard`, `.depth`, reached
through the `.mask()`, `.moodboard()` and `.depth()` wrappers on any image input.
`executionInputs(from:)` allows **at most one** `.image` and one `.mask` — a second of either
throws — and collects **all** `.moodboard` inputs into a single hint of type `.shuffle`.

In `LocalImageGenerator`, for `modifier` in `.kontext`, `.kontextKv`, `.qwenimageEditPlus`
or `.qwenimageEdit2511`, the ordered reference list is built as:

```swift
textImages = (image.map { [$0] } ?? []) + shuffles.map { graph.variable($0.0) }
```

and the latent-side reference list is built the same way, primary first. So:

- **The reference list is ordered, and moodboard order is preserved.** That matters — the
  Qwen-Edit prompt template counts its inputs, and Klein's instruction prompts refer to
  images positionally.
- **A primary image is optional.** `image == nil` dispatches to `generateTextOnly`, which
  still receives and consumes `shuffles`. A pure reference list with no denoising origin is
  a supported shape, not a workaround.
- **Moodboard weight is not reachable through MGK.** It hardcodes `weight: 1.0` per image,
  and the generator only tests `shuffle.1 > 0`, so weight is include/exclude in practice.
  Fine for a reference list; it does mean no per-image influence control without dropping to
  the wire protocol, where `HintProto` carries a `repeated TensorAndWeight`.

Which gives two clean mappings, and they are different enough to be worth naming separately:

| Mochi sidebar | Draw Things | Strength |
|---|---|---|
| Starting Image (SD-style img2img) | primary `.image` | `configuration.strength` |
| Input Images (Klein-style reference list) | N × `.moodboard()`, no primary | none |

**Do not pre-crop the moodboard images.** The two roles are sized differently, and only one
of them matches what Mochi does today:

- The primary image goes through `imageDataToTensor(data, width: startWidth * 64,
  height: startHeight * 64)`, and `ImageConverter.resize` scales to fill and centres, so
  overflow is cropped. That is the same behaviour as Mochi's `scaledAndCroppedTo(size:)`, so
  either side can do it and the result is identical.
- Hint images go through `hintImageDataToTensor(data)` with **no** target size. The generator
  later rescales each one to the *pixel count* of the output, preserving its own aspect ratio
  and snapping to a multiple of 16 — the code's comment notes Kontext was trained on 1M-pixel
  images. Cropping a reference image to the output's aspect ratio first discards information
  that DT would otherwise have used.

So `plan` for this engine passes the primary image scaled-and-cropped (or just passes it and
lets MGK crop) and the reference images **at native resolution**. Core ML's `plan` calls
`scaledAndCroppedTo` on everything; Draw Things' must not.

**One vocabulary gap this exposes.** `StartingImageConstraint` in
[Model/OptionConstraints.swift](Mochi%20Diffusion/Model/OptionConstraints.swift) models a
single image slot with an optional strength range. Draw Things wants both slots at once: one
strength-bearing origin *and* an unbounded strengthless ordered reference list, with the
count and whether the list is accepted at all depending on `modifier`. That is a third
constraint kind, not a widening of the existing one, and it is a Phase 6 prerequisite in the
same sense as the two §6 already lists.

### Corrections to §6 this pass forces

Recorded here rather than edited into §6, since §6 describes what was built for the two local
engines and these only become true when this engine lands.

- **`SizeConstraint.aspectRatios` is not needed for Draw Things.** §6 lists the missing
  aspect-ratio case as a Phase 6 prerequisite. DT takes concrete pixel dimensions —
  `runtimeConfiguration` enforces `width % 64 == 0` — so this engine is
  `.freeform(range:step:)` and needs no new case. The gap is real for OpenAI and only for
  OpenAI.
- **But the step is 64, not 16.** Mochi's freeform step is 16, which is right for Core ML
  latents. A size persisted from an Iris model — 1008, say — has to snap to 1024 here.
  `default_scale` values 8, 10, 12, 15 and 16 correspond to 512, 640, 768, 960 and 1024, each
  capped further by `DeviceCapability.defaultScale`.
- **The `Scheduler` break is wider than §6 estimates.** `SamplerType` has twenty cases
  (`DPMPP2MKarras`, `EulerA`, `DDIM`, `PLMS`, `DPMPPSDEKarras`, `UniPC`, `LCM`, the Substep,
  Trailing and AYS variants, `TCD`…) with **zero** name overlap with Mochi's three
  (`PNDM`, `DPM-Solver++`, `Flow Match Euler Discrete`). The recommended values in the
  catalog land on five of them — `EulerATrailing`, `DPMPP2MAYS`, `DDIMTrailing`,
  `UniPCTrailing`, `TCDTrailing`. The engine-scoped stable-string identifier §6 proposes is
  not optional here, and see the next subsection for why we cannot yet name the type at all.
  The metadata half of that — carrying the scheduler as the opaque string it is on disk
  — is scoped as Phase 6.5 in §6.5, because without it every Draw Things image imports
  claiming DPM-Solver++.

### Connection and remaining unknowns

Keep "Draw Things" as **one** engine with a Connection setting (§2), not several sibling
entries. MGK makes this easy: the backend is a single `Backend` value, passed to
`fromPretrained(_:backend:)` and held as `pipeline.backend` — `.local`,
`.local(directory:)`, `.remote(_:options:)`, or `.cloudCompute(apiKey:options:)` — which
maps onto Connection directly. (An earlier revision put it on `pipeline.configuration`;
it is a sibling of `configuration`, not a field in it.) The options types are Connection
settings too: `RemoteOptions` carries `useTLS` and a `sharedSecret`, and
`CloudComputeOptions` carries a `baseURL`, a `deviceName` and an `AppCheckConfiguration`.

**A blocker on the exposed option set, ahead of anything else in this subsection.** MGK's
`Exports.swift` is a single `@_exported import _MediaGenerationKit`, and
`_MediaGenerationKit` re-exports nothing of its own. `draw-things-community` exports only
`gRPCServerCLI`, `draw-things-cli`, `LocalCodeApp` and `_MediaGenerationKit` as products —
`DataModels` is an internal target. But `Configuration.sampler` is a `SamplerType`,
`seedMode` a `SeedMode`, `loras` a `[LoRA]`, `controls` a `[Control]`,
`compressionArtifacts` a `CompressionMethod` and `colorCalibration` a `ColorCalibration`,
and every one of those lives in `DataModels`. **We cannot name the types**, so as things
stand there is no sampler picker, no seed-mode control and no LoRA support — only the
model-seeded defaults for all of them. Reading and copying a whole `Configuration` still
works; constructing those field values does not.

This is a larger hole than the `Echo` gap and it belongs on the same tier-3 list: ask
upstream for a `DataModels` SwiftPM product, or for the public `Configuration` to express
these as its own stable identifiers. Until then, treat sampler as pinned-to-recommended for
this engine and say so in the sidebar rather than showing a control that cannot be wired.
Do not plan around SwiftPM's incidental `-I` leakage making `import DataModels` compile;
it is not a supported guarantee and it would break the build on an upstream reorganisation.

To verify in the prototype: local pipelines, LAN remote generation by host and port, Draw
Things cloud compute, previews in the progress callback (`MediaGenerationPipeline.Preview`
is a random-access collection that lazily decodes a `CGImage` per subscript, which suits
`onPreview`), and whether `fromPretrained(_:backend:)` will accept a model name present on
the remote host but absent from the local catalog. That last one decides whether tier 1
above is sufficient on its own or whether the local catalog must first be seeded from
`Echo`.

Added by the 2026-08-27 pass, in rough order of how much design depends on the answer:

1. **Whether `import DataModels` compiles at all** against the revision we pin. It decides
   whether sampler, seed mode and LoRA are in scope for the first release or deferred
   behind an upstream request.
2. **How expensive `fromPretrained` is per model.** It does not load weights, but it does
   async model resolution and a possibly-networked catalog fetch. If it is cheap it can run
   on model selection; if not, constraints come from our own catalog mirror and
   `fromPretrained` is called only at generate time. Either way the sidebar may need a
   "resolving constraints" state it does not have today.
3. **Whether a Klein reference list behaves the same with no primary image.** The code path
   says yes — `generateTextOnly` consumes `shuffles` — but confirm against real output
   before designing the Input Images section around it.
4. **Whether `strength` is inert for a `kontext` model given a primary image.** The
   recommended configuration sets `strength: 1`, which suggests the primary image is meant
   as a reference rather than a denoising origin, but the img2img path is still what runs.
   This decides whether Starting Image and Input Images are one control or two.
5. **What `estimatedComputeUnits(inputs:)` reports**, since it is the only pre-flight cost
   signal for cloud compute and §13.1 already requires the cancellation wording to be
   honest about charges.

Do not assume in advance that MediaGenerationKit replaces Core ML SD or Iris. Overlap is
likely; preserving the existing runtimes as separate engines stays valid where model
formats, performance, or user expectations differ.

## 6. Declarative long-tail options

Only Draw Things motivates this, so it sits behind §5 of this document.

The shipped constraint vocabulary is a fixed set of typed fields: negative prompt, size,
steps, guidance scale, scheduler, starting image, ControlNet, number of images, quality,
prompt token limit. That is the right shape for options several engines share and the sidebar
renders with bespoke controls — `SizeView`'s swap button, the ControlNet image wells, the
localized labels.

It is the wrong shape for the ~90-property surface §5 documents. The intended answer is a
declarative `[OptionSpec]` bag alongside the typed fields, rendered by a generic form, with
values in an `[OptionID: OptionValue]` dictionary persisted under
`Engine.<id>.Options` — the key `EngineSettingsStore` already reserves and nothing writes.

Deliberately not the starting point. A fully declarative sidebar would cost the bespoke
controls and straightforward localization, and no engine needed it until Draw Things. Add it
when a concrete engine demonstrates the need, and keep the shared core typed.

## 7. What is deliberately not here

- **The closed record itself.** [Multi-Engine-Design.md](Multi-Engine-Design.md) keeps the
  full history: what each phase built, where implementations deviated from the design and
  why, two independent review triages with severity disagreements, and the decisions that
  were reversed. Read it when you need to know *why* something is the way it is. This
  document is only what is left to do.
- **Anything shipped.** `AGENTS.md` describes the architecture as it exists.
- **Estimates.** None of this is scheduled, and the closed record's §11.8 explains why no
  day figures appear in either document.
