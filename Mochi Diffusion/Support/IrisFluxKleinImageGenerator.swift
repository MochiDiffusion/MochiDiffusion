//
//  IrisFluxKleinImageGenerator.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

nonisolated final class IrisFluxKleinImageGenerator: ImageGenerator {
    private let generationStopLock = NSLock()
    private var generationStopped = false
    private static let embeddingCache = FluxPromptEmbeddingCache(maxEntries: 16)

    @concurrent func generate(
        request: GenerationRequest,
        onState: @escaping @Sendable (GenerationState.Status) async -> Void,
        onProgress: @escaping @Sendable (GenerationState.Progress, Double?) async -> Void,
        onPreview: @escaping @Sendable (CGImage?) async -> Void,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        guard case .iris(let modelDir, let family) = request.pipeline, family == .fluxKlein else {
            await onState(.error("Pipeline is not loaded."))
            throw IrisFluxKleinImageGeneratorError.invalidPipeline
        }

        await onState(.loading("Loading model..."))
        setGenerationStopped(false)
        iris_clear_cancel()
        // Match the CLI startup order so transformer load sees Metal availability.
        _ = iris_metal_init()
        await FluxStepImageBridge.shared.configure(
            onState: onState,
            onProgress: onProgress,
            onPreview: onPreview,
            usePreview: request.useDenoisedIntermediates
        )
        defer {
            iris_clear_cancel()
            Task {
                await FluxStepImageBridge.shared.reset()
                await onPreview(nil)
            }
        }
        guard let ctx = iris_load_dir(modelDir) else {
            throw IrisFluxKleinImageGeneratorError.loadFailed(fluxErrorMessage())
        }

        iris_set_mmap(ctx, 1)
        iris_set_phase_callback(fluxPhaseCallback)
        iris_set_step_callback(fluxStepCallback)
        if request.useDenoisedIntermediates {
            iris_set_step_image_callback(ctx, fluxStepImageCallback)
        } else {
            iris_set_step_image_callback(ctx, nil)
        }
        let isDistilled = iris_is_distilled(ctx) != 0

        var embeddingLength: Int32 = 0
        var embeddings: [Float]?

        let inputFluxImages = request.inputImageDatas.compactMap(Self.makeFluxImage(from:))
        if inputFluxImages.count != request.inputImageDatas.count {
            for inputFluxImage in inputFluxImages {
                iris_image_free(inputFluxImage)
            }
            throw IrisFluxKleinImageGeneratorError.decodeInputImageFailed
        }

        if isDistilled {
            let shouldUseEmbeddingCache = inputFluxImages.count <= 1
            if shouldUseEmbeddingCache,
                let cached = await Self.embeddingCache.lookup(
                    modelDir: modelDir,
                    prompt: request.prompt
                )
            {
                embeddingLength = cached.seqLen
                embeddings = cached.values
            } else {
                guard let encoded = iris_encode_text(ctx, request.prompt, &embeddingLength) else {
                    throw IrisFluxKleinImageGeneratorError.generateFailed(fluxErrorMessage())
                }
                let textDim = Int(iris_text_dim(ctx))
                guard textDim > 0 else {
                    free(encoded)
                    throw IrisFluxKleinImageGeneratorError.generateFailed(
                        "Invalid text embedding dimension."
                    )
                }
                let elementCount = Int(embeddingLength) * textDim
                let rawEmbeddings = Array(UnsafeBufferPointer(start: encoded, count: elementCount))
                free(encoded)

                if shouldUseEmbeddingCache {
                    await Self.embeddingCache.store(
                        modelDir: modelDir,
                        prompt: request.prompt,
                        seqLen: embeddingLength,
                        values: rawEmbeddings
                    )

                    if let canonical = await Self.embeddingCache.lookup(
                        modelDir: modelDir,
                        prompt: request.prompt
                    ) {
                        embeddingLength = canonical.seqLen
                        embeddings = canonical.values
                    } else {
                        // Fallback preserves forward progress if cache write/read fails.
                        embeddings = rawEmbeddings
                    }
                } else {
                    embeddings = rawEmbeddings
                }
            }
            // Keep peak memory lower before transformer work, even on cache hits.
            iris_release_text_encoder(ctx)
        }

        defer {
            iris_set_step_image_callback(ctx, nil)
            iris_set_step_callback(nil)
            iris_set_phase_callback(nil)
            iris_free(ctx)
            for inputFluxImage in inputFluxImages {
                iris_image_free(inputFluxImage)
            }
        }

        var seed = request.seed

        for _ in 0..<request.numberOfImages {
            if isGenerationStopped() {
                break
            }

            var params = iris_params.defaultParams
            params.width = Int32(request.size.width)
            params.height = Int32(request.size.height)
            params.num_steps = 4
            params.seed = Int64(seed)

            let image: UnsafeMutablePointer<iris_image>?
            if !inputFluxImages.isEmpty {
                image = Self.generateMultiRef(
                    ctx: ctx,
                    prompt: request.prompt,
                    inputFluxImages: inputFluxImages,
                    params: &params
                )
            } else {
                if isDistilled, let embeddings {
                    image = Self.generateWithEmbeddings(
                        ctx: ctx,
                        embeddings: embeddings,
                        embeddingLength: embeddingLength,
                        params: &params
                    )
                } else {
                    image = iris_generate(ctx, request.prompt, &params)
                }
            }

            guard let image else {
                if isGenerationStopped() {
                    break
                }
                throw IrisFluxKleinImageGeneratorError.generateFailed(fluxErrorMessage())
            }
            defer { iris_image_free(image) }

            let metadata = GenerationMetadata(
                prompt: request.prompt,
                negativePrompt: request.negativePrompt,
                width: Int(image.pointee.width),
                height: Int(image.pointee.height),
                pipeline: request.pipeline,
                model: request.pipeline.displayName,
                quality: "",
                startingImage: "",
                controlNetImage: "",
                inputImages: request.inputImageNames,
                scheduler: .discreteFlowScheduler,
                seed: seed,
                steps: 4,
                guidanceScale: isDistilled ? 1.0 : 4.0,
                generatedDate: Date.now,
                metadataFields: request.pipeline.metadataFields
            )

            guard let cgImage = Self.makeCGImage(from: UnsafePointer(image)) else {
                throw IrisFluxKleinImageGeneratorError.encodeFailed
            }

            guard
                let imageData = await makeImageData(
                    from: cgImage,
                    metadata: metadata,
                    imageType: request.imageType
                )
            else {
                throw IrisFluxKleinImageGeneratorError.encodeFailed
            }

            let result = GenerationResult(metadata: metadata, imageData: imageData)
            try await onResult(result)
            seed &+= 1
        }

        await onState(.ready(nil))
    }

    private static func generateWithEmbeddings(
        ctx: OpaquePointer,
        embeddings: [Float],
        embeddingLength: Int32,
        params: inout iris_params
    ) -> UnsafeMutablePointer<iris_image>? {
        embeddings.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { return nil }
            return iris_generate_with_embeddings(ctx, pointer, embeddingLength, &params)
        }
    }

    private static func generateMultiRefWithEmbeddings(
        ctx: OpaquePointer,
        embeddings: [Float],
        embeddingLength: Int32,
        inputFluxImages: [UnsafeMutablePointer<iris_image>],
        params: inout iris_params
    ) -> UnsafeMutablePointer<iris_image>? {
        let refs = UnsafeMutablePointer<UnsafePointer<iris_image>?>.allocate(
            capacity: inputFluxImages.count
        )
        defer { refs.deallocate() }
        for (index, inputFluxImage) in inputFluxImages.enumerated() {
            refs[index] = UnsafePointer(inputFluxImage)
        }

        return embeddings.withUnsafeBufferPointer { buffer -> UnsafeMutablePointer<iris_image>? in
            guard let pointer = buffer.baseAddress else { return nil }
            return iris_multiref_with_embeddings(
                ctx,
                pointer,
                embeddingLength,
                refs,
                Int32(inputFluxImages.count),
                &params
            )
        }
    }

    private static func generateMultiRef(
        ctx: OpaquePointer,
        prompt: String,
        inputFluxImages: [UnsafeMutablePointer<iris_image>],
        params: inout iris_params
    ) -> UnsafeMutablePointer<iris_image>? {
        let refs = UnsafeMutablePointer<UnsafePointer<iris_image>?>.allocate(
            capacity: inputFluxImages.count
        )
        defer { refs.deallocate() }
        for (index, inputFluxImage) in inputFluxImages.enumerated() {
            refs[index] = UnsafePointer(inputFluxImage)
        }

        return iris_multiref(ctx, prompt, refs, Int32(inputFluxImages.count), &params)
    }

    func stopGenerate() async {
        setGenerationStopped(true)
        iris_request_cancel()
    }

    private func setGenerationStopped(_ value: Bool) {
        generationStopLock.lock()
        generationStopped = value
        generationStopLock.unlock()
    }

    private func isGenerationStopped() -> Bool {
        generationStopLock.lock()
        let value = generationStopped
        generationStopLock.unlock()
        return value
    }

    private func makeImageData(
        from cgImage: CGImage,
        metadata: GenerationMetadata,
        imageType: String
    ) async -> Data? {
        var sdi = SDImage()
        sdi.image = cgImage
        sdi.prompt = metadata.prompt
        sdi.negativePrompt = metadata.negativePrompt
        sdi.model = metadata.model
        sdi.quality = metadata.quality
        sdi.startingImage = metadata.startingImage
        sdi.controlNetImage = metadata.controlNetImage
        sdi.inputImages = metadata.inputImages
        sdi.scheduler = metadata.scheduler
        sdi.seed = metadata.seed
        sdi.steps = metadata.steps
        sdi.guidanceScale = metadata.guidanceScale
        sdi.generatedDate = metadata.generatedDate
        sdi.aspectRatio = CGFloat(Double(cgImage.width) / Double(cgImage.height))

        let type = UTType.fromString(imageType)
        return await sdi.imageData(type, metadataFields: metadata.metadataFields)
    }

    fileprivate static func makeCGImage(from image: UnsafePointer<iris_image>) -> CGImage? {
        let width = Int(image.pointee.width)
        let height = Int(image.pointee.height)
        let channels = Int(image.pointee.channels)

        guard width > 0, height > 0, channels == 3 || channels == 4 else {
            return nil
        }
        guard let dataPtr = image.pointee.data else {
            return nil
        }

        let bytesPerRow = width * channels
        let count = bytesPerRow * height
        let data = Data(bytes: dataPtr, count: count)
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alphaInfo: CGImageAlphaInfo = channels == 4 ? .last : .none
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * channels,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    fileprivate static func makeFluxImage(from data: Data) -> UnsafeMutablePointer<iris_image>? {
        guard let cgImage = CGImage.fromData(data) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let channels = 4
        let bytesPerRow = width * channels
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )

        let drewImage = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else {
                return false
            }
            guard
                let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                )
            else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drewImage else {
            return nil
        }

        guard let fluxImage = iris_image_create(Int32(width), Int32(height), Int32(channels)) else {
            return nil
        }
        guard let dataPtr = fluxImage.pointee.data else {
            iris_image_free(fluxImage)
            return nil
        }

        rgba.withUnsafeBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                memcpy(dataPtr, baseAddress, buffer.count)
            }
        }

        return fluxImage
    }
}

