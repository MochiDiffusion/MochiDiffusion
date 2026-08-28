//
//  EngineIdentityTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// `ModelID.key` is persisted data, so its derivation, traversal, symlink and
/// case-sensitivity rules are pinned here rather than left to whatever `URL`
/// happens to do.
struct ModelIDKeyTests {

    // MARK: - Derivation

    @Test(
        "A key is the model directory's own name, however the path is spelled",
        arguments: [
            "/var/folders/x/models/sd-model",
            "/var/folders/x/models/sd-model/",
            "/private/var/folders/x/models/sd-model",
            "/private/var/folders/x/models/sd-model/",
        ]
    )
    func keyIsTheDirectoryName(path: String) {
        let url = URL(fileURLWithPath: path)

        #expect(ModelID.localKey(for: url) == "sd-model")
    }

    /// Enumeration spells a path's prefix differently from the root it was handed,
    /// so a key derived from one cannot be compared against the other. Derived
    /// through real discovery rather than hand-built URLs, because the discrepancy
    /// only appears there.
    @Test("Discovery yields the same keys as the names on disk")
    func discoveredKeysMatchDiskNames() throws {
        let temp = try TempDirectory()
        let models = try temp.subdirectory("models")
        for name in ["a-model", "b-model", "Casing-Preserved"] {
            try FileManager.default.createDirectory(
                at: models.appending(path: name), withIntermediateDirectories: true)
        }
        // Reached the way the app reaches it: an unresolved path from settings.
        let root = URL(fileURLWithPath: models.path(percentEncoded: false), isDirectory: true)

        let discovered = try FileSystemStore().subDirectories(in: root)
        let keys = discovered.map { ModelID.localKey(for: $0) }.sorted()

        #expect(keys == ["Casing-Preserved", "a-model", "b-model"])
        // The prefix genuinely differs from the root that was passed in, which is
        // what breaks matching on full paths.
        #expect(discovered.allSatisfy { $0.path(percentEncoded: false).contains("/models/") })
    }

    /// A model directory symlinked in from elsewhere is discovered today, because
    /// `FileSystemStore.subDirectories` filters on the *resolved* path being a
    /// directory. Its key must be the name inside the models folder — the name the
    /// user sees — not anything derived from where it points.
    @Test("A symlinked model is keyed by its name in the models directory")
    func symlinkedModelKeyedByVisibleName() throws {
        let temp = try TempDirectory()
        let models = try temp.subdirectory("models")
        let elsewhere = try temp.subdirectory("elsewhere")
        let real = elsewhere.appending(path: "real-model")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: models.appending(path: "linked-model").path(percentEncoded: false),
            withDestinationPath: real.path(percentEncoded: false)
        )

        let discovered = try FileSystemStore().subDirectories(in: models)

