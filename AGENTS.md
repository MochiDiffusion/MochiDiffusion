# Repository Guidelines

## Build, Test, and Development Commands
- CLI build (Debug): `xcodebuild -project "Mochi Diffusion.xcodeproj" -scheme "Mochi Diffusion" -destination "platform=macOS" -configuration Debug`
- Run tests: `xcodebuild test -project "Mochi Diffusion.xcodeproj" -scheme "Mochi Diffusion" -destination "platform=macOS" -configuration Debug`
- Lint/format: `swift format lint -p -r ./`  
- Always ensure the project builds cleanly after any change. Resolve any lint warnings before committing any changes.

## Commit & Pull Request Guidelines
- Commit message format (from `CONTRIBUTING.md`):  
  `type: short summary` with types `build|ci|docs|feat|fix|perf|refactor|test`.  
  Include a body (≥20 characters) except for `docs` commits.
- Pull requests are squash-merged and must pass the gated check-in (build + `swift format` lint).  
  Include a clear description of changes; for UI changes, attach a brief screenshot when helpful.

## Localization

- Never directly edit non-English text, including translated READMEs and app localization
  resources. Translation work is done through Crowdin; review and merge the resulting Crowdin
  pull requests instead.

Run `bd prime` at the start of a new session or after context compaction to load the Beads
workflow primer before planning or tracking work.

That primer prints `Git authority: no git operations in this context` and `Git workflow:
stealth mode (no git ops)`. Both are generated from `no-git-ops: true` and describe what
**Beads itself** will not do — auto-commit its JSONL export, `git add`, or push. They are
not addressed to the agent and place no restriction on committing this project's source.
Follow the commit conventions above as normal.

## Scope and Planning

The next release is a minor stability and workflow release. It ships Core ML and Iris through
one combined model picker, keeps the completed multi-engine foundation underneath, and includes
multiple reference images/crop controls and gallery memory improvements. The explicit engine
picker, engine-oriented settings UI and OpenAI hosted generation are excluded from this stable
release surface. Preserve the OpenAI implementation and multi-engine contracts where practical
for a later experimental beta rather than rolling back the architecture wholesale.

Draw Things and Musubi interoperability are explicitly postponed by Graham. Draw Things is
preserved on branch `codex/draw-things-prototype` at
`e18663b3877bd42fac9fe169063a052b567a4f8a` and excluded from the release, including its
exclusive dependencies.
The abandoned Iris LoRA experiments are not carry-over work.

Beads owns task status, acceptance criteria and dependencies. `MochiDiffusion-q73` is the
finite next-release epic; `MochiDiffusion-e4v` is the deferred Musubi epic. Use the existing
database; do not create a replacement if access fails. Closed beads are historical and
may describe abandoned work. They do not create obligations to restore it. Do not turn
every research idea into a task or expand release scope without a concrete need.

This file describes the current architecture. [Multi-Engine-Design.md](Multi-Engine-Design.md)
is the closed record of phases 0–6, not the current work plan.
[Engine-Future-Work.md](Engine-Future-Work.md) preserves deferred research and decisions;
[Draw-Things-Proof-of-Concept.md](Draw-Things-Proof-of-Concept.md) records the prototype.
Keep work lists in Beads rather than maintaining parallel Markdown checklists.

## High-Level Design Flow

The multi-engine foundation is implemented. Current ownership and contracts follow.

- Runtime ownership boundaries:
  - `ConfigStore` (`@MainActor`, `@Observable`) owns persisted input that is *global* —
    `modelDir`, `controlNetDir`, `prompt`, `steps`, `width`/`height`, `imageDir`,
    `imageType`, and shared draft values such as `quality`. Its `UserDefaults` store is
    injectable, so tests use an isolated suite.
  - `EngineSettingsStore` (`@MainActor`, `@Observable`) owns per-engine persisted values
    under dynamic `Engine.<id>.…` keys: the selected engine, and the model each engine was
    last using. Separate from `ConfigStore` because `@AppStorage` binds one property to one
    literal key and cannot express a key set that grows with the engine list.
  - `GenerationController` (`@MainActor`, `@Observable`) owns the model list and the
    engine/model selection, builds a `GenerationDraft` from UI state, asks the selected
    engine to `plan` it, and enqueues the resulting `GenerationRequest`.
  - `GalleryController` (`@MainActor`) handles gallery I/O orchestration through
    `ImageRepository`.
  - `GenerationService` (`actor`) is the queue. It rejects a request whose payload does not
    belong to its engine *before* dequeuing it, drains serially, creates one
    `GenerationSession` per request, obtains the engine's runtime, writes results through
    `ImageRepository`, and emits `Snapshot`/`GenerationResult` streams. It deliberately does
    not consult `GenerationState`: queue readiness is not a UI status.
  - `GenerationState` (`@MainActor`) is the UI-facing status model
    (`ready`/`loading`/`running`/`error`).
  - Discovery problems have their own `GenerationController.discoveryMessage`.
    Generation outcomes are reported through alerts, separately from discovery.
  - Both controllers own their observation tasks and have a terminal `shutdown()`.

