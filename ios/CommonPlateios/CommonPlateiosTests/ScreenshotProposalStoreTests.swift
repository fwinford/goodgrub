//
//  ScreenshotProposalStoreTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W4-S1 non-authoritative proposal store: explicit
// manual-edit provenance (not value equality), selection-identity/generation
// concurrency (last-selection-wins, AI-Off mid-flight, busy-state
// generation-safety), ineligible/no-useful-extraction notices, and
// AI-disabled gating. W4-S3: the network-facing cases go through the
// local-first flow and the explicit `Use external AI` action
// (`analyzeThroughExternalFallback`).
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own transport double, capturing headers and supporting an injectable
/// delay — mirrors `EmailAlertStateURLProtocol`.
final class ScreenshotProposalURLProtocol: URLProtocol {
    struct CapturedRequest {
        let path: String
        let method: String
        let headers: [String: String]
        let body: Data?
    }

    struct Stub {
        let statusCode: Int
        let data: Data
        let delay: TimeInterval

        static func response(statusCode: Int = 200, data: Data, delay: TimeInterval = 0) -> Stub {
            Stub(statusCode: statusCode, data: data, delay: delay)
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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(
            CapturedRequest(
                path: request.url?.path ?? "",
                method: request.httpMethod ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    let bufferSize = 4096
                    var buffer = [UInt8](repeating: 0, count: bufferSize)
                    while stream.hasBytesAvailable {
                        let read = stream.read(&buffer, maxLength: bufferSize)
                        if read > 0 { data.append(buffer, count: read) }
                        else { break }
                    }
                    return data
                }
            )
        )
        Self.lock.unlock()

        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let completeRequest = {
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

/// W4-S3 consent-authority revision: defaults to a VALID consent record
/// already granted, so existing tests that want Screenshot Assistance On by
/// default (the pre-revision behavior) do not all need to call `grant...`
/// themselves. Tests of the fail-closed legacy-reset behavior construct their
/// own storage instead (`UserDefaultsScreenshotProposalPreferencesStorage`
/// directly, or a purpose-built in-memory double).
final class InMemoryScreenshotProposalPreferencesStorage: ScreenshotProposalPreferencesStoring {
    var hasValidScreenshotAssistanceConsent: Bool = true
    var hasCompletedScreenshotHelp: Bool = false

    func grantScreenshotAssistanceConsent() {
        hasValidScreenshotAssistanceConsent = true
    }

    func revokeScreenshotAssistanceConsent() {
        hasValidScreenshotAssistanceConsent = false
    }
}

@MainActor
final class ScreenshotProposalStoreTests: XCTestCase {
    override func tearDown() {
        ScreenshotProposalURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore(
        preferences: ScreenshotProposalPreferencesStoring = InMemoryScreenshotProposalPreferencesStorage()
    ) -> ScreenshotProposalStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        // Production Requester wiring (empty local qualification, real
        // network-backed external provider); only Vision is swapped for the
        // synthetic recognizer, since the tests' screenshots are synthetic.
        return makeProductionWiredRequesterStore(
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: preferences
        )
    }

    private let palladium = SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" }!
    private let crave370 = SupportedVendorCatalog.diningSpots.first { $0.name == "Cafe 370" }!

    private let noManualEdits = ScreenshotFieldManualEditState()

    /// These direct `apply` tests exercise behavior after a valid State E
    /// outcome. Keep the venue authority explicit here rather than weakening
    /// the production gate or changing a shared transport fixture.
    private func stateEOutcome(
        _ proposal: ScreenshotProposal,
        eligible: Bool = true,
        anchor: DiningSpot? = nil
    ) -> ScreenshotProposalOutcome {
        let anchor = anchor ?? palladium
        var anchoredProposal = proposal
        if anchoredProposal.selectedDiningSpot == nil {
            anchoredProposal.selectedDiningSpot = anchor
        }
        return ScreenshotProposalOutcome(
            eligible: eligible,
            proposal: anchoredProposal,
            venueDisposition: .supported(anchor)
        )
    }

    private func responseBody(
        eligible: Bool,
        locationName: String? = nil,
        mealItems: [String]? = nil,
        mealSwipes: Int? = nil,
        delay: TimeInterval = 0
    ) -> ScreenshotProposalURLProtocol.Stub {
        var proposal: [String: Any] = [:]
        if let locationName {
            proposal["selectedDiningSpot"] = ["name": locationName, "address": "irrelevant"]
        }
        if let mealItems {
            proposal["mealItems"] = mealItems
        }
        if let mealSwipes {
            proposal["mealSwipes"] = mealSwipes
        }
        proposal["selectedDiningSpot"] = [
            "name": "Jasper Kane Cafe",
            "address": "BROOKLYN, Rogers Hall",
        ]
        let body: [String: Any] = ["eligible": eligible, "proposal": proposal]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return .response(data: data, delay: delay)
    }

    // MARK: - No credential

    /// Participant-authority-loss decision: without a credential the external-AI
    /// popup is not offered and Screenshot Assistance shows no verification
    /// notice, but the ordinary local-outcome notice (here: the local model is
    /// unavailable in this environment) is still presented.
    func testNoCredentialOffersNoExternalAIAndShowsNoVerificationNoticeWithoutSendingAnything() async {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = await analyzeThroughExternalFallback(store: store,
            images: [
                ScreenshotPreparedImage(
                    sourceData: Data((ScreenshotTestEvidence.eligibleCart).utf8),
                    data: Data([0x01]),
                    mimeType: "image/jpeg"
                )
            ],
            participantAuthority: nil,
            token: token
        )
        XCTAssertNil(outcome)
        XCTAssertEqual(store.notice, .unavailable)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - apply(): explicit manual provenance (not value equality)

    func testApplyDoesNotOverwriteAnExistingManualDiningSpot() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        draft.selectedDiningSpot = crave370
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.hasManuallyEditedLocation = true

        let outcome = stateEOutcome(
            ScreenshotProposal(selectedDiningSpot: crave370),
            anchor: crave370
        )
        store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertEqual(draft.selectedDiningSpot, crave370)
    }

    func testApplyDoesNotOverwriteExistingManualFoodText() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        draft.mealEntries[0] = "my own words"
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.manuallyEditedMealItemNames = [0]

        let outcome = stateEOutcome(ScreenshotProposal(mealItems: ["1 Create Your Own Bowl"]))
        store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertEqual(draft.mealEntries[0], "my own words")
    }

    func testApplyDoesNotOverwriteMealSwipesOnceManuallyEdited() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        XCTAssertEqual(draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first!)
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.hasManuallyEditedMealSwipes = true

        let outcome = stateEOutcome(ScreenshotProposal(mealSwipes: 3))
        store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertEqual(draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first!)
    }

