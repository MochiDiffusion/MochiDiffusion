//
//  GenerationService.swift
//  Mochi Diffusion
//

import CoreGraphics
import CoreML
import Foundation
import os

protocol ImageGenerator: Sendable {
    func generate(
        request: GenerationRequest,
        onState: @escaping @Sendable (GenerationState.Status) async -> Void,
        onProgress: @escaping @Sendable (GenerationState.Progress, Double?) async -> Void,
        onPreview: @escaping @Sendable (CGImage?) async -> Void,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws

    func stopGenerate() async
}

actor GenerationService {
    struct Snapshot: Sendable {
        var queue: [GenerationRequest]
        var current: GenerationRequest?
    }

    static let shared = GenerationService()

    private var logger = Logger()
    private var queue: [GenerationRequest] = []
    private var current: GenerationRequest?
    private var cancelingCurrentID: GenerationRequest.ID?
    private var currentGenerator: ImageGenerator?
    private var processingTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var resultContinuations: [UUID: AsyncStream<GenerationResult>.Continuation] = [:]
    private let sdGenerator = SDImageGenerator()
    private let irisFluxKleinGenerator = IrisFluxKleinImageGenerator()
    private var nextImageIndex = 1
    private let imageRepository: ImageRepository
    private let modelRepository: ModelRepository

    init(
        imageRepository: ImageRepository = ImageRepository(),
        modelRepository: ModelRepository = ModelRepository()
    ) {
        self.imageRepository = imageRepository
        self.modelRepository = modelRepository
    }

    func updates() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    func results() -> AsyncStream<GenerationResult> {
        AsyncStream { continuation in
            let id = UUID()
            resultContinuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeResultContinuation(id) }
            }
        }
    }

    func enqueue(_ request: GenerationRequest) {
        queue.append(request)
        broadcastSnapshot()
        startProcessingIfNeeded()
    }

    func removeQueued(id: GenerationRequest.ID) {
        guard current?.id != id else { return }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
            broadcastSnapshot()
        }
    }

    func stopCurrentGeneration() async {
        guard let current else { return }
        guard cancelingCurrentID != current.id else { return }

        cancelingCurrentID = current.id
        broadcastSnapshot()
        await updateGenerationState(.canceling(nil))
        await currentGenerator?.stopGenerate()
    }

    func updateStatus(_ status: GenerationState.Status) async {
        await updateGenerationState(status)
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task { await processQueue() }
    }

    private func processQueue() async {
        defer { processingTask = nil }
        let currentState = await MainActor.run { GenerationState.shared.state }
        guard case .ready = currentState else { return }

        while !queue.isEmpty {
            let request = queue.removeFirst()
            current = request
            currentGenerator = nil
            broadcastSnapshot()

            let generator: ImageGenerator
            switch request.pipeline {
            case .sd(let model, _, _, _):
                if !(await modelRepository.modelExists(model)) {
                    logger.error("Couldn't load \(model.name) because it doesn't exist.")
                    await updateStatus(
                        .ready("Couldn't load \(model.name) because it doesn't exist.")
                    )
                    await finishCurrentRequest(request.id, restoreReadyAfterCancel: false)
                    continue
                }
                generator = sdGenerator
            case .iris(_, let family):
                switch family {
                case .fluxKlein:
                    generator = irisFluxKleinGenerator
                case .zImageTurbo:
                    await updateStatus(
                        .ready("Iris Z-Image-Turbo generation is not supported yet.")
                    )
                    await finishCurrentRequest(request.id, restoreReadyAfterCancel: false)
                    continue
                }
            }

            currentGenerator = generator
            var restoreReadyAfterCancel = false
            do {
                let outputDirectory = try await imageRepository.ensureOutputDirectory(
                    imageDir: request.imageDir
                )
                nextImageIndex = await MainActor.run { ImageGallery.shared.images.endIndex + 1 }

                if isCancelRequested(for: request.id) {
                    restoreReadyAfterCancel = true
                    await finishCurrentRequest(
                        request.id,
                        restoreReadyAfterCancel: restoreReadyAfterCancel
                    )
                    continue
                }

                try await generator.generate(
                    request: request,
                    onState: { [weak self] status in
                        await self?.handleGeneratorStateUpdate(status, for: request.id)
                    },
                    onProgress: { [weak self] progress, _ in
                        await self?.handleGeneratorProgressUpdate(progress, for: request.id)
                    },
                    onPreview: { [weak self] image in
                        await self?.handleGeneratorPreviewUpdate(image, for: request.id)
                    },
                    onResult: { [weak self] result in
                        guard let self else { return }
                        let filenameWithoutExtension = await self.nextFilename(
                            for: result.metadata
                        )
                        guard
                            let path = await imageRepository.writeImage(
                                filenameWithoutExtension: filenameWithoutExtension,
                                imageData: result.imageData,
                                imageDir: outputDirectory.path(percentEncoded: false),
                                imageType: request.imageType
                            )
                        else {
                            throw SDImageGenerator.GeneratorError.imageDirectoryNoAccess
                        }
                        let savedResult = GenerationResult(
                            id: result.id,
                            metadata: result.metadata,
                            imageData: result.imageData,
                            imageURL: path
                        )
                        await self.emitResult(savedResult)
                    }
                )
                restoreReadyAfterCancel = true
            } catch SDImageGenerator.GeneratorError.requestedModelNotFound {
                if case .sd(let model, _, _, _) = request.pipeline {
                    logger.error("Couldn't load \(model.name) because it doesn't exist.")
                    await updateStatus(
                        .ready("Couldn't load \(model.name) because it doesn't exist."))
                }
            } catch ImageRepositoryError.imageDirectoryNoAccess(let path) {
                logger.error("Couldn't access images folder at \(path)")
                await updateStatus(
                    .error("Couldn't access images folder at: \(path)")
                )
            } catch SDImageGenerator.GeneratorError.imageDirectoryNoAccess {
                logger.error("Couldn't save image to images folder.")
                await updateStatus(
                    .error("Couldn't save image to the images folder.")
                )
            } catch SDImageGenerator.GeneratorError.pipelineNotAvailable {
                logger.error("Pipeline is not available.")
                await updateStatus(
                    .ready("There was a problem loading pipeline."))
            } catch {
                logger.error("There was a problem generating images: \(error)")
                await updateStatus(
                    .error("There was a problem generating images: \(error)"))
            }

            await finishCurrentRequest(
                request.id,
                restoreReadyAfterCancel: restoreReadyAfterCancel
            )
        }

        current = nil
        cancelingCurrentID = nil
        currentGenerator = nil
        broadcastSnapshot()
        Task {
            await NotificationController.shared.sendQueueEmptyNotification()
        }
    }

    private func updateGenerationState(_ status: GenerationState.Status) async {
        await MainActor.run {
            GenerationState.shared.state = status
        }
    }

    private func handleGeneratorStateUpdate(
        _ status: GenerationState.Status,
        for requestID: GenerationRequest.ID
    ) async {
        guard current?.id == requestID else { return }
        guard !isCancelRequested(for: requestID) else { return }
        await updateGenerationState(status)
    }

    private func updateGenerationProgress(
        _ progress: GenerationState.Progress
    ) async {
        await MainActor.run {
            GenerationState.shared.state = .running(progress)
        }
    }

    private func handleGeneratorProgressUpdate(
        _ progress: GenerationState.Progress,
        for requestID: GenerationRequest.ID
    ) async {
        guard current?.id == requestID else { return }
        guard !isCancelRequested(for: requestID) else { return }
        await updateGenerationProgress(progress)
    }

    private func handleGeneratorPreviewUpdate(
        _ image: CGImage?,
        for requestID: GenerationRequest.ID
    ) async {
        if image == nil {
            guard current?.id == requestID || current == nil else { return }
            await MainActor.run {
                ImageGallery.shared.setCurrentGenerating(image: nil)
            }
            return
        }

        guard current?.id == requestID else { return }
        if isCancelRequested(for: requestID), image != nil {
            return
        }

        await MainActor.run {
            ImageGallery.shared.setCurrentGenerating(image: image)
        }
    }

    private func nextFilename(for metadata: GenerationMetadata) async -> String {
        let count = nextImageIndex
        nextImageIndex += 1
        return filenameWithoutExtension(prompt: metadata.prompt, seed: metadata.seed, count: count)
    }

    private func filenameWithoutExtension(prompt: String, seed: UInt32, count: Int) -> String {
        guard !prompt.isEmpty else {
            return "\(count).\(seed)"
        }
        let trimmed = String(prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed).\(count).\(seed)"
    }

    private func snapshot() -> Snapshot {
        let visibleCurrent: GenerationRequest?
        if let current, isCancelRequested(for: current.id) {
            visibleCurrent = nil
        } else {
            visibleCurrent = current
        }
        return Snapshot(queue: queue, current: visibleCurrent)
    }

    private func broadcastSnapshot() {
        let snapshot = snapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emitResult(_ result: GenerationResult) {
        for continuation in resultContinuations.values {
            continuation.yield(result)
        }
    }

    private func isCancelRequested(for requestID: GenerationRequest.ID) -> Bool {
        cancelingCurrentID == requestID
    }

    private func finishCurrentRequest(
        _ requestID: GenerationRequest.ID,
        restoreReadyAfterCancel: Bool
    ) async {
        if isCancelRequested(for: requestID) {
            cancelingCurrentID = nil
            if restoreReadyAfterCancel && queue.isEmpty {
                await updateGenerationState(.ready(nil))
            }
        }

        if current?.id == requestID {
            currentGenerator = nil
        }
    }

    private func removeResultContinuation(_ id: UUID) {
        resultContinuations[id] = nil
    }

}
