import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class StubVerifier: ConversationEntryVerifying {
    var result: RequestConversationEligibility = .eligible
    var denied = false
    private(set) var verifyCalls = 0
    var gate: Gate?

    func verify(requestID: String, role: RequestConversationRole) async -> RequestConversationEligibility {
        verifyCalls += 1
        if let gate { await gate.wait() }
        return result
    }

    func isLocallyDenied(requestID: String, role: RequestConversationRole) -> Bool { denied }

    var actions = ConversationActionAvailability.none
    func availableActions(requestID: String, role: RequestConversationRole) -> ConversationActionAvailability { actions }
}

@MainActor
struct SessionRig {
    let session: RequestConversationSession
    let http: ScriptedHTTP
    let verifier: StubVerifier
    let authority: MsgAuthorityBox

    static func make(
        requestID: String = MsgFixture.requestId,
        role: RequestConversationRole = .requester,
        text: String = "PRIVATE-A",
        conversationId: String = MsgFixture.conversationId
    ) -> SessionRig {
        let http = ScriptedHTTP()
        http.defaultConversationId = conversationId
        http.defaultHistory = { _ in
            .success(MsgFixture.history([MsgFixture.message(1, text: text)]))
        }
        let authority = MsgAuthorityBox()
        let verifier = StubVerifier()
        let composition = RequestMessagingComposition.enabled { id, provider, rejected in
            ConversationCoordinator(
                requestId: id,
                http: http,
                socketTransport: nil,
                authorityProvider: provider,
                participantAuthorityRejected: rejected,
                scheduler: ManualScheduler()
            )
        }
        let coordinator = composition.makeCoordinator!(
            requestID, { authority.value }, { authority.rejectedCount += 1 }
        )
        return SessionRig(
            session: RequestConversationSession(
                requestID: requestID, role: role, coordinator: coordinator, verifier: verifier
            ),
            http: http, verifier: verifier, authority: authority
        )
    }

    var transcript: String { String(describing: session.coordinator.items) }
}

/// Request-bound conversation identity, state isolation and authorization loss.
/// These drive the real session/coordinator with scripted HTTP; none of it is
/// live-backend evidence (the routes are unmounted).
@MainActor
final class RequestConversationSessionTests: XCTestCase {
    func testBeginOpensOnlyThisRequestsConversationForBothRoles() async {
        for role in [RequestConversationRole.requester, .helper] {
            let rig = SessionRig.make(role: role)
            rig.session.begin(isForeground: true)
            await eventually("active") { rig.session.coordinator.phase == .active }
            XCTAssertEqual(rig.http.opens, 1)
            XCTAssertEqual(rig.session.requestID, MsgFixture.requestId)
            await eventually("history") { rig.transcript.contains("PRIVATE-A") }
            XCTAssertEqual(rig.session.state, .open)
        }
    }

    func testLocalDenialAtEntryNeverContactsTheConversationEndpoint() async {
        let rig = SessionRig.make()
        rig.verifier.denied = true
        rig.session.begin(isForeground: true)
        await settle()
        XCTAssertEqual(rig.session.state, .closed)
        XCTAssertEqual(rig.http.opens, 0)
        XCTAssertEqual(rig.session.coordinator.phase, .ended)
        XCTAssertTrue(rig.session.coordinator.items.isEmpty)
    }

    func testIneligibleVerificationAfterEntryPurgesTheTranscript() async {
        let rig = SessionRig.make()
        rig.verifier.result = .ineligible
        rig.session.begin(isForeground: true)
        await eventually("closed") { rig.session.state == .closed }
        XCTAssertTrue(rig.session.coordinator.items.isEmpty)
        XCTAssertFalse(rig.transcript.contains("PRIVATE-A"))
    }

    func testReplacementHelperGetsAFreshConversationAndNeverSeesPriorHistory() async {
        let first = SessionRig.make(text: "PRIVATE-A", conversationId: MsgFixture.conversationId)
        first.session.begin(isForeground: true)
        await eventually("first active") { first.session.coordinator.phase == .active }
        // Helper replaced: the server now refuses the old binding.
        first.verifier.denied = true
        first.session.relationshipStateChanged()
        XCTAssertEqual(first.session.state, .closed)

        let second = SessionRig.make(text: "NEW-B", conversationId: MsgFixture.otherConversationId)
        second.session.begin(isForeground: true)
        await eventually("second active") { second.session.coordinator.phase == .active }
        XCTAssertFalse(second.transcript.contains("PRIVATE-A"))
        XCTAssertTrue(second.transcript.contains("NEW-B"))
        XCTAssertFalse(first.transcript.contains("PRIVATE-A"))
        XCTAssertTrue(first.session.coordinator.items.isEmpty)
    }

