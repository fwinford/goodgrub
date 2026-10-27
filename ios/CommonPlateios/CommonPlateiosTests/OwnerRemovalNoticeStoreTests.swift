import Foundation
import XCTest
@testable import CommonPlateios

private final class NoticeAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String?) { self.value = value }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: String?) { lock.lock(); value = new; lock.unlock() }
}

/// CP5 Home discovery, store boundary: the owner list's additive `removedNotice`
/// boolean is bound to the verified participant who was read, held in memory
/// only, and retired wherever the store retires owner state.
@MainActor
final class OwnerRemovalNoticeStoreTests: XCTestCase {
    private let authorityA = canonicalParticipantAuthorityFixture
    private let authorityB = replacementParticipantAuthorityFixture

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - DTO

    func testListDecodesPresentTrueFalseAndAbsentAsFalse() throws {
        let decoder = JSONDecoder()
        func decode(_ json: String) throws -> OwnerRequestListResponseDTO {
            try decoder.decode(OwnerRequestListResponseDTO.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try decode(#"{"requests":[],"removedNotice":true}"#).removedNotice)
        XCTAssertFalse(try decode(#"{"requests":[],"removedNotice":false}"#).removedNotice)
        XCTAssertFalse(try decode(#"{"requests":[]}"#).removedNotice, "older payload")
    }

    func testAMalformedNoticeIsAReadFailureNeverAFabricatedValue() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            OwnerRequestListResponseDTO.self,
            from: Data(#"{"requests":[],"removedNotice":"yes"}"#.utf8)
        ))
    }

    // MARK: - Store state

    func testASuccessfulReadSetsTheNoticeWithoutChangingTheRequestList() async {
        let store = makeStore(NoticeAuthority(authorityA))
        XCTAssertFalse(store.showsOwnerRemovalNotice)
        ClaimFlowURLProtocol.enqueue(.response(data: list([ownerObject("o1")], notice: true)))
        let outcome = await store.fetchOwnerRequests()

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(store.showsOwnerRemovalNotice)
        XCTAssertEqual(store.ownerRequests.map(\.id), ["o1"])
    }

    func testFalseAndAbsentNeverShowTheNotice() async {
        let store = makeStore(NoticeAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: list([ownerObject("o1")], notice: false)))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice)

        ClaimFlowURLProtocol.enqueue(.response(data: list([ownerObject("o1")], notice: nil)))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice)
    }

    func testALaterReadThatNoLongerReportsRemovalClearsTheNotice() async {
        let store = makeStore(NoticeAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        XCTAssertTrue(store.showsOwnerRemovalNotice)

        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: false)))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice)
    }

    func testAFailedReadNeverSetsTheNoticeAndKeepsTheSameParticipantsKnownState() async {
        let store = makeStore(NoticeAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice, "unknown is never removal")

        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice, "an unverifiable notice fails closed")
        XCTAssertNotNil(store.ownerRequestsError)
    }

    func testAFailedReadKeepsDismissalAndTheNextTrueReadStaysDismissed() async {
        let store = makeStore(NoticeAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        store.dismissOwnerRemovalNotice()
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice, "no false was observed, so still dismissed")
    }

    func testAFailedReadCannotBeRestoredByAStaleResponseAndExpiryClearsOnNextRead() async {
        let store = makeStore(NoticeAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        // The request expires: the backend stops reporting it.
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: false)))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice)
    }

    func testHomeRereadsOwnerRequestsWhenTheSceneBecomesActive() throws {
        let home = try source("Views/HomeExchangeView.swift")
        let start = try XCTUnwrap(home.range(of: ".onChange(of: scenePhase)"))
        let region = String(home[start.lowerBound...].prefix(300))
        XCTAssertTrue(region.contains("store.fetchOwnerRequests()"))
    }

    func testReportPopupIsClearedWhenTheIdentityChangesOrSignsOut() async {
        let authority = NoticeAuthority(authorityA)
        let store = makeStore(authority)
        store.presentReportPopup(requestID: "r1", returnsHome: false, offersBlockAfter: false)
        XCTAssertNotNil(store.reportPopup)

        authority.set(authorityB)
        await store.refreshParticipantRestriction()
        XCTAssertNil(store.reportPopup, "A's popup is not B's")

        authority.set(authorityA)
        store.presentReportPopup(requestID: "r2", returnsHome: false, offersBlockAfter: false)
        authority.set(nil)
        await store.refreshParticipantRestriction()
        XCTAssertNil(store.reportPopup)
    }

    func testReportPopupSurvivesARefreshForTheSameParticipant() async {
        let store = makeStore(NoticeAuthority(authorityA))
        store.presentReportPopup(requestID: "r1", returnsHome: false, offersBlockAfter: false)
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"restricted":false}"#.utf8)))
        await store.refreshParticipantRestriction()
        XCTAssertNotNil(store.reportPopup)
    }

    func testAnErrorEnvelopeNeverSetsTheNotice() async {
        let store = makeStore(NoticeAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 503,
            data: Data(#"{"error":{"code":"PARTICIPANT_VERIFICATION_UNAVAILABLE","message":"x","fields":null}}"#.utf8)
        ))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice)
    }

    // MARK: - Dismissal

    func testDismissalIsInMemoryAndOnlyResetsWhenTheBackendStopsReporting() async {
        let store = makeStore(NoticeAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        store.dismissOwnerRemovalNotice()
        XCTAssertFalse(store.showsOwnerRemovalNotice)

        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice, "a refresh does not resurrect a dismissed notice")

        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: false)))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        XCTAssertTrue(store.showsOwnerRemovalNotice, "a new removal is shown again")
    }

    // MARK: - Leakage prevention

    func testSignOutRetiresTheNoticeAtOnce() async {
        let authority = NoticeAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        XCTAssertTrue(store.showsOwnerRemovalNotice)

        authority.set(nil)
        XCTAssertFalse(store.showsOwnerRemovalNotice, "fail closed even before retirement runs")
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())
        XCTAssertFalse(store.hasOwnerRemovalNotice)

        authority.set(authorityA)
        XCTAssertFalse(store.showsOwnerRemovalNotice, "signing back in needs a fresh backend answer")
    }

    func testAccountSwitchNeverShowsTheNoticeToTheNewParticipant() async {
        let authority = NoticeAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()

        authority.set(authorityB)
        XCTAssertFalse(store.showsOwnerRemovalNotice, "bound to A, B is current")
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())
        XCTAssertFalse(store.hasOwnerRemovalNotice)

        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: false)))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice)
    }

    func testAccountSwitchRetiresADismissalSoTheNextParticipantStartsClean() async {
        let authority = NoticeAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        store.dismissOwnerRemovalNotice()

        authority.set(authorityB)
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await store.fetchOwnerRequests()
        XCTAssertTrue(store.showsOwnerRemovalNotice, "A's dismissal is not B's")
    }

    func testAFetchStartedForTheOldIdentityInstallsNothingAfterTheSwitch() async {
        let authority = NoticeAuthority(authorityA)
        let store = makeStore(authority)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true), gate: gate))
        let refresh = Task { await store.fetchOwnerRequests() }
        await waitUntil { gate.isWaiting }

        authority.set(authorityB)
        store.invalidateRequestDataIfIdentityReplaced()
        gate.open()
        _ = await refresh.value

        XCTAssertFalse(store.hasOwnerRemovalNotice)
        XCTAssertFalse(store.showsOwnerRemovalNotice)
        XCTAssertFalse(store.hasLoadedOwnerRequests)
    }

    func testASupersededRefreshCannotInstallAnOlderAnswer() async {
        let store = makeStore(NoticeAuthority(authorityA))
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true), gate: gate))
        let older = Task { await store.fetchOwnerRequests() }
        await waitUntil { gate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: false)))
        await store.fetchOwnerRequests()
        XCTAssertFalse(store.showsOwnerRemovalNotice)

        gate.open()
        _ = await older.value
        XCTAssertFalse(store.showsOwnerRemovalNotice, "the older, superseded answer is ignored")
    }

    func testARestoredSessionStartsWithoutTheNoticeUntilTheBackendAnswers() async {
        let first = makeStore(NoticeAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: list([], notice: true)))
        await first.fetchOwnerRequests()
        XCTAssertTrue(first.showsOwnerRemovalNotice)

        // A relaunch restores the same participant into a fresh store: nothing
        // about the notice was persisted, so none can be shown before a read.
        let restored = makeStore(NoticeAuthority(authorityA))
        XCTAssertFalse(restored.hasOwnerRemovalNotice)
        XCTAssertFalse(restored.showsOwnerRemovalNotice)
    }

    func testTheNoticeIsNeverPersistedAndHomeGatesOnlyOnTheStoreFlag() throws {
        let store = try source("Stores/RequestStore.swift")
        let start = try XCTUnwrap(store.range(of: "var hasOwnerRemovalNotice"))
        let end = try XCTUnwrap(store.range(of: "var isLoadingPlacedOrders", range: start.upperBound..<store.endIndex))
        let region = String(store[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(region.contains("UserDefaults"))
        XCTAssertFalse(region.contains("Keychain"))

        let banner = try source("Views/HomeRemovedRequestBanner.swift")
        for forbidden in ["UserDefaults", "AppStorage", "SceneStorage", "Keychain"] {
            XCTAssertFalse(banner.contains(forbidden), forbidden)
        }
        let home = try source("Views/HomeExchangeView.swift")
        XCTAssertTrue(home.contains(
            "if store.showsOwnerRemovalNotice {\n            HomeRemovedRequestBanner(onDismiss: { store.dismissOwnerRemovalNotice() })"
        ))
        XCTAssertEqual(home.components(separatedBy: "HomeRemovedRequestBanner(").count - 1, 1)
    }

    // MARK: - Helpers

    private func makeStore(_ authority: NoticeAuthority) -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.get() },
            participantAuthorityRejected: {},
            updateStorage: InMemoryPendingRequestUpdateStorage()
        )
    }

    private func waitUntil(timeoutIterations: Int = 200, condition: @MainActor () -> Bool) async {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    private func list(_ objects: [String], notice: Bool?) -> Data {
        let tail = notice.map { #","removedNotice":\#($0)"# } ?? ""
        return Data(#"{"requests":[\#(objects.joined(separator: ","))]\#(tail)}"#.utf8)
    }

    private func ownerObject(_ id: String) -> String {
        """
        {
          "id": "\(id)", "vendor": "Crave NYU", "food": "Rice bowl",
          "pickupWindowText": "ASAP", "mealSwipes": 1, "menuPath": "meal-exchange",
          "mealItems": [{"name": "Rice bowl"}], "orderDetails": null,
          "estimatedDiningDollarsCents": null, "windowStart": null, "windowEnd": null,
          "createdAt": "2026-07-20T18:30:00.000Z", "expiresAt": "2099-07-20T23:30:00.000Z",
          "timing": "asap", "phase": "available", "contentRevision": 1,
          "canEdit": true, "canWithdraw": true,
          "latestScheduledStart": "2026-07-21T03:30:00.000Z"
        }
        """
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
