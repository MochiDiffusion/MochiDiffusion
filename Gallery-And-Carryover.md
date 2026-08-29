# Gallery Work and `temp/MochiDiffusion` Carry-Over

**Status:** open carry-over record. The `feature/multi-image-and-gallery` branch merged
into `develop` at `4a4ea94`; the architecture is landed, but the review on 2026-08-29
found integration regressions and additional prototype work worth adapting.
**Created:** 2026-08-28

**Last reviewed:** 2026-08-29

This is no longer a branch handoff. Delete it when every accepted carry-over item below
has either landed or moved to a durable design record such as
[Engine-Future-Work.md](Engine-Future-Work.md).

## 0. Orientation

`~/temp/MochiDiffusion` is a plain working-tree snapshot of the unfinished 6.1 work,
with no Git history. It predates the engine refactor, so nothing there merges directly:
adapt the behaviour to the current ownership, identity and constraint model.

**Standing instruction for anything pulled from that copy:** preserve its behaviour and
UI closely where those still fit. An earlier rewrite of `InputImagesView` lost the
prototype's design; `a97f25f` is the corrected port.

**LoRA remains explicitly excluded.** `Flux2LoraLibrary`, `LoraNotesStore`, `LoraView`,
and the `.lora`/`.loraStrength` metadata fields are not carry-over candidates.

### Build and verify

```bash
xcodebuild test -project "Mochi Diffusion.xcodeproj" -scheme "Mochi Diffusion" -destination "platform=macOS" -configuration Debug
```

```bash
swift format lint -p -r ./
```

Both must be clean after a change. No build or test run was made for the 2026-08-29
read-only assessment.

**Worktree gotcha:** `iris.c` is a Git submodule (`antirez/iris.c`), and a build phase
clones it. A fresh worktree needs `git submodule update --init --recursive`; do not
symlink it from another checkout.

## 1. Landed from the prototype

### Multi-image and Iris UI

- `89a00ea` — input images become a list; `InputImagesConstraint` gains `maxCount`.
- `a0da0dc` — Klein takes up to four references through `iris_multiref`.
- `a97f25f` — prototype `InputImagesView`, `ImageWellView`, crop popover and reference
  budget estimator.
- `a3ccde3` — starting images and reference images become separate constraints, views
  and controller stores.

Also landed: `IrisReferenceImageSupport`, `CropSelectionView`, multi-file drops, the
overlay remove button, `normalizedRGBA8Image()`, and model-specific
`attentionHeadCount` discovery.

### Gallery ownership and memory architecture

- `80143a6` — injects the gallery into its consumers.
- `ff00aec` — records image dimensions without requiring decoded pixels.
- `dca4479` — renders the grid from on-demand thumbnails.
- `c87fa79` — removes the `ImageGallery` and `GenerationService` singletons.

The central design is complete:

- `ImageRecord.imageData` is optional: present for a fresh generation result and absent
  for a disk scan.
- `GalleryThumbnailProvider` is an actor with `NSCache`, in-flight request coalescing,
  ImageIO downsampling, and rendered-geometry/display-scale size buckets.
- `GalleryFullImageProvider` loads the few full-size images that are actually needed.
- Both providers are app-owned and injected through the SwiftUI environment.
- Production code has no `ImageGallery.shared` access.
- Gallery loading and provider behaviour have dedicated tests.

## 2. Gallery integration still to finish

The memory architecture deliberately leaves `sdi.image == nil` for images loaded from
disk. The 2026-08-29 review found two consumers that still assume it is resident.

### Inspector full-image and related-image loading

`InspectorView` enters its entire content only when the selected `SDImage` has a resident
`CGImage`. A disk-loaded selection therefore displays **No Info**, and its starting,
ControlNet and reference-image previews cannot resolve either.

Adapt the prototype's implementation:

- Inject `GalleryFullImageProvider` into the Inspector.
- Load the selected image asynchronously while keeping the metadata visible.
- Resolve related filenames case- and diacritic-insensitively against the injected
  gallery, then load those records through the same provider.
- Key the load task to selection and relevant gallery/path changes so stale work cannot
  replace a newer selection.

Add coverage for selecting a path-backed image whose `image` is nil and for resolving a
related image by filename.

### Set as Starting Image / Set as Input Image

`GenerationController.selectStartingImage(sdi:)` and `addInputImage(sdi:)` currently
guard on `sdi.image`, so both silently do nothing for disk-loaded gallery entries.
The context menu and Image command also always choose **Set as Starting Image**, even
when the current model accepts references instead.

Adapt the prototype's `selectReferenceImage(sdi:)` behaviour to current constraints:

- Load the image through the app-owned `GalleryFullImageProvider`.
- If `currentConstraints.inputImages` is supported, add it as a reference.
- Otherwise, if `currentConstraints.startingImage` is supported, use it as the starting
  image.
- Disable or omit the action if the model supports neither.
- Preserve the gallery filename in the corresponding metadata field.

Wire the context menu and keyboard command to that one operation and test both the Iris
and Core ML destinations with a path-backed image.

## 3. Generation restoration

### Keep the idea; redesign the implementation

The prototype's `GenerationConfigRestorer` unifies:

- copying all options from a gallery image; and
- copying all options from a queued request.

Those remain unrelated paths here: `GenerationController.copyToPrompt(_:)` restores only
scalar gallery metadata, while `JobQueueView.copyOptionsToSidebar()` contains model,
starting-image, reference-image and ControlNet reconstruction inline.

