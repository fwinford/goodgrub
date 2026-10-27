import CoreGraphics
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotTotalGeometryDerivationTests: XCTestCase {
    private typealias Raw = ScreenshotLocalTextRecognizer.Observation

    private let totalBox = CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.10)
    private let amountBox = CGRect(x: 0.40, y: 0.51, width: 0.20, height: 0.08)

    private func derived(
        totalBox: CGRect?,
        amounts: [(String, CGRect?)]
    ) -> ScreenshotRecognizedText {
        ScreenshotLocalTextRecognizer.derive(from: [
            Raw(text: "Your Pickup Order", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.05)),
            Raw(text: "Continue to Checkout", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)),
            Raw(text: "Total", boundingBox: totalBox),
            Raw(text: "Order actions", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.05)),
        ] + amounts.map { Raw(text: $0.0, boundingBox: $0.1) })
    }

    private func qualifying(_ result: ScreenshotRecognizedText) -> [ScreenshotTotalGeometryEvidence.Relation] {
        result.totalGeometryEvidence?.relations.filter { $0.sameRow && $0.rightOf } ?? []
    }

    private func sameRow(totalBox: CGRect, amountBox: CGRect) -> Bool {
        derived(totalBox: totalBox, amounts: [("$15.45", amountBox)])
            .totalGeometryEvidence?.relations.first?.sameRow ?? false
    }

    func testP1OneTotalAndOneSameRowRightSideAmountDeriveOneAssociation() throws {
        let result = derived(totalBox: totalBox, amounts: [("$15.45", amountBox)])
        let evidence = try XCTUnwrap(result.totalGeometryEvidence)
        XCTAssertEqual(qualifying(result).count, 1)
        XCTAssertEqual(evidence.observations.last?.cents, 1_545)
        XCTAssertEqual(
            RequesterOrderDeterministicEvidence.currentOrderTotalCents(
                imageEvidenceTexts: [result.text],
                imageTotalGeometryEvidence: [evidence]
            ),
            1_545
        )
        XCTAssertEqual(
            RequesterOrderDeterministicEvidence.resolveMenuPath(
                imageEvidenceTexts: [result.text],
                imageTotalGeometryEvidence: [evidence]
            ),
            .init(menuPath: .diningDollars, conflict: false)
        )
        let raw: [String: Any] = [
            "visibleVenueText": NSNull(), "foodItems": [Any](), "mealSwipes": NSNull(),
        ]
        XCTAssertEqual(
            RequesterOrderOutputValidator.validate(
                raw: raw,
                evidenceText: result.text,
                evidenceImageCount: 1,
                imageEvidenceTexts: [result.text],
                imageTotalGeometryEvidence: [evidence],
                allowsDiningDollarsEstimate: true
            ),
            .valid(ScreenshotProposal(
                menuPath: .diningDollars,
                diningDollarsOrderTotalCents: 1_545
            ))
        )
    }

    func testN1ZeroQualifyingAmountsDerivesNone() {
        let result = derived(
            totalBox: totalBox,
            amounts: [("$15.45", CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.08))]
        )
        XCTAssertTrue(qualifying(result).isEmpty)
    }

    func testN2TwoQualifyingAmountsRemainAmbiguous() throws {
        let result = derived(totalBox: totalBox, amounts: [
            ("$15.45", amountBox),
            ("$9.00", CGRect(x: 0.65, y: 0.51, width: 0.15, height: 0.08)),
        ])
        XCTAssertEqual(qualifying(result).count, 2)
        XCTAssertNil(RequesterOrderDeterministicEvidence.currentOrderTotalCents(
            imageEvidenceTexts: [result.text],
            imageTotalGeometryEvidence: [try XCTUnwrap(result.totalGeometryEvidence)]
        ))
    }

    func testN3MissingTotalGeometryFailsClosed() throws {
        let result = derived(totalBox: nil, amounts: [("$15.45", amountBox)])
        let evidence = try XCTUnwrap(result.totalGeometryEvidence)
        XCTAssertEqual(evidence.observations.first { $0.classification == .totalLabel }?.geometryValid, false)
        XCTAssertTrue(qualifying(result).isEmpty)
        XCTAssertNil(RequesterOrderDeterministicEvidence.currentOrderTotalCents(
            imageEvidenceTexts: [result.text], imageTotalGeometryEvidence: [evidence]
        ))
    }

    func testN4MissingRelevantAmountGeometryFailsClosedEvenWhenAnotherAmountQualifies() throws {
        let result = derived(totalBox: totalBox, amounts: [("$15.45", amountBox), ("$9.00", nil)])
        let evidence = try XCTUnwrap(result.totalGeometryEvidence)
        XCTAssertEqual(qualifying(result).count, 1)
        XCTAssertNil(RequesterOrderDeterministicEvidence.currentOrderTotalCents(
            imageEvidenceTexts: [result.text], imageTotalGeometryEvidence: [evidence]
        ))
    }

    func testN5SameRowAmountLeftOfTotalDoesNotQualify() {
        let left = CGRect(x: 0.0, y: 0.51, width: 0.08, height: 0.08)
        XCTAssertTrue(qualifying(derived(totalBox: totalBox, amounts: [("$15.45", left)])).isEmpty)
    }

    func testN6RightSideAmountOutsideSameRowDoesNotQualify() {
        let otherRow = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.08)
        XCTAssertTrue(qualifying(derived(totalBox: totalBox, amounts: [("$15.45", otherRow)])).isEmpty)
    }

    func testSameRowAcceptsExactFiftyPercentOverlap() {
        let box = CGRect(x: 0.1, y: 0, width: 0.2, height: 0.5)
        let exactlyHalf = CGRect(x: 0.4, y: 0.25, width: 0.2, height: 0.5)
        XCTAssertTrue(sameRow(totalBox: box, amountBox: exactlyHalf))
    }

    func testSameRowScaleRelativeToleranceAcceptsSixteenThresholdULPsBelowBoundary() {
        let height: CGFloat = 0.5
        let threshold = height * 0.5
        let permittedOverlap = threshold - threshold.ulp * 16
        let box = CGRect(x: 0.1, y: 0, width: 0.2, height: height)
        let amount = CGRect(
            x: 0.4,
            y: height - permittedOverlap,
            width: 0.2,
            height: height
        )
        XCTAssertTrue(sameRow(totalBox: box, amountBox: amount))
    }

    func testSameRowScaleRelativeToleranceRejectsSeventeenThresholdULPsBelowBoundary() {
        let height: CGFloat = 0.5
        let threshold = height * 0.5
        let outsideOverlap = threshold - threshold.ulp * 17
        let box = CGRect(x: 0.1, y: 0, width: 0.2, height: height)
        let amount = CGRect(
            x: 0.4,
            y: height - outsideOverlap,
            width: 0.2,
            height: height
        )
        XCTAssertFalse(sameRow(totalBox: box, amountBox: amount))
    }

    func testSameRowRejectsZeroOverlapForSeparatedAndEdgeTouchingBoxes() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let edgeTouching = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.1)
        let separated = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.1)
        XCTAssertFalse(sameRow(totalBox: box, amountBox: edgeTouching))
        XCTAssertFalse(sameRow(totalBox: box, amountBox: separated))
    }

    func testSameRowRejectsTinyPositiveEdgeTouchingBoxes() {
        let height: CGFloat = 1e-16
        let box = CGRect(x: 0.1, y: 0, width: 0.2, height: height)
        let edgeTouching = CGRect(x: 0.4, y: height, width: 0.2, height: height)
        XCTAssertFalse(sameRow(totalBox: box, amountBox: edgeTouching))
    }

    func testSameRowAcceptsTinyPositiveBoxesWithGenuineMajorityOverlap() {
        let height: CGFloat = 1e-16
        let box = CGRect(x: 0.1, y: 0, width: 0.2, height: height)
        let overlapping = CGRect(x: 0.4, y: 4e-17, width: 0.2, height: height)
        XCTAssertTrue(sameRow(totalBox: box, amountBox: overlapping))
    }

    func testSameRowRejectsOrdinaryOverlapBelowFiftyPercent() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let belowHalf = CGRect(x: 0.4, y: 0.2001, width: 0.2, height: 0.2)
        XCTAssertFalse(sameRow(totalBox: box, amountBox: belowHalf))
    }

    func testN7MultipleTotalsCannotBecomeAuthoritative() throws {
        let result = ScreenshotLocalTextRecognizer.derive(from: [
            Raw(text: "Your Pickup Order", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.05)),
            Raw(text: "Continue to Checkout", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)),
            Raw(text: "Total", boundingBox: totalBox),
            Raw(text: "Total", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1)),
            Raw(text: "$15.45", boundingBox: amountBox),
        ])
        XCTAssertNil(RequesterOrderDeterministicEvidence.currentOrderTotalCents(
            imageEvidenceTexts: [result.text],
            imageTotalGeometryEvidence: [try XCTUnwrap(result.totalGeometryEvidence)]
        ))
    }

    func testN8EachDerivationIsImageLocalAndCannotCreateCrossImageEdges() throws {
        let label = derived(totalBox: totalBox, amounts: [])
        let amount = ScreenshotLocalTextRecognizer.derive(from: [
            Raw(text: "Your Pickup Order", boundingBox: totalBox),
            Raw(text: "Continue to Checkout", boundingBox: totalBox),
            Raw(text: "$15.45", boundingBox: amountBox),
        ])
        XCTAssertTrue(try XCTUnwrap(label.totalGeometryEvidence).relations.isEmpty)
        XCTAssertNil(amount.totalGeometryEvidence)
        XCTAssertNil(RequesterOrderDeterministicEvidence.currentOrderTotalCents(
            imageEvidenceTexts: [label.text, amount.text],
            imageTotalGeometryEvidence: [label.totalGeometryEvidence, amount.totalGeometryEvidence]
        ))
    }

    func testN9NonfiniteAndOutOfBoundsGeometryFailsClosed() throws {
        for invalid in [
            CGRect(x: .nan, y: 0.5, width: 0.2, height: 0.1),
            CGRect(x: -0.01, y: 0.5, width: 0.2, height: 0.1),
            CGRect(x: 0.9, y: 0.5, width: 0.2, height: 0.1),
            CGRect(x: 0.1, y: 0.5, width: 0, height: 0.1),
        ] {
            let result = derived(totalBox: totalBox, amounts: [("$15.45", invalid)])
            let evidence = try XCTUnwrap(result.totalGeometryEvidence)
            XCTAssertTrue(qualifying(result).isEmpty)
            XCTAssertNil(RequesterOrderDeterministicEvidence.currentOrderTotalCents(
                imageEvidenceTexts: [result.text], imageTotalGeometryEvidence: [evidence]
            ))
        }
    }
}
