//
//  RequestFoodMenuPathHostedTests.swift
//  CommonPlateiosTests
//
// W4-R4.1 hosted simulator proof. Every test mounts the real production
// `RequestFoodView` (`RequesterFormHost`), applies a deterministic outcome
// through the real `ScreenshotProposalStore.apply` onto the SAME draft session
// the view renders, and then reads what the view actually shows: which menu
// option is selected, which branch's fields exist, what the amount field
// contains, and whether Post is enabled. The menu selector is exercised through
// the real control (the accessibility action VoiceOver's double-tap uses), so
// the manual-authority latch is proven through the production binding, not a
// re-implementation of it.
//
// Not established here: the Photos picker → Vision OCR → provider pipeline
// (there is no UI-test target and a `PhotosPickerItem` cannot be constructed),
// keyboard behavior, or physical-device rendering. The pipeline up to the
// outcome is covered by `ScreenshotMenuPathApplicationTests`; the physical
// iPhone checkout/payment-row proof remains Faith's.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestFoodMenuPathHostedTests: XCTestCase {
    private let spot = DiningSpot(name: "Jasper Kane Cafe", address: nil)

    private let mealKey = "request-menu-path-meal-exchange"
    private let diningKey = "request-menu-path-dining-dollars"

    private func makeStore() -> ScreenshotProposalStore {
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: .ephemeral)
        )
        return ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage()
        )
    }

    private func draft(
        path: RequestMenuPath = .mealExchange,
        meal: String = "Rice bowl",
        orderDetails: String = "",
        topUp: String = "",
        diningOnly: String = ""
    ) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: spot,
            menuPath: path,
            timing: .asap,
            mealSwipes: 1,
            mealEntries: [meal, "", "", "", ""],
            orderDetails: orderDetails,
            mealExchangeDiningDollarsText: topUp,
            diningDollarsOnlyText: diningOnly
        )
    }

    /// Mirrors `RequestFoodView.applyScreenshotOutcome`'s state changes: the
    /// real store apply, then recording that assistance established a path.
    @discardableResult
    private func applyOutcome(
        _ proposal: ScreenshotProposal,
        store: ScreenshotProposalStore,
        host: RequesterFormHost
    ) -> ScreenshotProposalAppliedFields {
        let session = host.draftSession
        var draft = session.draft
        // R4.2: an applicable result is a state-E outcome. The form's venue is
        // the anchor, so the R4.1 path behavior under test is exercised through
        // the venue gate rather than withheld by it.
        var anchored = proposal
        if anchored.selectedDiningSpot == nil { anchored.selectedDiningSpot = spot }
        let applied = store.apply(
            ScreenshotProposalOutcome(eligible: true, proposal: anchored, venueDisposition: .supported(spot)),
            manualEdits: session.screenshotManualEdits,
            to: &draft
        )
        session.draft = draft
        session.screenshotManualEdits.record(applied)
        if applied.establishedMenuPath { session.screenshotProvenance.menuPath = true }
        host.settle()
        return applied
    }

    private func isSelected(_ host: RequesterFormHost, _ key: String) throws -> Bool {
        try XCTUnwrap(host.nodes()[key], "no \(key)").accessibilityTraits.contains(.selected)
    }

    private func amountFieldText(_ host: RequesterFormHost) throws -> String? {
        try (XCTUnwrap(host.uiView(withIdentifier: "request-dining-dollars"), "no amount field") as? UITextField)?.text
    }

    private func isPostDisabled(_ host: RequesterFormHost) throws -> Bool {
        try XCTUnwrap(host.nodes()["request-post-request"], "no Post request")
            .accessibilityTraits.contains(.notEnabled)
    }

    private func assertMealBranchShown(_ host: RequesterFormHost, _ message: String, line: UInt = #line) throws {
        XCTAssertTrue(try isSelected(host, mealKey), "\(message): Meal Exchange selected", line: line)
        XCTAssertFalse(try isSelected(host, diningKey), "\(message): Dining Dollars not selected", line: line)
        XCTAssertTrue(host.exists("request-meal-control-0"), "\(message): Meal entry shown", line: line)
        XCTAssertFalse(host.exists("request-order-details-control"), "\(message): order details hidden", line: line)
    }

    private func assertDiningBranchShown(_ host: RequesterFormHost, _ message: String, line: UInt = #line) throws {
        XCTAssertTrue(try isSelected(host, diningKey), "\(message): Dining Dollars selected", line: line)
        XCTAssertFalse(try isSelected(host, mealKey), "\(message): Meal Exchange not selected", line: line)
        XCTAssertTrue(host.exists("request-order-details-control"), "\(message): order details shown", line: line)
        XCTAssertFalse(host.exists("request-meal-control-0"), "\(message): Meal entry hidden", line: line)
    }

    // MARK: - Deterministic switches, both directions

    func testMealExchangeDeterministicSwitchRendersTheMealBranch() throws {
        let host = try RequesterFormHost(draft: draft(path: .diningDollars, orderDetails: "Requester words", diningOnly: "$30.00"))
        try assertDiningBranchShown(host, "before")
        XCTAssertEqual(try amountFieldText(host), "$30.00")

        let applied = applyOutcome(
            ScreenshotProposal(menuPath: .mealExchange, mealItems: [MealItem(name: "1 Bowl")], mealSwipes: 1),
            store: makeStore(),
            host: host
        )

        XCTAssertTrue(applied.menuPath)
        XCTAssertEqual(applied.preservedManualFieldCount, 0)
        try assertMealBranchShown(host, "after deterministic Meal Exchange")
        XCTAssertEqual(try amountFieldText(host), "", "the Meal top-up draft shows, never the whole-order amount")
        XCTAssertEqual(host.draftSession.draft.diningDollarsOnlyText, "$30.00", "the inactive amount is retained")
        XCTAssertEqual(host.draftSession.draft.orderDetails, "Requester words")
    }

    func testDiningDollarsDeterministicSwitchRendersTheDiningBranchAndInventsNoAmount() throws {
        let host = try RequesterFormHost(draft: draft(path: .mealExchange, topUp: "$2.00"))
        try assertMealBranchShown(host, "before")
        XCTAssertEqual(try amountFieldText(host), "$2.00")

        let applied = applyOutcome(
            ScreenshotProposal(menuPath: .diningDollars, mealItems: [MealItem(name: "1 Bowl")]),
            store: makeStore(),
            host: host
        )

        XCTAssertTrue(applied.menuPath)
        try assertDiningBranchShown(host, "after deterministic Dining Dollars")
        XCTAssertEqual(try amountFieldText(host), "", "the selected-method signal supplies no amount")
        XCTAssertEqual(host.draftSession.draft.orderDetails, "1 Bowl")
        XCTAssertEqual(host.draftSession.draft.mealExchangeDiningDollarsText, "$2.00", "the inactive top-up is retained")
        XCTAssertTrue(try isPostDisabled(host), "Post stays disabled until the active branch's amount validates")

        host.draftSession.draft.diningDollarsText = "$12.00"
        host.settle()
        XCTAssertEqual(try amountFieldText(host), "$12.00")
        XCTAssertFalse(try isPostDisabled(host), "Post enables once the active branch validates")
    }

    // MARK: - No evidence / conflict preserve the selection

    func testNoEvidenceAndConflictResultsPreserveTheRequesterSelection() throws {
        for path in [RequestMenuPath.mealExchange, .diningDollars] {
            let host = try RequesterFormHost(draft: draft(path: path, orderDetails: "Fries", topUp: "$1.00", diningOnly: "$9.00"))
            let store = makeStore()
            // A no-path result (no evidence, or a disputed selection whose
            // validator omitted the path and every branch-dependent value).
            let applied = applyOutcome(ScreenshotProposal(selectedDiningSpot: spot), store: store, host: host)
            XCTAssertFalse(applied.menuPath)
            XCTAssertFalse(applied.establishedMenuPath)
            XCTAssertEqual(host.draftSession.draft.menuPath, path)
            if path == .mealExchange {
                try assertMealBranchShown(host, "no path / conflict")
            } else {
                try assertDiningBranchShown(host, "no path / conflict")
            }
            XCTAssertEqual(host.draftSession.draft.mealExchangeDiningDollarsText, "$1.00")
            XCTAssertEqual(host.draftSession.draft.diningDollarsOnlyText, "$9.00")
            XCTAssertFalse(host.draftSession.screenshotManualEdits.hasScreenshotEstablishedMenuPath)
        }
    }

    // MARK: - Manual override through the real selector

    func testRequesterOverrideThroughTheRealSelectorSurvivesARerun() throws {
        let host = try RequesterFormHost(draft: draft(path: .mealExchange))
        let store = makeStore()

        applyOutcome(ScreenshotProposal(menuPath: .diningDollars), store: store, host: host)
        try assertDiningBranchShown(host, "assisted switch")
        XCTAssertTrue(host.draftSession.screenshotManualEdits.hasScreenshotEstablishedMenuPath)
        XCTAssertFalse(host.draftSession.screenshotManualEdits.hasManuallyEditedMenuPath)
        XCTAssertEqual(host.nodes()["request-menu-path-provenance"]?.accessibilityLabel, "Suggested")

        // Re-selecting the option that is already current is not a path change.
        XCTAssertTrue(host.activate(diningKey))
        XCTAssertFalse(host.draftSession.screenshotManualEdits.hasManuallyEditedMenuPath)
        try assertDiningBranchShown(host, "no-op re-selection")

        // A real change after assistance acted is requester-owned.
        XCTAssertTrue(host.activate(mealKey))
        try assertMealBranchShown(host, "requester override")
        XCTAssertTrue(host.draftSession.screenshotManualEdits.hasManuallyEditedMenuPath)
        XCTAssertEqual(host.nodes()["request-menu-path-provenance"]?.accessibilityLabel, "Manually selected")

        let rerun = applyOutcome(ScreenshotProposal(menuPath: .diningDollars), store: store, host: host)
        try assertMealBranchShown(host, "rerun cannot overwrite")
        XCTAssertFalse(rerun.menuPath)
        XCTAssertEqual(rerun.suggestedMenuPath, .diningDollars)
        XCTAssertEqual(rerun.preservedManualFieldCount, 0, "path assistance is inline")

        let same = applyOutcome(ScreenshotProposal(menuPath: .mealExchange), store: store, host: host)
        XCTAssertEqual(same.preservedManualFieldCount, 0, "a same-path proposal is not preservation")
        try assertMealBranchShown(host, "same-path rerun")
    }

    func testRequesterPathChangeBeforeAssistanceKeepsManualAuthority() throws {
        let host = try RequesterFormHost(draft: draft(path: .mealExchange))
        XCTAssertTrue(host.activate(diningKey))
        try assertDiningBranchShown(host, "requester picks first")
        XCTAssertTrue(host.draftSession.screenshotManualEdits.hasManuallyEditedMenuPath)

        applyOutcome(ScreenshotProposal(menuPath: .mealExchange), store: makeStore(), host: host)
        try assertDiningBranchShown(host, "manual path is preserved")
    }

    // MARK: - Branch amount round trip through the real selector

    func testBranchAmountsRoundTripThroughTheRealSelectorWithoutMixing() throws {
        let host = try RequesterFormHost(
            draft: draft(path: .mealExchange, orderDetails: "Grain bowl", topUp: "$2.00", diningOnly: "$30.00")
        )
        XCTAssertEqual(try amountFieldText(host), "$2.00")
        XCTAssertFalse(try isPostDisabled(host))

        XCTAssertTrue(host.activate(diningKey))
        XCTAssertEqual(try amountFieldText(host), "$30.00", "Dining Dollars shows its own amount")
        XCTAssertFalse(try isPostDisabled(host))

        XCTAssertTrue(host.activate(mealKey))
        XCTAssertEqual(try amountFieldText(host), "$2.00", "switching back restores the top-up")

        let finalDraft = host.draftSession.draft
        XCTAssertEqual(finalDraft.mealExchangeDiningDollarsText, "$2.00")
        XCTAssertEqual(finalDraft.diningDollarsOnlyText, "$30.00")
    }

    func testInactiveBranchAmountNeverParticipatesInTheActiveBranchsPostGate() throws {
        // A top-up above its own ceiling is irrelevant while Dining Dollars is
        // active; an empty whole-order amount is irrelevant on Meal Exchange.
        let dining = try RequesterFormHost(
            draft: draft(path: .diningDollars, orderDetails: "Grain bowl", topUp: "garbage", diningOnly: "$30.00")
        )
        XCTAssertFalse(try isPostDisabled(dining))

        let meal = try RequesterFormHost(draft: draft(path: .mealExchange, topUp: "", diningOnly: ""))
        XCTAssertFalse(try isPostDisabled(meal), "an empty top-up means none needed")

        let missing = try RequesterFormHost(draft: draft(path: .diningDollars, orderDetails: "Grain bowl", topUp: "$2.00", diningOnly: ""))
        XCTAssertTrue(try isPostDisabled(missing), "the top-up cannot satisfy the required whole-order amount")
    }
}
