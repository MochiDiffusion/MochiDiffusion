//
//  OpenAIImageEngineTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// An `HTTPSession` that answers from canned lines.
///
/// Nothing in this suite makes a request. A suite that talks to a paid service is
/// one nobody can run offline, and one that occasionally bills.
nonisolated final class FakeHTTPSession: HTTPSession, @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode: Int
    private var body: [String]
    private var failure: (any Error)?
    private var recorded: URLRequest?

    init(statusCode: Int = 200, body: [String] = [], failure: (any Error)? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.failure = failure
    }

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var lastRequestBody: [String: Any]? {
        guard let data = lastRequest?.httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func record(_ request: URLRequest) -> (Int, [String], (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        recorded = request
        return (statusCode, body, failure)
    }

    func lines(
        for request: URLRequest
    ) async throws -> (response: HTTPURLResponse, lines: AsyncThrowingStream<String, any Error>) {
        // `NSLock` is unavailable from an async context, so the mutation is done
        // in a synchronous helper. The lock is still needed: the runtime may call
        // this from any executor.
        let (status, lines, failure) = record(request)
        // A transport failure, for the callers that have to tell "the service
        // said no" apart from "the service could not be asked".
        if let failure { throw failure }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return (response, stream)
    }
}

/// Builds the base64 PNG the API would return, so the stream fixtures carry a
/// real decodable image rather than a placeholder that would make the decode path
/// untested.
nonisolated func base64PNG(width: Int = 8, height: Int = 8) -> String {
    makeCGImage(width: width, height: height).pngData()!.base64EncodedString()
}

struct OpenAIImageEngineTests {
    private let account = OpenAIImageEngine.secretAccount

    private func engine(
        key: String? = "sk-test",
        session: any HTTPSession = FakeHTTPSession()
    ) -> OpenAIImageEngine {
        let store = InMemorySecretStore(key.map { [account: $0] } ?? [:])
        return OpenAIImageEngine(secrets: store, session: session)
    }

    private var settings: EngineSettings {
        EngineSettings(
            modelDirectory: URL(fileURLWithPath: "/nonexistent-models"),
            controlNetDirectory: URL(fileURLWithPath: "/nonexistent-controlnet")
        )
    }

    private func draft(
        size: CGSize = CGSize(width: 1_024, height: 1_024),
        quality: ImageQuality = .auto,
        numberOfImages: Int = 1,
        previews: Bool = false
    ) -> GenerationDraft {
        GenerationDraft(
            prompt: "a cat",
            negativePrompt: "blurry",
            configuredSize: size,
            startingImage: makeCGImage(),
            startingImageName: "start.png",
            controlNets: [],
            strength: 0.5,
            stepCount: 23,
            guidanceScale: 11,
            scheduler: .pndmScheduler,
            quality: quality,
            seed: 7,
            numberOfImages: numberOfImages,
            computeUnitPreference: .auto,
            reduceMemory: false,
            safetyChecker: false,
            showGenerationPreview: previews,
            imageDir: FileManager.default.temporaryDirectory.path(percentEncoded: false),
            imageType: "png",
            controlNetDirectory: URL(fileURLWithPath: "/controlnet")
        )
    }

    // MARK: - Availability

    /// The reason this engine is listed while unconfigured: nobody discovers a
    /// backend that only appears once it is already set up (§8).
    @Test("Without a key the engine says what is missing")
    func availabilityWithoutKey() async {
        let availability = await engine(key: nil).availability(settings)

        #expect(availability == .needsConfiguration("Add an API key in Settings"))
    }

    @Test("With a key the engine is ready")
    func availabilityWithKey() async {
        #expect(await engine().availability(settings) == .ready)
    }

    /// Availability must not read the secret, only ask whether one exists.
    @Test("Availability does not fetch the secret")
    func availabilityDoesNotReadTheSecret() async {
        final class CountingStore: SecretStore, @unchecked Sendable {
            let lock = NSLock()
            var reads = 0
            func hasSecret(for account: String) -> Bool { true }
            func secret(for account: String) -> String? {
                lock.lock()
                reads += 1
                lock.unlock()
                return "sk-test"
            }
            func setSecret(_ secret: String?, for account: String) throws {}
        }
        let store = CountingStore()

        _ = await OpenAIImageEngine(secrets: store).availability(settings)

        #expect(store.reads == 0)
    }

    // MARK: - Discovery

    @Test("Discovery ignores the models folder entirely")
    func discoveryIgnoresLocalFolder() async throws {
        // The folder does not exist. A hosted engine must not look broken because
        // a local directory is unreadable.
        let models = try await engine().discoverModels(
            ModelDiscoveryContext(settings: settings))

        #expect(models.count == 1)
        #expect(models[0].id == ModelID(engine: .init(rawValue: "openai"), key: "gpt-image-2"))
        #expect(models[0].name == "gpt-image-2")
        #expect(models[0].tokenizerModelDir == nil)
    }

    /// No seed: the service exposes none, so recording one would put a number in
    /// the metadata that had no effect on the image.
    @Test("The model records only what it actually has")
    func metadataFieldsAreHonest() {
        let fields = OpenAIImageEngine.gptImage2.metadataFields

        #expect(fields == [.prompt, .model, .engine, .modelKey, .size, .quality])
        #expect(!fields.contains(.seed))
        #expect(!fields.contains(.steps))
        #expect(!fields.contains(.scheduler))
        #expect(!fields.contains(.guidanceScale))
    }

    // MARK: - Planning

    @Test("Planning leaves every unsupported option unset")
    func planLeavesUnsupportedOptionsNil() throws {
        let plan = try engine().plan(draft: draft(), model: OpenAIImageEngine.gptImage2)

        // The sidebar had a step count, scheduler, strength and guidance scale.
        // None of them survives, because this model has no notion of any of them.
        #expect(plan.stepCount == nil)
        #expect(plan.scheduler == nil)
        #expect(plan.strength == nil)
        #expect(plan.guidanceScale == nil)
        #expect(plan.mlComputeUnit == nil)
        // A starting image was set too, and is dropped rather than sent: this
        // version uses the generations endpoint only.
        #expect(plan.startingImageData == nil)
        #expect(plan.startingImageName == nil)
        #expect(plan.inputImageNames.isEmpty)
        #expect(plan.controlNetImageData.isEmpty)
    }

    @Test(
        "Planning corrects a size the service would reject",
        arguments: [
            // Legal already.
            (CGSize(width: 1_024, height: 1_024), CGSize(width: 1_024, height: 1_024)),
            // 7.5:1, past the 3:1 cap.
            (CGSize(width: 3_840, height: 512), CGSize(width: 1_536, height: 512)),
            // Below the pixel floor.
            (CGSize(width: 512, height: 512), CGSize(width: 816, height: 816)),
        ]
    )
    func planCorrectsSize(requested: CGSize, expected: CGSize) throws {
        let plan = try engine().plan(
            draft: draft(size: requested), model: OpenAIImageEngine.gptImage2)

        #expect(plan.size == expected)
        // The payload and the plan must agree: the queue shows one and the request
        // sends the other.
        let payload = try #require(plan.payload as OpenAIGenerationPayload?)
        #expect(payload.size == expected)
    }

    @Test("Planning resolves quality and carries it both ways")
    func planResolvesQuality() throws {
        let plan = try engine().plan(
            draft: draft(quality: .high), model: OpenAIImageEngine.gptImage2)

        #expect(plan.quality == .high)
        #expect(plan.payload.quality == .high)
    }

    @Test("A count above what the engine offers is brought down")
    func planClampsImageCount() throws {
        // Deliberately tighter than the local engines' 1...100, and with no room
        // above it, because every image here is billed.
        let plan = try engine().plan(
            draft: draft(numberOfImages: 500), model: OpenAIImageEngine.gptImage2)

        #expect(plan.numberOfImages == 10)
    }

    /// §13.1 keeps credentials out of persisted requests and logs, and a payload
    /// rides in a `GenerationRequest`. This is the structural guard.
    @Test("The payload carries no credential")
    func payloadCarriesNoCredential() throws {
        let plan = try engine().plan(draft: draft(), model: OpenAIImageEngine.gptImage2)

        let values = Mirror(reflecting: plan.payload).children.map { "\($0.value)" }
        #expect(!values.contains { $0.contains("sk-test") })
        // And nothing that looks like a store, either — the runtime holds that.
        #expect(values.count == 4)
    }
}
