import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// W3-I3: participant verification's primary actions must be discoverable
/// without reading explanatory copy first. Without `ViewInspector` in this
/// target, this suite proves the accepted ordering by reading the view's own
/// tracked source — matching the source-inspection pattern already used
/// elsewhere in `CommonPlateiosTests` — rather than pinning incidental
/// SwiftUI formatting. Each assertion is scoped to the one section
/// declaration it is actually about, not the whole file, so an unrelated
/// identifier appearing earlier elsewhere in the source cannot produce a
/// false pass.
final class ParticipantVerificationHierarchyTests: XCTestCase {
    /// The accepted email-section hierarchy: the field and its action lead;
    /// the standing eligibility/purpose/replacement/revoked explanation comes
    /// after, not before.
    func testEmailSectionPutsTheFieldAndSendCodeBeforeSupportingExplanation() throws {
        let section = try declarationSource(
            startMarker: "private var emailSection: some View {",
            endMarker: "private func codeSection(address: String, resendAvailableAt: Date) -> some View {"
        )

        let fieldRange = try requiredRange(of: "participant-verification-email", in: section)
        let sendRange = try requiredRange(of: "participant-verification-send", in: section)
        let lifetimeRange = try requiredRange(of: "participant-verification-code-lifetime", in: section)

        // W4-B1 ruling: "Codes expire after 10 minutes." sits between the
        // title and the field, and the permanent eligibility caption is gone.
        XCTAssertLessThan(lifetimeRange.lowerBound, fieldRange.lowerBound)
        XCTAssertLessThan(fieldRange.lowerBound, sendRange.lowerBound)
        XCTAssertNil(section.range(of: "participant-verification-eligibility"))
    }

    /// The accepted code-section hierarchy: the code field, Verify, and
    /// resend are the actionable controls and appear in that order. This
    /// makes no claim about the code-sent notice, which the production view
    /// deliberately places before the code field to say what to type next —
    /// that placement is unaffected by, and not part of, this slice's
    /// action-first hierarchy.
    func testCodeSectionOrdersCodeFieldVerifyThenResend() throws {
        let section = try declarationSource(
            startMarker: "private func codeSection(address: String, resendAvailableAt: Date) -> some View {",
            endMarker: "static func canSendCode(email: String, isRequesting: Bool) -> Bool {"
        )

        let codeFieldRange = try requiredRange(of: "participant-verification-code", in: section)
        let verifyRange = try requiredRange(of: "participant-verification-submit", in: section)
        let resendRange = try requiredRange(of: "participant-verification-resend", in: section)

        XCTAssertLessThan(codeFieldRange.lowerBound, verifyRange.lowerBound)
        XCTAssertLessThan(verifyRange.lowerBound, resendRange.lowerBound)
    }

    func testErrorsAreBelowFieldAndAboveThePrimaryActionOnBothSteps() throws {
        let email = try declarationSource(
            startMarker: "private var emailSection: some View {",
            endMarker: "private func codeSection(address: String, resendAvailableAt: Date) -> some View {"
        )
        // Both steps place errors beneath the field so the field sits in the same spot.
        XCTAssertLessThan(
            try requiredRange(of: "TextField(Self.emailPlaceholder", in: email).lowerBound,
            try requiredRange(of: "verificationError(isFieldError: true)", in: email).lowerBound
        )
        let code = try declarationSource(
            startMarker: "private func codeSection(address: String, resendAvailableAt: Date) -> some View {",
            endMarker: "private var codeFieldError:"
        )
        let field = try requiredRange(of: "participant-verification-code", in: code)
        let error = try requiredRange(of: "participant-verification-error", in: code)
        let verify = try requiredRange(of: "participant-verification-submit", in: code)
        let resend = try requiredRange(of: "participant-verification-resend\"", in: code)
        let resendError = try requiredRange(of: "participant-verification-resend-error", in: code)
        XCTAssertLessThan(field.lowerBound, error.lowerBound)
        XCTAssertLessThan(error.lowerBound, verify.lowerBound)
        XCTAssertLessThan(resend.lowerBound, resendError.lowerBound)
        XCTAssertFalse(code.contains("CommonPlateInlineStatus"))
    }

    func testServiceProblemsAreNotPresentedAsInvalidInput() {
        for error: ParticipantVerificationPresentationError in [
            .temporarilyUnavailable, .resendTooSoon, .replacementBlocked
        ] {
            XCTAssertFalse(ParticipantVerificationView.isFieldError(error))
        }
        for error: ParticipantVerificationPresentationError in [
            .ineligibleEmail, .codeIncorrect, .codeExpired, .codeNotRequested, .attemptsExceeded
        ] {
            XCTAssertTrue(ParticipantVerificationView.isFieldError(error))
        }
    }

    func testCodeKeepsSingleAutofillFieldAndAccessibleLabel() throws {
        let section = try declarationSource(
            startMarker: "private func codeSection(address: String, resendAvailableAt: Date) -> some View {",
            endMarker: "static func isFieldError("
        )
        XCTAssertEqual(section.components(separatedBy: "TextField(").count - 1, 1)
        XCTAssertTrue(section.contains(".textContentType(.oneTimeCode)"))
        XCTAssertFalse(section.contains(".tracking("))
        XCTAssertFalse(section.contains(".font(.title2"))
        XCTAssertTrue(section.contains(".accessibilityLabel(\"6-digit verification code\")"))
        XCTAssertTrue(section.contains("CommonPlateStyle.Color.requestCardSurface"))
    }