    func testApplyFillsUntouchedFields() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()

        let outcome = stateEOutcome(
            ScreenshotProposal(
                selectedDiningSpot: palladium,
                mealItems: ["1 Create Your Own Bowl"],
                mealSwipes: 2
            )
        )
        let applied = store.apply(outcome, manualEdits: noManualEdits, to: &draft)

        XCTAssertEqual(draft.selectedDiningSpot, palladium)
        XCTAssertEqual(draft.mealEntries[0], "1 Create Your Own Bowl")
        XCTAssertEqual(draft.mealSwipes, 2)
        XCTAssertNil(store.notice)

        // W4-R2 provenance/afterglow plumbing: `apply(...)` reports exactly
        // which allowlisted fields it actually wrote.
        XCTAssertTrue(applied.location)
        XCTAssertTrue(applied.mealEntries.contains(0))
        XCTAssertTrue(applied.mealSwipes)
        XCTAssertFalse(applied.isEmpty)
    }

    /// A field the requester already manually owns must not be reported as
    /// applied, even though the proposal carried a value for it — mirroring
    /// the manual-precedence guarantee `apply(...)` already enforces on
    /// `draft` itself.
    func testAppliedFieldsOmitManuallyOwnedFields() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(mealEntries: ["Already typed", "", "", "", ""])

        let outcome = stateEOutcome(
            ScreenshotProposal(
                selectedDiningSpot: palladium,
                mealItems: ["1 Create Your Own Bowl"],
                mealSwipes: 2
            )
        )
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.manuallyEditedMealItemNames = [0]

