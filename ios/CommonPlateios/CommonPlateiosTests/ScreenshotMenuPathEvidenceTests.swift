//
//  ScreenshotMenuPathEvidenceTests.swift
//  CommonPlateiosTests
//
// W4-R4.1 deterministic evidence: the third (checkout/review) eligibility
// category, the per-screenshot menu-path rule, conflict/no-evidence behavior,
// the provider boundary, and the on-device re-validation of an external
// result's path. All evidence is synthetic. The shared conformance vectors
// (`ScreenshotConformanceVectorTests`) are the parity guard; these cases try
// to break the rules directly.
import Foundation
import XCTest
@testable import CommonPlateios

final class ScreenshotMenuPathEvidenceTests: XCTestCase {
    private typealias Evidence = RequesterOrderDeterministicEvidence

    private static let cart = "Your Pickup Order\nContinue to Checkout"
    private static let diningRow = ["Your payment", "Payment method", "Dining Dollars"]

    private func review(_ lines: String..., delivery: Bool = false) -> String {
        ([delivery ? "Review your delivery order" : "Review your pickup order"] + lines)
            .joined(separator: "\n")
    }

    private func resolve(_ texts: String...) -> RequesterOrderDeterministicEvidence.MenuPathResolution {
        Evidence.resolveMenuPath(imageEvidenceTexts: texts)
    }

    // MARK: - Checkout/review eligibility

    func testQualifyingCheckoutReviewScreenshotsAreEligibleAsCheckout() {
        let accepted = [
            review("Your order", "1 Chicken Bowl", "Subtotal 12.00"),
            review("Your order", "2x Chicken Bowl", "Subtotal 12.00", delivery: true),
            review("Your payment", "Payment method", "Dining Dollars"),
            review("Your payment", "Payment method Visa", delivery: true),
            "Review your\npickup order\nYour\npayment\nSubtotal 12.00\nPayment\nmethod\nDining Dollars",
            review("Your payment", "Subtotal 12.00", "Payment method", "Dining Dollars"),
            "Review your pickup order\r\nYour order\r\n2x Chicken Bowl",
            // Classified as checkout before any cart phrase can claim it.
            review("Your order", "1 Chicken Bowl", "Order instructions", "Add more items"),
        ]
        for text in accepted {
            let result = Evidence.evaluateEligibility(text)
            XCTAssertTrue(result.eligible, text)
            XCTAssertEqual(result.category, .checkout, text)
        }
    }

    func testCheckoutCategoryIsNotNewlyGrantedWithoutTheBoundedStructure() {
        let rejected = [
            "Review your pickup order\nTotal due today\nEstimated total 12.00",
            review("Your order", "Subtotal 12.00", "Tax 1.06"),
            review("Your payment", "Subtotal 12.00", "Total 13.06"),
            review("Your order", "Your payment", "Subtotal 12.00", "1 Chicken Bowl"),
            "Your order\n1 Chicken Bowl\nYour payment\nPayment method\nDining Dollars",
            "Place your pickup order\nYour order\n1 Chicken Bowl",
            "Please Review your pickup order today\nYour order\n1 Chicken Bowl",
            review("Your payment", "Payment methods", "Dining Dollars"),
            "Checkout\nSubtotal 12.00\nTax 1.06\nTip 2.00\nTotal 15.06 Place order",
            "Menu browse popular items reviews rating delivery fee 3.99",
        ]
        for text in rejected {
            let result = Evidence.evaluateEligibility(text)
            XCTAssertFalse(result.eligible, text)
            XCTAssertNil(result.category, text)
        }
    }

    func testExistingCartAndStrictHistoricalEligibilityAreUnchanged() {
        XCTAssertEqual(
            Evidence.evaluateEligibility(Self.cart + "\n" + Self.diningRow.joined(separator: "\n")).category,
            .cart
        )
        XCTAssertEqual(
            Evidence.evaluateEligibility("View order\nOrder information\n2 x Chicken Bowl\nPayment method\nDining Dollars").category,
            .historical
        )
        XCTAssertEqual(
            Evidence.evaluateEligibility("Review your pickup order\nOrder instructions\nAdd more items").category,
            .cart,
            "the pre-existing checkout-context exclusion fixture is unchanged"
        )
        XCTAssertFalse(
            Evidence.evaluateEligibility("Review your pickup order please confirm this order today").eligible
        )
    }

