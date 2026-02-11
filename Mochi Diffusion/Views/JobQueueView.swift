//
//  JobQueueView.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-18.
//

import CoreML
import SwiftUI

struct JobQueueView: View {
    @Environment(GenerationState.self) private var generationState: GenerationState
    @Environment(GenerationController.self) private var controller: GenerationController

    @State private var progressData: (Double, String)?

    private func updateProgressData() {
        if case .running(let progress) = generationState.state, let progress = progress,
            progress.stepCount > 0
        {
            let step = progress.step + 1
            let stepValue = Double(step) / Double(progress.stepCount)

            let progressLabel = String(
                localized:
                    "About \(formatTimeRemaining(generationState.lastStepGenerationElapsedTime, stepsLeft: progress.stepCount - step))",
                comment: "Text displaying the current time remaining"
            )
            progressData = (stepValue, progressLabel)
        } else if case .loading = generationState.state {
            let progressLabel = String(
                localized: "Loading the model for the first time may take a few minutes",
                comment: "Text displayed when the model is being loaded"
            )
            progressData = (-1, progressLabel)
        }
    }

    var body: some View {
        ScrollView {
            VStack {
                if let currentGeneration = controller.currentGeneration {
                    JobView(request: currentGeneration, progress: progressData) {
                        Task { await GenerationService.shared.stopCurrentGeneration() }
                    }
                    .onAppear {
                        updateProgressData()
                    }
                    .onChange(of: generationState.state) {
                        updateProgressData()
                    }
                }
                ForEach(controller.generationQueue) { generation in
                    Divider()
                    JobView(request: generation) {
                        Task { await controller.removeQueued(generation.id) }
                    }
                }
            }
            .padding()
        }
    }
}

private struct JobView: View {
    @State private var isGetInfoPopoverShown = false

    let request: GenerationRequest
    let progress: (Double, String)?
    let stop: () -> Void

