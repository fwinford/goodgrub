import Foundation
import XCTest
@testable import CommonPlateios

/// The exact NYU allowlist, and where it now applies.
///
/// Week 3 Day 5 Slice 5B put this rule on the requester's email field. W3-I1
/// moved the field itself: a request's requester is the verified participant,
/// so the allowlist gates *becoming* one rather than typing one. The rule, the
/// sentence, and the lookalike refusals are unchanged and are still proved
/// here; what changed is that they are proved at participant verification, and
/// that the request form is proved to no longer collect an address at all.
///
/// Alert signup's own coverage stays in `AlertSignupTests`.
@MainActor
final class RequestEmailAllowlistTests: XCTestCase {
    private let nyuMessage =
        "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu."

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - The shared policy

    func testAllowlistIsExactlyTheTwoAcceptedDomains() {
        XCTAssertEqual(NYUEmailPolicy.allowedDomains, ["nyu.edu", "stern.nyu.edu"])
    }

    /// Participant verification and alert signup must not be able to disagree.
    /// This fails if either grows its own allowlist or its own sentence.
    func testParticipantVerificationAndAlertSignupShareOnePolicy() {
        XCTAssertEqual(AlertSignupEmailValidator.allowedDomains, NYUEmailPolicy.allowedDomains)
        XCTAssertEqual(AlertSignupEmailValidator.invalidEmailMessage, NYUEmailPolicy.requiredMessage)
        XCTAssertEqual(
            ParticipantVerificationPresentationError.ineligibleEmail.message,
            "Enter a valid NYU email address."
        )
        XCTAssertEqual(NYUEmailPolicy.requiredMessage, nyuMessage)

        for address in ["taylor@nyu.edu", "taylor@gmail.com", "taylor@law.nyu.edu", "taylor@"] {
            XCTAssertEqual(
                NYUEmailPolicy.isAllowed(address),
                AlertSignupEmailValidator.isAllowedNYUEmail(address),
                address
            )
        }
    }

    // MARK: - The allowlist, at the gate that now applies it

    func testAllowedAddressesMaySendAVerificationCode() {
        for address in [
            "taylor@nyu.edu",
            "taylor@stern.nyu.edu",
            "TAYLOR@NYU.EDU",
            "  taylor@nyu.edu  ",
            "\tTaylor@Stern.NYU.EDU\n",
            "taylor+food@nyu.edu",
            "first.last+tag@stern.nyu.edu"
        ] {
            XCTAssertTrue(
                ParticipantVerificationView.canSendCode(email: address, isRequesting: false),
                address
            )
        }
    }

    /// W4-B1: Continue is actionable for any typed address, but only a
    /// supported one may ever reach `startVerification`; malformed and
    /// unsupported-school addresses are classified locally and send nothing.
    func testRejectedAddressesNeverClassifyAsSupported() {
        for address in [
            // Malformed.
            "taylor@",
            "@nyu.edu",
            "taylor@@nyu.edu",
            "taylor @nyu.edu",
            "taylor@.",
            "nyu.edu",
            "",
            "   ",
            // Not allowlisted.
            "taylor@gmail.com",
            "taylor@example.edu",
            // Unlisted NYU subdomains are not implicitly allowed.
            "taylor@law.nyu.edu",
            "taylor@sps.nyu.edu",
            // Lookalikes a suffix or substring check would wrongly accept.
            "taylor@fake-nyu.edu",
            "taylor@nyu.edu.fake",
            "taylor@nyu.edu.example.com",
            "taylor@notnyu.edu",
            "taylor@nyu.education"
        ] {
            XCTAssertNotEqual(ParticipantEmailClassification.classify(address), .supported, address)
        }
    }

    func testVerificationEntryActionKeepsMalformedAndNonNYUAddressesInline() {
        XCTAssertEqual(
            ParticipantEmailEntryAction.forSubmission("taylor@"),
            .showValidation("Enter a valid email address.")
        )
        XCTAssertEqual(
            ParticipantEmailEntryAction.forSubmission("test@e.com"),
            .showValidation("Enter a valid NYU email address.")
        )
        XCTAssertEqual(
            ParticipantEmailEntryAction.forSubmission("student@nyu.edu"),
            .requestVerification("student@nyu.edu")
        )
        XCTAssertEqual(
            ParticipantEmailEntryAction.forSubmission("student@stern.nyu.edu"),
            .requestVerification("student@stern.nyu.edu")
        )
    }

    /// An ineligible address is refused with the shared sentence and, crucially,
    /// mails nobody: the local check exists so an obviously wrong address does
    /// not spend a request *and* does not put a message in a stranger's inbox.
    func testIneligibleAddressIssuesNoNetworkRequest() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()

        await store.requestCode(for: "taylor@gmail.com")

