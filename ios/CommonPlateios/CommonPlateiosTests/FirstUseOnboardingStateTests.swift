//
//  FirstUseOnboardingStateTests.swift
//  CommonPlateiosTests
//
// W4-O1 focused proof: local first-use / discovery state model, grandfathering,
// reset ordering, and the P2 reset seam. Presentation state only.

import XCTest
@testable import CommonPlateios

@MainActor
final class FirstUseOnboardingStateTests: XCTestCase {
    private final class RecordingStorage: OnboardingPresentationStoring {
        var writes: [String] = []
        var hasCompletedOnboarding = false {
            didSet { writes.append("completed=\(hasCompletedOnboarding)") }
        }
        var helpingDiscoveryRecord: HelpingDiscoveryRecord? {
            didSet { writes.append("record=\(helpingDiscoveryRecord?.rawValue ?? "nil")") }
        }
    }

    func testFreshInstallIsNeitherCompleteNorPending() {
        let store = OnboardingPresentationStore(storage: RecordingStorage())
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertFalse(store.isHelpingDiscoveryPending)
    }

    func testWelcomeCompletionWritesPendingRecordBeforeCompletionFlag() {
        let storage = RecordingStorage()
        let store = OnboardingPresentationStore(storage: storage)

        store.completeOnboarding()

        XCTAssertEqual(storage.writes, ["record=pending", "completed=true"])
        XCTAssertTrue(store.hasCompletedOnboarding)
        XCTAssertTrue(store.isHelpingDiscoveryPending)
    }

    func testGrandfatheredInstallIsCompleteWithNoRecordAndNeverPending() {
        let storage = RecordingStorage()
        storage.hasCompletedOnboarding = true
        let store = OnboardingPresentationStore(storage: storage)

        XCTAssertTrue(store.hasCompletedOnboarding)
        XCTAssertNil(store.helpingDiscoveryRecord)
        XCTAssertFalse(store.isHelpingDiscoveryPending)
        store.completeOnboarding()
        store.completeHelpingDiscovery()
        XCTAssertNil(storage.helpingDiscoveryRecord)
        XCTAssertFalse(store.isHelpingDiscoveryPending)
    }

    func testDiscoveryCompletesOnlyFromPendingAndPersistsAcrossRelaunch() {
        let storage = RecordingStorage()
        let store = OnboardingPresentationStore(storage: storage)
        store.completeOnboarding()

        store.completeHelpingDiscovery()

        XCTAssertEqual(storage.helpingDiscoveryRecord, .complete)
        let relaunched = OnboardingPresentationStore(storage: storage)
        XCTAssertTrue(relaunched.hasCompletedOnboarding)
        XCTAssertFalse(relaunched.isHelpingDiscoveryPending)
    }

    func testPendingPersistsAcrossRelaunchUntilCompleted() {
        let storage = RecordingStorage()
        OnboardingPresentationStore(storage: storage).completeOnboarding()
        XCTAssertTrue(OnboardingPresentationStore(storage: storage).isHelpingDiscoveryPending)
    }

    func testResetClearsCompletionFirstThenRecordAndShowsWelcomeAgain() {
        let storage = RecordingStorage()
        let store = OnboardingPresentationStore(storage: storage)
        store.completeOnboarding()
        store.completeHelpingDiscovery()
        storage.writes.removeAll()

        store.resetFirstUsePresentation()

        XCTAssertEqual(storage.writes, ["completed=false", "record=nil"])
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertFalse(store.isHelpingDiscoveryPending)
        store.completeOnboarding()
        XCTAssertTrue(store.isHelpingDiscoveryPending)
    }

    func testInterruptedResetNeverLeavesCompletedWithoutRecord() {
        // Only the first reset write landed: completion cleared, record stale.
        let storage = RecordingStorage()
        storage.helpingDiscoveryRecord = .complete
        storage.hasCompletedOnboarding = false
        let store = OnboardingPresentationStore(storage: storage)

        XCTAssertFalse(store.hasCompletedOnboarding, "Welcome must show, not grandfather")
        store.completeOnboarding()
        XCTAssertEqual(storage.helpingDiscoveryRecord, .pending)
    }

    func testUserDefaultsStorageRoundTripsBothValuesAndRemovesRecord() {
        let suite = "FirstUseOnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = UserDefaultsOnboardingPresentationStorage(defaults: defaults)

        let store = OnboardingPresentationStore(storage: storage)
        store.completeOnboarding()
        XCTAssertEqual(
            UserDefaultsOnboardingPresentationStorage(defaults: defaults).helpingDiscoveryRecord,
            .pending
        )
        store.resetFirstUsePresentation()
        XCTAssertFalse(defaults.bool(forKey: "commonplate.onboarding.completed"))
        XCTAssertNil(UserDefaultsOnboardingPresentationStorage(defaults: defaults).helpingDiscoveryRecord)
    }

    func testCoordinatorCompletionIsSynchronousAndCarriesNoRoleState() {
        let storage = RecordingStorage()
        let store = OnboardingPresentationStore(storage: storage)
        let coordinator = OnboardingFlowCoordinator(presentationStore: store)

        coordinator.continueFromWelcome()

        XCTAssertTrue(store.hasCompletedOnboarding)
        XCTAssertTrue(coordinator.isCompletingOnboarding)
        coordinator.finishCompletionPresentation()
        XCTAssertFalse(coordinator.isCompletingOnboarding)
        XCTAssertTrue(store.hasCompletedOnboarding)
    }

    func testOnlyCheckedDeletionCompletionOwnsTheProductionResetSeam() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if url.lastPathComponent == "OnboardingPresentationStorage.swift" { continue }
            if url.lastPathComponent == "ParticipantDeletionStore.swift" {
                XCTAssertTrue(source.contains("resetFirstUsePresentationChecked()"))
                continue
            }
            XCTAssertFalse(
                source.contains("resetFirstUsePresentation"),
                "\(url.lastPathComponent) must not call the P2 reset seam"
            )
        }
    }
}
