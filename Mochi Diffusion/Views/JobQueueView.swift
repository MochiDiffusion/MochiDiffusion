//
//  JobQueueView.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-18.
//

import CoreML
import SwiftUI

struct JobQueueView: View {
    @Environment(ImageGenerator.self) private var generator: ImageGenerator
    @EnvironmentObject private var controller: ImageController

    @State private var progressData: (Double, String)?

    private func updateProgressData() {
        if case .running(let progress) = generator.state, let progress = progress,
            progress.stepCount > 0
        {
            let step = progress.step + 1
            let stepValue = Double(step) / Double(progress.stepCount)

            let progressLabel = String(
                localized:
                    "About \(formatTimeRemaining(generator.lastStepGenerationElapsedTime, stepsLeft: progress.stepCount - step))",
                comment: "Text displaying the current time remaining"
            )
            progressData = (stepValue, progressLabel)
        } else if case .loading = generator.state {
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
                    JobView(config: currentGeneration, progress: progressData) {
                        Task { await generator.stopGenerate() }
                    }
                    .onAppear {
                        updateProgressData()
                    }
                    .onChange(of: generator.state) {
                        updateProgressData()
                    }
                }
                ForEach(controller.generationQueue) { generation in
                    Divider()
                    JobView(config: generation) {
                        controller.generationQueue.removeAll { $0.id == generation.id }
                    }
                }
            }
            .padding()
        }
    }
}

private struct JobView: View {
    @State private var isGetInfoPopoverShown = false

    let config: GenerationConfig
    let progress: (Double, String)?
    let stop: () -> Void

    init(config: GenerationConfig, progress: (Double, String)? = nil, stop: @escaping () -> Void) {
        self.config = config
        self.progress = progress
        self.stop = stop
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(config.pipelineConfig.prompt)
                        .lineLimit(1)
                        .help(config.pipelineConfig.prompt)
                    Text(config.model.name)
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
                InfoPopoverView(config: config)
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
    @EnvironmentObject private var controller: ImageController
    let config: GenerationConfig

    func copyOptionsToSidebar() {
        Task {
            var image = SDImage()
            image.prompt = config.pipelineConfig.prompt
            image.negativePrompt = config.pipelineConfig.negativePrompt
            image.steps = config.pipelineConfig.stepCount
            image.guidanceScale = Double(config.pipelineConfig.guidanceScale)
            image.seed = config.pipelineConfig.seed
            image.scheduler = config.scheduler
            controller.copyToPrompt(image)

            controller.currentModel = config.model

            if let startingImage = config.pipelineConfig.startingImage {
                controller.startingImage = startingImage
                controller.strength = Double(config.pipelineConfig.strength)
            } else {
                await controller.unsetStartingImage()
            }

            if let controlNetName = config.controlNets.first,
                let controlNetImage = config.pipelineConfig.controlNetInputs.first
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
                    InfoGridRow(
                        type: LocalizedStringKey(Metadata.model.rawValue),
                        text: config.model.name,
                        showCopyToPromptOption: false
                    )
                    InfoGridRow(
                        type: LocalizedStringKey(Metadata.includeInImage.rawValue),
                        text: config.pipelineConfig.prompt,
                        showCopyToPromptOption: true,
                        callback: { controller.prompt = config.pipelineConfig.prompt }
                    )
                    InfoGridRow(
                        type: LocalizedStringKey(Metadata.excludeFromImage.rawValue),
                        text: config.pipelineConfig.negativePrompt,
                        showCopyToPromptOption: true,
                        callback: {
                            controller.negativePrompt = config.pipelineConfig.negativePrompt
                        }
                    )
                    if config.pipelineConfig.seed != 0 {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.seed.rawValue),
                            text: String(config.pipelineConfig.seed),
                            showCopyToPromptOption: true,
                            callback: { controller.seed = config.pipelineConfig.seed }
                        )
                    }
                    if config.numberOfImages != 1 {
                        InfoGridRow(
                            type: LocalizedStringKey("Number of Images"),
                            text: String(config.numberOfImages),
                            showCopyToPromptOption: true,
                            callback: { controller.numberOfImages = Double(config.numberOfImages) }
                        )
                    }
                    InfoGridRow(
                        type: LocalizedStringKey(Metadata.steps.rawValue),
                        text: String(config.pipelineConfig.stepCount),
                        showCopyToPromptOption: true,
                        callback: { controller.steps = Double(config.pipelineConfig.stepCount) }
                    )
                    InfoGridRow(
                        type: LocalizedStringKey(Metadata.guidanceScale.rawValue),
                        text: String(
                            config.pipelineConfig.guidanceScale.formatted(
                                .number.precision(.fractionLength(2)))),
                        showCopyToPromptOption: true,
                        callback: {
                            controller.guidanceScale = Double(config.pipelineConfig.guidanceScale)
                        }
                    )
                    InfoGridRow(
                        type: LocalizedStringKey(Metadata.scheduler.rawValue),
                        text: config.scheduler.rawValue,
                        showCopyToPromptOption: true,
                        callback: { controller.scheduler = config.scheduler }
                    )
                    InfoGridRow(
                        type: LocalizedStringKey(Metadata.mlComputeUnit.rawValue),
                        text: MLComputeUnits.toString(config.mlComputeUnit),
                        showCopyToPromptOption: false
                    )
                    if let startingImage = config.pipelineConfig.startingImage {
                        InfoGridRow(
                            type: LocalizedStringKey("Starting Image"),
                            image: startingImage,
                            showCopyToPromptOption: false
                        )
                        InfoGridRow(
                            type: LocalizedStringKey("Strength"),
                            text: config.pipelineConfig.strength.formatted(
                                .number.precision(.fractionLength(2))),
                            showCopyToPromptOption: true,
                            callback: {
                                controller.strength = Double(config.pipelineConfig.strength)
                            }
                        )
                    }
                    if let controlNetName = config.controlNets.first,
                        let controlNetImage = config.pipelineConfig.controlNetInputs.first
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

extension ImageGenerator.State: Equatable {
    static func == (lhs: ImageGenerator.State, rhs: ImageGenerator.State) -> Bool {
        switch (lhs, rhs) {
        case (.ready(let lhsValue), .ready(let rhsValue)):
            return lhsValue == rhsValue
        case (.error(let lhsValue), .error(let rhsValue)):
            return lhsValue == rhsValue
        case (.loading, .loading):
            return true
        case (.running(let lhsProgress), .running(let rhsProgress)):
            // This is NOT a comprehensive comparison
            // it is just enough to fulfill the .onChange requirements in JobQueueView
            return lhsProgress?.step == rhsProgress?.step
                && lhsProgress?.stepCount == rhsProgress?.stepCount
        default:
            return false
        }
    }
}
