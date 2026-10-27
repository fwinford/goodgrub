//
//  RequesterOrderPerImageEvidenceWiringTests.swift
//  CommonPlateiosTests
//
// W4-R4.1 review fix: pins the Requester workflow's call boundary. The
// workflow must hand each validator the per-screenshot OCR text
// (`evaluation.derived.orderedTexts(for:)`). Without it the validators fall
// back to one blob made of every screenshot's text, which lets structure
// stitch together across screenshots and lets one screenshot's category
// decide for all. These tests run the real workflow's `evaluate` and
// `validateLocal`/`validateExternal` over synthetic screenshots and fail if
// either call stops passing per-screenshot evidence.
import Foundation
import XCTest
@testable import CommonPlateios

final class RequesterOrderPerImageEvidenceWiringTests: XCTestCase {
    private let workflow = RequesterOrderWorkflow(recognizer: SyntheticTextRecognizer())

    private static let diningRow = ["Your payment", "Payment method", "Dining Dollars"]
    private static let cart = "Your Pickup Order\nContinue to Checkout"

    private func review(_ lines: String..., delivery: Bool = false) -> String {
        ([delivery ? "Review your delivery order" : "Review your pickup order"] + lines)
            .joined(separator: "\n")
    }

    private func evaluation(
        _ texts: [String]
    ) async throws -> ScreenshotWorkflowEvaluation<RequesterOrderEvidence> {
        let selection = try XCTUnwrap(
            ScreenshotSelection(images: ScreenshotTestEvidence.inputs(texts.count) { texts[$0 - 1] })
        )
        let admitted = await workflow.evaluate(selection)
        let evaluation = try XCTUnwrap(admitted, "every synthetic screenshot is eligible")
        XCTAssertEqual(evaluation.derived.orderedTexts(for: evaluation.selection), texts)
        return evaluation
    }

