//
//  HTTPSession.swift
//  Mochi Diffusion
//

import Foundation

/// The network, narrowed to what a streaming hosted engine needs.
///
/// Lines rather than bytes, because a server-sent-event body is line-oriented.
/// A protocol so a runtime can be exercised without making a request.
nonisolated protocol HTTPSession: Sendable {
    func lines(
        for request: URLRequest
    ) async throws -> (response: HTTPURLResponse, lines: AsyncThrowingStream<String, any Error>)
}

nonisolated struct URLSessionHTTPSession: HTTPSession {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func lines(
        for request: URLRequest
    ) async throws -> (response: HTTPURLResponse, lines: AsyncThrowingStream<String, any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.malformedResponse
        }

        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the consumer has to stop the transfer, or a cancelled
            // generation would keep downloading in the background.
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, lines)
    }
}
