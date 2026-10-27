// Privacy-safe synthetic proof of the bounded selected-payment relationship.
import XCTest
@testable import CommonPlateios

final class ScreenshotSelectedPaymentAttributionTests: XCTestCase {
    private typealias Evidence = RequesterOrderDeterministicEvidence
    private let payment = ["Your payment", "Payment method"]
    private let none = Evidence.MenuPathResolution.noEvidence
    private let dd = Evidence.MenuPathResolution(menuPath: .diningDollars, conflict: false)
    private let me = Evidence.MenuPathResolution(menuPath: .mealExchange, conflict: false)

    private func review(_ parts: [String]) -> String {
        (["Review your pickup order"] + parts).joined(separator: "\n")
    }

    private func path(_ text: String) -> Evidence.MenuPathResolution {
        Evidence.resolveMenuPath(imageEvidenceTexts: [text])
    }

    func testOneInertObservationAttributesEitherCanonicalTenderWithoutAmount() {
        let dining = review(payment + ["Payment detail", "Dining Dollars"])
        let meal = review(payment + ["Payment detail", "Use 1 Meal + Dining Dollars"])
        XCTAssertEqual(Evidence.evaluateEligibility(dining).category, .checkout)
        XCTAssertEqual(path(dining), dd)
        XCTAssertNil(Evidence.currentOrderTotalCents(imageEvidenceTexts: [dining]))
        XCTAssertEqual(path(meal), me)
        let withTotal = review(payment + ["Payment detail", "Dining Dollars", "Your order", "Total $4.30"])
        XCTAssertEqual(path(withTotal), dd)
        XCTAssertEqual(Evidence.currentOrderTotalCents(imageEvidenceTexts: [withTotal]), 430)
    }

    func testImmediateInlineAndPromoElsewhereRemainAttributable() {
        for text in [
            review(payment + ["Dining Dollars"]),
            review(["Your payment", "Payment method Dining Dollars"]),
            review(["Your payment", "Apply a promo code", "Payment method", "Payment detail",
                    "Dining Dollars", "Apply a promo code ›"]),
        ] {
            XCTAssertEqual(path(text), dd, text)
        }
    }

    func testTwoObservationsDeparturesDuplicatesAndPaymentSignalsFailClosed() {
        for text in [
            review(payment + ["Dining Dollars and Visa", "Dining Dollars"]),
            review(payment + ["Detail A", "Detail B", "Dining Dollars"]),
            review(payment + ["Detail A", "Detail B", "Use 1 Meal + Dining Dollars"]),
            review(["Your order", "1 Bowl"] + payment + ["Payment detail", "Receipt", "Dining Dollars"]),
            review(payment + ["Review your order", "Dining Dollars"]),
            review(["Your order", "1 Bowl"] + payment + ["Payment detail", "Dining Dollars", "Payment method"]),
            review(payment + ["Payment detail", "Dining Dollars", "Visa ending 1234"]),
            review(payment + ["Payment detail", "Dining Dollars", "Dining Dollars"]),
            review(payment + ["Dining Dollars", "Use 1 Meal + Dining Dollars"]),
            review(payment + ["Visa ending 1234", "Dining Dollars"]),
            review(payment + ["Split payment", "Dining Dollars"]),
            review(payment + ["Dining Dollars $4.30", "Dining Dollars"]),
            review(payment + ["Dining Dollars and Visa"]),
            review(payment + ["Payment detail"]),
        ] {
            XCTAssertEqual(path(text), none, text)
        }
    }

    func testUnsupportedAndHistoricalStructuresHaveNoCurrentPaymentAuthority() {
        XCTAssertEqual(path("Review your order\nYour payment\nPayment method\nPayment detail\nDining Dollars"), none)
        XCTAssertEqual(path("View order\nOrder information\nYour payment\nPayment method\nPayment detail\nDining Dollars"), none)
        XCTAssertEqual(path(review(["Your order", "1 Bowl"] + payment +
                                   ["Payment detail", "Order confirmation", "Dining Dollars"])), none)
    }
}
