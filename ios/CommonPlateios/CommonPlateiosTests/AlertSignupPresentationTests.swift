//
//  AlertSignupPresentationTests.swift
//  CommonPlateiosTests
//
// Focused coverage for Week 3 Day 5 Slice 5C: the `Check your email`
// presentation surviving app relaunch, and the boundary that keeps what is
// stored to presentation history rather than subscription truth.
//
// Its own file rather than more of `AlertSignupTests`: that file pins the one
// POST and the presentation states within a session, this one pins what
// outlives the process. The transport double is shared with it, because both
// need the same one thing — the exact number of requests.
//
// Every store built here is given isolated storage: either the in-memory double
// below, or a `UserDefaults` suite created per test and removed in tearDown.
// Nothing in this file can read or write the developer's real preferences.
import Foundation
import XCTest
@testable import CommonPlateios

/// Presentation storage that keeps a record in memory and counts what was done
/// to it. The counts are the point: "a failure wrote nothing" and "a failure
/// deleted nothing" are different claims from "the record still looks right",
/// and only the counts can tell a preserved record from a destroyed-and-rewritten
/// one.
final class InMemoryAlertSignupPresentationStorage: AlertSignupPresentationStorage {
    private(set) var record: AlertSignupPresentationRecord?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(record: AlertSignupPresentationRecord? = nil) {
        self.record = record
    }

    func loadValidPresentation() -> AlertSignupPresentationRecord? {
        record
    }

    func save(_ record: AlertSignupPresentationRecord) {
        self.record = record
        saveCount += 1
    }

    func clear() {
        record = nil
        clearCount += 1
    }
}

