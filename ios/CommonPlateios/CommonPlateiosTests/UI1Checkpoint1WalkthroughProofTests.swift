//
//  UI1Checkpoint1WalkthroughProofTests.swift
//  CommonPlateiosTests
//
// W4-UI1 Checkpoint 1 hosted-test renders and state checks for correction D.
// Production SwiftUI views are hosted in XCTest; verification requests and
// responses use stubbed transport. These tests do not exercise live email
// delivery, navigation to Home, or an app-process relaunch. Scenario D creates
// a new store over the same in-memory storage to check that unfinished flow
// state is not restored.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class UI1Checkpoint1WalkthroughProofTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    typealias Host = UI1Checkpoint1CorrectionsTests.Host

    private func makeIdentityStore(
        storage: InMemoryParticipantIdentityStorage? = nil,
        stored: ParticipantIdentityRecord? = nil
    ) -> (ParticipantIdentityStore, InMemoryParticipantIdentityStorage) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        let backingStorage = storage ?? InMemoryParticipantIdentityStorage(stored: stored)
        let store = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: backingStorage
        )
        return (store, backingStorage)
    }

    private func challengeResponse() -> Data {
        Data(#"""
        {"verification":{
          "expiresAt": "2026-07-28T16:10:00.000Z",
          "resendAvailableAt": "2026-07-28T16:01:00.000Z"
        }}
        """#.utf8)
    }

    private func errorResponse(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    private func redeemSuccessResponse(email: String) -> Data {
        // 24 lowercase-hex id + version 1 + a 43-char base64url signature
        // whose final character is in the canonical set — matches
        // ParticipantAuthorityShape.isCanonical exactly (see
        // ParticipantIdentityStorage.swift).
        let authority = "64c0000000000000000000a1.1." + String(repeating: "A", count: 43)
        return Data(#"""
        {"authority":"\#(authority)","participant":{"email":"\#(email)"}}
        """#.utf8)
    }

    // MARK: - Scenario (a): a fresh flow receives a stubbed cooldown response
    // and remains on email entry.

    func testScenarioA_freshFlowCooldownStaysOnEmailEntry() async throws {
        let (store, _) = makeIdentityStore()
        store.beginVerificationIfNeeded()
        let beforeHost = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        try beforeHost.captureBothAppearances(named: "hosted-stub-a1-before-first-cooldown-response")
        beforeHost.close()

        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 429, data: errorResponse(code: "VERIFICATION_RESEND_TOO_SOON"))
        )
        await store.requestCode(for: "freshstudent@nyu.edu")

        XCTAssertEqual(store.flow?.stage, .enteringEmail,
                        "Scenario A: a flow's first-ever attempt must stay on email entry, never jump to code entry for a code it never confirmed sending.")
        let afterHost = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        defer { afterHost.close() }
        try afterHost.captureBothAppearances(named: "hosted-stub-a2-after-cooldown-stays-on-email-entry")
    }

    // MARK: - Scenario (b): after stubbed issuance, a repeat attempt for the
    // same address receives a stubbed cooldown and reaches code entry.

    func testScenarioB_stubbedRepeatCooldownReachesCodeEntry() async throws {
        let (store, _) = makeIdentityStore()
        store.beginVerificationIfNeeded()

        // A stubbed successful response records this address as sent in this
        // flow, populating the store's confirmedCodeEmails set.
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await store.requestCode(for: "repeatstudent@nyu.edu")
        guard case .awaitingCode = store.flow?.stage else {
            return XCTFail("setup: first send should reach code entry")
        }

        // Return to email entry and resubmit the same address; the stubbed
        // cooldown response exercises the same-flow recovery path.
        store.returnToEmailEntry()
        let beforeHost = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        try beforeHost.captureBothAppearances(named: "hosted-stub-b1-before-same-flow-cooldown")
        beforeHost.close()

        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 429, data: errorResponse(code: "VERIFICATION_RESEND_TOO_SOON"))
        )
        await store.requestCode(for: "repeatstudent@nyu.edu")

        guard case .awaitingCode(let email, _, _)? = store.flow?.stage else {
            return XCTFail("Scenario B: a legitimate repeat for an address this flow already confirmed sending to must still reach code entry, not strand the student on email entry.")
        }
        XCTAssertEqual(email, "repeatstudent@nyu.edu")
        let afterHost = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        defer { afterHost.close() }
        try afterHost.captureBothAppearances(named: "hosted-stub-b2-after-same-flow-cooldown-reaches-code-entry")
    }

    // MARK: - Scenario (c): stubbed redemption reaches the verified store
    // state; this does not test Home routing.

    func testScenarioC_stubbedRedemptionReachesVerifiedStoreState() async throws {
        let (store, _) = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await store.requestCode(for: "newstudent@nyu.edu")
        let beforeHost = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        try beforeHost.captureBothAppearances(named: "hosted-stub-c1-before-code-submission")
        beforeHost.close()

        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 200, data: redeemSuccessResponse(email: "newstudent@nyu.edu"))
        )
        let succeeded = await store.submitCode("123456")

        XCTAssertTrue(succeeded, "Scenario C: a valid code must verify successfully")
        XCTAssertTrue(store.isVerified, "Scenario C: the store must reach the verified state that gates routing to Home")
        XCTAssertNil(store.flow, "Scenario C: a completed verification clears the in-progress flow")

        // Render the production verification view with the store's verified
        // state. This test does not instantiate ContentView or verify routing.
        let afterHost = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        defer { afterHost.close() }
        try afterHost.captureBothAppearances(named: "hosted-stub-c2-after-redemption-verified-store-state")
    }

    // MARK: - Scenario (d): a newly constructed store over the same in-memory
    // storage does not restore the unfinished verification flow.

    func testScenarioD_newStoreWithSharedInMemoryStorageDoesNotRestoreFlow() async throws {
        // Store A starts verification and receives a stubbed challenge, but
        // never submits a code.
        let (storeA, sharedStorage) = makeIdentityStore()
        storeA.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await storeA.requestCode(for: "interrupted@nyu.edu")
        guard case .awaitingCode = storeA.flow?.stage else {
            return XCTFail("setup: should be mid-flow awaiting a code before the simulated interruption")
        }
        XCTAssertFalse(storeA.isVerified, "setup: must not be verified before interruption")
        let beforeHost = try Host(ParticipantVerificationView(store: storeA, isRootGate: true))
        try beforeHost.captureBothAppearances(named: "hosted-stub-d1-before-new-store")
        beforeHost.close()

        // Construct a second store over the same in-memory storage. This
        // checks store re-instantiation only; it does not simulate app
        // termination, relaunch, or persistent storage.
        let storeB = ParticipantIdentityStore(
            service: ParticipantVerificationService(
                client: APIClient(
                    configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
                    session: URLSession(configuration: {
                        let c = URLSessionConfiguration.ephemeral
                        c.protocolClasses = [RequestFetchingURLProtocol.self]
                        return c
                    }())
                )
            ),
            storage: sharedStorage
        )

        XCTAssertFalse(storeB.isVerified,
                        "Scenario D: an interrupted, never-completed verification must not leave a new store verified — no identity bypass.")
        storeB.beginVerificationIfNeeded()
        XCTAssertEqual(storeB.flow?.stage, .enteringEmail,
                        "Scenario D: recovery presents the ordinary email-entry experience, not a stranded or fabricated state.")
        let afterHost = try Host(ParticipantVerificationView(store: storeB, isRootGate: true))
        defer { afterHost.close() }
        try afterHost.captureBothAppearances(named: "hosted-stub-d2-after-new-store-same-in-memory-storage")
    }
}