    // MARK: - Meal Exchange evidence

    func testExplicitMealExchangeWordingEstablishesThePathWithoutACount() {
        let text = Self.cart + "\nCrave NYU - Meal Exchange"
        XCTAssertEqual(resolve(text), .init(menuPath: .mealExchange, conflict: false))
        XCTAssertNil(Evidence.corroboratedMealSwipeCount(text), "wording supplies no swipe count")
        XCTAssertEqual(resolve(Self.cart + "\nMEAL\nEXCHANGE").menuPath, .mealExchange)
        XCTAssertNil(resolve(Self.cart + "\nmeal exchanges").menuPath)
    }

    func testBoundedMNotationEstablishesMealExchangeUnderTheExistingRule() {
        for n in 1...5 {
            XCTAssertEqual(resolve(Self.cart + "\nTotal \(n)M").menuPath, .mealExchange, "\(n)M")
        }
        for text in ["6M", "0M", "Total 2M\nTotal 3M", "1.3M"] {
            XCTAssertEqual(resolve(Self.cart + "\n" + text), .noEvidence, text)
        }
        // Explicit wording still stands, but never repairs the count.
        let mixed = Self.cart + "\nMeal Exchange\nTotal 2M\nTotal 3M"
        XCTAssertEqual(resolve(mixed).menuPath, .mealExchange)
        XCTAssertNil(Evidence.corroboratedMealSwipeCount(mixed))
        XCTAssertEqual(resolve("Your pickup order\n3M + $2.00").menuPath, .mealExchange)
    }

    func testMealBasedPaymentIsMealExchangeWithoutCountAndOtherHeuristicsAreNotEvidence() {
        let mealPayment = Self.cart + "\nUse 1 Meal + Dining Dollars"
        XCTAssertEqual(resolve(mealPayment).menuPath, .mealExchange)
        XCTAssertNil(Evidence.corroboratedMealSwipeCount(mealPayment))
        for text in [
            "Meal swipe bowl meal",
            "Jasper Kane Cafe\nChicken Bowl\nSubtotal 12.00",
        ] {
            XCTAssertEqual(resolve(Self.cart + "\n" + text), .noEvidence, text)
        }
    }

    // MARK: - Dining Dollars evidence

    func testSelectedPaymentMethodRowEstablishesDiningDollarsOnCheckoutReviewOnly() {
        let accepted = [
            review(Self.diningRow[0], Self.diningRow[1], Self.diningRow[2]),
            review("Your payment", "Payment method Dining Dollars"),
            review("Your payment", "Payment method: Dining Dollars"),
            review("Your payment", "Payment method", "Dining Dollars >"),
            review("Your payment", "Payment method Dining Dollars \u{203A}"),
            review("YOUR  PAYMENT", "PAYMENT   METHOD", "dining\u{00A0}dollars"),
            review("Your order", "1 Chicken Bowl", "Your payment", "Payment method", "Dining Dollars", delivery: true),
            review("Your order", "1 Chicken Bowl", "Your payment", "Subtotal 12.00", "Payment method", "Dining Dollars"),
        ]
        for text in accepted {
            XCTAssertEqual(resolve(text), .init(menuPath: .diningDollars, conflict: false), text)
        }
        // The same signal outside the accepted category gains no authority.
        XCTAssertEqual(resolve(Self.cart + "\n" + Self.diningRow.joined(separator: "\n")), .noEvidence)
        XCTAssertEqual(
            resolve("View order\nOrder information\n2 x Chicken Bowl\n" + Self.diningRow.joined(separator: "\n")),
            .noEvidence
        )
    }

