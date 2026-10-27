//
//  StructuredRequestDraftTests.swift
//  CommonPlateiosTests
//
// W4-R4 requester draft behaviour: the structured Meal Exchange /
// Dining-Dollars-only representation, swipe-count draft preservation, exact
// currency entry, and what actually reaches `CreateRequestPayload`.
import XCTest
@testable import CommonPlateios

final class StructuredRequestDraftTests: XCTestCase {
    private let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_000)

    private func mealExchangeDraft(
        mealSwipes: Int = 2,
        entries: [String] = ["Rice bowl", "Side salad", "", "", ""],
        diningDollarsText: String = ""
    ) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: now,
            mealSwipes: mealSwipes,
            mealEntries: entries,
            diningDollarsText: diningDollarsText
        )
    }

    private func diningDollarsDraft(
        orderDetails: String = "Grain bowl with extra avocado",
        diningDollarsText: String = "18.50"
    ) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .diningDollars,
            timing: .asap,
            preferredPickupTime: now,
            orderDetails: orderDetails,
            diningDollarsText: diningDollarsText
        )
    }

    private func errors(_ draft: RequestFoodFormDraft) -> [RequestFoodFieldError] {
        RequestFoodFormValidator.validate(
            draft: draft,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
    }

    // MARK: - One meal field per active swipe

    func testOneMealFieldExistsPerSelectedSwipe() {
        for count in RequestFoodFormDraft.mealSwipeOptions {
            let draft = mealExchangeDraft(mealSwipes: count)
            XCTAssertEqual(Array(draft.activeMealEntryIndices), Array(0..<count))
            XCTAssertEqual(draft.activeMealEntries.count, count)
        }
    }

    func testEveryActiveMealFieldIsRequiredBeforePosting() {
        // Three swipes, only two filled: the third is required and invalid.
        let draft = mealExchangeDraft(
            mealSwipes: 3,
            entries: ["Rice bowl", "Side salad", "  ", "", ""]
        )

        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(draft))
        XCTAssertEqual(
            errors(draft).map(\.field),
            [.mealDetail(index: 2)]
        )
    }

    func testACompleteMealExchangeDraftIsValidWithNoDiningDollars() {
        let draft = mealExchangeDraft()

        XCTAssertTrue(RequestFoodFormValidator.hasRequiredInput(draft))
        XCTAssertTrue(errors(draft).isEmpty)
    }

    // MARK: - Swipe-count decrease preserves, re-increase restores

    func testLoweringTheSwipeCountHidesHigherEntriesWithoutDestroyingThem() {
        var draft = mealExchangeDraft(
            mealSwipes: 4,
            entries: ["First", "Second", "Third", "Fourth", ""]
        )

        draft.mealSwipes = 2

        // Hidden from the form and excluded from submission...
        XCTAssertEqual(draft.activeMealEntries, ["First", "Second"])
        XCTAssertEqual(Array(draft.activeMealEntryIndices), [0, 1])
        // ...but still exactly where the requester left them.
        XCTAssertEqual(draft.mealEntries[2], "Third")
        XCTAssertEqual(draft.mealEntries[3], "Fourth")
    }

    func testRaisingTheSwipeCountAgainRestoresTheExactHiddenContent() {
        var draft = mealExchangeDraft(
            mealSwipes: 4,
            entries: ["First", "Second", "Third", "Fourth", ""]
        )

        draft.mealSwipes = 1
        draft.mealSwipes = 4

        XCTAssertEqual(
            draft.activeMealEntries,
            ["First", "Second", "Third", "Fourth"]
        )
    }

    func testRepeatedDecreaseAndIncreaseNeverLosesContent() {
        var draft = mealExchangeDraft(
            mealSwipes: 5,
            entries: ["A", "B", "C", "D", "E"]
        )
        let original = draft.mealEntries

        for count in [1, 5, 2, 4, 3, 5] {
            draft.mealSwipes = count
            XCTAssertEqual(
                draft.mealEntries,
                original,
                "changing the swipe count must never rewrite stored entries"
            )
        }
        XCTAssertEqual(draft.activeMealEntries, ["A", "B", "C", "D", "E"])
    }

    func testHiddenEntryContentIsExcludedFromTheConstructedPayload() throws {
        var draft = mealExchangeDraft(
            mealSwipes: 4,
            entries: ["First", "Second", "Hidden third", "Hidden fourth", ""]
        )
        draft.mealSwipes = 2

        let payload = try RequestFoodView.makePayload(
            draft: draft,
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.mealSwipes, 2)
        XCTAssertEqual(payload.mealItems, ["First", "Second"])
        // The hidden text is nowhere in the encoded request, not merely
        // absent from the array.
        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("Hidden third"))
        XCTAssertFalse(json.contains("Hidden fourth"))
    }

    func testAHiddenBlankEntryDoesNotBlockSubmission() {
        // Entries 3-5 are blank, but only the two active ones are required.
        let draft = mealExchangeDraft(
            mealSwipes: 2,
            entries: ["First", "Second", "", "", ""]
        )

        XCTAssertTrue(RequestFoodFormValidator.hasRequiredInput(draft))
        XCTAssertTrue(errors(draft).isEmpty)
    }

    // MARK: - Dining-Dollars-only

    func testACompleteDiningDollarsOnlyDraftIsValid() {
        let draft = diningDollarsDraft()

        XCTAssertEqual(draft.activeMealSwipes, 0)
        XCTAssertTrue(RequestFoodFormValidator.hasRequiredInput(draft))
        XCTAssertTrue(errors(draft).isEmpty)
    }

    func testDiningDollarsOnlyRequiresOrderDetails() {
        let draft = diningDollarsDraft(orderDetails: "   ")

        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(draft))
        XCTAssertEqual(errors(draft).map(\.field), [.orderDetails])
    }

    func testDiningDollarsOnlyRequiresAnAmount() {
        let draft = diningDollarsDraft(diningDollarsText: "")

        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(draft))
        XCTAssertEqual(errors(draft).map(\.error), [.missingDiningDollars])
    }

    func testDiningDollarsOnlyRefusesAnAmountAboveFiftyDollars() {
        let draft = diningDollarsDraft(diningDollarsText: "50.01")

        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(draft))
        XCTAssertEqual(
            errors(draft).map(\.error),
            [.invalidDiningDollars(ceilingCents: 5_000)]
        )
    }

    func testDiningDollarsOnlyAcceptsExactlyFiftyDollars() {
        XCTAssertTrue(
            RequestFoodFormValidator.hasRequiredInput(
                diningDollarsDraft(diningDollarsText: "50.00")
            )
        )
    }

    func testDiningDollarsOnlyPayloadCarriesZeroSwipesAndExactCents() throws {
        let payload = try RequestFoodView.makePayload(
            draft: diningDollarsDraft(),
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.menuPath, .diningDollars)
        XCTAssertEqual(payload.mealSwipes, 0)
        XCTAssertEqual(payload.mealItems, [])
        XCTAssertEqual(payload.orderDetails, "Grain bowl with extra avocado")
        XCTAssertEqual(payload.estimatedDiningDollarsCents, 1_850)
    }

    // MARK: - Optional Meal Exchange Dining Dollars

    func testMealExchangeDiningDollarsAreOptionalAndEmptyMeansNone() throws {
        let draft = mealExchangeDraft(diningDollarsText: "")

        XCTAssertTrue(RequestFoodFormValidator.hasRequiredInput(draft))
        let payload = try RequestFoodView.makePayload(
            draft: draft,
            now: now,
            calendar: utcCalendar
        )

        // Absent, never a fabricated `$0.00`.
        XCTAssertNil(payload.estimatedDiningDollarsCents)
        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertFalse(json.keys.contains("estimatedDiningDollarsCents"))
    }

    func testMealExchangeDiningDollarsAreRefusedAboveTwentyFiveDollars() {
        let draft = mealExchangeDraft(diningDollarsText: "25.01")

        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(draft))
        XCTAssertEqual(
            errors(draft).map(\.error),
            [.invalidDiningDollars(ceilingCents: 2_500)]
        )
    }

    func testMealExchangeAcceptsExactlyTwentyFiveDollars() throws {
        let payload = try RequestFoodView.makePayload(
            draft: mealExchangeDraft(diningDollarsText: "25.00"),
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.estimatedDiningDollarsCents, 2_500)
    }

    func testAZeroAmountIsInvalidRatherThanTreatedAsEmpty() {
        // Typing `0` says something different from typing nothing, and
        // neither may silently become the other.
        let draft = mealExchangeDraft(diningDollarsText: "0")

        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(draft))
        XCTAssertEqual(
            errors(draft).map(\.error),
            [.invalidDiningDollars(ceilingCents: 2_500)]
        )
    }

    // MARK: - Exact currency entry

    func testOrdinaryDollarEntryParsesToExactCents() {
        let cases: [(String, Int)] = [
            ("1", 100),
            ("0.01", 1),
            (".5", 50),
            ("0.05", 5),
            ("12.34", 1_234),
            ("12.3", 1_230),
            ("$12.34", 1_234),
            ("  12.34  ", 1_234),
            ("1,234.56", 123_456),
            ("25", 2_500),
        ]

        for (text, expected) in cases {
            guard case .cents(let cents) = DiningDollarsEntry.parse(text) else {
                XCTFail("\(text) should parse to an exact amount")
                continue
            }
            XCTAssertEqual(cents, expected, "\(text)")
        }
    }

    func testEmptyEntryIsEmptyRatherThanZero() {
        XCTAssertEqual(DiningDollarsEntry.parse(""), .empty)
        XCTAssertEqual(DiningDollarsEntry.parse("   "), .empty)
        // Zero is not empty.
        XCTAssertEqual(DiningDollarsEntry.parse("0"), .invalid)
        XCTAssertEqual(DiningDollarsEntry.parse("0.00"), .invalid)
    }

    func testNonAmountsAreRefusedRatherThanCoerced() {
        for text in ["abc", "12.345", "1.2.3", "$", "-5", "12-34", "1e3"] {
            XCTAssertEqual(
                DiningDollarsEntry.parse(text),
                .invalid,
                "\(text) must be refused, not coerced into an amount"
            )
        }
    }

    func testAPastedEnormousNumberIsRefusedRatherThanOverflowing() {
        XCTAssertEqual(
            DiningDollarsEntry.parse(String(repeating: "9", count: 40)),
            .invalid
        )
        // Just past `Int.max` cents, with and without valid grouping.
        XCTAssertEqual(DiningDollarsEntry.parse("92233720368547759"), .invalid)
        XCTAssertEqual(DiningDollarsEntry.parse("92,233,720,368,547,759"), .invalid)
        XCTAssertEqual(DiningDollarsEntry.parse("92233720368547758.08"), .invalid)
    }

    /// A misplaced comma must never be stripped into a different amount:
    /// `1,2` is not `$12.00`.
    func testMalformedThousandsSeparatorsAreRefusedRatherThanStripped() {
        for text in [
            "1,2", "12,34", "1,2.50", "$1,2", "1,23", "1,2345", "1234,567",
            "1,,234", ",123", "123,", "1,234,56", ",", "$,", "0,5", "1.2,3",
            "12.3,4", "1,234.5,6",
        ] {
            XCTAssertEqual(
                DiningDollarsEntry.parse(text),
                .invalid,
                "\(text) must be refused, not read as a different amount"
            )
        }
    }

    func testValidThousandsGroupingStillParsesExactly() {
        let cases: [(String, Int)] = [
            ("1,234", 123_400),
            ("1,234.56", 123_456),
            ("$1,234.5", 123_450),
            ("12,345,678.90", 1_234_567_890),
            ("1,000.", 100_000),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(DiningDollarsEntry.parse(text), .cents(expected), "\(text)")
        }
    }

    /// Grouping never widens the accepted bounds: a grouped amount is still
    /// held to each path's ceiling, and a grouped zero is still zero.
    func testGroupedAmountsRemainBoundedByThePathCeilings() {
        XCTAssertEqual(DiningDollarsEntry.parse("0,000"), .invalid)
        XCTAssertEqual(DiningDollarsEntry.parse("0,000.00"), .invalid)
        XCTAssertEqual(
            RequestFoodFormValidator.hasRequiredInput(mealExchangeDraft(diningDollarsText: "25.00")),
            true
        )
        XCTAssertEqual(
            RequestFoodFormValidator.hasRequiredInput(mealExchangeDraft(diningDollarsText: "1,000")),
            false
        )
        XCTAssertEqual(
            RequestFoodFormValidator.hasRequiredInput(diningDollarsDraft(diningDollarsText: "50.00")),
            true
        )
        XCTAssertEqual(
            RequestFoodFormValidator.hasRequiredInput(diningDollarsDraft(diningDollarsText: "50.01")),
            false
        )
        XCTAssertEqual(
            RequestFoodFormValidator.hasRequiredInput(diningDollarsDraft(diningDollarsText: "1,000.00")),
            false
        )
        // The malformed entry that used to become $12.00 is not submittable.
        XCTAssertEqual(
            RequestFoodFormValidator.hasRequiredInput(diningDollarsDraft(diningDollarsText: "1,2")),
            false
        )
        XCTAssertEqual(
            RequestFoodFormValidator.hasRequiredInput(mealExchangeDraft(diningDollarsText: "1,2")),
            false
        )
    }

    func testNonASCIIDigitsAreRefused() {
        for text in ["١٢", "１２", "½"] {
            XCTAssertEqual(DiningDollarsEntry.parse(text), .invalid, "\(text)")
        }
    }

    /// The exactness guarantee itself: every accepted amount round-trips
    /// through entry text and back to the same integer cents, with no
    /// floating-point step anywhere in between.
    func testEveryAcceptedAmountRoundTripsExactly() {
        for cents in 1...RequestFoodFormDraft.diningDollarsOnlyCeilingCents {
            let text = DiningDollarsEntry.formatted(cents: cents)
            guard case .cents(let parsed) = DiningDollarsEntry.parse(text) else {
                XCTFail("\(text) must parse back to an amount")
                continue
            }
            XCTAssertEqual(parsed, cents)
        }
    }

    func testFormattingMatchesTheBackendsOwnIntegerFormatting() {
        XCTAssertEqual(DiningDollarsEntry.formatted(cents: 1), "$0.01")
        XCTAssertEqual(DiningDollarsEntry.formatted(cents: 100), "$1.00")
        XCTAssertEqual(DiningDollarsEntry.formatted(cents: 1_005), "$10.05")
        XCTAssertEqual(DiningDollarsEntry.formatted(cents: 1_850), "$18.50")
        XCTAssertEqual(DiningDollarsEntry.formatted(cents: 5_000), "$50.00")
    }

    // MARK: - Pickup name removal

    func testTheDraftHasNoPickupNameAndThePayloadNeverEncodesOne() throws {
        let payload = try RequestFoodView.makePayload(
            draft: mealExchangeDraft(),
            now: now,
            calendar: utcCalendar
        )

        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertFalse(json.keys.contains("pickupName"))
        // The backend derives the summary, so this app never sends one.
        XCTAssertFalse(json.keys.contains("food"))
        XCTAssertEqual(
            Set(json.keys),
            Set(["vendor", "timing", "menuPath", "mealSwipes", "mealItems"])
        )
    }

    func testNoRequestFormFieldRepresentsAPickupName() {
        // The focusable-field vocabulary itself has no pickup-name case left.
        let fieldDescriptions = RequestFoodFormField.allCases.map(String.init(describing:))
        XCTAssertFalse(fieldDescriptions.contains { $0.lowercased().contains("pickup name") })
        XCTAssertFalse(fieldDescriptions.contains { $0 == "pickupName" })
    }

    // MARK: - Path switching preserves the requester's own words

    func testSwitchingMenusPreservesBothPathsDraftContent() throws {
        var draft = mealExchangeDraft(
            mealSwipes: 2,
            entries: ["Rice bowl", "Side salad", "", "", ""],
            diningDollarsText: "4.75"
        )
        draft.orderDetails = "A dining dollars order"

        draft.menuPath = .diningDollars
        XCTAssertEqual(draft.activeMealSwipes, 0)
        XCTAssertEqual(draft.orderDetails, "A dining dollars order")
        // The meal entries are untouched, merely not part of this path.
        XCTAssertEqual(draft.mealEntries[0], "Rice bowl")

        draft.menuPath = .mealExchange
        XCTAssertEqual(draft.activeMealSwipes, 2)
        XCTAssertEqual(draft.activeMealEntries, ["Rice bowl", "Side salad"])
        XCTAssertEqual(draft.diningDollarsText, "4.75")
    }

    func testOnlyTheActivePathsFieldsReachThePayload() throws {
        var draft = mealExchangeDraft(
            mealSwipes: 1,
            entries: ["Rice bowl", "", "", "", ""]
        )
        draft.orderDetails = "Should not be submitted on this path"

        let mealExchangePayload = try RequestFoodView.makePayload(
            draft: draft,
            now: now,
            calendar: utcCalendar
        )
        XCTAssertNil(mealExchangePayload.orderDetails)

        draft.menuPath = .diningDollars
        draft.orderDetails = "Grain bowl"
        draft.diningDollarsText = "12.00"
        let diningDollarsPayload = try RequestFoodView.makePayload(
            draft: draft,
            now: now,
            calendar: utcCalendar
        )
        XCTAssertEqual(diningDollarsPayload.mealItems, [])
        XCTAssertEqual(diningDollarsPayload.orderDetails, "Grain bowl")
    }

    // MARK: - Timing continuity (W4-R2, unchanged by R4)

    func testTimingSelectionSurvivesTheStructuredRepresentation() throws {
        var draft = mealExchangeDraft()
        let start = Date(timeIntervalSince1970: 2_000)
        draft.timing = .later
        draft.preferredPickupTime = start

        let payload = try RequestFoodView.makePayload(
            draft: draft,
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(payload.timing, .scheduled)
        XCTAssertEqual(payload.windowStart, start)
        // Still only the start: R4 adds no end, exactly as R2 accepted.
        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertFalse(json.keys.contains("windowEnd"))
    }
}
