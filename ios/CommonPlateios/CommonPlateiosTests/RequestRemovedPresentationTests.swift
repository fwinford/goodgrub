import Foundation
import XCTest
@testable import CommonPlateios

/// CP5 removal notice: `REQUEST_REMOVED` is decoded only on the requester's own
/// detail read, maps to the neutral removal state, and nothing else does.
@MainActor
final class RequestRemovedPresentationTests: XCTestCase {
    private let authority =
        "64c0000000000000000000c1.1." + String(repeating: "C", count: 42) + "A"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
    }

    private func store() -> RequestStore {
        RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { self.authority },
            participantAuthorityRejected: {}
        )
    }

    private func errorBody(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"x","fields":null}}"#.utf8)
    }

    // MARK: Copy

    func testCopyIsExactlyTheApprovedNeutralNotice() {
        XCTAssertEqual(
            RequestRemovedPresentation.message,
            "This request is no longer available. Contact support if you need assistance."
        )
        XCTAssertEqual(RequestRemovedPresentation.supportActionTitle, "Contact support")
        let copy = RequestRemovedPresentation.message.lowercased()
        for forbidden in ["report", "violat", "polic", "moderat", "suspend", "reason", "remov", "rule"] {
            XCTAssertFalse(copy.contains(forbidden), forbidden)
        }
    }

    // MARK: Error decoding and mapping

    func testTheServiceDecodesRequestRemovedOnTheOwnerDetailRead() async {
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorBody("REQUEST_REMOVED")
        ))
        do {
            _ = try await RequestService(client: client())
                .fetchOwnerRequest(id: "o1", participantAuthority: authority)
            XCTFail("expected a decoded removal")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, RequestRemovedPresentation.errorCode)
            XCTAssertEqual(code, "REQUEST_REMOVED")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOnlyTheDecodedRemovalCodeMapsToRemoved() {
        XCTAssertTrue(RequestRemovedPresentation.isRemoval(
            RequestServiceError.serverError(code: "REQUEST_REMOVED", message: "x")
        ))

        let notRemoved: [Error] = [
            RequestServiceError.serverError(code: "REQUEST_NOT_FOUND", message: "x"),
            RequestServiceError.serverError(code: "REQUEST_EXPIRED", message: "x"),
            RequestServiceError.serverError(code: "REQUEST_WITHDRAWN", message: "x"),
            RequestServiceError.serverError(code: "REQUEST_ALREADY_PLACED", message: "x"),
            RequestServiceError.serverError(code: "PARTICIPANT_SUSPENDED", message: "x"),
            RequestServiceError.serverError(code: "request_removed", message: "x"),
            RequestServiceError.serverError(code: "REQUEST_REMOVED_BY", message: "x"),
            RequestServiceError.notFound,
            RequestServiceError.participantAuthorityRequired,
            RequestServiceError.transport(underlying: URLError(.timedOut)),
            CancellationError(),
        ]
        for error in notRemoved {
            XCTAssertFalse(RequestRemovedPresentation.isRemoval(error), "\(error)")
        }
    }

    func testAnOrdinaryNotFoundIsNeverReadAsRemoval() async {
        for stub in [
            RequestFetchingURLProtocol.Stub.response(statusCode: 404, data: errorBody("REQUEST_NOT_FOUND")),
            .response(statusCode: 404, data: Data()),
            .response(statusCode: 500, data: errorBody("INTERNAL_FAILURE")),
        ] {
            RequestFetchingURLProtocol.enqueue(stub)
            do {
                _ = try await RequestService(client: client())
                    .fetchOwnerRequest(id: "o1", participantAuthority: authority)
                XCTFail("expected a failure")
            } catch {
                XCTAssertFalse(RequestRemovedPresentation.isRemoval(error), "\(error)")
            }
        }
    }

    // MARK: Store state

    func testTheStoreSurfacesRemovalAsADecodedErrorAndMutatesNothing() async {
        let store = store()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorBody("REQUEST_REMOVED")
        ))
        do {
            _ = try await store.fetchOwnerRequest(id: "o1")
            XCTFail("expected a decoded removal")
        } catch {
            XCTAssertTrue(RequestRemovedPresentation.isRemoval(error))
        }
        XCTAssertTrue(store.ownerRequests.isEmpty)
        XCTAssertNil(store.requesterNotice, "removal adds no Home notice")
        XCTAssertFalse(store.isParticipantRestricted, "a removed request implies no account state")
    }

    // MARK: Wiring

    func testViewReadsTheRemovalOnlyThroughTheDecodedCodeAndSharesTheSupportAction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        let view = try String(
            contentsOf: root.appendingPathComponent("Views/OwnerRequestDetailView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(view.contains("RequestRemovedPresentation.isRemoval(error)"))
        XCTAssertTrue(view.contains("CommonPlateSupportAction(title: RequestRemovedPresentation.supportActionTitle)"))
        XCTAssertFalse(view.contains("\"REQUEST_REMOVED\""), "the code lives only in the presentation type")
    }
}
