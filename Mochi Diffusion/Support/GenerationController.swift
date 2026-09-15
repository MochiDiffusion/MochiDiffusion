//
//  GenerationController.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import CoreML
import SwiftUI
import os

private enum SidebarRestoreModel {
    case exact(ModelID)
    case legacyName(String)
    /// Modern metadata that claims an engine-scoped identity but does not contain
    /// a complete one. It must not fall back to a display name that another engine
    /// may also offer.
    case unavailable
    case unspecified
}

private enum SidebarRestoreImage {
    case encoded(Data, name: String?)
    case galleryFilename(String)

    var name: String? {
        switch self {
        case .encoded(_, let name): return name?.normalizedFilename
        case .galleryFilename(let filename): return filename.normalizedFilename
        }
    }
}

private struct SidebarRestoreControlNet {
    /// Nil for gallery metadata, which records the guide filename but not the
    /// ControlNet bundle that interpreted it.
    var name: String?
    var image: SidebarRestoreImage
}

private struct SidebarRestoreSource {
    var model: SidebarRestoreModel
    var prompt: String?
    var negativePrompt: String?
    var size: CGSize?
    var startingImage: SidebarRestoreImage?
    var inputImages: [SidebarRestoreImage]
    var controlNets: [SidebarRestoreControlNet]
    var strength: Double?
    var steps: Int?
    var guidanceScale: Double?
    var scheduler: Scheduler?
    var quality: ImageQuality?
    var computeUnits: MLComputeUnits?
    var seed: UInt32?
    var numberOfImages: Int?

    init(galleryImage: SDImage, metadataFields: Set<MetadataField>) {
        if metadataFields.contains(.engine) || metadataFields.contains(.modelKey) {
            if !galleryImage.engine.isEmpty, !galleryImage.modelKey.isEmpty {
                model = .exact(
                    ModelID(
                        engine: EngineID(rawValue: galleryImage.engine),
                        key: galleryImage.modelKey
                    )
                )
            } else {
                model = .unavailable
            }
        } else if metadataFields.contains(.model), !galleryImage.model.isEmpty {
            model = .legacyName(galleryImage.model)
        } else {
            model = .unspecified
        }

        prompt = metadataFields.contains(.prompt) ? galleryImage.prompt : nil
        negativePrompt =
            metadataFields.contains(.negativePrompt) ? galleryImage.negativePrompt : nil
        size =
            metadataFields.contains(.size)
            ? CGSize(width: galleryImage.width, height: galleryImage.height) : nil
        startingImage =
            metadataFields.contains(.startingImage) && !galleryImage.startingImage.isEmpty
            ? .galleryFilename(galleryImage.startingImage) : nil
        inputImages =
            metadataFields.contains(.inputImages)
            ? galleryImage.inputImages.compactMap { filename in
                filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : .galleryFilename(filename)
            }
            : []
        controlNets =
            metadataFields.contains(.controlNetImage) && !galleryImage.controlNetImage.isEmpty
            ? [
                SidebarRestoreControlNet(
                    name: nil,
                    image: .galleryFilename(galleryImage.controlNetImage)
                )
            ] : []
        // Saved captions do not contain starting-image strength.
        strength = nil
        steps = metadataFields.contains(.steps) ? galleryImage.steps : nil
        guidanceScale =
            metadataFields.contains(.guidanceScale) ? galleryImage.guidanceScale : nil
        scheduler = metadataFields.contains(.scheduler) ? galleryImage.scheduler : nil
        quality =
            metadataFields.contains(.quality) ? ImageQuality(galleryImage.quality) : nil
        computeUnits =
            metadataFields.contains(.mlComputeUnit) ? galleryImage.mlComputeUnit : nil
        seed = metadataFields.contains(.seed) ? galleryImage.seed : nil
        numberOfImages = nil
    }

    init(request: GenerationRequest) {
        model = .exact(request.modelID)
        prompt = request.metadataFields.contains(.prompt) ? request.prompt : nil
        negativePrompt =
            request.metadataFields.contains(.negativePrompt) ? request.negativePrompt : nil
        size = request.size

        if let startingImageData = request.startingImageData {
            startingImage = .encoded(startingImageData, name: request.startingImageName)
        } else {
            startingImage = nil
        }
        inputImages = request.inputImageData.enumerated().map { index, data in
            .encoded(data, name: request.inputImageNames[safe: index] ?? nil)
        }
        controlNets = request.controlNetImageData.enumerated().map { index, data in
            SidebarRestoreControlNet(
                name: request.controlNetNames[safe: index],
                image: .encoded(
                    data,
                    name: request.controlNetImageNames[safe: index] ?? nil
                )
            )
        }
        strength = request.strength.map(Double.init)
        steps = request.stepCount
        guidanceScale = request.guidanceScale.map(Double.init)
        scheduler = request.scheduler
        quality = request.quality
        computeUnits = request.mlComputeUnit
        seed = request.metadataFields.contains(.seed) ? request.seed : nil
        numberOfImages = request.numberOfImages
    }
}

@MainActor
@Observable
final class GenerationController {
    enum GalleryImageDestination: Equatable {
        case inputImage
        case startingImage
    }

    struct ControlNetInput {
        var name: String?
        var image: CGImage?
        var imageFilename: String?
    }

