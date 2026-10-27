//
//  ScreenshotReviewSectionBoundaryTests.swift
//  CommonPlateiosTests
//
// W4-R4.1 canonical matrix: the authorized review-heading set and the bounded
// `Your payment` / `Your order` sections. Mirrors the backend suite in
// `src/screenshotEligibility.test.ts`; the shared conformance vectors remain the
// parity guard. All evidence is synthetic.
import Foundation
import XCTest
@testable import CommonPlateios

final class ScreenshotReviewSectionBoundaryTests: XCTestCase {
    private typealias Evidence = RequesterOrderDeterministicEvidence

    private static let heading = "Review your pickup order"
    private static let checkout = RequesterOrderEligibilityResult(eligible: true, category: .checkout)
    private static let ineligible = RequesterOrderEligibilityResult(eligible: false, category: nil)

    private func lines(_ parts: String...) -> String { parts.joined(separator: "\n") }

    private func path(_ text: String) -> Evidence.MenuPathResolution {
        Evidence.resolveMenuPath(imageEvidenceTexts: [text])
    }

    private func assertNoPath(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(path(text), .noEvidence, text, file: file, line: line)
    }

    func testGenericReviewYourOrderHeadingIsNotAuthorized() {
        for text in [
            lines("Review your order", "Your order", "1 Chicken Bowl", "Your payment", "Payment method", "Dining Dollars"),
            lines("Review your", "order", "Your payment", "Payment method", "Dining Dollars"),
        ] {
            XCTAssertEqual(Evidence.evaluateEligibility(text), Self.ineligible, text)
            assertNoPath(text)
        }
    }

    func testAuthorizedHeadingsIncludingWordBoundarySplitsRemainSupported() {
        for heading in [
            "Review your pickup order",
            "Review your delivery order",
            "Review your\npickup order",
            "Review\nyour\ndelivery order",
        ] {
            let text = lines(heading, "Your payment", "Payment method", "Dining Dollars")
            XCTAssertEqual(Evidence.evaluateEligibility(text), Self.checkout, text)
        }
    }

    func testPaymentAttributionEndsAtEveryRecognizedLaterSection() {
        let boundaries = [
            "Receipt", "Order confirmation", "Order\nconfirmation", "Order information",
            "Review your order",
            "View order", "Your order\n1 Chicken Bowl", "Place your pickup order",
        ]
        for boundary in boundaries {
            let text = lines(Self.heading, "Your order", "1 Chicken Bowl", "Your payment", boundary,
                             "Payment method", "Dining Dollars")
            assertNoPath(text)
            XCTAssertNil(Evidence.currentOrderTotalCents(imageEvidenceTexts: [text + "\nTotal $4.30"]), boundary)
        }
        let orphan = lines(Self.heading, "Your payment", "Receipt", "Payment method", "Dining Dollars")
        XCTAssertEqual(Evidence.evaluateEligibility(orphan), Self.ineligible)
        assertNoPath(orphan)
    }

    func testLaterRowInsideTheSamePaymentSectionStaysAttributableWithoutALineCutoff() {
        let filler = (0..<40).map { "Detail \($0)" }.joined(separator: "\n")
        for text in [
            lines(Self.heading, "Your payment", "Apply a promo code", "Payment method", "Dining Dollars"),
            lines(Self.heading, "Your payment", "Payment method", "Dining Dollars", "Apply a promo code"),
            lines(Self.heading, "Your payment", filler, "Payment method", "Dining Dollars"),
        ] {
            XCTAssertEqual(Evidence.evaluateEligibility(text), Self.checkout)
            XCTAssertEqual(path(text), Evidence.MenuPathResolution(menuPath: .diningDollars, conflict: false))
        }
    }

    func testDuplicateSectionsDuplicateRowsAndValuelessRowsFailClosed() {
        for text in [
            lines(Self.heading, "Your payment", "Payment method", "Dining Dollars",
                  "Your payment", "Payment method", "Dining Dollars"),
            lines(Self.heading, "Your payment", "Payment method", "Dining Dollars", "Payment method", "Dining Dollars"),
            lines(Self.heading, "Your order", "1 Chicken Bowl", "Your payment", "Payment method"),
            lines(Self.heading, "Your order", "1 Chicken Bowl", "Your payment", "Payment method", "Apply a promo code"),
        ] {
            assertNoPath(text)
        }
    }

