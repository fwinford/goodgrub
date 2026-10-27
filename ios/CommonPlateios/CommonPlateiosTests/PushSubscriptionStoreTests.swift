//
//  PushSubscriptionStoreTests.swift
//  CommonPlateiosTests
//
// Focused coverage for Week 3 Day 6 Slice 6A.2: the permission flow, APNs
// registration handoff, backend synchronization, and the states the push
// control shows. Doubles stand in only at the boundaries named in the Slice
// 6A.2 task — system notification permission, application registration,
// local storage, and (for a few cases) a controllable clock via a delayed
// network stub — and the store still talks to the real
// `InstallationPushService` and `APIClient` over a local `URLProtocol`
// double, matching how `AlertSignupTests` exercises `AlertSubscriptionStore`.
import Foundation
import UserNotifications
import XCTest
@testable import CommonPlateios

// MARK: - Local transport double

/// Its own double rather than reusing `AlertSignupURLProtocol`: each test
/// file owns its stubbing state, so a push test can never depend on — or
/// interfere with — an alert-signup test's queue.
final class InstallationPushURLProtocol: URLProtocol {
    struct CapturedRequest {
        let path: String
        let method: String
        let body: Data?
        let participantAuthority: String?
    }

    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        let delay: TimeInterval

        static func response(statusCode: Int = 200, data: Data, delay: TimeInterval = 0) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil, delay: delay)
        }

        static func failure(_ errorCode: URLError.Code, delay: TimeInterval = 0) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: errorCode, delay: delay)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var captured: [CapturedRequest] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        captured.removeAll()
        lock.unlock()
    }

    static var capturedRequests: [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1_024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(
            CapturedRequest(
                path: request.url?.path ?? "",
                method: request.httpMethod ?? "",
                body: Self.readBody(from: request),
                participantAuthority: request.value(forHTTPHeaderField: "x-commonplate-participant")
            )
        )
        Self.lock.unlock()

        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let completeRequest = {
            if let errorCode = stub.errorCode {
                self.client?.urlProtocol(self, didFailWithError: URLError(errorCode))
                return
            }
            guard let url = self.request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: stub.statusCode,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  ) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: completeRequest)
        } else {
            completeRequest()
        }
    }

    override func stopLoading() {}
}

// MARK: - Other test doubles

final class StubPushAuthorizationCoordinator: PushAuthorizationCoordinator {
    var status: UNAuthorizationStatus = .notDetermined
    var requestResult: Result<Bool, Error> = .success(true)
    private(set) var requestCallCount = 0
    private(set) var statusCheckCount = 0

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        statusCheckCount += 1
        return status
    }

    func requestAuthorization() async throws -> Bool {
        requestCallCount += 1
        switch requestResult {
        case .success(let granted):
            if granted { status = .authorized }
            return granted
        case .failure(let error):
            throw error
        }
    }
}

final class StubRemoteNotificationRegistrar: RemoteNotificationRegistering {
    enum Outcome {
        case token(String)
        case failure(Error)
    }

    var outcome: Outcome = .token("aabbccdd")
    private(set) var callCount = 0

    func registerAndAwaitToken(timeout: Duration) async throws -> String {
        callCount += 1
        switch outcome {
        case .token(let token):
            return token
        case .failure(let error):
            throw error
        }
    }
}

final class StubPushSettingsOpener: PushSettingsOpener {
    private(set) var openCount = 0
    func openSettings() { openCount += 1 }
}

/// Mirrors `InMemoryAlertSignupPresentationStorage`: the counts are the
/// point, so a preserved value can be told apart from a
/// destroyed-and-rewritten one.
final class InMemoryPushInstallationStorage: PushInstallationStorage {
    private(set) var pendingReplacementEmail: String?
    func setPendingReplacementEmail(_ email: String?) { pendingReplacementEmail = email }
    private(set) var hasPendingAssociationChange = false
    func setPendingAssociationChange(_ pending: Bool) { hasPendingAssociationChange = pending }
    private var credential: String?
    private(set) var lastConfirmedPushEnabled: Bool?
    private(set) var recordCalls: [Bool] = []
    private(set) var settingsRecoveryIntentStartedAt: Date?
    private(set) var settingsRecoveryIntentStartedAtCalls: [Date?] = []
    private(set) var pendingAmbiguousDesiredEnabled: Bool?
    private(set) var pendingAmbiguousDesiredEnabledCalls: [Bool?] = []

    init(
        credential: String? = nil,
        lastConfirmedPushEnabled: Bool? = nil,
        settingsRecoveryIntentStartedAt: Date? = nil,
        pendingAmbiguousDesiredEnabled: Bool? = nil
    ) {
        self.credential = credential
        self.lastConfirmedPushEnabled = lastConfirmedPushEnabled
        self.settingsRecoveryIntentStartedAt = settingsRecoveryIntentStartedAt
        self.pendingAmbiguousDesiredEnabled = pendingAmbiguousDesiredEnabled
    }

    func installationCredential() -> String {
        if let credential { return credential }
        let generated = InstallationCredentialGenerator.generate()
        credential = generated
        return generated
    }

    func recordConfirmedPushEnabled(_ enabled: Bool) {
        lastConfirmedPushEnabled = enabled
        recordCalls.append(enabled)
    }