    private var logger = Logger()
    private(set) var configStore: ConfigStore
    private(set) var engineSettings: EngineSettingsStore
    private let modelRepository: ModelRepository
    private let engineRegistry: EngineRegistry
    private let imageRepository: ImageRepository
    private let fullImageProvider: GalleryFullImageProvider
    /// The gallery finished images are inserted into, and the one "copy to sidebar"
    /// reads its selection from. Injected for the same reason as
    /// `GalleryController.imageGallery`.
    private let imageGallery: ImageGallery
    /// The queue this controller submits to and observes.
    ///
    /// Injected rather than reached for as a singleton, which is what lets the
    /// gallery singleton go: the service holds a gallery, so as long as it built
    /// itself it needed a globally reachable one to hold.
    private let generationService: GenerationService
    private(set) var generationQueue = [GenerationRequest]()
    private(set) var currentGeneration: GenerationRequest?
    var hasGenerationWork: Bool { currentGeneration != nil || !generationQueue.isEmpty }
    private(set) var models = [any EngineModel]()
    /// What the last discovery pass has to report, if anything. Rendered beside
    /// the generation banner rather than through it — see
    /// ``discoveryMessage(failures:engines:foundModels:modelDir:)``.
    private(set) var discoveryMessage: String?
    private(set) var controlNet: [String] = []
    /// The image to denoise from, for a model that does img2img.
    ///
    /// Separate state from `inputImages`, not the first of it. The two mean
    /// different things to a model and are edited by different sidebar sections, and
    /// a model may declare either, both, or neither.
    private(set) var startingImage: InputImage?
    /// The reference images the sidebar is holding, in the order the user added them.
    ///
    /// Kept whole regardless of what the selected model accepts, so switching to a
    /// model that takes fewer does not throw away images the user chose. `plan`
    /// truncates to the model's `maxCount` when the request is built, and the
    /// sidebar marks the ones that will not be used.
    private(set) var inputImages: [InputImage] = []
    var numberOfImages = 1.0
    var seed: UInt32 = 0

    var currentModelId: ModelID? {
        didSet {
            if oldValue != currentModelId {
                galleryImageLoadGeneration += 1
            }
            guard let model = models.first(where: { $0.id == self.currentModelId }) else {
                // Selecting nothing — an engine with no models — has to clear the
                // ControlNet state too. Leaving it would offer the previous
                // model's ControlNets for a model that is not selected.
                controlNet = []
                currentControlNets = []
                return
            }
            engineSettings.selectedEngine = model.id.engine
            engineSettings.setSelectedModel(model.id, for: model.id.engine)
            // From the constraint rather than a downcast: which ControlNets a
            // model can use is something it declares, not something the
            // controller reads off one engine's concrete type.
            controlNet = model.constraints.controlNet.names
            currentControlNets = []
            reconcileImagesWithConstraints()
        }
    }

    /// Every registered engine, including unconfigured ones and ones with no
    /// models. The picker filters; Settings lists all of them.
    var engines: [AnyGenerationEngine] {
        engineRegistry.allEngines
    }

    /// Why each engine can or cannot be used, refreshed with every discovery pass.
    private(set) var engineAvailability: [EngineID: EngineAvailability] = [:]

    /// Increments per `loadModels()` call, so a pass that finishes after a newer one
    /// can tell and discard itself rather than overwriting it.
    private var loadGeneration = 0

    var selectedEngine: EngineID? {
        engineSettings.selectedEngine
    }

    /// The models the model picker shows: the selected engine's own.
    ///
    /// Falls back to every model when no engine is selected, which is the state
    /// before the first discovery pass finishes.
    var visibleModels: [any EngineModel] {
        guard let selectedEngine else { return models }
        return models.filter { $0.id.engine == selectedEngine }
    }

    /// Whether `engine` has anything to generate with right now.
    /// Whether an engine can be generated with right now.
    ///
    /// Both halves are needed and neither implies the other: a local engine is
    /// `.ready` as soon as its folder exists but has no models until one is put
    /// there, and a hosted engine always has a model but is not `.ready` until a
    /// key is entered.
    func isUsable(_ engine: EngineID) -> Bool {
        engineAvailability[engine] == .ready && hasModels(engine)
    }

    /// The engines the sidebar picker offers.
    ///
    /// Not every registered engine. Most people use one or two, and a mode switch
    /// that lists modes you cannot enter is noise on the surface you look at for
    /// every generation — which only gets worse as engines are added. Settings ▸
    /// Engines lists all of them unconditionally, and that is where an engine is
    /// meant to be discovered and configured.
    ///
    /// The selected engine is always included, even when it stops being usable.
    /// `restoreSelection` deliberately keeps a chosen engine whose models have
    /// disappeared so the picker can say why; hiding it would leave the selection
    /// pointing at something absent from its own picker, and take the explanation
    /// with it.
    ///
    /// Empty is a real answer, and `EngineView` renders a placeholder for it rather
    /// than this inventing one — an engine is a thing that can generate, and the
    /// placeholder is not one.
    var pickerEngines: [AnyGenerationEngine] {
        engines.filter { isUsable($0.id) || $0.id == selectedEngine }
    }

    func hasModels(_ engine: EngineID) -> Bool {
        models.contains { $0.id.engine == engine }
    }

    /// Switches engine, restoring the model that engine was last using.
    ///
    /// An engine with no models leaves the selection empty rather than borrowing
    /// another engine's model, so nothing generates with a model the user did not
    /// pick.
    func selectEngine(_ engine: EngineID) {
        guard engine != engineSettings.selectedEngine else { return }
        engineSettings.selectedEngine = engine
        currentModelId = rememberedOrFirstModel(for: engine)
    }

    private func rememberedOrFirstModel(for engine: EngineID) -> ModelID? {
        let candidates = models.filter { $0.id.engine == engine }
        if let remembered = engineSettings.selectedModel(for: engine),
            candidates.contains(where: { $0.id == remembered })
        {
            return remembered
        }
        return candidates.first?.id
    }
    var currentModel: (any EngineModel)? {
        models.first(where: { $0.id == self.currentModelId })
    }

    /// What the sidebar should offer. Falls back to
    /// `OptionConstraints.unconstrained` when no model is selected.
    var currentConstraints: OptionConstraints {
        currentModel?.constraints ?? .unconstrained
    }

    private(set) var currentControlNets: [ControlNetInput] = []
    private var pendingSelectedImageFilename: String?

