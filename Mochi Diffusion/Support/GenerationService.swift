//
//  GenerationService.swift
//  Mochi Diffusion
//

import CoreGraphics
import CoreML
import Foundation
import os

protocol ImageGenerator {
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
    private var currentGenerator: ImageGenerator?
    private var processingTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var resultContinuations: [UUID: AsyncStream<GenerationResult>.Continuation] = [:]
    private let sdGenerator = SDImageGenerator()
    private let fluxGenerator = Flux2cImageGenerator()
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
            broadcastSnapshot()

            let generator: ImageGenerator
            switch request.pipeline {
            case .sd(let model, _, _, _):
                if !(await modelRepository.modelExists(model)) {
                    logger.error("Couldn't load \(model.name) because it doesn't exist.")
                    await updateStatus(
                        .ready("Couldn't load \(model.name) because it doesn't exist.")
                    )
                    continue
                }
                generator = sdGenerator
            case .flux2c:
                generator = fluxGenerator
            }

            currentGenerator = generator
            do {
                let outputDirectory = try await imageRepository.ensureOutputDirectory(
                    imageDir: request.imageDir
                )
                nextImageIndex = await MainActor.run { ImageGallery.shared.images.endIndex + 1 }

                try await generator.generate(
                    request: request,
                    onState: { [weak self] status in
                        await self?.updateGenerationState(status)
                    },
                    onProgress: { [weak self] progress, elapsed in
                        await self?.updateGenerationProgress(progress, elapsedTime: elapsed)
                    },
                    onPreview: { image in
                        await MainActor.run {
                            ImageGallery.shared.setCurrentGenerating(image: image)
                        }
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
            } catch SDImageGenerator.GeneratorError.startingImageProvidedWithoutEncoder {
                logger.error("The selected model does not support setting a starting image.")
                await updateStatus(
                    .ready(
                        "The selected model does not support setting a starting image."))
            } catch {
                logger.error("There was a problem generating images: \(error)")
                await updateStatus(
                    .error("There was a problem generating images: \(error)"))
            }
        }

        current = nil
        currentGenerator = nil
        broadcastSnapshot()
        Task {
            await NotificationController.shared.sendQueueEmptyNotification()
        }
    }

    private func updateGenerationState(_ status: GenerationState.Status) async {
        await MainActor.run {
            GenerationState.shared.state = status
            if case .running = status {
                return
            }
            GenerationState.shared.lastStepGenerationElapsedTime = nil
        }
    }

    private func updateGenerationProgress(
        _ progress: GenerationState.Progress,
        elapsedTime: Double?
    ) async {
        await MainActor.run {
            GenerationState.shared.state = .running(progress)
            GenerationState.shared.lastStepGenerationElapsedTime = elapsedTime
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
        Snapshot(queue: queue, current: current)
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

    private func removeResultContinuation(_ id: UUID) {
        resultContinuations[id] = nil
    }

}
