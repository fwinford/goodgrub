//
//  ScreenshotCheckoutAmountAuthorityTests.swift
//  CommonPlateiosTests
//
// W4-R4.1 review fix: checkout/review eligibility is a bounded new
// supported-input category and grants no new extraction authority. The
// checkout heading, its `Your order` section title, and its own `3M + $2.00`
// may establish the Meal Exchange path, but never the pre-existing
// current-cart/order-level Dining Dollars amount. All evidence is synthetic;
// the shared conformance vectors are the backend parity guard.
import Foundation
import XCTest
@testable import CommonPlateios

final class ScreenshotCheckoutAmountAuthorityTests: XCTestCase {
    private typealias Evidence = RequesterOrderDeterministicEvidence

    private static let cartWithAmount = "Your pickup order\nItems subtotal\n3M + $2.00"
    private static let cartWithoutAmount = "Your pickup order\nItems subtotal\nContinue to checkout"

    private func review(_ lines: String..., delivery: Bool = false) -> String {
        ([delivery ? "Review your delivery order" : "Review your pickup order"] + lines)
            .joined(separator: "\n")
    }

    private let rawBowl = RequesterOrderRawOutput(
        visibleVenueText: nil,
        foodItems: [.init(name: "Chicken Bowl", quantity: 1, modifiers: [])],
        mealSwipes: 3
    )

    private func proposal(
        evidence: String,
        images: [String]? = nil,
        allowsAmount: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ScreenshotProposal {
        let result = RequesterOrderOutputValidator.validate(
            raw: rawBowl.jsonObject,
            evidenceText: evidence,
            evidenceImageCount: images?.count ?? 1,
            imageEvidenceTexts: images,
            allowsDiningDollarsEstimate: allowsAmount
        )
        guard case .valid(let proposal) = result else {
            XCTFail("expected a valid proposal", file: file, line: line)
            return ScreenshotProposal()
        }
        return proposal
    }

    // MARK: - Evidence selection

    func testAmountAuthorityExcludesCheckoutReviewScreenshotsAndKeepsEveryOtherTextUnchanged() {
        let checkout = review("Your order", "1 Chicken Bowl", "3M + $2.00")
        let historical = "View order\nOrder information\n1 Create Your Own Bowl"
        XCTAssertEqual(Evidence.evaluateEligibility(checkout).category, .checkout)
        XCTAssertEqual(Evidence.evaluateEligibility(Self.cartWithAmount).category, .cart)
        XCTAssertEqual(Evidence.evaluateEligibility(historical).category, .historical)

        XCTAssertEqual(
            Evidence.amountAuthorityEvidenceText(imageEvidenceTexts: [Self.cartWithAmount, checkout, historical]),
            [Self.cartWithAmount, historical].joined(separator: "\n")
        )
        XCTAssertEqual(
            Evidence.amountAuthorityEvidenceText(imageEvidenceTexts: [Self.cartWithAmount, historical]),
            [Self.cartWithAmount, historical].joined(separator: "\n"),
            "no checkout/review screenshot: the combined evidence, joined the same way"
        )
        XCTAssertEqual(Evidence.amountAuthorityEvidenceText(imageEvidenceTexts: [checkout, checkout]), "")
        XCTAssertEqual(Evidence.amountAuthorityEvidenceText(imageEvidenceTexts: []), "")
    }

    // MARK: - Checkout/review grants no amount

    func testCheckoutReviewThreeMPlusDollarsProposesTheMealExchangePathButNoAmount() {
        for delivery in [false, true] {
            let text = review("Your order", "1 Chicken Bowl", "3M + $2.00", delivery: delivery)
            let result = proposal(evidence: text)
            XCTAssertEqual(result.menuPath, .mealExchange, text)
            XCTAssertEqual(result.mealSwipes, 3, text)
            XCTAssertNil(result.estimatedDiningDollarsCents, text)
        }
    }

    func testCheckoutChromeNeverStandsInForACurrentCartMarker() {
        let text = review("Checkout", "Your order", "1 Chicken Bowl", "3M + $2.00", "Place your pickup order")
        let result = proposal(evidence: text)
        XCTAssertEqual(result.menuPath, .mealExchange)
        XCTAssertNil(result.estimatedDiningDollarsCents)
    }

    func testExistingCurrentCartAmountIsUnchangedForCartEvidence() {
        let result = proposal(evidence: "Your pickup order\n1 Chicken Bowl\n3M + $2.00")
        XCTAssertEqual(result.menuPath, .mealExchange)
        XCTAssertEqual(result.mealSwipes, 3)
        XCTAssertEqual(result.estimatedDiningDollarsCents, 200)
        XCTAssertNil(
            proposal(evidence: "Your pickup order\n1 Chicken Bowl\n3M + $2.00", allowsAmount: false)
                .estimatedDiningDollarsCents,
            "the OCR-consuming strategy policy still withholds the amount"
        )
    }

    // MARK: - Mixed per-screenshot selection

    func testACartScreenshotsAmountSurvivesBesideACheckoutScreenshot() {
        let images = [Self.cartWithAmount, review("Your order", "1 Chicken Bowl")]
        let result = proposal(evidence: images.joined(separator: "\n"), images: images)
        XCTAssertEqual(result.menuPath, .mealExchange)
        XCTAssertEqual(result.estimatedDiningDollarsCents, 200)
    }

    func testACartMarkerFromAnotherScreenshotNeverCarriesACheckoutScreenshotsAmount() {
        let images = [Self.cartWithoutAmount, review("Your order", "1 Chicken Bowl", "3M + $2.00")]
        let result = proposal(evidence: images.joined(separator: "\n"), images: images)
        XCTAssertEqual(result.menuPath, .mealExchange)
        XCTAssertEqual(result.mealSwipes, 3)
        XCTAssertNil(result.estimatedDiningDollarsCents)
    }
}