    private var modelFolderMonitorTask: Task<Void, Never>?
    private var controlNetFolderMonitorTask: Task<Void, Never>?
    private var modelDirDebounceTask: Task<Void, Never>?
    private var controlNetDirDebounceTask: Task<Void, Never>?
    private var generationUpdatesTask: Task<Void, Never>?
    private var generationResultsTask: Task<Void, Never>?
    /// Supersedes an older gallery image load when the user invokes the action
    /// again before the first file has finished decoding.
    private var galleryImageLoadGeneration = 0
    /// Stored, and capturing weakly, so `shutdown()` can reach it. An
    /// unreferenced `Task` capturing `self` strongly would keep the controller
    /// alive until the load finished, with no handle to cancel.
    private var initialLoadTask: Task<Void, Never>?
    /// Checked before arming observation, scheduling a debounce or starting a
    /// monitor.
    ///
    /// A `withObservationTracking` callback stays armed until it fires, and firing
    /// is what re-registers it, so cancelling tasks alone does not stop a
    /// configuration change after `shutdown()` from scheduling fresh work.
    ///
    /// Also checked by `loadModels()` after its await. Cancellation is cooperative,
    /// so a refresh already past that point would otherwise mutate — and keep
    /// alive — a controller that has been shut down.
    private var isShutDown = false

    /// - Parameter startsObserving: whether to begin the eager work — the initial
    ///   model load, the folder monitors, and the generation-service observation.
    ///   The app always wants it. Tests opt out so the controller owns no
    ///   background task that can reload models, and therefore reassign
    ///   `currentModelId`, in the middle of their assertions: its `didSet` clears
    ///   `currentControlNets`, so a stray reload silently empties state a test
    ///   just set up.
    init(
        configStore: ConfigStore,
        modelRepository: ModelRepository = ModelRepository(),
        imageRepository: ImageRepository = ImageRepository(),
        imageGallery: ImageGallery,
        generationService: GenerationService,
        engineRegistry: EngineRegistry = EngineRegistry(),
        engineSettings: EngineSettingsStore? = nil,
        fullImageProvider: GalleryFullImageProvider = GalleryFullImageProvider(),
        startsObserving: Bool = true
    ) {
        self.configStore = configStore
        self.modelRepository = modelRepository
        self.engineRegistry = engineRegistry
        self.imageRepository = imageRepository
        self.fullImageProvider = fullImageProvider
        self.imageGallery = imageGallery
        self.generationService = generationService
        // Defaulted from the registry rather than by the caller, so the store only
        // ever loads selections for engines that actually exist.
        self.engineSettings =
            engineSettings
            ?? EngineSettingsStore(
                store: configStore.defaults,
                engines: engineRegistry.engineIDs
            )
        guard startsObserving else { return }
        initialLoadTask = Task { [weak self] in
            await self?.loadModels()
        }
        startModelFolderMonitor()
        startControlNetFolderMonitor()
        observeModelDir()
        observeControlNetDir()
        observeGenerationService()
        observeGenerationResults()
    }

    func loadModels() async {
        loadGeneration += 1
        let generation = loadGeneration
        logger.info("Started loading model directory at: \"\(self.configStore.modelDir)\"")
        let modelDirectoryURL = ModelRepository.modelDirectoryURL(
            fromPath: configStore.modelDir
        )
        let controlNetDirectoryURL = ModelRepository.controlNetDirectoryURL(
            fromPath: configStore.controlNetDir)

        let settings = EngineSettings(
            modelDirectory: modelDirectoryURL,
            controlNetDirectory: controlNetDirectoryURL
        )
        // One aggregate pass: availability and discovery gathered together, so
        // this cannot pair one engine's availability with another pass's models.
        let refresh = await engineRegistry.refresh(settings: settings)

        // The two guards that make a refresh abandonable. `loadModels` is
        // started by the initial load, two folder monitors and two debounced
        // settings paths, and `@MainActor` serialises the *mutations* without
        // preventing reentrancy across the await above. Without the epoch, a
        // pass for the previous models folder could finish after a newer pass
        // and overwrite its models, availability and selection.
        guard generation == loadGeneration else {
            logger.info("Discarding a superseded model load")
            return
        }
        guard !isShutDown else { return }

        engineAvailability = refresh.availability
        let discoveries = refresh.discoveries
        let discoveredModels = refresh.models
        // Assigned before the check below, so a pass that finds nothing empties
        // the picker instead of leaving the previous pass's models on screen.
        self.models = discoveredModels
        discoveryMessage = Self.discoveryMessage(
            failures: discoveries.failures,
            engines: engines,
            foundModels: !discoveredModels.isEmpty,
            modelDir: configStore.modelDir
        )
        guard !discoveredModels.isEmpty else {
            currentModelId = nil
            return
        }

        // Two migrations, in order, both idempotent. The first recovers the
        // engine for a pre-engine `Model` URL by matching what discovery just
        // found; the second turns that single selection into an engine plus a
        // per-engine model. A user upgrading across both arrives with the model
        // they had selected still selected.
        configStore.migrateSelectedModelIfNeeded(discovered: self.models.map(\.id))
        engineSettings.migrateSelectedEngineIfNeeded(
            from: configStore.selectedModel,
            discovered: self.models.map(\.id)
        )

        logger.info("Found \(self.models.count) model(s)")
        restoreSelection()
    }

    /// What to tell the user about the discovery pass, or `nil` when there is
    /// nothing to say.
    ///
    /// Owned by the controller rather than pushed into `GenerationState`: discovery
    /// and generation are different subjects, and sharing one banner means they
    /// overwrite each other.
    ///
    /// Reported per engine. A message that fired only when the combined model list
    /// was empty would be silenced permanently by any hosted engine, since one
    /// always has a model, hiding a broken models folder.
    ///
    /// Availability is not reported here: "Add an API key" is a standing fact about
    /// an engine rather than a problem with this pass, and the picker already says it
    /// next to the engine's name.
    nonisolated static func discoveryMessage(
        failures: [(engine: EngineID, error: any Error)],
        engines: [AnyGenerationEngine],
        foundModels: Bool,
        modelDir: String
    ) -> String? {
        if !failures.isEmpty {
            let names = failures.map { failure in
                engines.first { $0.id == failure.engine }?.displayName
                    ?? failure.engine.rawValue
            }
            return String(
                localized: "Couldn't read the models folder for \(names.joined(separator: ", ")).",
                comment: "Shown when one or more engines could not read their models folder"
            )
        }
        guard !foundModels else { return nil }
        return String(
            localized: "No models found under: \(modelDir)",
            comment: "Shown when discovery completed but found no models anywhere"
        )
    }

