//
//  RequesterScreenshotAssistanceExclusionTests.swift
//  CommonPlateiosTests
//
// W5-IOS1: V1.0 excludes requester Screenshot Assistance in every shipping
// configuration while the implementation stays testable with the gate injected
// enabled. Each negative case has an enabled positive control so a pass cannot
// come from an unwired fixture. All evidence is synthetic.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequesterScreenshotAssistanceExclusionTests: XCTestCase {
    override func tearDown() {
        ScreenshotProposalURLProtocol.reset()
        super.tearDown()
    }

    private let environment = testQualifiableEnvironment

    private final class CountingPreferences: ScreenshotProposalPreferencesStoring {
        var hasValidScreenshotAssistanceConsent = true
        var hasCompletedScreenshotHelp = true
        private(set) var mutationCount = 0

        func grantScreenshotAssistanceConsent() {
            mutationCount += 1
            hasValidScreenshotAssistanceConsent = true
        }

        func revokeScreenshotAssistanceConsent() {
            mutationCount += 1
            hasValidScreenshotAssistanceConsent = false
        }
    }

    private func makeService(
        _ availability: RequesterScreenshotAssistanceAvailability
    ) -> ScreenshotProposalService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return ScreenshotProposalService(availability: availability, client: client)
    }

    private func makeStore(
        _ availability: RequesterScreenshotAssistanceAvailability,
        local: StubLocalProvider,
        external: StubExternalProvider,
        preferences: ScreenshotProposalPreferencesStoring
    ) -> ScreenshotProposalStore {
        let runtime = makeRequesterTestRuntime(
            local: local,
            external: external,
            qualification: qualifiedRegistry(environment: environment),
            environment: environment
        )
        return ScreenshotProposalStore(
            availability: availability,
            service: makeService(availability),
            preferences: preferences,
            runtime: runtime
        )
    }

    private var usefulOutput: RequesterOrderRawOutput {
        RequesterOrderRawOutput(
            visibleVenueText: "Palladium",
            foodItems: [.init(name: "Bowl", quantity: 1, modifiers: [])],
            mealSwipes: nil
        )
    }

    private func analyze(_ store: ScreenshotProposalStore) async -> ScreenshotProposalOutcome? {
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: ScreenshotFieldManualEditState())
        return await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input()],
            participantAuthority: { "an-authority" },
            token: token
        )
    }

    func testShippingPolicyIsExcludedAndOnlyTestsCanEnable() {
        XCTAssertFalse(RequesterScreenshotAssistanceAvailability.shipping.isAvailable)
        XCTAssertTrue(RequesterScreenshotAssistanceAvailability.enabledForTesting().isAvailable)
    }

    func testStandingConsentAndHelpStateCannotEnableExcludedStoreAndArePreserved() {
        let preferences = CountingPreferences()
        let store = makeStore(.shipping, local: StubLocalProvider(behavior: .output(usefulOutput)),
                              external: StubExternalProvider(), preferences: preferences)

        XCTAssertFalse(store.isAssistanceAvailable)
        XCTAssertFalse(store.isAIAssistanceEnabled)

        store.setAIAssistanceEnabled(true)
        store.setAIAssistanceEnabled(false)

        XCTAssertFalse(store.isAIAssistanceEnabled)
        XCTAssertEqual(preferences.mutationCount, 0, "excluded builds neither grant nor revoke saved consent")
        XCTAssertTrue(preferences.hasValidScreenshotAssistanceConsent)
        XCTAssertTrue(preferences.hasCompletedScreenshotHelp)
    }

    func testEnabledControlHonorsSavedConsent() {
        let store = makeStore(.enabledForTesting(), local: StubLocalProvider(behavior: .output(usefulOutput)),
                              external: StubExternalProvider(), preferences: CountingPreferences())
        XCTAssertTrue(store.isAssistanceAvailable)
        XCTAssertTrue(store.isAIAssistanceEnabled)
    }

    func testExcludedStoreInvokesNeitherLocalNorExternalProviderNorNetwork() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput))
        let external = StubExternalProvider()
        let store = makeStore(.shipping, local: local, external: external, preferences: CountingPreferences())

        let outcome = await analyze(store)

        XCTAssertNil(outcome)
        XCTAssertEqual(local.extractCallCount, 0)
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    func testEnabledControlReachesTheLocalProvider() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput))
        let store = makeStore(.enabledForTesting(), local: local, external: StubExternalProvider(),
                              preferences: CountingPreferences())

        let outcome = await analyze(store)

        XCTAssertNotNil(outcome)
        XCTAssertEqual(local.extractCallCount, 1)
    }

    func testExcludedSelectionNeverClearsTheManualDraft() {
        let store = makeStore(.shipping, local: StubLocalProvider(behavior: .output(usefulOutput)),
                              external: StubExternalProvider(), preferences: CountingPreferences())
        var draft = RequestFoodFormDraft()
        draft.selectedDiningSpot = SupportedVendorCatalog.diningSpots.first
        draft.orderDetails = "typed by the requester"

        _ = store.beginSelection(clearing: &draft, manualEdits: ScreenshotFieldManualEditState())

        XCTAssertNotNil(draft.selectedDiningSpot)
        XCTAssertEqual(draft.orderDetails, "typed by the requester")
    }

    func testExcludedServiceSendsNothingForAStaleOrModifiedCaller() async {
        let service = makeService(.shipping)
        do {
            _ = try await service.requestProposal(images: [], authority: "stale-authority")
            XCTFail("an excluded service must refuse")
        } catch ScreenshotProposalServiceError.excluded {
            // Expected: refused before any request was built.
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    func testBackendExclusionRefusalMapsToTheOrdinaryUnavailableNotice() {
        XCTAssertEqual(ScreenshotProposalNotice.map(ScreenshotProposalServiceError.excluded), .unavailable)
    }

    // MARK: - Source-inspection proof (not rendered; complements the hosted test)

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testSettingsOffersNoScreenshotAssistanceControl() throws {
        let settings = try source("Views/SettingsView.swift")
        XCTAssertFalse(settings.contains("setAIAssistanceEnabled"))
        XCTAssertFalse(settings.contains("Screenshot Assistance"))
        XCTAssertFalse(settings.contains("ScreenshotAssistanceDisclosureView"))
    }

    func testEditRequestEntryPointIsGatedByTheStoreAvailability() throws {
        let edit = try source("Views/EditRequestView.swift")
        XCTAssertTrue(edit.contains("if screenshotProposalStore.isAssistanceAvailable {\n                        EditScreenshotAssistanceRow("))
    }

    func testOnboardingAndHelpCopyMakeNoAssistanceAvailabilityClaim() throws {
        for path in ["Views/OnboardingExperienceView.swift", "Views/HowCommonPlateWorksViews.swift",
                     "Views/PrivacySafetyView.swift", "Views/SupportView.swift"] {
            XCTAssertFalse(try source(path).localizedCaseInsensitiveContains("screenshot assist"), path)
        }
    }

    func testProductionLaunchOnlyEverConstructsTheExcludedPolicy() throws {
        let content = try source("ContentView.swift")
        XCTAssertFalse(content.contains(".enabledForTesting()"))
        XCTAssertEqual(content.components(separatedBy: "availability: .shipping").count - 1, 2)
    }
}
