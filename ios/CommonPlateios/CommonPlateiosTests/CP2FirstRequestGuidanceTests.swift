//
//  CP2FirstRequestGuidanceTests.swift
//  CommonPlateiosTests
//
// CP2 (Faith, 2026-10-25): a participant's first post on this install shows
// `successGuidance` with a 3.5s Success dwell; later posts show only
// `Request posted!` with the accepted 1.6s dwell. The signal is a device-local
// record keyed by a digest of the participant identifier.
import SwiftUI
import XCTest
@testable import CommonPlateios

@MainActor
final class CP2FirstRequestGuidanceTests: XCTestCase {
    private let participantID = "0123456789abcdef01234567"
    private var authority: String { "\(participantID).1.\(String(repeating: "A", count: 43))" }
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CP2FirstRequestGuidanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testGuidanceIsShownOncePerParticipantAndOnlyAfterRecording() {
        let ledger = FirstRequestGuidanceLedger(defaults: defaults)
        XCTAssertTrue(ledger.showsGuidance(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ))
        XCTAssertTrue(ledger.showsGuidance(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ), "reading never records")

        XCTAssertTrue(ledger.recordGuidanceShown(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ))
        XCTAssertFalse(ledger.showsGuidance(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ))
        XCTAssertFalse(FirstRequestGuidanceLedger(defaults: defaults).showsGuidance(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ), "remembered across launches on this install")

        let other = "fedcba9876543210fedcba98.1.\(String(repeating: "A", count: 43))"
        XCTAssertTrue(ledger.showsGuidance(
            forAuthority: other, currentAuthority: other, deletionFrozen: false
        ), "another participant still gets its first guidance")

        XCTAssertTrue(ledger.recordGuidanceShown(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ))
        XCTAssertEqual(defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey)?.count, 1)
    }

    func testStoresOnlyADigestNeverTheParticipantIdOrCredential() throws {
        let ledger = FirstRequestGuidanceLedger(defaults: defaults)
        XCTAssertTrue(ledger.recordGuidanceShown(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ))
        let stored = try XCTUnwrap(defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey))
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].count, 64)
        XCTAssertFalse(stored[0].contains(participantID))
        XCTAssertFalse(stored[0].contains(authority))
    }

    func testNonCanonicalAuthorityGetsNoGuidanceAndRecordsNothing() {
        let ledger = FirstRequestGuidanceLedger(defaults: defaults)
        XCTAssertFalse(ledger.showsGuidance(
            forAuthority: "a", currentAuthority: "a", deletionFrozen: false
        ))
        XCTAssertFalse(ledger.recordGuidanceShown(
            forAuthority: "a", currentAuthority: "a", deletionFrozen: false
        ))
        XCTAssertFalse(ledger.showsGuidance(
            forAuthority: authority, currentAuthority: "another", deletionFrozen: false
        ))
        XCTAssertFalse(ledger.recordGuidanceShown(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: true
        ))
        XCTAssertNil(defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey))
    }

    func testMalformedStringLedgerFailsClosedForGuidanceReadsAndWrites() {
        defaults.set(["not-a-digest"], forKey: FirstRequestGuidanceLedger.defaultsKey)
        let ledger = FirstRequestGuidanceLedger(defaults: defaults)

        XCTAssertFalse(ledger.showsGuidance(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ))
        XCTAssertFalse(ledger.recordGuidanceShown(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ))
        XCTAssertEqual(defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey), ["not-a-digest"])
    }

    func testOldLedgerSnapshotCannotWriteAfterDeletionGenerationChanges() throws {
        let staleLedger = FirstRequestGuidanceLedger(defaults: defaults)
        let other = "fedcba9876543210fedcba98.1.\(String(repeating: "A", count: 43))"
        XCTAssertTrue(staleLedger.recordGuidanceShown(
            forAuthority: other, currentAuthority: other, deletionFrozen: false
        ))

        try ParticipantLocalPresentationStorage.retire(defaults: defaults, generation: UUID().uuidString)

        XCTAssertFalse(staleLedger.recordGuidanceShown(
            forAuthority: authority, currentAuthority: authority, deletionFrozen: false
        ))
        XCTAssertEqual(
            defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey),
            [try XCTUnwrap(FirstRequestGuidanceLedger.entry(forAuthority: other))]
        )
    }

    func testFirstRequestLengthensOnlyTheSettleAndKeepsReduceMotionParity() {
        typealias Plan = RequestCreationContinuityMotionPlan
        XCTAssertEqual(Plan.firstRequestSuccessDwellDuration, .milliseconds(3500))
        for reduceMotion in [false, true] {
            let base = Plan.plan(reduceMotion: reduceMotion)
            let first = Plan.plan(reduceMotion: reduceMotion, isFirstRequest: true)
            XCTAssertEqual(Plan.plan(reduceMotion: reduceMotion, isFirstRequest: false), base)
            XCTAssertEqual(base.totalDuration, Plan.successDwellDuration)
            XCTAssertEqual(first.totalDuration, Plan.firstRequestSuccessDwellDuration)
            XCTAssertEqual(first.settleDwell, .milliseconds(3000))
            XCTAssertEqual(first.landingDuration, base.landingDuration)
            XCTAssertEqual(first.entranceRise, base.entranceRise)
            XCTAssertEqual(first.entranceScale, base.entranceScale)
        }
    }

    func testContentViewRecordsGuidanceOnlyWhenThePresentationFinishes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/ContentView.swift"),
            encoding: .utf8
        )
        let presentation = try XCTUnwrap(source.range(of: "RequestCreationContinuityView("))
        let end = try XCTUnwrap(source.range(of: ".id(continuity.id)", range: presentation.upperBound..<source.endIndex))
        let call = String(source[presentation.lowerBound..<end.lowerBound])
        let finished = try XCTUnwrap(call.range(of: "onFinished: { id in"))
        let record = try XCTUnwrap(call.range(of: "recordGuidanceShown("))
        let retire = try XCTUnwrap(call.range(of: "requestStore.retireCreationContinuity(id: id)"))
        XCTAssertLessThan(finished.lowerBound, record.lowerBound)
        XCTAssertLessThan(record.lowerBound, retire.lowerBound)
        XCTAssertTrue(call.contains("isFirstRequest: guidanceLedger.showsGuidance("))
        XCTAssertTrue(call.contains("currentAuthority: participantIdentityStore.currentAuthority()"))
        XCTAssertTrue(call.contains("deletionFrozen: participantDeletionStore.hasRecord"))
        XCTAssertEqual(source.components(separatedBy: "recordGuidanceShown(").count - 1, 1)
    }

    // MARK: - Evidence

    @MainActor
    func testCaptureFirstAndSubsequentSuccess() throws {
        for (isFirst, name) in [(true, "cp2-success-first-request"), (false, "cp2-success-subsequent-request")] {
            // A fresh host per appearance keeps each frame inside the shorter
            // 1.1s settle of a later post.
            for (style, appearance) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
                let host = try UI1Checkpoint1CorrectionsTests.Host(
                    RequestCreationContinuityView(
                        continuity: makeContinuity(),
                        homeSlotFrame: nil,
                        reduceMotion: true,
                        onFinished: { _ in },
                        isFirstRequest: isFirst
                    )
                )
                host.window.overrideUserInterfaceStyle = style
                host.settle(0.4)
                try host.screenshot(named: name, appearance: appearance)
                host.close()
            }
        }
    }

    private func makeContinuity() -> RequestCreationContinuity {
        let request = FoodRequest(
            id: "cp2-first-request",
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "Chicken bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 1,
            resource: .unspecified,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .open,
            ownership: .own
        )
        return RequestCreationContinuity(operationId: "op-cp2-first", participantAuthority: authority, request: request)
    }
}