    /// Picks the engine and model to show after a discovery pass.
    ///
    /// A persisted engine is kept even when it has no models, so the picker can
    /// say why rather than moving the user to an engine they did not choose. With
    /// no engine persisted — a first launch, or a selection whose engine is no
    /// longer registered — the first engine that actually has a model is chosen,
    /// in registration order, so the sidebar is never pointlessly empty.
    private func restoreSelection() {
        if let engine = engineSettings.selectedEngine, engines.contains(where: { $0.id == engine })
        {
            currentModelId = rememberedOrFirstModel(for: engine)
            return
        }
        // The engine of the first model in the combined list, not the first engine
        // in registration order. `models` is sorted by name, so this lands on the
        // same model the app picked before engines were selectable; going by
        // registration order would instead make Iris the default for any mixed
        // folder, which is arbitrary and would change what a fresh install opens
        // with.
        //
        // Restricted to engines that are `.ready`, which matters as soon as a
        // hosted engine ships. It always has a model, so without this an empty
        // local folder would land on an engine with no API key — and because
        // assigning `currentModelId` persists it, that would overwrite the
        // selection the user had and not give it back when their folder returned.
        // Selecting nothing is better: the picker still lists every engine with
        // its reason.
        guard
            let firstModel = models.first(where: {
                engineAvailability[$0.id.engine] == .ready
            })
        else {
            currentModelId = nil
            return
        }
        engineSettings.selectedEngine = firstModel.id.engine
        currentModelId = rememberedOrFirstModel(for: firstModel.id.engine)
    }

    func generate() async {
        guard let request = buildGenerationRequest() else { return }
        // Asking again is a new attempt, so it forgets what was dismissed during
        // the last one. The boundary is here rather than at the start of a drain
        // because the folder check below fails *before* anything is enqueued: with
        // no drain to reset it, dismissing this error once would suppress it for
        // every later click, and Generate would go silent with nothing queued.
        GenerationState.shared.noteBatchStarted()
        // Both engines write through ImageRepository, so an unwritable images
        // folder should surface before the job is queued rather than after it runs.
        do {
            _ = try await imageRepository.ensureOutputDirectory(
                imageDir: request.imageDir
            )
        } catch ImageRepositoryError.imageDirectoryNoAccess(let path) {
            await generationService.updateStatus(
                .error("Couldn't access images folder at: \(path)")
            )
            return
        } catch {
            await generationService.updateStatus(
                .error("Couldn't access images folder.")
            )
            return
        }

        await generationService.enqueue(request)
    }

    // MARK: - Starting image

    func setStartingImage(image: CGImage, filename: String? = nil) {
        startingImage = InputImage(
            image: image,
            name: filename?.normalizedFilename ?? consumePendingSelectedImageFilename()
        )
    }

    func unsetStartingImage() async {
        startingImage = nil
    }

    func selectStartingImage() async {
        guard let image = await selectImage() else { return }
        setStartingImage(image: image)
    }

    func setStartingImageEdit(_ edit: IrisReferenceImageEdit) {
        startingImage?.edit = edit.clamped()
    }

    // MARK: - Input images

    /// How many reference images the selected model will take.
    var maxInputImageCount: Int {
        currentConstraints.inputImages.maxCount
    }

    /// Appends an image, up to what the selected model accepts.
    ///
    /// Refuses silently at the cap rather than dropping the oldest: a user who has
    /// filled the list and adds another is more likely to have miscounted than to
    /// want their first image replaced.
    func addInputImage(image: CGImage, filename: String? = nil) {
        guard maxInputImageCount > 0, inputImages.count < maxInputImageCount else { return }
        inputImages.append(
            InputImage(
                image: image,
                name: filename?.normalizedFilename ?? consumePendingSelectedImageFilename()
            )
        )
    }

    func setInputImages(_ images: [InputImage]) {
        inputImages = images
    }

    /// Sets the image at `index`, appending when the list is not that long yet.
    ///
    /// Indexed rather than keyed by id because the sidebar shows an empty well past
    /// the last image — the slot exists before anything is in it.
    ///
    /// Replacing keeps the entry's id, so its row does not animate out and back in,
    /// and drops its old name: the previous filename no longer describes the new
    /// picture, and keeping it would put a wrong name in the image's metadata.
    func setInputImage(image: CGImage, at index: Int, filename: String? = nil) {
        let name = filename?.normalizedFilename ?? consumePendingSelectedImageFilename()
        guard index >= 0, index < maxInputImageCount else { return }

        if index < inputImages.count {
            inputImages[index].image = image
            inputImages[index].name = name
            // A new picture invalidates a crop dragged out against the old one.
            inputImages[index].edit = .identity
        } else if index == inputImages.count {
            inputImages.append(InputImage(image: image, name: name))
        }
    }

    /// Fills consecutive slots from `index`, for a multi-file drop.
    ///
    /// Extras past the model's limit are dropped rather than wrapping around to the
    /// front, so dropping six files on a four-image model keeps the first four.
    func setInputImages(_ dropped: [ImageWellView.DroppedImage], startingAt index: Int) {
        for (offset, item) in dropped.enumerated() {
            setInputImage(image: item.image, at: index + offset, filename: item.filename)
        }
    }

    func unsetInputImage(at index: Int) {
        guard inputImages.indices.contains(index) else { return }
        inputImages.remove(at: index)
    }