        let applied = store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertTrue(applied.location)
        XCTAssertFalse(applied.mealEntries.contains(0))
        XCTAssertTrue(applied.mealSwipes)
        XCTAssertEqual(draft.mealEntries[0], "Already typed")
    }

    func testApplyMarksUnsupportedScreenshotNoticeForAnIneligibleResult() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let outcome = ScreenshotProposalOutcome(eligible: false, proposal: .empty)
        store.apply(outcome, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(store.notice, .unsupportedScreenshot)
    }

    func testApplyMarksNoUsefulExtractionNoticeForAnEligibleButEmptyResult() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: .empty,
            venueDisposition: .unresolved
        )
        store.apply(outcome, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(store.notice, .noUsefulExtraction)
    }

    // MARK: - Current-content manual authority

    func testTypeThenClearReopensAFieldForAValidProposal() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        var manualEdits = ScreenshotFieldManualEditState()

        // The actual binding removes authority when the current value is
        // empty; a previous edit is not historical protection.
        draft.mealEntries[0] = "partial"
        manualEdits.manuallyEditedMealItemNames = [0]
        draft.mealEntries[0] = ""
        manualEdits.manuallyEditedMealItemNames.remove(0)
        XCTAssertFalse(manualEdits.hasManuallyEditedMealItemName(0))

        let outcome = stateEOutcome(ScreenshotProposal(mealItems: ["1 Create Your Own Bowl"]))
        store.apply(outcome, manualEdits: manualEdits, to: &draft)

        XCTAssertEqual(draft.mealEntries[0], "1 Create Your Own Bowl")
    }

    /// AI proposes X (programmatic write) → requester manually picks Y →
    /// requester manually picks X again (still a real interaction) →
    /// screenshot replaced. X must survive as the requester's own choice,
    /// not be cleared merely because it coincides with the original AI value.
    func testManualReconvergenceToTheOriginalAIValueStillCountsAsManual() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()

        let firstOutcome = stateEOutcome(ScreenshotProposal(selectedDiningSpot: palladium))
        store.apply(firstOutcome, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(draft.selectedDiningSpot, palladium)

        var manualEdits = ScreenshotFieldManualEditState()
        // Manually picks a different spot.
        draft.selectedDiningSpot = crave370
        manualEdits.hasManuallyEditedLocation = true
        // Manually picks Jasper Kane Cafe again — still a real interaction.
        draft.selectedDiningSpot = palladium

        var draftAfterReplacement = draft
        _ = store.beginSelection(clearing: &draftAfterReplacement, manualEdits: manualEdits)

        XCTAssertEqual(
            draftAfterReplacement.selectedDiningSpot,
            palladium,
            "a manually re-selected value must survive replacement even though it equals the original AI value"
        )
    }

    /// A location manually cleared back to `nil` must not be silently
    /// refilled by a later proposal.
    func testManuallyClearingLocationToNilBlocksAIFromRefillingIt() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let firstOutcome = stateEOutcome(ScreenshotProposal(selectedDiningSpot: palladium))
        store.apply(firstOutcome, manualEdits: noManualEdits, to: &draft)

        var manualEdits = ScreenshotFieldManualEditState()
        // Manually clears back to nil — a real interaction with the picker.
        draft.selectedDiningSpot = nil
        manualEdits.hasManuallyEditedLocation = true

        let secondOutcome = stateEOutcome(ScreenshotProposal(selectedDiningSpot: palladium))
        store.apply(secondOutcome, manualEdits: manualEdits, to: &draft)

        XCTAssertNil(draft.selectedDiningSpot)
    }

    /// The ordinary, non-adversarial case must still work: a field AI set
    /// and the requester never touched still clears correctly when the
    /// screenshot is replaced.
    func testAIOwnedUntouchedValueStillClearsOnReplacement() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let firstOutcome = stateEOutcome(
            ScreenshotProposal(
                selectedDiningSpot: palladium,
                mealItems: ["1 Create Your Own Bowl"],
                mealSwipes: 2
            )
        )
        store.apply(firstOutcome, manualEdits: noManualEdits, to: &draft)

        _ = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        XCTAssertNil(draft.selectedDiningSpot)
        XCTAssertEqual(draft.mealEntries[0], "")
        XCTAssertEqual(draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first!)
    }

    // MARK: - Finding 3 regression: replacement clears stale AI values even
    // if the new image later fails to load/decode/OCR

    func testBeginSelectionClearsStaleAIValuesSynchronouslyRegardlessOfWhatHappensNext() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let firstOutcome = stateEOutcome(
            ScreenshotProposal(selectedDiningSpot: palladium, mealItems: ["1 Bowl"])
        )
        store.apply(firstOutcome, manualEdits: noManualEdits, to: &draft)

        // `beginSelection` itself is the only thing that must run before any
        // async work (image load/decode/OCR) even starts — clearing happens
        // here, synchronously, independent of whether that later work ever
        // succeeds.
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        XCTAssertNil(draft.selectedDiningSpot)
        XCTAssertEqual(draft.mealEntries[0], "")
        // The new selection is already current even though no image has
        // been loaded, decoded, or OCR'd for it yet.
        XCTAssertTrue(store.isCurrent(token))
    }

    // MARK: - Finding 3 regression: last-selection-wins, including an
    // A/B preprocessing inversion (B finishes before A)

    func testASecondSelectionSupersedesTheFirstEvenIfTheFirstsNetworkCallFinishesLast() async {
        let store = makeStore()
        // A (selected first) gets a slow response.
        ScreenshotProposalURLProtocol.enqueue(
            responseBody(eligible: true, locationName: "Jasper Kane Cafe", delay: 0.3)
        )

        var draft = RequestFoodFormDraft()
        let tokenA = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let taskA = Task {
            await analyzeThroughExternalFallback(store: store,
                images: [
                    ScreenshotPreparedImage(
                        sourceData: Data(("View order Order information 1 Bowl").utf8),
                        data: Data([0x01]),
                        mimeType: "image/jpeg"
                    )
                ],
                participantAuthority: "authority-1",
                token: tokenA
            )
        }

        // B is selected shortly after — before A's slow response returns —
        // and gets a fast response.
        try? await Task.sleep(nanoseconds: 20_000_000)
        ScreenshotProposalURLProtocol.enqueue(
            responseBody(eligible: true, locationName: "Cafe 370", delay: 0)
        )
        let tokenB = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcomeB = await analyzeThroughExternalFallback(store: store,
            images: [
                ScreenshotPreparedImage(
                    sourceData: Data(("View order Order information 1 Bowl").utf8),
                    data: Data([0x02]),
                    mimeType: "image/jpeg"
                )
            ],
            participantAuthority: "authority-1",
            token: tokenB
        )

        let outcomeA = await taskA.value

        XCTAssertNil(outcomeA, "A must be dropped even though its network call finished after B started")
        XCTAssertNotNil(outcomeB)
        XCTAssertTrue(store.isCurrent(tokenB))
        XCTAssertFalse(store.isCurrent(tokenA))
    }

    // MARK: - Finding 3 regression: busy state is generation-safe

    func testIsApplyingIsNotClearedByAnOlderGenerationFinishingWhileANewerOneIsStillInFlight() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, delay: 0.05))
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, delay: 0.3))

        var draft = RequestFoodFormDraft()
        let tokenA = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let taskA = Task {
            await analyzeThroughExternalFallback(store: store,
                images: [
                    ScreenshotPreparedImage(
                        sourceData: Data((ScreenshotTestEvidence.eligibleCart).utf8),
                        data: Data([0x01]),
                        mimeType: "image/jpeg"
                    )
                ],
                participantAuthority: "authority-1",
                token: tokenA
            )
        }
        try? await Task.sleep(nanoseconds: 10_000_000)

        let tokenB = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let taskB = Task {
            await analyzeThroughExternalFallback(store: store,
                images: [
                    ScreenshotPreparedImage(
                        sourceData: Data((ScreenshotTestEvidence.eligibleCart).utf8),
                        data: Data([0x02]),
                        mimeType: "image/jpeg"
                    )
                ],
                participantAuthority: "authority-1",
                token: tokenB
            )
        }

        // A (the shorter delay) finishes first and removes itself from the
        // in-flight set; B (the newer, current generation) is still running.
        _ = await taskA.value
        XCTAssertTrue(
            store.isApplying,
            "an older generation finishing must not clear busy state a newer generation still owns"
        )

        _ = await taskB.value
        XCTAssertFalse(store.isApplying)
    }

    // MARK: - Finding 2 regression: AI Assistance Off stops transfer/use,
    // including work already preprocessing but not yet transferred

    func testAnalyzeScreenshotRefusesToTransferWhenAIAssistanceIsOff() async {
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(preferences: preferences)
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        // AI Assistance turns Off after selection/local preprocessing would
        // have started, but before transfer.
        store.setAIAssistanceEnabled(false)

        let outcome = await analyzeThroughExternalFallback(store: store,
            images: [
                ScreenshotPreparedImage(
                    sourceData: Data((ScreenshotTestEvidence.eligibleCart).utf8),
                    data: Data([0x01]),
                    mimeType: "image/jpeg"
                )
            ],
            participantAuthority: "an-authority",
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0, "no transfer may occur once AI Assistance is Off")
    }

    func testAnInFlightNetworkResponseIsDroppedIfAIAssistanceTurnsOffBeforeItReturns() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(
            responseBody(eligible: true, locationName: "Jasper Kane Cafe", delay: 0.2)
        )

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let task = Task {
            await analyzeThroughExternalFallback(store: store,
                images: [
                    ScreenshotPreparedImage(
                        sourceData: Data(("View order Order information 1 Bowl").utf8),
                        data: Data([0x01]),
                        mimeType: "image/jpeg"
                    )
                ],
                participantAuthority: "an-authority",
                token: token
            )
        }

        // The network call is already in flight (transfer already started)
        // when AI Assistance turns Off. The response, once it arrives, must
        // still be unusable.
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.setAIAssistanceEnabled(false)

        let outcome = await task.value
        XCTAssertNil(outcome, "a response that arrives after AI Assistance turns Off must never be applied")
    }

    func testInvalidateCurrentSelectionMakesAnyOutstandingTokenStale() async {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        XCTAssertTrue(store.isCurrent(token))

        // Screen disappearance.
        store.invalidateCurrentSelection()

        XCTAssertFalse(store.isCurrent(token))
        let outcome = await analyzeThroughExternalFallback(store: store,
            images: [
                ScreenshotPreparedImage(
                    sourceData: Data((ScreenshotTestEvidence.eligibleCart).utf8),
                    data: Data([0x01]),
                    mimeType: "image/jpeg"
                )
            ],
            participantAuthority: "an-authority",
            token: token
        )
        XCTAssertNil(outcome)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Finding 1 (review 3) regression: a real, enforceable handoff
    // between authorization and transfer initiation — not a boolean re-check
    // separated from transfer start by a suspension window.

    /// `analyzeScreenshot` is started concurrently, then AI Assistance is
    /// turned Off on the very next synchronous step — before the
    /// just-created outer `Task` has had any opportunity to run at all. This
    /// exercises "Off before `analyzeScreenshot`'s own guards ever ran,"
    /// the outermost edge of the race.
    func testOffImmediatelyAfterStartingAnalysisPreventsTransferFromEverStarting() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, locationName: "Jasper Kane Cafe"))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let task = Task {
            await analyzeThroughExternalFallback(store: store,
                images: [
                    ScreenshotPreparedImage(
                        sourceData: Data(("View order Order information 1 Bowl").utf8),
                        data: Data([0x01]),
                        mimeType: "image/jpeg"
                    )
                ],
                participantAuthority: "an-authority",
                token: token
            )
        }
        store.setAIAssistanceEnabled(false)

        let outcome = await task.value
        XCTAssertNil(outcome)
        XCTAssertEqual(
            ScreenshotProposalURLProtocol.capturedRequests.count, 0,
            "no provider request may ever start once Off precedes it, even concurrently"
        )
    }

    /// The deeper race: a single `Task.yield()` gives `analyzeScreenshot`'s
    /// own synchronous guard checks and child-task registration a chance to
    /// run (the token is still current, AI Assistance is still On, and the
    /// transfer's own child `Task` now exists and is tracked) before this
    /// test cancels it — the exact suspension window between "authorized"
    /// and "transfer genuinely started" that a plain boolean re-check cannot
    /// close, and real `Task` cancellation does: the child task's own first
    /// statement is `Task.checkCancellation()`, observed regardless of
    /// which actor is running it or whether its body had started yet.
    func testInvalidationDuringTheHandoffWindowNeverLetsATransferBecomeUsable() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, locationName: "Jasper Kane Cafe"))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let task = Task {
            await analyzeThroughExternalFallback(store: store,
                images: [
                    ScreenshotPreparedImage(
                        sourceData: Data(("View order Order information 1 Bowl").utf8),
                        data: Data([0x01]),
                        mimeType: "image/jpeg"
                    )
                ],
                participantAuthority: "an-authority",
                token: token
            )
        }
        await Task.yield()
        store.invalidateCurrentSelection()

        let outcome = await task.value
        // Deliberately not asserting `capturedRequests.count == 0` here: a
        // single `Task.yield()` biases toward, but cannot guarantee,
        // cancelling before the child task's own actor hop reaches
        // `URLProtocol.startLoading()` — both a genuinely prevented start
        // and a started-then-correctly-discarded transfer are valid
        // outcomes of this exact race, and asserting only the former made
        // this test flaky under real scheduler timing (confirmed against
        // production code, not a test-only accident). The one thing
        // guaranteed regardless of which side of that boundary the
        // cancellation lands on is that the outcome is never usable — the
        // two ends of this window are each proven individually and
        // deterministically by
        // `testOffImmediatelyAfterStartingAnalysisPreventsTransferFromEverStarting`
        // (cancel strictly before any chance to start) and
        // `testAnInFlightNetworkResponseIsDroppedIfAIAssistanceTurnsOffBeforeItReturns`
        // (cancel strictly after transfer has genuinely started).
        XCTAssertNil(outcome)
    }

    /// Off must retire the current generation itself, not merely cancel a
    /// task — `isCurrent` for a token minted before Off must become false
    /// immediately, synchronously, independent of any task's cancellation
    /// timing.
    func testOffRetiresTheCurrentGenerationSynchronously() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        XCTAssertTrue(store.isCurrent(token))

        store.setAIAssistanceEnabled(false)

        XCTAssertFalse(store.isCurrent(token))
    }

    /// Off retires the generation; turning AI Assistance back On must not
    /// itself revive a token minted before Off. A later analysis can only
    /// ever start from a fresh `beginSelection(...)` token.
    func testTurningOffThenBackOnCannotReviveThePreOffToken() async {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true, locationName: "Jasper Kane Cafe"))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        store.setAIAssistanceEnabled(false)
        store.setAIAssistanceEnabled(true)

        XCTAssertFalse(store.isCurrent(token), "On restores availability for a new selection, not the retired one")
        let outcome = await analyzeThroughExternalFallback(store: store,
            images: [
                ScreenshotPreparedImage(
                    sourceData: Data(("View order Order information 1 Bowl").utf8),
                    data: Data([0x01]),
                    mimeType: "image/jpeg"
                )
            ],
            participantAuthority: "an-authority",
            token: token
        )
        XCTAssertNil(outcome)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Error mapping

    func testProviderUnavailableMapsToUnavailableNotice() async {
        let store = makeStore()
        let body = Data(#"{"error":{"code":"PROVIDER_UNAVAILABLE","message":"x","fields":null}}"#.utf8)
        ScreenshotProposalURLProtocol.enqueue(.response(statusCode: 503, data: body))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = await analyzeThroughExternalFallback(store: store,
            images: [
                ScreenshotPreparedImage(
                    sourceData: Data(("View order Order information 1 Bowl").utf8),
                    data: Data([0x01]),
                    mimeType: "image/jpeg"
                )
            ],
            participantAuthority: "an-authority",
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(store.notice, .unavailable)
    }

    func testAuthorityInvalidMapsToVerificationExpiredNotice() async {
        let store = makeStore()
        let body = Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8)
        ScreenshotProposalURLProtocol.enqueue(.response(statusCode: 401, data: body))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        _ = await analyzeThroughExternalFallback(store: store,
            images: [
                ScreenshotPreparedImage(
                    sourceData: Data(("View order Order information 1 Bowl").utf8),
                    data: Data([0x01]),
                    mimeType: "image/jpeg"
                )
            ],
            participantAuthority: "a-stale-authority",
            token: token
        )

        XCTAssertEqual(store.notice, .verificationExpired)
    }

    // MARK: - Independent evidence transmission (regression: OpenAI must not
    // manufacture the evidence its own claims are validated against)

    /// The service must actually transmit the independently-derived local
    /// OCR text alongside the image, not just accept the parameter and drop
    /// it — this is what lets the backend refuse to call OpenAI at all for
    /// an independently-ineligible screenshot, and what lets it corroborate
    /// mealSwipes against real evidence rather than the provider's own
    /// output.
    func testAnalyzeScreenshotTransmitsTheIndependentLocalEvidenceTextInTheRequestBody() async throws {
        let store = makeStore()
        ScreenshotProposalURLProtocol.enqueue(responseBody(eligible: true))

        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        _ = await analyzeThroughExternalFallback(store: store,
            images: [
                ScreenshotPreparedImage(
                    sourceData: Data(("Your Pickup Order a very specific literal independent evidence phrase").utf8),
                    data: Data([0x01, 0x02]),
                    mimeType: "image/jpeg"
                )
            ],
            participantAuthority: "an-authority",
            token: token
        )

        let request = try XCTUnwrap(ScreenshotProposalURLProtocol.capturedRequests.last)
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        // W4-R4: evidence is carried per image, inside `images`, so each
        // screenshot's eligibility can be decided independently server-side.
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(
            images.first?["localEvidenceText"] as? String,
            "Your Pickup Order a very specific literal independent evidence phrase"
        )
        XCTAssertNil(json["localEvidenceText"])
    }

    // MARK: - AI Assistance enable/consent persistence

    func testSetAIAssistanceEnabledPersistsThroughStorage() {
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(preferences: preferences)
        XCTAssertTrue(store.isAIAssistanceEnabled)

        store.setAIAssistanceEnabled(false)

        XCTAssertFalse(store.isAIAssistanceEnabled)
        XCTAssertFalse(preferences.hasValidScreenshotAssistanceConsent)

        store.setAIAssistanceEnabled(true)

        XCTAssertTrue(store.isAIAssistanceEnabled)
        XCTAssertTrue(preferences.hasValidScreenshotAssistanceConsent)
    }

    // MARK: - W4-R2 2026-09-01 sync: independent Screenshot Help
    // education-completion state

    /// Defaults to `false` (unlike `isAIAssistanceEnabled`, which defaults
    /// `true`): education is shown until actually completed once.
    func testScreenshotHelpCompletionDefaultsToFalse() {
        let store = makeStore()
        XCTAssertFalse(store.hasCompletedScreenshotHelp)
    }

    func testRecordScreenshotHelpCompletedPersistsThroughStorage() {
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(preferences: preferences)
        XCTAssertFalse(store.hasCompletedScreenshotHelp)

        store.recordScreenshotHelpCompleted()

        XCTAssertTrue(store.hasCompletedScreenshotHelp)
        XCTAssertTrue(preferences.hasCompletedScreenshotHelp)
    }

    /// Education state and the AI-enabled state are independent — recording
    /// one must never mutate the other, in either direction.
    func testScreenshotHelpCompletionIsIndependentOfAIEnabledState() {
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        let store = makeStore(preferences: preferences)

        store.recordScreenshotHelpCompleted()
        XCTAssertTrue(store.isAIAssistanceEnabled)

        let otherPreferences = InMemoryScreenshotProposalPreferencesStorage()
        let otherStore = makeStore(preferences: otherPreferences)
        otherStore.setAIAssistanceEnabled(false)
        XCTAssertFalse(otherStore.hasCompletedScreenshotHelp)
    }
}

