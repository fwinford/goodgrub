//
//  RequestFoodDraftSessionTests.swift
//  CommonPlateiosTests
//

import XCTest
@testable import CommonPlateios

@MainActor
final class RequestFoodDraftSessionTests: XCTestCase {
    func testManualDraftSurvivesRouteRecreationAndBackgroundInSameProcess() {
        let owner = RequestFoodDraftSession()
        let chosenTime = Date(timeIntervalSince1970: 1_776_000_000)
        owner.draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: "140 E 14th St"),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: chosenTime,
            mealSwipes: 3,
            mealEntries: ["Chicken bowl with salsa", "Side salad", "Iced tea", "", ""],
            diningDollarsText: "4.75"
        )

        // Route exit/re-entry and scene backgrounding recreate views, not this
        // ContentView-owned process object.
        let reenteredOwner = owner

        XCTAssertEqual(reenteredOwner.draft.selectedDiningSpot?.name, "Jasper Kane Cafe")
        XCTAssertEqual(reenteredOwner.draft.timing, .later)
        XCTAssertEqual(reenteredOwner.draft.preferredPickupTime, chosenTime)
        XCTAssertEqual(reenteredOwner.draft.mealSwipes, 3)
        // W4-R4: every structured value survives route recreation with the
        // rest of the draft, including the typed Dining Dollar estimate.
        XCTAssertEqual(reenteredOwner.draft.menuPath, .mealExchange)
        XCTAssertEqual(
            reenteredOwner.draft.activeMealEntries,
            ["Chicken bowl with salsa", "Side salad", "Iced tea"]
        )
        XCTAssertEqual(reenteredOwner.draft.diningDollarsText, "4.75")
    }

    func testProposalAndManualPrecedenceMetadataSurviveWithDraft() {
        let owner = RequestFoodDraftSession()
        owner.draft.selectedDiningSpot = DiningSpot(name: "Jasper Kane Cafe", address: nil)
        owner.draft.mealEntries[0] = "Manual edit after proposal"
        owner.draft.mealSwipes = 2
        owner.screenshotManualEdits.manuallyEditedMealItemNames = [0]
        owner.screenshotProvenance.location = true
        owner.screenshotProvenance.mealSwipes = true

        let reenteredOwner = owner

        XCTAssertEqual(reenteredOwner.draft.mealEntries[0], "Manual edit after proposal")
        XCTAssertTrue(reenteredOwner.screenshotManualEdits.hasManuallyEditedMealItemName(0))
        XCTAssertTrue(reenteredOwner.screenshotProvenance.location)
        XCTAssertFalse(reenteredOwner.screenshotProvenance.mealEntries.contains(0))
        XCTAssertTrue(reenteredOwner.screenshotProvenance.mealSwipes)
    }

    func testAuthoritativeCreationClearsCompletedDraftAndS1Metadata() {
        let owner = RequestFoodDraftSession()
        owner.draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .diningDollars,
            timing: .later,
            preferredPickupTime: Date(timeIntervalSince1970: 1_776_000_000),
            mealSwipes: 4,
            mealEntries: ["Completed request", "", "", "", ""],
            orderDetails: "Completed order",
            diningDollarsText: "12.34"
        )
        owner.screenshotManualEdits.hasManuallyEditedLocation = true
        owner.screenshotManualEdits.manuallyEditedMealItemNames = [0]
        owner.screenshotManualEdits.hasManuallyEditedMealSwipes = true
        owner.screenshotProvenance.location = true

        owner.clearAfterAuthoritativeCreation()

        XCTAssertNil(owner.draft.selectedDiningSpot)
        // A completed creation clears every structured value too, so a
        // genuinely new Request Food entry inherits nothing.
        XCTAssertEqual(owner.draft.mealEntries, RequestFoodFormDraft.emptyMealEntries)
        XCTAssertEqual(owner.draft.orderDetails, "")
        XCTAssertEqual(owner.draft.diningDollarsText, "")
        XCTAssertEqual(owner.draft.menuPath, .mealExchange)
        XCTAssertEqual(owner.draft.timing, .asap)
        XCTAssertEqual(owner.draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first)
        XCTAssertEqual(owner.screenshotManualEdits, ScreenshotFieldManualEditState())
        XCTAssertEqual(owner.screenshotProvenance, ScreenshotProposalAppliedFields())
    }

    // MARK: - W4-D2 FIX 2026-09-18 (independent-review MUST FIX 2): terminal
    // recovery must replace the whole session, never merely the draft.

    /// Path A contaminated-session test: a session left dirty by an unrelated
    /// draft/request must not let any of that contamination attach to the
    /// trusted restored draft.
    func testReplaceForTerminalRecoveryInstallsTrustedDraftAndDiscardsAllContamination() {
        let owner = RequestFoodDraftSession()
        // Deliberate contamination from an unrelated in-progress draft.
        owner.draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Contaminated Spot", address: nil),
            menuPath: .diningDollars,
            timing: .later,
            preferredPickupTime: Date(timeIntervalSince1970: 1_700_000_000),
            mealSwipes: 5,
            mealEntries: ["Stale 1", "Stale 2", "", "", ""],
            orderDetails: "Stale order",
            diningDollarsText: "9.99"
        )
        owner.screenshotManualEdits.hasManuallyEditedLocation = true
        owner.screenshotManualEdits.hasManuallyEditedOrderDetails = true
        owner.screenshotManualEdits.manuallyEditedMealItemNames = [0, 1]
        owner.screenshotManualEdits.manuallyEditedMealItemDetails = [0, 1]
        owner.screenshotProvenance.location = true
        owner.screenshotProvenance.orderDetails = true
        owner.screenshotProvenance.mealItemNames = [0]

        let trustedDraft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 1_800_000_000),
            mealSwipes: 1,
            mealEntries: ["Trusted meal", "", "", "", ""],
            orderDetails: "",
            diningDollarsText: ""
        )

        owner.replaceForTerminalRecovery(restoring: trustedDraft)

        XCTAssertEqual(owner.draft, trustedDraft)
        XCTAssertEqual(owner.screenshotManualEdits, ScreenshotFieldManualEditState())
        XCTAssertEqual(owner.screenshotProvenance, ScreenshotProposalAppliedFields())
    }

    /// Path B contaminated-session test: `Start a new request` must be
    /// behaviorally equivalent to a genuinely fresh Request Food form, no
    /// matter what an unrelated earlier draft/session left behind.
    func testStartEmptyAfterTerminalRecoveryResetsAllContamination() {
        let owner = RequestFoodDraftSession()
        owner.draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Contaminated Spot", address: nil),
            menuPath: .diningDollars,
            timing: .later,
            preferredPickupTime: Date(timeIntervalSince1970: 1_700_000_000),
            mealSwipes: 5,
            mealEntries: ["Stale 1", "Stale 2", "", "", ""],
            orderDetails: "Stale order",
            diningDollarsText: "9.99"
        )
        owner.screenshotManualEdits.hasManuallyEditedMealSwipes = true
        owner.screenshotManualEdits.manuallyEditedMealItemNames = [0, 1]
        owner.screenshotManualEdits.manuallyEditedMealItemDetails = [0, 1]
        owner.screenshotProvenance.mealSwipes = true
        owner.screenshotProvenance.mealItemNames = [0, 1]
        owner.screenshotProvenance.mealItemDetails = [0, 1]

        owner.startEmptyAfterTerminalRecovery()

        // `RequestFoodFormDraft()`'s default `preferredPickupTime` is `Date()`
        // at construction, so it is checked field-by-field rather than by
        // whole-struct equality against a separately constructed default.
        XCTAssertNil(owner.draft.selectedDiningSpot)
        XCTAssertEqual(owner.draft.menuPath, .mealExchange)
        XCTAssertEqual(owner.draft.timing, .asap)
        XCTAssertEqual(owner.draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first)
        XCTAssertEqual(owner.draft.mealEntries, RequestFoodFormDraft.emptyMealEntries)
        XCTAssertEqual(owner.draft.orderDetails, "")
        XCTAssertEqual(owner.draft.diningDollarsText, "")
        XCTAssertEqual(owner.screenshotManualEdits, ScreenshotFieldManualEditState())
        XCTAssertEqual(owner.screenshotProvenance, ScreenshotProposalAppliedFields())
    }

    func testOwnerIsWiredAboveRouteWithoutDurableOrCreateAuthority() throws {
        let contentSource = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        let entrySource = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift")
        let ownerSource = try fileSource("ios/CommonPlateios/CommonPlateios/Stores/RequestFoodDraftSession.swift")

        XCTAssertTrue(contentSource.contains("@StateObject private var requestFoodDraftSession"))
        XCTAssertTrue(contentSource.contains("draftSession: requestFoodDraftSession"))
        XCTAssertTrue(entrySource.contains("@ObservedObject var draftSession"))
        XCTAssertTrue(entrySource.contains("draftSession: draftSession"))
        for forbidden in ["UserDefaults", "AppStorage", "FileManager", "RequestService", "createRequest("] {
            XCTAssertFalse(ownerSource.contains(forbidden), forbidden)
        }
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
