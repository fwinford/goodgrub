//
//  AlertSignupEmailAlertsOffTransitionTests.swift
//  CommonPlateiosTests
//
// Independent-review regression coverage (W3-N2): `AlertSubscriptionStore`
// and `ParticipantEmailUnsubscribeStore` are separate state owners with no
// shared state, but `AlertSignupView` coordinates both on one screen. A
// stale in-session Off from a previous address must never be shown for a
// later, unrelated signup's truthful "check your email" presentation — the
// accepted contract's own words: "A later signup/reconfirmation returns to
// Check Your Email."
//
// SwiftUI view button closures are not directly reachable from XCTest, so
// this drives both stores exactly the way `AlertSignupView`'s
// `Use a different email` button does: `store.useDifferentEmail()` and
// `unsubscribeStore.reset()` together.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class AlertSignupEmailAlertsOffTransitionTests: XCTestCase {
    override func tearDown() {
        AlertSignupURLProtocol.reset()
        ParticipantEmailUnsubscribeURLProtocol.reset()
        super.tearDown()
    }

    private func makeSubscriptionStore() -> AlertSubscriptionStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlertSignupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return AlertSubscriptionStore(
            service: AlertSubscriptionService(client: client),
            presentationStorage: InMemoryAlertSignupPresentationStorage()
        )
    }

    private func makeUnsubscribeStore() -> ParticipantEmailUnsubscribeStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParticipantEmailUnsubscribeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return ParticipantEmailUnsubscribeStore(
            service: ParticipantEmailUnsubscribeService(client: client)
        )
    }

    private var acceptedBody: Data {
        Data(#"{"message":"If confirmation is needed, check your email for the next step."}"#.utf8)
    }

    private var unsubscribeSuccessBody: Data {
        Data(#"{"email":{"unsubscribed":true}}"#.utf8)
    }

    /// The exact sequence the independent review found reachable: sign up,
    /// confirm the participant-authorized Off, move on to a different
    /// address exactly the way the view's `Use a different email` button
    /// does, then submit the new address. The new signup's generic 202 must
    /// present as Check Your Email, never as a leftover Off from the address
    /// just left behind.
    func testUseDifferentEmailAfterOffReturnsANewSignupToCheckYourEmail() async {
        let store = makeSubscriptionStore()
        let unsubscribeStore = makeUnsubscribeStore()

        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "a@nyu.edu")
        XCTAssertEqual(store.phase, .checkEmail)

        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: unsubscribeSuccessBody))
        await unsubscribeStore.turnOffEmailAlerts(authority: "authority-credential")
        XCTAssertTrue(unsubscribeStore.emailAlertsOff)

        // What AlertSignupView's "Use a different email" button does.
        store.useDifferentEmail()
        unsubscribeStore.reset()
        XCTAssertFalse(unsubscribeStore.emailAlertsOff)
        XCTAssertEqual(store.phase, .editing)

        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "b@nyu.edu")

        XCTAssertEqual(store.phase, .checkEmail)
        XCTAssertFalse(
            unsubscribeStore.emailAlertsOff,
            "a later, unrelated signup must present Check Your Email, not a stale Off from the previous address"
        )
        XCTAssertNil(unsubscribeStore.failure)
    }

    /// The same reachable transition for reconfirming the *same* address:
    /// per the accepted contract, a later signup/reconfirmation returns to
    /// Check Your Email even when it is the identical address that was just
    /// turned off.
    func testResubmittingTheSameAddressAfterOffAlsoReturnsToCheckYourEmail() async {
        let store = makeSubscriptionStore()
        let unsubscribeStore = makeUnsubscribeStore()

        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "a@nyu.edu")

        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: unsubscribeSuccessBody))
        await unsubscribeStore.turnOffEmailAlerts(authority: "authority-credential")
        XCTAssertTrue(unsubscribeStore.emailAlertsOff)

        store.useDifferentEmail()
        unsubscribeStore.reset()

        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "a@nyu.edu")

        XCTAssertEqual(store.phase, .checkEmail)
        XCTAssertFalse(unsubscribeStore.emailAlertsOff)
    }

    /// Without the coordinated reset, a signup that never touched the
    /// unsubscribe action at all must never see Off either — the baseline
    /// this correction protects.
    func testAnOrdinarySignupNeverSeesEmailAlertsOffWithNoUnsubscribeAction() async {
        let store = makeSubscriptionStore()
        let unsubscribeStore = makeUnsubscribeStore()

        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "never-unsubscribed@nyu.edu")

        XCTAssertEqual(store.phase, .checkEmail)
        XCTAssertFalse(unsubscribeStore.emailAlertsOff)
    }
}
