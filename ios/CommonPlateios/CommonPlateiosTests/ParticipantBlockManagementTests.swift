//
//  ParticipantBlockManagementTests.swift
//  CommonPlateiosTests
//
// W4-U1.3 final UX reconciliation fixes (2026-10-15). Unit and source-structure
// proof of:
//
// - the single Block-management route (Settings → Privacy & Safety → Blocked
//   Students) with no top-level duplicate;
// - the Blocked Students row hierarchy, stable trailing action lane, and
//   comfortable Unblock interaction target (structural, not pixel, assertions);
// - F6a: a stale Unblock failure is not carried into a fresh management load;
// - F6d: a successful Unblock re-establishes direct-contact restriction for the
//   still-held reservation through the existing authoritative reservation read,
//   and stays conservative whenever that read does not confirm otherwise.
//
// Not device evidence of presentation, touch targets, or navigation.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
private final class ManagementAuthorityBox {
    var value: String?
    init(_ value: String?) { self.value = value }
}

@MainActor
final class ParticipantBlockManagementTests: XCTestCase {
    private let requestID = "meal-a"
    private let authority = "64c0000000000000000000a1.1.credential"
    private let reservationPath = "/api/participant/active-reservation"

    override func tearDown() {
        ParticipantBlockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Information architecture

    func testSettingsKeepsPrivacySafetyAndHasNoTopLevelBlockedStudents() throws {
        let settings = try source("Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("NavigationLink(value: AppRoute.privacySafety)"))
        XCTAssertFalse(settings.contains("AppRoute.blockedStudents"))
        XCTAssertFalse(settings.contains("settings-blocked-students"))
        XCTAssertFalse(settings.contains("managementRowTitle"))
    }

    func testPrivacyAndSafetyIsTheOnlyEntryAndIsOfferedOnlyToAVerifiedParticipant() throws {
        let privacy = try source("Views/PrivacySafetyView.swift")
        XCTAssertTrue(privacy.contains("@ObservedObject var participantIdentityStore: ParticipantIdentityStore"))
        let gate = try XCTUnwrap(privacy.range(of: "if participantIdentityStore.identity != nil {"))
        let link = try XCTUnwrap(privacy.range(of: "NavigationLink(value: AppRoute.blockedStudents)"))
        XCTAssertLessThan(gate.lowerBound, link.lowerBound)
        XCTAssertTrue(privacy.contains("privacy-safety-blocked-students"))

        // Exactly one route producer anywhere in the app's views.
        let viewsDirectory = root().appendingPathComponent("Views")
        let files = try FileManager.default.contentsOfDirectory(
            at: viewsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        var producers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("AppRoute.blockedStudents") {
                producers.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(producers, ["PrivacySafetyView.swift"])

        // The destination is still the one existing management screen, and
        // Privacy & Safety receives the identity store it gates on.
        let content = try source("ContentView.swift")
        let privacyCall = try XCTUnwrap(content.range(of: "PrivacySafetyView("))
        XCTAssertTrue(content[privacyCall.upperBound...].prefix(120)
            .contains("participantIdentityStore: participantIdentityStore,"))
        let destination = try XCTUnwrap(content.range(of: "case .blockedStudents:"))
        XCTAssertTrue(content[destination.upperBound...].prefix(160).contains("BlockedStudentsView("))
    }

    // MARK: - Row presentation (structural)

    func testBlockedStudentRowKeepsOneSemanticHierarchyOnBothLayoutPaths() throws {
        let views = try source("Views/ParticipantBlockViews.swift")
        let runs = try XCTUnwrap(views.range(of: "private func locationRun("))
        let fits = try XCTUnwrap(views.range(of: "private func locationAndTimestamp("))
        let lane = try XCTUnwrap(views.range(of: "private func unblockLane("))
        let layout = String(views[fits.lowerBound..<runs.lowerBound])
        let styles = String(views[runs.lowerBound..<lane.lowerBound])

        // Both branches draw location and timestamp only through the two run
        // helpers, so neither can restyle independently.
        XCTAssertEqual(layout.components(separatedBy: "locationRun(").count - 1, 2)
        XCTAssertEqual(layout.components(separatedBy: "timestampRun(").count - 1, 2)
        XCTAssertFalse(layout.contains(".font("))
        XCTAssertFalse(layout.contains(".foregroundStyle("))
        XCTAssertFalse(layout.contains("Text(BlockedStudentPresentation.singleLine"))
        XCTAssertTrue(layout.contains("ViewThatFits(in: .horizontal)"))

        // Location: primary and semibold. Timestamp: secondary and regular.
        let location = try XCTUnwrap(styles.range(of: "private func timestampRun("))
        let locationStyle = String(styles[..<location.lowerBound])
        let timestampStyle = String(styles[location.lowerBound...])
        XCTAssertTrue(locationStyle.contains(".font(.subheadline.weight(.semibold))"))
        XCTAssertTrue(locationStyle.contains(".foregroundStyle(.primary)"))
        XCTAssertTrue(timestampStyle.contains(".font(.subheadline.weight(.regular))"))
        XCTAssertTrue(timestampStyle.contains(".foregroundStyle(.secondary)"))

        // The role stays muted metadata, and nothing is truncated anywhere.
        let role = try XCTUnwrap(
            views.range(of: "Text(BlockedStudentPresentation.roleTitle(for: student))")
        )
        let roleStyle = String(views[role.upperBound...].prefix(160))
        XCTAssertTrue(roleStyle.contains(".font(.caption.weight(.semibold))"))
        XCTAssertTrue(roleStyle.contains(".foregroundStyle(.secondary)"))
        let rowStart = try XCTUnwrap(views.range(of: "struct BlockedStudentsView"))
        let management = String(views[rowStart.lowerBound...])
        XCTAssertFalse(management.contains("truncationMode"))
        XCTAssertFalse(management.contains("minimumScaleFactor"))
        // Wrapping is allowed for the location (the fallback), never a cap.
        XCTAssertEqual(management.components(separatedBy: "lineLimit(1)").count - 1, 1)
    }

    func testUnblockLaneIsOneStableFootprintWithAComfortableTarget() throws {
        let views = try source("Views/ParticipantBlockViews.swift")
        let start = try XCTUnwrap(views.range(of: "private func unblockLane("))
        let lane = String(views[start.lowerBound...])

        // One container holds both states; the button stays laid out while
        // removing (hidden, inert, and not exposed), the spinner overlays it.
        XCTAssertTrue(lane.contains("ZStack {"))
        XCTAssertTrue(lane.contains(".opacity(isRemoving ? 0 : 1)"))
        XCTAssertTrue(lane.contains(".disabled(isRemoving)"))
        XCTAssertTrue(lane.contains(".accessibilityHidden(isRemoving)"))
        XCTAssertTrue(lane.contains("if isRemoving {\n                ProgressView()"))
        // The old collapsing structure (button or spinner as alternatives).
        XCTAssertFalse(lane.contains("} else {\n                Button("))

        // Comfortable target: project minimum control height, whole frame
        // tappable; the visible label typography is unchanged.
        XCTAssertTrue(lane.contains("minHeight: CommonPlateStyle.Control.minimumHeight"))
        XCTAssertTrue(lane.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(lane.contains(".font(.subheadline.weight(.semibold))"))
        XCTAssertGreaterThanOrEqual(CommonPlateStyle.Control.minimumHeight, 44)

        // The row's vertical padding belongs to the text column so the target
        // does not enlarge ordinary rows.
        let rowStart = try XCTUnwrap(views.range(of: "private func row(for student"))
        let rowEnd = try XCTUnwrap(views.range(of: "private func locationAndTimestamp("))
        let row = String(views[rowStart.lowerBound..<rowEnd.lowerBound])
        XCTAssertTrue(row.contains(".padding(.vertical, CommonPlateStyle.Spacing.s)\n            .frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(row.contains("unblockLane(for: student)"))
    }

    func testCompactAndFallbackStringsRemainTheSameContext() {
        let when = Date(timeIntervalSince1970: 1_791_411_300)
        let student = BlockedStudent(
            id: "b1", role: .helper, diningLocation: "Jasper Kane Cafe", interactionAt: when
        )
        // The compact one-line text is the location, then the same timestamp
        // the fallback shows on its own line.
        XCTAssertEqual(
            BlockedStudentPresentation.singleLine(for: student),
            "Jasper Kane Cafe · " + BlockedStudentPresentation.timestamp(for: student)
        )
    }

    // MARK: - F6a

    func testAFailedUnblockIsPresentedThenNotCarriedIntoAFreshLoad() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: listResponse([("b1", "requester")])))
        await store.loadBlockedStudents()

        ParticipantBlockURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.unblockStudent(id: "b1")
        // The current operation's truthful failure is presented.
        XCTAssertNotNil(store.unblockError)
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["b1"])

        // Leaving and re-entering Blocked Students loads again.
        ParticipantBlockURLProtocol.enqueue(.response(data: listResponse([("b1", "requester")])))
        await store.loadBlockedStudents()

        XCTAssertNil(store.unblockError)
        XCTAssertEqual(store.blockedStudentsLoadState, .loaded)
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["b1"])
    }

    func testAFreshLoadClearsTheStaleErrorEvenWhenTheLoadItselfFails() async {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: listResponse([("b1", "helper")])))
        await store.loadBlockedStudents()
        ParticipantBlockURLProtocol.enqueue(.failure(.timedOut))
        await store.unblockStudent(id: "b1")
        XCTAssertNotNil(store.unblockError)

        ParticipantBlockURLProtocol.enqueue(.failure(.timedOut))
        await store.loadBlockedStudents()

        // The failed reload is its own truthful failure; the old Unblock
        // error is not what is presented for it.
        XCTAssertNil(store.unblockError)
        XCTAssertEqual(store.blockedStudentsLoadState, .failed)
    }

