import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
func installationPushIdentityFixture(client: APIClient) -> ParticipantIdentityStore {
    ParticipantIdentityStore(
        service: ParticipantVerificationService(client: client),
        storage: InMemoryParticipantIdentityStorage(stored: ParticipantIdentityRecord(
            principal: "a@nyu.edu",
            authority: canonicalParticipantAuthorityFixture,
            verifiedAt: Date()
        ))
    )
}

@MainActor
final class InstallationPushAuthorityTests: XCTestCase {
    override func tearDown() {
        InstallationPushURLProtocol.reset()
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testEnabledUsesSessionHeaderAndCannotChooseParticipantInBody() async throws {
        let client = client()
        let identity = installationPushIdentityFixture(client: client)
        let service = InstallationPushService(client: client, participantIdentityStore: identity)
        InstallationPushURLProtocol.enqueue(.response(data: enabledBody))
        let enabled = try await service.synchronizeEnabled(
            credential: InstallationCredentialGenerator.generate(),
            apnsToken: "aabb", environment: .current
        )
        XCTAssertTrue(enabled)
        let request = try XCTUnwrap(InstallationPushURLProtocol.capturedRequests.last)
        XCTAssertEqual(request.participantAuthority, identity.currentAuthority())
        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["participantId"])
        XCTAssertNil(object["participantAuthorityVersion"])
        XCTAssertNil(object["authority"])
    }

    func testMissingSessionFailsBeforeTransportButDisableIsCredentialOnly() async throws {
        let service = InstallationPushService(client: client())
        do {
            _ = try await service.synchronizeEnabled(
                credential: InstallationCredentialGenerator.generate(),
                apnsToken: "aabb", environment: .current
            )
            XCTFail("Missing authority must not enable")
        } catch InstallationPushSyncError.participantAuthorityRequired {}
        XCTAssertTrue(InstallationPushURLProtocol.capturedRequests.isEmpty)
        InstallationPushURLProtocol.enqueue(.response(data: disabledBody))
        let enabled = try await service.synchronizeDisabled(
            credential: InstallationCredentialGenerator.generate()
        )
        XCTAssertFalse(enabled)
        XCTAssertNil(InstallationPushURLProtocol.capturedRequests.last?.participantAuthority)
    }

    func testRemovalWhileAwaitingAPNsCannotSendPreviouslyCapturedAuthority() async {
        let client = client()
        let identity = installationPushIdentityFixture(client: client)
        let registrar = RemovingRegistrar { identity.discardRejectedIdentity() }
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let storage = InMemoryPushInstallationStorage()
        let store = PushSubscriptionStore(
            service: InstallationPushService(client: client, participantIdentityStore: identity),
            installationStorage: storage,
            authorizationCoordinator: authorization,
            remoteNotificationRegistrar: registrar,
            settingsOpener: StubPushSettingsOpener(),
            participantAuthorityProvider: { identity.currentAuthority() }
        )
        await store.enable()
        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(store.failure, .couldNotEnable)
        XCTAssertTrue(InstallationPushURLProtocol.capturedRequests.isEmpty)
        XCTAssertNil(storage.lastConfirmedPushEnabled)
    }

    func testRejectedAuthorityIsDefinitiveAndRetryReadsReplacementSession() async throws {
        let identityClient = client(RequestFetchingURLProtocol.self)
        let identity = installationPushIdentityFixture(client: identityClient)
        identity.configureInstallationAssociation { _ in }
        let service = InstallationPushService(client: client(), participantIdentityStore: identity)
        let credential = InstallationCredentialGenerator.generate()
        InstallationPushURLProtocol.enqueue(.response(
            statusCode: 403,
            data: Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"Verify again","fields":null}}"#.utf8)
        ))
        do {
            _ = try await service.synchronizeEnabled(
                credential: credential, apnsToken: "aabb", environment: .current
            )
            XCTFail("Invalid authority cannot confirm On")
        } catch InstallationPushSyncError.unknownFailure {}
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 1)

        identity.beginEmailReplacement()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data(
            #"{"verification":{"expiresAt":"2026-10-24T23:10:00Z","resendAvailableAt":"2026-10-24T23:01:00Z"}}"#.utf8
        )))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(
            #"{"participant":{"email":"b@nyu.edu"},"authority":"\#(replacementParticipantAuthorityFixture)"}"#.utf8
        )))
        await identity.requestCode(for: "b@nyu.edu")
        let replaced = await identity.submitCode("123456")
        XCTAssertTrue(replaced)
        InstallationPushURLProtocol.enqueue(.response(data: enabledBody))
        _ = try await service.synchronizeEnabled(
            credential: credential, apnsToken: "aabb", environment: .current
        )
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.map(\.participantAuthority), [
            canonicalParticipantAuthorityFixture, replacementParticipantAuthorityFixture
        ])

        await identity.removeIdentity()
        do {
            _ = try await service.synchronizeEnabled(
                credential: credential, apnsToken: "aabb", environment: .current
            )
            XCTFail("Removal must not leak the old authority")
        } catch InstallationPushSyncError.participantAuthorityRequired {}
        InstallationPushURLProtocol.enqueue(.response(data: disabledBody))
        _ = try await service.synchronizeDisabled(credential: credential)
        XCTAssertNil(InstallationPushURLProtocol.capturedRequests.last?.participantAuthority)
    }

    private var enabledBody: Data { Data(#"{"push":{"enabled":true}}"#.utf8) }
    private var disabledBody: Data { Data(#"{"push":{"enabled":false}}"#.utf8) }

    private func client(_ protocolClass: URLProtocol.Type = InstallationPushURLProtocol.self) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
    }
}

@MainActor
private final class RemovingRegistrar: RemoteNotificationRegistering {
    let remove: () -> Void
    init(_ remove: @escaping () -> Void) { self.remove = remove }
    func registerAndAwaitToken(timeout: Duration) async throws -> String {
        remove()
        return "aabb"
    }
}