- Engines:
  - `iris.c` is intentionally pinned to
    `b832344c4caa71da00e16f2dab94571a72603477`, the baseline that provides the Iris APIs
    Mochi uses. Do not advance the submodule automatically; any update requires an explicit
    compatibility review.
  - Identity is `ModelID` (an `EngineID` plus a key), persisted as one value. A local key is
    the model directory's own name — see `EngineIdentity.swift` for why it is not a relative
    path computed against the models root.
  - `GenerationEngineDescriptor` is the immutable, `Sendable` half: `availability`,
    `discoverModels`, `plan`, `makeRuntime`. Its associated `Model` and `Payload` keep the
    engine, its models and its payload a compiler-checked triple. `AnyGenerationEngine`
    erases it for the registry and exposes `accepts(payload:)`.
  - `GenerationEngineRuntime` is the stateful half: it owns loaded pipelines and runs one
    request against one session: `CoreMLEngineRuntime`, `IrisEngineRuntime`, and
    `OpenAIEngineRuntime`.
  - `EngineRegistry` (`actor`) holds the engines; `refresh(settings:)` gathers availability
    and discovery per engine, failure-isolated, so one engine's missing folder or absent API
    key cannot empty the model list for the others.
  - **Engines never consult each other.** Each applies only its own recognition rules, and
    identity is engine-qualified, so two engines recognising the same directory both return a
    model. Registration order affects presentation order only — never ownership or validity.
  - One shared models folder is a settled decision. `ModelDiscoveryContext` enumerates it
    once per discovery pass and hands the same candidate list to every engine.
  - Concrete descriptors live in `LocalEngines.swift` and `OpenAIImageEngine.swift`;
    `EngineRegistry.shipped(secrets:)` registers them. OpenAI availability requires a
    Keychain credential, and its model catalog is hand-maintained. `EngineModel` requires no
    filesystem URL; its optional `tokenizerModelDir` is nil for hosted/server models.

- Options, and where they are resolved:
  - `OptionConstraints` describes what a **model** will honour — per model, not per engine,
    because a Core ML model's size is fixed by how it was converted. Each option is
    `.unsupported`, `.pinned`, or an editable range.
  - `plan(draft:model:)` is the *single* place a draft is resolved against those
    constraints. Synchronous, deterministic, side-effect free: no network, no pipeline
    loading, no cache mutation. Nothing downstream may reinterpret a resolved value, and
    metadata is written from the plan rather than recomputed.
  - Sidebar controls read the same constraints, so an option that is hidden is one the model
    does not use, and a value that is shown is the value that will run.
  - `GenerationPlan<Payload>` stays generic until `erased()` at the heterogeneous queue
    boundary.
  - Request fields are `Optional` where a model may not use the option at all — `strength`,
    `stepCount`, `guidanceScale`, `scheduler`, `quality`. A runtime that does use one reads
    the concrete value from its own payload. Two copies exist by design;
    `GenerationRequestBuilderTests` pins them equal.
  - Starting images and reference inputs have separate constraints and controller state.
    OpenAI and Iris accept reference lists; Core ML uses a denoising starting image.
    `SizeLimits` bounds dimensions jointly for hosted models, and quality is a typed choice.

- Concurrency defaults (project settings):
  - `SWIFT_VERSION = 6.0`
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for the app target, `nonisolated` for the
    test target
  - `SWIFT_STRICT_CONCURRENCY = complete`
  - Domain/service value types that cross actor boundaries are explicitly `nonisolated` +
    `Sendable` where required.