    func testYourOrderScanStopsAtTheFirstLaterPaymentHeading() {
        for text in [
            lines(Self.heading, "Your order", "Your payment", "1 Chicken Bowl"),
            lines(Self.heading, "Your order", "Your payment", "1 Chicken Bowl", "Your payment"),
            lines(Self.heading, "Your order", "Your payment", "Payment method", "Your payment", "1 Chicken Bowl"),
        ] {
            XCTAssertEqual(Evidence.evaluateEligibility(text), Self.ineligible, text)
        }
    }

    func testItemInsideYourOrderStaysEligibleDespiteAMalformedLaterPaymentSection() {
        for tail in [
            lines("Your payment", "Your payment"),
            lines("Your payment", "Payment method", "Your payment"),
        ] {
            let text = lines(Self.heading, "Your order", "1 Chicken Bowl", tail)
            XCTAssertEqual(Evidence.evaluateEligibility(text), Self.checkout, text)
        }
    }

    func testReviewOutranksCartChromeAndChromeAloneStaysCart() {
        let chrome = lines("Your pickup order", "Continue to checkout", "Order instructions")
        XCTAssertEqual(
            Evidence.evaluateEligibility(lines(chrome, Self.heading, "Your payment", "Payment method", "Dining Dollars")),
            Self.checkout
        )
        XCTAssertEqual(
            Evidence.evaluateEligibility(lines(chrome, "Payment method", "Dining Dollars")),
            RequesterOrderEligibilityResult(eligible: true, category: .cart)
        )
    }

    func testRealReviewLayoutResolvesDiningDollarsAndTheLabeledTotalIsTheOnlyAmount() {
        let text = lines(Self.heading, "Your payment", "Payment method", "Dining Dollars", "Apply a promo code",
                         "Your order", "1 Coffee", "Subtotal $4.00", "Total $4.30")
        XCTAssertEqual(path(text), Evidence.MenuPathResolution(menuPath: .diningDollars, conflict: false))
        XCTAssertEqual(Evidence.currentOrderTotalCents(imageEvidenceTexts: [text]), 430)
        let noTotal = lines(Self.heading, "Your payment", "Payment method", "Dining Dollars", "Your order", "1 Coffee")
        XCTAssertNil(Evidence.currentOrderTotalCents(imageEvidenceTexts: [noTotal]))
    }

    func testMealBasedPaymentWordingIsNeverDiningDollars() {
        for text in [
            lines(Self.heading, "Your payment", "Payment method", "Use 1 Meal + Dining Dollars", "Your order", "1 Coffee"),
            lines(Self.heading, "Your payment", "Payment method Use 1 Meal + Dining Dollars", "Your order", "1 Coffee"),
            lines(Self.heading, "Dunkin' at U-Hall - Meal Exchange", "Your payment", "Payment method",
                  "Use 1 Meal + Dining Dollars", "Your order", "1 Coffee", "Total 1M"),
        ] {
            XCTAssertEqual(path(text), Evidence.MenuPathResolution(menuPath: .mealExchange, conflict: false), text)
        }
    }

    func testDollarCartWithoutALabeledTotalDerivesNoPathFromPriceNoise() {
        let text = lines("Your Pickup Order", "Continue to Checkout", "Starbucks", "1 Latte $5.00",
                         "Subtotal $5.00", "Tax $0.44")
        assertNoPath(text)
        XCTAssertNil(Evidence.currentOrderTotalCents(imageEvidenceTexts: [text]))
    }
}

/// Structural departures are boundary-only: decorated forms end `Your payment`
/// and `Your order` attribution, and never grant positive authority.
final class ScreenshotStructuralDepartureTests: XCTestCase {
    private typealias Evidence = RequesterOrderDeterministicEvidence

    private static let heading = "Review your pickup order"
    private static let checkout = RequesterOrderEligibilityResult(eligible: true, category: .checkout)
    private static let ineligible = RequesterOrderEligibilityResult(eligible: false, category: nil)
    private static let departures = [
        "Receipt \u{203A}", "Receipt >", "Order confirmation: 123", "Order confirmation #A1-23",
        "Place your pickup order \u{203A}", "Place your delivery order $4.30", "Order history",
        "Past order", "Past orders", "Order information \u{203A}", "View order \u{203A}",
        "Your order \u{203A}", "Review your delivery order \u{203A}",
    ]

