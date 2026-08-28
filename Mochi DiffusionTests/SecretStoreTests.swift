//
//  SecretStoreTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the contract every `SecretStore` has to satisfy, and the fail-closed
/// default.
///
/// **`KeychainSecretStore` is deliberately not exercised here.** It writes to the
/// user's login keychain, which a test suite must not do, and a CI runner's
/// keychain may be locked, which would make the suite fail for reasons unrelated
/// to the code. Its behaviour was verified by hand against the framework instead,
/// and the two findings are recorded where they are relied on:
///
/// - `SecItemCopyMatching(query, nil)` with no return keys is a valid existence
///   check — `errSecItemNotFound` when absent, `errSecSuccess` when present, and
///   no secret returned either way. This is what makes `hasSecret(for:)` safe on
///   the discovery path.
/// - `kSecReturnAttributes: true` with `kSecReturnData: false` also works and
///   confirms `kSecValueData` is absent from the result, but returns a dictionary
///   to discard, so the simpler form is used.
///
/// Recorded as a known gap rather than papered over with a test that would prove
/// only that the double works.
struct SecretStoreTests {

    // MARK: - The fail-closed default

    /// `EngineSettings.secrets` defaults to this, so forgetting to inject the real
    /// store makes a hosted engine report "no key configured" rather than
    /// silently reaching into the keychain.
    @Test("The default store holds nothing")
    func noSecretStoreIsEmpty() {
        let store = NoSecretStore()

        #expect(!store.hasSecret(for: "openai"))
        #expect(store.secret(for: "openai") == nil)
    }

    @Test("The default store refuses writes rather than dropping them")
    func noSecretStoreRefusesWrites() {
        let store = NoSecretStore()

        // Throwing rather than silently succeeding: a write that went nowhere
        // would look to the user like a key they had saved.
        #expect(throws: SecretStoreError.unavailable) {
            try store.setSecret("sk-test", for: "openai")
        }
    }

    @Test("A fresh EngineSettings has no secrets")
    func engineSettingsDefaultsToNoSecrets() {
        let settings = EngineSettings(
            modelDirectory: URL(fileURLWithPath: "/models"),
            controlNetDirectory: URL(fileURLWithPath: "/controlnet")
        )

        #expect(!settings.secrets.hasSecret(for: "openai"))
    }

    // MARK: - The contract

    @Test("A stored secret is readable and reported present")
    func storeRoundTrips() throws {
        let store = InMemorySecretStore()

        try store.setSecret("sk-test", for: "openai")

        #expect(store.hasSecret(for: "openai"))
        #expect(store.secret(for: "openai") == "sk-test")
    }

    @Test("Accounts do not see each other's secrets")
    func accountsAreSeparate() throws {
        let store = InMemorySecretStore()

        try store.setSecret("sk-one", for: "openai")

        #expect(!store.hasSecret(for: "other-engine"))
        #expect(store.secret(for: "other-engine") == nil)
    }

    /// `nil` and empty both mean "remove". An empty string is what a user leaves
    /// behind after clearing the field, and storing it would make `hasSecret`
    /// answer true for a key that cannot authenticate anything.
    @Test("Clearing removes the secret", arguments: [nil, ""])
    func clearingRemoves(value: String?) throws {
        let store = InMemorySecretStore(["openai": "sk-test"])

        try store.setSecret(value, for: "openai")

        #expect(!store.hasSecret(for: "openai"))
        #expect(store.storedValue(for: "openai") == nil)
    }

    @Test("Storing again replaces the previous secret")
    func storeReplaces() throws {
        let store = InMemorySecretStore(["openai": "sk-old"])

        try store.setSecret("sk-new", for: "openai")

        #expect(store.storedValue(for: "openai") == "sk-new")
    }
}