// MARK: - W4-R4 multi-screenshot evidence

extension ScreenshotProposalStoreTests {
    private func makeMultiStore() -> ScreenshotProposalStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return makeProductionWiredRequesterStore(
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage()
        )
    }

    private func analysisInputs(_ count: Int) -> [ScreenshotPreparedImage] {
        (0..<count).map { index in
            ScreenshotPreparedImage(
                sourceData: Data(("Your Pickup Order evidence for screenshot \(index + 1)").utf8),
                data: Data([UInt8(index + 1)]),
                mimeType: "image/jpeg"
            )
        }
    }

    /// Encodes each `MealItem` the way the real backend does
    /// (`src/screenshotProposalTypes.ts`: `Array<{ name: string; details?:
    /// string }>`), so this stub exercises the current structured decode path
    /// rather than `MealItem`'s bare-string read-compatibility fallback.
    private func eligibleStub(
        mealItems: [MealItem],
        mealSwipes: Int? = nil
    ) -> ScreenshotProposalURLProtocol.Stub {
        var proposal: [String: Any] = [
            "mealItems": mealItems.map { item -> [String: Any] in
                var encoded: [String: Any] = ["name": item.name]
                if let details = item.details { encoded["details"] = details }
                return encoded
            },
        ]
        if let mealSwipes {
            proposal["mealSwipes"] = mealSwipes
        }
        let body: [String: Any] = ["eligible": true, "proposal": proposal]
        return .response(data: try! JSONSerialization.data(withJSONObject: body))
    }

    func testUpToFiveScreenshotsAreSentAsOneAnalysisForOneOrder() async throws {
        for count in 1...ScreenshotProposalStore.maxScreenshotSelection {
            ScreenshotProposalURLProtocol.reset()
            ScreenshotProposalURLProtocol.enqueue(eligibleStub(mealItems: ["1 Bowl"]))
            let store = makeMultiStore()
            var draft = RequestFoodFormDraft()
            let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

            let outcome = await analyzeThroughExternalFallback(store: store,
                images: analysisInputs(count),
                participantAuthority: "an-authority",
                token: token
            )

            XCTAssertNotNil(outcome, "\(count) screenshots must be analyzable")
            // One request for the whole set — never one per screenshot.
            XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 1)
            let body = try XCTUnwrap(
                ScreenshotProposalURLProtocol.capturedRequests.last?.body
            )
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let images = try XCTUnwrap(json["images"] as? [[String: Any]])
            XCTAssertEqual(images.count, count)
            // Each screenshot carries its own independent evidence.
            XCTAssertEqual(
                images.compactMap { $0["localEvidenceText"] as? String },
                (0..<count).map { "Your Pickup Order evidence for screenshot \($0 + 1)" }
            )
        }
    }

    func testMoreThanFiveScreenshotsAreRefusedWithoutAnyTransfer() async {
        ScreenshotProposalURLProtocol.reset()
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        let outcome = await analyzeThroughExternalFallback(store: store,
            images: analysisInputs(6),
            participantAuthority: "an-authority",
            token: token
        )

        XCTAssertNil(outcome)
        // Refused locally, so no bytes leave the device at all.
        XCTAssertTrue(ScreenshotProposalURLProtocol.capturedRequests.isEmpty)
    }

    func testAnEmptySelectionIsRefusedWithoutAnyTransfer() async {
        ScreenshotProposalURLProtocol.reset()
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        let outcome = await analyzeThroughExternalFallback(store: store,
            images: [],
            participantAuthority: "an-authority",
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertTrue(ScreenshotProposalURLProtocol.capturedRequests.isEmpty)
    }

    func testProposedItemsFillOneActiveMealFieldEachInOrder() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(menuPath: .mealExchange, mealSwipes: 3)

        let applied = store.apply(
            stateEOutcome(
                ScreenshotProposal(
                    mealItems: ["1 Bowl", "2 Soda", "1 Cookie"]
                )
            ),
            manualEdits: noManualEdits,
            to: &draft
        )

        XCTAssertEqual(draft.activeMealEntries, ["1 Bowl", "2 Soda", "1 Cookie"])
        XCTAssertEqual(applied.mealEntries, [0, 1, 2])
    }

    func testDecodedThreeSwipeThreeItemProposalActivatesAndFillsAllThreeMealFields() async throws {
        ScreenshotProposalURLProtocol.reset()
        // The backend sends structured `{ name, details }` items
        // (`src/screenshotProposalTypes.ts`), so the modifier clause each
        // item already carried is expressed as `details` here rather than
        // left embedded in `name` — this decodes through `MealItem`'s
        // ordinary keyed path, not its bare-string compatibility fallback.
        let mealItems = [
            MealItem(
                name: "1 Chicken Wings",
                details: "Buffalo Sauce, Blue Cheese Dressing, Chips, Fountain Beverage"
            ),
            MealItem(
                name: "1 Happy Cobb Salad",
                details: "No Cabbage, No Mixed Greens, No Roasted Mushrooms, No Roasted Sunburst Tomato, Chips, Fountain Beverage"
            ),
            MealItem(
                name: "1 Caesar Salad",
                details: "Fire Braised Chicken (Served Cold) (+ $2.00), No Romaine Lettuce, Apple, Fountain Beverage"
            ),
        ]
        ScreenshotProposalURLProtocol.enqueue(
            eligibleStub(mealItems: mealItems, mealSwipes: 3)
        )
        let store = makeMultiStore()
        let palladium = try XCTUnwrap(SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" })
        var draft = RequestFoodFormDraft(selectedDiningSpot: palladium)
        let manualEdits = ScreenshotFieldManualEditState(hasManuallyEditedLocation: true)
        let token = store.beginSelection(clearing: &draft, manualEdits: manualEdits)

        // The external result is re-validated on device against independent
        // OCR evidence, so the three-swipe claim must be corroborated by an
        // explicit `3M` in that evidence to survive.
        let receivedOutcome = await analyzeThroughExternalFallback(store: store,
            images: [
                ScreenshotTestEvidence.input("Your Pickup Order 3M\nContinue to Checkout\nJasper Kane Cafe"),
                ScreenshotTestEvidence.input("Your Pickup Order 3M\nContinue to Checkout\nJasper Kane Cafe", byte: 2),
            ],
            participantAuthority: "an-authority",
            token: token
        )
        let outcome = try XCTUnwrap(receivedOutcome)
        // The evidence deliberately has no V1 venue identity line, so R4.2
        // requires the State A picker/confirmation before field application.
        let applied = store.apply(
            outcome,
            manualEdits: manualEdits,
            to: &draft,
            venueConfirmation: true
        )

        XCTAssertEqual(outcome.proposal.mealSwipes, 3)
        XCTAssertEqual(outcome.proposal.mealItems, mealItems)
        XCTAssertEqual(draft.mealSwipes, 3)
        XCTAssertEqual(Array(draft.activeMealEntryIndices), [0, 1, 2])
        XCTAssertEqual(draft.activeMealEntries, mealItems)
        XCTAssertEqual(applied.mealEntries, [0, 1, 2])
        XCTAssertTrue(applied.mealSwipes)
        XCTAssertEqual(draft.diningDollarsText, "")
    }

    func testProposedItemsNeverFillAFieldHiddenByALoweredSwipeCount() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(menuPath: .mealExchange, mealSwipes: 2)

        store.apply(
            stateEOutcome(
                ScreenshotProposal(
                    mealItems: ["1 Bowl", "2 Soda", "1 Cookie", "1 Tea"]
                )
            ),
            manualEdits: noManualEdits,
            to: &draft
        )

        // Only the two visible fields receive values; writing into a hidden
        // field would put AI content where the requester cannot review it.
        XCTAssertEqual(draft.activeMealEntries, ["1 Bowl", "2 Soda"])
        XCTAssertEqual(draft.mealEntries[2], "")
        XCTAssertEqual(draft.mealEntries[3], "")
    }

    func testManualPrecedenceHoldsPerMealEntry() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(
            menuPath: .mealExchange,
            mealSwipes: 3,
            mealEntries: ["", "Requester typed this", "", "", ""]
        )
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.manuallyEditedMealItemNames = [1]

        let applied = store.apply(
            stateEOutcome(
                ScreenshotProposal(
                    mealItems: ["1 Bowl", "2 Soda", "1 Cookie"]
                )
            ),
            manualEdits: manualEdits,
            to: &draft
        )

        // Entry 1 is requester-owned and untouched; its neighbours are filled.
        XCTAssertEqual(
            draft.activeMealEntries,
            ["1 Bowl", "Requester typed this", "1 Cookie"]
        )
        XCTAssertEqual(applied.mealEntries, [0, 2])
    }

    func testProposedItemsFillOrderDetailsOnTheDiningDollarsPath() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(menuPath: .diningDollars)

        let applied = store.apply(
            stateEOutcome(ScreenshotProposal(mealItems: ["1 Bowl", "2 Soda"])),
            manualEdits: noManualEdits,
            to: &draft
        )

        XCTAssertEqual(draft.orderDetails, "1 Bowl; 2 Soda")
        XCTAssertTrue(applied.orderDetails)
        // The per-swipe fields belong to the other path and stay empty.
        XCTAssertEqual(draft.mealEntries, RequestFoodFormDraft.emptyMealEntries)
    }

    func testManuallyOwnedOrderDetailsAreNeverOverwritten() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(
            menuPath: .diningDollars,
            orderDetails: "Requester typed this"
        )
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.hasManuallyEditedOrderDetails = true

        let applied = store.apply(
            stateEOutcome(ScreenshotProposal(mealItems: ["1 Bowl"])),
            manualEdits: manualEdits,
            to: &draft
        )

        XCTAssertEqual(draft.orderDetails, "Requester typed this")
        XCTAssertFalse(applied.orderDetails)
    }

    func testAProposalWithoutADeterministicPathNeverChangesTheMenuPathOrTheDiningDollarAmount() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(
            menuPath: .diningDollars,
            diningDollarsText: "7.25"
        )

        store.apply(
            stateEOutcome(
                ScreenshotProposal(
                    selectedDiningSpot: palladium,
                    mealItems: ["1 Bowl"],
                    mealSwipes: 3
                )
            ),
            manualEdits: noManualEdits,
            to: &draft
        )

        // With no deterministic path proposal (W4-R4.1 covers that case in
        // `ScreenshotMenuPathApplicationTests`), Screenshot Assistance does not
        // decide which menu the requester is using or how much money they need.
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.diningDollarsText, "7.25")
    }

    func testANewSelectionClearsOnlyAIOwnedEntries() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(
            menuPath: .mealExchange,
            mealSwipes: 3,
            mealEntries: ["AI filled", "Requester typed", "AI filled", "", ""],
            orderDetails: "AI filled order"
        )
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.manuallyEditedMealItemNames = [1]

        _ = store.beginSelection(clearing: &draft, manualEdits: manualEdits)

        XCTAssertEqual(draft.mealEntries[0], "")
        XCTAssertEqual(draft.mealEntries[1], "Requester typed")
        XCTAssertEqual(draft.mealEntries[2], "")
        XCTAssertEqual(draft.orderDetails, "")
    }

    func testAnEmptyItemListIsReportedAsNoUsefulExtraction() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft()

        store.apply(
            ScreenshotProposalOutcome(
                eligible: true,
                proposal: ScreenshotProposal(mealItems: []),
                venueDisposition: .unresolved
            ),
            manualEdits: noManualEdits,
            to: &draft
        )

        XCTAssertEqual(store.notice, .noUsefulExtraction)
    }

    func testTheClientBoundMatchesTheBackendsOwnBound() {
        // Both sides enforce the same number independently; this pins them
        // together so one cannot drift without the other.
        XCTAssertEqual(ScreenshotProposalStore.maxScreenshotSelection, 5)
    }

    // MARK: - W4-R4 per-field structured-meal authority and provenance

    func testManualMealNamePreservesOnlyNameWhileEmptyDetailsAcceptsProposal() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(mealEntries: [MealItem(name: "Requester wings"), MealItem(name: ""), MealItem(name: ""), MealItem(name: ""), MealItem(name: "")])
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.manuallyEditedMealItemNames = [0]

        let applied = store.apply(
            stateEOutcome(
                ScreenshotProposal(mealItems: [MealItem(name: "AI bowl", details: "Buffalo sauce")])
            ),
            manualEdits: manualEdits,
            to: &draft
        )

        XCTAssertEqual(draft.mealEntries[0], MealItem(name: "Requester wings", details: "Buffalo sauce"))
        XCTAssertFalse(applied.mealItemNames.contains(0))
        XCTAssertTrue(applied.mealItemDetails.contains(0))
        XCTAssertEqual(applied.preservedManualFieldCount, 1)
    }

    func testManualMealDetailsPreservesOnlyDetailsWhileEmptyNameAcceptsProposal() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(mealEntries: [MealItem(name: "", details: "No onions"), MealItem(name: ""), MealItem(name: ""), MealItem(name: ""), MealItem(name: "")])
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.manuallyEditedMealItemDetails = [0]

        let applied = store.apply(
            stateEOutcome(
                ScreenshotProposal(mealItems: [MealItem(name: "AI bowl", details: "AI sauce")])
            ),
            manualEdits: manualEdits,
            to: &draft
        )

        XCTAssertEqual(draft.mealEntries[0], MealItem(name: "AI bowl", details: "No onions"))
        XCTAssertTrue(applied.mealItemNames.contains(0))
        XCTAssertFalse(applied.mealItemDetails.contains(0))
        XCTAssertEqual(applied.preservedManualFieldCount, 1)
    }

    func testClearingEitherMealSubfieldReopensOnlyThatSubfieldForReproposal() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(mealEntries: [MealItem(name: "", details: "Manual details"), MealItem(name: ""), MealItem(name: ""), MealItem(name: ""), MealItem(name: "")])
        var manualEdits = ScreenshotFieldManualEditState()
        // Name was manually cleared, while Details remains requester-owned.
        manualEdits.manuallyEditedMealItemDetails = [0]

        let first = store.apply(
            stateEOutcome(
                ScreenshotProposal(mealItems: [MealItem(name: "Reproposed name", details: "AI details")])
            ),
            manualEdits: manualEdits,
            to: &draft
        )
        XCTAssertEqual(draft.mealEntries[0], MealItem(name: "Reproposed name", details: "Manual details"))
        XCTAssertTrue(first.mealItemNames.contains(0))
        XCTAssertFalse(first.mealItemDetails.contains(0))

        // Clearing Details removes only Details authority. The later proposal
        // establishes fresh provenance for that newly filled current value.
        draft.mealEntries[0].details = nil
        manualEdits.manuallyEditedMealItemDetails.remove(0)
        let second = store.apply(
            stateEOutcome(
                ScreenshotProposal(mealItems: [MealItem(name: "Updated name", details: "Reproposed details")])
            ),
            manualEdits: manualEdits,
            to: &draft
        )
        XCTAssertEqual(draft.mealEntries[0], MealItem(name: "Updated name", details: "Reproposed details"))
        XCTAssertTrue(second.mealItemNames.contains(0))
        XCTAssertTrue(second.mealItemDetails.contains(0))
    }

    func testProposalApplicationReportsManualPreservationOnlyWhenWarranted() {
        let store = makeMultiStore()
        var draft = RequestFoodFormDraft(mealEntries: [MealItem(name: "Manual name", details: "Manual details"), MealItem(name: ""), MealItem(name: ""), MealItem(name: ""), MealItem(name: "")])
        var manualEdits = ScreenshotFieldManualEditState()
        manualEdits.manuallyEditedMealItemNames = [0]
        manualEdits.manuallyEditedMealItemDetails = [0]

        let preserved = store.apply(
            stateEOutcome(
                ScreenshotProposal(mealItems: [MealItem(name: "AI name", details: "AI details")])
            ),
            manualEdits: manualEdits,
            to: &draft
        )
        XCTAssertEqual(preserved.preservedManualFieldCount, 2)

        var emptyDraft = RequestFoodFormDraft()
        let replaced = store.apply(
            stateEOutcome(
                ScreenshotProposal(mealItems: [MealItem(name: "AI name", details: "AI details")])
            ),
            manualEdits: ScreenshotFieldManualEditState(),
            to: &emptyDraft
        )
        XCTAssertEqual(replaced.preservedManualFieldCount, 0)
    }
}