    /// Where the gallery's reuse action will put an image for the selected model.
    ///
    /// References take precedence for a model that supports both roles. A full
    /// reference list disables the action rather than unexpectedly switching its
    /// meaning to starting image or replacing one the user already chose.
    var galleryImageDestination: GalleryImageDestination? {
        guard currentModel != nil else { return nil }
        let constraints = currentConstraints
        if constraints.inputImages.isSupported {
            return inputImages.count < constraints.inputImages.maxCount ? .inputImage : nil
        }
        return constraints.startingImage.isSupported ? .startingImage : nil
    }

    /// Loads a gallery image on demand and sends it to the role the selected model
    /// accepts.
    ///
    /// The file read suspends outside this main-actor controller. Model changes and
    /// newer gallery actions own the sidebar after that suspension, so an older
    /// load is discarded rather than updating their destination.
    func useGalleryImage(_ sdi: SDImage) async {
        guard let modelID = currentModelId, let destination = galleryImageDestination else {
            return
        }
        let destinationStartingImage = startingImage
        let destinationInputImages = inputImages
        galleryImageLoadGeneration += 1
        let generation = galleryImageLoadGeneration
        guard let image = await fullImageProvider.image(for: sdi) else { return }
        guard generation == galleryImageLoadGeneration,
            currentModelId == modelID,
            galleryImageDestination == destination,
            startingImage == destinationStartingImage,
            inputImages == destinationInputImages
        else { return }

        let filename = URL(fileURLWithPath: sdi.path).lastPathComponent
        switch destination {
        case .inputImage:
            addInputImage(image: image, filename: filename)
        case .startingImage:
            setStartingImage(image: image, filename: filename)
        }
    }

    /// Moves images between the two sections when the selected model changes what it
    /// accepts.
    ///
    /// Called from `currentModelId.didSet`. Without it, choosing a picture on a Core
    /// ML model and switching to Klein would leave it in a section the new model does
    /// not read, looking like the app forgot it. Moving it is better than discarding
    /// it and better than leaving it stranded — the user chose that picture, and both
    /// sections are asking the same question of it.
    ///
    /// Only ever moves a single image, and only into an empty destination, so nothing
    /// is silently reordered or dropped.
    private func reconcileImagesWithConstraints() {
        let constraints = currentConstraints

        if !constraints.startingImage.isSupported, let stranded = startingImage {
            startingImage = nil
            if constraints.inputImages.isSupported, inputImages.isEmpty {
                inputImages = [stranded]
            }
        }

        if !constraints.inputImages.isSupported, !inputImages.isEmpty {
            let stranded = inputImages
            inputImages = []
            if constraints.startingImage.isSupported, startingImage == nil,
                stranded.count == 1
            {
                startingImage = stranded[0]
            }
        }
    }

    // MARK: - Per-image crop

    func inputImageEdit(at index: Int) -> IrisReferenceImageEdit? {
        inputImages[safe: index]?.edit
    }

    func setInputImageEdit(_ edit: IrisReferenceImageEdit, at index: Int) {
        guard inputImages.indices.contains(index) else { return }
        inputImages[index].edit = edit.clamped()
    }

    func resetInputImageEdit(at index: Int) {
        setInputImageEdit(.identity, at: index)
    }

    /// The cropped image, for the well's preview.
    func editedInputImage(at index: Int) -> CGImage? {
        inputImages[safe: index]?.edited
    }

    func editedInputImageSize(at index: Int) -> CGSize? {
        inputImages[safe: index]?.editedSize
    }

    /// What will actually be sent, cropped and fitted the way the request will
    /// fit it. Shown in the crop popover's preview so the estimate is not a
    /// separate calculation from the one that runs.
    func preprocessedInputImage(at index: Int) -> CGImage? {
        guard let cropped = editedInputImage(at: index) else { return nil }
        guard let target = predictedInputImageSize(at: index) else { return cropped }
        return IrisReferenceImageProcessor.resizedAndCroppedToTokenGrid(cropped, to: target)
            ?? cropped
    }

    /// The size the model's own budget leaves for this image, or `nil` when the
    /// engine has no budget to fit — every engine but Iris.
    func predictedInputImageSize(at index: Int) -> CGSize? {
        irisReferenceBudgetReport?.predictedReferenceSizes[safe: index]
    }

    /// Iris's attention budget for the current references, or `nil` for any other
    /// engine or when there are no references.
    ///
    /// Computed through `IrisEngine.budgetReport`, the same call `plan` makes, so
    /// the warning the sidebar shows and the sizes the request uses cannot drift
    /// apart.
    var irisReferenceBudgetReport: IrisReferenceBudgetReport? {
        guard let model = currentModel as? IrisFluxKleinModel else { return nil }
        return IrisEngine.budgetReport(
            for: inputImages,
            model: model,
            outputSize: currentConstraints.size.resolved(
                CGSize(width: configStore.width, height: configStore.height)
            ),
            constraint: currentConstraints.inputImages
        )
    }

    func setControlNet(name: String) async {
        if self.currentControlNets.isEmpty {
            self.currentControlNets = [ControlNetInput(name: name, image: nil, imageFilename: nil)]
        } else {
            self.currentControlNets[0].name = name
        }
    }

    func setControlNet(image: CGImage, filename: String? = nil) async {
        let imageFilename = filename?.normalizedFilename ?? consumePendingSelectedImageFilename()
        if self.currentControlNets.isEmpty {
            self.currentControlNets = [
                ControlNetInput(name: nil, image: image, imageFilename: imageFilename)
            ]
        } else {
            self.currentControlNets[0].image = image
            self.currentControlNets[0].imageFilename = imageFilename
        }
    }

    func unsetControlNet() async {
        self.currentControlNets = []
    }

    func selectControlNetImage(at index: Int) async {
        guard let image = await selectImage() else { return }
        let imageFilename = consumePendingSelectedImageFilename()

        if currentControlNets.isEmpty {
            currentControlNets = [
                ControlNetInput(name: nil, image: image, imageFilename: imageFilename)
            ]
        } else if index >= currentControlNets.count {
            currentControlNets.append(
                ControlNetInput(name: nil, image: image, imageFilename: imageFilename)
            )
        } else {
            currentControlNets[index].image = image
            currentControlNets[index].imageFilename = imageFilename
        }
    }