    func testCodeAndEmailUseIdenticalFieldGeometryAndConditionalErrors() throws {
        let email = try declarationSource(
            startMarker: "private var emailSection: some View {",
            endMarker: "private func codeSection(address: String, resendAvailableAt: Date) -> some View {"
        )
        let code = try declarationSource(
            startMarker: "private func codeSection(address: String, resendAvailableAt: Date) -> some View {",
            endMarker: "static func isFieldError("
        )
        for geometry in [
            ".padding(.horizontal, CommonPlateStyle.Spacing.m)",
            ".padding(.vertical, 12)",
            "CommonPlateStyle.Radius.standard",
            "lineWidth: 1"
        ] {
            XCTAssertTrue(email.contains(geometry))
            XCTAssertTrue(code.contains(geometry))
        }
        XCTAssertFalse(code.contains("error?.message ?? \" \""), "no blank reserved line shifts the primary action")
        XCTAssertTrue(code.contains("if !lastCodeActionWasResend, let error = store.verificationError"))
        XCTAssertTrue(code.contains(".accessibilityHint(codeFieldError?.message ?? \"\")"))
        XCTAssertTrue(code.contains("CommonPlateStyle.Color.destructiveBorder"))
        XCTAssertTrue(code.contains(".frame(maxWidth: .infinity, minHeight: 44)"), "secondary actions centered like Not at NYU?")
        XCTAssertTrue(code.contains(".commonPlatePrimaryAction()"))
    }

    func testDestinationCopyIsConcise() {
        // W4-UI1 Checkpoint 1 (C, Faith 2026-10-23): shortened to exactly
        // "Code sent to [verified destination email]."
        XCTAssertEqual(ParticipantVerificationView.codeSentNotice(email: "test@nyu.edu"),
                       "Code sent to test@nyu.edu.")
    }

    @MainActor
    func testRenderedCodeInputDoesNotExceedEmailInputAtStandardAndAccessibilitySizes() async throws {
        defer { RequestFetchingURLProtocol.reset() }
        for size: DynamicTypeSize in [.large, .accessibility3] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RequestFetchingURLProtocol.self]
            let store = ParticipantIdentityStore(
                service: ParticipantVerificationService(client: APIClient(
                    configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
                    session: URLSession(configuration: configuration)
                )),
                storage: InMemoryParticipantIdentityStorage()
            )
            store.beginVerificationIfNeeded()
            let host = UIHostingController(rootView:
                ParticipantVerificationView(store: store, isRootGate: true)
                    .environment(\.dynamicTypeSize, size)
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }

            func field(in view: UIView) -> UITextField? {
                if let input = view as? UITextField { return input }
                return view.subviews.lazy.compactMap { field(in: $0) }.first
            }
            func element(_ identifier: String, in root: NSObject) -> NSObject? {
                if (root.value(forKey: "accessibilityIdentifier") as? String) == identifier { return root }
                for child in root.accessibilityElements ?? [] {
                    if let child = child as? NSObject, let found = element(identifier, in: child) { return found }
                }
                if let view = root as? UIView {
                    for subview in view.subviews { if let found = element(identifier, in: subview) { return found } }
                }
                return nil
            }
            func measuredInput(placeholder: String, action: String) async throws -> (CGRect, CGRect) {
                for _ in 0..<40 {
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    if let input = field(in: host.view), input.placeholder == placeholder,
                       input.bounds.height > 0,
                       let button = element(action, in: window), button.accessibilityFrame.height > 0 {
                        return (input.convert(input.bounds, to: window), button.accessibilityFrame)
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw NSError(domain: "VerificationInputNotRendered", code: 1)
            }
            let (emailFrame, sendFrame) = try await measuredInput(
                placeholder: ParticipantVerificationView.emailPlaceholder,
                action: "participant-verification-send"
            )
            let emailSize = emailFrame.size
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data(
                #"{"verification":{"expiresAt":"2026-10-23T15:00:00.000Z","resendAvailableAt":"2026-10-23T14:51:00.000Z"}}"#.utf8
            )))
            await store.requestCode(for: "test@nyu.edu")
            await Task.yield()
            let (codeFrame, verifyFrame) = try await measuredInput(
                placeholder: "6-digit code",
                action: "participant-verification-submit"
            )
            let codeSize = codeFrame.size
            XCTAssertEqual(verifyFrame.minY - codeFrame.maxY, sendFrame.minY - emailFrame.maxY, accuracy: 0.5,
                           "field-to-primary-action gap must match on both steps (\(size))")
            XCTAssertEqual(verifyFrame.height, sendFrame.height, accuracy: 0.5, "\(size)")
            if size == .large {
                XCTAssertEqual(codeFrame.minY, emailFrame.minY, accuracy: 0.5,
                               "single-line description keeps the field in the same place")
            }
            XCTAssertEqual(codeSize.height, emailSize.height, accuracy: 0.5, "\(size)")
            XCTAssertEqual(codeSize.width, emailSize.width, accuracy: 0.5, "\(size)")
        }
    }

    private func requiredRange(of identifier: String, in source: String) throws -> Range<String.Index> {
        try XCTUnwrap(
            source.range(of: identifier),
            "expected to find \(identifier)"
        )
    }

    /// Extracts one declaration's own source text — from `startMarker` up to
    /// (not including) `endMarker` — so an assertion about one section cannot
    /// be satisfied or defeated by unrelated content elsewhere in the file.
    private func declarationSource(startMarker: String, endMarker: String) throws -> String {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
            ),
            encoding: .utf8
        )

        guard let startRange = source.range(of: startMarker) else {
            XCTFail("expected to find \(startMarker)")
            return ""
        }
        guard let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find \(endMarker) after \(startMarker)")
            return ""
        }

        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Walks up from this file to the repository root, so the source-text
    /// assertions above read the real tracked file rather than a copy.
    private func repositoryFile(_ relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "expected \(relativePath) at \(url.path)"
        )
        return url
    }
}