    // MARK: - F6d

    func testNoRestrictionRemainingRestoresNormalHelpingAfterUnblock() async throws {
        let store = try await heldAndBlockedViaYes()
        // A Block never withheld the extension, so there is nothing to give back.
        XCTAssertTrue(try XCTUnwrap(store.activeClaim).isExtensionAvailable)
        XCTAssertTrue(store.canExtendActiveClaim)

        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: reservationResponse(restricted: false)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.unblockStudent(id: "block-1")

        // Caller-owned knowledge and the direction-agnostic restriction are
        // both gone, so the notice and Message return for the still-active
        // reservation; the extension was never withheld and is unchanged.
        XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertTrue(try XCTUnwrap(store.activeClaim).isExtensionAvailable)
        XCTAssertTrue(store.canExtendActiveClaim)
        XCTAssertTrue(store.canBlockHelpedRequester)

        // The read is the existing authoritative reservation read, made with
        // participant authority and carrying nothing about any block.
        let reads = ParticipantBlockURLProtocol.capturedRequests.filter { $0.path == reservationPath }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first?.method, "GET")
        XCTAssertEqual(reads.first?.headers[RequestService.participantAuthorityHeader], authority)
        XCTAssertNil(reads.first?.body)
    }

    func testRestrictionStillTrueKeepsTheNeutralConservativeState() async throws {
        let store = try await heldAndBlockedViaYes()

        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: reservationResponse(restricted: true)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.unblockStudent(id: "block-1")

        // Caller-owned knowledge is gone; direction-agnostic restriction stays,
        // so Helping shows "Direct contact is unavailable".
        XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertTrue(try XCTUnwrap(store.activeClaim).isExtensionAvailable)
        XCTAssertTrue(store.canExtendActiveClaim)
    }

    func testAFailedOrAmbiguousReadNeverClearsTheRestriction() async throws {
        let outcomes: [(String, ParticipantBlockURLProtocol.Stub)] = [
            ("transport failure", .failure(.networkConnectionLost)),
            ("server failure", .response(
                statusCode: 500,
                data: Data(#"{"error": {"code": "INTERNAL_ERROR", "message": "x", "fields": null}}"#.utf8)
            )),
            ("unreadable body", .response(data: Data("not json".utf8))),
        ]
        for (label, stub) in outcomes {
            ParticipantBlockURLProtocol.reset()
            let store = try await heldAndBlockedViaYes()

            ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
            ParticipantBlockURLProtocol.enqueue(stub)
            ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
            await store.unblockStudent(id: "block-1")

            XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID), label)
            XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID), label)
            XCTAssertNotNil(store.activeClaim, label)
            XCTAssertTrue(try XCTUnwrap(store.activeClaim).isExtensionAvailable, label)
            XCTAssertNil(store.unblockError, label)
            XCTAssertTrue(store.currentBlockedStudents.isEmpty, label)
        }
    }

    func testAReadThatDoesNotConfirmTheSameReservationChangesNothing() async throws {
        let none = Data(#"{"reservation": null, "placement": null}"#.utf8)
        let otherRequest = Data("""
        {
          "reservation": {
            "request": \(requestObject(id: "someone-elses", status: "claimed")),
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(10 * 60)))",
            "claimExtendedAt": null
          },
          "placement": null
        }
        """.utf8)
        for (label, body) in [("no reservation", none), ("different request", otherRequest)] {
            ParticipantBlockURLProtocol.reset()
            let store = try await heldAndBlockedViaYes()

            ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
            ParticipantBlockURLProtocol.enqueue(.response(data: body))
            ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
            await store.unblockStudent(id: "block-1")

            XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID), label)
            XCTAssertEqual(store.activeClaim?.requestID, requestID, label)
            XCTAssertTrue(try XCTUnwrap(store.activeClaim).isExtensionAvailable, label)
        }
    }

    func testAnExtensionAlreadyUsedIsNeverGivenBack() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(data: Data("""
        {
          "claim": {
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(20 * 60)))",
            "claimExtendedAt": "\(iso8601String(Date()))"
          }
        }
        """.utf8)))
        await store.extendActiveClaim()
        XCTAssertTrue(try XCTUnwrap(store.activeClaim).hasUsedExtension)

        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-1", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.blockHelpedRequester(externalOrderPlaced: true)
        try await settleBoardRefresh(store)

        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data("""
        {
          "reservation": {
            "request": \(requestObject(id: requestID, status: "claimed")),
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(20 * 60)))",
            "claimExtendedAt": "\(iso8601String(Date()))"
          },
          "placement": null
        }
        """.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.unblockStudent(id: "block-1")

        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertFalse(try XCTUnwrap(store.activeClaim).isExtensionAvailable)
        XCTAssertFalse(store.canExtendActiveClaim)
    }

    func testAReconstructedRestrictedReservationIsRestoredByTheSameAuthoritativeRead() async throws {
        // A relaunched process has no memory of the Block; it learned the
        // restriction only from the backend, so only the backend lifts it.
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: reservationResponse(restricted: true)))
        _ = try await store.continueActiveReservationIfNeeded()
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        // The extension is offered in the reconstructed restricted state too.
        XCTAssertTrue(store.canExtendActiveClaim)

        ParticipantBlockURLProtocol.enqueue(.response(
            data: listResponse([("block-1", "requester")])
        ))
        await store.loadBlockedStudents()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: reservationResponse(restricted: false)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.unblockStudent(id: "block-1")

        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertTrue(store.canExtendActiveClaim)
    }

    func testNoReservationReadHappensWithoutALocalRestrictionToReconcile() async throws {
        // No reservation at all.
        let bare = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: listResponse([("b1", "helper")])))
        await bare.loadBlockedStudents()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await bare.unblockStudent(id: "b1")
        XCTAssertFalse(ParticipantBlockURLProtocol.capturedRequests.contains { $0.path == reservationPath })
        // The fire-and-forget board refresh spawned by `unblockStudent` must
        // reach the shared transport before it is reset for phase 2.
        try await settleBoardRefresh(bare)

        // A held reservation with no restriction.
        ParticipantBlockURLProtocol.reset()
        let held = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await held.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(data: listResponse([("b1", "helper")])))
        await held.loadBlockedStudents()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await held.unblockStudent(id: "b1")
        XCTAssertFalse(ParticipantBlockURLProtocol.capturedRequests.contains { $0.path == reservationPath })
        XCTAssertTrue(held.canExtendActiveClaim)
    }

    func testReconciliationAddsNoOwnershipFieldOrOracle() throws {
        let store = try source("Stores/RequestStore.swift")
        let start = try XCTUnwrap(
            store.range(of: "private func reconcileRestrictionAfterUnblock(")
        )
        let end = try XCTUnwrap(
            store.range(of: "/// `POST /api/request/:id/claim/extend`", range: start.upperBound..<store.endIndex)
        )
        let body = String(store[start.lowerBound..<end.lowerBound])
        for forbidden in ["blockedRole", "blockedBy", "blockOwner", "ownedByCaller", "initiator"] {
            XCTAssertFalse(body.contains(forbidden), forbidden)
        }
        // It reuses the existing authoritative read.
        XCTAssertTrue(body.contains("service.fetchParticipantReservationState("))

        // The wire DTO still has no caller-relative ownership field.
        let dto = try source("DTOs/RequestDTOs.swift")
        XCTAssertFalse(dto.contains("blockedByCaller"))
        XCTAssertFalse(dto.contains("callerOwnsBlock"))
    }

    // MARK: - Helpers

    private func root() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(relative), encoding: .utf8)
    }

    private func settleBoardRefresh(_ store: RequestStore) async throws {
        for _ in 0..<500 {
            if ParticipantBlockURLProtocol.capturedRequests.contains(where: { $0.path == "/api/requests" }),
               !store.isFetching {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the post-block board refresh")
    }

    /// A helper holding the reservation who has chosen `Yes, already placed`
    /// and been told their Block is active.
    private func heldAndBlockedViaYes() async throws -> RequestStore {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-1", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        let result = await store.blockHelpedRequester(externalOrderPlaced: true)
        XCTAssertEqual(result, .blocked(reservationReleased: false))
        XCTAssertTrue(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        try await settleBoardRefresh(store)
        return store
    }

    private func makeStore() -> RequestStore {
        let box = ManagementAuthorityBox(authority)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParticipantBlockURLProtocol.self]
        let service = RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        ))
        return RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { box.value },
            participantAuthorityRejected: {}
        )
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func requestObject(id: String, status: String) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "Jasper Kane Cafe",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": [],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "\(iso8601String(Date().addingTimeInterval(5 * 60 * 60)))"
        }
        """
    }

    private func claimResponse() -> Data {
        Data("""
        {
          "request": \(requestObject(id: requestID, status: "claimed")),
          "claim": {
            "claimToken": "claim-token",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))"
          }
        }
        """.utf8)
    }

    private func reservationResponse(restricted: Bool) -> Data {
        let flag = restricted ? #","directContactRestricted": true"# : ""
        return Data("""
        {
          "reservation": {
            "request": \(requestObject(id: requestID, status: "claimed")),
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(10 * 60)))",
            "claimExtendedAt": null\(flag)
          },
          "placement": null
        }
        """.utf8)
    }

    private func blockObject(id: String, role: String) -> String {
        """
        {
          "id": "\(id)",
          "blockedRole": "\(role)",
          "diningLocation": "Jasper Kane Cafe",
          "interactionAt": "2026-07-20T18:30:00.000Z",
          "createdAt": "2026-07-20T18:31:00.000Z"
        }
        """
    }

    private func blockResponse(id: String, role: String, released: Bool) -> Data {
        Data("""
        { "block": \(blockObject(id: id, role: role)), "reservationReleased": \(released) }
        """.utf8)
    }

    private func listResponse(_ rows: [(String, String)]) -> Data {
        let items = rows.map { blockObject(id: $0.0, role: $0.1) }.joined(separator: ",")
        return Data(#"{ "blocks": [\#(items)] }"#.utf8)
    }
}