    init(
        request: GenerationRequest,
        progress: (Double, String)? = nil,
        stop: @escaping () -> Void
    ) {
        self.request = request
        self.progress = progress
        self.stop = stop
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(request.prompt)
                        .lineLimit(1)
                        .help(request.prompt)
                    Text(request.pipeline.displayName)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Spacer()
                controlButtons
            }
            if let (percentDone, label) = progress {
                if percentDone == -1 {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: percentDone)
                }
                Text(label)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }

    var controlButtons: some View {
        HStack {
            Button {
                isGetInfoPopoverShown = true
            } label: {
                Image(systemName: "info.circle.fill")
            }
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .popover(isPresented: self.$isGetInfoPopoverShown, arrowEdge: .bottom) {
                InfoPopoverView(request: request)
                    .frame(width: 320)
            }

            Button {
                stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
    }
}

private struct InfoPopoverView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore
    let request: GenerationRequest

    private func decodeImage(from data: Data?) -> CGImage? {
        guard let data else { return nil }
        return CGImage.fromData(data)
    }

    private var capabilities: GenerationCapabilities {
        request.pipeline.generationCapabilities
    }

    private var metadataFields: Set<MetadataField> {
        request.pipeline.metadataFields
    }

    private var effectiveStepCount: Int? {
        request.pipeline.effectiveStepCount(
            requestedStepCount: request.stepCount
        )
    }

    private var effectiveScheduler: Scheduler? {
        request.pipeline.effectiveScheduler(
            requestedScheduler: request.scheduler
        )
    }

    private var supportsStrengthControl: Bool {
        capabilities.contains(.strength)
    }

    func copyOptionsToSidebar() {
        Task {
            if metadataFields.contains(.prompt) {
                configStore.prompt = request.prompt
            }
            if metadataFields.contains(.negativePrompt) {
                configStore.negativePrompt = request.negativePrompt
            }
            if metadataFields.contains(.size) {
                configStore.width = Int(request.size.width)
                configStore.height = Int(request.size.height)
            }
            if let stepCount = effectiveStepCount {
                configStore.steps = Double(stepCount)
            }
            if metadataFields.contains(.guidanceScale) {
                configStore.guidanceScale = Double(request.guidanceScale)
            }
            if metadataFields.contains(.seed) {
                controller.seed = request.seed
            }
            if let scheduler = effectiveScheduler {
                configStore.scheduler = scheduler
            }

            if let model = request.pipeline.coreMLModel {
                controller.currentModelId = model.id  // TODO: we should just store id?
            }

            if let startingImage = decodeImage(from: request.startingImageData) {
                controller.startingImage = startingImage
                if supportsStrengthControl {
                    configStore.strength = Double(request.strength)
                }
            } else {
                await controller.unsetStartingImage()
            }

            if let controlNetName = request.pipeline.controlNets.first,
                let controlNetImage = decodeImage(from: request.controlNetInputs.first)
            {
                await controller.setControlNet(name: controlNetName)
                await controller.setControlNet(image: controlNetImage)
            } else {
                await controller.unsetControlNet()
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Grid(alignment: .leading, horizontalSpacing: 4) {
                    if metadataFields.contains(.model) {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.model.rawValue),
                            text: request.pipeline.displayName,
                            showCopyToPromptOption: false
                        )
                    }
                    if metadataFields.contains(.prompt) {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.includeInImage.rawValue),
                            text: request.prompt,
                            showCopyToPromptOption: true,
                            callback: { configStore.prompt = request.prompt }
                        )
                    }
                    if metadataFields.contains(.negativePrompt) {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.excludeFromImage.rawValue),
                            text: request.negativePrompt,
                            showCopyToPromptOption: true,
                            callback: {
                                configStore.negativePrompt = request.negativePrompt
                            }
                        )
                    }
                    if metadataFields.contains(.size) {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.size.rawValue),
                            text: "\(Int(request.size.width)) x \(Int(request.size.height))",
                            showCopyToPromptOption: true,
                            callback: {
                                configStore.width = Int(request.size.width)
                                configStore.height = Int(request.size.height)
                            }
                        )
                    }
                    if metadataFields.contains(.seed), request.seed != 0 {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.seed.rawValue),
                            text: String(request.seed),
                            showCopyToPromptOption: true,
                            callback: { controller.seed = request.seed }
                        )
                    }
                    if request.numberOfImages != 1 {
                        InfoGridRow(
                            type: LocalizedStringKey("Number of Images"),
                            text: String(request.numberOfImages),
                            showCopyToPromptOption: true,
                            callback: {
                                controller.numberOfImages = Double(request.numberOfImages)
                            }
                        )
                    }
                    if let stepCount = effectiveStepCount {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.steps.rawValue),
                            text: String(stepCount),
                            showCopyToPromptOption: true,
                            callback: { configStore.steps = Double(stepCount) }
                        )
                    }
                    if metadataFields.contains(.guidanceScale) {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.guidanceScale.rawValue),
                            text: String(
                                request.guidanceScale.formatted(
                                    .number.precision(.fractionLength(2)))),
                            showCopyToPromptOption: true,
                            callback: {
                                configStore.guidanceScale = Double(request.guidanceScale)
                            }
                        )
                    }
                    if let scheduler = effectiveScheduler {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.scheduler.rawValue),
                            text: scheduler.rawValue,
                            showCopyToPromptOption: true,
                            callback: { configStore.scheduler = scheduler }
                        )
                    }
                    if metadataFields.contains(.mlComputeUnit),
                        let computeUnit = request.pipeline.mlComputeUnit
                    {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.mlComputeUnit.rawValue),
                            text: MLComputeUnits.toString(computeUnit),
                            showCopyToPromptOption: false
                        )
                    }
                    if let startingImage = decodeImage(from: request.startingImageData) {
                        InfoGridRow(
                            type: LocalizedStringKey("Starting Image"),
                            image: startingImage,
                            showCopyToPromptOption: false
                        )
                        if supportsStrengthControl {
                            InfoGridRow(
                                type: LocalizedStringKey("Strength"),
                                text: request.strength.formatted(
                                    .number.precision(.fractionLength(2))),
                                showCopyToPromptOption: true,
                                callback: {
                                    configStore.strength = Double(request.strength)
                                }
                            )
                        }
                    }
                    if let controlNetName = request.pipeline.controlNets.first,
                        let controlNetImage = decodeImage(from: request.controlNetInputs.first)
                    {
                        InfoGridRow(
                            type: LocalizedStringKey("ControlNet"),
                            text: controlNetName,
                            showCopyToPromptOption: false
                        )
                        InfoGridRow(
                            type: LocalizedStringKey("ControlNet Image"),
                            image: controlNetImage,
                            showCopyToPromptOption: false
                        )
                    }
                }

                HStack {
                    Spacer()
                    Button("Copy Options to Sidebar") {
                        copyOptionsToSidebar()
                    }
                }
            }
            .padding()
        }
    }
}