@MainActor
final class AlertSignupPresentationTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        // A fresh suite per test. `UserDefaults.standard` is never used here:
        // these cases would otherwise leave a remembered address in whatever
        // process ran them.
        suiteName = "AlertSignupPresentationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AlertSignupURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Writing the record

    func testGenericAcceptedResponsePersistsTheNormalizedAddressAndTheResponseTime() async throws {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))

        let before = Date()
        await store.submit(email: "  Student@NYU.EDU  ")
        let after = Date()

        XCTAssertEqual(store.phase, .checkEmail)
        let record = try XCTUnwrap(makeStorage().loadValidPresentation())
        // Exactly the address that was sent, so a restored screen can never
        // name an address the backend never saw.
        XCTAssertEqual(record.email, "student@nyu.edu")
        XCTAssertEqual(store.rememberedEmail, "student@nyu.edu")
        // The stored instant is ISO-8601 to the second, so it can land up to a
        // second before the call that produced it.
        XCTAssertGreaterThanOrEqual(record.acceptedResponseAt, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(record.acceptedResponseAt, after.addingTimeInterval(1))
    }

    func testARecreatedStoreOverTheSamePersistenceRestoresTheCheckEmailPresentation() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "student@nyu.edu")

        // Standing in for the whole relaunch: a new store reading the same
        // stored value, exactly as `ContentView` builds one at launch.
        let relaunched = makeStore()

        XCTAssertEqual(relaunched.phase, .checkEmail)
        XCTAssertEqual(relaunched.rememberedEmail, "student@nyu.edu")
        XCTAssertNil(relaunched.fieldError)
        XCTAssertNil(relaunched.failure)
        // Nothing was typed this launch, and the field is not on screen.
        XCTAssertTrue(relaunched.email.isEmpty)
    }

    func testRestoredPresentationUsesTheRememberedAddressAndClaimsNoSubscriptionStatus() throws {
        seed(email: "student@nyu.edu", acceptedResponseAt: Date())

        let store = makeStore()
        let record = try XCTUnwrap(makeStorage().loadValidPresentation())

        XCTAssertEqual(store.phase, .checkEmail)
        XCTAssertEqual(store.rememberedEmail, "student@nyu.edu")

        // The restored screen is the existing accepted presentation, whose copy
        // is already proven to claim nothing. Restoring adds no stronger claim
        // because it adds no copy at all.
        XCTAssertEqual(AlertSignupView.checkEmailTitle, "Check your email")
        XCTAssertTrue(AlertSignupView.checkEmailBody.contains("if one is needed"))

        // Nothing observable is named for a subscription state, so no caller can
        // read a local presentation record as backend truth.
        let forbidden = [
            "subscriptionstatus", "issubscribed", "isconfirmed",
            "activesubscriber", "pendingsubscriber"
        ]
        let names = Mirror(reflecting: store).children.compactMap(\.label)
            + Mirror(reflecting: record).children.compactMap(\.label)
            + [UserDefaultsAlertSignupPresentationStorage.key]
        for name in names {
            let lowercased = name.lowercased()
            for claim in forbidden {
                XCTAssertFalse(
                    lowercased.contains(claim),
                    "\(name) is named for subscription status, which a local record cannot know"
                )
            }
        }
    }

    func testRestoringLocalStateSendsNoRequest() {
        seed(email: "student@nyu.edu", acceptedResponseAt: Date())

        let restored = makeStore()
        XCTAssertEqual(restored.phase, .checkEmail)

        // Rejecting a stored record must not reach the network either: there is
        // no endpoint that reports subscription status, and asking for one would
        // be exactly the lookup this slice does not add.
        defaults.set(Data("not a record".utf8), forKey: UserDefaultsAlertSignupPresentationStorage.key)
        let rejected = makeStore()
        XCTAssertEqual(rejected.phase, .editing)

        XCTAssertTrue(AlertSignupURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: - Replacing and clearing

    func testUseADifferentEmailClearsPersistenceAndReturnsToABlankEditableForm() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "student@nyu.edu")
        XCTAssertNotNil(makeStorage().loadValidPresentation())

        store.useDifferentEmail()

        XCTAssertNil(makeStorage().loadValidPresentation())
        XCTAssertNil(defaults.object(forKey: UserDefaultsAlertSignupPresentationStorage.key))
        XCTAssertEqual(store.phase, .editing)
        XCTAssertTrue(store.email.isEmpty)
        XCTAssertNil(store.rememberedEmail)
        // Local only. Nothing was sent, so the earlier address was not
        // unsubscribed, cancelled, or otherwise altered on the backend.
        XCTAssertEqual(AlertSignupURLProtocol.capturedRequests.count, 1)
    }

    func testARecreatedStoreAfterClearingReturnsToEditing() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "student@nyu.edu")
        store.useDifferentEmail()

        let relaunched = makeStore()

        XCTAssertEqual(relaunched.phase, .editing)
        XCTAssertNil(relaunched.rememberedEmail)
        XCTAssertTrue(relaunched.email.isEmpty)
    }

    func testALaterAcceptedAddressReplacesTheEarlierRecord() async throws {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "student@nyu.edu")
        store.useDifferentEmail()

        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "Student@Stern.NYU.edu")

        let record = try XCTUnwrap(makeStorage().loadValidPresentation())
        XCTAssertEqual(record.email, "student@stern.nyu.edu")
        XCTAssertEqual(store.rememberedEmail, "student@stern.nyu.edu")
        // One record, not two: the screen presents one address.
        XCTAssertEqual(makeStore().rememberedEmail, "student@stern.nyu.edu")
    }

    func testDoneLeavesTheRecordInPlaceForTheNextLaunch() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "student@nyu.edu")

        // `Done` dismisses the screen and calls nothing on the store, so the
        // store's whole surface is what could clear the record — and only
        // `useDifferentEmail` does. Re-entering the screen therefore restores
        // the accepted presentation, this launch and the next.
        XCTAssertEqual(store.phase, .checkEmail)
        XCTAssertNotNil(makeStorage().loadValidPresentation())
        XCTAssertEqual(makeStore().phase, .checkEmail)
    }

    // MARK: - Failures never create or replace a record

    func testLocallyRejectedAddressCreatesNoRecord() async {
        let storage = InMemoryAlertSignupPresentationStorage()
        let store = makeStore(storage: storage)

        await store.submit(email: "student@example.com")

        XCTAssertEqual(store.fieldError, .invalidNYUEmail)
        XCTAssertNil(storage.record)
        XCTAssertEqual(storage.saveCount, 0)
        XCTAssertEqual(storage.clearCount, 0)
        XCTAssertNil(store.rememberedEmail)
        XCTAssertTrue(AlertSignupURLProtocol.capturedRequests.isEmpty)
    }

    func testBackendInvalidEmailCreatesNoRecord() async {
        await assertFailureTouchesNoRecord(
            stub: .response(
                statusCode: 400,
                data: errorBody(code: "INVALID_EMAIL", message: "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu.")
            ),
            expectedFailure: nil,
            expectedFieldError: .invalidNYUEmail
        )
    }

    func testPausedSignupCreatesNoRecord() async {
        await assertFailureTouchesNoRecord(
            stub: .response(
                statusCode: 503,
                data: Data(#"{"error":"Meal request alerts are temporarily unavailable"}"#.utf8)
            ),
            expectedFailure: .paused
        )
    }

    func testRateLimitedSignupCreatesNoRecord() async {
        await assertFailureTouchesNoRecord(
            stub: .response(statusCode: 429, data: Data("Too many requests, please try again later.".utf8)),
            expectedFailure: .rateLimited
        )
    }

    func testAmbiguousOutcomeCreatesNoRecord() async {
        // The one that matters most: an uncertain outcome must not be recorded
        // as an accepted one, because a restored `Check your email` would then
        // be a claim the app never received.
        await assertFailureTouchesNoRecord(
            stub: .failure(.networkConnectionLost),
            expectedFailure: .ambiguousOutcome
        )
    }

    func testUnknownFailureCreatesNoRecord() async {
        await assertFailureTouchesNoRecord(
            stub: .response(statusCode: 404, data: Data("Not Found".utf8)),
            expectedFailure: .unknown
        )
    }

    func testAFailedAttemptCannotDestroyAnExistingAcceptedRecord() async {
        let storage = InMemoryAlertSignupPresentationStorage(
            record: AlertSignupPresentationRecord(email: "student@nyu.edu", acceptedResponseAt: Date())
        )
        let store = makeStore(storage: storage)
        XCTAssertEqual(store.phase, .checkEmail)

        // Submitting is refused outside `editing`, so a failure cannot even be
        // reached while a record stands. Nothing is sent and nothing is written.
        AlertSignupURLProtocol.enqueue(.failure(.networkConnectionLost))
        await store.submit(email: "someone@nyu.edu")

        XCTAssertTrue(AlertSignupURLProtocol.capturedRequests.isEmpty)
        XCTAssertEqual(storage.record?.email, "student@nyu.edu")
        XCTAssertEqual(storage.saveCount, 0)
        XCTAssertEqual(storage.clearCount, 0)
        XCTAssertEqual(store.phase, .checkEmail)

        // Only the explicit choice removes it — and once it has, a later
        // failure still writes nothing of its own.
        store.useDifferentEmail()
        XCTAssertEqual(storage.clearCount, 1)
        await store.submit(email: "someone@nyu.edu")
        XCTAssertEqual(store.failure, .ambiguousOutcome)
        XCTAssertEqual(storage.saveCount, 0)
        XCTAssertEqual(storage.clearCount, 1)
    }

    // MARK: - Unusable stored records

    func testCorruptStoredDataIsRemovedWithoutCrashing() {
        let key = UserDefaultsAlertSignupPresentationStorage.key

        for corrupt in [
            Data("not json at all".utf8),
            Data("{}".utf8),
            Data(#"{"email":"student@nyu.edu"}"#.utf8),
            Data(#"["student@nyu.edu","2026-08-04T17:00:00Z"]"#.utf8)
        ] {
            defaults.set(corrupt, forKey: key)

            XCTAssertNil(makeStorage().loadValidPresentation())
            XCTAssertNil(defaults.object(forKey: key), "an unusable record must not be left to be re-read")
            XCTAssertEqual(makeStore().phase, .editing)
        }

        // A value of the wrong type entirely, which a `data(forKey:)` read
        // cannot even return.
        defaults.set("student@nyu.edu", forKey: key)
        XCTAssertNil(makeStorage().loadValidPresentation())
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(makeStore().phase, .editing)
    }

    func testStoredAddressThatIsNoLongerEligibleIsRemoved() {
        let key = UserDefaultsAlertSignupPresentationStorage.key

        for email in ["student@example.com", "student@law.nyu.edu", "student@fake-nyu.edu", "student@", ""] {
            defaults.set(
                Data(#"{"email":"\#(email)","acceptedResponseAt":"2026-08-04T17:00:00Z"}"#.utf8),
                forKey: key
            )

            XCTAssertNil(
                makeStorage().loadValidPresentation(),
                "\(email) no longer satisfies the NYU rule and must not be restored"
            )
            XCTAssertNil(defaults.object(forKey: key))

            let store = makeStore()
            XCTAssertEqual(store.phase, .editing)
            XCTAssertNil(store.rememberedEmail)
        }
    }

    func testStoredMissingOrUnparseableTimestampIsRemoved() {
        let key = UserDefaultsAlertSignupPresentationStorage.key

        for body in [
            #"{"email":"student@nyu.edu"}"#,
            #"{"email":"student@nyu.edu","acceptedResponseAt":""}"#,
            #"{"email":"student@nyu.edu","acceptedResponseAt":"yesterday"}"#,
            #"{"email":"student@nyu.edu","acceptedResponseAt":null}"#,
            // A bare number is the `Date` default encoding, not this record's.
            #"{"email":"student@nyu.edu","acceptedResponseAt":776030400}"#
        ] {
            defaults.set(Data(body.utf8), forKey: key)

            XCTAssertNil(makeStorage().loadValidPresentation(), "\(body) has no usable timestamp")
            XCTAssertNil(defaults.object(forKey: key))
            XCTAssertEqual(makeStore().phase, .editing)
        }
    }

    func testAValidStoredRecordSurvivesAFullRoundTrip() throws {
        let written = AlertSignupPresentationRecord(
            email: "student@stern.nyu.edu",
            acceptedResponseAt: Date(timeIntervalSince1970: 1_785_000_000)
        )
        makeStorage().save(written)

        let read = try XCTUnwrap(makeStorage().loadValidPresentation())
        XCTAssertEqual(read, written)
    }

    // MARK: - Test isolation

    func testStoreTestsUseAnIsolatedPersistenceDomain() async {
        let key = UserDefaultsAlertSignupPresentationStorage.key
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "the suite under test must be empty of app state")

        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "student@nyu.edu")

        XCTAssertNotNil(defaults.object(forKey: key))
        XCTAssertNotEqual(suiteName, Bundle.main.bundleIdentifier)
        // The real application domain is untouched, so running these tests
        // cannot leave a remembered address behind.
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        for value in UserDefaults.standard.dictionaryRepresentation().values {
            XCTAssertFalse(String(describing: value).contains("student@nyu.edu"))
        }
    }

    // MARK: - Helpers

    private func assertFailureTouchesNoRecord(
        stub: AlertSignupURLProtocol.Stub,
        expectedFailure: AlertSignupFailure?,
        expectedFieldError: AlertSignupFieldError? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let storage = InMemoryAlertSignupPresentationStorage()
        let store = makeStore(storage: storage)
        AlertSignupURLProtocol.enqueue(stub)

        await store.submit(email: "student@nyu.edu")

        XCTAssertEqual(store.phase, .editing, file: file, line: line)
        XCTAssertEqual(store.failure, expectedFailure, file: file, line: line)
        XCTAssertEqual(store.fieldError, expectedFieldError, file: file, line: line)
        XCTAssertNil(storage.record, file: file, line: line)
        XCTAssertEqual(storage.saveCount, 0, "a failure must write no record", file: file, line: line)
        XCTAssertEqual(storage.clearCount, 0, "a failure must delete no record", file: file, line: line)
        XCTAssertNil(store.rememberedEmail, file: file, line: line)

        // And nothing is restored on the next launch either.
        XCTAssertEqual(
            makeStore(storage: storage).phase,
            .editing,
            file: file,
            line: line
        )
    }

    private func seed(email: String, acceptedResponseAt: Date) {
        makeStorage().save(
            AlertSignupPresentationRecord(email: email, acceptedResponseAt: acceptedResponseAt)
        )
    }

    private var acceptedBody: Data {
        Data(#"{"message":"If confirmation is needed, check your email for the next step."}"#.utf8)
    }

    private func errorBody(code: String, message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)","fields":null}}"#.utf8)
    }

    private func makeStorage() -> UserDefaultsAlertSignupPresentationStorage {
        UserDefaultsAlertSignupPresentationStorage(defaults: defaults)
    }

    private func makeService() -> AlertSubscriptionService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlertSignupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return AlertSubscriptionService(client: client)
    }

    /// A store over this test's own suite unless a double is supplied. Each call
    /// builds a new storage instance as well, so a "relaunched" store reads the
    /// stored value rather than an object it shares with the first one.
    private func makeStore(storage: AlertSignupPresentationStorage? = nil) -> AlertSubscriptionStore {
        AlertSubscriptionStore(
            service: makeService(),
            presentationStorage: storage ?? makeStorage()
        )
    }
}