    private func local(
        _ raw: RequesterOrderRawOutput,
        _ evaluation: ScreenshotWorkflowEvaluation<RequesterOrderEvidence>,
        strategy: ScreenshotInputMode = .ocrFlattenedText,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ScreenshotProposal {
        guard case .valid(let outcome, _) = workflow.validateLocal(
            ScreenshotProviderResult(output: raw), evaluation: evaluation, strategy: strategy
        ) else {
            XCTFail("expected a valid local result", file: file, line: line)
            return ScreenshotProposal()
        }
        return outcome.proposal
    }

    private func external(
        _ proposal: ScreenshotProposal,
        _ evaluation: ScreenshotWorkflowEvaluation<RequesterOrderEvidence>,
        strategy: ScreenshotInputMode = .directImageMultimodal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ScreenshotProposal {
        guard case .valid(let outcome, _) = workflow.validateExternal(
            ScreenshotProviderResult(output: ScreenshotProposalOutcome(eligible: true, proposal: proposal)),
            evaluation: evaluation,
            strategy: strategy
        ) else {
            XCTFail("expected a valid external result", file: file, line: line)
            return ScreenshotProposal()
        }
        return outcome.proposal
    }

    private let emptyRaw = RequesterOrderRawOutput(visibleVenueText: nil, foodItems: [], mealSwipes: nil)
    private let bowlRaw = RequesterOrderRawOutput(
        visibleVenueText: nil,
        foodItems: [.init(name: "Chicken Bowl", quantity: 1, modifiers: [])],
        mealSwipes: 3
    )

    // MARK: - A path that depends on reading each screenshot on its own

    /// Two checkout screenshots, each with its own single Dining Dollars row.
    /// As one blob they read as one screenshot with two Payment method rows,
    /// an ambiguous layout that proposes no path.
    private var twoDiningScreenshots: [String] {
        [
            review(Self.diningRow[0], Self.diningRow[1], Self.diningRow[2]),
            review("Your order", "1 Chicken Bowl", Self.diningRow[0], Self.diningRow[1], Self.diningRow[2], delivery: true),
        ]
    }

    func testLocalValidationReadsEachScreenshotOnItsOwn() async throws {
        let evaluation = try await evaluation(twoDiningScreenshots)
        XCTAssertEqual(local(emptyRaw, evaluation).menuPath, .diningDollars)
    }

    func testExternalValidationReadsEachScreenshotOnItsOwn() async throws {
        let evaluation = try await evaluation(twoDiningScreenshots)
        XCTAssertEqual(
            external(ScreenshotProposal(menuPath: .diningDollars), evaluation).menuPath,
            .diningDollars,
            "a returned path survives when each screenshot's own evidence establishes it"
        )
    }

    // MARK: - Cross-screenshot stitching must not establish a path

    /// Screenshot A ends at the `Your payment` title. Screenshot B opens with
    /// `Payment method` / `Dining Dollars` and is eligible only as a cart, so
    /// it carries no payment-section evidence of its own. As one blob the two
    /// would read as a single selected Dining Dollars row.
    private var stitchedScreenshots: [String] {
        [
            review("Your order", "1 Chicken Bowl", "Your payment"),
            ["Payment method", "Dining Dollars", Self.cart].joined(separator: "\n"),
        ]
    }

    func testLocalValidationDoesNotStitchPaymentStructureAcrossScreenshots() async throws {
        let evaluation = try await evaluation(stitchedScreenshots)
        XCTAssertNil(local(emptyRaw, evaluation).menuPath)
    }

    func testExternalValidationDoesNotStitchPaymentStructureAcrossScreenshots() async throws {
        let evaluation = try await evaluation(stitchedScreenshots)
        XCTAssertNil(
            external(ScreenshotProposal(menuPath: .diningDollars), evaluation).menuPath,
            "a returned path is not evidence; stitched structure is not either"
        )
    }

    // MARK: - Amount authority is decided per screenshot

    func testALocalCartAmountSurvivesBesideACheckoutScreenshot() async throws {
        let evaluation = try await evaluation([
            "Your pickup order\nItems subtotal\n3M + $2.00",
            review("Your order", "1 Chicken Bowl"),
        ])
        let proposal = local(bowlRaw, evaluation, strategy: .directImageMultimodal)
        XCTAssertEqual(proposal.menuPath, .mealExchange)
        XCTAssertEqual(proposal.estimatedDiningDollarsCents, 200)
    }

    func testAnExternalCartAmountSurvivesBesideACheckoutScreenshot() async throws {
        let evaluation = try await evaluation([
            "Your pickup order\nItems subtotal\n3M + $2.00",
            review("Your order", "1 Chicken Bowl"),
        ])
        let validated = external(
            ScreenshotProposal(
                menuPath: .mealExchange,
                mealItems: [MealItem(name: "1 Chicken Bowl")],
                mealSwipes: 3,
                estimatedDiningDollarsCents: 200
            ),
            evaluation
        )
        XCTAssertEqual(validated.menuPath, .mealExchange)
        XCTAssertEqual(validated.estimatedDiningDollarsCents, 200)
    }

    func testACheckoutScreenshotsAmountIsNeverProposedLocallyOrExternally() async throws {
        let evaluation = try await evaluation([
            "Your pickup order\nItems subtotal\nContinue to checkout",
            review("Your order", "1 Chicken Bowl", "3M + $2.00"),
        ])
        let localProposal = local(bowlRaw, evaluation, strategy: .directImageMultimodal)
        XCTAssertEqual(localProposal.menuPath, .mealExchange)
        XCTAssertEqual(localProposal.mealSwipes, 3)
        XCTAssertNil(localProposal.estimatedDiningDollarsCents)

        let externalProposal = external(
            ScreenshotProposal(mealSwipes: 3, estimatedDiningDollarsCents: 200),
            evaluation
        )
        XCTAssertEqual(externalProposal.mealSwipes, 3)
        XCTAssertNil(externalProposal.estimatedDiningDollarsCents)
    }
}
