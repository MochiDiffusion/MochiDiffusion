//
//  IrisEngineRuntime.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Runs Iris FLUX.2 requests.
///
/// The Iris C calls block inside the actor for the length of a generation, the
/// same trade `CoreMLEngineRuntime` documents.
///
/// Single-flight is enforced by `IrisSingleFlight`, *not* by this being an
/// actor. Actors are reentrant at every suspension point and `run` suspends four
/// times, so a second call would otherwise interleave and reset the C library's
/// process-global callback route and cancel flag under the first.
actor IrisEngineRuntime: GenerationEngineRuntime {
    private static let embeddingCache = FluxPromptEmbeddingCache(maxEntries: 16)

    func run(
        request: GenerationRequest,
        session: GenerationSession,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        // Held across the whole call, including its suspensions. Released on
        // every exit path — hence the explicit outcome rather than a `defer`,
        // which cannot await.
        await IrisSingleFlight.shared.acquire()

        // Checked here rather than only inside the generation loop. Waiting for the
        // lease is unbounded — it lasts as long as the generation ahead — so a
        // request cancelled while queued would otherwise take its turn and pay for
        // `iris_metal_init` and a multi-gigabyte `iris_load_dir` before the first
        // check, holding the lease against work that is still wanted.
        //
        // A cancelled waiter still takes its place in the FIFO rather than being
        // removed from it, but its turn is now one actor round-trip, so it delays
        // nothing measurably. Removing it instead would mean plumbing session
        // cancellation into the lease, and the session's flag is not the task's.
        guard !session.isCancelled else {
            await IrisSingleFlight.shared.release()
            return
        }

        let outcome: Result<Void, any Error>
        do {
            try await runHoldingLease(request: request, session: session, onResult: onResult)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await IrisSingleFlight.shared.release()
        try outcome.get()
    }

    private func runHoldingLease(
        request: GenerationRequest,
        session: GenerationSession,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        // The single downcast of this engine's payload; a mismatch is a wiring
        // bug, not a pipeline the user could fix.
        guard let payload = request.payload as? IrisGenerationPayload else {
            throw EngineError.payloadDoesNotBelongToEngine(engine: .iris)
        }
        let modelDir = payload.modelDirectory

        session.emit(.state(.loading("Loading model...")))
        iris_clear_cancel()
        // The C loop stops when the library's own flag is set, and this runtime
        // cannot set it while it is inside the call that would notice. So the poke
        // is registered on the session and runs on whichever thread cancels.
        session.onCancel { iris_request_cancel() }
        // Match the CLI startup order so transformer load sees Metal availability.
        _ = iris_metal_init()
        IrisCallbackRouter.shared.begin(
            session: session,
            usePreview: request.useDenoisedIntermediates
        )
        defer {
            iris_clear_cancel()
            IrisCallbackRouter.shared.end(session: session)
            session.emit(.preview(nil))
        }
        guard let ctx = iris_load_dir(modelDir) else {
            throw IrisRuntimeError.loadFailed(fluxErrorMessage())
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

        // Every reference the request carried, decoded up front so a failure is
        // reported before any generation starts rather than part-way through a
        // batch. Freed together in the `defer` below.
        var referenceImages: [UnsafeMutablePointer<iris_image>] = []
        for data in request.inputImageData {
            guard let decoded = Self.makeFluxImage(from: data) else {
                for image in referenceImages {
                    iris_image_free(image)
                }
                throw IrisRuntimeError.decodeStartingImageFailed
            }
            referenceImages.append(decoded)
        }
        // More than one reference means `iris_multiref`, which has no
        // `_with_embeddings` variant — so a multi-reference request re-encodes its
        // prompt instead of reusing the cache. Worth knowing when a two-image
        // generation feels slower to start than a one-image one.
        let usesMultiref = referenceImages.count > 1

        if isDistilled {
            if let cached = await Self.embeddingCache.lookup(
                modelDir: modelDir,
                prompt: request.prompt
            ) {
                embeddingLength = cached.seqLen
                embeddings = cached.values
            } else {
                guard let encoded = iris_encode_text(ctx, request.prompt, &embeddingLength) else {
                    throw IrisRuntimeError.generateFailed(fluxErrorMessage())
                }
                let textDim = Int(iris_text_dim(ctx))
                guard textDim > 0 else {
                    free(encoded)
                    throw IrisRuntimeError.generateFailed(
                        "Invalid text embedding dimension."
                    )
                }
                let elementCount = Int(embeddingLength) * textDim
                let rawEmbeddings = Array(UnsafeBufferPointer(start: encoded, count: elementCount))
                free(encoded)

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
            }
            // Keep peak memory lower before transformer work, even on cache hits.
            iris_release_text_encoder(ctx)
        }

        defer {
            iris_set_step_image_callback(ctx, nil)
            iris_set_step_callback(nil)
            iris_set_phase_callback(nil)
            iris_free(ctx)
            for image in referenceImages {
                iris_image_free(image)
            }
        }

        var seed = request.seed

        for _ in 0..<request.numberOfImages {
            if session.isCancelled {
                break
            }

            var params = iris_params.defaultParams
            params.width = Int32(request.size.width)
            params.height = Int32(request.size.height)
            // Resolved by IrisEngine.plan, so the queue, the generator and the
            // saved metadata cannot disagree about how many steps ran.
            params.num_steps = Int32(payload.stepCount)
            params.seed = Int64(seed)

            let image: UnsafeMutablePointer<iris_image>?
            if usesMultiref {
                image = Self.generateMultiref(
                    ctx: ctx,
                    prompt: request.prompt,
                    references: referenceImages,
                    params: &params
                )
            } else if let startingFluxImage = referenceImages.first {
                if isDistilled, let embeddings {
                    image = Self.generateImg2ImgWithEmbeddings(
                        ctx: ctx,
                        embeddings: embeddings,
                        embeddingLength: embeddingLength,
                        startingFluxImage: startingFluxImage,
                        params: &params
                    )
                } else {
                    image = iris_img2img(ctx, request.prompt, startingFluxImage, &params)
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
                    image = iris_generate(ctx, request.prompt, &params)
                }
            }

            guard let image else {
                if session.isCancelled {
                    break
                }
                throw IrisRuntimeError.generateFailed(fluxErrorMessage())
            }
            defer { iris_image_free(image) }

            let metadata = GenerationMetadata(
                prompt: request.prompt,
                negativePrompt: request.negativePrompt,
                width: Int(image.pointee.width),
                height: Int(image.pointee.height),
                model: request.displayName,
                engine: request.modelID.engine.rawValue,
                modelKey: request.modelID.key,
                quality: "",
                startingImage: "",
                controlNetImage: "",
                inputImages: request.inputImageNames,
                scheduler: payload.scheduler,
                mlComputeUnit: request.mlComputeUnit,
                seed: seed,
                steps: payload.stepCount,
                guidanceScale: isDistilled ? 1.0 : 4.0,
                generatedDate: Date.now,
                metadataFields: request.metadataFields
            )

            guard let cgImage = Self.makeCGImage(from: UnsafePointer(image)) else {
                throw IrisRuntimeError.encodeFailed
            }

            guard
                let imageData = await makeImageData(
                    from: cgImage,
                    metadata: metadata,
                    imageType: request.imageType
                )
            else {
                throw IrisRuntimeError.encodeFailed
            }

            let result = GenerationResult(metadata: metadata, imageData: imageData)
            try await onResult(result)
            seed &+= 1
        }
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

    private static func generateImg2ImgWithEmbeddings(
        ctx: OpaquePointer,
        embeddings: [Float],
        embeddingLength: Int32,
        startingFluxImage: UnsafeMutablePointer<iris_image>,
        params: inout iris_params
    ) -> UnsafeMutablePointer<iris_image>? {
        embeddings.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { return nil }
            return iris_img2img_with_embeddings(
                ctx,
                pointer,
                embeddingLength,
                startingFluxImage,
                &params
            )
        }
    }

    /// Generation against several reference images.
    ///
    /// `iris_multiref` wants an array of `const iris_image *`, so the owned mutable
    /// pointers are rebound to immutable ones for the call. The array is local to
    /// the call and the images it points at outlive it — they are freed with the
    /// context — so nothing here escapes.
    private static func generateMultiref(
        ctx: OpaquePointer,
        prompt: String,
        references: [UnsafeMutablePointer<iris_image>],
        params: inout iris_params
    ) -> UnsafeMutablePointer<iris_image>? {
        var pointers: [UnsafePointer<iris_image>?] = references.map { UnsafePointer($0) }
        return pointers.withUnsafeMutableBufferPointer {
            buffer -> UnsafeMutablePointer<iris_image>? in
            guard let base = buffer.baseAddress else { return nil }
            return iris_multiref(ctx, prompt, base, Int32(buffer.count), &params)
        }
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
        sdi.engine = metadata.engine
        sdi.modelKey = metadata.modelKey
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

private enum IrisRuntimeError: Error, CustomStringConvertible {
    case loadFailed(String)
    case generateFailed(String)
    case encodeFailed
    case decodeStartingImageFailed

    var description: String {
        switch self {
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
    private var entries: [Key: StoredEntry] = [:]
    private var lru: [Key] = []

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func lookup(modelDir: String, prompt: String) -> Entry? {
        let key = Key(modelDir: modelDir, prompt: prompt)
        guard let stored = entries[key] else { return nil }
        touch(key)

        return Entry(
            seqLen: stored.seqLen,
            values: stored.quantized.dequantized()
        )
    }

    func store(modelDir: String, prompt: String, seqLen: Int32, values: [Float]) {
        let key = Key(modelDir: modelDir, prompt: prompt)
        let quantized = QuantizedEmbedding(values: values)

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

extension iris_params {
    nonisolated fileprivate static var defaultParams: iris_params {
        iris_params(
            width: 256, height: 256, num_steps: 4, seed: -1,
            guidance: 0.0, schedule: Int32(IRIS_SCHEDULE_DEFAULT), power_alpha: 2.0
        )
    }
}

/// Routes the Iris C callbacks to the session that is generating.
///
/// The Iris C API takes bare function pointers with no context parameter, so a
/// callback cannot be told which request it belongs to. Two things follow.
///
/// First, delivery is **synchronous**, straight into the session's stream. Hopping
/// through a `Task` per callback would add a scheduling delay, give no ordering
/// guarantee between two updates, and let a task outlive the request that created
/// it and land on the next one.
///
/// Second, the router holds the active session and clears it on teardown, so a
/// callback arriving after generation finished has nowhere to go. It cannot defend
/// against one arriving after the *next* session has begun: with no context
/// pointer, such a callback is indistinguishable from a current one. That is safe
/// only because Iris calls back from inside `iris_generate` and friends, so no
/// callback outlives the call that produced it — an assumption about the C library
/// that cannot be enforced from this side.
///
/// `@unchecked Sendable` is sound because every mutable field is guarded by this
/// type's own lock.
nonisolated final class IrisCallbackRouter: @unchecked Sendable {
    static let shared = IrisCallbackRouter()

    private let lock = NSLock()
    private var session: GenerationSession?
    private var usePreview = false

    func begin(session: GenerationSession, usePreview: Bool) {
        lock.lock()
        self.session = session
        self.usePreview = usePreview
        lock.unlock()
    }

    /// Clears the route, but only if `session` is still the one installed, so a
    /// late teardown cannot detach the session that replaced it.
    func end(session: GenerationSession) {
        lock.lock()
        if self.session === session {
            self.session = nil
            usePreview = false
        }
        lock.unlock()
    }

    func report(progress step: Int32, total: Int32) {
        guard total > 0 else { return }
        let totalSteps = Int(total)
        // Iris counts from one; the UI's progress is zero-based.
        let zeroBasedStep = max(0, min(Int(step) - 1, totalSteps - 1))
        emit(
            .progress(GenerationState.Progress(step: zeroBasedStep, stepCount: totalSteps))
        )
    }

    func report(phase name: String?, done: Int32) {
        guard done == 0, let label = Self.phaseLabel(for: name) else { return }
        emit(.state(.loading(label)))
    }

    func report(preview image: CGImage?) {
        lock.lock()
        let wantsPreview = usePreview
        lock.unlock()
        guard wantsPreview else { return }
        emit(.preview(image))
    }

    private func emit(_ event: GenerationEvent) {
        lock.lock()
        let session = self.session
        lock.unlock()
        session?.emit(event)
    }

    private static func phaseLabel(for phaseName: String?) -> String? {
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

nonisolated private let fluxStepCallback: @convention(c) (Int32, Int32) -> Void = {
    step, total in
    IrisCallbackRouter.shared.report(progress: step, total: total)
}

nonisolated private let fluxPhaseCallback: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = {
    phase, done in
    IrisCallbackRouter.shared.report(phase: phase.map { String(cString: $0) }, done: done)
}

nonisolated private let fluxStepImageCallback:
    @convention(c) (
        Int32,
        Int32,
        UnsafePointer<iris_image>?
    ) -> Void = { _, _, image in
        IrisCallbackRouter.shared.report(
            preview: image.flatMap { IrisEngineRuntime.makeCGImage(from: $0) }
        )
    }