        XCTAssertEqual(store.verificationError, .ineligibleEmail)
        XCTAssertEqual(store.verificationError?.message, "Enter a valid NYU email address.")
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertFalse(store.isVerified)
        XCTAssertEqual(store.flow?.stage, .enteringEmail)
    }

    func testWalkthroughAddressIssuesNoNetworkRequest() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()

        await store.requestCode(for: "test@e.com")

        XCTAssertEqual(store.verificationError, .ineligibleEmail)
        XCTAssertEqual(store.verificationError?.message, "Enter a valid NYU email address.")
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(store.flow?.stage, .enteringEmail)
    }

    func testAllowedAddressReachesTheVerificationEndpoint() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 202, data: challengeResponse())
        )

        await store.requestCode(for: "taylor@stern.nyu.edu")

        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/participant/verification"]
        )
        XCTAssertNil(store.verificationError)
        // A mailed code is not an identity: nothing is verified until the code
        // comes back and the backend accepts it.
        XCTAssertFalse(store.isVerified)
    }

    /// The address the code is sent for is normalized before it leaves, so the
    /// backend compares and stores the same string the app remembers.
    func testTheVerifiedAddressIsNormalized() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 202, data: challengeResponse())
        )

        await store.requestCode(for: "  TAYLOR@Stern.NYU.EDU  ")

        XCTAssertEqual(
            store.flow?.stage,
            .awaitingCode(
                email: "taylor@stern.nyu.edu",
                expiresAt: try date("2026-07-28T16:10:00.000Z"),
                resendAvailableAt: try date("2026-07-28T16:01:00.000Z")
            )
        )
    }

    // MARK: - The request form no longer collects an address

    func testTheRequestDraftHasNoEmailAtAll() {
        // A field that does not exist cannot be typed wrong, sent, or leaked.
        let mirror = Mirror(reflecting: draft())
        let labels = mirror.children.compactMap(\.label)

        XCTAssertFalse(labels.contains("email"))
        XCTAssertFalse(RequestFoodFormField.allCases.contains(where: {
            String(describing: $0).lowercased().contains("email")
        }))
    }

    func testTheCreatePayloadCarriesNoAddress() throws {
        let payload = try RequestFoodView.makePayload(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                menuPath: .mealExchange,
                timing: .asap,
                preferredPickupTime: try date("2026-07-28T17:00:00.000Z"),
                mealSwipes: 2,
                mealEntries: ["Chicken bowl"] + Array(repeating: "filler", count: 2 - 1) + Array(repeating: "", count: RequestFoodFormDraft.maxMealSwipes - 2)
            ),
            now: try date("2026-07-28T16:00:00.000Z"),
            calendar: utcCalendar
        )
        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.contains("email"))
        XCTAssertFalse(json.contains("@"))
    }

    // MARK: - No Contact section (W3-I3)

    /// Request Food's Contact section is removed entirely (W3-I3): verified
    /// participant identity moved to app-level Home presentation, and the
    /// eligibility/purpose copy that lived beside it went with it. This reads
    /// the file's own source rather than rendering the view, matching this
    /// suite's existing source-inspection pattern elsewhere in this target, so
    /// it fails on any reintroduction under a different property or section
    /// name.
    func testRequestFoodHasNoContactSection() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(#"Section("Contact")"#))
        XCTAssertFalse(source.contains("Posting as"))
        XCTAssertFalse(source.contains("emailEligibilityNotice"))
        XCTAssertFalse(source.contains("emailPurposeNotice"))
        XCTAssertFalse(source.contains("verificationRequiredNotice"))
    }

    /// Walks up from this file to the repository root, so the source-text
    /// assertion above reads the real tracked file rather than a copy.
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

    // MARK: - Backend refusal

    /// The create outcome mappings the allowlist code used to occupy. An
    /// unreadable outcome must still be ambiguous rather than an identity
    /// problem, and the participant codes must each have their own answer.
    func testCreateOutcomeMappingsCoverTheParticipantCodes() {
        let expected: [(String, RequestCreatePresentationError)] = [
            ("INVALID_REQUEST", .invalidRequest),
            ("REQUEST_LIMIT_REACHED", .requestLimitReached),
            ("RATE_LIMITED", .rateLimited),
            ("PUBLIC_ACTIONS_PAUSED", .publicActionsPaused),
            ("REQUEST_CREATION_FAILED", .creationFailed),
            ("SOMETHING_NEW", .creationFailed),
            (ParticipantErrorCode.verificationRequired, .verificationRequired),
            (ParticipantErrorCode.authorityInvalid, .verificationExpired),
            (ParticipantErrorCode.verificationUnavailable, .verificationUnavailable),
            (ParticipantErrorCode.principalMismatch, .principalMismatch)
        ]

        for (code, presentation) in expected {
            XCTAssertEqual(
                RequestCreatePresentationError.map(
                    RequestServiceError.serverError(code: code, message: "detail")
                ),
                presentation,
                code
            )
        }

        XCTAssertEqual(
            RequestCreatePresentationError.map(
                RequestServiceError.ambiguousCreateOutcome(underlying: URLError(.timedOut))
            ),
            .ambiguous
        )
        XCTAssertEqual(
            RequestCreatePresentationError.map(RequestServiceError.operationInProgress),
            .operationInProgress
        )
    }

    /// "Could not check" must never read as "you are not verified".
    func testUnavailableVerificationIsNotPresentedAsUnverified() {
        let unavailable = RequestCreatePresentationError.verificationUnavailable
        XCTAssertNotEqual(unavailable.message, RequestCreatePresentationError.verificationRequired.message)
        XCTAssertNotEqual(unavailable.message, RequestCreatePresentationError.verificationExpired.message)
    }

    // MARK: - Unchanged submit-button and duplicate-submit behavior

    func testDuplicateSubmitAndAmbiguityGuardsStillApply() {
        XCTAssertTrue(RequestFoodView.isSubmissionEnabled(
            draft: draft(),
            submissionError: nil,
            isCreating: false
        ))
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: draft(),
            submissionError: nil,
            isCreating: true
        ))
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: draft(),
            submissionError: .ambiguous,
            isCreating: false
        ))
    }

    func testStoreStillRefusesASecondInFlightCreate() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 201, data: createdResponse(), delay: 0.05)
        )

        async let first: Void = store.createRequest(payload())
        try await Task.sleep(nanoseconds: 10_000_000)

        do {
            try await store.createRequest(payload())
            XCTFail("A second in-flight create must be refused")
        } catch RequestServiceError.operationInProgress {
            // Expected: refused before any second POST.
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }

        try await first
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, ["/api/request"])
    }

    // MARK: - Fixtures

    private func draft(timing: RequestTiming = .asap) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: "140 E 14th St"),
            menuPath: .mealExchange,
            timing: timing,
            preferredPickupTime: try! date("2026-07-28T17:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )
    }

    private func payload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: ["Chicken bowl"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func challengeResponse() -> Data {
        Data(#"""
        {"verification":{
          "expiresAt": "2026-07-28T16:10:00.000Z",
          "resendAvailableAt": "2026-07-28T16:01:00.000Z"
        }}
        """#.utf8)
    }

    private func createdResponse() -> Data {
        Data(#"""
        {"request":{
          "id": "64b000000000000000000001",
          "vendor": "Jasper Kane Cafe",
          "food": "Chicken bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "open",
          "createdAt": "2026-07-28T16:00:00.000Z",
          "expiresAt": "2026-07-28T19:00:00.000Z"
        }}
        """#.utf8)
    }

    private func stubbedClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
    }

    private func makeIdentityStore() -> ParticipantIdentityStore {
        ParticipantIdentityStore(
            service: ParticipantVerificationService(client: stubbedClient()),
            storage: InMemoryParticipantIdentityStorage()
        )
    }

    private func makeStore() -> RequestStore {
        RequestStore(
            service: RequestService(client: stubbedClient()),
            installationCredentialProvider: { "test-installation-credential" },
            // W3-I1: a verified participant, so the gate is not what these
            // cases are proving.
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }
}

/// An in-memory `ParticipantIdentityStorage`, so identity tests never touch the
/// simulator's real `UserDefaults` and never leak one case's identity into the
/// next. `UserDefaultsParticipantIdentityStorage` has its own coverage.
final class InMemoryParticipantIdentityStorage: ParticipantIdentityStorage {
    private(set) var stored: ParticipantIdentityRecord?
    private(set) var clearCount = 0

    init(stored: ParticipantIdentityRecord? = nil) {
        self.stored = stored
    }

    func loadValidIdentity() -> ParticipantIdentityRecord? {
        stored
    }

    @discardableResult
    func save(_ record: ParticipantIdentityRecord) -> Bool {
        stored = record
        return true
    }

    func clear() {
        stored = nil
        clearCount += 1
    }
}

final class InMemoryParticipantAuthorityStorage: ParticipantAuthorityStorage {
    private(set) var stored: StoredParticipantAuthority?
    private(set) var clearCount = 0
    var permitsSave = true

    init(stored: StoredParticipantAuthority? = nil) {
        self.stored = stored
    }

    func load() -> StoredParticipantAuthority? {
        stored
    }

    func replaceForTest(_ record: StoredParticipantAuthority?) {
        stored = record
    }

    @discardableResult
    func save(_ record: StoredParticipantAuthority) -> Bool {
        guard permitsSave else { return false }
        stored = record
        return true
    }

    func clear() {
        stored = nil
        clearCount += 1
    }
}