    func setSettingsRecoveryIntentStartedAt(_ date: Date?) {
        settingsRecoveryIntentStartedAt = date
        settingsRecoveryIntentStartedAtCalls.append(date)
    }

    func setPendingAmbiguousDesiredEnabled(_ desired: Bool?) {
        pendingAmbiguousDesiredEnabled = desired
        pendingAmbiguousDesiredEnabledCalls.append(desired)
    }
}

// MARK: - Tests

@MainActor
final class PushSubscriptionStoreTests: XCTestCase {
    override func tearDown() {
        InstallationPushURLProtocol.reset()
        super.tearDown()
    }

    // MARK: No automatic permission requests

    func testConstructingTheStoreRequestsNoAuthorization() {
        let authorization = StubPushAuthorizationCoordinator()
        _ = makeStore(authorization: authorization)
        XCTAssertEqual(authorization.requestCallCount, 0)
    }

    /// `Not now` is handled entirely by the view: it flips local UI state and
    /// never calls the store at all. What is testable here is the necessary
    /// condition that makes that safe — that nothing the store does on its
    /// own, including a lifecycle refresh, ever requests authorization.
    func testRefreshingAuthorizationStatusNeverRequestsAuthorization() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .notDetermined
        let store = makeStore(authorization: authorization)

        await store.refreshAuthorizationStatus()

