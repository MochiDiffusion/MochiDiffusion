//
//  SecretStore.swift
//  Mochi Diffusion
//

import Foundation
import Security
import os

/// Where an engine's credential lives.
///
/// A protocol because the real store writes to the user's login keychain, which
/// nothing but the app may do.
///
/// `hasSecret(for:)` and `secret(for:)` are separate deliberately: `availability`
/// runs on every discovery pass and must answer "is a key configured?" without
/// fetching the secret, since reading one can prompt.
nonisolated protocol SecretStore: Sendable {
    /// Whether a secret exists, without reading it.
    func hasSecret(for account: String) -> Bool
    /// The secret itself. Only generation and ``OpenAICredentialCheck`` need this;
    /// no caller may put the value into a view.
    func secret(for account: String) -> String?
    /// Stores, or removes when `secret` is `nil`.
    func setSecret(_ secret: String?, for account: String) throws
}

/// A store with nothing in it that cannot be written to: an engine whose key has
/// never been entered.
///
/// Never a default parameter, so every construction site has to choose a store.
nonisolated struct NoSecretStore: SecretStore {
    func hasSecret(for account: String) -> Bool { false }
    func secret(for account: String) -> String? { nil }
    func setSecret(_ secret: String?, for account: String) throws {
        throw SecretStoreError.unavailable
    }
}

nonisolated enum SecretStoreError: Error, Equatable {
    /// No real store was injected. A wiring bug, not a user-facing condition.
    case unavailable
    case keychain(OSStatus)
}

/// Generic-password items in the user's login keychain, one per engine.
nonisolated struct KeychainSecretStore: SecretStore {
    /// Fixed rather than derived from the bundle identifier, so debug and release
    /// builds read the same item and a rename cannot orphan a stored key.
    static let defaultService = "MochiDiffusion.EngineSecrets"

    private let service: String
    private let logger = Logger()

    init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    /// Asks only whether the item exists: no return keys and a `nil` result
    /// pointer, so the Keychain hands back a status and no data.
    func hasSecret(for account: String) -> Bool {
        var query = baseQuery(for: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("Keychain lookup for \(account) failed: \(status)")
        }
        return status == errSecSuccess
    }

    func secret(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.error("Keychain read for \(account) failed: \(status)")
            }
            return nil
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ secret: String?, for account: String) throws {
        guard let secret, !secret.isEmpty else {
            let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status)
            }
            return
        }

        let data = Data(secret.utf8)
        // Update first, add second. The reverse order would need the caller to
        // know whether a key is already there, which is exactly what the
        // existence check is meant to keep off this path.
        let update = SecItemUpdate(
            baseQuery(for: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }

        var item = baseQuery(for: account)
        item[kSecValueData as String] = data
        // An API key is needed only while the app is in use, and this keeps it out
        // of a backup restored onto another machine.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
