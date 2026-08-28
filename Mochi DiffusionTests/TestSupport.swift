//
//  TestSupport.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import Mochi_Diffusion

/// A temporary directory that removes itself when the test scope ends.
///
/// Fixtures deliberately contain only the files the production sniffing code
/// actually inspects (`metadata.json`, zero-byte weight stand-ins), so the
/// suite stays fast and needs no real model weights.
nonisolated final class TempDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(
                path: "MochiDiffusionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func appending(_ components: String...) -> URL {
        components.reduce(url) { $0.appending(path: $1) }
    }

    /// Creates and returns a nested directory, so a single owner covers every
    /// fixture a test needs.
    func subdirectory(_ name: String) throws -> URL {
        let child = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return child
    }
}

nonisolated func writeFile(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url, options: .atomic)
}

// MARK: - Core ML Stable Diffusion fixtures

/// Builds the subset of a converted Core ML SD model directory that `SDModel`
/// inspects: a Unet metadata histogram (attention type + model family) and a
/// VAE encoder input shape (fixed input size).
nonisolated func makeSDModelFixture(
    at url: URL,
    attention: SDModelAttentionType = .original,
    inputSize: CGSize? = CGSize(width: 512, height: 512),
    unetName: String = "Unet.mlmodelc",
    extraUnetInputs: [String] = []
) throws {
    let histogram = attention == .splitEinsum ? #"{"Ios16.einsum": 1}"# : #"{"Ios16.add": 1}"#
    let inputNames = ["sample", "timestep", "encoder_hidden_states"] + extraUnetInputs
    let inputSchema =
        inputNames
        .map { #"{"name": "\#($0)"}"# }
        .joined(separator: ", ")

    try writeFile(
        """
        [{"mlProgramOperationTypeHistogram": \(histogram), "inputSchema": [\(inputSchema)]}]
        """,
        to: url.appending(components: unetName, "metadata.json")
    )

    if let inputSize {
        try writeFile(
            """
            [{"inputSchema": [{"name": "z", \
            "shape": "[1, 3, \(Int(inputSize.height)), \(Int(inputSize.width))]"}]}]
            """,
            to: url.appending(components: "VAEEncoder.mlmodelc", "metadata.json")
        )
    }
}

nonisolated func makeControlNetFixture(
    at url: URL,
    size: CGSize = CGSize(width: 512, height: 512),
    attention: SDModelAttentionType = .original
) throws {
    let histogram = attention == .splitEinsum ? #"{"Ios16.einsum": 1}"# : #"{"Ios16.add": 1}"#
    try writeFile(
        """
        [{"mlProgramOperationTypeHistogram": \(histogram), \
        "inputSchema": [{"name": "controlnet_cond", \
        "shape": "[1, 3, \(Int(size.height)), \(Int(size.width))]"}]}]
        """,
        to: url.appending(path: "metadata.json")
    )
}

// MARK: - Iris FLUX.2 Klein fixtures

/// Every path `IrisFluxKleinModel.init?` requires, minus the transformer and
/// text encoder weights, which `weights` supplies in either layout.
nonisolated enum KleinWeightLayout {
    /// A single `<base>.safetensors` file.
    case single
    /// An index file plus every shard it names, as produced by sharded exports.
    /// Production only requires the index and at least one matching shard, so
    /// this fixture is deliberately stricter than discovery needs — discovery
    /// stays shallow on purpose, since parsing every index for every model on
    /// every folder-change event would put real I/O on that path.
    case sharded
    /// Nothing, for asserting that the model is rejected.
    case missing
}

/// Every non-weight path `IrisFluxKleinModel.init?` requires, declared once so a
/// test can assert that each one is load-bearing without restating the list and
/// silently covering only part of it.
nonisolated let kleinRequiredConfigPaths: [[String]] = [
    ["text_encoder", "config.json"],
    ["text_encoder", "generation_config.json"],
    ["tokenizer", "added_tokens.json"],
    ["tokenizer", "chat_template.jinja"],
    ["tokenizer", "merges.txt"],
    ["tokenizer", "special_tokens_map.json"],
    ["tokenizer", "tokenizer.json"],
    ["tokenizer", "tokenizer_config.json"],
    ["tokenizer", "vocab.json"],
    ["transformer", "config.json"],
    ["vae", "config.json"],
    ["vae", "diffusion_pytorch_model.safetensors"],
]

nonisolated func makeKleinModelFixture(
    at url: URL,
    weights: KleinWeightLayout = .single,
    omitting omittedPaths: [[String]] = []
) throws {
    var required = kleinRequiredConfigPaths
    required.removeAll { omittedPaths.contains($0) }

    for components in required {
        try writeFile("{}", to: components.reduce(url) { $0.appending(path: $1) })
    }

    switch weights {
    case .single:
        try writeFile("", to: url.appending(components: "text_encoder", "model.safetensors"))
        try writeFile(
            "", to: url.appending(components: "transformer", "diffusion_pytorch_model.safetensors"))
    case .sharded:
        try writeFile(
            "{}", to: url.appending(components: "text_encoder", "model.safetensors.index.json"))
        try writeFile(
            "", to: url.appending(components: "text_encoder", "model-00001-of-00001.safetensors"))
        try writeFile(
            "{}",
            to: url.appending(
                components: "transformer", "diffusion_pytorch_model.safetensors.index.json"))
        for shard in 1...2 {
            try writeFile(
                "",
                to: url.appending(
                    components: "transformer",
                    "diffusion_pytorch_model-0000\(shard)-of-00002.safetensors"))
        }
    case .missing:
        break
    }
}

// MARK: - Images

nonisolated func makeCGImage(width: Int = 8, height: Int = 8) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Writes a PNG carrying `caption` as its IPTC caption-abstract, bypassing
/// `SDImage.metadata(including:)` so tests can exercise the import parser
/// against arbitrary — including malformed or legacy — metadata strings.
nonisolated func writePNG(
    caption: String,
    to url: URL,
    image: CGImage = makeCGImage()
) throws {
    let data = CFDataCreateMutable(nil, 0)!
    let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    let properties =
        [
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCaptionAbstract: caption,
                kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
            ]
        ] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    precondition(CGImageDestinationFinalize(destination))
    try (data as Data).write(to: url, options: .atomic)
}