        #expect(discovered.count == 1)
        #expect(ModelID.localKey(for: try #require(discovered.first)) == "linked-model")
    }

    // MARK: - Validation

    @Test(
        "A key naming anything but a direct child is rejected",
        arguments: [
            "",
            ".",
            "..",
            "../sibling",
            "../../etc/passwd",
            "sub/model",
            "/absolute",
            "trailing/",
            "with\0null",
        ]
    )
    func invalidKeysAreRejected(key: String) {
        #expect(!ModelID.isValidLocalKey(key))
        #expect(ModelID.localURL(forKey: key, under: URL(fileURLWithPath: "/models")) == nil)
    }

    @Test(
        "An ordinary directory name is accepted",
        arguments: [
            "sd-model",
            "sd-1.5_512x512",
            "model with spaces",
            "модель",
            "モデル",
            "..leading-dots",
            "-leading-dash",
        ]
    )
    func validKeysAreAccepted(key: String) {
        #expect(ModelID.isValidLocalKey(key))
    }

    // MARK: - Resolution

    @Test("A valid key resolves to a directory under the configured root")
    func validKeyResolvesUnderRoot() throws {
        let root = URL(fileURLWithPath: "/models", isDirectory: true)

        let url = try #require(ModelID.localURL(forKey: "sd-model", under: root))

        #expect(url.path(percentEncoded: false) == "/models/sd-model/")
    }

    @Test("A key round-trips from a discovered URL back to the same directory")
    func keyRoundTripsThroughDiscovery() throws {
        let temp = try TempDirectory()
        let models = try temp.subdirectory("models")
        let modelURL = models.appending(path: "sd-model")
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)

        let discovered = try #require(FileSystemStore().subDirectories(in: models).first)
        let key = ModelID.localKey(for: discovered)
        let resolved = try #require(ModelID.localURL(forKey: key, under: models))

        // Resolution reconstructs a usable path even though it will not be
        // byte-identical to the discovered URL, which is the whole point of not
        // comparing URLs.
        #expect(FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false)))
        #expect(resolved.lastPathComponent == discovered.lastPathComponent)
    }

    // MARK: - Identity semantics

    @Test("The same key under two engines is two different models")
    func engineQualifiesIdentity() {
        let coreML = ModelID(engine: .coreMLStableDiffusion, key: "shared-dir")
        let iris = ModelID(engine: .iris, key: "shared-dir")

        // This is what removes the need for discovery to arbitrate ownership: both
        // engines can expose one directory and stay distinguishable.
        #expect(coreML != iris)
        #expect(Set([coreML, iris]).count == 2)
    }

    @Test("Keys differing only in case are different models")
    func keysAreCaseSensitive() {
        let lower = ModelID(engine: .iris, key: "model")
        let upper = ModelID(engine: .iris, key: "Model")

        // Documented consequence on a case-insensitive volume: renaming a model's
        // case loses the selection, exactly as any other rename does.
        #expect(lower != upper)
    }

    @Test("A model id survives an encode/decode round trip")
    func modelIDIsCodable() throws {
        let id = ModelID(engine: .coreMLStableDiffusion, key: "sd-1.5_512x512")

        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ModelID.self, from: data)

        #expect(decoded == id)
    }

    // MARK: - Persistence

    /// A selection is one stored value, not two, so it cannot be torn into a
    /// valid-looking hybrid of a new engine and an old key by a process that dies
    /// between two `UserDefaults` writes.
    @Test("The persisted form is one value with the engine first")
    func persistedFormIsStable() {
        let id = ModelID(engine: .coreMLStableDiffusion, key: "sd-1.5_512x512")

        // Pinned: this is on-disk format, so a change must be deliberate.
        #expect(id.persistedValue == "coreml-sd:sd-1.5_512x512")
    }

    @Test(
        "A persisted selection round-trips, including keys containing a colon",
        arguments: [
            "sd-model",
            "sd-1.5_512x512",
            "model with spaces",
            // Legal in a POSIX filename, which is why parsing splits on the
            // first colon rather than the only one.
            "colon:in:name",
            ":leading-colon",
            "モデル",
        ]
    )
    func persistedFormRoundTrips(key: String) throws {
        let id = ModelID(engine: .iris, key: key)

        let decoded = try #require(ModelID(persistedValue: id.persistedValue))

        #expect(decoded == id)
    }

    @Test(
        "An unparseable persisted value is no selection rather than a wrong one",
        arguments: [
            "",
            "no-separator",
            ":no-engine",
            "no-key:",
        ]
    )
    func unparseablePersistedFormIsNil(value: String) {
        #expect(ModelID(persistedValue: value) == nil)
    }

    @Test("The persisted form is not tied to the description")
    func persistedFormIsIndependentOfDescription() {
        let id = ModelID(engine: .iris, key: "klein")

        // They coincide today. The point is that they are separate members, so
        // making logs read better cannot silently change what is on disk.
        #expect(id.persistedValue == "iris:klein")
        #expect(id.description == "iris:klein")
    }

    @Test("Engine ids are stable strings")
    func engineIDsAreStable() {
        // These are persisted, so a change here silently orphans a user's
        // selection. Pinned so that requires a deliberate edit.
        #expect(EngineID.coreMLStableDiffusion.rawValue == "coreml-sd")
        #expect(EngineID.iris.rawValue == "iris")
        #expect(EngineID.openAI.rawValue == "openai")
    }
}
