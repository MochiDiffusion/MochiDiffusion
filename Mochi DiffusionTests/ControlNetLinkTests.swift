//
//  ControlNetLinkTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the two halves of a bug that predates the engine work: a stale
/// `<model>/controlnet` link was never replaced, and the pipeline cache key did
/// not include where ControlNet was actually loaded from, so changing the
/// configured folder could keep using the old one for as long as the app ran.
struct ControlNetLinkTests {
    let temp: TempDirectory
    let modelURL: URL
    let folderA: URL
    let folderB: URL

    init() throws {
        temp = try TempDirectory()
        modelURL = try temp.subdirectory("model")
        folderA = try temp.subdirectory("controlnet-a")
        folderB = try temp.subdirectory("controlnet-b")
    }

    private var linkPath: String {
        modelURL.appending(component: "controlnet").path(percentEncoded: false)
    }

    private func linkDestination() throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
    }

    @Test("A missing link is created")
    func createsMissingLink() throws {
        let location = ControlNetLink.resolve(configured: folderA, in: modelURL)

        #expect(try linkDestination() == folderA.path(percentEncoded: false))
        #expect(location == folderA.path(percentEncoded: false))
    }

    @Test("A link that already points at the configured folder is left alone")
    func keepsCorrectLink() throws {
        ControlNetLink.resolve(configured: folderA, in: modelURL)
        let location = ControlNetLink.resolve(configured: folderA, in: modelURL)

        #expect(try linkDestination() == folderA.path(percentEncoded: false))
        #expect(location == folderA.path(percentEncoded: false))
    }

    /// The first half of the bug. The old code returned early whenever anything
    /// existed at the path, so this link stayed pointing at A forever.
    @Test("A link pointing at the wrong folder is replaced")
    func replacesStaleLink() throws {
        ControlNetLink.resolve(configured: folderA, in: modelURL)

        let location = ControlNetLink.resolve(configured: folderB, in: modelURL)

        #expect(try linkDestination() == folderB.path(percentEncoded: false))
        #expect(location == folderB.path(percentEncoded: false))
    }

    /// The second half. The returned location is what makes the pipeline cache
    /// key differ, so the pipeline is rebuilt against the new folder instead of
    /// the already-loaded one being reused.
    @Test("The reported location changes with the configured folder")
    func locationTracksConfiguredFolder() {
        let first = ControlNetLink.resolve(configured: folderA, in: modelURL)
        let second = ControlNetLink.resolve(configured: folderB, in: modelURL)

        #expect(first != second)
    }

    /// The hazard in the obvious fix. `ml-stable-diffusion` reads
    /// `<model>/controlnet` whether or not it is a link, so a user not using
    /// Mochi's shared folder may keep their own bundles there. Replacing a
    /// directory means deleting what is inside it.
    @Test("A real directory is left in place and its contents survive")
    func doesNotReplaceRealDirectory() throws {
        let real = modelURL.appending(path: "controlnet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let bundle = real.appending(path: "user-controlnet.mlmodelc")
        try writeFile("{}", to: bundle.appending(path: "metadata.json"))

        let location = ControlNetLink.resolve(configured: folderA, in: modelURL)

        #expect(
            FileManager.default.fileExists(
                atPath: bundle.appending(path: "metadata.json").path(percentEncoded: false)
            )
        )
        // Reported as the load location, because that is where the pipeline reads.
        // Compared against `linkPath` rather than `real.path`: creating the URL
        // with `directoryHint: .isDirectory` gives it a trailing slash that
        // `appending(component:)` does not produce.
        #expect(location == linkPath)
        // Still a directory, not swapped for a link.
        let type =
            (try? FileManager.default.attributesOfItem(atPath: linkPath))?[.type]
            as? FileAttributeType
        #expect(type == .typeDirectory)
    }

    /// `fileExists` follows symlinks, so a link to a folder the user has since
    /// deleted reads as absent. Resolution has to look at the link itself.
    @Test("A dangling link is still recognised and repointed")
    func repointsDanglingLink() throws {
        let removed = try temp.subdirectory("controlnet-gone")
        ControlNetLink.resolve(configured: removed, in: modelURL)
        try FileManager.default.removeItem(at: removed)

        let location = ControlNetLink.resolve(configured: folderB, in: modelURL)

        #expect(try linkDestination() == folderB.path(percentEncoded: false))
        #expect(location == folderB.path(percentEncoded: false))
    }
}