    func unsetControlNetImage(at index: Int) async {
        guard index < currentControlNets.count else { return }
        currentControlNets[index].image = nil
        currentControlNets[index].imageFilename = nil
    }

    func selectImage() async -> CGImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(
            localized: "Choose image",
            comment: "Message text for choosing starting image or ControlNet image")
        panel.prompt = String(localized: "Select", comment: "OK button text for choose image panel")
        let resp = await ModalPresentation.present(panel)
        if resp != .OK {
            return nil
        }

        guard let url = panel.url else { return nil }
        guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)
        pendingSelectedImageFilename = url.lastPathComponent

        return CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil)
    }

    private func consumePendingSelectedImageFilename() -> String? {
        defer { pendingSelectedImageFilename = nil }
        return pendingSelectedImageFilename?.normalizedFilename
    }

    func copyToPrompt() async {
        guard let sdi = imageGallery.selected() else { return }
        await copyToPrompt(sdi)
    }

    func copyToPrompt(_ sdi: SDImage) async {
        let metadataFields = imageGallery.metadataFields(for: sdi.id)
        await restoreSidebar(
            from: SidebarRestoreSource(galleryImage: sdi, metadataFields: metadataFields)
        )
    }

    func copyToPrompt(_ request: GenerationRequest) async {
        await restoreSidebar(from: SidebarRestoreSource(request: request))
    }

    func copyPromptToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        configStore.prompt = sdi.prompt
    }

    func copyModelToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        selectModel(named: sdi.model, engine: sdi.engine, key: sdi.modelKey)
    }

    /// Selects the model a gallery image was generated with.
    ///
    /// An image whose metadata records an engine and key resolves exactly. Older
    /// images carry only a display name, which two engines may both offer — see
    /// `setModel(_:)` for how that ambiguity is settled.
    func selectModel(named name: String, engine: String, key: String) {
        if !engine.isEmpty || !key.isEmpty {
            guard !engine.isEmpty, !key.isEmpty else { return }
            let id = ModelID(engine: EngineID(rawValue: engine), key: key)
            if models.contains(where: { $0.id == id }) {
                currentModelId = id
            }
            return
        }
        setModel(name)
    }

    private func restoreSidebar(from source: SidebarRestoreSource) async {
        selectModel(for: source.model)
        guard let destinationModel = currentModel else { return }
        let destinationModelID = destinationModel.id
        let constraints = destinationModel.constraints

        let restoredStartingImage =
            constraints.startingImage.isSupported
            ? await restoreImage(source.startingImage) : nil
        var restoredInputImages: [InputImage] = []
        if constraints.inputImages.isSupported {
            for image in source.inputImages.prefix(constraints.inputImages.maxCount) {
                if let restored = await restoreImage(image) {
                    restoredInputImages.append(restored)
                }
            }
        }

        var restoredControlNets: [ControlNetInput] = []
        if constraints.controlNet.isSupported {
            for controlNet in source.controlNets {
                if let name = controlNet.name, !constraints.controlNet.names.contains(name) {
                    continue
                }
                guard let restored = await restoreImage(controlNet.image) else { continue }
                restoredControlNets.append(
                    ControlNetInput(
                        name: controlNet.name,
                        image: restored.image,
                        imageFilename: restored.name
                    )
                )
            }
        }

        // Loading a path-backed gallery image suspends. If the user selected a
        // different model while it was loading, that newer choice owns the sidebar.
        guard currentModelId == destinationModelID else { return }

        apply(source, constrainedBy: constraints, to: destinationModel)
        startingImage = restoredStartingImage
        inputImages = restoredInputImages
        currentControlNets = restoredControlNets
    }

    private func selectModel(for source: SidebarRestoreModel) {
        switch source {
        case .exact(let id):
            if models.contains(where: { $0.id == id }) {
                currentModelId = id
            }
        case .legacyName(let name):
            setModel(name)
        case .unavailable, .unspecified:
            break
        }
    }

    private func restoreImage(_ source: SidebarRestoreImage?) async -> InputImage? {
        guard let source else { return nil }
        let image: CGImage?
        switch source {
        case .encoded(let data, _):
            image = CGImage.fromData(data)
        case .galleryFilename(let filename):
            guard let galleryImage = galleryImage(named: filename) else { return nil }
            image = await fullImageProvider.image(for: galleryImage)
        }
        guard let image else { return nil }
        return InputImage(image: image, name: source.name)
    }

    private func galleryImage(named filename: String) -> SDImage? {
        imageGallery.image(named: filename)
    }

    private func apply(
        _ source: SidebarRestoreSource,
        constrainedBy constraints: OptionConstraints,
        to model: any EngineModel
    ) {
        if let prompt = source.prompt {
            configStore.prompt = prompt
        }
        if constraints.supportsNegativePrompt, let negativePrompt = source.negativePrompt {
            configStore.negativePrompt = negativePrompt
        }
        if let size = source.size {
            configStore.width = Int(size.width)
            configStore.height = Int(size.height)
        }
        if constraints.steps.isSupported, let steps = source.steps {
            configStore.steps = Double(steps)
        }
        if constraints.guidanceScale.isSupported, let guidanceScale = source.guidanceScale {
            configStore.guidanceScale = guidanceScale
        }
        if let scheduler = source.scheduler, constraints.scheduler.options.contains(scheduler) {
            configStore.scheduler = scheduler
        }
        if let quality = source.quality, constraints.quality.options.contains(quality) {
            configStore.quality = quality
        }
        if constraints.startingImage.strength.isSupported, let strength = source.strength {
            configStore.strength = strength
        }
        if constraints.numberOfImages.isSupported, let numberOfImages = source.numberOfImages {
            self.numberOfImages = Double(numberOfImages)
        }
        if let seed = source.seed {
            self.seed = seed
        }
        if model.id.engine == .coreMLStableDiffusion,
            let preference = source.computeUnits.flatMap(ComputeUnitPreference.init(exact:))
        {
            configStore.mlComputeUnitPreference = preference
        }
    }

    /// Selects a model by display name, which is all a pre-engine image recorded.
    ///
    /// Prefers the engine already selected, so a name two engines both offer does
    /// not move the user off the engine they are working in. Failing that, a single
    /// unambiguous match elsewhere is taken. If several engines offer the name, the
    /// selection is left alone.
    func setModel(_ modelName: String) {
        let matches = models.filter { $0.name == modelName }
        guard !matches.isEmpty else { return }

        if let currentEngine = currentModelId?.engine,
            let sameEngine = matches.first(where: { $0.id.engine == currentEngine })
        {
            currentModelId = sameEngine.id
            return
        }
        if matches.count == 1 {
            currentModelId = matches[0].id
        }
    }

    func copySizeToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        setSize(width: sdi.width, height: sdi.height)
    }

    /// Applies a size, which for some engines means selecting a different model.
    ///
    /// Core ML models are converted at a fixed resolution and usually ship as a
    /// per-orientation set, so a size the current model cannot produce may be
    /// another model's. The engine answers whether such a model exists, so this
    /// does not have to know how any engine names its files.
    func setSize(width: Int, height: Int) {
        guard let model = currentModel else { return }
        let size = CGSize(width: width, height: height)

        if model.constraints.size.isEditable {
            configStore.width = width
            configStore.height = height
            return
        }

        guard
            let engine = engineRegistry.engine(model.id.engine),
            let variant = engine.model(
                forSize: size,
                among: models.filter { $0.id.engine == model.id.engine },
                current: model
            )
        else { return }
        currentModelId = variant.id
    }

    /// Whether `setSize(width:height:)` would change anything, so the sidebar
    /// can hide a swap control that would silently do nothing.
    func canSetSize(width: Int, height: Int) -> Bool {
        guard let model = currentModel else { return false }
        if model.constraints.size.isEditable { return true }
        guard let engine = engineRegistry.engine(model.id.engine) else { return false }
        let variant = engine.model(
            forSize: CGSize(width: width, height: height),
            among: models.filter { $0.id.engine == model.id.engine },
            current: model
        )
        return variant != nil && variant?.id != model.id
    }

    func copyNegativePromptToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        configStore.negativePrompt = sdi.negativePrompt
    }

    func copySchedulerToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        configStore.scheduler = sdi.scheduler
    }

    func copySeedToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        seed = sdi.seed
    }

    func copyStepsToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        configStore.steps = Double(sdi.steps)
    }

    func copyGuidanceScaleToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        configStore.guidanceScale = sdi.guidanceScale
    }

    /// Gathers the sidebar into a `GenerationDraft`, hands it to the selected
    /// model's engine to resolve, and copies the resulting plan into a request.
    /// Every per-engine decision belongs to that engine's `plan`.
    ///
    /// Internal rather than private so tests can assert the exact request the app
    /// builds.
    func buildGenerationRequest() -> GenerationRequest? {
        guard let model = currentModel else { return nil }
        guard let engine = engineRegistry.engine(model.id.engine) else {
            logger.error("no engine registered for \(model.id.description)")
            return nil
        }

        let draft = GenerationDraft(
            prompt: configStore.prompt,
            negativePrompt: configStore.negativePrompt,
            configuredSize: CGSize(width: configStore.width, height: configStore.height),
            startingImage: startingImage,
            inputImages: inputImages,
            controlNets: currentControlNets.map {
                ControlNetDraft(name: $0.name, image: $0.image, imageName: $0.imageFilename)
            },
            strength: Float(configStore.strength),
            stepCount: Int(configStore.steps),
            guidanceScale: Float(configStore.guidanceScale),
            scheduler: configStore.scheduler,
            quality: configStore.quality,
            seed: seed == 0 ? UInt32.random(in: 0..<UInt32.max) : seed,
            numberOfImages: Int(numberOfImages),
            computeUnitPreference: configStore.mlComputeUnitPreference,
            reduceMemory: configStore.reduceMemory,
            safetyChecker: configStore.safetyChecker,
            showGenerationPreview: configStore.showGenerationPreview,
            imageDir: configStore.imageDir,
            imageType: configStore.imageType,
            controlNetDirectory: ModelRepository.controlNetDirectoryURL(
                fromPath: configStore.controlNetDir
            )
        )

        let plan: GenerationPlan<any Sendable>
        do {
            plan = try engine.plan(draft: draft, model: model)
        } catch {
            logger.error("\(engine.id.rawValue) could not plan a generation: \(error)")
            GenerationState.shared.report(.error(error.localizedDescription))
            return nil
        }

        return GenerationRequest(
            modelID: model.id,
            displayName: model.name,
            metadataFields: model.metadataFields,
            payload: plan.payload,
            prompt: draft.prompt,
            negativePrompt: draft.negativePrompt,
            size: plan.size,
            startingImageData: plan.startingImageData,
            inputImageData: plan.inputImageData,
            startingImageName: plan.startingImageName,
            controlNetImageData: plan.controlNetImageData,
            controlNetNames: plan.controlNetNames,
            controlNetImageNames: plan.controlNetImageNames,
            inputImageNames: plan.inputImageNames,
            strength: plan.strength,
            stepCount: plan.stepCount,
            guidanceScale: plan.guidanceScale,
            scheduler: plan.scheduler,
            quality: plan.quality,
            mlComputeUnit: plan.mlComputeUnit,
            useDenoisedIntermediates: draft.showGenerationPreview,
            seed: draft.seed,
            numberOfImages: plan.numberOfImages,
            imageDir: draft.imageDir,
            imageType: draft.imageType
        )
    }

    /// Cancels every task this controller owns and stops it starting new ones.
    ///
    /// The observation loops iterate streams that never end by themselves, so
    /// without this they keep consuming after the controller is finished with.
    /// Call before releasing a controller that was constructed with
    /// `startsObserving: true`.
    func shutdown() {
        isShutDown = true
        initialLoadTask?.cancel()
        generationUpdatesTask?.cancel()
        generationResultsTask?.cancel()
        modelFolderMonitorTask?.cancel()
        controlNetFolderMonitorTask?.cancel()
        modelDirDebounceTask?.cancel()
        controlNetDirDebounceTask?.cancel()
        initialLoadTask = nil
        generationUpdatesTask = nil
        generationResultsTask = nil
        modelFolderMonitorTask = nil
        controlNetFolderMonitorTask = nil
        modelDirDebounceTask = nil
        controlNetDirDebounceTask = nil
    }

    private func observeGenerationService() {
        generationUpdatesTask?.cancel()
        // The service is captured alongside the weak self, not read through it: the
        // loop must be able to reach the stream without resurrecting a controller
        // that has gone away.
        generationUpdatesTask = Task { [weak self, service = generationService] in
            let stream = await service.updates()
            for await snapshot in stream {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    private func observeGenerationResults() {
        generationResultsTask?.cancel()
        generationResultsTask = Task { [weak self, service = generationService] in
            let stream = await service.results()
            for await result in stream {
                guard let self else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ snapshot: GenerationService.Snapshot) {
        generationQueue = snapshot.queue
        currentGeneration = snapshot.current
    }

    private func apply(_ result: GenerationResult) {
        let shouldAnimateInsert = imageGallery.currentGeneratingImage == nil
        defer {
            // Scoped to the request that produced this result. Results arrive on
            // their own channel and can be applied after the next request has put
            // its first preview up; clearing unconditionally erased it.
            if let requestID = result.requestID {
                imageGallery.clearCurrentGenerating(owner: requestID)
            } else {
                imageGallery.clearCurrentGenerating()
            }
        }
        guard let url = result.imageURL else { return }
        let metadata = result.metadata
        let width = metadata.width
        let height = metadata.height
        let aspectRatio = height > 0 ? Double(width) / Double(height) : 0
        let record = ImageRecord(
            id: result.id,
            prompt: metadata.prompt,
            negativePrompt: metadata.negativePrompt,
            width: width,
            height: height,
            aspectRatio: aspectRatio,
            model: metadata.model,
            engine: metadata.engine,
            modelKey: metadata.modelKey,
            quality: metadata.quality,
            startingImage: metadata.startingImage,
            controlNetImage: metadata.controlNetImage,
            inputImages: metadata.inputImages,
            scheduler: metadata.scheduler,
            mlComputeUnit: metadata.mlComputeUnit,
            seed: metadata.seed,
            steps: metadata.steps,
            guidanceScale: metadata.guidanceScale,
            metadataFields: metadata.metadataFields,
            generatedDate: metadata.generatedDate,
            path: url.path(percentEncoded: false),
            finderTagColorNumber: 0,
            imageData: result.imageData,
            loras: metadata.loras
        )
        guard let sdi = createSDImage(from: record) else { return }
        imageGallery.add(
            sdi,
            metadataFields: metadata.metadataFields,
            animate: shouldAnimateInsert
        )
    }

    /// Stops the running generation.
    ///
    /// Here rather than the view reaching for the queue itself, so the controller
    /// stays the one thing that knows which queue it is talking to.
    func stopCurrentGeneration() async {
        await generationService.stopCurrentGeneration()
    }

    func removeQueued(_ id: GenerationRequest.ID) async {
        await generationService.removeQueued(id: id)
    }

    private func observeModelDir() {
        guard !isShutDown else { return }
        withObservationTracking {
            _ = configStore.modelDir
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleModelDirUpdate()
                self?.observeModelDir()
            }
        }
    }

    private func observeControlNetDir() {
        guard !isShutDown else { return }
        withObservationTracking {
            _ = configStore.controlNetDir
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleControlNetDirUpdate()
                self?.observeControlNetDir()
            }
        }
    }

    private func scheduleModelDirUpdate() {
        guard !isShutDown else { return }
        modelDirDebounceTask?.cancel()
        modelDirDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            await updateModelFolderMonitor()
        }
    }

    private func scheduleControlNetDirUpdate() {
        guard !isShutDown else { return }
        controlNetDirDebounceTask?.cancel()
        controlNetDirDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            await updateControlNetFolderMonitor()
        }
    }

    private func updateModelFolderMonitor() async {
        startModelFolderMonitor()
        await loadModels()
    }

    private func updateControlNetFolderMonitor() async {
        startControlNetFolderMonitor()
        await loadModels()
    }

    private func startModelFolderMonitor() {
        guard !isShutDown else { return }
        modelFolderMonitorTask?.cancel()
        let path = modelDirectoryPath()
        modelFolderMonitorTask = Task { [weak self] in
            // Weak *inside* the loop, not before it. Hoisting `self` out kept the
            // controller alive for as long as the task ran, and the task ran
            // forever, so neither could be released.
            let stream = await FolderMonitorService.shared.updates(for: path)
            for await _ in stream {
                guard let self else { return }
                await self.loadModels()
            }
        }
    }

    private func startControlNetFolderMonitor() {
        guard !isShutDown else { return }
        controlNetFolderMonitorTask?.cancel()
        let path = controlNetDirectoryPath()
        controlNetFolderMonitorTask = Task { [weak self] in
            let stream = await FolderMonitorService.shared.updates(for: path)
            for await _ in stream {
                guard let self else { return }
                await self.loadModels()
            }
        }
    }

    private func modelDirectoryPath() -> String {
        ModelRepository.modelDirectoryURL(fromPath: configStore.modelDir)
            .path(percentEncoded: false)
    }

    private func controlNetDirectoryPath() -> String {
        ModelRepository.controlNetDirectoryURL(fromPath: configStore.controlNetDir)
            .path(percentEncoded: false)
    }
}