- Concurrency structure:
  - `GenerationSession` carries one request's cancellation flag and its event route
    (`GenerationEvent`: state, progress, preview — all lossy, bounded buffer). It is
    lock-guarded rather than an actor for two reasons: the generation callbacks are
    synchronous and have nothing to await into, and cancelling must not queue behind
    generating on a runtime actor's executor.
  - Results are **not** events. A result must never be dropped, it applies back-pressure,
    and a failed write has to fail the generation, so it stays a throwing call.
  - Queue execution is globally serial. Runtimes can declare an idle timeout enforced by
    the queue through the session; hosted transports also support cancellation/deadlines.
    Timeout policy is runtime/request-specific, not a universal 60-second budget.
  - `IrisSingleFlight` (`actor`) is a process-wide lease around the Iris C library, whose
    callback slots and cancel flag are per process rather than per instance. An actor runtime
    is not sufficient: actors are reentrant at every suspension point.
  - **`@unchecked Sendable` policy:** allowed only where the type guards its own mutable
    state with its own lock (`GenerationSession`, `IrisCallbackRouter`). Never justified by
    an assumption that some *other* type serializes callers — that is an invariant the
    compiler cannot see and a later change silently breaks.

- Metadata lifecycle:
  - `MetadataCodec` owns both directions. Version 2 is newline-separated `Key: value` lines
    with escaped values; legacy captions parse under version 1 rules. Malformed input never
    traps.
  - A model's `metadataFields` is the export contract; `presentFields` is what an imported
    image actually carried. Keep those distinct.
  - `.engine` and `.modelKey` let an imported image name a model exactly rather than by
    display name alone.
  - Generated and imported images share one interpretation path
    (`createImageRecordFromURL`).
  - Musubi is not integrated. Keep the current caption format for this release; broad
    interoperability, per-output snapshot design and new container writers remain deferred.
    `Scheduler` is still Core ML vocabulary. Unknown imported values must not be presented
    or restored as a known default; the bounded correction is tracked in the release epic.

- Gallery ownership and memory:
  - `ImageGallery` and `GenerationService` are app-owned, not singletons.
  - Disk scans produce path-backed records with dimensions and metadata, without resident
    full-size pixels. Generation results may carry already-available encoded bytes.
  - App-owned `GalleryThumbnailProvider` and `GalleryFullImageProvider` load pixels on
    demand. The thumbnail actor caches and coalesces requests; consumers receive providers
    through the environment. Do not reintroduce eager gallery-wide decoding.
  - `InputImagesView` preserves the landed crop/reference-budget UI. There is no standing
    requirement to port more code from an abandoned prototype.
  - Filename construction is shared by generation/export, and `ImageRepository` owns
    collision allocation. Gallery counts are presentation, not a uniqueness guarantee.

- Filesystem observation flow:
  - `FolderMonitorService` (`actor`) exposes `AsyncStream<Void>` update streams keyed by
    monitored path.
  - Controllers subscribe with task-based loops and trigger targeted refresh/sync
    operations. A refresh is one abandonable snapshot: a superseded pass is discarded rather
    than applied out of order.

- Test coverage (`Mochi DiffusionTests`, Swift Testing — `@Test`, `arguments:`,
  `#expect`/`#require`, no XCTest):
  - Identity and persistence: `EngineIdentityTests`, `ModelSelectionPersistenceTests`,
    `PreferenceMigrationTests`.
  - Discovery and selection: `ModelDiscoveryTests`, `EngineDiscoveryTests`,
    `EngineSelectionTests`.
  - Resolution: `OptionConstraintsTests`, `GenerationRequestBuilderTests`,
    `ComputeUnitPreferenceTests`.
  - Queue and concurrency: `QueueLivenessTests`, `GenerationSessionTests`,
    `GenerationOwnershipTests`, `IrisSingleFlightTests`, `ControllerLifecycleTests`,
    `IdleTimeoutTests` and `FailureReportingTests`.
  - Gallery: `GalleryLoadingTests`, `GalleryImageProviderTests`.
  - Hosted engine and credentials: `OpenAIImageEngineTests`, `OpenAIRuntimeTests`,
    `OpenAICredentialCheckTests`, `SecretStoreTests`.
  - Metadata: `MetadataCodecTests`, `MetadataRoundTripTests`.
  - Support: `ControlNetLinkTests`.
  - Fixtures are synthetic directories containing only the files the production sniffing
    code inspects, so no real model weights are required.
  - There are no `withKnownIssue` tests: the two defects that used one — prompt truncation
    on import, and an unreachable Iris fallback name — are fixed.
