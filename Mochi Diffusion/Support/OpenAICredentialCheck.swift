//
//  OpenAICredentialCheck.swift
//  Mochi Diffusion
//

import Foundation

/// Asks OpenAI whether a key is live.
///
/// A request rather than a shape check. The key format has changed more than once,
/// so a regex can only reject keys that would have worked while still accepting
/// keys that have been revoked. `GET /v1/models` costs nothing and answers the
/// question that matters: 200 or 401.
///
/// Not part of ``OpenAIImageEngine``. `GenerationEngineDescriptor` describes models
/// and plans requests; authentication there would oblige every local engine to
/// answer a question it does not have. Note that
/// ``OpenAIImageEngine/discoverModels(_:)`` declines this same endpoint for its own
/// purpose — it cannot say which models generate images. It can say who is calling.
nonisolated struct OpenAICredentialCheck: Sendable {
    private static let endpoint = URL(string: "https://api.openai.com/v1/models")!

    /// How long to wait for a verdict. Short, because this blocks a sheet's
    /// primary button, and an answer that has not arrived by then is better
    /// reported as "could not check" than waited on.
    private static let timeout: TimeInterval = 15

    /// A verdict is not the only outcome.
    ///
    /// `unreachable` exists so that "we could not ask" is never presented as "your
    /// key is wrong": someone offline still gets to store a key.
    enum Outcome: Equatable, Sendable {
        case valid
        /// The service refused it: revoked, mistyped, or from another account.
        case rejected
        /// No verdict, and what stood in the way.
        case unreachable(String)
    }

    private let session: any HTTPSession

    init(session: any HTTPSession = URLSessionHTTPSession()) {
        self.session = session
    }

    func check(_ key: String) async -> Outcome {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Not `unreachable`: an empty key is one the service would refuse, and
        // there is no reason to spend a request finding that out.
        guard !trimmed.isEmpty else { return .rejected }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.timeout

        do {
            let (response, lines) = try await session.lines(for: request)
            switch response.statusCode {
            case 200:
                // The body is the account's entire model list and nothing here
                // reads it. Dropping the stream cancels the transfer.
                return .valid
            case 401, 403:
                return .rejected
            default:
                // Everything else, 429 included: throttling and an exhausted
                // quota share that code, and both mean the request did
                // authenticate, so calling it valid or rejected would be a
                // guess. Report what the service said instead.
                return .unreachable(
                    await Self.message(from: lines, status: response.statusCode)
                )
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// Prefers the service's own wording, which is more specific than a status
    /// code and the thing the user has to act on.
    private static func message(
        from lines: AsyncThrowingStream<String, any Error>,
        status: Int
    ) async -> String {
        var body = ""
        do {
            for try await line in lines { body += line }
        } catch {
            // Keep whatever arrived. The status code is the more useful signal
            // and must not be lost to a read failure.
        }
        if let message = OpenAIEngineRuntime.errorFields(in: body).message {
            return message
        }
        return String(
            localized: "OpenAI returned \(status).",
            comment: "Fallback when checking an API key gets an unexpected status code"
        )
    }
}
