# Gallery Work and `temp/MochiDiffusion` Carry-Over

**Status:** open. Working document for the `feature/multi-image-and-gallery` branch.
**Created:** 2026-08-28
**Delete this file** when the branch merges — it is a handoff, not a design record.
Anything here that turns out to be a durable decision belongs in a commit message, a
code comment, or [Engine-Future-Work.md](Engine-Future-Work.md).

## 0. Orientation

This branch does two unrelated things, in order: **multi-image input support** (done)
and **gallery memory/performance work** (not started). Both draw on a 6.1 prototype
at `~/temp/MochiDiffusion`, a plain working-tree copy with no git history that
predates the whole engine refactor. Nothing there merges; everything is
adapt-the-idea.

**Standing instruction for anything pulled from that copy:** be functionally as
similar as possible. The implementation may differ where the codebases have drifted,
but **UI elements should be copied closely** rather than reinterpreted. An earlier
attempt rewrote `InputImagesView` from scratch and lost its design; the correction is
in commit `a97f25f`.

### Build and verify

```bash
xcodebuild test -project "Mochi Diffusion.xcodeproj" -scheme "Mochi Diffusion" -destination "platform=macOS" -configuration Debug
```

```bash
swift format lint -p -r ./
```

Both must be clean before anything merges. At the time of writing: **521 test-case
executions, 0 failures**, no compiler warnings.

**Worktree gotcha:** `iris.c` is a **git submodule** (`antirez/iris.c`), and a build
phase clones it. A fresh worktree needs `git submodule update --init --recursive` or
the build fails with a confusing clone error. Do *not* symlink it from the main
checkout — that blocks the clone and breaks the build in a different way.

### Commits so far on this branch

| | |
|---|---|
| `89a00ea` | Input images become a list; `InputImagesConstraint` gains `maxCount`; `prepared(_:resize:)` pairs data with names in one pass |
| `a0da0dc` | Klein takes up to four references via `iris_multiref`; no budget fitting yet |
| `a97f25f` | Ports the prototype's `InputImagesView`, `ImageWellView`, crop popover and reference-budget estimator; budget fitting restored, scoped to Iris |
| `a3ccde3` | Splits `StartingImageConstraint` from `InputImagesConstraint`; two independent constraints, two views, two controller stores |

## 1. Task: inject `ImageGallery` (do this first)

A mechanical refactor with **no behaviour change**, worth doing before the thumbnail
work because it is what makes gallery loading testable — and gallery loading is
exactly what the thumbnail work changes.

`ImageGallery.shared` is reached from 37 sites:

| File | Sites | Notes |
|---|---|---|
| `Support/GalleryController.swift` | 16 | the main one; the prototype injected here |
| `Support/GenerationController.swift` | 14 | mostly `selected()` for copy-to-prompt |
| `Support/GenerationService.swift` | 3 | `images.endIndex`, `setCurrentGenerating`, `clearCurrentGenerating` |
| `Support/Functions.swift` | 1 | `updateMetadata` |
| `Views/AppView.swift` | 1 | `.environment(ImageGallery.shared)` — the real injection point |
| `Views/InspectorView.swift` | 1 | `#Preview` only |
| `Views/GalleryToolbarView.swift` | 1 | `#Preview` only |

Shape, following the prototype (its `GalleryController` has 21 `imageGallery`
references and its `GenerationController` takes one too, both with a convenience init
for production):

```swift
init(configStore: ConfigStore, imageGallery: ImageGallery, …)
convenience init(configStore: ConfigStore, …)   // passes ImageGallery.shared
```

Same seam pattern the project already uses for `ConfigStore(store:)`,
`EngineRegistry(engines:)`, `SecretStore` and `HTTPSession`.

**The trap:** a half-finished injection *compiles*. Leftover `ImageGallery.shared`
calls stay valid, so nothing fails loudly. Finish by checking the count is zero
outside `AppView` and the two `#Preview` blocks:

```bash
grep -rn "ImageGallery.shared" "Mochi Diffusion"
```

`GenerationService` is an actor and reaches the gallery through `MainActor.run`, so it
needs the reference handed in rather than captured — check that it does not end up
holding a main-actor object across an isolation boundary.

Worth adding once the seam exists: a `GalleryController` test that loads from a
scratch directory into its own `ImageGallery`. `ControllerLifecycleTests` is the only
file that touches `GalleryController` today and it only covers shutdown.

## 2. Task: gallery thumbnail architecture

The largest remaining user-facing win, and independent of the engine layer.

### The problem

`ImageRecord` carries `var imageData: Data`, and `Functions.createSDImage(from:)`
decodes a **full-size `CGImage` per gallery entry**. A decoded 1024×1024 image is
about 4 MB, so a few hundred gallery images is gigabytes resident. The prototype's
`ImageRecord` has no `imageData` field at all: the gallery load path never decodes,
and thumbnails are read from disk on demand.

Note the engine work *added* `imageData` (for inserting generation results), so
relative to where the prototype was heading, this repo moved the wrong way.

### What to port

Both live at the top of the prototype's `Views/GalleryItemView.swift`:

