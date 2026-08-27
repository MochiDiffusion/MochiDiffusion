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

## High-Level Design Flow

Multi-engine generation is an in-flight refactor. `Multi-Engine-Design.md` is the source of
truth for what is built, what is decided, and what is deliberately deferred; §10's phase
table is the status of record. This section is the orientation, not the detail.

- Runtime ownership boundaries:
  - `ConfigStore` (`@MainActor`, `@Observable`) owns persisted input that is *global* —
    `modelDir`, `controlNetDir`, `prompt`, `steps`, `width`/`height`, `imageDir`,
    `imageType`. Its `UserDefaults` store is injectable, so tests use an isolated suite.
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
  - Both controllers own their observation tasks and have a terminal `shutdown()`.

- Engines:
  - Identity is `ModelID` (an `EngineID` plus a key), persisted as one value. A local key is
    the model directory's own name — see `EngineIdentity.swift` for why it is not a relative
    path computed against the models root.
  - `GenerationEngineDescriptor` is the immutable, `Sendable` half: `availability`,
    `discoverModels`, `plan`, `makeRuntime`. Its associated `Model` and `Payload` keep the
    engine, its models and its payload a compiler-checked triple. `AnyGenerationEngine`
    erases it for the registry and exposes `accepts(payload:)`.
  - `GenerationEngineRuntime` is the stateful half: it owns loaded pipelines and runs one
    request against one session. `CoreMLEngineRuntime`, `IrisEngineRuntime`.
  - `EngineRegistry` (`actor`) holds the engines; `refresh(settings:)` gathers availability
    and discovery per engine, failure-isolated, so one engine's missing folder or absent API
    key cannot empty the model list for the others.
  - **Engines never consult each other.** Each applies only its own recognition rules, and
    identity is engine-qualified, so two engines recognising the same directory both return a
    model. Registration order affects presentation order only — never ownership or validity.
  - One shared models folder is a settled decision. `ModelDiscoveryContext` enumerates it
    once per discovery pass and hands the same candidate list to every engine.
  - Concrete engines live in `LocalEngines.swift`.

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
    `stepCount`, `guidanceScale`, `scheduler`. A runtime that does use one reads the concrete
    value from its own payload. Two copies exist by design; `GenerationRequestBuilderTests`
    pins them equal.

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
    `GenerationOwnershipTests`, `IrisSingleFlightTests`, `ControllerLifecycleTests`.
  - Metadata: `MetadataCodecTests`, `MetadataRoundTripTests`.
  - Support: `ControlNetLinkTests`.
  - Fixtures are synthetic directories containing only the files the production sniffing
    code inspects, so no real model weights are required.
  - There are no `withKnownIssue` tests: the two defects that used one — prompt truncation
    on import, and an unreachable Iris fallback name — are fixed.

### Potential improvements
- `Scheduler` is a Core ML type serving as cross-engine vocabulary: `OptionConstraints.scheduler`
  is a `ChoiceConstraint<Scheduler>`, so every engine has to express its sampler in an enum
  that maps one-to-one onto `StableDiffusionScheduler`. It breaks as soon as a second engine
  offers a real choice; the fix is an engine-scoped identifier. Related defect worth fixing
  at the same time: an image naming a scheduler this build does not know imports as
  DPM-Solver++ while `presentFields` still claims the field was present, so the Info panel
  displays a scheduler the image never used.
- `EngineModel.url` is non-optional and `tokenizerModelDir` exists on the protocol, both
  because every model is currently a local directory. A hosted model has neither.
- There is no `quality` constraint and no aspect-ratio `SizeConstraint` case; a hosted engine
  with quality tiers or ratio-based geometry needs both.
- Discovery problems are still reported through `GenerationService.updateStatus(.error:)`, so
  a discovery message and a generation message share one banner and overwrite each other.
- There is no request timeout. Local generation always finishes or is cancelled; a network
  call can hang, and the queue is serial.
- Queue concurrency is global and serial. If it is relaxed, model it as per-runtime capacity
  (`IrisSingleFlight` is the pattern) rather than lanes in the registry protocol.
- Evaluate `SWIFT_UPCOMING_FEATURE_NonisolatedNonsendingByDefault` after current Swift 6.0
  strict-concurrency behavior remains stable across release builds.
