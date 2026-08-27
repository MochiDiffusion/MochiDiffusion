//
//  ConfigStore.swift
//  Mochi Diffusion
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable final class ConfigStore {
    /// Storage keys, named once so ``init(store:)`` and tests cannot drift from
    /// the property wrappers.
    enum Key {
        static let imageDir = "ImageDir"
        static let imageType = "ImageType"
        static let modelDir = "ModelDir"
        static let controlNetDir = "ControlNetDir"
        static let modelId = "Model"
        static let prompt = "Prompt"
        static let negativePrompt = "NegativePrompt"
        static let strength = "ImageStrength"
        static let steps = "Steps"
        static let guidanceScale = "Scale"
        static let width = "ImageWidth"
        static let height = "ImageHeight"
        static let scheduler = "Scheduler"
        static let showGenerationPreview = "ShowGenerationPreview"
        static let mlComputeUnitPreference = "MLComputeUnitPreference"
        static let reduceMemory = "ReduceMemory"
        static let safetyChecker = "SafetyChecker"
        static let useTrash = "UseTrash"
    }

    /// Declared once for the same reason. `init(store:)` has to restate every
    /// default when it rebinds the wrappers, and a default that drifts from its
    /// declaration would be visible only under an injected store — that is, only
    /// in tests, and as a wrong expected value rather than a failure.
    private enum Default {
        static let imageDir = ""
        static let imageType = UTType.png.preferredFilenameExtension!
        static let modelDir = ""
        static let controlNetDir = ""
        static let prompt = ""
        static let negativePrompt = ""
        static let strength = 0.75
        static let steps = 12.0
        static let guidanceScale = 11.0
        static let width = 512
        static let height = 512
        static let scheduler = Scheduler.dpmSolverMultistepScheduler
        static let showGenerationPreview = true
        static let mlComputeUnitPreference = ComputeUnitPreference.auto
        static let reduceMemory = false
        static let safetyChecker = false
        static let useTrash = true
    }

    @ObservationIgnored @AppStorage(Key.imageDir) private var _imageDir = Default.imageDir
    @ObservationIgnored @AppStorage(Key.imageType) private var _imageType = Default.imageType
    @ObservationIgnored @AppStorage(Key.modelDir) private var _modelDir = Default.modelDir
    @ObservationIgnored @AppStorage(Key.controlNetDir) private var _controlNetDir =
        Default.controlNetDir
    @ObservationIgnored @AppStorage(Key.modelId) private var _modelId: URL?
    @ObservationIgnored @AppStorage(Key.prompt) private var _prompt = Default.prompt
    @ObservationIgnored @AppStorage(Key.negativePrompt) private var _negativePrompt =
        Default.negativePrompt
    @ObservationIgnored @AppStorage(Key.strength) private var _strength = Default.strength
    @ObservationIgnored @AppStorage(Key.steps) private var _steps = Default.steps
    @ObservationIgnored @AppStorage(Key.guidanceScale) private var _guidanceScale =
        Default.guidanceScale
    @ObservationIgnored @AppStorage(Key.width) private var _width = Default.width
    @ObservationIgnored @AppStorage(Key.height) private var _height = Default.height
    @ObservationIgnored @AppStorage(Key.scheduler) private var _scheduler = Default.scheduler
    @ObservationIgnored @AppStorage(Key.showGenerationPreview) private var _showGenPreview =
        Default.showGenerationPreview
    @ObservationIgnored @AppStorage(Key.mlComputeUnitPreference)
    private var _mlComputeUnitPreference = Default.mlComputeUnitPreference
    @ObservationIgnored @AppStorage(Key.reduceMemory) private var _reduceMemory =
        Default.reduceMemory
    @ObservationIgnored @AppStorage(Key.safetyChecker) private var _safetyChecker =
        Default.safetyChecker
    @ObservationIgnored @AppStorage(Key.useTrash) private var _useTrash = Default.useTrash

    /// - Parameter store: the defaults every value is read from and written to.
    ///   `nil` keeps `@AppStorage`'s own `UserDefaults.standard`, which is what
    ///   the app always wants; tests pass an isolated suite so they neither read
    ///   nor overwrite the real app's settings. The test host *is* Mochi
    ///   Diffusion, so `UserDefaults.standard` here is the developer's own
    ///   preferences.
    init(store: UserDefaults? = nil) {
        guard let store else { return }
        __imageDir = AppStorage(wrappedValue: Default.imageDir, Key.imageDir, store: store)
        __imageType = AppStorage(wrappedValue: Default.imageType, Key.imageType, store: store)
        __modelDir = AppStorage(wrappedValue: Default.modelDir, Key.modelDir, store: store)
        __controlNetDir = AppStorage(
            wrappedValue: Default.controlNetDir, Key.controlNetDir, store: store)
        __modelId = AppStorage(Key.modelId, store: store)
        __prompt = AppStorage(wrappedValue: Default.prompt, Key.prompt, store: store)
        __negativePrompt = AppStorage(
            wrappedValue: Default.negativePrompt, Key.negativePrompt, store: store)
        __strength = AppStorage(wrappedValue: Default.strength, Key.strength, store: store)
        __steps = AppStorage(wrappedValue: Default.steps, Key.steps, store: store)
        __guidanceScale = AppStorage(
            wrappedValue: Default.guidanceScale, Key.guidanceScale, store: store)
        __width = AppStorage(wrappedValue: Default.width, Key.width, store: store)
        __height = AppStorage(wrappedValue: Default.height, Key.height, store: store)
        __scheduler = AppStorage(wrappedValue: Default.scheduler, Key.scheduler, store: store)
        __showGenPreview = AppStorage(
            wrappedValue: Default.showGenerationPreview, Key.showGenerationPreview, store: store)
        __mlComputeUnitPreference = AppStorage(
            wrappedValue: Default.mlComputeUnitPreference,
            Key.mlComputeUnitPreference,
            store: store
        )
        __reduceMemory = AppStorage(
            wrappedValue: Default.reduceMemory, Key.reduceMemory, store: store)
        __safetyChecker = AppStorage(
            wrappedValue: Default.safetyChecker, Key.safetyChecker, store: store)
        __useTrash = AppStorage(wrappedValue: Default.useTrash, Key.useTrash, store: store)
    }

    var imageDir: String {
        get {
            access(keyPath: \.imageDir)
            return _imageDir
        }
        set {
            withMutation(keyPath: \.imageDir) {
                _imageDir = newValue
            }
        }
    }

    var imageType: String {
        get {
            access(keyPath: \.imageType)
            return _imageType
        }
        set {
            withMutation(keyPath: \.imageType) {
                _imageType = newValue
            }
        }
    }

    var modelDir: String {
        get {
            access(keyPath: \.modelDir)
            return _modelDir
        }
        set {
            withMutation(keyPath: \.modelDir) {
                _modelDir = newValue
            }
        }
    }

    var controlNetDir: String {
        get {
            access(keyPath: \.controlNetDir)
            return _controlNetDir
        }
        set {
            withMutation(keyPath: \.controlNetDir) {
                _controlNetDir = newValue
            }
        }
    }

    var modelId: URL? {
        get {
            access(keyPath: \.modelId)
            return _modelId
        }
        set {
            withMutation(keyPath: \.modelId) {
                _modelId = newValue
            }
        }
    }

    var prompt: String {
        get {
            access(keyPath: \.prompt)
            return _prompt
        }
        set {
            withMutation(keyPath: \.prompt) {
                _prompt = newValue
            }
        }
    }

    var negativePrompt: String {
        get {
            access(keyPath: \.negativePrompt)
            return _negativePrompt
        }
        set {
            withMutation(keyPath: \.negativePrompt) {
                _negativePrompt = newValue
            }
        }
    }

    var strength: Double {
        get {
            access(keyPath: \.strength)
            return _strength
        }
        set {
            withMutation(keyPath: \.strength) {
                _strength = newValue
            }
        }
    }

    var steps: Double {
        get {
            access(keyPath: \.steps)
            return _steps
        }
        set {
            withMutation(keyPath: \.steps) {
                _steps = newValue
            }
        }
    }

    var guidanceScale: Double {
        get {
            access(keyPath: \.guidanceScale)
            return _guidanceScale
        }
        set {
            withMutation(keyPath: \.guidanceScale) {
                _guidanceScale = newValue
            }
        }
    }

    var width: Int {
        get {
            access(keyPath: \.width)
            return _width
        }
        set {
            withMutation(keyPath: \.width) {
                _width = newValue
            }
        }
    }

    var height: Int {
        get {
            access(keyPath: \.height)
            return _height
        }
        set {
            withMutation(keyPath: \.height) {
                _height = newValue
            }
        }
    }

    var scheduler: Scheduler {
        get {
            access(keyPath: \.scheduler)
            return _scheduler
        }
        set {
            withMutation(keyPath: \.scheduler) {
                _scheduler = newValue
            }
        }
    }

    var showGenerationPreview: Bool {
        get {
            access(keyPath: \.showGenerationPreview)
            return _showGenPreview
        }
        set {
            withMutation(keyPath: \.showGenerationPreview) {
                _showGenPreview = newValue
            }
        }
    }

    var mlComputeUnitPreference: ComputeUnitPreference {
        get {
            access(keyPath: \.mlComputeUnitPreference)
            return _mlComputeUnitPreference
        }
        set {
            withMutation(keyPath: \.mlComputeUnitPreference) {
                _mlComputeUnitPreference = newValue
            }
        }
    }

    var reduceMemory: Bool {
        get {
            access(keyPath: \.reduceMemory)
            return _reduceMemory
        }
        set {
            withMutation(keyPath: \.reduceMemory) {
                _reduceMemory = newValue
            }
        }
    }

    var safetyChecker: Bool {
        get {
            access(keyPath: \.safetyChecker)
            return _safetyChecker
        }
        set {
            withMutation(keyPath: \.safetyChecker) {
                _safetyChecker = newValue
            }
        }
    }

    var useTrash: Bool {
        get {
            access(keyPath: \.useTrash)
            return _useTrash
        }
        set {
            withMutation(keyPath: \.useTrash) {
                _useTrash = newValue
            }
        }
    }
}
