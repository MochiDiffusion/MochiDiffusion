//
//  ConfigStore.swift
//  Mochi Diffusion
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable final class ConfigStore {
    @ObservationIgnored @AppStorage("ImageDir") private var _imageDir = ""
    @ObservationIgnored @AppStorage("ImageType") private var _imageType =
        UTType.png.preferredFilenameExtension!
    @ObservationIgnored @AppStorage("ModelDir") private var _modelDir = ""
    @ObservationIgnored @AppStorage("ControlNetDir") private var _controlNetDir = ""
    @ObservationIgnored @AppStorage("Model") private var _modelId: URL?
    @ObservationIgnored @AppStorage("Prompt") private var _prompt = ""
    @ObservationIgnored @AppStorage("NegativePrompt") private var _negativePrompt = ""
    @ObservationIgnored @AppStorage("ImageStrength") private var _strength = 0.75
    @ObservationIgnored @AppStorage("Steps") private var _steps = 12.0
    @ObservationIgnored @AppStorage("Scale") private var _guidanceScale = 11.0
    @ObservationIgnored @AppStorage("ImageWidth") private var _width = 512
    @ObservationIgnored @AppStorage("ImageHeight") private var _height = 512
    @ObservationIgnored @AppStorage("Scheduler") private var _scheduler: Scheduler =
        .dpmSolverMultistepScheduler
    @ObservationIgnored @AppStorage("ShowGenerationPreview") private var _showGenPreview = true
    @ObservationIgnored @AppStorage("MLComputeUnitPreference") private var _mlComputeUnitPreference:
        ComputeUnitPreference = .auto
    @ObservationIgnored @AppStorage("ReduceMemory") private var _reduceMemory = false
    @ObservationIgnored @AppStorage("SafetyChecker") private var _safetyChecker = false
    @ObservationIgnored @AppStorage("UseTrash") private var _useTrash = true

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
