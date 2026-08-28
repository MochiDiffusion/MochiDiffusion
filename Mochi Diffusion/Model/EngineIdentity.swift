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

nonisolated extension EngineID: CustomStringConvertible {
    var description: String { rawValue }
}

nonisolated extension EngineID {
    static let coreMLStableDiffusion = EngineID(rawValue: "coreml-sd")
    static let iris = EngineID(rawValue: "iris")
    static let openAI = EngineID(rawValue: "openai")
}

/// Identifies a model *within* an engine.
///
/// Qualifying identity by engine is what lets two engines expose the same
/// directory without arbitration, and lets a hosted engine name models that have
/// no URL at all. Identifying a model by bare `URL` instead compares by exact
/// equality, so any other spelling of the same path silently fails to match.
nonisolated struct ModelID: Hashable, Codable, Sendable {
    let engine: EngineID
    /// For a local engine, the name of a direct child of the engine's model
    /// directory. For a hosted engine, the API's own model name.
    let key: String
}

nonisolated extension ModelID: CustomStringConvertible {
    var description: String { "\(engine.rawValue):\(key)" }
}

// MARK: - Persistence

nonisolated extension ModelID {
    /// The persisted form: engine and key in one value.
    ///
    /// One value rather than two so a selection is stored with a single
    /// `UserDefaults` write. Two writes reach `cfprefsd` as two messages, so a
    /// process killed between them could leave a new engine beside an old key: a
    /// pair that looks valid, names nothing, and silently resets the user's
    /// selection on the next launch.
    ///
    /// Deliberately not `description`, so how an id reads in a log can change
    /// without changing what is on disk.
    var persistedValue: String { "\(engine.rawValue):\(key)" }

    /// Parses `persistedValue`.
    ///
    /// Splits on the *first* colon. Engine ids never contain one — we choose them
    /// — but a model key may, since a colon is legal in a POSIX filename.
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
    /// The key for a model directory that discovery returned.
    ///
    /// The last path component, deliberately, rather than a relative path
    /// computed against the models root. Two behaviours make the arithmetic
    /// version wrong:
    ///
    /// - `FileManager.contentsOfDirectory(at:)` returns children prefixed
    ///   `/private/var` even when handed a `/var` URL, while
    ///   `resolvingSymlinksInPath()` normalises the other way, so a child and its
    ///   root can disagree about the same prefix.
    /// - A model directory that is a symlink into the models folder resolves
    ///   outside the root entirely, and `FileSystemStore.subDirectories` accepts
    ///   such a directory because it filters on the *resolved* path. Stripping a
    ///   resolved root off a resolved child would reject exactly those models.
    ///
    /// Discovery only enumerates direct children, so the last component is the
    /// whole relative path. It also drops the trailing slash enumeration adds for
    /// a real directory but not for a symlink.
    ///
    /// Supporting a nested layout would make the key a relative path, and whatever
    /// computed it would still have to leave symlinks in the child unresolved.
    static func localKey(for url: URL) -> String {
        url.lastPathComponent
    }

    /// Whether `key` could have come from `localKey(for:)`.
    ///
    /// This is the escape check: a key is a single path component, so it cannot
    /// traverse out of the models directory. It belongs here rather than at
    /// derivation, because the dangerous direction is a persisted or imported key
    /// being turned back into a path to read.
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
