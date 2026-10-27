import XCTest
@testable import CommonPlateios

/// W4-B1 active-activity gate for Change Email: eligibility preflight, blocked
/// start/redeem, fail-closed reads, identity preservation, and first-time
/// verification staying credential-free.
@MainActor
final class B1EmailReplacementGateTests: XCTestCase {
    private let principal = "taylor@nyu.edu"
    private let eligibilityPath = "/api/participant/email-replacement-eligibility"

    override func setUp() {
        super.setUp()
        RequestFetchingURLProtocol.reset()
    }

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Preflight

    func testNoActivityOpensTheFlowAndSendsTheCredentialOnlyOnTheRead() async {
        let (store, _) = makeVerifiedStore()
        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(true, [])))

        await store.startEmailReplacement()

        XCTAssertEqual(store.flow?.purpose, .emailReplacement)
        XCTAssertNil(store.replacementBlock)
        XCTAssertFalse(store.replacementCheckFailed)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [eligibilityPath])
        XCTAssertEqual(
            header("x-commonplate-participant"),
            canonicalParticipantAuthorityFixture
        )
    }

    func testEachBlockerKeepsTheIdentityAndDoesNotOpenTheFlow() async {
        for reason in ["ownRequestOpen", "ownRequestHelped", "helping"] {
            RequestFetchingURLProtocol.reset()
            let (store, storage) = makeVerifiedStore()
            RequestFetchingURLProtocol.enqueue(.response(data: eligibility(false, [reason])))

            await store.startEmailReplacement()

            XCTAssertNil(store.flow, reason)
            XCTAssertEqual(store.replacementBlock?.blockers.map(\.rawValue), [reason])
            XCTAssertEqual(store.identity?.principal, principal, reason)
            XCTAssertEqual(storage.stored?.authority, canonicalParticipantAuthorityFixture, reason)
            // Read-only: exactly the one eligibility GET, nothing else.
            XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [eligibilityPath], reason)
        }
    }

    func testAnUnreadableEligibilityFailsClosed() async {
        let failures: [RequestFetchingURLProtocol.Stub] = [
            .failure(.notConnectedToInternet),
            .response(statusCode: 503, data: errorBody("VERIFICATION_UNAVAILABLE")),
            .response(statusCode: 200, data: Data("not json".utf8)),
            // Contradictory: eligible yet naming a blocker.
            .response(data: eligibility(true, ["helping"]))
        ]
        for stub in failures {
            RequestFetchingURLProtocol.reset()
            let (store, storage) = makeVerifiedStore()
            RequestFetchingURLProtocol.enqueue(stub)

            await store.startEmailReplacement()

            XCTAssertNil(store.flow)
            XCTAssertTrue(store.replacementCheckFailed)
            XCTAssertNil(store.replacementBlock)
            XCTAssertEqual(store.identity?.principal, principal)
            XCTAssertNotNil(storage.stored)
        }
    }

    func testIneligibleWithAnUnrecognizedReasonIsStillBlocked() async {
        let (store, _) = makeVerifiedStore()
        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(false, ["somethingNew"])))

        await store.startEmailReplacement()

        XCTAssertNil(store.flow)
        XCTAssertEqual(store.replacementBlock, EmailReplacementBlock(blockers: []))
    }

    func testDismissingTheNoticeClearsItAndChangesNothingElse() async {
        let (store, _) = makeVerifiedStore()
        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(false, ["helping"])))
        await store.startEmailReplacement()

        store.dismissReplacementNotice()

        XCTAssertNil(store.replacementBlock)
        XCTAssertFalse(store.replacementCheckFailed)
        XCTAssertEqual(store.identity?.principal, principal)
    }

    // MARK: - Activity appearing during the flow

    func testABlockedStartClosesTheFlowAndKeepsTheIdentity() async {
        let (store, storage) = makeVerifiedStore()
        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(true, [])))
        await store.startEmailReplacement()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 409, data: blockedBody(["ownRequestOpen"])))
        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(false, ["ownRequestOpen"])))

        await store.requestCode(for: "new@nyu.edu")

        XCTAssertNil(store.flow)
        XCTAssertEqual(store.replacementBlock?.blockers, [.ownRequestOpen])
        XCTAssertEqual(store.identity?.principal, principal)
        XCTAssertEqual(storage.stored?.authority, canonicalParticipantAuthorityFixture)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.suffix(2),
            ["/api/participant/verification", eligibilityPath]
        )
    }

    func testActivityAppearingBeforeRedeemRefusesAndKeepsTheOldIdentity() async {
        let (store, storage) = makeVerifiedStore()
        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(true, [])))
        await store.startEmailReplacement()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challenge()))
        await store.requestCode(for: "new@nyu.edu")
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 409, data: blockedBody(["helping"])))
        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(false, ["helping"])))

        let adopted = await store.submitCode("123456")

        XCTAssertFalse(adopted)
        XCTAssertNil(store.flow)
        XCTAssertEqual(store.replacementBlock?.blockers, [.helping])
        XCTAssertEqual(store.identity?.principal, principal)
        XCTAssertEqual(storage.stored?.principal, principal)
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
    }

    func testABlockedRedeemWhoseBlockerReadFailsStillBlocksGenerally() async {
        let (store, _) = makeVerifiedStore()
        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(true, [])))
        await store.startEmailReplacement()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challenge()))
        await store.requestCode(for: "new@nyu.edu")
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 409, data: blockedBody(["helping"])))
        RequestFetchingURLProtocol.enqueue(.failure(.timedOut))

        _ = await store.submitCode("123456")

        XCTAssertEqual(store.replacementBlock, EmailReplacementBlock(blockers: []))
        XCTAssertEqual(store.identity?.principal, principal)
    }

    func testReplacementRequestsCarryTheCurrentCredentialAndSuccessReplacesIt() async {
        let (store, _) = makeVerifiedStore()
        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(true, [])))
        await store.startEmailReplacement()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challenge()))
        await store.requestCode(for: "new@nyu.edu")
        XCTAssertEqual(header("x-commonplate-participant"), canonicalParticipantAuthorityFixture)

        RequestFetchingURLProtocol.enqueue(.response(data: verified("new@nyu.edu")))
        let adopted = await store.submitCode("123456")

        XCTAssertTrue(adopted)
        XCTAssertEqual(header("x-commonplate-participant"), canonicalParticipantAuthorityFixture)
        XCTAssertEqual(store.identity?.principal, "new@nyu.edu")
    }

    // MARK: - First-time verification unaffected

    func testFirstTimeVerificationSendsNoCredentialAndNeverReadsEligibility() async {
        let storage = InMemoryParticipantIdentityStorage()
        let store = makeStore(storage: storage)
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challenge()))
        await store.requestCode(for: principal)
        XCTAssertNil(header("x-commonplate-participant"))

        RequestFetchingURLProtocol.enqueue(.response(data: verified(principal)))
        let adopted = await store.submitCode("123456")

        XCTAssertTrue(adopted)
        XCTAssertNil(header("x-commonplate-participant"))
        XCTAssertFalse(RequestFetchingURLProtocol.capturedRequestedPaths.contains(eligibilityPath))
    }

    func testWithoutAnIdentityTheReplacementEntryDoesNothing() async {
        let store = makeStore(storage: InMemoryParticipantIdentityStorage())

        await store.startEmailReplacement()

        XCTAssertNil(store.flow)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
    }

    // MARK: - Notice content

    func testNoticeContentMatchesTheApprovedActionsAndNeverMutates() {
        func content(_ blockers: [EmailReplacementBlocker]) -> EmailReplacementNoticeContent {
            EmailReplacementNoticeContent.content(for: EmailReplacementBlock(blockers: blockers))
        }
        XCTAssertEqual(content([.ownRequestOpen]).primaryActionTitle, "View Request")
        XCTAssertEqual(content([.helping]).primaryActionTitle, "View Helping")
        XCTAssertEqual(content([.ownRequestHelped]).primaryActionTitle, "View Request")
        XCTAssertEqual(content([.helping, .ownRequestOpen]).title, "Finish your requests and helping")
        XCTAssertEqual(content([.helping]).title, "Currently helping")
        XCTAssertEqual(content([]).title, "Can’t change your email yet")
        XCTAssertFalse(content([]).message.lowercased().contains("request"))
        XCTAssertFalse(content([]).message.lowercased().contains("helping"))
        XCTAssertEqual(EmailReplacementNoticeContent.unavailable.title, "Couldn’t check your activity")
        XCTAssertEqual(EmailReplacementNoticeContent.unavailable.primaryActionTitle, "Try Again")
        XCTAssertTrue(EmailReplacementNoticeContent.unavailable.isRetry)
        XCTAssertFalse(content([.helping]).isRetry)
        XCTAssertEqual(EmailReplacementNoticeContent.dismissTitle, "Keep My Email")
    }

    func testSignOutReusesTheNoticeWithItsOwnCopyAndStaysFailClosed() throws {
        XCTAssertEqual(EmailReplacementNoticeContent.signOutHelping.title, "Currently helping")
        XCTAssertEqual(EmailReplacementNoticeContent.signOutHelping.primaryActionTitle, "View Helping")
        XCTAssertEqual(EmailReplacementNoticeContent.signOutRequestUnconfirmed.title, "Request still being confirmed")
        XCTAssertTrue(EmailReplacementNoticeContent.signOutUnchecked.isRetry)
        XCTAssertEqual(EmailReplacementNoticeContent.signOutUnchecked.primaryActionTitle, "Try Again")
        for c in [EmailReplacementNoticeContent.signOutHelping, .signOutRequestUnconfirmed, .signOutUnchecked] {
            XCTAssertEqual(c.dismissTitle, "Stay Signed In")
        }
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("guard isRemoveEmailBlocked else { return nil }"))
        XCTAssertTrue(source.contains("participantIdentityStore.currentAuthority() == nil"))
        XCTAssertFalse(source.contains("Sign Out is temporarily unavailable"))
    }

    func testReplacementEntryScreenNoLongerCarriesTheConsequenceParagraph() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/ParticipantVerificationView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("keeps working until the new one is verified"))
        XCTAssertTrue(source.contains("codeLifetimeNotice"))
    }

    // MARK: - Fixtures

    private func header(_ name: String) -> String? {
        RequestFetchingURLProtocol.lastCapturedHeaders?
            .first { $0.key.lowercased() == name }?.value
    }

    private func makeVerifiedStore() -> (ParticipantIdentityStore, InMemoryParticipantIdentityStorage) {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        return (makeStore(storage: storage), storage)
    }

    private func makeStore(storage: ParticipantIdentityStorage) -> ParticipantIdentityStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        let store = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: storage
        )
        store.configureInstallationAssociation { _ in }
        return store
    }

    func testNavigationFallsBackToHomeWhenDestinationIsUnavailableOrAmbiguous() {
        for blockers in [
            [EmailReplacementBlocker.helping],
            [.ownRequestOpen],
            [.ownRequestHelped],
            [.ownRequestOpen, .ownRequestHelped],
            [.helping, .ownRequestOpen],
            []
        ] {
            XCTAssertEqual(
                EmailReplacementNavigation.path(
                    for: EmailReplacementBlock(blockers: blockers),
                    activeClaim: nil,
                    ownerRequests: []
                ),
                [],
                "\(blockers) with no loaded destination must be Home, never a guess"
            )
        }
    }

    func testRetryAfterAFailedCheckIsAFreshReadOnlyCheckThatKeepsTheIdentity() async {
        let (store, storage) = makeVerifiedStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.startEmailReplacement()
        XCTAssertTrue(store.replacementCheckFailed)

        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.startEmailReplacement()
        XCTAssertTrue(store.replacementCheckFailed, "still unreadable: remains fail-closed")
        XCTAssertNil(store.flow)

        RequestFetchingURLProtocol.enqueue(.response(data: eligibility(true, [])))
        await store.startEmailReplacement()
        XCTAssertFalse(store.replacementCheckFailed)
        XCTAssertEqual(store.flow?.purpose, .emailReplacement)
        XCTAssertEqual(store.identity?.principal, principal)
        XCTAssertNotNil(storage.stored)
    }

    func testNoticeSecondaryActionUsesTheSharedStyleAndTheHeaderUsesOneRow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        let notice = try String(
            contentsOf: root.appendingPathComponent("Views/EmailReplacementNoticeView.swift"), encoding: .utf8
        )
        XCTAssertTrue(notice.contains(".commonPlateSecondaryAction()"))
        XCTAssertFalse(notice.contains("commonPlateTertiaryAction"))
        XCTAssertFalse(notice.contains("Color(red"))
        XCTAssertTrue(notice.contains("noticeFirstLineCenter"))
        let styles = try String(
            contentsOf: root.appendingPathComponent("Design/CommonPlateButtonStyles.swift"), encoding: .utf8
        )
        XCTAssertEqual(styles.components(separatedBy: "commonPlateSecondaryActionSurface(isEnabled:").count - 1, 3,
                       "one definition and the standard and major secondary styles")
    }

    func testSharedCloseControlIsUsedByEveryB1Screen() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Views")
        // UnsupportedSchoolView deliberately has no close control (CP2).
        for file in ["ParticipantVerificationView", "EmailReplacementNoticeView"] {
            let source = try String(contentsOf: root.appendingPathComponent("\(file).swift"), encoding: .utf8)
            XCTAssertTrue(source.contains("CommonPlateScreenCloseControl("), file)
        }
    }

    private func eligibility(_ eligible: Bool, _ blockers: [String]) -> Data {
        let list = blockers.map { "\"\($0)\"" }.joined(separator: ",")
        return Data(#"{"eligible":\#(eligible),"blockers":[\#(list)]}"#.utf8)
    }

    private func blockedBody(_ blockers: [String]) -> Data {
        let list = blockers.map { "\"\($0)\"" }.joined(separator: ",")
        return Data(
            #"{"error":{"code":"EMAIL_REPLACEMENT_BLOCKED","message":"x","fields":null},"blockers":[\#(list)]}"#.utf8
        )
    }

    private func errorBody(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"x","fields":null}}"#.utf8)
    }

    private func challenge() -> Data {
        Data(#"{"verification":{"expiresAt":"2026-07-28T16:10:00.000Z","resendAvailableAt":"2026-07-28T16:01:00.000Z"}}"#.utf8)
    }

    private func verified(_ email: String) -> Data {
        Data(#"{"participant":{"email":"\#(email)"},"authority":"\#(canonicalParticipantAuthorityFixture)"}"#.utf8)
    }
}
