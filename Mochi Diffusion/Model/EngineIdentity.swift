//
//  EngineIdentity.swift
//  Mochi Diffusion
//

import Foundation

/// Identifies a generation engine. Stable across launches and persisted, so a
/// raw value is never renamed once shipped.
nonisolated struct EngineID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

extension EngineID: CustomStringConvertible {
    var description: String { rawValue }
}

extension EngineID {
    static let coreMLStableDiffusion = EngineID(rawValue: "coreml-sd")
    static let iris = EngineID(rawValue: "iris")
}

/// Identifies a model *within* an engine.
///
/// Engine-qualifying identity is what lets two engines expose the same directory
/// without arbitration, and lets hosted engines name models that have no URL at
/// all. It replaces the bare `URL` that used to identify a model, which compared
/// by exact equality and so silently failed to match any other spelling of the
/// same path.
nonisolated struct ModelID: Hashable, Codable, Sendable {
    let engine: EngineID
    /// For a local engine, the name of a direct child of the engine's model
    /// directory. For a hosted engine, the API's own model name.
    let key: String
}

extension ModelID: CustomStringConvertible {
    var description: String { "\(engine.rawValue):\(key)" }
}

// MARK: - Local keys

extension ModelID {
    /// The key for a model directory that discovery returned.
    ///
    /// Deliberately just the last path component, rather than a relative path
    /// computed against the models root. Two measured behaviours make the
    /// arithmetic version wrong:
    ///
    /// - `FileManager.contentsOfDirectory(at:)` returns children prefixed
    ///   `/private/var` even when handed a `/var` URL, and
    ///   `resolvingSymlinksInPath()` normalises back the other way, so the child
    ///   and the root can disagree about the same prefix.
    /// - A model directory that is a symlink into the models folder — which
    ///   `FileSystemStore.subDirectories` accepts, since it filters on the
    ///   *resolved* path being a directory — resolves to a location outside the
    ///   root entirely. Stripping a resolved root off a resolved child would
    ///   reject exactly those models.
    ///
    /// Discovery only ever enumerates direct children, so the last component is
    /// the whole relative path. It also drops the inconsistent trailing slash:
    /// enumeration returns one for a real directory and none for a symlink.
    ///
    /// If a nested layout is ever needed, the key becomes a relative path — and
    /// whatever computes it must not resolve symlinks in the child.
    static func localKey(for url: URL) -> String {
        url.lastPathComponent
    }

    /// Whether `key` could have come from ``localKey(for:)``.
    ///
    /// This is the escape check. A key is a single path component, so it cannot
    /// traverse out of the models directory. Enforcing it here rather than at
    /// derivation time is what matters, because the dangerous direction is a
    /// persisted or imported key being turned back into a path to read.
    static func isValidLocalKey(_ key: String) -> Bool {
        if key.isEmpty { return false }
        if key == "." || key == ".." { return false }
        if key.contains("/") { return false }
        if key.contains("\0") { return false }
        return true
    }

    /// Resolves a local key back to a directory under `root`, or `nil` when the
    /// key is not one discovery could have produced.
    ///
    /// Keys are matched case-sensitively, exactly as written. On a
    /// case-insensitive volume that means renaming a model directory's case
    /// loses the selection and falls back to the first model — the same outcome
    /// as any other rename, and preferable to two keys that compare equal while
    /// naming different strings.
    static func localURL(forKey key: String, under root: URL) -> URL? {
        guard isValidLocalKey(key) else { return nil }
        return root.appending(path: key, directoryHint: .isDirectory)
    }
}
