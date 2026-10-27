import Foundation
import XCTest
@testable import CommonPlateios

let canonicalParticipantAuthorityFixture =
    "64c0000000000000000000a1.1." + String(repeating: "A", count: 43)
let replacementParticipantAuthorityFixture =
    "64c0000000000000000000b2.1." + String(repeating: "B", count: 42) + "A"

/// W3-I1 participant identity: the verification flow, what is remembered
/// across launches, and what happens when the backend refuses what was
/// remembered.
///
/// The rule these cases exist to hold: this app never decides it is verified.
/// Only a decoded backend response establishes identity, and only a backend
/// refusal takes one away.
@MainActor
final class ParticipantIdentityTests: XCTestCase {
    private let principal = "taylor@nyu.edu"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Establishing identity

    func testRequestWithoutAnActiveVerificationFlowShowsAnErrorInsteadOfSilentlyIgnoring() async {
        let store = makeStore(storage: InMemoryParticipantIdentityStorage())

        await store.requestCode(for: principal)

        XCTAssertEqual(store.verificationError, .temporarilyUnavailable)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
    }

    func testAVerifiedCodeEstablishesAndRemembersIdentity() async throws {
        let storage = InMemoryParticipantIdentityStorage()
        let store = makeStore(storage: storage)
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse()))

        await store.requestCode(for: principal)
        let verified = await store.submitCode("424242")

        XCTAssertTrue(verified)
        XCTAssertTrue(store.isVerified)
        XCTAssertEqual(store.identity?.principal, principal)
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
        // Remembered, so the next launch on this installation does not ask again.
        XCTAssertEqual(storage.stored?.principal, principal)
        XCTAssertEqual(storage.stored?.authority, canonicalParticipantAuthorityFixture)
        // The flow is over; nothing is left presenting a form.
        XCTAssertNil(store.flow)
        XCTAssertNil(store.verificationError)
    }

    func testSendingACodeIsNotVerification() async throws {
        let storage = InMemoryParticipantIdentityStorage()
        let store = makeStore(storage: storage)
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))

        await store.requestCode(for: principal)

        // A mailed code proves nothing until it comes back and the backend
        // accepts it.
        XCTAssertFalse(store.isVerified)
        XCTAssertNil(store.currentAuthority())
        XCTAssertNil(storage.stored)
    }

    // W4-UI1 Checkpoint 1 (D, Faith 2026-10-23): a flow's first-ever
    // `requestCode` call must never optimistically claim a code it did not
    // itself just send — a `resendTooSoon` refusal here could belong to an
    // older, foreign, or already-expired attempt from a different session.
    // Entering code entry without this flow ever confirming a send could
    // falsely say "Code sent" and strand the student with resend blocked.
    func testAFreshFlowsFirstResendTooSoonDoesNotEnterCodeEntry() async throws {
        let storage = InMemoryParticipantIdentityStorage()
        let store = makeStore(storage: storage)
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 429, data: errorResponse(code: "VERIFICATION_RESEND_TOO_SOON"))
        )

        await store.requestCode(for: principal)

        XCTAssertEqual(store.flow?.stage, .enteringEmail)
        XCTAssertEqual(store.verificationError, .resendTooSoon)
        XCTAssertFalse(store.isVerified)
        XCTAssertNil(storage.stored)
    }

    // The behavior the above test's old name described — a code sent
    // moments ago lets the student enter it instead of stranding them —
    // still holds, but only once THIS flow has itself confirmed sending a
    // code to this exact address (e.g. it backed out of the code screen and
    // retried the same address).
    func testACodeSentMomentsAgoInThisFlowLetsTheStudentEnterItInsteadOfStrandingThem() async throws {
        let storage = InMemoryParticipantIdentityStorage()
        let store = makeStore(storage: storage)
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await store.requestCode(for: principal)
        guard case .awaitingCode? = store.flow?.stage else {
            return XCTFail("setup: the initial send must succeed")
        }
        store.returnToEmailEntry()
        XCTAssertEqual(store.flow?.stage, .enteringEmail)

        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 429, data: errorResponse(code: "VERIFICATION_RESEND_TOO_SOON"))
        )
        await store.requestCode(for: principal)

        guard case .awaitingCode(let email, _, _)? = store.flow?.stage else {
            return XCTFail("a code this flow already confirmed sending must lead to the code entry step")
        }
        XCTAssertEqual(email, principal)
        XCTAssertNil(store.verificationError)
        // Entering the code stage proves nothing; only a redeem verifies.
        XCTAssertFalse(store.isVerified)
        XCTAssertNil(storage.stored)
    }

    func testEveryRefusedCodeLeavesTheAppUnverified() async throws {
        let cases: [(Int, String, ParticipantVerificationPresentationError)] = [
            (400, "VERIFICATION_CODE_INVALID", .codeIncorrect),
            (410, "VERIFICATION_CODE_EXPIRED", .codeExpired),
            (409, "VERIFICATION_CODE_NOT_REQUESTED", .codeNotRequested),
            (429, "VERIFICATION_ATTEMPTS_EXCEEDED", .attemptsExceeded),
            (503, "VERIFICATION_UNAVAILABLE", .temporarilyUnavailable)
        ]

        for (status, code, expected) in cases {
            RequestFetchingURLProtocol.reset()
            let storage = InMemoryParticipantIdentityStorage()
            let store = makeStore(storage: storage)
            store.beginVerificationIfNeeded()
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
            RequestFetchingURLProtocol.enqueue(
                .response(statusCode: status, data: errorResponse(code: code))
            )

            await store.requestCode(for: principal)
            let verified = await store.submitCode("999999")

            XCTAssertFalse(verified, code)
            XCTAssertFalse(store.isVerified, code)
            XCTAssertNil(store.currentAuthority(), code)
            XCTAssertNil(storage.stored, code)
            XCTAssertEqual(store.verificationError, expected, code)
        }
    }

    /// An unreadable or malformed success is not a success. A response with a
    /// principal and no credential — or a credential and no principal — must
    /// not become a half-identity the app then acts on.
    func testAnIncompleteSuccessResponseEstablishesNothing() async throws {
        for body in [
            #"{"participant":{"email":"taylor@nyu.edu"},"authority":""}"#,
            #"{"participant":{"email":""},"authority":"a.1.b"}"#,
            #"{"participant":{"email":"taylor@nyu.edu"}}"#,
            #"not json at all"#
        ] {
            RequestFetchingURLProtocol.reset()
            let storage = InMemoryParticipantIdentityStorage()
            let store = makeStore(storage: storage)
            store.beginVerificationIfNeeded()
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
            RequestFetchingURLProtocol.enqueue(
                .response(statusCode: 200, data: Data(body.utf8))
            )

            await store.requestCode(for: principal)
            let verified = await store.submitCode("424242")

            XCTAssertFalse(verified, body)
            XCTAssertFalse(store.isVerified, body)
            XCTAssertNil(storage.stored, body)
        }
    }

    // MARK: - Same-install restoration and unusable stored state

    func testARememberedIdentityIsRestoredOnTheNextLaunch() {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date(timeIntervalSince1970: 1_000)
            )
        )

        // A fresh store is what a relaunch produces.
        let store = makeStore(storage: storage)

        XCTAssertTrue(store.isVerified)
        XCTAssertEqual(store.identity?.principal, principal)
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
        // Restoration reads no network: there is no validity endpoint, and the
        // backend answers that question on the next participant action.
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
    }

    func testUnusableStoredStateRequiresVerificationAgain() {
        let defaults = isolatedDefaults()
        let authorityStorage = InMemoryParticipantAuthorityStorage()
        let storage = UserDefaultsParticipantIdentityStorage(
            defaults: defaults,
            authorityStorage: authorityStorage
        )

        for unusable in [
            // Not a record at all.
            Data("not json".utf8),
            // A credential with no principal to act as.
            Data(#"{"principal":"","authority":"a.1.b","verifiedAt":"2026-08-01T00:00:00Z"}"#.utf8),
            // A principal with no credential to prove it.
            Data(#"{"principal":"taylor@nyu.edu","authority":"","verifiedAt":"2026-08-01T00:00:00Z"}"#.utf8),
            // An address that is no longer one this app may act as.
            Data(#"{"principal":"taylor@gmail.com","authority":"a.1.b","verifiedAt":"2026-08-01T00:00:00Z"}"#.utf8),
            // A malformed timestamp makes the whole record undecodable.
            Data(#"{"principal":"taylor@nyu.edu","authority":"a.1.b","verifiedAt":"whenever"}"#.utf8)
        ] {
            defaults.set(unusable, forKey: UserDefaultsParticipantIdentityStorage.key)

            XCTAssertNil(storage.loadValidIdentity())
            // Rejected once and removed, rather than re-rejected every launch.
            XCTAssertNil(defaults.object(forKey: UserDefaultsParticipantIdentityStorage.key))
        }
    }

    func testStoredStateOfTheWrongTypeEntirelyIsRemoved() {
        let defaults = isolatedDefaults()
        let storage = UserDefaultsParticipantIdentityStorage(
            defaults: defaults,
            authorityStorage: InMemoryParticipantAuthorityStorage()
        )
        defaults.set("a bare string", forKey: UserDefaultsParticipantIdentityStorage.key)

        XCTAssertNil(storage.loadValidIdentity())
        XCTAssertNil(defaults.object(forKey: UserDefaultsParticipantIdentityStorage.key))
    }

    func testANewInstallationHasNoIdentity() {
        // What a reinstall looks like: UserDefaults did not survive, while a
        // local Keychain item may have. The surviving bearer is deliberately
        // unusable without the old installation's matching marker.
        let authorityStorage = InMemoryParticipantAuthorityStorage(
            stored: StoredParticipantAuthority(
                principal: principal,
                installationBinding: UUID().uuidString,
                authority: canonicalParticipantAuthorityFixture
            )
        )
        let store = makeStore(
            storage: UserDefaultsParticipantIdentityStorage(
                defaults: isolatedDefaults(),
                authorityStorage: authorityStorage
            )
        )

        XCTAssertFalse(store.isVerified)
        XCTAssertNil(store.currentAuthority())
        XCTAssertNil(authorityStorage.stored)
    }

    func testARoundTripThroughRealStorageSurvives() {
        let defaults = isolatedDefaults()
        let authorityStorage = InMemoryParticipantAuthorityStorage()
        let storage = UserDefaultsParticipantIdentityStorage(
            defaults: defaults,
            authorityStorage: authorityStorage
        )
        let record = ParticipantIdentityRecord(
            principal: principal,
            authority: canonicalParticipantAuthorityFixture,
            verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        storage.save(record)

        XCTAssertEqual(storage.loadValidIdentity(), record)
    }

    func testADeviceMigrationMarkerCannotRestoreWithoutTheThisDeviceOnlyBearer() {
        let defaults = isolatedDefaults()
        let authorityStorage = InMemoryParticipantAuthorityStorage()
        let storage = UserDefaultsParticipantIdentityStorage(
            defaults: defaults,
            authorityStorage: authorityStorage
        )
        XCTAssertTrue(storage.save(ParticipantIdentityRecord(
            principal: principal,
            authority: canonicalParticipantAuthorityFixture,
            verifiedAt: Date()
        )))

        // Models restored preferences on another device. A real
        // ThisDeviceOnly Keychain item is excluded from that restore.
        authorityStorage.replaceForTest(nil)

        XCTAssertNil(storage.loadValidIdentity())
        XCTAssertNil(defaults.object(forKey: UserDefaultsParticipantIdentityStorage.key))
    }

    func testMismatchedInstallationHalvesAreRejected() {
        let defaults = isolatedDefaults()
        let authorityStorage = InMemoryParticipantAuthorityStorage()
        let storage = UserDefaultsParticipantIdentityStorage(
            defaults: defaults,
            authorityStorage: authorityStorage
        )
        XCTAssertTrue(storage.save(ParticipantIdentityRecord(
            principal: principal,
            authority: canonicalParticipantAuthorityFixture,
            verifiedAt: Date()
        )))
        authorityStorage.replaceForTest(StoredParticipantAuthority(
            principal: principal,
            installationBinding: UUID().uuidString,
            authority: canonicalParticipantAuthorityFixture
        ))

        XCTAssertNil(storage.loadValidIdentity())
        XCTAssertNil(defaults.object(forKey: UserDefaultsParticipantIdentityStorage.key))
        XCTAssertNil(authorityStorage.stored)
    }

    func testMatchingInstallationBindingWithDifferentProtectedPrincipalIsRejected() {
        let defaults = isolatedDefaults()
        let authorityStorage = InMemoryParticipantAuthorityStorage()
        let storage = UserDefaultsParticipantIdentityStorage(
            defaults: defaults,
            authorityStorage: authorityStorage
        )
        XCTAssertTrue(storage.save(ParticipantIdentityRecord(
            principal: principal,
            authority: canonicalParticipantAuthorityFixture,
            verifiedAt: Date()
        )))
        let secured = try! XCTUnwrap(authorityStorage.stored)
        authorityStorage.replaceForTest(StoredParticipantAuthority(
            principal: "someone-else@nyu.edu",
            installationBinding: secured.installationBinding,
            authority: secured.authority
        ))

        let store = makeStore(storage: storage)

        XCTAssertFalse(store.isVerified)
        XCTAssertNil(store.identity)
        XCTAssertNil(store.currentAuthority())
        XCTAssertNil(defaults.object(forKey: UserDefaultsParticipantIdentityStorage.key))
        XCTAssertNil(authorityStorage.stored)
    }

    func testMalformedNonemptyStoredAuthorityIsNotDisplayedAsVerified() {
        for malformed in [
            "not-empty",
            "64c0000000000000000000a1.01." + String(repeating: "A", count: 43),
            "64C0000000000000000000A1.1." + String(repeating: "A", count: 43),
            String(repeating: "١", count: 24) + ".1." + String(repeating: "A", count: 43),
            "64c0000000000000000000a1.١." + String(repeating: "A", count: 43),
            "64c0000000000000000000a1.1.short",
            "64c0000000000000000000a1.1." + String(repeating: "!", count: 43),
            // Allowed base64url characters and the right length, but the last
            // character carries non-zero unused bits and is not canonical.
            "64c0000000000000000000a1.1." + String(repeating: "B", count: 43),
        ] {
            let defaults = isolatedDefaults()
            let authorityStorage = InMemoryParticipantAuthorityStorage()
            let storage = UserDefaultsParticipantIdentityStorage(
                defaults: defaults,
                authorityStorage: authorityStorage
            )
            XCTAssertTrue(storage.save(ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )))
            let binding = try! XCTUnwrap(authorityStorage.stored?.installationBinding)
            authorityStorage.replaceForTest(StoredParticipantAuthority(
                principal: principal,
                installationBinding: binding,
                authority: malformed
            ))

            let store = makeStore(storage: storage)

            XCTAssertFalse(store.isVerified, malformed)
            XCTAssertNil(store.identity, malformed)
            XCTAssertNil(store.currentAuthority(), malformed)
        }
    }

    func testCanonicalAuthorityShapeDoesNotAuthenticateLocally() {
        // This signature is opaque fixture text, not one signed by the backend.
        // Local restoration checks only canonical shape; the next participant
        // action is where the backend authenticates it.
        XCTAssertTrue(ParticipantAuthorityShape.isCanonical(
            canonicalParticipantAuthorityFixture
        ))
    }

    // MARK: - Backend refusal of a stored identity

    func testABackendRefusalDiscardsTheStoredIdentity() {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeStore(storage: storage)

        store.discardRejectedIdentity()

        // The backend is authoritative: a credential it will not accept is not
        // an identity, whatever this installation remembered.
        XCTAssertFalse(store.isVerified)
        XCTAssertNil(store.currentAuthority())
        XCTAssertNil(storage.stored)
        XCTAssertEqual(storage.clearCount, 1)
        // Explained once, so the next verification screen says why it is asking.
        XCTAssertTrue(store.wasIdentityRevoked)

        store.acknowledgeRevocationNotice()
        XCTAssertFalse(store.wasIdentityRevoked)
    }

    // MARK: - Change Email

    func testChangeEmailKeepsTheCurrentIdentityUntilTheReplacementVerifies() async throws {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 400, data: errorResponse(code: "VERIFICATION_CODE_INVALID"))
        )

        store.beginEmailReplacement()
        XCTAssertEqual(store.flow?.purpose, .emailReplacement)
        // Opening the flow changes nothing.
        XCTAssertEqual(store.identity?.principal, principal)

        await store.requestCode(for: "replacement@stern.nyu.edu")
        // A code mailed to the replacement changes nothing either.
        XCTAssertEqual(store.identity?.principal, principal)
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)

        let verified = await store.submitCode("999999")

        XCTAssertFalse(verified)
        // A failed replacement does not destroy the identity it was replacing.
        XCTAssertEqual(store.identity?.principal, principal)
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
        XCTAssertEqual(storage.stored?.principal, principal)
    }

    func testAnAbandonedReplacementLeavesTheCurrentIdentityActive() async throws {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))

        store.beginEmailReplacement()
        await store.requestCode(for: "replacement@stern.nyu.edu")
        store.cancelVerification()

        XCTAssertNil(store.flow)
        XCTAssertEqual(store.identity?.principal, principal)
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
    }

    func testASuccessfulReplacementSwitchesIdentityCompletely() async throws {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(
            .response(
                statusCode: 200,
                data: verifiedResponse(
                    email: "replacement@stern.nyu.edu",
                    authority: replacementParticipantAuthorityFixture
                )
            )
        )

        store.beginEmailReplacement()
        await store.requestCode(for: "replacement@stern.nyu.edu")
        let verified = await store.submitCode("424242")

        XCTAssertTrue(verified)
        XCTAssertEqual(store.identity?.principal, "replacement@stern.nyu.edu")
        // Replaced, not merged: there is no way left to act as the old
        // principal from this installation.
        XCTAssertEqual(store.currentAuthority(), replacementParticipantAuthorityFixture)
        XCTAssertEqual(storage.stored?.principal, "replacement@stern.nyu.edu")
        XCTAssertNil(store.flow)
    }

    // MARK: - Flow guards

    func testASecondGatedTapDoesNotRestartTheFlow() async throws {
        let store = makeStore(storage: InMemoryParticipantIdentityStorage())
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))

        store.beginVerificationIfNeeded()
        await store.requestCode(for: principal)
        guard case .awaitingCode = store.flow?.stage else {
            return XCTFail("expected the code stage")
        }

        store.beginVerificationIfNeeded()

        // Still on the code step: a second tap must not throw away the code the
        // student is already reading out of their inbox.
        guard case .awaitingCode = store.flow?.stage else {
            return XCTFail("a second gated tap must not restart the flow")
        }
    }

    func testAVerifiedInstallationOpensNoFlow() {
        let store = makeStore(
            storage: InMemoryParticipantIdentityStorage(
                stored: ParticipantIdentityRecord(
                    principal: principal,
                    authority: canonicalParticipantAuthorityFixture,
                    verifiedAt: Date()
                )
            )
        )

        store.beginVerificationIfNeeded()

        XCTAssertNil(store.flow)
    }

    func testACodeCannotBeSubmittedBeforeOneIsRequested() async throws {
        let store = makeStore(storage: InMemoryParticipantIdentityStorage())
        store.beginVerificationIfNeeded()

        let verified = await store.submitCode("424242")

        XCTAssertFalse(verified)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
    }

    // MARK: - Masking

    func testTheRememberedAddressIsShownMaskedButRecognizable() {
        XCTAssertEqual(
            ParticipantIdentityStore.maskedAddress("taylor@nyu.edu"),
            "ta••••@nyu.edu"
        )
        XCTAssertEqual(
            ParticipantIdentityStore.maskedAddress("TAYLOR@Stern.NYU.EDU"),
            "ta••••@stern.nyu.edu"
        )
        // Short local parts still hide something.
        XCTAssertEqual(ParticipantIdentityStore.maskedAddress("ab@nyu.edu"), "a•@nyu.edu")
        XCTAssertEqual(ParticipantIdentityStore.maskedAddress("a@nyu.edu"), "a•@nyu.edu")
    }

    func testMaskingKeepsTheDomainSoTheTwoAllowedOnesStayDistinguishable() {
        let nyu = ParticipantIdentityStore.maskedAddress("taylor@nyu.edu")
        let stern = ParticipantIdentityStore.maskedAddress("taylor@stern.nyu.edu")

        XCTAssertNotEqual(nyu, stern)
        XCTAssertTrue(nyu.hasSuffix("@nyu.edu"))
        XCTAssertTrue(stern.hasSuffix("@stern.nyu.edu"))
    }

    func testTheMaskedFormNeverContainsTheWholeLocalPart() {
        let masked = ParticipantIdentityStore.maskedAddress("exampleperson@nyu.edu")

        XCTAssertFalse(masked.contains("exampleperson"))
        XCTAssertTrue(masked.contains("•"))
    }

    // MARK: - The credential never becomes view-readable state

    func testTheCredentialIsNotOnThePublishedPresentation() {
        let store = makeStore(
            storage: InMemoryParticipantIdentityStorage(
                stored: ParticipantIdentityRecord(
                    principal: principal,
                    authority: canonicalParticipantAuthorityFixture,
                    verifiedAt: Date()
                )
            )
        )
        let identity = try? XCTUnwrap(store.identity)

        // The same boundary `RequestStore` keeps around the raw claim token: a
        // credential must not be reachable from anything a screen renders.
        let described = String(describing: identity)
        XCTAssertFalse(described.contains(String(repeating: "A", count: 43)))
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
    }

    // MARK: - Fixtures

    private func makeStore(storage: ParticipantIdentityStorage) -> ParticipantIdentityStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        let store = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: storage
        )
        store.configureInstallationAssociation { _ in }
        return store
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "com.commonplate.tests.participant.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func challengeResponse() -> Data {
        Data(#"""
        {"verification":{
          "expiresAt": "2026-07-28T16:10:00.000Z",
          "resendAvailableAt": "2026-07-28T16:01:00.000Z"
        }}
        """#.utf8)
    }

    private func verifiedResponse(
        email: String = "taylor@nyu.edu",
        authority: String = canonicalParticipantAuthorityFixture
    ) -> Data {
        Data(#"{"participant":{"email":"\#(email)"},"authority":"\#(authority)"}"#.utf8)
    }

    private func errorResponse(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }
}
