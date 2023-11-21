//
//  JobQueueView.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-18.
//

import SwiftUI

struct JobQueueView: View {
    @EnvironmentObject private var generator: ImageGenerator
    @EnvironmentObject private var controller: ImageController

    @State private var progressData: (Double, String) = (-1, "Loading...")

    var body: some View {
        ScrollView {
            VStack {
                if let currentGeneration = controller.currentGeneration {
                    JobView(config: currentGeneration, progress: progressData) {
                        Task { await generator.stopGenerate() }
                    }
                    .onChange(of: generator.state) { newState in
                        if case let .running(progress) = newState, let progress = progress, progress.stepCount > 0 {
                            let step = Double(progress.step + 1)
                            let totalStepProgress = Double(generator.queueProgress.index * progress.stepCount) + step
                            let totalStepCount = Double(generator.queueProgress.total * progress.stepCount)

                            let stepLabel = String(
                                localized: "About \(formatTimeRemaining(generator.lastStepGenerationElapsedTime, stepsLeft: Int(totalStepCount - totalStepProgress)))",
                                comment: "Text displaying the time remaining"
                            )
                            progressData = (totalStepProgress / totalStepCount, stepLabel)
                        } else if case .loading = newState {
                            progressData = (-1, "Loading...")
                        }
                    }
                }
                ForEach(controller.generationQueue) { generation in
                    Divider()
                    JobView(config: generation) {
                        controller.generationQueue.removeAll { $0.id == generation.id }
                    }
                }
            }
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
                    .lineLimit(1)
            }
        }
    }

    var controlButtons: some View {
        HStack {
            Button {
                stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            Button {
                isGetInfoPopoverShown = true
            } label: {
                Image(systemName: "info.circle.fill")
            }
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .popover(isPresented: self.$isGetInfoPopoverShown, arrowEdge: .bottom) {
                InfoPopoverView(config: config)
                    .frame(width: 240)
                    .padding()
            }
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

            if let controlNetName = config.controlNets.first, let controlNetImage = config.pipelineConfig.controlNetInputs.first {
                await controller.setControlNet(name: controlNetName)
                await controller.setControlNet(image: controlNetImage)
            } else {
                await controller.unsetControlNet()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading) {

            Text("Prompt")
                .sidebarLabelFormat()
            Text(config.pipelineConfig.prompt)

            if !config.pipelineConfig.negativePrompt.isEmpty {
                Text("Negative Prompt")
                    .sidebarLabelFormat()
                Text(config.pipelineConfig.negativePrompt)
            }

            if config.numberOfImages != 1 {
                Text("Number of Images")
                    .sidebarLabelFormat()
                Text("\(config.numberOfImages)")
                    .monospacedDigit()
            }

            Text("Steps")
                .sidebarLabelFormat()
            Text("\(config.pipelineConfig.stepCount)")
                .monospacedDigit()

            Text("Guidance Scale")
                .sidebarLabelFormat()
            Text(config.pipelineConfig.guidanceScale.formatted(.number.precision(.fractionLength(2))))
                .monospacedDigit()

            Text("Model")
                .sidebarLabelFormat()
            Text(config.model.name)

            if config.pipelineConfig.seed != 0 {
                Text("Seed")
                    .sidebarLabelFormat()
                Text("\(config.pipelineConfig.seed)")
                    .monospacedDigit()
            }

            if let startingImage = config.pipelineConfig.startingImage {
                Text("Starting Image")
                    .sidebarLabelFormat()
                Image(startingImage, scale: 4, label: Text("Starting Image"))
                Text("Strength")
                    .sidebarLabelFormat()
                Text(config.pipelineConfig.strength.formatted(.number.precision(.fractionLength(2))))
            }

            if let controlNetName = config.controlNets.first, let controlNetImage = config.pipelineConfig.controlNetInputs.first {
                Text("ControlNet")
                    .sidebarLabelFormat()
                Text(controlNetName)
                Image(controlNetImage, scale: 4, label: Text("Control Net Image"))
            }

            HStack {
                Spacer()
                Button("Copy Options to Sidebar") {
                    copyOptionsToSidebar()
                }
            }
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
            return lhsProgress?.step == rhsProgress?.step &&
            lhsProgress?.stepCount == rhsProgress?.stepCount
        default:
            return false
        }
    }
}