    func testIncidentalAlternativeAmbiguousAndOtherMethodLayoutsFailClosed() {
        let rejected: [String] = [
            review("Your order", "1 Chicken Bowl", "Dining Dollars applied -$2.00"),
            review("Your order", "1 Chicken Bowl", "Payment method", "Dining Dollars", "Credit card"),
            review("Your order", "1 Chicken Bowl", "Dining Dollars discount -$2.00", "Your payment", "Payment method", "Credit card"),
            review("Your payment", "Payment method", "Visa ending 1234"),
            review("Your payment", "Payment method", "Dining Dollars and Visa"),
            review("Your payment", "Payment method"),
            review("Your payment", "Payment method", "Dining Dollars", "Payment method", "Credit card"),
            review("Your payment", "Payment method", "Dining Dollars", "Payment method", "Dining Dollars"),
            review("Your payment", "Payment method", "Dining Dollars", "Your payment"),
            review("Your payment", "Payment method", "Dining Dollars", "Visa ending 1234"),
            review("Your payment", "Payment method", "Dining Dollars", "Visa1234"),
            review("Your order", "1 Chicken Bowl", "Subtotal $12.00", "Total $13.06"),
        ]
        for text in rejected {
            XCTAssertEqual(resolve(text), .noEvidence, text)
        }
    }

    func testSelectedPaymentSignalNeedsItsOwnTotalForAmount() {
        let text = review("Your order", "1 Chicken Bowl", "Subtotal $12.00", "Total $13.06", "Your payment", "Payment method", "Dining Dollars")
        let validated = RequesterOrderOutputValidator.validate(
            raw: RequesterOrderRawOutput(visibleVenueText: nil, foodItems: [], mealSwipes: nil).jsonObject,
            evidenceText: text,
            evidenceImageCount: 1,
            allowsDiningDollarsEstimate: true
        )
        guard case .valid(let proposal) = validated else { return XCTFail("expected a valid proposal") }
        XCTAssertEqual(proposal.menuPath, .diningDollars)
        XCTAssertNil(proposal.estimatedDiningDollarsCents)
        XCTAssertEqual(proposal.diningDollarsOrderTotalCents, 1306)
        XCTAssertNil(proposal.mealSwipes)
        XCTAssertFalse(ScreenshotProposalOutcome(eligible: true, proposal: proposal).isEmpty)
        let localOCRStrategy = RequesterOrderOutputValidator.validate(
            raw: RequesterOrderRawOutput(visibleVenueText: nil, foodItems: [], mealSwipes: nil).jsonObject,
            evidenceText: text,
            evidenceImageCount: 1,
            allowsDiningDollarsEstimate: false
        )
        guard case .valid(let localProposal) = localOCRStrategy else { return XCTFail("expected a valid local proposal") }
        XCTAssertEqual(localProposal.diningDollarsOrderTotalCents, 1306,
                       "the labeled Total is deterministic OCR evidence, not model amount authority")
    }

    func testCurrentDollarCartsHaveBoundedTotalAuthority() {
        for venue in ["Crave", "Starbucks", "Dunkin'"] {
            let text = Self.cart + "\n" + venue
                + "\n1 Coffee $4.25\nSubtotal $12.00\nTax $1.06\nTotal $13.06"
            XCTAssertEqual(resolve(text).menuPath, .diningDollars, venue)
            XCTAssertEqual(Evidence.currentOrderTotalCents(imageEvidenceTexts: [text]), 1306)
        }
        let base = Self.cart + "\nStarbucks\n1 Coffee $4.25"
        for suffix in [
            "", "Subtotal $4.25", "Tax $0.40", "Delivery fee $1.00",
            "Promo -$2.00", "Total $4.25\nTotal $5.25",
            "Total $4.25\nSplit payment",
            "Total $4.25\nSplit payment1234",
            "Total $13.06\nDining Dollars $5.00\nVisa $8.06"
        ] {
            let text = base + "\n" + suffix
            XCTAssertNil(resolve(text).menuPath, suffix)
            XCTAssertNil(Evidence.currentOrderTotalCents(imageEvidenceTexts: [text]), suffix)
        }
        let outOfBounds = Self.cart + "\nDunkin'\nTotal $99.00"
        XCTAssertEqual(resolve(outOfBounds).menuPath, .diningDollars)
        XCTAssertNil(Evidence.currentOrderTotalCents(imageEvidenceTexts: [outOfBounds]))
        let splitImages = [
            Self.cart + "\nTotal $13.06\nDining Dollars $5.00",
            Self.cart + "\nVisa $8.06"
        ]
        XCTAssertNil(Evidence.currentOrderTotalCents(imageEvidenceTexts: splitImages))
        XCTAssertNil(Evidence.resolveMenuPath(imageEvidenceTexts: splitImages).menuPath)
        let conflicting = [
            Self.cart + "\nTotal $13.06",
            Self.cart + "\nTotal $14.06"
        ]
        XCTAssertNil(Evidence.currentOrderTotalCents(imageEvidenceTexts: conflicting))
        XCTAssertNil(Evidence.resolveMenuPath(imageEvidenceTexts: conflicting).menuPath)
    }

