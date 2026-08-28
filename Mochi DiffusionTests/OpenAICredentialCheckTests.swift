//
//  OpenAICredentialCheckTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins what the key check asks, and what it concludes from each answer.
///
/// The third outcome is the point of most of these: a check that reported every
/// non-200 as a bad key would tell an offline user their working key is wrong.
struct OpenAICredentialCheckTests {
    private func check(_ session: FakeHTTPSession) -> OpenAICredentialCheck {
        OpenAICredentialCheck(session: session)
    }

    @Test func acceptsAKeyTheServiceAnswersFor() async {
        let outcome = await check(FakeHTTPSession(statusCode: 200)).check("sk-test")
        #expect(outcome == .valid)
    }

    @Test(arguments: [401, 403])
    func rejectsAKeyTheServiceRefuses(status: Int) async {
        let outcome = await check(FakeHTTPSession(statusCode: status)).check("sk-test")
        #expect(outcome == .rejected)
    }

    /// A rate limit or an exhausted quota means the request authenticated, so it
    /// is neither verdict — and the service's own wording is what the user needs.
    @Test func reportsARateLimitAsNoVerdict() async {
        let session = FakeHTTPSession(
            statusCode: 429,
            body: [
                "{\"error\":{\"code\":\"insufficient_quota\","
                    + "\"message\":\"You're out of credits.\"}}"
            ]
        )
        #expect(await check(session).check("sk-test") == .unreachable("You're out of credits."))
    }

    /// Nothing parseable in the body, so the status code is all there is to say.
    @Test func fallsBackToTheStatusCode() async {
        let session = FakeHTTPSession(statusCode: 503, body: ["<html>nope</html>"])
        guard case .unreachable(let reason) = await check(session).check("sk-test") else {
            Issue.record("expected no verdict")
            return
        }
        #expect(reason.contains("503"))
    }

    /// Offline. The one case that must not read as a bad key.
    @Test func reportsATransportFailureAsNoVerdict() async {
        let session = FakeHTTPSession(
            failure: URLError(.notConnectedToInternet)
        )
        guard case .unreachable = await check(session).check("sk-test") else {
            Issue.record("expected no verdict")
            return
        }
    }

    /// No request spent on a key the service would certainly refuse.
    @Test(arguments: ["", "   \n "])
    func rejectsAnEmptyKeyWithoutAsking(key: String) async {
        let session = FakeHTTPSession(statusCode: 200)
        #expect(await check(session).check(key) == .rejected)
        #expect(session.lastRequest == nil)
    }

    @Test func asksTheModelsEndpointWithABearerToken() async {
        let session = FakeHTTPSession(statusCode: 200)
        _ = await check(session).check("  sk-test  ")

        let request = session.lastRequest
        #expect(request?.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request?.httpMethod == "GET")
        // Trimmed: a key pasted with a trailing newline is the key.
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request?.httpBody == nil)
    }
}
