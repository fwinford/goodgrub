//
//  CP2VerificationActionHierarchyHostedTests.swift
//  CommonPlateiosTests
//
// CP2 refinement of the code-entry actions: Verify stays the only filled
// action, Send a new code is the outlined secondary, and Use a different
// email is a quiet tertiary link set apart below. Hosted production view
// with stubbed transport; captures Light and Dark with a typed code so
// Verify is in its enabled state.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class CP2VerificationActionHierarchyHostedTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testCodeEntryActionsCaptureWithVerifyEnabled() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 202,
            data: challengeResponse(resendAvailableAt: Date().addingTimeInterval(60))
        ))
        await store.requestCode(for: "student@nyu.edu")

        let host = try UI1Checkpoint1CorrectionsTests.Host(
            ParticipantVerificationView(store: store, isRootGate: true)
        )
        defer { host.close() }

        let field = try XCTUnwrap(
            textField(placeholder: "6-digit code", in: host.controller.view),
            "The production code field must be present."
        )
        field.text = "123456"
        field.sendActions(for: .editingChanged)
        host.settle(0.4)

        // Source order (code -> Verify -> resend -> change email) is proven by
        // ParticipantVerificationHierarchyTests; SwiftUI does not vend its
        // accessibility tree to hosted unit tests, so this records evidence.
        XCTAssertEqual(field.text, "123456")

        try host.captureBothAppearances(named: "cp2-verification-code-entered-actions")
    }

    func testUnavailableCodeRequestIsVisibleOnEmailEntry() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 503,
            data: Data(
                #"{"error":{"code":"VERIFICATION_UNAVAILABLE","message":"Unavailable","fields":null}}"#.utf8
            )
        ))
        await store.requestCode(for: "student@nyu.edu")

        let host = try UI1Checkpoint1CorrectionsTests.Host(
            ParticipantVerificationView(store: store, isRootGate: true)
        )
        defer { host.close() }

        let status = try XCTUnwrap(
            accessibilityElement(
                identifier: "participant-verification-error",
                in: host.window
            )
        )
        XCTAssertTrue(
            (status.value(forKey: "accessibilityLabel") as? String)?
                .contains("We couldn’t verify your email right now") == true
        )
        try host.captureBothAppearances(named: "cp2-verification-unavailable-error")
    }

    private func textField(placeholder: String, in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.placeholder == placeholder { return field }
        for subview in view.subviews {
            if let field = textField(placeholder: placeholder, in: subview) { return field }
        }
        return nil
    }

    private func accessibilityElement(identifier: String, in root: NSObject) -> NSObject? {
        if (root.value(forKey: "accessibilityIdentifier") as? String) == identifier {
            return root
        }
        for child in root.accessibilityElements ?? [] {
            if let child = child as? NSObject,
               let found = accessibilityElement(identifier: identifier, in: child) {
                return found
            }
        }
        if let view = root as? UIView {
            for subview in view.subviews {
                if let found = accessibilityElement(identifier: identifier, in: subview) {
                    return found
                }
            }
        }
        return nil
    }

    private func makeIdentityStore() -> ParticipantIdentityStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: InMemoryParticipantIdentityStorage()
        )
    }

    private func challengeResponse(resendAvailableAt: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: resendAvailableAt.addingTimeInterval(9 * 60))
        let resendDate = formatter.string(from: resendAvailableAt)
        return Data(
            #"{"verification":{"expiresAt":"\#(expiresAt)","resendAvailableAt":"\#(resendDate)"}}"#.utf8
        )
    }
}