    func testDollarCartCannotInferPastUnresolvedMNotationInAnotherEligibleImage() {
        let totalCart = Self.cart + "\nTotal $13.06"
        for notation in ["6M", "0M", "Total 2M\nTotal 3M"] {
            XCTAssertEqual(
                Evidence.resolveMenuPath(imageEvidenceTexts: [totalCart, Self.cart + "\n" + notation]),
                .noEvidence,
                notation
            )
        }
        XCTAssertEqual(
            Evidence.resolveMenuPath(imageEvidenceTexts: [totalCart, Self.cart + "\nTotal 1M"]),
            .init(menuPath: nil, conflict: true)
        )
    }

    func testExternalOrderTotalSurvivesOnlyExactIndependentOCRCorroboration() {
        let text = review(
            "Your order", "1 Coffee", "Total $4.30",
            "Your payment", "Payment method: Dining Dollars"
        )
        let returned = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                menuPath: .diningDollars,
                diningDollarsOrderTotalCents: 430
            )
        )
        let valid = RequesterOrderExternalOutcomeValidator.validate(
            returned, evidenceText: text, allowsDiningDollarsEstimate: false
        )
        XCTAssertEqual(valid.proposal.menuPath, .diningDollars)
        XCTAssertEqual(valid.proposal.diningDollarsOrderTotalCents, 430)
        let mismatched = RequesterOrderExternalOutcomeValidator.validate(
            returned,
            evidenceText: text.replacingOccurrences(of: "$4.30", with: "$4.50"),
            allowsDiningDollarsEstimate: false
        )
        XCTAssertEqual(mismatched.proposal.menuPath, .diningDollars)
        XCTAssertNil(mismatched.proposal.diningDollarsOrderTotalCents)
    }

    // MARK: - Conflicts and multiple images

    func testAcceptedEvidenceForBothPathsFailsClosed() {
        let conflict = RequesterOrderDeterministicEvidence.MenuPathResolution(menuPath: nil, conflict: true)
        XCTAssertEqual(
            resolve(review("Your order", "1 Chicken Bowl", "3M + $2.00", "Your payment", "Payment method", "Dining Dollars")),
            conflict
        )
        XCTAssertEqual(
            resolve(review("Crave NYU - Meal Exchange", "Your payment", "Payment method", "Dining Dollars")),
            conflict
        )
        XCTAssertEqual(
            resolve(review("Your payment", "Payment method", "Dining Dollars"), Self.cart + "\nBowl 1M"),
            conflict,
            "conflict is judged across the whole logical selection"
        )
    }

    func testPathEvidenceIsAttributedPerEligibleScreenshot() {
        let dining = review("Your payment", "Payment method", "Dining Dollars")
        XCTAssertEqual(resolve(dining, review("Your order", "1 Chicken Bowl", "Your payment", "Payment method", "Dining Dollars", delivery: true)).menuPath, .diningDollars)
        XCTAssertEqual(
            resolve(dining, review("Your payment", "Payment method", "Visa ending 1234")),
            .noEvidence,
            "a second checkout screenshot with another method keeps the path unproposed"
        )
        let browse = "Menu browse popular items reviews rating\n" + Self.diningRow.joined(separator: "\n")
        XCTAssertEqual(resolve(Self.cart + "\nBowl 1M", browse).menuPath, .mealExchange)
        XCTAssertEqual(resolve(browse), .noEvidence, "an ineligible screenshot contributes no evidence")
        XCTAssertEqual(resolve(Self.cart + "\nJasper Kane Cafe", Self.cart + "\nCafe 370"), .noEvidence)
        XCTAssertEqual(Evidence.resolveMenuPath(imageEvidenceTexts: []), .noEvidence)
    }

    func testConflictOmitsThePathAndBranchDependentValuesButKeepsTheSharedLocation() {
        let text = review("Your order", "1 Chicken Bowl", "Jasper Kane Cafe", "3M + $2.00", "Your payment", "Payment method", "Dining Dollars")
        let raw = RequesterOrderRawOutput(
            visibleVenueText: "Jasper Kane Cafe",
            foodItems: [.init(name: "Chicken Bowl", quantity: 1, modifiers: [])],
            mealSwipes: 3
        )
        guard case .valid(let proposal) = RequesterOrderOutputValidator.validate(
            raw: raw.jsonObject, evidenceText: text, evidenceImageCount: 1, allowsDiningDollarsEstimate: true
        ) else { return XCTFail("expected a valid proposal") }

        XCTAssertNil(proposal.menuPath)
        XCTAssertNil(proposal.mealItems)
        XCTAssertNil(proposal.mealSwipes)
        XCTAssertNil(proposal.estimatedDiningDollarsCents)
        XCTAssertEqual(proposal.selectedDiningSpot?.name, "Jasper Kane Cafe")
    }

    // MARK: - Provider boundary

    func testProviderSuppliedMenuPathIsRejectedAndNeverNeededForTheDeterministicPath() {
        let dining = review("Your payment", "Payment method", "Dining Dollars")
        for value: Any in ["dining-dollars", "meal-exchange", "MEAL_EXCHANGE", NSNull()] {
            var raw = RequesterOrderRawOutput(visibleVenueText: nil, foodItems: [], mealSwipes: nil).jsonObject
            raw["menuPath"] = value
            XCTAssertEqual(
                RequesterOrderOutputValidator.validate(raw: raw, evidenceText: dining, evidenceImageCount: 1, allowsDiningDollarsEstimate: true),
                .invalid(.forbiddenFields)
            )
        }
        let clean = RequesterOrderRawOutput(visibleVenueText: nil, foodItems: [], mealSwipes: nil).jsonObject
        guard case .valid(let proposal) = RequesterOrderOutputValidator.validate(
            raw: clean, evidenceText: dining, evidenceImageCount: 1, allowsDiningDollarsEstimate: true
        ) else { return XCTFail("expected a valid proposal") }
        XCTAssertEqual(proposal.menuPath, .diningDollars)
    }

    func testPathIsIndependentOfTheAmountStrategyPolicy() {
        let raw = RequesterOrderRawOutput(
            visibleVenueText: nil,
            foodItems: [.init(name: "Bowl", quantity: nil, modifiers: [])],
            mealSwipes: 3
        ).jsonObject
        guard case .valid(let restricted) = RequesterOrderOutputValidator.validate(
            raw: raw,
            evidenceText: "Your pickup order\n3M + $2.00",
            evidenceImageCount: 1,
            allowsDiningDollarsEstimate: RequesterOrderPolicy.permitsDiningDollarsEstimate(for: .ocrFlattenedText)
        ) else { return XCTFail("expected a valid proposal") }
        // The amount stays withheld for an OCR-consuming strategy; the path is
        // derived from the evidence alone, not from anything that strategy's
        // provider claimed.
        XCTAssertNil(restricted.estimatedDiningDollarsCents)
        XCTAssertEqual(restricted.menuPath, .mealExchange)
        XCTAssertEqual(restricted.mealSwipes, 3)
    }

    // MARK: - External-result re-validation

    private func externalOutcome(_ proposal: ScreenshotProposal) -> ScreenshotProposalOutcome {
        ScreenshotProposalOutcome(eligible: true, proposal: proposal)
    }

    func testExternalPathSurvivesOnlyWhenOnDeviceEvidenceEstablishesExactlyThatPath() {
        let dining = review("Your payment", "Payment method", "Dining Dollars")
        let matching = RequesterOrderExternalOutcomeValidator.validate(
            externalOutcome(ScreenshotProposal(menuPath: .diningDollars)),
            evidenceText: dining,
            allowsDiningDollarsEstimate: true
        )
        XCTAssertEqual(matching.proposal.menuPath, .diningDollars)

        let opposite = RequesterOrderExternalOutcomeValidator.validate(
            externalOutcome(ScreenshotProposal(menuPath: .mealExchange)),
            evidenceText: dining,
            allowsDiningDollarsEstimate: true
        )
        XCTAssertNil(opposite.proposal.menuPath)

        let unsupported = RequesterOrderExternalOutcomeValidator.validate(
            externalOutcome(ScreenshotProposal(menuPath: .diningDollars)),
            evidenceText: Self.cart + "\nJasper Kane Cafe",
            allowsDiningDollarsEstimate: true
        )
        XCTAssertNil(unsupported.proposal.menuPath, "a returned path is not evidence")
        XCTAssertTrue(unsupported.isEmpty)
    }

    func testExternalConflictDropsPathAndBranchDependentValues() {
        let text = review("Your order", "1 Chicken Bowl", "Jasper Kane Cafe", "3M + $2.00", "Your payment", "Payment method", "Dining Dollars")
        let palladium = SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" }!
        let validated = RequesterOrderExternalOutcomeValidator.validate(
            externalOutcome(ScreenshotProposal(
                menuPath: .mealExchange,
                selectedDiningSpot: palladium,
                mealItems: [MealItem(name: "1 Chicken Bowl")],
                mealSwipes: 3,
                estimatedDiningDollarsCents: 200
            )),
            evidenceText: text,
            imageEvidenceTexts: [text],
            allowsDiningDollarsEstimate: true
        )
        XCTAssertEqual(validated.proposal, ScreenshotProposal(selectedDiningSpot: palladium))
    }

    func testExternalMealExchangeKeepsTheExistingIndependentAmountRuleForCurrentCartEvidence() {
        let text = Self.cart + "\n1 Chicken Bowl\n3M + $2.00"
        let validated = RequesterOrderExternalOutcomeValidator.validate(
            externalOutcome(ScreenshotProposal(
                menuPath: .mealExchange,
                mealItems: [MealItem(name: "1 Chicken Bowl")],
                mealSwipes: 3,
                estimatedDiningDollarsCents: 200
            )),
            evidenceText: text,
            allowsDiningDollarsEstimate: true
        )
        XCTAssertEqual(validated.proposal.menuPath, .mealExchange)
        XCTAssertEqual(validated.proposal.mealSwipes, 3)
        XCTAssertEqual(validated.proposal.estimatedDiningDollarsCents, 200)
    }

    func testExternalCheckoutReviewEvidenceKeepsPathAndSwipesButNeverTheAmount() {
        let text = review("Your order", "1 Chicken Bowl", "3M + $2.00")
        let validated = RequesterOrderExternalOutcomeValidator.validate(
            externalOutcome(ScreenshotProposal(
                menuPath: .mealExchange,
                mealItems: [MealItem(name: "1 Chicken Bowl")],
                mealSwipes: 3,
                estimatedDiningDollarsCents: 200
            )),
            evidenceText: text,
            allowsDiningDollarsEstimate: true
        )
        XCTAssertEqual(validated.proposal.menuPath, .mealExchange)
        XCTAssertEqual(validated.proposal.mealSwipes, 3)
        XCTAssertNil(validated.proposal.estimatedDiningDollarsCents)
    }
}
