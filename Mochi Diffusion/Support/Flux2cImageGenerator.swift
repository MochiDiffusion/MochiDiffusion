//
//  Flux2cImageGenerator.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

final class Flux2cImageGenerator: ImageGenerator {
    private var generationStopped = false
    private static let embeddingCache = FluxPromptEmbeddingCache(maxEntries: 16)

    func generate(
        request: GenerationRequest,
        onState: @escaping @Sendable (GenerationState.Status) async -> Void,
        onProgress: @escaping @Sendable (GenerationState.Progress, Double?) async -> Void,
        onPreview: @escaping @Sendable (CGImage?) async -> Void,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        guard case .flux2c(let modelDir) = request.pipeline else {
            await onState(.error("Pipeline is not loaded."))
            throw Flux2cImageGeneratorError.invalidPipeline
        }

        await onState(.loading)
        generationStopped = false
        FluxStepImageBridge.configure(
            onProgress: onProgress,
            onPreview: onPreview,
            usePreview: request.useDenoisedIntermediates
        )
        defer {
            FluxStepImageBridge.reset()
            Task {
                await onPreview(nil)
            }
        }
        guard let ctx = flux_load_dir(modelDir) else {
            throw Flux2cImageGeneratorError.loadFailed(fluxErrorMessage())
        }

        flux_set_mmap(ctx, 1)
        let isDistilled = flux_is_distilled(ctx) != 0

        var embeddingLength: Int32 = 0
        var embeddings: [Float]?

        var startingFluxImage: UnsafeMutablePointer<flux_image>?
        if let startingImageData = request.startingImageData {
            startingFluxImage = Self.makeFluxImage(from: startingImageData)
            if startingFluxImage == nil {
                throw Flux2cImageGeneratorError.decodeStartingImageFailed
            }
        }

        if isDistilled {
            if let cached = Self.embeddingCache.lookup(
                modelDir: modelDir,
                prompt: request.prompt
            ) {
                embeddingLength = cached.seqLen
                embeddings = cached.values
            } else {
                guard let encoded = flux_encode_text(ctx, request.prompt, &embeddingLength) else {
                    throw Flux2cImageGeneratorError.generateFailed(fluxErrorMessage())
                }
                let textDim = Int(flux_text_dim(ctx))
                guard textDim > 0 else {
                    free(encoded)
                    throw Flux2cImageGeneratorError.generateFailed(
                        "Invalid text embedding dimension."
                    )
                }
                let elementCount = Int(embeddingLength) * textDim
                let rawEmbeddings = Array(UnsafeBufferPointer(start: encoded, count: elementCount))
                free(encoded)

                Self.embeddingCache.store(
                    modelDir: modelDir,
                    prompt: request.prompt,
                    seqLen: embeddingLength,
                    values: rawEmbeddings
                )

                if let canonical = Self.embeddingCache.lookup(
                    modelDir: modelDir,
                    prompt: request.prompt
                ) {
                    embeddingLength = canonical.seqLen
                    embeddings = canonical.values
                } else {
                    // Fallback preserves forward progress if cache write/read fails.
                    embeddings = rawEmbeddings
                }
            }
            // Keep peak memory lower before transformer work, even on cache hits.
            flux_release_text_encoder(ctx)
        }

        //flux_set_step_image_callback(ctx, fluxStepImageCallback)
        defer {
            //flux_set_step_image_callback(ctx, nil)
            flux_free(ctx)
            if let startingFluxImage {
                flux_image_free(startingFluxImage)
            }
        }

        var seed = request.seed

        for _ in 0..<request.numberOfImages {
            if generationStopped {
                break
            }

            FluxStepImageBridge.startStepTiming()
            var params = flux_params.defaultParams
            params.width = Int32(request.size.width)
            params.height = Int32(request.size.height)
            params.num_steps = 4
            params.seed = Int64(seed)

            let image: UnsafeMutablePointer<flux_image>?
            if let startingFluxImage {
                if isDistilled, let embeddings {
                    image = Self.generateImg2ImgWithEmbeddings(
                        ctx: ctx,
                        embeddings: embeddings,
                        embeddingLength: embeddingLength,
                        startingFluxImage: startingFluxImage,
                        params: &params
                    )
                } else {
                    image = flux_img2img(ctx, request.prompt, startingFluxImage, &params)
                }
            } else {
                if isDistilled, let embeddings {
                    image = Self.generateWithEmbeddings(
                        ctx: ctx,
                        embeddings: embeddings,
                        embeddingLength: embeddingLength,
                        params: &params
                    )
                } else {
                    image = flux_generate(ctx, request.prompt, &params)
                }
            }

            guard let image else {
                throw Flux2cImageGeneratorError.generateFailed(fluxErrorMessage())
            }
            defer { flux_image_free(image) }

            let metadata = GenerationMetadata(
                prompt: request.prompt,
                negativePrompt: request.negativePrompt,
                width: Int(image.pointee.width),
                height: Int(image.pointee.height),
                pipeline: request.pipeline,
                model: request.pipeline.displayName,
                scheduler: .discreteFlowScheduler,
                seed: seed,
                steps: 4,
                guidanceScale: isDistilled ? 1.0 : 4.0,
                generatedDate: Date.now,
                metadataFields: request.pipeline.metadataFields
            )

            guard
                let imageData = await makeImageData(
                    from: image,
                    metadata: metadata,
                    imageType: request.imageType
                )
            else {
                throw Flux2cImageGeneratorError.encodeFailed
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
        params: inout flux_params
    ) -> UnsafeMutablePointer<flux_image>? {
        embeddings.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { return nil }
            return flux_generate_with_embeddings(ctx, pointer, embeddingLength, &params)
        }
    }

    private static func generateImg2ImgWithEmbeddings(
        ctx: OpaquePointer,
        embeddings: [Float],
        embeddingLength: Int32,
        startingFluxImage: UnsafeMutablePointer<flux_image>,
        params: inout flux_params
    ) -> UnsafeMutablePointer<flux_image>? {
        embeddings.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { return nil }
            return flux_img2img_with_embeddings(
                ctx,
                pointer,
                embeddingLength,
                startingFluxImage,
                &params
            )
        }
    }

