# Multi-Engine Design

**Status: CLOSED, 2026-08-28.** Phases 0–6 delivered. This document is the historical
record of the multi-engine work — what was built, where implementations deviated from the
design and why, which review findings were accepted and which were declined, and which
decisions were later reversed. It is no longer updated.

**Current guidance:** start with [AGENTS.md](AGENTS.md) for the architecture and agreed
release scope. Beads epic `MochiDiffusion-q73` owns the next-release work list. Draw Things
and Musubi are explicitly postponed; closed phases or historical beads do not create new
carry-over obligations.

**Deferred research:** [Engine-Future-Work.md](Engine-Future-Work.md) preserves Phase 6.5,
Draw Things / MediaGenerationKit and long-tail-option reasoning. It is not a release plan.
The later Musubi epic owns metadata integration decisions when that work resumes.

**Final revision:** 2026-08-28. Sections that were still forward-looking at close — §6.5 and
§13.3 — are stubs pointing to their new home; every other section describes work that exists.

**Reading this document.** Sections 1–9 and 11–15 describe the design at close. §10's
phase table records that historical milestone, not current release readiness.
Where a section describes what was built, it says so.
Where an earlier claim turned out wrong, the correction is inline rather than by deletion, so
the reasoning stays reviewable — §14 and §15 record two independent review passes, including
findings that were declined and why, and severity calls that disagreed with the reviewer.

It was a living document while the work was in flight, which is why several sections read as
a decision being argued rather than a fact being stated. That is deliberate: the argument is
the part worth keeping. Two decisions were reversed outright and both say so in place — the
engine picker listing every engine (§8), and the licensing conclusion for MediaGenerationKit
(now in [Engine-Future-Work.md](Engine-Future-Work.md) §5).

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
| Draw Things MediaGenerationKit | local + LAN + cloud | see §13.3 for dependency weight, maturity, and remote model listing |

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

