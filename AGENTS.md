# Repository Guidelines

## Build, Test, and Development Commands
- CLI build (Debug): `xcodebuild -project "Mochi Diffusion.xcodeproj" -scheme "Mochi Diffusion" -destination "platform=macOS" -configuration Debug`
- Lint/format: `swift format lint -p -r ./`  
- Always ensure the project builds cleanly after any change. Resolve any lint warnings before committing any changes.

## Commit & Pull Request Guidelines
- Commit message format (from `CONTRIBUTING.md`):  
  `type: short summary` with types `build|ci|docs|feat|fix|perf|refactor|test`.  
  Include a body (≥20 characters) except for `docs` commits.
- Pull requests are squash-merged and must pass the gated check-in (build + `swift format` lint).  
  Include a clear description of changes; for UI changes, attach a brief screenshot when helpful.

## High-Level Design Flow
- Runtime ownership boundaries:
  - `MochiDiffusionApp` composes runtime dependencies once (state, services, controllers) and injects them through initializers/environment. Avoid direct `.shared` singleton access for app-owned services.
  - `ConfigStore` (`@MainActor`) owns persisted user inputs (`modelDir`, `imageDir`, `prompt`, `steps`, etc.) via `@AppStorage`.
  - `GenerationController` (`@MainActor`) translates UI/config state into `GenerationRequest` values and submits work to `GenerationService`.
  - `GalleryController` (`@MainActor`) handles gallery I/O orchestration (load/import/save/remove/sync) through `ImageRepository`.
  - `GenerationService` (`actor`) is the queue/worker boundary. It serializes requests, selects the concrete generator, persists output files, and emits `Snapshot`/`GenerationResult` streams.
  - `GenerationState` (`@MainActor`) is the UI-facing status model (`ready/loading/running/error`) updated by `GenerationService`.

- Model and pipeline resolution:
  - `ModelRepository` (`actor`) discovers model directories and returns `[any MochiModel]` (`SDModel` or `IrisFluxKleinModel`).
  - Request-time model selection is represented as `GenerationPipeline` (`.sd` or `.iris`) inside `GenerationRequest`.
  - Pipeline-specific behavior is encapsulated in generators:
    - `SDImageGenerator` for Core ML Stable Diffusion models.
    - `IrisFluxKleinImageGenerator` for Iris FLUX.2 generation.
  - `GenerationPipeline` exposes normalized UI-facing helpers (`displayName`, `mlComputeUnit`, `effectiveStepCount`, `effectiveScheduler`).

- Concurrency defaults (project settings):
  - `SWIFT_VERSION = 6.0`
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  - `SWIFT_STRICT_CONCURRENCY = complete`
  - Domain/service value types that cross actor boundaries are explicitly `nonisolated` + `Sendable` where required.

- Configuration and metadata lifecycle:
  - User-selected runtime inputs live in `GenerationRequest` (`stepCount`, `scheduler`, `strength`, etc.).
  - Pipeline capability and effective behavior live in `MochiModelConfig.generationCapabilities` and `GenerationPipeline` helpers (for example, `effectiveStepCount` and `effectiveScheduler`).
  - The persisted image metadata contract lives in `metadataFields` and is embedded through `SDImage.metadata(including:)`.
  - Imported-image "what was actually present" is tracked as parsed `presentFields` and carried through gallery/repository records as `metadataFields`.
  - Treat these as intentional boundaries: request-time inputs, pipeline-time behavior resolution, export metadata contract, and import-time metadata presence should remain distinct.

- Persistence and gallery ingestion:
  - Generation output is always materialized as `GenerationResult` (`metadata` + encoded image bytes).
  - `GenerationService` writes image bytes through `ImageRepository`, then emits saved `GenerationResult` including `imageURL`.
  - `GenerationController` converts saved results into `ImageRecord`/`SDImage` and inserts them into `ImageGallery` with per-image `metadataFields`.
  - Imported files use the same parse path (`createImageRecordFromURL`) so generated and imported images share one metadata interpretation path.

- Filesystem observation flow:
  - `FolderMonitor` is owned directly by controllers; each controller instantiates monitors for its watched path(s).
  - Monitor callbacks schedule targeted refresh/sync operations (`loadModels`, `syncImages`, etc.) on `@MainActor`.

### Potential improvements
- Align sidebar controls to `generationCapabilities` so unsupported options (for example, `negativePrompt`, `guidanceScale`, `controlNet`) are hidden/disabled by model instead of silently ignored downstream.
- Move metadata parsing/formatting helpers from global functions into a dedicated metadata codec type (for example, `MetadataCodec`) to clarify ownership and improve testability.
- Replace temporary `@unchecked Sendable` on generator classes with stricter ownership/isolation (for example, actor-backed generators) once pipeline migration stabilizes.
- Evaluate `SWIFT_UPCOMING_FEATURE_NonisolatedNonsendingByDefault` after current Swift 6.0 strict-concurrency behavior remains stable across release builds.