- **`GalleryThumbnailProvider`** — an actor with an `NSCache` (`countLimit: 256`) and
  an in-flight request dictionary so scrolling does not spawn duplicate decodes of the
  same path. Thumbnails via `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceCreateThumbnailFromImageAlways`, `…WithTransform`, and
  `kCGImageSourceShouldCache: false`.
- **`GalleryFullImageProvider`** — full images on demand, for QuickLook and sharing.

Both are handed to views through environment keys (`\.galleryThumbnailProvider`), and
constructed once in `MochiDiffusionApp`.

The sizing detail is the careful part and should be copied exactly:
`GalleryItemView.thumbnailPixelSize(for:)` takes the **actual rendered geometry ×
`displayScale`**, rounds up into 32px buckets and clamps to 64…1024. The bucketing is
what keeps the cache key stable across small window resizes instead of thrashing on
every point of drag.

### The four call sites that assume `sdi.image` is resident

These are what breaks when the image is no longer decoded at load:

| Site | What it needs |
|---|---|
| `Views/GalleryItemView.swift:75` | the thumbnail — the main change |
| `Views/GalleryToolbarView.swift:71` | share sheet; prefers `sdi.path`, falls back to the image |
| `Support/QuickLookState.swift:44` | the prototype prefers the path and only materialises an image when there is none |
| `Views/GalleryView.swift:97` | drag-out; already prefers `sdi.path` and falls back to a temp file |

### Decide before starting: does `ImageRecord.imageData` survive?

The open question from the discussion, unresolved:

- It is what forces the full decode on the gallery load path.
- But it is *also* how a freshly generated result reaches the gallery, where the bytes
  are already in hand and re-reading from disk would be wasteful.

So the likely answer is **`imageData: Data?`** — populated for generation results, nil
for disk-loaded records — rather than removing it. Settle this first, because it
decides whether the change is contained to rendering or reaches into the insert path
too.

## 3. Remaining `temp/MochiDiffusion` carry-over

Already landed, for reference: `IrisReferenceImageSupport` (crop, processor, budget
estimator), `CropSelectionView` and the crop popover, the `InputImagesView` layout,
`StartingImageView`, `ImageWellView`'s multi-file drop and overlay remove button,
`normalizedRGBA8Image()`, and `attentionHeadCount`.

### `GenerationConfigRestorer` + `GenerationConfigEditing`

One restorer for both "copy options from a gallery image" and "copy options from a
queued request", which are still two unrelated paths here
(`GenerationController.copy*ToPrompt` and `JobQueueView.copyOptionsToSidebar`). Came
with 421 lines of tests in the prototype.

Two ideas worth keeping even if none of the code is:

- **`compatibleRestoreMetadataFields`** intersects the source's fields with the
  *destination model's*, so restoring a Core ML image's options while a Klein model is
  selected does not push values that model ignores.
- **It restores the images**, resolving `startingImage` and `inputImages` filenames
  against the gallery. `copyToPrompt` here still restores only numbers and text — copy
  options from an img2img result today and you get the seed and steps but not the
  picture.

**Do it better than the prototype:** intersect against the destination model's
**`OptionConstraints`** (what it can accept) rather than its `metadataFields` (what it
records). That distinction did not exist when the prototype was written.

This got *more* valuable in `a3ccde3`: with two image sections, a restorer has to put
each image back in the right one, and `JobQueueView` now does that inline. That logic
wants to live in the restorer.

The prototype's version is unfinished — `case .scheduler` is commented out, with TODOs
for starting-image strength and ControlNet.

### Pipeline-cache invalidation test

The prototype's `SDImageGeneratorTests` is 44 lines, two tests, pinning that flipping
the safety toggle invalidates the cached SD 1.5 pipeline. `CoreMLEngineRuntime` still
caches a loaded pipeline and has no test suite of its own — and safety became a Core
ML-scoped setting in Phase 5, so the interaction changed since.

### Trivia

`ImageRepository.imageCount(imageDir:)` and `SDImage.transferFileURL()` — extractions
of logic this repo does inline. Take or leave.

### Deliberately skipped

- **All Lora**: `Flux2LoraLibrary`, `LoraNotesStore`, `LoraView`, and the
  `.lora`/`.loraStrength` metadata fields. Excluded by decision, not oversight.
- **The `NotificationService` static-enum refactor.** This repo already handles
  notification authorization, and converting to static methods would make it *less*
  injectable — which matters, because `NotificationController.shared` having no seam is
  the recorded reason the queue-teardown race cannot be pinned by a test. If you touch
  it, inject a protocol instead.
- **Anything capability-flag-shaped** (`supportsInputImages`,
  `GenerationCapabilitiesTests`). Superseded by `OptionConstraints`.

## 4. Also queued, unrelated to the gallery

**OpenAI input images.** The engine declares `inputImages: .unsupported` today, which
is honest: input images go to `/v1/images/edits`, which takes a multipart form rather
than the JSON streaming body `OpenAIEngineRuntime` currently builds. So this is a new
request path, not a raised number. The constraint layer already expresses what it
needs — `inputImages: .supported(maxCount:)` with no starting image, since the edits
endpoint takes references and no strength. Re-verify that against current API
documentation when implementing; §13.2 of the closed design doc records what was read
in August 2026, and the model list there is deliberately hand-maintained.