    func testTwoRequestsHaveIsolatedCoordinators() async {
        let a = SessionRig.make(requestID: "64c0000000000000000000a1", text: "REQ-A")
        let b = SessionRig.make(requestID: "64c0000000000000000000a2", text: "REQ-B")
        a.session.begin(isForeground: true)
        b.session.begin(isForeground: true)
        await eventually("both active") {
            a.session.coordinator.phase == .active && b.session.coordinator.phase == .active
        }
        XCTAssertTrue(a.transcript.contains("REQ-A") && !a.transcript.contains("REQ-B"))
        XCTAssertTrue(b.transcript.contains("REQ-B") && !b.transcript.contains("REQ-A"))
        a.session.retire()
        XCTAssertTrue(a.session.coordinator.items.isEmpty)
        XCTAssertTrue(b.transcript.contains("REQ-B"))
    }

    func testBlockOrAuthorizationRevocationClosesAccessAndStaysClosed() async {
        let rig = SessionRig.make()
        rig.session.begin(isForeground: true)
        await eventually("active") { rig.session.coordinator.phase == .active }
        rig.verifier.denied = true
        rig.session.relationshipStateChanged()
        XCTAssertEqual(rig.session.state, .closed)
        XCTAssertTrue(rig.session.coordinator.items.isEmpty)
        // Block removed / reinstated: nothing reopens this session.
        rig.verifier.denied = false
        rig.verifier.result = .eligible
        rig.session.sceneDidBecomeActive()
        rig.session.retryVerification()
        await settle()
        XCTAssertEqual(rig.session.state, .closed)
        XCTAssertTrue(rig.session.coordinator.items.isEmpty)
        XCTAssertEqual(rig.http.opens, 1)
    }

    func testIdentityChangeClosesWithoutTranscript() async {
        let rig = SessionRig.make()
        rig.session.begin(isForeground: true)
        await eventually("active") { rig.session.coordinator.phase == .active }
        rig.session.identityChanged()
        XCTAssertEqual(rig.session.state, .closed)
        XCTAssertTrue(rig.session.coordinator.items.isEmpty)
    }

    func testResumeReverifiesBeforeAnyRefreshAndIneligibleDoesNotRestoreAuthorization() async {
        let rig = SessionRig.make()
        rig.session.begin(isForeground: true)
        await eventually("active") { rig.session.coordinator.phase == .active }
        let readsBefore = rig.http.reads.count
        rig.session.sceneDidEnterBackground()
        rig.verifier.result = .ineligible
        rig.session.sceneDidBecomeActive()
        await eventually("closed") { rig.session.state == .closed }
        XCTAssertEqual(rig.http.reads.count, readsBefore)
        XCTAssertTrue(rig.session.coordinator.items.isEmpty)
    }

    func testUnknownVerificationNeitherClosesNorResumes() async {
        let rig = SessionRig.make()
        rig.session.begin(isForeground: true)
        await eventually("active") { rig.session.coordinator.phase == .active }
        rig.session.sceneDidEnterBackground()
        rig.verifier.result = .unknown
        rig.session.sceneDidBecomeActive()
        await eventually("verification failed flag") { rig.session.verificationFailed }
        XCTAssertEqual(rig.session.state, .open)
        rig.verifier.result = .eligible
        rig.session.retryVerification()
        await eventually("recovered") { !rig.session.verificationFailed }
    }

    func testRetireDuringPendingVerificationDropsTheLateResult() async {
        let rig = SessionRig.make()
        let gate = Gate()
        rig.verifier.gate = gate
        rig.session.begin(isForeground: true)
        await eventually("verify started") { rig.verifier.verifyCalls == 1 }
        rig.session.retire()
        gate.open()
        await settle()
        XCTAssertEqual(rig.session.state, .closed)
        XCTAssertFalse(rig.session.verificationFailed)
    }
}
