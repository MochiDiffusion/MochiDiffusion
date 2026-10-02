//
//  EngineSettingsStore.swift
//  Mochi Diffusion
//

import Foundation
import Observation

/// Persisted settings that belong to one engine: the Draw Things server connection.
///
/// Separate from `ConfigStore` because the value is a whole connection under an
/// engine-qualified `Engine.<id>.Options` key rather than one `@AppStorage`
/// property per literal key. The model picker's selection is
/// `ConfigStore.selectedModel`.
@MainActor
@Observable final class EngineSettingsStore {
    nonisolated enum Key {
        /// Engine-specific values that are not a model selection, such as a
        /// server's address.
        static func options(_ engine: EngineID) -> String {
            "Engine.\(engine.rawValue).Options"
        }
    }

    private let store: UserDefaults

    /// The shared secret is not part of this value; it is kept in the Keychain.
    var drawThings: DrawThingsConnection {
        didSet {
            if let data = try? JSONEncoder().encode(drawThings) {
                store.set(data, forKey: Key.options(.drawThings))
            }
        }
    }

    /// - Parameter store: the defaults to read and write. Tests pass an isolated
    ///   suite; the app uses `.standard`.
    init(store: UserDefaults = .standard) {
        self.store = store
        drawThings =
            store.data(forKey: Key.options(.drawThings))
            .flatMap { try? JSONDecoder().decode(DrawThingsConnection.self, from: $0) }
            ?? DrawThingsConnection()
    }
}