// Safety invariant: GenerationService serializes generation calls, and cancellation state
// mutation is synchronized with generationStopLock while migration away from class-based
// generators is in progress.
extension IrisFluxKleinImageGenerator: @unchecked Sendable {}

private enum IrisFluxKleinImageGeneratorError: Error, CustomStringConvertible {
    case invalidPipeline
    case loadFailed(String)
    case generateFailed(String)
    case encodeFailed
    case decodeInputImageFailed

    var description: String {
        switch self {
        case .invalidPipeline:
            return "IrisFluxKleinImageGenerator called with non-Iris FLUX.2 pipeline."
        case .loadFailed(let message):
            return "Failed to load model: \(message)"
        case .generateFailed(let message):
            return "Failed to generate image: \(message)"
        case .encodeFailed:
            return "Failed to encode generated image."
        case .decodeInputImageFailed:
            return "Failed to decode input image for image-conditioned generation."
        }
    }
}

nonisolated private func fluxErrorMessage() -> String {
    guard let cString = iris_get_error() else {
        return "Unknown error."
    }
    return String(cString: cString)
}

private actor FluxPromptEmbeddingCache {
    struct Entry {
        let seqLen: Int32
        let values: [Float]
    }

    private struct Key: Hashable {
        let modelDir: String
        let prompt: String
    }

    private let maxEntries: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var lru: [Key] = []

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func lookup(modelDir: String, prompt: String) -> Entry? {
        let key = Key(modelDir: modelDir, prompt: prompt)
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else {
            return nil
        }
        touch(key)
        return entry
    }

    func store(modelDir: String, prompt: String, seqLen: Int32, values: [Float]) {
        let key = Key(modelDir: modelDir, prompt: prompt)
        lock.lock()
        defer { lock.unlock() }

        entries[key] = Entry(seqLen: seqLen, values: values)
        touch(key)
        trimIfNeeded()
    }

    private func touch(_ key: Key) {
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
        }
        lru.append(key)
    }

    private func trimIfNeeded() {
        while lru.count > maxEntries {
            let key = lru.removeFirst()
            entries.removeValue(forKey: key)
        }
    }
}

