//
//  EngineIdentity.swift
//  Mochi Diffusion
//

import Foundation

nonisolated struct EngineID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

nonisolated extension EngineID: CustomStringConvertible {
    var description: String { rawValue }
}

nonisolated extension EngineID {
    static let coreMLStableDiffusion = EngineID(rawValue: "coreml-sd")
    static let iris = EngineID(rawValue: "iris")
    static let openAI = EngineID(rawValue: "openai")
}

/// Identifies a model within an engine.
///
/// For a local engine, `key` is the name of a direct child of the model directory.
/// For a hosted engine, `key` is the API's own model name.
nonisolated struct ModelID: Hashable, Codable, Sendable {
    let engine: EngineID
    let key: String
}

nonisolated extension ModelID: CustomStringConvertible {
    var description: String { "\(engine.rawValue):\(key)" }
}

// MARK: - Persistence

nonisolated extension ModelID {
    /// The persisted form: engine and key in one value, so a selection is written
    /// once rather than as two writes that can tear.
    ///
    /// Not `description`, so how an id reads in a log can change without changing
    /// what is on disk.
    var persistedValue: String { "\(engine.rawValue):\(key)" }

    /// Parses `persistedValue`.
    ///
    /// Splits on the first colon: engine ids never contain one, but a model key
    /// may, since a colon is legal in a POSIX filename.
    init?(persistedValue: String) {
        guard let separator = persistedValue.firstIndex(of: ":") else { return nil }
        let engine = String(persistedValue[persistedValue.startIndex..<separator])
        let key = String(persistedValue[persistedValue.index(after: separator)...])
        guard !engine.isEmpty, !key.isEmpty else { return nil }
        self.init(engine: EngineID(rawValue: engine), key: key)
    }
}

// MARK: - Local keys

nonisolated extension ModelID {
    /// The key for a model directory that discovery returned: its last path component.
    ///
    /// Discovery only enumerates direct children, so the last component is the
    /// whole relative path. Computing one against the models root instead breaks
    /// two cases: `contentsOfDirectory(at:)` returns `/private/var`-prefixed
    /// children for a `/var` root, and a model directory that is itself a symlink
    /// resolves outside the root entirely.
    ///
    /// A nested layout would make this a relative path, and would still have to
    /// leave symlinks in the child unresolved.
    static func localKey(for url: URL) -> String {
        url.lastPathComponent
    }

    /// Whether `key` could have come from `localKey(for:)`.
    ///
    /// The escape check: a key is a single path component, so it cannot traverse
    /// out of the models directory. Enforced here rather than at derivation, since
    /// the dangerous direction is a persisted or imported key becoming a path.
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
    /// Case-sensitive. On a case-insensitive volume, changing a model directory's
    /// case loses the selection, as any other rename does.
    static func localURL(forKey key: String, under root: URL) -> URL? {
        guard isValidLocalKey(key) else { return nil }
        return root.appending(path: key, directoryHint: .isDirectory)
    }
}