    func stopGenerate() async {
        generationStopped = true
    }

    private func makeImageData(
        from image: UnsafePointer<flux_image>,
        metadata: GenerationMetadata,
        imageType: String
    ) async -> Data? {
        guard let cgImage = Self.makeCGImage(from: image) else {
            return nil
        }

        var sdi = SDImage()
        sdi.image = cgImage
        sdi.prompt = metadata.prompt
        sdi.negativePrompt = metadata.negativePrompt
        sdi.model = metadata.model
        sdi.scheduler = metadata.scheduler
        sdi.seed = metadata.seed
        sdi.steps = metadata.steps
        sdi.guidanceScale = metadata.guidanceScale
        sdi.generatedDate = metadata.generatedDate
        sdi.aspectRatio = CGFloat(Double(cgImage.width) / Double(cgImage.height))

        let type = UTType.fromString(imageType)
        return await sdi.imageData(type, metadataFields: metadata.metadataFields)
    }

    fileprivate static func makeCGImage(from image: UnsafePointer<flux_image>) -> CGImage? {
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

    fileprivate static func makeFluxImage(from data: Data) -> UnsafeMutablePointer<flux_image>? {
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

        guard let fluxImage = flux_image_create(Int32(width), Int32(height), Int32(channels)) else {
            return nil
        }
        guard let dataPtr = fluxImage.pointee.data else {
            flux_image_free(fluxImage)
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

private enum Flux2cImageGeneratorError: Error, CustomStringConvertible {
    case invalidPipeline
    case loadFailed(String)
    case generateFailed(String)
    case encodeFailed
    case decodeStartingImageFailed

    var description: String {
        switch self {
        case .invalidPipeline:
            return "Flux2cImageGenerator called with non-flux pipeline."
        case .loadFailed(let message):
            return "Failed to load model: \(message)"
        case .generateFailed(let message):
            return "Failed to generate image: \(message)"
        case .encodeFailed:
            return "Failed to encode generated image."
        case .decodeStartingImageFailed:
            return "Failed to decode starting image for img2img."
        }
    }
}

private func fluxErrorMessage() -> String {
    guard let cString = flux_get_error() else {
        return "Unknown error."
    }
    return String(cString: cString)
}

private final class FluxPromptEmbeddingCache {
    struct Entry {
        let seqLen: Int32
        let values: [Float]
    }

    private struct QuantizedEmbedding {
        static let blockSize = 32

        let elementCount: Int
        let packed: [UInt8]
        let scales: [Float]
        let offsets: [Float]

        init(values: [Float]) {
            elementCount = values.count
            let blockCount = (values.count + Self.blockSize - 1) / Self.blockSize

            var packed = [UInt8](repeating: 0, count: (values.count + 1) / 2)
            var scales = [Float](repeating: 0, count: blockCount)
            var offsets = [Float](repeating: 0, count: blockCount)

            for block in 0..<blockCount {
                let start = block * Self.blockSize
                let end = min(start + Self.blockSize, values.count)
                let slice = values[start..<end]
                guard let minVal = slice.min(), let maxVal = slice.max() else {
                    continue
                }
                let range = max(maxVal - minVal, 1e-10)
                offsets[block] = minVal
                scales[block] = range

                let invScale = 15.0 / range
                for idx in start..<end {
                    let normalized = (values[idx] - minVal) * invScale
                    let quantized = max(0, min(15, Int(normalized.rounded())))
                    let byteIdx = idx / 2
                    if idx.isMultiple(of: 2) {
                        packed[byteIdx] = (packed[byteIdx] & 0xF0) | UInt8(quantized & 0x0F)
                    } else {
                        packed[byteIdx] = (packed[byteIdx] & 0x0F) | UInt8((quantized & 0x0F) << 4)
                    }
                }
            }

            self.packed = packed
            self.scales = scales
            self.offsets = offsets
        }

        func dequantized() -> [Float] {
            var values = [Float](repeating: 0, count: elementCount)
            let blockCount = scales.count

            for block in 0..<blockCount {
                let start = block * Self.blockSize
                let end = min(start + Self.blockSize, elementCount)

                let scale = scales[block] / 15.0
                let offset = offsets[block]

                for idx in start..<end {
                    let byteIdx = idx / 2
                    let quantized: UInt8
                    if idx.isMultiple(of: 2) {
                        quantized = packed[byteIdx] & 0x0F
                    } else {
                        quantized = (packed[byteIdx] >> 4) & 0x0F
                    }
                    values[idx] = Float(quantized) * scale + offset
                }
            }

            return values
        }
    }

    private struct StoredEntry {
        let seqLen: Int32
        let quantized: QuantizedEmbedding
    }

    private struct Key: Hashable {
        let modelDir: String
        let prompt: String
    }

    private let maxEntries: Int
    private let lock = NSLock()
    private var entries: [Key: StoredEntry] = [:]
    private var lru: [Key] = []

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func lookup(modelDir: String, prompt: String) -> Entry? {
        let key = Key(modelDir: modelDir, prompt: prompt)
        lock.lock()
        guard let stored = entries[key] else {
            lock.unlock()
            return nil
        }
        touch(key)
        lock.unlock()

        return Entry(
            seqLen: stored.seqLen,
            values: stored.quantized.dequantized()
        )
    }

    func store(modelDir: String, prompt: String, seqLen: Int32, values: [Float]) {
        let key = Key(modelDir: modelDir, prompt: prompt)
        let quantized = QuantizedEmbedding(values: values)

        lock.lock()
        defer { lock.unlock() }

        entries[key] = StoredEntry(
            seqLen: seqLen,
            quantized: quantized
        )
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

extension flux_params {
    fileprivate static var defaultParams: flux_params {
        flux_params(
            width: 256, height: 256, num_steps: 4, seed: -1,
            guidance: 0.0, linear_schedule: 0, power_schedule: 0, power_alpha: 2.0
        )
    }
}

private enum FluxStepImageBridge {
    static var onProgress: (@Sendable (GenerationState.Progress, Double?) async -> Void)?
    static var onPreview: (@Sendable (CGImage?) async -> Void)?
    static var usePreview = false
    static var lastStepTime: DispatchTime?

    static func configure(
        onProgress: @escaping @Sendable (GenerationState.Progress, Double?) async -> Void,
        onPreview: @escaping @Sendable (CGImage?) async -> Void,
        usePreview: Bool
    ) {
        self.onProgress = onProgress
        self.onPreview = onPreview
        self.usePreview = usePreview
        lastStepTime = nil
    }

    static func startStepTiming() {
        lastStepTime = DispatchTime.now()
    }

    static func reset() {
        onProgress = nil
        onPreview = nil
        usePreview = false
        lastStepTime = nil
    }
}

//private let fluxStepImageCallback: @convention(c) (Int32, Int32, UnsafePointer<flux_image>?) -> Void = {
//    step, total, image in
//    guard let onProgress = FluxStepImageBridge.onProgress else { return }
//
//    let now = DispatchTime.now()
//    let elapsed = FluxStepImageBridge.lastStepTime.map {
//        Double(now.uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000
//    }
//    FluxStepImageBridge.lastStepTime = now
//
//    Task {
//        await onProgress(
//            GenerationState.Progress(step: Int(step), stepCount: Int(total)),
//            elapsed
//        )
//    }
//
//    guard FluxStepImageBridge.usePreview,
//          let onPreview = FluxStepImageBridge.onPreview,
//          let image
//    else {
//        return
//    }
//
//    let cgImage = Flux2cImageGenerator.makeCGImage(from: image)
//    Task {
//        await onPreview(cgImage)
//    }
//}