- `MochiModelConfig` ([Model/MochiModel.swift at the pre-refactor revision](https://github.com/MochiDiffusion/MochiDiffusion/blob/e686551ee06cf0d9fc788d59f9282f9dea5e6dbd/Mochi%20Diffusion/Model/MochiModel.swift))
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

## 4. What blocked adding a third engine

Four closed sum types had to be edited in lockstep for every new engine. **Three are
gone as of Phase 2:**

1. ~~`GenerationPipeline`~~ — the enum of `.sd` / `.iris` with roughly ten switch-based
   accessors is deleted. Engines resolve their own values in `plan`.
2. ~~`PipelineModelAdapter`~~ — deleted; it restated the same taxonomy a second time.
3. ~~Generator selection~~ — closed in Phase 3. `GenerationService` asks the registry
   which engine owns the request and the engine makes its own runtime, so the switch and
   its `default:` arm are gone. Adding an engine no longer touches the queue.
4. ~~Model discovery~~ — each engine discovers independently behind `EngineRegistry`, and
   per-engine failures no longer take the whole model list down. `ModelRepository` is
   reduced to directory resolution and an existence check.

All four are now closed, and so are both transitional leaks Phase 2 left:

- ~~The queue downcast `request.payload as? CoreMLGenerationPayload`~~ to check the model
  still existed. The check moved into `CoreMLEngineRuntime`, so the queue no longer
  inspects a payload §5.4 says it must not.
- ~~`discoverModels` wrote a `controlnet` symlink~~ into every capable model directory on
  every folder-change event. `CoreMLEngineRuntime` creates it at load, for the one model
  being loaded, only when that load asks for ControlNet.

Of the three structural mismatches, two are resolved:

- ~~**`MochiModel.id` is a `URL`.**~~ Identity is `ModelID` (engine + key); `url` is
  optional on `EngineModel`, so a hosted model needs no fake path.
- **`GenerationRequest` is still flat**, but no longer merges every engine's options: the
  engine-specific half moved into an opaque `payload`, and the shared half now carries
  *resolved* values rather than raw sidebar input.
- ~~**`ConfigStore` cannot express dynamic keys.**~~ Partly resolved: it now takes an
  injectable `UserDefaults` store and persists the selection as one engine-qualified key.
  Per-engine namespacing still arrives in Phase 5.

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

Because `ModelID.key` is persisted data, its rules are specified and tested rather than
left to whatever `URL` happens to do. **Decided (implemented in `EngineIdentity.swift`,
pinned by `EngineIdentityTests`):**

- **A local key is the model directory's own name** — its `lastPathComponent` — not a
  relative path computed against the models root. Two measured behaviours rule the
  arithmetic version out. `FileManager.contentsOfDirectory(at:)` returns children prefixed
  `/private/var` even when handed a `/var` URL, while `resolvingSymlinksInPath()`
  normalises back the other way, so child and root disagree about the same prefix. And a
  model directory symlinked *into* the models folder — which `FileSystemStore` accepts,
  since it filters on the resolved path being a directory — resolves outside the root
  entirely, so stripping a resolved root off a resolved child would reject exactly those
  models. Discovery only enumerates direct children, so the last component *is* the whole
  relative path. It also drops the trailing slash that enumeration adds for real
  directories but not for symlinks.
- **Persisted and imported keys are identifiers, not paths.** They are matched against the
  models returned by discovery and are never appended to the models root. An unknown,
  malformed or stale key therefore selects no model rather than granting filesystem access.
  If a future feature needs to turn a key into a path, it must introduce and test validation
  at that new trust boundary instead of treating `ModelID` itself as filesystem authority.
- **Symlinks are preserved as written.** A symlinked model is keyed by the name visible in
  the models folder, which is the name the user sees and the only one stable against the
  link's target moving.
- **Keys are case-sensitive.** On a case-insensitive volume, renaming a model's case loses
  the selection and falls back to the first model — the same outcome as any other rename,
  and better than two keys comparing equal while naming different strings.

If a nested model layout is ever needed, the key becomes a relative path, and whatever
computes it must still not resolve symlinks in the child.

This is not hypothetical. Today a model's identity is the exact `URL`
`contentsOfDirectory` returned — symlinks already resolved (`/private/var/…`, not
`/var/…`) and carrying a trailing slash because it is a directory — and restore is plain
`URL` equality. A path naming the same directory in any other form misses, and the user
silently gets the first model instead of theirs. Nothing writes such a value today, since
`currentModelId.didSet` only ever persists a discovered id, so the defect is latent; it
goes live the moment anything else computes a model path. `ModelSelectionPersistenceTests`
pins it as a `withKnownIssue` that should start failing when Phase 2 lands relative keys.

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

**Not yet true, as of Phase 5.** `EngineModel` still declares `url: URL` — non-optional —
and still carries `tokenizerModelDir`, because every model is a local directory today and
nothing forced the issue. Both are Phase 6 prerequisites: a hosted model has neither, and
the test double standing in for one already has to invent a placeholder `url`. Moving them
behind the engine is part of adding the first hosted engine, alongside the constraint
vocabulary gaps in §6.

**Phase staging.** The protocol above is the Phase 4 shape. `OptionConstraints` does not
exist until Phase 4, so Phase 2 lands `EngineModel` carrying today's
`config: MochiModelConfig` (capabilities plus `metadataFields`) in that slot, and Phase 4
replaces the capabilities half with `constraints`. Do not block Phase 2 on the constraint
vocabulary — engine-qualified identity is independently valuable and the swap is
mechanical once every model already answers a per-model question.

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

**Phase staging.** Phase 2 introduces `plan` as a pure *move*: the per-engine branches now
in `GenerationController.buildGenerationRequest` and `PipelineModelAdapter` become each
engine's `plan`, producing the same values today's code produces. It does not yet resolve
anything against constraints — that is Phase 4, which is what makes `plan` the sole
resolution point. Staging it this way means Phase 2 can be verified by asserting the
request is byte-identical to what the old path built (§12).

`EngineSettings` likewise starts minimal in Phase 2 — the engine's model directory and
whatever else `discoverModels` needs — and grows into the per-engine store in Phase 5.
It is a parameter, not the persistence layer.

**One further addition, not yet made.** §6.5 moves the per-image metadata field set out of
`EngineModel` and into what `plan` returns, so that an engine whose models are described by
upstream data can resolve the set instead of declaring it. Phase 6.5, after the OpenAI
engine; nothing in Phase 6 depends on it.

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

A second consequence, from §13.3: for at least one engine a discovered model carries data
that request construction needs and cannot re-derive — Draw Things must replay the model
specification it learned during discovery back into the generation request. So the
aggregated discovery result is retained state, not a value recomputed per read. Cache it
per engine and invalidate on the engine's own discovery trigger.

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

### Decided before Phase 4

**Constraints live on the model, not on the engine.** `EngineModel.constraints`, replacing
the capability half of `MochiModelConfig`. Some are engine-wide facts — Iris never supports
a negative prompt — and an engine's model type restating them is the same small duplication
`config` already carries. `engine.constraints(for: model)` would spare that at the cost of
an indirection on the path the sidebar reads most.

**The size swap keeps working for paired Core ML models, behind an engine hook.**

Today `SizeView`'s swap calls `GenerationController.setSize`, which for a Core ML model
searches for a *different* model whose name prefix matches and whose orientation is flipped
— `foo_512x768` → `foo_768x512`. An earlier revision of this section proposed deleting it,
on the grounds that constraints cannot express "a sibling model has the other orientation"
and the heuristic's own comment calls itself hacky.

That was wrong: **it is released behaviour.** Both the swap button and `setSize`'s
model-prefix search are present at `v6.0`, and `setSize` has a second released caller —
`copySizeToPrompt`, behind the Info panel's copy-size button, which v6.0's notes list as a
feature. Removing the search would have quietly broken both. Phase 4 is a refactor with a
visible payload; it does not get to drop shipped features to make a type nicer.

So the relationship moves into the engine rather than out of the app. The descriptor gains
a resolution the engine performs over its own models:

```swift
/// The model this engine would use to produce `size`, when its models are
/// per-size variants. `nil` when there is no such model — the default, and what
/// every engine with freeform sizes returns.
func model(forSize size: CGSize, among candidates: [Model], current: Model) -> Model?
```

Core ML implements the name-prefix and orientation search it does today; Iris returns
`nil`. `GenerationController.setSize` and `copySizeToPrompt` route through it, which is what
removes the `as? SDModel` downcast from the controller and from `SizeView` without removing
the behaviour.

The swap button is then shown when the size is freeform (swap the two numbers, as now) or
when it is pinned *and* the engine offers a model for the flipped size. A lone fixed-size
model with no sibling hides the button — today it is shown and silently does nothing, so
that case gets better rather than worse.

**`plan` normalizes; it throws only when normalization is impossible.** §5.3 said Phase 4
makes `plan` reject unsupported values, which is too strong. The persisted width and height
will routinely not match a newly selected fixed-size model, and overriding them is correct
behaviour rather than an error — throwing there would turn every model switch into an error
banner. So `plan` clamps to range, snaps to step, and overrides pinned values silently,
because a constraint-driven sidebar already shows a pinned value as disabled and therefore
already told the user. It throws only for a combination no normalization can rescue, which
in practice means a wiring bug.

**`GenerationRequest.capabilities` goes away.** Its only consumer is
`JobQueueView.supportsStrengthControl`, which wants to know whether the request has a
strength value at all. A resolved `strength: Float?` answers that directly and matches how
`stepCount` and `scheduler` are already read from the request.

**Prompt token counting is not part of this.** `promptTokenLimit` moves into constraints,
but `tokenizerModelDir` stays where it is. It is a live measurement rather than a constraint
on a control, and it only *has* to change when a hosted engine has no directory to tokenize
— so it moves in Phase 6, where there will be two implementations to design against
instead of one.

**Control visibility is a pure function, and there are no view tests.** Each control asks
the constraints a question that can be unit-tested — in the event `isSupported`,
`isEditable` and `bounds` on the constraint itself rather than a `shows…` helper per
control, which is the same property with less vocabulary. `ModelVisibilityTests` pins the
answers for both real models. The views stay thin enough that the untested part is only the
wiring, and the repo has no view-test infrastructure worth adding for this.

### Learned while building it

**Snapping belongs to the slider, not the constraint.** The first cut gave guidance scale
`step: 0.5` and strength `step: 0.05`, mirroring the sliders — and a typed 0.42 became 0.40.
The Phase 2 entry-gate tests caught it. Nothing in Core ML requires either value to land on
a grid, and `MochiSlider` already rounds to its own step when it writes, so a constraint
that snaps is moving a number the user typed for no reason the model cares about. Both are
clamp-only; `DoubleConstraint.range` takes an optional step for the cases that do need one.
Size is the genuine opposite: latent dimensions really are multiples of 16, so it snaps.

The general rule: **a constraint says what the model accepts; granularity is a UI
affordance.** Worth keeping in mind for the hosted engines, where quality levels and
aspect ratios *are* genuinely enumerated by the API.

**Bounds must match the released controls — including the ones that are not really
bounds.** Two separate versions of this mistake, found on two separate passes.

The first invented `0.05...0.95` for strength where the shipped slider is `0.0...1.0`, which
would have clamped persisted values at both ends.

The second was subtler and worse: `steps` and `numberOfImages` were given `1...50` and
`1...100`, which are what the sliders span — but both sliders pass
`strictUpperBound: false`, so a *typed* value above the maximum is deliberately kept. The
constraint clamped it, so the sidebar could show 75 steps while the request generated 50.
That is the exact failure mode the phase exists to remove, reintroduced in the fix for it.
`IntConstraint.range` now carries `acceptsBeyondUpperBound`, which maps straight onto
`strictUpperBound`, and the views read it rather than hardcoding it.

Constraints for an existing engine are a description of what already works, not an
opportunity to tidy the numbers. The generalisation: **read the control, not just its
declared range** — a range plus a flag that widens it is still the contract.

**A raw value used as display text is an identifier in disguise.** `Scheduler`'s raw values
were shown in Settings, the Inspector and the queue while also being persisted in
`UserDefaults` and written into image metadata. §6 requires stable ids separately from
labels, and this was in breach the whole time: the first attempt to reword or localise a
scheduler would have orphaned stored preferences and stopped existing images parsing.
`displayName` now carries the label and `rawValue` stays the identifier, so nothing had to
migrate. A test pins the identifiers precisely because they must not drift.

**A per-model option in a model-agnostic window will disagree with the model.** The
scheduler picker lives in Settings, which never saw a model, so a distilled model pinned
Flow Match in `plan` while Settings still offered PNDM. Settings now reads
`currentConstraints` and shows a pinned scheduler disabled, the same way the sidebar shows
pinned steps. Phase 5 should decide whether the control belongs in the sidebar instead —
this fix makes it correct, not well-placed.

**`OptionConstraints.unconstrained`** is what the sidebar shows with no model selected —
every control visible with its pre-constraint bounds. Hiding controls in that state would
make the sidebar flicker as discovery finishes, and an empty model list already reports
itself.

Engine-specific long-tail options (Draw Things will have many) are deferred to Phase 7 as
a declarative `[OptionSpec]` bag. We deliberately do *not* start there: a fully
declarative sidebar would cost us `SizeView`'s swap button, the ControlNet image wells,
and straightforward localization.

### `stepCount` and `scheduler` are non-optional; a hosted engine must invent both (fixed)

**Done.** `GenerationPlan` and `GenerationRequest` now carry `stepCount: Int?` and
`scheduler: Scheduler?`, and `plan` no longer falls back to the raw draft value when a
constraint reports `.unsupported`. The resolved values moved into `CoreMLGenerationPayload`
and `IrisGenerationPayload`, which is where `strength` and `guidanceScale` already lived —
so a runtime that uses an option reads it from its own payload, and one that does not is
never asked to invent it.

Two copies of each value now exist, request and payload, which is the arrangement Phase 4
existed to remove. `GenerationRequestBuilderTests.payloadAgreesWithRequest` pins them equal
for both engines, so a plan that resolved one and forgot the other cannot pass.

Also corrected while there: `JobQueueView`'s step-count and scheduler rows gated on
`metadataFields` — "does the image record this" — where `strength` and `guidanceScale`
already gated on the plan optional — "does the model use this". The queue should say what
the job is about to do, so all four now use the optional. No behaviour change today, since
both local engines declare all four.

The `nil` path has no production model to exercise yet, which is expected: no engine
declares these unsupported until a hosted one does.

The original finding follows.


Phase 5 made `strength` and `guidanceScale` optional in both `GenerationPlan` and
`GenerationRequest`, with the right reasoning: `nil` means "the model does not use this at
all," so the queue omits the row rather than printing a number that had no effect.

`stepCount: Int` and `scheduler: Scheduler` did not get the same treatment, and both are
options a hosted engine has no concept of. `IntConstraint.unsupported` exists and
`resolved(_:)` returns `nil` for it, but the plan has nowhere to put that `nil`, so an
engine without steps has to coerce a number. `metadataFields` keeps the invented value off
screen, which means the coercion is invisible rather than harmless — exactly the shape of
the bug Phase 4 existed to remove, just moved down a layer.

`scheduler` is the worse of the two and is already analysed at length in §6's "Learned
while building it": it is a Core ML type serving as cross-engine vocabulary, and it needs
an engine-scoped identifier rather than an optional. `stepCount` needs only the same
`Optional` treatment `strength` and `guidanceScale` already got.

Both are small mechanical changes and both are cheaper before Phase 6 than during it.
Doing them inside Phase 6 means a vocabulary change, a new option kind, a new transport
and a new error taxonomy landing in one reviewable unit.

### The vocabulary is narrower than a hosted engine needs

Phase 4 implemented only the constraint kinds the two local engines need, which was the
right call — but it means **Phase 6 begins with a constraint-vocabulary extension, not an
API client.** Two specific gaps:

- **`SizeConstraint` cannot express a joint width/height rule.** It is `.pinned([CGSize])`
  or `.freeform(range:step:)`, and `.freeform` bounds each dimension independently.
  **Resolved by the Phase 6 research (§13.2, D1): an `.aspectRatios` case is *not* what is
  needed.** The hosted API takes pixel `WIDTHxHEIGHT` with both edges multiples of 16 —
  which `.freeform(range:step:)` already says — but also caps the long:short ratio and
  bounds total pixels, and those are joint constraints on the pair. So `.freeform` grows
  limits, and `resolved(_:)` becomes the first one that must move both dimensions. `SizeView`
  needs no third presentation.
- **`EngineModel.url` is non-optional, and `tokenizerModelDir` is on the protocol.** Both
  exist because every model is a local directory today; a hosted model has neither. §5.2
  specified `url: URL?` and it was implemented non-optional — the protocol's own doc comment
  and a test comment in `EngineDiscoveryTests.FolderIgnoringEngine` both already record this
  as a Phase 6 prerequisite. The change looks small: the only generic use of `url` is
  `ModelRepository.modelExists(_ model: any EngineModel)`, and its one caller passes a
  concrete `SDModel` from a payload, so the parameter could take a `URL` and `url` could
  leave the protocol entirely. `tokenizerModelDir` is the harder half, since the sidebar's
  prompt token counter reads it generically.
- **There is no `quality` constraint at all.** `MetadataField.quality` exists and
  round-trips — it is pre-engine vocabulary — but no model declares it, no constraint
  describes it, no sidebar control edits it, and neither `GenerationDraft` nor
  `GenerationPlan` carries it. A hosted engine with quality tiers needs the whole chain:
  constraint, draft field, plan field, sidebar control, and metadata wiring.

- **`Scheduler` is a Core ML type being used as cross-engine vocabulary.** It
  `import StableDiffusion`, its own comment describes it as "Schedulers compatible with
  `StableDiffusionPipeline`", and `convertScheduler` maps it one-to-one onto
  `StableDiffusionScheduler`. `OptionConstraints.scheduler` is a
  `ChoiceConstraint<Scheduler>`, so that Core ML enum is the vocabulary every engine has to
  express its sampler in.

  It holds today only because Iris has no choice to express: `IrisEngineRuntime` never
  passes a sampler to the C library — flow matching is fixed inside it — and uses the value
  only to write metadata, resolved from `.pinned(.discreteFlowScheduler)`. Core ML is the
  one engine that consumes it, at `pipelineConfig.schedulerType`.

  It breaks as soon as a second engine offers a real choice. Draw Things has its own
  sampler list, and those cases cannot be added to this enum without Core ML offering them
  too, because `SDModel` declares `.oneOf(Scheduler.allCases)` — and `convertScheduler`
  would need to map a case with no `StableDiffusionScheduler` equivalent. The fix is an
  engine-scoped identifier: a stable string per scheduler, each engine declaring its own
  set and mapping to its own runtime type.

  **Related import defect, worth fixing whenever this is touched.** `MetadataCodec` parses
  the scheduler into the enum (`Scheduler(rawValue:)`), and `createImageRecordFromURL`
  falls back to `.dpmSolverMultistepScheduler` when that fails — while `presentFields`
  still records `.scheduler` as present. So an image whose metadata names a scheduler this
  build does not know imports claiming DPM-Solver++, and the Info panel displays a
  scheduler the image never used. Silently attributing the wrong value is worse than
  showing none. Metadata should carry the scheduler as the opaque string it is on disk,
  and resolve it to a known case only where one is needed.

So "add the OpenAI engine" is at least five separable pieces of work: the two vocabulary
extensions above (which belong conceptually with Phase 4), indeterminate progress, the
error taxonomy, Keychain storage, and the client itself. Size Phase 6 accordingly rather
than discovering this at implementation time.

## 6.5 Metadata fields are resolved, not declared — moved

**Moved to [Engine-Future-Work.md](Engine-Future-Work.md) §4** on 2026-08-28, in full.

Designed and deliberately not built. It alters `EngineModel` and `GenerationPlan`, is a
prerequisite for nothing that shipped, and is a prerequisite for all of the Draw Things work.
The two hand-declared fields it was meant to reclaim — `.revisedPrompt` and `.quality` on the
hosted engine — are still hand-declared.


## 7. Persistence and migration

```
SelectedEngine                 -> EngineID
Engine.<id>.SelectedModel      -> ModelID (encoded)
Engine.<id>.Options            -> JSON blob of engine-specific values
```

Shared, and deliberately **not** namespaced: `ModelDir`, `ControlNetDir`, `Prompt`,
`NegativePrompt`, `Seed`, `NumberOfImages`, `Width`, `Height`, `ImageDir`, `ImageType`.
A prompt should survive an engine switch.

`ConfigStore`'s one-property-per-key pattern cannot express dynamic keys, so add an
`@Observable EngineSettingsStore` reading and writing `UserDefaults` under a prefix.
`ConfigStore` keeps the genuinely global values.

### Decided: one shared models folder, not one per engine

**Decision (2026-08-27): `ModelDir` stays global.** Both local engines continue to scan
the same folder, and a per-engine models directory is not built.

An earlier draft made `ModelDir` per-engine, on the grounds that Klein's multi-gigabyte
diffusers trees and Core ML's `.mlmodelc` bundles are different enough to want separate
homes, and that separate folders would end the double scan. Rejected: it buys organisation
users have not asked for, at the cost of a third migration and a settings surface that
grows a folder picker per engine. Users with one mixed folder keep working unchanged.

Two consequences follow, and both are now Phase 5 obligations rather than optional:

- **Discovery must coalesce per directory.** With a shared folder this is permanent, not a
  transitional state: every folder-change event otherwise triggers one full enumeration per
  engine, and every subdirectory is sniffed by every engine. Coalesce the enumeration and
  hand each engine the same child list to apply its own recognition rules to. §5.5 raised
  this as a wrinkle; it is now a requirement.
- **`EngineSettings` keeps `controlNetDirectory` for every engine**, including Iris, which
  ignores it. §5.3's comment calls this a Phase 5 cleanup; with one shared folder there is
  nothing to clean up, so the comment should be corrected to say the field is global and
  deliberately so.

**`Width`/`Height` also stay global.** The earlier rationale — Core ML pins size per model
— was answered by Phase 4 instead: `SizeConstraint.resolved(_:)` already overrides the
configured size for a pinned model, so the stored value is only ever the freeform value the
sidebar shows when a model permits one. Namespacing it per engine would preserve two copies
of a number the constraint layer resolves anyway.

### Phase 2 scope versus Phase 5

The key layout above is the Phase 5 end state. §10 puts the per-engine settings store and
the engine picker in Phase 5 but the migration in Phase 2, which needs resolving: Phase 2
migrates the legacy `Model` URL to a **single, engine-qualified selection** —
`SelectedModelEngine` plus `SelectedModelKey` — and both local engines keep sharing one
`ModelDir`. Remembering a *separate* model and directory per engine is Phase 5, and arrives
with the picker that makes per-engine memory observable in the first place.

The legacy `Model` key is left in place rather than deleted. Migration is gated on the new
keys being absent, so it runs once, and leaving the old value costs nothing while making a
downgrade less destructive.

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

**Revised 2026-08-27: the picker lists only engines that can be generated with.** The
original decision was to list every registered engine with its reason inline, on the
grounds that hiding an unconfigured engine makes it undiscoverable.

That rationale is satisfied by Settings ▸ Engines, which lists every engine
unconditionally — and satisfies it better than a greyed-out picker row does. Settings is
where you configure; the sidebar is where you work. Putting the discovery burden on the
surface a user looks at for every generation was the wrong division, and it gets worse with
each engine added: Draw Things would make four, three of them unusable for most people.

The rules:

- **Usable** means `availability == .ready` *and* the engine has at least one model. Both
  halves are needed and neither implies the other: a local engine is ready as soon as its
  folder exists but has no models until one is put there, and a hosted engine always has a
  model but is not ready until a key is entered.
- **The selected engine is always listed**, even once it stops being usable. `restoreSelection`
  deliberately keeps a chosen engine whose models have disappeared so the picker can say why;
  hiding it would leave the selection pointing at something absent from its own picker and
  take the explanation with it.
- **When nothing is usable the picker holds a placeholder**, an em dash, with a caption
  naming the two ways out. Not a registered engine and not selectable — an engine is a thing
  that can generate, and this is not one. It is plainly a placeholder, so it can come and go
  without looking like something was removed, which is the objection to a *real* engine
  disappearing. The sidebar renders `OptionConstraints.unconstrained` in that state, which it
  already did for "no model selected", and Generate is already disabled on
  `currentModelId == nil`.

Rejected: always listing Core ML Stable Diffusion as a floor. It would privilege one engine
permanently, which is the same litter for anyone who only uses another one.

Empty-engine case: engine selected, no models available → disable Generate and show the
reason. Do not silently fall back to another engine's model.

`Views/SettingsView.swift` grows a per-engine section. With one shared models folder
(§7) that section holds no paths for the local engines — Core ML's compute units, reduce
memory and ControlNet folder, nothing yet for Iris, and in Phase 6 the hosted engine's key
and host. Shape TBD in Phase 5; likely a list of engines rather than the current fixed
tabs, but with two local engines contributing little, a flat section per engine may be
enough.

Phase 5 ships as one unit rather than splitting the settings layer from the picker
(decided 2026-08-27), so the picker and the per-engine selected-model memory arrive
together — which is what makes per-engine memory observable at all.

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

**Container check (verified 2026-08-26).** Newline-separated captions are only safe if
every container preserves embedded LF in the IPTC caption byte for byte. If any of them
normalised LF to CRLF, every field would decode with a trailing `\r` and numeric fields
would silently parse as nil. Round-tripping a multi-field caption through
`CGImageDestination` was confirmed identical for **PNG, JPEG and HEIC** — the three types
`SettingsView` offers. The round-trip suite only covers PNG, so this invariant is
since verified by CI: the image round-trip test is parameterized over all three
`UTType`s, so a future container change cannot break the format silently.

### 9.3 New fields

- `.engine` — engine identity
- `.modelKey` — the engine-qualified model key, alongside the existing human-readable
  `.model` name for display
- `.aspectRatio` — for engines that express geometry that way
- `.revisedPrompt` — OpenAI rewrites prompts and returns the revision
- `.host` — for remote generation

Existing images carry no `Engine` key, and its absence must mean "legacy, infer from the
other fields," never "corrupt."

Which of these keys a given image carries is a per-image question, not a per-model-type
one — see §6.5, which moves the field set from a static declaration on `EngineModel` to
something `plan` resolves, and rules on what belongs in this vocabulary at all.

**Write `.engine` and `.modelKey` in Phase 2, not later.** Engine identity exists as of
Phase 2, and additive keys are now free — the codec skips unknown keys leniently and old
readers are already excluded (§9.2). If we defer these keys to Phase 6, every image
generated during Phases 2–5 is permanently unqualified legacy data, and §9.4's
name-matching fallback has to cover our own recent output rather than only pre-engine
history.

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
| 2 | Engine descriptor/registry, `EngineID`/`ModelID`, independent discovery, migration, `.engine`/`.modelKey` metadata keys | none | **done** |
| 3 | Engine runtime and session boundaries; request-scoped cancellation; remove serialization-assumption `@unchecked Sendable`; move generator selection, the payload downcast and the ControlNet symlink write out of the queue and discovery (§4) | ordered progress, no cross-job previews | **done** |
| 4a | Constraints model; `plan` as the sole resolution point; request carries resolved values | none | **done** |
| 4b | Sidebar driven from constraints; size swap routed through the engine | unsupported controls hide; step count stops lying | **done** |
| 5 | Engine picker, `EngineSettingsStore`, per-engine selected model, Settings restructure, coalesced discovery (§7). Shared `ModelDir`; **no** per-engine model directories | the feature as described | **done** |
| 6 | OpenAI engine, per §13.2 (D1–D10). `EngineModel.url` dropped, `SizeLimits`, idle timeout and `requestExpired`, Keychain-backed credential, quality vocabulary, the streaming client, the Settings field and the sidebar row, and the discovery-message fix §15 needed before it could be registered. D3 withdrawn as needing no code | first hosted engine | **done** |
| — | Everything after Phase 6 is **out of scope for this document** and moved to [Engine-Future-Work.md](Engine-Future-Work.md): Phase 6.5 (metadata resolved not declared), Draw Things, declarative long-tail options, and deferred polish | | not scheduled |

**Entry gate for Phase 2: satisfied.** The two regression suites in §12 have landed —
`buildGenerationRequest` is pinned field by field, and the model-selection restore contract
the migration must preserve is covered. The migration's own tests are written with the
migration, in Phase 2.

### Phase 2 progress

- **Engine-qualified identity** — `EngineID`/`ModelID` with decided key rules (§5.1). Done.
- **Identity adopted end to end** — `MochiModel` is now `EngineModel` with `id: ModelID`;
  `GenerationController.currentModelId` and the persisted selection are engine-qualified.
  Done.
- **Preference migration** — legacy `Model` URL to a single `SelectedModel` value,
  idempotent, folders untouched. Done.

  Two review findings changed how, both worth recording:

  - The engine is recovered by matching **what discovery just found**, not by re-running
    recognition. A first attempt called `IrisFluxKleinModel.init?` and `SDModel.init?` and
    described itself as frozen, which it was not: those are live sniffers that Phases 3
    onward rewrite, so relaxing Klein's required-file list would have silently changed
    which engine a legacy URL migrated to — and because users upgrade at different times,
    two users with identical preferences would migrate differently depending on which
    version they landed on. The only frozen part is now a two-element preference order
    (Iris, then Core ML) reproducing the old sniff order, and engines absent from that list
    are ignored as candidates, so an engine added later can never claim an old selection.
  - The selection is **one** stored `"engine:key"` string, not two keys. Two
    `UserDefaults.set` calls reach `cfprefsd` as two messages, so a process killed between
    them could leave a new engine beside an old key — a pair that looks valid, names
    nothing, and resets the selection. One value cannot tear. Parsing splits on the first
    colon, since engine ids never contain one but a model key legally may.
- **Engine descriptors, registry, independent discovery** — done.
  `GenerationEngineDescriptor` with `AnyGenerationEngine` erasure, `EngineRegistry` running
  per-engine failure-isolated discovery, and `CoreMLStableDiffusionEngine`/`IrisEngine`
  each applying only their own recognition rules. The sniff chain and
  `kleinTakesPrecedenceOverCoreML` are gone; a directory both engines recognise is now
  offered twice under distinct ids. `ModelRepository` keeps only path helpers and
  `modelExists`, which is really an engine-runtime question and moves in Phase 3.

  One concurrency trap worth recording: with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
  an **unannotated extension's closures are inferred main-actor-isolated**, and
  `sorted(by:)` calls its predicate synchronously on whatever thread it is on — so the
  model-ordering sort trapped in `dispatch_assert_queue` at runtime instead of failing to
  compile. Extensions holding closures that cross threads need explicit `nonisolated`.
  Note that the nonisolated test target is what surfaced this: a main-actor-defaulted test
  target would have run the sort on the main queue and let it pass (§12.1).
- **`plan`, request reshape, deleting `GenerationPipeline` and
  `PipelineModelAdapter`** — done. `IrisModelFamily` went with them, and its
  `withKnownIssue` with it: **no known issues remain**.

  Two deviations from §5.4 worth recording:

  - **The scalar options stay flat on the request rather than grouping under `core`.**
    Grouping them is cosmetic regrouping, and doing it here would have rewritten almost
    every assertion in the entry-gate pins — which are only worth what their textual
    stability is worth. Keeping them flat meant the pins verified the move rather than
    being rewritten alongside it. Phase 4 reshapes *which* options exist anyway, so the
    grouping is better done there.
  - **`controlNetImageData` sits on the request, not in the Core ML payload.** The queue
    shows guide images as thumbnails and restores them to the sidebar, so it needs the
    bytes; duplicating them in both places is worse than one field that only one engine
    currently fills. Consistent with `startingImageData`, which was always flat.
    The queue still never inspects `payload`, which is the actual rule.

  `plan` resolves the distilled step count and scheduler, so the request, the queue and
  the saved metadata read one value instead of three that happened to agree. Before this,
  the request carried the sidebar's number, the queue recomputed 4 through a pipeline
  helper, and the Iris generator hardcoded its own 4. The displayed value is unchanged.

  Also cleared on the way through: `ComputeUnitPreference` became `nonisolated`, exactly as
  §12.1 predicted it would when compute-unit selection moved into the Core ML engine, and
  the `@MainActor` annotation on its tests went with it.
- **`.engine`/`.modelKey` metadata keys** — done. Both engines declare them, so every
  image generated from now on names its model exactly rather than by a display name two
  engines might share. `getHumanReadableInfo` shows the engine; `modelKey` stays out of the
  inspector, being an identifier for matching rather than a row worth reading.

  This also settles §9.4. `selectModel(named:engine:key:)` resolves an engine-qualified id
  exactly when the image recorded one. Falling back to a bare name, `setModel` prefers the
  engine already selected — a name collision should not move the user out of the engine
  they are working in — then takes a single unambiguous match elsewhere, and leaves the
  selection alone when several engines offer the name.

  One test earned its keep here: `unknownKeysAreSkipped` used `Engine` as its stand-in for
  a hypothetical future key, so it failed the moment `Engine` became real. Exactly the
  intended signal. Its placeholders are now `Revised Prompt` and `Refiner`.

**Phase 2 is complete.** 136 test cases, no known issues.

Three review findings landed after the phase was first called done:

- **The engine/model/payload triple is now checked.** `GenerationPlan` is generic over the
  payload and `plan` returns the engine's own type, so an engine returning the wrong
  payload is a compile error. `AnyGenerationEngine.accepts(payload:)` covers the reverse
  direction, and `GenerationService.enqueue` calls it *before* taking the request, since a
  generator unwrapping the payload discovers a mismatch only after the request has been
  dequeued and published as current. This is what §5.4 asked for and the first cut did not
  do; the owed "a payload can only be executed by its originating engine" test exists now.
- **An unreadable models folder no longer reports as an empty one.** Collapsing every
  engine failing into `noModelsFound` made the access-error branch unreachable and sent
  users looking for missing models when the problem was the folder. Phase 5's picker
  replaces the single global message with per-engine availability reasons.
- **The changelog entries this phase owed** — the engine metadata row, and the
  fixed-size-model queue fix from before it — per the Release notes rule above.

Adopting identity closed the `withKnownIssue` from the entry gate: a persisted selection
now survives the models directory being spelled differently, because a key is the
directory's own name rather than an absolute URL compared for exact equality.

### Phase 5 progress

Built: `ModelDiscoveryContext` (one enumeration per pass), `EngineSettingsStore`
(`SelectedEngine` plus `Engine.<id>.SelectedModel`), `EngineSelectionMigration`, the
sidebar `EngineView`, an Engines tab in Settings, and per-engine model memory. 373
test-case executions, `swift format lint` clean.

Four places the implementation departed from this document:

- **The Phase 2 → Phase 5 migration must resolve against discovered models.** §7 said it
  needed none, because the Phase 2 value is already engine-qualified and so has nothing to
  resolve. That was wrong in a way only the regression suite caught: writing it through
  unchecked sets `SelectedEngine` to an engine that may have no models, and the controller
  deliberately *keeps* a chosen engine when it is empty. An upgrading user would land on an
  empty sidebar with no way to see why. The migration now records nothing unless the
  selection names a model discovery found, and retries next pass otherwise.
- **§8's "keep the chosen engine even when empty" applies to engines the user chose**,
  through a picker that only offers real ones. A stale persisted waypoint is not a choice,
  which is what the point above turns on. Worth stating because the two read identically
  from inside `restoreSelection`.
- **With nothing persisted, the engine comes from the first model in the sorted list, not
  the first engine in registration order.** Iris is registered first, so registration order
  would open any mixed folder on a Klein model and change what a fresh install starts with.
- **A failed discovery pass no longer clears the persisted selection**, and does now empty
  the model list. Both are reversals of pre-Phase-5 behaviour, and both follow from
  per-engine memory: wiping the selection would discard the engine as well as the model,
  and a briefly unavailable folder should cost neither. The model list used to be left
  stale, showing models that were gone.

Not built, and deliberately: `Engine.<id>.Options` exists as a key but nothing reads or
writes it. It is where a host or an API key will go, and inventing a shape for it before a
hosted engine needs one would be guessing.

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

### Release notes

Every phase that changes observable behaviour updates the `# Unreleased` section at the
top of [CHANGELOG.md](CHANGELOG.md) in the same commit, in the house style: one bullet per
change, starting with Added / Changed / Fixed / Removed / Updated, described from the
user's point of view. Sub-bullets carry consequences the user has to act on.

Write nothing for internal work. Extracting `MetadataCodec`, adding a test target, or
changing an actor-isolation build setting are invisible and do not belong there; the
crash they fixed does. Phases 2 and 3 are expected to produce **no** changelog entries at
all except for behaviour a user could notice — for Phase 3, more responsive cancellation.

Compatibility consequences are the entries most easily forgotten and the most important
to record. Phase 1's format change means images written by this build do not appear in an
older build's gallery (§9.2); that is a changelog entry, not just a commit message.

Note that `CHANGELOG.md` had not been updated since v5.0 while the app shipped v5.1, v5.2
and v6.0, so the `# Unreleased` heading is a new convention here. Backfilling those three
releases is out of scope for this work.

**Phase 3 runtime validation passed** (2026-08-27, by hand against real models): cancelling
a Core ML generation mid-run, cancelling a multi-image Iris batch mid-run, and a queued
second request starting clean with no stale preview or inherited progress. §11.8 named this
the dominant uncertainty in the phase; it is closed.

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
- `CHANGELOG.md` describes every user-visible change the work introduced, including the
  metadata compatibility break.

## 11. Concurrency

### 11.1 Baseline

Already in place: Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY = complete`,
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, actors for `GenerationService`,
`ModelRepository`, `ImageRepository` and `FolderMonitorService`, and `Sendable` domain
values. This is hardening, not a migration.

### 11.2 An actor alone does not make cancellation work (implemented)

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

**As built.** `GenerationSession`
([Support/GenerationSession.swift](Mochi%20Diffusion/Support/GenerationSession.swift)) is
the token: one per request, created and closed by `GenerationService`, holding the
cancellation flag and the event route behind its own lock. Both runtimes are actors and
both run their blocking call inside the actor.

Two things the plan did not anticipate:

- **Polling is not enough for Iris.** Core ML's progress handler returns `Bool`, so
  `!session.isCancelled` stops it. Iris runs its loop inside a C call that stops only when
  `iris_request_cancel()` sets the library's flag — and the runtime cannot call that,
  because it is inside the call that would notice. So the session takes cancellation
  *handlers* that run synchronously on the cancelling thread, and the Iris runtime
  registers the poke as one. Without this, cancelling Iris would have compiled and done
  nothing until the current image finished.
- **The blocking call stayed inside the actor.** §11.2 wanted it on "an execution context
  suited to the blocking API", with the session borrowing the pipeline. That needs a
  non-`Sendable` pipeline sent out of actor storage and back, which Swift's region
  analysis will not prove for a value read from a stored property. Occupying the actor's
  executor is the accepted cost; nothing deadlocks on it, because the queue admits one
  request at a time and cancellation never comes here.

### 11.3 `@unchecked Sendable` policy (satisfied)

The two generator conformances
([Support/SDImageGenerator.swift at the pre-refactor revision](https://github.com/MochiDiffusion/MochiDiffusion/blob/e686551ee06cf0d9fc788d59f9282f9dea5e6dbd/Mochi%20Diffusion/Support/SDImageGenerator.swift),
[Support/IrisFluxKleinImageGenerator.swift at the pre-refactor revision](https://github.com/MochiDiffusion/MochiDiffusion/blob/e686551ee06cf0d9fc788d59f9282f9dea5e6dbd/Mochi%20Diffusion/Support/IrisFluxKleinImageGenerator.swift))
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

**As built.** Both generator conformances are gone — the generators became actors. Two
`@unchecked Sendable` conformances exist, and both are the permitted kind: `GenerationSession`
and `IrisCallbackRouter` each guard every mutable field with their own lock, and each needs
to be readable from a synchronous C callback that has no actor to hop to.

**Correction: an actor does not give single-flight.** Phase 3 claimed making
`IrisEngineRuntime` an actor made Iris's one-generation-per-process rule structural. That
was wrong, and it is the same mistake in a new costume: actors are reentrant at every
suspension point, and `run` suspends four times — twice on the embedding cache, once
encoding image data, once delivering a result. A second `run` could enter during any of
them and call `iris_clear_cancel()`, install its own callback route and load a second
context while the first still owned one. Two runtime *instances* could overlap for the same
reason, the C state being per process. Nothing hit it only because `GenerationService` runs
one request at a time — precisely the external serialization assumption this section forbids
relying on.

`IrisSingleFlight` ([Support/IrisSingleFlight.swift](Mochi%20Diffusion/Support/IrisSingleFlight.swift))
is a process-wide FIFO lease held across the whole call, suspending rather than blocking a
pool thread. `IrisSingleFlightTests` asserts holders never coexist even when each suspends
mid-critical-section, which is the shape an actor cannot protect.

The general lesson, which is worth more than the fix: **"it is an actor" answers questions
about state, not about invocations.** Any invariant that has to hold across an `await` needs
something that outlives the suspension.

### 11.4 Iris callback routing

The C callbacks create unstructured Swift tasks that later reach a singleton
`FluxStepImageBridge`. A callback emitted near teardown can be scheduled after the bridge
has been reconfigured for the next request, delivering a stale event to the wrong job.

Callbacks must synchronously snapshot request-scoped routing state, or carry a
session/epoch token checked before delivery.

**As built.** `IrisCallbackRouter` replaces the singleton bridge. Delivery is now
*synchronous* — no `Task` per callback, so no scheduling delay, no undefined order between
two updates, and no task outliving the request that made it. Teardown is keyed by session
identity, so a finishing request cannot detach the route its successor just installed.

What this does **not** solve, and the source says so: with no context pointer, a callback
that outlived its `iris_generate` call would be indistinguishable from a current one. That
is safe only because Iris calls back from inside those calls. It is an assumption about the
C library, stated rather than enforced, which is the only honest option at that boundary.

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

**As built, with one deliberate deviation: results are not events.**

`GenerationEvent` carries `.state`, `.progress` and `.preview` on one ordered stream per
session. Results stay an awaited, throwing callback. Three reasons, and they are properties
of results rather than convenience:

- **They must not be dropped**, and the stream is bounded on purpose (previews are
  full-size images, so an unbounded buffer in front of a suspended consumer grows without
  limit). Putting results on the same stream would mean choosing one policy for channels
  that need opposite ones.
- **They carry back-pressure.** The caller writes each image to disk before the engine
  produces the next one. A stream would decouple that, so a broken images folder would let
  the engine keep generating into nothing.
- **A failed write has to stop generation**, which needs the call to throw back into the
  generation loop. A stream cannot fail the producer.

They also never arrive late — they are emitted from the generation loop, not a C callback —
so they are not subject to the stale-delivery problem the stream exists to solve. The count
that matters went from four channels to two, and the one that needed a single stale-event
checkpoint got it.

The terminal `.ready` moved out of the runtimes and onto `GenerationService`, so a dropped
informational event cannot leave the UI stuck mid-generation.

**The cost of two channels, and what it took to pay it.** Splitting results from events means
their relative order is not guaranteed, and that had a visible consequence: a buffered
preview could be applied *after* the controller had replaced the preview with the finished
image, and teardown skipped clearing on the assumption the insert had done it — so the stale
frame survived and was inherited by the next request. `GenerationService` now tracks whether
a preview was applied since the last result and clears at teardown only in that case, which
leaves the common path untouched (no blank between the last preview and the inserted image,
and no change to whether the insert animates). Anything that adds a third channel needs to
answer the same question.

Separately: `GenerationState.Progress` and `.Status` are now `nonisolated`. Nested in a
`@MainActor` class under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, they were `Sendable`
with main-actor-isolated members — an engine off the main actor could build a `Progress`
and hand it over but could not read one back. Indeterminate hosted progress (§13.1) needs
both directions.

### 11.6 Observation task lifecycle (implemented)

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

**As built.** All four loops take their weak reference *inside* the loop rather than
hoisting `self` before it, which is what made task and controller retain each other.
`GenerationController.shutdown()` and `GalleryController.shutdown()` cancel every owned
task. `updates()` is `bufferingNewest(1)`; `results()` stays unbounded.

**Cancelling tasks is not the same as being shut down.** Two holes turned up after the fact.
The initial `Task { await loadModels() }` in each `init` was stored nowhere and captured
`self` strongly, so `shutdown()` had no handle on it. And a `withObservationTracking`
callback stays armed until it fires, and *firing is what re-registers it* — so a settings
change after shutdown armed observation again and scheduled fresh debounce work. Both
controllers now store that initial task weakly and carry an `isShutDown` flag checked before
arming observation, scheduling a debounce, or starting a monitor. `ControllerLifecycleTests`
changes settings after shutdown and asserts the controller still deallocates.

`shutdown()` has **no caller in the app, deliberately.** Both controllers are created once
in `App.init()` and held in `@State` on the `App` struct, with a single `Window` scene;
SwiftUI creates that state once per process and nothing replaces it. So there is no leak
today, and no path where `shutdown()` would change observable behaviour.

A review suggested wiring it into `NSApplication.willTerminateNotification`, alongside the
temp-file cleanup. Declined: it would run microseconds before the process dies, where tasks
are killed by teardown anyway, FSEvent sources are reclaimed by the OS and there is nothing
to flush. It is also faintly counterproductive — it cancels the debounce and monitor loops,
so an in-flight `loadModels()` or `syncImages()` would be interrupted for no gain — and it
adds a call site that reads as load-bearing when it is not. Wire it up in Phase 5, at the
real call site, when settings changes actually rebuild a controller.

What the review was right about is that `shutdown()` was dead code, and the fix for that is
a test rather than a call site. `ControllerLifecycleTests` asserts both controllers are
released after `shutdown()`, which pins the thing Phase 3 actually fixed: re-hoisting a
`guard let self` out of a monitor loop compiles, reads as a simplification, and silently
restores the retain cycle. A termination call site would not have caught that.

Writing the test found a hole the review had not: both controllers spawned an untracked
`Task { await loadModels() }` in `init` with an implicit strong `self`, so `shutdown()`'s
claim to cancel every task the controller owns was false — it had no handle on that one, and
the controller stayed alive until the load finished. Both are now stored and capture weakly.

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

The Swift Testing target exists and passes: **235 test cases, 235 passing, no known
issues**, and `swift format lint` is clean. (223 at the first triage pass; 235 after the
second.)

**Counts come from `xcresulttool get test-results summary`.** Grepping `xcodebuild` output
for passed test cases roughly doubles the figure, because it logs most cases twice. This
warning has already been ignored once: figures of 273, 347 and 373 were reported during
Phases 2–5 from grepped output and were all roughly 2× the truth. Use the result bundle:

```
xcodebuild test … -resultBundlePath out.xcresult
xcrun xcresulttool get test-results summary --path out.xcresult
``` It uses current idioms correctly: `@Test`, parameterized `arguments:`,
`#expect`/`#require`, per-test temporary directories, and no XCTest.

Changes needed before it becomes the contract for the new architecture:

1. ~~**Drop the Main Actor default for the test target.**~~ Done. The test target now sets
   `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` (the app target keeps `MainActor`), so
   pure domain suites run nonisolated and in parallel, and actor crossings stay visible.
   `@MainActor` is now applied only where production isolation genuinely requires it:
   `MetadataRoundTripTests` (constructs and mutates `SDImage`) and
   `ComputeUnitPreferenceTests` (`ComputeUnitPreference` is main-actor-isolated).

   The setting is written explicitly as `nonisolated` rather than deleted, so it does not
   silently change if Xcode's target template default changes.

   Worth noting for Phase 4: `ComputeUnitPreference` is a pure value mapping that only
   needs `@MainActor` because it was never marked `nonisolated`. When compute-unit
   selection moves into the Core ML engine it should become `nonisolated`, and that test
   annotation should disappear with it.

2. **Delete `kleinTakesPrecedenceOverCoreML`.** It pins sniffer precedence, which §5.5
   removes. Replace it with a test that both engines can expose the same directory under
   distinct `ModelID`s.
3. ~~**Fix the sharded Klein fixture or rename it.**~~ Done. The fixture now writes every
   shard its index names. Production `hasSafetensorWeights` still only checks for an index
   plus any matching shard, and that shallowness is deliberate for a *picker* — parsing
   every index for every model on every folder-change event would put real I/O on the
   discovery path — so the fixture is documented as stricter than discovery requires. Deep
   validation belongs at load time, where failure is already handled.
4. ~~**Rename or extend "Every required Klein config file is required."**~~ Done. Both the
   fixture and the test now read the same `kleinRequiredConfigPaths`, so it covers all
   twelve and cannot silently cover fewer again.
5. ~~**Turn the separator known-issue into a passing parameterized test.**~~ Done in
   Phase 1: `MetadataCodecTests` covers `"; "`, bare semicolons, backslashes, colons, key-lookalike strings, newlines,
   Unicode, empty strings, filenames containing commas and semicolons, legacy unescaped
   captions, and unknown future keys alongside escaped known values, plus the crash case
   from §9.1 and a golden encoded-shape assertion in both the codec and image suites.

### Phase 2 entry gate — landed

Both suites exist. 95 test cases pass, two of them as `withKnownIssue` defects.

- **`GenerationRequestBuilderTests`** pins `buildGenerationRequest` field by field: scalar
  pass-through, size, compute-unit resolution, starting-image scaling for fixed-size and
  freeform models, all four ControlNet gates, the Klein `startingImageName` →
  `inputImageNames` divergence, and both seed branches. Phase 2 moves this logic into
  per-engine `plan` implementations, and these tests are what "the request is unchanged"
  means.
- **`ModelSelectionPersistenceTests`** pins the restore contract the §7 migration has to
  preserve: first-model selection, persisted restore, stale-selection fallback, the three
  failure paths that clear the persisted id, `currentModelId.didSet`'s side effects on
  ControlNet state, and name-based selection as the baseline for §9.4.

Two enabling changes came with them:

- `ConfigStore` gained `init(store: UserDefaults? = nil)`, which rebinds its `@AppStorage`
  wrappers to an injected suite. The test host *is* Mochi Diffusion, so without this a test
  run reads and overwrites the developer's real preferences. Keys and defaults are now
  declared once each (`ConfigStore.Key`, `ConfigStore.Default`) because `init(store:)` has
  to restate every default, and a drifted default would be visible only under an injected
  store — that is, only in tests, and as a wrong expected value rather than a failure.
- `GenerationController.init` gained `startsObserving: Bool = true`. Its eager work — the
  initial model load, folder monitors, service observation — is an unowned background task
  that can reload models mid-test, and `currentModelId.didSet` clears `currentControlNets`,
  so a stray reload silently empties state a test just set up. §11.5 wants this seam to
  become an explicit lifecycle with a matching shutdown path.

#### What writing the pins turned up

Pinning behaviour before refactoring it found two things neither the design nor the review
had noticed:

- **A live bug, now fixed.** `buildGenerationRequest` recorded the *configured* size even
  for a Core ML model with a fixed input size that ignores it. Generation was unaffected —
  `SDImageGenerator` ignores `request.size` — but `JobQueueView` displays it and
  `copyOptionsToSidebar` writes it back, so a queued job showed dimensions no generated
  image would match. Divergence is the normal case, not an edge one: `SizeView` shows a
  fixed model's size in a disabled constant field without writing it to `ConfigStore`. The
  request now carries `adapter.inputSize ?? configuredSize`. Fixed ahead of the suites so
  the pins assert correct behaviour rather than encoding the bug.
- **Model identity is an exact `URL` match** — see §5.1. Left as a known issue for Phase 2.

Both were invisible until something asserted what the code actually produced, which is the
argument for the entry gate in general.

**Still owed: the migration itself.** The §7 migration cannot be tested before it exists,
so its own tests are written with it in Phase 2 — legacy `Model` URL resolving to a Core ML
directory, to a Klein directory, to one satisfying both, to a path that no longer exists,
and to no value at all; asserting `SelectedEngine`, `Engine.<id>.SelectedModel`, that both
local engines' `ModelDir` inherit the legacy value, and that the migration is idempotent.

### Remaining test work

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

### `AGENTS.md` is now wrong (rewritten)

**Done.** The design-flow, test-coverage and potential-improvements sections were rewritten
against the current code, and every symbol named in them was checked to exist. The build,
test and commit sections were left alone; they were accurate.

The "Potential improvements" list is now the real one — engine-scoped scheduler identifiers
and the scheduler import defect, `EngineModel.url`/`tokenizerModelDir`, the missing quality
and aspect-ratio vocabulary, discovery messages sharing the generation banner, the absent
request timeout, and per-runtime queue capacity. It points at this document as the source of
truth for the in-flight work rather than restating it.

The original finding follows.


Not a test, but it belongs with the things that silently rot. `AGENTS.md` is the
orientation file a new contributor or agent reads first, and its "High-Level Design Flow"
still describes the pre-engine architecture: `GenerationPipeline` (three mentions),
`SDImageGenerator` and `IrisFluxKleinImageGenerator` as the two generators, `MochiModel`,
and `ModelRepository` returning `[any MochiModel]`. It mentions none of `EngineID`,
`ModelID`, `EngineRegistry`, `GenerationEngineDescriptor`, `GenerationEngineRuntime`,
`GenerationSession`, or `OptionConstraints`.

Its "Potential improvements" list is also stale in a misleading direction — it still
recommends aligning the sidebar to `generationCapabilities` (done in Phase 4b, via
constraints rather than capabilities) and replacing the generators'
`@unchecked Sendable` conformances (done in Phase 3).

Rewrite it once Phase 5 settles the settings layer, so it is rewritten once rather than
per phase. Until then it actively misleads anyone starting from it.

## 13. Hosted and third-party engines

### 13.1 What hosted generation breaks

The app is **not** sandboxed (`MochiDiffusion.entitlements` is empty), so no network
entitlement is required. Everything else needs work:

- **Progress and preview frames may or may not exist — do not assume they are absent.**
  `GenerationState.Progress` and the `onPreview` stream assume step-by-step denoising, and
  an indeterminate mode is needed for services that report nothing. But this is a
  per-service question, not a property of "hosted": the OpenAI API streams up to three
  partial images with a 0-based index, which feeds `onPreview` and a truthful `Progress`
  directly (§13.2, D2). The indeterminate case is narrower than it looks — see D3.
- **Cancellation differs.** Cancelling local waiting may not cancel remote computation or
  avoid a charge. The UI wording must be honest about that.
- **API keys belong in the Keychain**, and out of persisted requests, logs, metadata, and
  test fixtures.
- **Distinct error classes**: content-policy refusal, authentication failure, rate limit,
  transient service error. `GeneratorError` is currently a small filesystem-shaped enum.
  A refusal must read as a message, not as a crash.
- **Generation status messages are not localized.** Mochi ships 20 Crowdin-managed
  locales and uses `String(localized:comment:)` — 32 call sites. Every user-facing string
  routed through `GenerationState.Status` in `GenerationService` is a bare literal instead:
  roughly fifteen of them, of which seven are the hosted-engine messages added in Phase 6
  (authentication, rate limiting, service failure, malformed response, expiry, refusal).
  The pattern predates this work — "Couldn't load <model>" and "Couldn't access images
  folder" were always bare — but Phase 6 roughly doubled the count and made the gap visible
  *inside one feature*: `OpenAIImageEngine.availability` returns a translated
  "Add an API key in Settings", and then the failure the user hits next says
  "OpenAI is rate limiting requests. Try again shortly." in English. Fixing it is
  mechanical, and the whole set should move together rather than only the new ones.

  **Declined 2026-08-28.** Out of scope for the engine work and owned elsewhere. Recorded
  here as an observation rather than carried forward as a task; it is deliberately absent
  from [Engine-Future-Work.md](Engine-Future-Work.md).
- **A request timeout, which nothing in this design has yet.** Every failure mode
  considered so far is one the local engines can hit, and a local generation always either
  finishes or is cancelled. A network call can hang indefinitely, and §11.7 commits Phase 6
  to the globally serial queue — so one stuck hosted request blocks every local job behind
  it until the user notices and cancels. Cancellation is the user-initiated path; a timeout
  is the automatic backstop, and the serial queue is what makes it mandatory rather than
  merely polite. Decide the value per engine, surface an expiry as a distinct error from a
  refusal, and make sure it releases the drain the same way a completed request does.
- **LAN discovery** needs `NSLocalNetworkUsageDescription` and Bonjour service types on
  macOS 15+, even unsandboxed. For Draw Things the values are already known: browse
  `_dt-grpc._tcp.` in domain `local.` (`GRPCServiceBrowser` uses `NetServiceBrowser`), and
  the server's default port is 7859. That service type is what goes in `NSBonjourServices`.

### 13.2 OpenAI — decided before Phase 6

Researched 2026-08-27 and updated 2026-09-09 against the live documentation, in the same
spirit as the Phase 4 decisions pass. Sources: the [image generation
guide](https://developers.openai.com/api/docs/guides/image-generation), the [generation
streaming events
reference](https://developers.openai.com/api/reference/resources/images/generation-streaming-events),
the [gpt-image-2 model page](https://developers.openai.com/api/docs/models/gpt-image-2), and
the model pages for [GPT Image 2.5
Flare](https://developers.openai.com/api/docs/models/gpt-image-2.5-flare) and [GPT Image 2.5
Sunburst](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst).

**Provenance caveat.** The numeric limits below were read out of the guide page by a
summarising fetch, not transcribed from a table by hand. Treat the *shape* of each decision
as settled and re-confirm the exact numbers against the reference when writing the client.
Nothing below depends on a number being exactly right; several decisions depend on the
shape, which is why they can be made now.

#### Verified API surface

- **Models:** `gpt-image-2`, `gpt-image-2.5-flare`, and `gpt-image-2.5-sunburst`. The 2.5
  models also have dated aliases ending in `-2026-09-08`. Earlier models —
  `gpt-image-1.5`, `gpt-image-1`, `gpt-image-1-mini` — had narrower geometry.
- **`size`:** an arbitrary `WIDTHxHEIGHT` string, or `auto`. Both edges multiples of 16;
  maximum edge 3840; long-edge-to-short-edge ratio at most 3:1; total pixels between
  655,360 and 8,294,400. Presets: 1024x1024, 1536x1024, 1024x1536, 2048x2048, 3840x2160.
- **`quality`:** `gpt-image-2` offers `low`, `medium`, `high`, and `auto` (default). Both
  2.5 models add `xhigh` and `max`.
- **`output_format`:** `png` (default), `jpeg`, `webp`. `output_compression` 0–100 applies
  to jpeg and webp only.
- **`background`:** `transparent`, `opaque`, `auto`.
- **`moderation`:** `auto` (default) or `low`.
- **`n`:** more than one image per request, default 1.
- **`partial_images`:** 0–3. With streaming, `image_generation.partial_image` events carry
  `b64_json` and a 0-based `partial_image_index` (no total), and
  `image_generation.completed` carries the final image plus a `usage` breakdown of input,
  output and total tokens. No error event is documented.
- **Response:** base64 image data, not a URL.
- **Image references:** all three models accept one or more images at `/v1/images/edits` as repeated multipart
  `image[]` fields. Edit streaming uses `image_edit.partial_image` and
  `image_edit.completed` events. `gpt-image-2` always processes image inputs at high
  fidelity; the current guide does not state a maximum reference count.
- **`revised_prompt`** is documented on the Responses API image tool. It was *not* confirmed
  on the Images API response. Verify before adding the metadata field.

#### D1 — Geometry needs a joint constraint, not an aspect-ratio case

**This corrects §6.** The gap is not a missing `.aspectRatios` case: `size` is
width-by-height in pixels, and "both edges multiples of 16" is exactly what
`SizeConstraint.freeform(range:step:)` already expresses. What `.freeform` cannot express is
that the ratio cap and the pixel budget are *joint* constraints on width × height, while
`.freeform` bounds each dimension independently.

So `SizeConstraint.freeform` grows limits — a maximum long:short ratio and minimum/maximum
total pixels — rather than gaining a new case. Two consequences:

- **`resolved(_:)` must be able to move both dimensions.** Every existing constraint clamps
  one number at a time. Here a pair can each be individually legal and jointly illegal.
  Decision: clamp each dimension to range and step first, then while the ratio or pixel
  budget is violated, reduce the **long** edge and leave the short one alone. Deterministic,
  predictable, and it never silently grows an image the user asked to be smaller.
- **A hosted model's floor is far above a local one's.** A 655,360-pixel minimum rules out
  most sizes a Core ML model offers. Per-model constraints already handle this; it is worth
  noting because it is the first model whose *minimum* is interesting rather than its
  maximum.

`auto` is deliberately not modelled. Mochi always has a concrete size to send, and letting
the service choose would put a value in the metadata that the sidebar never showed.

#### D2 — Previews work; §13.1's "no preview frames" is wrong for this API

`partial_images` up to 3, each event carrying `b64_json`, feeds `onPreview` directly. So a
hosted engine is not preview-less, and `showGenerationPreview` maps cleanly: request
`partial_images: 3` when it is on, `0` when it is off. That is the same switch
`useDenoisedIntermediates` already performs for Iris.

Progress is honest too. `partial_image_index` has no total, but *we* choose the total, so
`Progress(step: index, stepCount: requested, kind: .preview)` is accurate rather than
invented. The kind matters to presentation: these are “Preview 1/3”, not Core ML diffusion
steps.

#### D3 — Withdrawn: indeterminate progress needs no code

**Withdrawn on inspection, 2026-08-27.** The decision was to render an indeterminate spinner
for `Status.running(nil)`, on the grounds that all three renderers test
`if case .running(let p) = state, let p, p.stepCount > 0` and fall through, so a job in
flight would draw nothing. The premise is accurate. The conclusion does not follow, because
nothing has to emit `.running(nil)` in the first place:

- `GalleryToolbarView` **already** draws an indeterminate circular `ProgressView` for
  `.loading`.
- `JobQueueView` **already** has a `.loading(stage)` branch that shows the stage message.
- `GalleryPreviewView` only overlays a preview image, and with D2's partial images the
  progress it overlays is determinate anyway.
- Nothing anywhere gates *behaviour* on `.loading` versus `.running` — no button disabling,
  no queue logic. Checked: the distinction is those three render sites and nothing else.

So the honest sequence for this hosted engine is
`.state(.loading("Generating with OpenAI..."))` until the first partial image arrives, then
`.progress(step: index, stepCount: requested, kind: .preview)`. The queue's nil-stage
fallback is now the engine-neutral “Preparing generation...”; Core ML owns the first-load
message that previously served as that fallback for every engine.
`.running(nil)` is simply never emitted, and the fact that it draws nothing stops mattering.

`Status.running(Progress?)` keeps its optional payload. Nothing is gained by removing it and
a later engine may want it.

**The general lesson, since this is the third:** D7's output-format mismatch and the
unreachable branch in `SizeLimits.applyingRatio` went the same way. A decision reached by
reading the *shape* of the code — "the renderers ignore this case", "the formats do not
line up" — is worth re-checking against what the code actually does before implementing it.
All three were correct about the shape and wrong about the consequence.

#### D4 — An idle timeout, not a wall-clock budget

Streaming makes the better-shaped decision available: a 3840x2160 high-quality generation
may legitimately take minutes, so a total-duration budget is either useless or a footgun.
What is unambiguously wrong is a stream that stops producing events. Decision: bound the gap
*between* events, not the whole request.

- **Lives on the runtime**, not in `EngineSettings` or a constraint. It is a property of the
  transport, not of the model or of anything the user should tune.
- **Local engines get none.** A wedged Core ML load is a bug to fix, and any bound loose
  enough for a slow 9B Klein generation is too loose to catch anything.
- **Not cancellation.** `session.cancel()` means "the user asked to stop", and reusing it
  would make an expired request indistinguishable from a deliberate one in the queue
  snapshot. Expiry needs its own terminal state.
- **The clock starts when the request starts**, not when it is enqueued. With a serial queue
  a hosted request can sit behind a long local job for minutes; starting the clock at enqueue
  would expire a queue of hosted jobs en masse.
- **Expiry must release the drain exactly as completion does.** This is the `dc209e9` bug
  class — a failure path that leaves the queue unable to start again — and it is the single
  most important thing to get right here.

**Implemented in `649f5b4`**, with three refinements the decision did not anticipate:

- **Enforcement lives in the queue, not the runtime.** The *value* is on
  `GenerationEngineRuntime.idleTimeout` as decided, with local runtimes inheriting `nil` from
  a protocol extension. But the queue owns the request lifecycle and the drain, so it is the
  only place that can guarantee the release above. Runtimes declare; the queue enforces.
- **Expiry is a sibling of `cancel()`, not a flag beside it.** "Its own terminal state" turned
  out to need a shared *mechanism*: a runtime only polls `isCancelled`, and a stalled request
  needs the same `iris_request_cancel()` poke a cancelled one does. So `cancel()` and
  `expire()` both route through one `stop(because:)`, `StopReason` distinguishes the outcome,
  and the first reason wins.
- **The expiry check must run before the runtime's own outcome.** A runtime that notices the
  stop returns *normally*, so checking afterwards would make an expiry indistinguishable from
  success — the UI would go quietly `.ready` having produced nothing. This is the one part
  that is easy to get wrong and silent when wrong.

Two details worth keeping: results count as activity even though they are not events, since a
run producing one image a minute is working rather than stalled; and the watchdog sleeps for
exactly the time remaining rather than polling, so a long generation that keeps reporting
costs one wake-up per reported event.

The drain-release guarantee is pinned by `IdleTimeoutQueueTests.drainSurvivesAnExpiry`, and
the pin was verified by removing the expiry check — which fails both expiry tests and leaves
the heartbeat test passing.

#### D5 — A refusal is not an error

`GenerationError` is entirely filesystem-shaped (`imageDirectoryNoAccess`,
`modelDirectoryNoAccess`, `noModelsFound`, `pipelineNotAvailable`,
`requestedModelNotFound`). It gains hosted cases: authentication failure, rate limit,
transient service error, request expired.

**Split across two increments, deliberately.** `requestExpired` landed with the timeout in
`649f5b4`, because the timeout produces it. The other three are deferred to the client
increment: nothing throws them until an HTTP response can be mapped onto them, and enum cases
with no producer are guesses at a shape we are about to be told. Matching them to real
responses beats inventing them now — which is also why there is no `rateLimited(retryAfter:)`
yet, since whether the service supplies that value is a question the client answers.

The *principle* needs no code and is already available: `updateStatus(.ready(message))` is
exactly how "Couldn't load <model>" surfaces a non-error message against a request, and it is
what a refusal will use.

A content-policy refusal is **not** among them. The call succeeded and the service told us
something; routing that through `.error` makes a normal outcome look like a malfunction.
Decision: refusals surface as a message against the request, in the same register as
"Couldn't load <model>", not as a red banner.

`usage` on the completed event means cost could be surfaced. Decision: not in Phase 6.
Recording token counts in image metadata would make it a permanent part of the export
contract for a number nobody has asked for.

#### D6 — One API call per image; keep the runtime loop

Both existing runtimes loop `for _ in 0..<numberOfImages` and yield results one at a time.
Decision: the hosted runtime does the same, with `n: 1`, rather than sending `n: 5`.

- Cancellation granularity is the money argument: stopping after image 2 of 5 should cost
  two images, not five.
- Results already stream into the gallery one at a time; `n > 1` would hold them all until
  the end.
- `partial_images` previews are per-call, so batching would lose previews for all but one.

#### D7 — Request `png`, then re-encode through the existing path

There is an apparent mismatch — Mochi's `imageType` is png, jpeg or **heic**, while the API
offers png, jpeg and **webp** — and it dissolves on inspection. Both runtimes already build
an `SDImage` and call `imageData(type, metadataFields:)`, because Mochi embeds its own
metadata into the file and the service's bytes carry none. A hosted engine must decode and
re-encode regardless.

So: request `output_format: png` (lossless, transparency-capable, and the default), decode to
a `CGImage`, and hand it to the same encode path. All three of Mochi's output types keep
working, including HEIC. Passing service bytes straight to disk would be the mistake — it
would produce a file with no Mochi metadata and, for HEIC, a misleading extension.

`background: transparent` is not modelled in Phase 6. It needs png or webp output and a new
option kind, and nothing in the sidebar expresses transparency today.

#### D8 — Check for the key without reading it

`availability` is consulted on every discovery pass, so it must answer "is a key
configured?" without fetching the secret — a Keychain read can prompt, and a credential
fetch does not belong on the discovery path. Decision: `SecItemCopyMatching` with
`kSecReturnData: false` for the existence check. Preferred over mirroring a "key is set"
flag into `EngineSettingsStore`, which would be a second source of truth that can drift from
the Keychain.

#### D9 — Model discovery is a static list

`/v1/models` returns every model the account can see and does not mark which are
image-capable, so it cannot drive the picker. Decision: the engine reports a hand-maintained
list of known image models, each with its own constraints, and `availability` reports
`.needsConfiguration` when no key is present. Revisit if a capability-filtered endpoint
appears.

This is also where `EngineModel.url` being non-optional bites — see §6.

#### D10 — Still deferred, deliberately

- **Concurrency stays serial** (§11.7). D4's idle timeout bounds the damage.
- **Discovery messages still share the generation banner** (§15's open item). This is the
  phase where it stops being cosmetic, since a hosted engine produces availability messages
  and generation errors in roughly equal number. Fix it in Phase 6, not after.
- **Moderation is not exposed as a per-image option.** A later explicit product decision set
  every OpenAI request to `moderation: low`; it remains engine policy rather than a sidebar
  control.

#### D11 — OpenAI reference images reuse the shared input-image path

`gpt-image-2` accepts references, so its model declares `inputImages` and the existing
progressively revealed sidebar wells are shared with Klein. The service documentation does
not state a count maximum, but Mochi deliberately caps the model at **16**. This is an app
safety limit: a multi-file drop must stop loading at the remaining slot count, so selecting
hundreds of files cannot make the app decode all of them before truncating the request.

The pixel path stays engine-specific:

- User cropping remains shared and is applied before planning.
- OpenAI receives each cropped image as PNG at its native cropped resolution. It does not
  inherit Iris's attention-budget fitting or token-grid normalization.
- Iris alone shows its budget warning and estimated final reference size. For OpenAI the
  sidebar shows the original and cropped sizes without an inapplicable estimate.

The runtime uses `/v1/images/generations` with its existing JSON body when the request has no
references, and `/v1/images/edits` with repeated multipart `image[]` parts when it does. The
same preview and completion path accepts both the `image_generation.*` and `image_edit.*`
event families. Input filenames are recorded through `.inputImages` metadata; generated
multipart filenames are transport-only because pasted inputs may not have source names.

### 13.3 Draw Things / MediaGenerationKit — moved

**Moved to [Engine-Future-Work.md](Engine-Future-Work.md) §5** on 2026-08-28, in full: the
license chain and the correction to it, dependency weight, maturity, the `Echo` RPC that
carries the remote catalog, the mapping from a ~90-property configuration onto our constraint
vocabulary, moodboard and `MetadataOverride`, the Connection mapping, and the build-first
gate with its remaining unknowns.

No code was written against it. Moved rather than copied, so there is one source of truth to
keep current.


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
- MediaGenerationKit **licensing is a non-issue**, though the chain is GPL-3 rather than
  LGPL-3 as first recorded. The real risks are **dependency weight** — MGK is a façade over
  the whole `draw-things-community` tree — and **maturity**: created five months ago, ~25
  stars (§13.3).
- Remote model listing is **absent from MGK's public API but present in the protocol**, via
  `Echo`'s `files` and `MetadataOverride`. The earlier "have the user type a known
  identifier" plan is replaced by a three-tier strategy, and `MetadataOverride`'s
  round-trip adds a discovery-lifetime requirement to §5.5 (§13.3).
- Duplicated directory scans once both local engines share a model dir (§5.5).
- `ModelID.key` normalization rules — traversal, symlinks, case sensitivity (§5.1).

## 15. Post-Phase-5 review triage

An independent review of Phases 3–5 raised nine findings. All nine were checked against the
code. Seven were real; the two severity calls below are ours, not the reviewer's.

**Fixed:**

- **Queued requests stranded after an error** (reviewer's High, agreed). `processQueue`
  gated on `GenerationState` being `.ready`, and nothing outside `GenerationService`
  restores `.ready`. Fixed by removing the guard: `startProcessingIfNeeded` already
  prevents a second drain, so the guard could only ever block a terminal `.error`. Two
  refinements the review did not have: the guard was only at the *top* of the drain, so a
  mid-batch error never stranded the rest of a batch; and three of six failure paths report
  `.ready(message)`, which satisfied the guard — which is why this went unnoticed, since the
  common missing-model failure is one of the safe ones.
- **A second liveness bug, found while fixing the first.** The drain ends with an `await` on
  the queue-empty notification. A request enqueued during that await saw `processingTask`
  still set, scheduled no drain, and was then left queued when the finishing task cleared
  `processingTask`. `processQueue` now re-checks the queue after the notification. **Not
  pinned by a test**: hitting the window needs a slow queue-empty notification, and
  `NotificationController.shared` is a singleton with no seam.
- **Discovery failures reported as "No models found"** (reviewer's Medium, agreed; a Phase 5
  defect). Merged into `engineAvailability` as `.unreachable` before the picker reads it.
- **The safety checker was still global** (agreed; a Phase 5 miss). Moved under Core ML with
  the other three.

**Also fixed, in a second pass:**

- **Result delivery could clear the next request's preview.** `ImageGallery` now records
  which request the preview belongs to, and a scoped clear is ignored unless that request
  still owns it. The request id rides on `GenerationResult`, not `GenerationMetadata`:
  metadata is the contract written into the image, where a request id means nothing.
  Severity was **Medium, not High** — the result is yielded before `session.close()`,
  `await forwarding.value`, the terminal status and teardown, and only then is the next
  request dequeued and its model loaded, so the result had a large head start on that
  request's first preview. The review's framing is the one worth keeping: Phase 3
  established ordering *within* the event stream and none *across* the result and event
  streams.
- **`loadModels` reentrancy**, and **`shutdown()` not being terminal** for a refresh already
  past its await. `EngineRegistry.refresh(settings:)` now gathers availability and discovery
  into one value, asked concurrently, re-ordered to registration order; `loadModels` takes an
  epoch and discards a superseded pass. The discovery-failure merge moved into `refresh` and
  now overrides only `.ready`, since an engine that has already said why it cannot be used
  has given the actionable answer.
- **`IrisSingleFlight` waiting was not cancellation-aware.** Cancellation is now checked
  immediately after acquiring the lease, before `iris_metal_init` and `iris_load_dir`. A
  cancelled waiter still takes its place in the FIFO rather than being removed from it, but
  its turn is one actor round-trip. Removing it would mean plumbing session cancellation into
  the lease, and the session's flag is not the task's.

**Known gaps in the tests for the above**, recorded rather than papered over:

- The queue-teardown race — a request enqueued after the inner drain loop exits but before
  `processingTask` is cleared — is fixed but not pinned. Hitting the window needs a slow
  queue-empty notification, and `NotificationController.shared` is a singleton with no seam.
- Both ordering tests were checked against the unguarded code, and the first version of the
  superseded-pass test was **not** a real pin: releasing a gate only schedules the waiting
  continuation, so releasing both passes and then awaiting left the apply order unspecified.
  It now lets the newer pass finish completely before releasing the older one. A regression
  test that has not been run against the bug is not yet a regression test.

**Still open:**

- ~~**The state-machine separation itself.**~~ **Fixed while registering the hosted
  engine.** `GenerationController` now owns a `discoveryMessage`, reported per engine and
  rendered in `GalleryView` beside the generation banner rather than through it.

  It stopped being cosmetic exactly where this section predicted. The old messages fired
  only when the *combined* model list was empty, and a hosted engine always contributes a
  model — so registering one would have silenced "No models found" and "couldn't read the
  models folder" permanently, leaving a broken models folder visible only as a label inside
  the picker.

  Registering it also exposed a second problem this section did not anticipate. Selection
  fell back to the first model by name, and assigning `currentModelId` **persists** it — so
  an empty local folder would have selected a hosted engine with no API key *and overwritten
  the user's stored choice*, which would not have come back when their folder did. The
  fallback is now restricted to engines reporting `.ready`, and selecting nothing is
  preferred to selecting something unusable. Pinned by
  `ModelSelectionPersistenceTests.hostedEngineIsNotAutoSelected`.

**Declined:**

- **"`plan` is not the sole resolution point" (negative prompt).** The finding infers a
  principle from `guidanceScale` — that `plan` resolves unsupported options to absent — but
  `guidanceScale` is optional so the *queue row* knows whether to draw it, which is §6's
  presentation distinction, not a rule about erasing input. Checked the consumers:
  `copyOptionsToSidebar` already gates the negative prompt on `metadataFields`, which Klein
  does not declare, so nothing reads it for a Klein job and nil'ing it buys no observable
  correctness. The inconsistency in how unsupported fields are represented is real, and is
  better revisited with the Phase 6 work that already has to change `EngineModel.url` and
  the constraint vocabulary.

**The review's structural conclusion is endorsed:** discovery status, generation status,
queue readiness, preview ownership and result delivery are spread across loosely
coordinated state machines above the engines. Three of the findings above are one defect —
`GenerationState.shared` conflates engine and discovery health with queue activity and is
written from several places with no owner. Separating "can the queue run" from "what is the
UI showing", and giving discovery its own per-engine status, dissolves them rather than
patching each. That belongs before Phase 6, not inside it: a hosted engine makes every one
of them worse.

## 16. Non-goals

- Reworking the gallery, filtering, or inspector beyond the new metadata fields.
- Model downloading or conversion for any engine.
- A wholesale switch to an opaque metadata format. The format stays human-readable
  `Key: value` lines; §9.2 changed the separator and added escaping and a version marker,
  and additive keys remain in scope.
- Multi-engine batching within a single request.
- A separate "Swift Concurrency migration" project. The remaining hardening rides along
  with the engine runtime work in Phase 3.