    private func lines(_ parts: String...) -> String { parts.joined(separator: "\n") }
    private func path(_ text: String) -> Evidence.MenuPathResolution {
        Evidence.resolveMenuPath(imageEvidenceTexts: [text])
    }

    func testDecoratedDeparturesEndPaymentAttribution() {
        for departure in Self.departures {
            let text = lines(Self.heading, "Your order", "1 Chicken Bowl", "Your payment", departure,
                             "Payment method", "Dining Dollars")
            XCTAssertEqual(path(text), .noEvidence, departure)
            XCTAssertNil(Evidence.currentOrderTotalCents(imageEvidenceTexts: [text + "\nTotal $4.30"]), departure)
        }
    }

    func testDeparturesEndTheYourOrderItemScan() {
        for departure in Self.departures where departure != "Your order \u{203A}" {
            XCTAssertEqual(
                Evidence.evaluateEligibility(lines(Self.heading, "Your order", departure, "1 Chicken Bowl")),
                Self.ineligible, departure)
            XCTAssertEqual(
                Evidence.evaluateEligibility(lines(Self.heading, "Your order", "1 Chicken Bowl", departure, "1 Pasta Bowl")),
                Self.checkout, departure)
        }
        XCTAssertEqual(
            Evidence.evaluateEligibility(lines(Self.heading, "Your order", "Your payment \u{203A}", "1 Chicken Bowl")),
            Self.ineligible)
        XCTAssertEqual(
            Evidence.evaluateEligibility(
                lines(Self.heading, "Your order", "1 Chicken Bowl", "Your payment \u{203A}", "Your payment")),
            Self.checkout)
    }

    func testDecoratedDuplicatePaymentHeadingFailsClosed() {
        XCTAssertEqual(
            path(lines(Self.heading, "Your payment", "Payment method", "Dining Dollars", "Your payment \u{203A}")),
            .noEvidence)
    }

    func testDeparturesGrantNoPositiveAuthority() {
        XCTAssertEqual(
            Evidence.evaluateEligibility(Self.heading + "\n" + Self.departures.joined(separator: "\n")),
            Self.ineligible)
        XCTAssertEqual(
            Evidence.evaluateEligibility(lines(Self.heading, "Your payment \u{203A}", "Payment method", "Dining Dollars")),
            Self.ineligible)
        XCTAssertEqual(
            Evidence.evaluateEligibility(lines(Self.heading, "Your order \u{203A}", "1 Chicken Bowl")),
            Self.ineligible)
        for departure in Self.departures {
            XCTAssertEqual(path(lines(departure, "Payment method", "Dining Dollars")), .noEvidence, departure)
        }
    }

    func testLookalikesWithoutADelimiterAreNotDepartures() {
        for lookalike in ["Receipts", "Receipt of purchase", "Order confirmations", "View order details", "Order historyx"] {
            let text = lines(Self.heading, "Your payment", lookalike, "Payment method", "Dining Dollars")
            XCTAssertEqual(path(text), Evidence.MenuPathResolution(menuPath: .diningDollars, conflict: false), lookalike)
        }
    }

    func testNoLineCountCutoffAppliesToEitherSection() {
        let filler = (0..<200).map { "Detail \($0)" }.joined(separator: "\n")
        XCTAssertEqual(
            Evidence.evaluateEligibility(lines(Self.heading, "Your order", filler, "1 Chicken Bowl")), Self.checkout)
        XCTAssertEqual(
            path(lines(Self.heading, "Your payment", filler, "Payment method", "Dining Dollars")),
            Evidence.MenuPathResolution(menuPath: .diningDollars, conflict: false))
    }

    func testPromoControlsStayInsideThePaymentSection() {
        for promo in ["Apply a promo code", "Apply a promo code \u{203A}"] {
            let text = lines(Self.heading, "Your payment", promo, "Payment method", "Dining Dollars", promo,
                             "Your order", "1 Coffee", "Total $4.30")
            XCTAssertEqual(path(text), Evidence.MenuPathResolution(menuPath: .diningDollars, conflict: false), promo)
            XCTAssertEqual(Evidence.currentOrderTotalCents(imageEvidenceTexts: [text]), 430, promo)
        }
    }
}
