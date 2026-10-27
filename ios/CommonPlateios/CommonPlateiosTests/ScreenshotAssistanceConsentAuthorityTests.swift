//
//  ScreenshotAssistanceConsentAuthorityTests.swift
//  CommonPlateiosTests
//
// W4-S3 consent-authority revision (2026-10-01 HQ sync): the preferences-level
// consent record and its legacy pre-TestFlight development-state reset.
// `ScreenshotProposalPreferencesStorage`'s own doc comment and
// `docs/week-4-ios-testflight-spec.md`'s "Migration/default behavior" item (8)
// are the accepted source. This is a pre-TestFlight development-state reset,
// not a user migration: there is no distributed user base, so any
// preference/consent state predating this revised contract carries no
// consent, and no migration screen, notice, or legacy-compatibility UX exists
// or is required.
import Foundation
import XCTest
@testable import CommonPlateios

final class ScreenshotAssistanceConsentAuthorityTests: XCTestCase {
    private func freshDefaults(file: StaticString = #filePath, line: UInt = #line) throws -> (UserDefaults, () -> Void) {
        let suiteName = "commonplate.tests.s3.consentAuthority.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    // MARK: - Fail-closed defaults

    func testACleanInstallationHasNoValidConsent() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)

        XCTAssertFalse(storage.hasValidScreenshotAssistanceConsent)
    }

    func testALegacyDefaultOnPreferenceAloneIsNotConsent() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        // The pre-revision key defaulted to `true` when never set, and may
        // still be explicitly `true` from a pre-revision build.
        defaults.set(true, forKey: "commonplate.screenshotProposal.aiAssistanceEnabled")
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)

        XCTAssertFalse(storage.hasValidScreenshotAssistanceConsent)
    }

    func testTheLegacyThirdPartyConsentKeyAloneIsNotConsent() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        // A build from before S3 ever existed recorded this flag when the
        // requester tapped Continue on the long-retired first-use disclosure.
        defaults.set(true, forKey: "commonplate.screenshotProposal.thirdPartyConsentRecorded")
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)

        XCTAssertFalse(storage.hasValidScreenshotAssistanceConsent)
    }

    func testBothLegacyKeysTogetherAreStillNotConsent() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        defaults.set(true, forKey: "commonplate.screenshotProposal.aiAssistanceEnabled")
        defaults.set(true, forKey: "commonplate.screenshotProposal.thirdPartyConsentRecorded")
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)

        XCTAssertFalse(storage.hasValidScreenshotAssistanceConsent)
    }

    func testCorruptConsentDataFailsClosed() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        defaults.set(Data([0xFF, 0x00, 0x01]), forKey: "commonplate.screenshotProposal.consentContract.v1")
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)

        XCTAssertFalse(storage.hasValidScreenshotAssistanceConsent)
    }

    func testAMismatchedContractFailsClosed() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        let mismatched = ScreenshotAssistanceConsentContract(
            purpose: "screenshotAssistance",
            provider: "anthropic", // a materially different provider
            transferredDataClass: "selectedScreenshotImages"
        )
        defaults.set(try JSONEncoder().encode(mismatched), forKey: "commonplate.screenshotProposal.consentContract.v1")
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)

        XCTAssertFalse(storage.hasValidScreenshotAssistanceConsent, "consent is not portable to a materially different provider")
    }

    func testAMismatchedDataClassFailsClosed() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        let mismatched = ScreenshotAssistanceConsentContract(
            purpose: "screenshotAssistance",
            provider: "openAI",
            transferredDataClass: "selectedScreenshotImagesPlusOCRText" // a materially broader data class
        )
        defaults.set(try JSONEncoder().encode(mismatched), forKey: "commonplate.screenshotProposal.consentContract.v1")
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)

        XCTAssertFalse(storage.hasValidScreenshotAssistanceConsent, "consent is not portable to a materially broader data class")
    }

    // MARK: - Grant / revoke round-trip, persisted

    func testGrantingConsentPersistsAcrossAFreshStorageInstance() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults).grantScreenshotAssistanceConsent()

        // A fresh instance over the same `UserDefaults`, simulating relaunch.
        let reopened = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)
        XCTAssertTrue(reopened.hasValidScreenshotAssistanceConsent)
    }

    func testRevokingConsentPersistsAcrossAFreshStorageInstance() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)
        storage.grantScreenshotAssistanceConsent()
        storage.revokeScreenshotAssistanceConsent()

        let reopened = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)
        XCTAssertFalse(reopened.hasValidScreenshotAssistanceConsent)
    }

    func testRevokingWithNoExistingConsentIsIdempotent() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)

        storage.revokeScreenshotAssistanceConsent()

        XCTAssertFalse(storage.hasValidScreenshotAssistanceConsent)
    }

    func testReEnablingAfterRevocationRequiresAFreshGrant() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        let storage = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)
        storage.grantScreenshotAssistanceConsent()
        storage.revokeScreenshotAssistanceConsent()
        XCTAssertFalse(storage.hasValidScreenshotAssistanceConsent)

        storage.grantScreenshotAssistanceConsent()
        XCTAssertTrue(storage.hasValidScreenshotAssistanceConsent)
    }

    // MARK: - Store-level integration over real `UserDefaults`

    @MainActor
    func testStoreIsOffOnAFreshInstallationEvenWithLegacyKeysPresent() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        defaults.set(true, forKey: "commonplate.screenshotProposal.aiAssistanceEnabled")
        defaults.set(true, forKey: "commonplate.screenshotProposal.thirdPartyConsentRecorded")
        let store = ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: APIClient(configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!))),
            preferences: UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults),
            runtime: nil
        )

        XCTAssertFalse(store.isAIAssistanceEnabled)
    }

    @MainActor
    func testStoreSetAIAssistanceEnabledGrantsAndRevokesThroughRealUserDefaults() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        let preferences = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)
        let store = ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: APIClient(configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!))),
            preferences: preferences,
            runtime: nil
        )
        XCTAssertFalse(store.isAIAssistanceEnabled)

        store.setAIAssistanceEnabled(true)
        XCTAssertTrue(store.isAIAssistanceEnabled)
        XCTAssertTrue(preferences.hasValidScreenshotAssistanceConsent)
        // Persists across a fresh read of the same `UserDefaults`.
        XCTAssertTrue(UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults).hasValidScreenshotAssistanceConsent)

        store.setAIAssistanceEnabled(false)
        XCTAssertFalse(store.isAIAssistanceEnabled)
        XCTAssertFalse(preferences.hasValidScreenshotAssistanceConsent)
        XCTAssertFalse(UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults).hasValidScreenshotAssistanceConsent)
    }

    /// No stray persisted key beyond the consent record and the independent
    /// Screenshot Help completion flag — in particular, no separate
    /// persisted remote-transfer permission of any kind.
    func testOnlyTheExpectedKeysArePersisted() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        let preferences = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)
        preferences.grantScreenshotAssistanceConsent()
        preferences.hasCompletedScreenshotHelp = true

        let keys = Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("commonplate.screenshotProposal") })
        XCTAssertEqual(keys, [
            "commonplate.screenshotProposal.consentContract.v1",
            "commonplate.screenshotProposal.helpCompleted",
        ])
    }

    // MARK: - No migration UI

    /// Only the user-facing view files are checked: the store and preferences
    /// files legitimately discuss, in doc comments, why no migration UI
    /// exists — that prose is not migration UI.
    func testNoMigrationUIExistsInTheScreenshotAssistanceViews() throws {
        for file in [
            "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift",
            "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift",
            "ios/CommonPlateios/CommonPlateios/Views/ScreenshotAssistanceDisclosureView.swift",
        ] {
            let source = try fileSource(file)
            for forbidden in ["migration", "Migration", "upgrade your"] {
                XCTAssertFalse(source.contains(forbidden), "\(file) must not contain migration UI/copy (`\(forbidden)`)")
            }
        }
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