        XCTAssertEqual(authorization.requestCallCount, 0)
        XCTAssertEqual(store.state, .off)
    }

    // MARK: - Enabling: permission states

    func testNotDeterminedPermissionRequestsAuthorizationThenRegistersAndSynchronizes() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .notDetermined
        authorization.requestResult = .success(true)
        let registrar = StubRemoteNotificationRegistrar()
        registrar.outcome = .token("0123456789abcdef")
        let store = makeStore(authorization: authorization, registrar: registrar)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))

        await store.enable()

        XCTAssertEqual(authorization.requestCallCount, 1)
        XCTAssertEqual(registrar.callCount, 1)
        XCTAssertEqual(store.state, .on)
        XCTAssertNil(store.failure)
    }

    func testAlreadyAuthorizedPermissionSkipsTheSystemPromptAndRegisters() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))

        await store.enable()

        XCTAssertEqual(authorization.requestCallCount, 0)
        XCTAssertEqual(registrar.callCount, 1)
        XCTAssertEqual(store.state, .on)
    }

    /// Explicitly re-checked: calling the enable flow a second time while
    /// permission is already authorized must not request it again either.
    func testReEnablingWhilePermissionIsAlreadyAuthorizedNeverRequestsAuthorizationAgain() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        registrar.outcome = .failure(RemoteNotificationRegistrationError.timedOut)
        let store = makeStore(authorization: authorization, registrar: registrar)

        await store.enable()
        XCTAssertEqual(store.state, .failed)

        registrar.outcome = .token("aabbccdd")
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))
        await store.enable()

        XCTAssertEqual(authorization.requestCallCount, 0)
        XCTAssertEqual(store.state, .on)
    }

    func testDeniedPermissionProducesTheRecoveryStateWithoutRegisteringOrSynchronizing() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar)

        await store.enable()

        XCTAssertEqual(store.state, .denied)
        XCTAssertEqual(registrar.callCount, 0)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 0)
    }

    func testDenialDuringTheRequestPromptProducesTheRecoveryState() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .notDetermined
        authorization.requestResult = .success(false)
        let store = makeStore(authorization: authorization)

        await store.enable()

        XCTAssertEqual(store.state, .denied)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Open Settings

    func testOpenSystemSettingsIsNeverCalledExceptExplicitly() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let opener = StubPushSettingsOpener()
        let store = makeStore(authorization: authorization, settingsOpener: opener)

        await store.enable()
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(opener.openCount, 0)

        store.openSystemSettings()
        XCTAssertEqual(opener.openCount, 1)
    }

    // MARK: - APNs registration and backend failure produce one recovery state

    func testAPNsRegistrationFailureProducesTheRetryStateAndTouchesNoBackend() async {
        let registrar = StubRemoteNotificationRegistrar()
        registrar.outcome = .failure(RemoteNotificationRegistrationError.system(URLError(.notConnectedToInternet)))
        let store = makeStore(authorization: alreadyAuthorized(), registrar: registrar)

        await store.enable()

        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(store.failure, .couldNotEnable)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 0)
    }

    func testAPNsRegistrationTimeoutProducesTheSameRetryStateAsAnyOtherRegistrationFailure() async {
        let registrar = StubRemoteNotificationRegistrar()
        registrar.outcome = .failure(RemoteNotificationRegistrationError.timedOut)
        let store = makeStore(authorization: alreadyAuthorized(), registrar: registrar)

        await store.enable()

        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(store.failure, .couldNotEnable)
    }

    /// A transport-level loss after the request may already have reached the
    /// backend is genuinely ambiguous, not a known failure: `.failed` would
    /// wrongly claim the enable definitely did not apply, and reverting to
    /// `.off` would wrongly claim the opposite. The unresolved desired state
    /// must also survive relaunch, which is why it is persisted here rather
    /// than only held in memory.
    func testBackendFailureAfterAValidTokenProducesTheAmbiguousStateAndDoesNotPersistOn() async {
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: alreadyAuthorized(), storage: storage)
        InstallationPushURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.enable()

        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: true))
        XCTAssertNil(storage.lastConfirmedPushEnabled)
        XCTAssertTrue(storage.recordCalls.isEmpty)
        XCTAssertEqual(storage.pendingAmbiguousDesiredEnabled, true)
    }

    /// A backend rejection the service can definitively decode (here, a rate
    /// limit) is not ambiguous: it never reached the reconciliation logic, so
    /// `.failed` is the correct — and retryable through the ordinary
    /// `enable` entry point — state, with no unresolved
    /// desired state left persisted.
    func testDefinitiveBackendRejectionProducesFailedRatherThanAmbiguous() async {
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: alreadyAuthorized(), storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 429, data: Data()))

        await store.enable()

        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(store.failure, .couldNotEnable)
        XCTAssertNil(storage.pendingAmbiguousDesiredEnabled)
    }

    /// The whole point of `.failed` being an allowed entry point for
    /// `enable`: one recovery state, retried by calling
    /// exactly the same thing again.
    func testRetryingAfterAFailureCanSucceed() async {
        let registrar = StubRemoteNotificationRegistrar()
        registrar.outcome = .failure(RemoteNotificationRegistrationError.timedOut)
        let store = makeStore(authorization: alreadyAuthorized(), registrar: registrar)
        await store.enable()
        XCTAssertEqual(store.state, .failed)

        registrar.outcome = .token("aabbccdd")
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))
        await store.enable()
        XCTAssertEqual(store.state, .on)
        XCTAssertNil(store.failure)
    }

    // MARK: - Ambiguous synchronization (W3-N2)

    /// Explicit recovery from `.ambiguous` reasserts only the same desired
    /// state, through `retryAmbiguousSync()` — never the ordinary
    /// `enable`/`disable` entry points, which refuse outside
    /// their own states.
    func testExplicitRetryFromAmbiguousEnableCanSucceedAndClearsThePersistedFlag() async {
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: alreadyAuthorized(), storage: storage)
        InstallationPushURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.enable()
        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: true))

        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))
        await store.retryAmbiguousSync()

        XCTAssertEqual(store.state, .on)
        XCTAssertNil(storage.pendingAmbiguousDesiredEnabled)
    }

    /// A second ambiguous outcome while retrying must not be reported as a
    /// definitive `.failed` — the original unresolved mutation is still
    /// exactly as unresolved as it was, so the state stays `.ambiguous`.
    func testExplicitRetryFromAmbiguousEnableThatIsAgainAmbiguousStaysAmbiguous() async {
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: alreadyAuthorized(), storage: storage)
        InstallationPushURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.enable()
        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: true))

        InstallationPushURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.retryAmbiguousSync()

        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: true))
        XCTAssertEqual(storage.pendingAmbiguousDesiredEnabled, true)
    }

    /// A relaunch is simulated by constructing a fresh store over the same
    /// storage. The unresolved desired state must be exactly what the new
    /// store starts in, with no automatic reconciliation attempted from
    /// `init` itself.
    func testAmbiguousDesiredStateSurvivesRelaunch() async {
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: alreadyAuthorized(), storage: storage)
        InstallationPushURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.enable()
        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: true))

        let relaunched = makeStore(storage: storage)

        XCTAssertEqual(relaunched.state, .ambiguous(desiredEnabled: true))
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 1, "relaunch alone must attempt no network call")
    }

    /// An ordinary lifecycle refresh (app foreground, screen revisit) must
    /// never automatically resolve or retry an ambiguous outcome — only an
    /// explicit `retryAmbiguousSync()` call may.
    func testLifecycleRefreshNeverAutomaticallyRetriesAnAmbiguousOutcome() async {
        let storage = InMemoryPushInstallationStorage()
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let store = makeStore(authorization: authorization, storage: storage)
        InstallationPushURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.enable()
        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: true))
        let requestCountAfterFirstAttempt = InstallationPushURLProtocol.capturedRequests.count

        await store.refreshAuthorizationStatus()
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: true))
        XCTAssertEqual(
            InstallationPushURLProtocol.capturedRequests.count,
            requestCountAfterFirstAttempt,
            "a lifecycle refresh must not itself attempt a network call while ambiguous"
        )
    }

    // MARK: - Backend success required before showing on

    func testShowsOnOnlyAfterTheBackendConfirmsEnabled() async {
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: alreadyAuthorized(), storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))

        XCTAssertEqual(store.state, .off)
        await store.enable()

        XCTAssertEqual(store.state, .on)
        XCTAssertEqual(storage.lastConfirmedPushEnabled, true)
        XCTAssertEqual(storage.recordCalls, [true])
    }

    // MARK: - Disabling

    func testDisableIsIgnoredUnlessCurrentlyOn() async {
        let store = makeStore(authorization: alreadyAuthorized())
        XCTAssertEqual(store.state, .off)

        await store.disable()

        XCTAssertEqual(store.state, .off)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 0)
    }

    func testDisableSendsOnlyCredentialAndEnabledFalse() async throws {
        let storage = InMemoryPushInstallationStorage(credential: "the-installation-credential")
        let store = await enabledStore(storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody))

        await store.disable()

        XCTAssertEqual(store.state, .off)
        let requests = InstallationPushURLProtocol.capturedRequests
        let disableRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(disableRequest.method, "PUT")
        let body = try XCTUnwrap(disableRequest.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["installationCredential", "enabled"])
        XCTAssertEqual(json["installationCredential"] as? String, "the-installation-credential")
        XCTAssertEqual(json["enabled"] as? Bool, false)
    }

    func testDisableWaitsForTheBackendResponseBeforeShowingOff() async throws {
        let store = await enabledStore()
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody, delay: 0.3))

        let disableTask = Task { await store.disable() }
        await waitUntil { store.state == .settingUp }
        XCTAssertEqual(store.state, .settingUp, "must not show off before the backend responds")

        await disableTask.value
        XCTAssertEqual(store.state, .off)
    }

    /// A definitive backend rejection during disable — one the service can
    /// decode, so it never reached reconciliation — preserves the last
    /// confirmed On state and remains retryable through the ordinary
    /// `disable()` entry point.
    func testDefinitivelyFailedDisablePreservesTheLastConfirmedOnStateAndOffersRetry() async throws {
        let storage = InMemoryPushInstallationStorage()
        let store = await enabledStore(storage: storage)
        let recordsBeforeFailure = storage.recordCalls.count
        InstallationPushURLProtocol.enqueue(.response(statusCode: 429, data: Data()))

        await store.disable()

        XCTAssertEqual(store.state, .on, "a definitively failed disable must not claim delivery stopped")
        XCTAssertEqual(store.failure, .couldNotDisable)
        XCTAssertEqual(storage.recordCalls.count, recordsBeforeFailure)
        XCTAssertNil(storage.pendingAmbiguousDesiredEnabled)

        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody))
        await store.disable()
        XCTAssertEqual(store.state, .off)
        XCTAssertNil(store.failure)
    }

    func testPermissionRevocationAfterFailedDisableCannotKeepToggleOnOrRetrySilently() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: authorization, storage: storage)
        InstallationPushURLProtocol.enqueue(.response(data: enabledBody))
        await store.enable()
        InstallationPushURLProtocol.enqueue(.response(statusCode: 429, data: Data()))
        await store.disable()
        XCTAssertEqual(store.state, .on)

        let requests = InstallationPushURLProtocol.capturedRequests.count
        authorization.status = .denied
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .denied)
        XCTAssertEqual(store.failure, .couldNotDisable)
        XCTAssertEqual(storage.lastConfirmedPushEnabled, true)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, requests)
        XCTAssertEqual(authorization.requestCallCount, 0)

        InstallationPushURLProtocol.enqueue(.response(data: disabledBody))
        await store.retryUpdate()
        XCTAssertEqual(store.state, .off)
        XCTAssertNil(store.failure)
        XCTAssertEqual(authorization.status, .denied)
    }

    /// A transport-level loss during disable is genuinely ambiguous: `.on`
    /// would wrongly claim delivery definitely did not stop, and `.off` would
    /// wrongly claim it definitely did. The unresolved desired state (Off)
    /// must survive relaunch and resolve only through explicit retry.
    func testAmbiguousDisableWithholdsBothOnAndOffAndPersistsTheDesiredState() async throws {
        let storage = InMemoryPushInstallationStorage()
        let store = await enabledStore(storage: storage)
        InstallationPushURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.disable()

        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: false))
        XCTAssertEqual(storage.pendingAmbiguousDesiredEnabled, false)

        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody))
        await store.retryAmbiguousSync()

        XCTAssertEqual(store.state, .off)
        XCTAssertNil(storage.pendingAmbiguousDesiredEnabled)
    }

    // MARK: - Relaunch / activation re-registration

    func testRelaunchWithAPreviouslyConfirmedInstallationStartsInASettingUpState() {
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        let store = makeStore(storage: storage)
        XCTAssertEqual(store.state, .settingUp)
    }

    func testActivationSilentlyReRegistersAnAlreadyEnabledInstallationWithoutPrompting() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))

        await store.refreshAuthorizationStatus()

        XCTAssertEqual(authorization.requestCallCount, 0)
        XCTAssertEqual(registrar.callCount, 1)
        XCTAssertEqual(store.state, .on)
    }

    func testActivationWithNoPriorConfirmationNeverAutomaticallyRequestsOrRegisters() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .notDetermined
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar)

        await store.refreshAuthorizationStatus()

        XCTAssertEqual(authorization.requestCallCount, 0)
        XCTAssertEqual(registrar.callCount, 0)
        XCTAssertEqual(store.state, .off)
    }

    // MARK: - Revoked permission detected on lifecycle refresh

    func testRevokedPermissionIsDetectedOnRefreshAndReconciledToTheBackend() async {
        let storage = InMemoryPushInstallationStorage()
        // A real enable call through this storage, so it holds a genuine
        // confirmed-on record and a real credential rather than a fixture.
        _ = await enabledStore(storage: storage)

        // A fresh store over the same storage, standing in for the app
        // relaunching with permission now revoked in Settings.
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let store = makeStore(authorization: authorization, storage: storage)
        XCTAssertEqual(store.state, .settingUp, "constructed from a still-confirmed-on record")
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody))

        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .denied)
        XCTAssertEqual(storage.lastConfirmedPushEnabled, false)
    }

    /// This is required test #12: authorized permission with no pending
    /// recovery intent must not auto-enable a backend-confirmed-off
    /// installation, even once it has seen `.denied`.
    func testReturningFromSettingsWithPermissionRestoredButNeverConfirmedStaysOff() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let store = makeStore(authorization: authorization)
        await store.enable()
        XCTAssertEqual(store.state, .denied)

        authorization.status = .authorized
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .off, "never confirmed on and no pending recovery intent, so an explicit enable is still required")
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Dismissing the explanation without a pending recovery intent (Bug 1)

    /// Covers required tests 1–5 together: opening the explanation is a
    /// purely local view-state change that never touches the store, so the
    /// only thing to prove at the store level is that a lifecycle refresh —
    /// what `Not now` or navigating back ultimately leaves behind once the
    /// screen is revisited — is a complete no-op while genuinely
    /// `.notDetermined`: no state change, no authorization request, no APNs
    /// registration, no backend call.
    func testRefreshWhileNotDeterminedAndNeverConfirmedIsACompleteNoOp() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .notDetermined
        let registrar = StubRemoteNotificationRegistrar()
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)

        // Simulates the explanation being shown and dismissed one or more
        // times, and the screen being revisited, all before any explicit
        // enable — repeated because `Not now` and navigating back are both
        // expected to reach this same no-op path however many times.
        await store.refreshAuthorizationStatus()
        await store.refreshAuthorizationStatus()
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .off, "must return to the neutral Off card, never the Settings-recovery card")
        XCTAssertEqual(authorization.requestCallCount, 0)
        XCTAssertEqual(registrar.callCount, 0)
        XCTAssertTrue(storage.recordCalls.isEmpty)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 0)
    }

    /// The scenario a stale Apple `.denied` read (from any earlier,
    /// unrelated interaction) would previously have mishandled: dismissing
    /// the explanation must stay neutral even when Apple's permission
    /// happens to already read denied, as long as nothing was ever confirmed
    /// on and no recovery was ever started from this installation.
    func testRefreshWhileDeniedWithNoPriorConfirmationAndNoPendingRecoveryStaysNeutral() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let registrar = StubRemoteNotificationRegistrar()
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)

        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .off, "no pending recovery intent and never confirmed on: this is not news to surface")
        XCTAssertEqual(registrar.callCount, 0)
        XCTAssertTrue(storage.recordCalls.isEmpty)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 0)
    }

    /// Required test 6: an actual denial reached through the real enable
    /// flow (not a stale background read) still shows the recovery state —
    /// the fix narrows when a *bare refresh* surfaces `.denied`; it does not
    /// suppress the direct, synchronous outcome of an explicit attempt.
    func testActualDenialThroughTheEnableFlowStillShowsTheRecoveryState() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let store = makeStore(authorization: authorization)

        await store.enable()

        XCTAssertEqual(store.state, .denied)
    }

    // MARK: - Settings recovery (Bug 2)

    /// Required test 7 (the other half of the existing
    /// `testOpenSystemSettingsIsNeverCalledExceptExplicitly`): the store
    /// itself refuses to open Settings — and to record a pending recovery
    /// intent — outside `.denied`.
    func testOpenSystemSettingsDoesNothingOutsideDeniedState() {
        let opener = StubPushSettingsOpener()
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(storage: storage, settingsOpener: opener)
        XCTAssertEqual(store.state, .off)

        store.openSystemSettings()

        XCTAssertEqual(opener.openCount, 0)
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt)
    }

    /// Required test 8: returning from Settings with permission still denied
    /// remains in the denied/recovery state rather than reverting to neutral.
    func testReturningFromSettingsStillDeniedRemainsInRecovery() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let opener = StubPushSettingsOpener()
        let store = makeStore(authorization: authorization, settingsOpener: opener)
        await store.enable()
        XCTAssertEqual(store.state, .denied)

        store.openSystemSettings()
        XCTAssertEqual(opener.openCount, 1)

        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .denied)
    }

    /// Required tests 9 and 10: returning from Settings with permission now
    /// authorized and a pending recovery intent starts APNs registration and
    /// backend synchronization automatically — no second explicit action —
    /// and backend success produces On and clears the pending intent.
    func testReturningFromSettingsAuthorizedWithPendingRecoveryCompletesAutomaticallyAndClearsIntent() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let registrar = StubRemoteNotificationRegistrar()
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)
        await store.enable()
        store.openSystemSettings()
        XCTAssertNotNil(storage.settingsRecoveryIntentStartedAt)

        authorization.status = .authorized
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(authorization.requestCallCount, 0, "no second Apple prompt")
        XCTAssertEqual(registrar.callCount, 1)
        XCTAssertEqual(store.state, .on)
        XCTAssertEqual(storage.lastConfirmedPushEnabled, true)
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt, "the pending intent must be cleared once recovery completes")
    }

    /// Required test 11: an APNs or backend failure while completing
    /// Settings recovery produces the same retryable setup-failure state as
    /// any other registration failure, not a silent return to Off.
    func testAPNsFailureDuringSettingsRecoveryProducesTheRetryState() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar)
        await store.enable()
        store.openSystemSettings()

        authorization.status = .authorized
        registrar.outcome = .failure(RemoteNotificationRegistrationError.timedOut)
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(store.failure, .couldNotEnable)
    }

    /// A transport-level loss while Settings recovery auto-continues is still
    /// genuinely ambiguous, exactly like any other backend call: `.failed`
    /// would wrongly claim the enable definitely did not apply.
    func testAmbiguousBackendOutcomeDuringSettingsRecoveryProducesTheAmbiguousState() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: authorization, storage: storage)
        await store.enable()
        store.openSystemSettings()

        authorization.status = .authorized
        InstallationPushURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: true))
        XCTAssertEqual(storage.pendingAmbiguousDesiredEnabled, true)
    }

    /// A definitive backend rejection during Settings recovery is not
    /// ambiguous and produces the ordinary retryable `.failed` state.
    func testDefinitiveBackendRejectionDuringSettingsRecoveryProducesFailed() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let store = makeStore(authorization: authorization)
        await store.enable()
        store.openSystemSettings()

        authorization.status = .authorized
        InstallationPushURLProtocol.enqueue(.response(statusCode: 429, data: Data()))
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(store.failure, .couldNotEnable)
    }

    // MARK: - Settings-recovery intent expiration
    //
    // Independent-review Finding 1: the persisted recovery intent had no
    // expiration, so an abandoned `Open Settings` excursion followed by an
    // unrelated, much later permission grant could silently enable push
    // with no fresh explicit action that session. Every test below drives
    // `refreshAuthorizationStatus(now:)` and `openSystemSettings(now:)`
    // with an injected, fixed `Date` — never the real wall clock — so
    // freshness and staleness are deterministic. Labeled "Expiration test
    // N" to avoid colliding with the "Required test N" labels above, which
    // number the original Bug 1/Bug 2 fix's own required tests.

    /// Expiration test 1: `openSystemSettings` records the recovery
    /// intent's start time using exactly the clock it is given, not the
    /// real wall clock.
    func testOpenSystemSettingsRecordsTheInjectedNowAsTheRecoveryStartTime() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: authorization, storage: storage)
        await store.enable()
        XCTAssertEqual(store.state, .denied)

        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        store.openSystemSettings(now: fixedNow)

        XCTAssertEqual(storage.settingsRecoveryIntentStartedAt, fixedNow)
    }

    /// Expiration tests 2 and 3: a fresh store — standing in for the app
    /// relaunching after Settings, matching how
    /// `testRevokedPermissionIsDetectedOnRefreshAndReconciledToTheBackend`
    /// simulates a relaunch elsewhere in this file — with a recovery intent
    /// well under 10 minutes old and permission now authorized completes
    /// APNs and backend setup automatically, and shows On only once the
    /// backend confirms.
    func testFreshStoreWithRecentRecoveryIntentAndAuthorizedPermissionCompletesAutomatically() async {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = startedAt.addingTimeInterval(PushSubscriptionStore.settingsRecoveryIntentLifetime - 60)
        let storage = InMemoryPushInstallationStorage(settingsRecoveryIntentStartedAt: startedAt)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))

        await store.refreshAuthorizationStatus(now: now)

        XCTAssertEqual(authorization.requestCallCount, 0, "no second Apple prompt")
        XCTAssertEqual(registrar.callCount, 1)
        XCTAssertEqual(store.state, .on)
        XCTAssertEqual(storage.lastConfirmedPushEnabled, true)
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt)
    }

    /// Expiration test 4: exactly `settingsRecoveryIntentLifetime` elapsed
    /// is still fresh — the accepted rule (`elapsed <= 10 minutes`) is
    /// inclusive at the boundary, not exclusive.
    func testRecoveryIntentExactlyAtTheLifetimeBoundaryIsStillFresh() async {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = startedAt.addingTimeInterval(PushSubscriptionStore.settingsRecoveryIntentLifetime)
        let storage = InMemoryPushInstallationStorage(settingsRecoveryIntentStartedAt: startedAt)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))

        await store.refreshAuthorizationStatus(now: now)

        XCTAssertEqual(registrar.callCount, 1, "exactly the lifetime elapsed must still count as fresh")
        XCTAssertEqual(store.state, .on)
    }

    /// Expiration tests 5 and 6: one second past the lifetime is stale —
    /// cleared, with no APNs registration and no backend call attempted
    /// from it — and the store remains CommonPlate Off rather than
    /// claiming push turned on.
    func testExpiredRecoveryIntentWithAuthorizedPermissionDoesNotRegisterAndStaysOff() async {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = startedAt.addingTimeInterval(PushSubscriptionStore.settingsRecoveryIntentLifetime + 1)
        let storage = InMemoryPushInstallationStorage(settingsRecoveryIntentStartedAt: startedAt)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)

        await store.refreshAuthorizationStatus(now: now)

        XCTAssertEqual(registrar.callCount, 0, "no APNs registration from a stale intent")
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 0, "no backend call from a stale intent")
        XCTAssertEqual(store.state, .off, "must not claim push turned on")
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt)
    }

    /// Expiration test 7: an expired intent with Apple permission still
    /// denied does not auto-enable and remains truthful — the person still
    /// sees the denied/recovery card, exactly matching Apple's actual
    /// current permission, rather than silently reverting to a neutral Off
    /// that would hide the real denial.
    func testExpiredRecoveryIntentWithDeniedPermissionStaysInRecoveryWithoutAutoEnabling() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: authorization, storage: storage)
        await store.enable()
        XCTAssertEqual(store.state, .denied)

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.openSystemSettings(now: startedAt)
        let now = startedAt.addingTimeInterval(PushSubscriptionStore.settingsRecoveryIntentLifetime + 1)

        await store.refreshAuthorizationStatus(now: now)

        XCTAssertEqual(store.state, .denied, "still truthfully denied, just no longer auto-continuing")
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt, "the stale intent must be cleared")
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 0)
    }

    /// Expiration test 8: a start time in the future (clock skew, or
    /// corrupted storage) is treated as stale, not as "very fresh."
    func testFutureRecoveryIntentTimestampIsTreatedAsStaleAndCleared() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let futureStartedAt = now.addingTimeInterval(60)
        let storage = InMemoryPushInstallationStorage(settingsRecoveryIntentStartedAt: futureStartedAt)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)

        await store.refreshAuthorizationStatus(now: now)

        XCTAssertEqual(registrar.callCount, 0)
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt)
    }

    /// Expiration test 9 (the missing half; the malformed-value half is
    /// covered by `PushInstallationStorageTests` at the concrete storage
    /// layer, since `InMemoryPushInstallationStorage`'s `Date?` type cannot
    /// represent a value that fails to decode as a `Date`): no recovery
    /// intent at all reads as stale with no special-casing needed.
    func testMissingRecoveryIntentIsTreatedAsStale() async {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)

        await store.refreshAuthorizationStatus()

        XCTAssertEqual(registrar.callCount, 0)
    }

    /// Expiration test 10: a stale intent found by one store instance
    /// stays stale for a second, freshly constructed store over the same
    /// storage — simulating the app relaunching — because staleness is a
    /// property of elapsed wall-clock time recorded in storage, not of one
    /// in-memory store's lifetime.
    func testExpiredRecoveryIntentRemainsExpiredAcrossAFreshStoreConstruction() async {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let staleNow = startedAt.addingTimeInterval(PushSubscriptionStore.settingsRecoveryIntentLifetime + 1)
        let storage = InMemoryPushInstallationStorage(settingsRecoveryIntentStartedAt: startedAt)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()

        let firstStore = makeStore(authorization: authorization, registrar: registrar, storage: storage)
        await firstStore.refreshAuthorizationStatus(now: staleNow)
        XCTAssertEqual(registrar.callCount, 0)
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt)

        let secondStore = makeStore(authorization: authorization, registrar: registrar, storage: storage)
        await secondStore.refreshAuthorizationStatus(now: staleNow.addingTimeInterval(1))

        XCTAssertEqual(registrar.callCount, 0)
        XCTAssertEqual(secondStore.state, .off)
    }

    /// Expiration test 11: two rapid foreground refreshes over a single
    /// valid recovery intent must not both attempt registration — the
    /// first consumes it, so the second finds nothing to act on.
    func testRepeatedForegroundRefreshesConsumeAValidRecoveryIntentOnlyOnce() async {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = startedAt.addingTimeInterval(60)
        let storage = InMemoryPushInstallationStorage(settingsRecoveryIntentStartedAt: startedAt)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))

        await store.refreshAuthorizationStatus(now: now)
        XCTAssertEqual(registrar.callCount, 1)
        XCTAssertEqual(store.state, .on)

        await store.refreshAuthorizationStatus(now: now.addingTimeInterval(1))

        XCTAssertEqual(registrar.callCount, 1, "the same intent must not trigger registration twice")
    }

    /// Expiration test 12: a valid recovery intent that fails during APNs
    /// registration does not remain armed — it was already consumed before
    /// the attempt began, so a later retry requires the ordinary explicit
    /// action, not another silent auto-continuation.
    func testValidRecoveryIntentThatFailsDuringAPNsRegistrationDoesNotRemainArmed() async {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = startedAt.addingTimeInterval(60)
        let storage = InMemoryPushInstallationStorage(settingsRecoveryIntentStartedAt: startedAt)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        registrar.outcome = .failure(RemoteNotificationRegistrationError.timedOut)
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)

        await store.refreshAuthorizationStatus(now: now)

        XCTAssertEqual(store.state, .failed)
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt, "the consumed intent must not be restored after failure")
    }

    /// Expiration test 13: explicit Turn off neither creates nor preserves
    /// a Settings-recovery intent — that intent exists only for the
    /// denied-permission recovery path, never for an ordinary disable.
    func testExplicitTurnOffDoesNotCreateOrPreserveARecoveryIntent() async {
        let storage = InMemoryPushInstallationStorage()
        let store = await enabledStore(storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody))

        await store.disable()

        XCTAssertEqual(store.state, .off)
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt)
    }

    /// Expiration test 14: authorized permission with a backend-confirmed
    /// Off installation and no recovery intent pending must not
    /// auto-enable — distinct from the "never confirmed" case already
    /// covered above.
    func testAuthorizedPermissionWithConfirmedOffAndNoRecoveryIntentDoesNotAutoEnable() async {
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: false)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let registrar = StubRemoteNotificationRegistrar()
        let store = makeStore(authorization: authorization, registrar: registrar, storage: storage)

        await store.refreshAuthorizationStatus()

        XCTAssertEqual(registrar.callCount, 0)
        XCTAssertEqual(store.state, .off)
    }

    /// Expiration test 15: discovering and clearing a stale recovery
    /// intent leaves email signup presentation history completely
    /// untouched, exactly like every other push-only mutation in this
    /// store.
    func testDiscoveringAStaleRecoveryIntentLeavesEmailSignupPresentationHistoryUntouched() async {
        let alertStorage = InMemoryAlertSignupPresentationStorage()
        let alertStore = AlertSubscriptionStore(
            service: AlertSubscriptionService(client: APIClient(configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!))),
            presentationStorage: alertStorage
        )

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let staleNow = startedAt.addingTimeInterval(PushSubscriptionStore.settingsRecoveryIntentLifetime + 1)
        let storage = InMemoryPushInstallationStorage(settingsRecoveryIntentStartedAt: startedAt)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let store = makeStore(authorization: authorization, storage: storage)

        await store.refreshAuthorizationStatus(now: staleNow)

        XCTAssertEqual(alertStore.phase, .editing)
        XCTAssertNil(alertStore.rememberedEmail)
        XCTAssertEqual(alertStorage.saveCount, 0)
        XCTAssertEqual(alertStorage.clearCount, 0)
    }

    // MARK: - Explicit Turn off remains meaningful

    /// Required test 13: after an explicit Turn off, a lifecycle refresh
    /// (app activation, screen revisit) must not turn push back on merely
    /// because Apple permission remains authorized.
    func testExplicitTurnOffRemainsOffAcrossLifecycleRefresh() async {
        let storage = InMemoryPushInstallationStorage()
        let store = await enabledStore(storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody))
        await store.disable()
        XCTAssertEqual(store.state, .off)

        // Permission remains authorized throughout — never revoked — which
        // is exactly the case that must not auto-re-enable.
        await store.refreshAuthorizationStatus()

        XCTAssertEqual(store.state, .off)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 2, "no third request from the refresh")
    }

    /// Required test 14: re-enabling after an explicit Turn off requires the
    /// same explicit in-app action as any first-time enable — never implicit.
    func testReEnablingAfterExplicitTurnOffRequiresAnExplicitAction() async {
        let storage = InMemoryPushInstallationStorage()
        let store = await enabledStore(storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody))
        await store.disable()
        XCTAssertEqual(store.state, .off)

        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))
        await store.enable()

        XCTAssertEqual(store.state, .on)
    }

    // MARK: - Installation credential stability across calls

    func testTheSameCredentialIsSentOnEveryCall() async throws {
        let storage = InMemoryPushInstallationStorage()
        let store = makeStore(authorization: alreadyAuthorized(), storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))
        await store.enable()
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody))
        await store.disable()

        let requests = InstallationPushURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 2)
        let credentials = try requests.map { request -> String in
            let body = try XCTUnwrap(request.body)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(json["installationCredential"] as? String)
        }
        XCTAssertEqual(credentials[0], credentials[1])
    }

    // MARK: - Email presentation history is untouched

    func testDrivingPushLeavesEmailSignupPresentationHistoryUntouched() async {
        let alertStorage = InMemoryAlertSignupPresentationStorage()
        let alertStore = AlertSubscriptionStore(
            service: AlertSubscriptionService(client: APIClient(configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!))),
            presentationStorage: alertStorage
        )

        let store = makeStore(authorization: alreadyAuthorized())
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))
        await store.enable()
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: disabledBody))
        await store.disable()

        XCTAssertEqual(alertStore.phase, .editing)
        XCTAssertNil(alertStore.rememberedEmail)
        XCTAssertEqual(alertStorage.saveCount, 0)
        XCTAssertEqual(alertStorage.clearCount, 0)
    }

    // MARK: - Helpers

    private var enabledBody: Data {
        Data(#"{"push":{"enabled":true}}"#.utf8)
    }

    private var disabledBody: Data {
        Data(#"{"push":{"enabled":false}}"#.utf8)
    }

    private func alreadyAuthorized() -> StubPushAuthorizationCoordinator {
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        return authorization
    }

    private func makeService() -> InstallationPushService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstallationPushURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return InstallationPushService(
            client: client,
            participantIdentityStore: installationPushIdentityFixture(client: client)
        )
    }

    private func makeStore(
        authorization: StubPushAuthorizationCoordinator = StubPushAuthorizationCoordinator(),
        registrar: StubRemoteNotificationRegistrar = StubRemoteNotificationRegistrar(),
        storage: InMemoryPushInstallationStorage = InMemoryPushInstallationStorage(),
        settingsOpener: StubPushSettingsOpener = StubPushSettingsOpener()
    ) -> PushSubscriptionStore {
        PushSubscriptionStore(
            service: makeService(),
            installationStorage: storage,
            authorizationCoordinator: authorization,
            remoteNotificationRegistrar: registrar,
            settingsOpener: settingsOpener,
            registrationTimeout: .seconds(5),
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture }
        )
    }

    /// A store already showing `.on`, built fresh from `.off` through a
    /// successful enable call, so disable-focused tests do not have to
    /// reconstruct that path themselves.
    private func enabledStore(storage: InMemoryPushInstallationStorage = InMemoryPushInstallationStorage()) async -> PushSubscriptionStore {
        let store = makeStore(authorization: alreadyAuthorized(), storage: storage)
        InstallationPushURLProtocol.enqueue(.response(statusCode: 200, data: enabledBody))
        await store.enable()
        precondition(store.state == .on, "enabledStore() setup did not reach .on")
        return store
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            await Task.yield()
        }
    }
}