extension iris_params {
    nonisolated fileprivate static var defaultParams: iris_params {
        iris_params(
            width: 256, height: 256, num_steps: 4, seed: -1,
            guidance: 0.0, schedule: Int32(IRIS_SCHEDULE_DEFAULT), power_alpha: 2.0
        )
    }
}

private actor FluxStepImageBridge {
    static let shared = FluxStepImageBridge()

    private var onState: (@Sendable (GenerationState.Status) async -> Void)?
    private var onProgress: (@Sendable (GenerationState.Progress, Double?) async -> Void)?
    private var onPreview: (@Sendable (CGImage?) async -> Void)?
    private var usePreview = false

    func configure(
        onState: @escaping @Sendable (GenerationState.Status) async -> Void,
        onProgress: @escaping @Sendable (GenerationState.Progress, Double?) async -> Void,
        onPreview: @escaping @Sendable (CGImage?) async -> Void,
        usePreview: Bool
    ) {
        self.onState = onState
        self.onProgress = onProgress
        self.onPreview = onPreview
        self.usePreview = usePreview
    }

    func reset() {
        onState = nil
        onProgress = nil
        onPreview = nil
        usePreview = false
    }

    func handleStep(step: Int32, total: Int32) async {
        guard
            let onProgress,
            total > 0
        else {
            return
        }

        let totalSteps = Int(total)
        let zeroBasedStep = max(0, min(Int(step) - 1, totalSteps - 1))
        await onProgress(
            GenerationState.Progress(step: zeroBasedStep, stepCount: totalSteps),
            nil
        )
    }

    func handlePhase(_ phaseName: String?, done: Int32) async {
        guard done == 0, let onState else { return }
        guard let label = phaseLabel(for: phaseName) else { return }
        await onState(.loading(label))
    }

    func handlePreview(_ image: CGImage?) async {
        guard
            usePreview,
            let onPreview
        else {
            return
        }
        await onPreview(image)
    }

    private func phaseLabel(for phaseName: String?) -> String? {
        guard let phaseName else { return nil }
        let normalized = phaseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "loading qwen3 encoder":
            return "Loading text encoder..."
        case "loading flux.2 transformer", "loading z-image transformer":
            return "Loading transformer..."
        case "encoding text":
            return "Encoding prompt..."
        case "encoding reference image":
            return "Encoding input image..."
        case "decoding image":
            return "Decoding image..."
        default:
            return phaseName
        }
    }
}

nonisolated private let fluxStepCallback: @convention(c) (Int32, Int32) -> Void = { step, total in
    Task {
        await FluxStepImageBridge.shared.handleStep(step: step, total: total)
    }
}

nonisolated private let fluxPhaseCallback: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = {
    phase, done in
    let phaseName = phase.map { String(cString: $0) }
    Task {
        await FluxStepImageBridge.shared.handlePhase(phaseName, done: done)
    }
}

nonisolated private let fluxStepImageCallback:
    @convention(c) (
        Int32,
        Int32,
        UnsafePointer<iris_image>?
    ) -> Void = { _, _, image in
        let previewImage = image.flatMap {
            IrisFluxKleinImageGenerator.makeCGImage(from: $0)
        }
        Task {
            await FluxStepImageBridge.shared.handlePreview(previewImage)
        }
    }