Keep these behaviours:

- Resolve an exact source model by `ModelID`, with display-name fallback only for legacy
  images.
- Select the destination model before deciding which options apply.
- Intersect the source image's `presentFields` with what the destination model accepts.
- Gate through `OptionConstraints`, not `metadataFields`: recording an option and
  accepting one are distinct contracts.
- Restore starting and reference images into their separate sections.
- Resolve gallery filenames against the injected gallery and load them through
  `GalleryFullImageProvider`; queued requests already carry their encoded pixels.
- Restore queued values from the request, because they were already resolved by `plan`.
- Keep a missing source model from clearing the current selection or enabling every
  source field.

Do not port `GenerationConfigEditing` mechanically. Prefer a deterministic value-type
restore plan, with a small `@MainActor` application layer for controller/store mutation
and an asynchronous image-resolution phase. The restorer should decide whether a field
applies, but it must not become a second value-normalization point: `plan` remains the
single place model constraints resolve a draft.

Known limits that tests and UI must state honestly:

- Saved image metadata does not currently record starting-image strength.
- It does not carry enough ControlNet identity to reconstruct a gallery source fully.
- Scheduler restoration is entangled with the engine-scoped scheduler work in
  `Engine-Future-Work.md`; do not silently restore an unknown sampler as DPM-Solver++.

The prototype's 421-line test file is useful as a behavioural inventory, not as code to
copy. Rewrite coverage around `ModelID`, `OptionConstraints`, missing models, the two
image sections, path-backed gallery images, and queued request payload-independent fields.

## 4. Core ML safety and pipeline caching

This is a live defect, not only a missing test.

`CoreMLEngineRuntime.loadPipelineIfNeeded` omits safety state from its cache key and
constructs every SD 1.5 pipeline with `disableSafety: true`. The per-request generation
configuration cannot enable a checker that was excluded when the pipeline was built.

Adapt the prototype's `makePipelineLoadOptions` idea:

- For SD 1.5, derive the constructor-time `disableSafety` value from the resolved Core ML
  payload, include it in the cache identity, and pass it to `StableDiffusionPipeline`.
- For SDXL and SD3, keep constructor-time safety out of the key because those pipelines
  use the per-request setting.
- Keep the existing model, ControlNet/link location, compute-unit and memory inputs in
  the same cache identity.

Adapt the prototype's two `SDImageGeneratorTests` and add a third assertion that changing
the toggle does not invalidate an SDXL/SD3 key unnecessarily.

## 5. Output filenames and image-directory handling — implemented 2026-08-29

The earlier carry-over list understated this as `ImageRepository.imageCount(imageDir:)`.
The useful prototype work is the surrounding filename and destination handling.

Filename construction is now shared by generation and `SDImage` export paths. Prompt text
is reduced to a bounded, human-readable filename component; path punctuation cannot become
a directory traversal, and blank or punctuation-only prompts use `Image` as a stable
fallback.

`ImageRepository` also treats caller-supplied names as filename components and owns
collision allocation. Generation writes and Save All preserve an existing file and choose
`-2`, `-3`, … suffixes. Allocation and writing are synchronous operations on the repository
actor, so concurrent app writes cannot choose the same candidate. This deliberately makes
the gallery-derived numeric count presentation only rather than relying on it for
uniqueness.

All repository operations now resolve an empty image-directory setting consistently,
including import and folder synchronization. The default location is injectable for tests.
Coverage includes prompt sanitization and fallback, the length cap, repository path
containment, duplicate and concurrent writes, Save All collisions, and default-directory
writes and imports.

## 6. Low-priority carry-over

### `SDImage.transferFileURL()`

Optional cleanup. Its path-first behaviour already exists inline in gallery drag-out and
Quick Look: return the existing file when there is one, otherwise materialise a resident
image in a temporary PNG. Port it only if centralising that duplication is useful. The two
prototype tests are worthwhile if it is ported.

### Gallery regression tests

The prototype also had tests that a generated result inserts a resident image without
losing its saved path, that repeated full-image requests use the cache, and that transfer
URLs prefer the original file. Current coverage handles most of the surrounding design,
but these are reasonable additions when their code paths are next touched.

## 7. Deliberately skipped or superseded

- **All LoRA work:** excluded by decision, not oversight.
- **`NotificationService` as a static enum:** do not port. Static methods are less
  injectable; if notification delivery is touched, introduce a protocol seam instead.
- **`GenerationCapabilities` and capability flags:** superseded by per-model
  `OptionConstraints`.
- **`SDImageGenerator`, `IrisFluxKleinImageGenerator`, `GenerationPipeline`, and their
  cancellation/update bridges:** superseded by engine descriptors/runtimes,
  `GenerationSession`, typed payload ownership and `IrisSingleFlight`.
- **`MessageBanner`:** superseded by separate discovery reporting and generation-outcome
  alerts.

No other non-LoRA prototype area stood out after comparing the source and test inventories.

## 8. Unrelated future item retained from the branch handoff

**OpenAI input images.** The engine declares `inputImages: .unsupported`, which is honest:
the edits endpoint takes a multipart form rather than the JSON streaming body
`OpenAIEngineRuntime` currently builds. This requires a separate request path, not merely a
higher constraint count. Re-verify the current API before implementing it; the model list
and endpoint details recorded in the closed multi-engine design were intentionally
hand-maintained.