// MARK: - Preferences

/// An isolated `UserDefaults` suite that removes itself when the test scope ends.
///
/// The test host *is* Mochi Diffusion, so `UserDefaults.standard` inside a test is
/// the developer's own live preferences. A `ConfigStore` built on this suite
/// neither reads real settings nor overwrites them, and parallel suites cannot
/// see each other's writes.
nonisolated final class TempDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() {
        suiteName = "MochiDiffusionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

// MARK: - Image inspection

/// Decodes just the pixel dimensions of encoded image data, so tests can assert
/// what a starting image was scaled to without pinning encoded bytes.
nonisolated func pixelSize(of data: Data) -> CGSize? {
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return CGSize(width: image.width, height: image.height)
}

// MARK: - Secrets

/// A `SecretStore` held in memory.
///
/// Exists so no test ever writes to the developer's login keychain.
/// `KeychainSecretStore` itself is deliberately not exercised by the suite — see
/// `SecretStoreTests` for why, and for what was verified by hand instead.
nonisolated final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]
    /// Set to make writes fail, for testing the paths that report a store problem.
    var writesFail = false

    init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    func hasSecret(for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account] != nil
    }

    func secret(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func setSecret(_ secret: String?, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if writesFail { throw SecretStoreError.unavailable }
        if let secret, !secret.isEmpty {
            secrets[account] = secret
        } else {
            secrets.removeValue(forKey: account)
        }
    }

    /// Reads without going through the protocol, so a test can assert on what was
    /// stored without the assertion depending on the code under test.
    func storedValue(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }
}
