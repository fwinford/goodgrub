import XCTest
@testable import CommonPlateios

final class ScreenshotMealSwipeInferenceTests: XCTestCase {
    private let evidence = "View order\nOrder information\nCrave NYU - Meal Exchange\n1 Build Your Own Bowl\n1 Create Your Own Pasta Bowl"
    private let items = [
        MealItem(name: "1 Build Your Own Bowl"),
        MealItem(name: "1 Create Your Own Pasta Bowl"),
    ]

    func testExternalCountRequiresOnDeviceGroundingAndNeverUnlocksAmount() {
        var returned = ScreenshotProposal()
        returned.menuPath = .mealExchange
        returned.mealItems = items
        returned.mealSwipes = 2
        returned.estimatedDiningDollarsCents = 200

        let accepted = RequesterOrderExternalOutcomeValidator.validate(
            ScreenshotProposalOutcome(eligible: true, proposal: returned),
            evidenceText: evidence,
            allowsDiningDollarsEstimate: true
        )
        XCTAssertEqual(accepted.proposal.mealSwipes, 2)
        XCTAssertNil(accepted.proposal.estimatedDiningDollarsCents)

        let ungrounded = RequesterOrderExternalOutcomeValidator.validate(
            ScreenshotProposalOutcome(eligible: true, proposal: returned),
            evidenceText: evidence.replacingOccurrences(of: "1 Create Your Own Pasta Bowl", with: "• Create Your Own Pasta Bowl"),
            allowsDiningDollarsEstimate: true
        )
        XCTAssertNil(ungrounded.proposal.mealSwipes)

        let explicit = RequesterOrderExternalOutcomeValidator.validate(
            ScreenshotProposalOutcome(eligible: true, proposal: returned),
            evidenceText: evidence + "\n1M",
            allowsDiningDollarsEstimate: true
        )
        XCTAssertNil(explicit.proposal.mealSwipes)
    }

    // MARK: - External re-validator gates (W4-R4.1 review fix F6)

    private func returnedProposal(mealSwipes: Int) -> ScreenshotProposalOutcome {
        var returned = ScreenshotProposal()
        returned.menuPath = .mealExchange
        returned.mealItems = items
        returned.mealSwipes = mealSwipes
        return ScreenshotProposalOutcome(eligible: true, proposal: returned)
    }

    private func revalidate(_ outcome: ScreenshotProposalOutcome, evidence: String) -> ScreenshotProposal {
        RequesterOrderExternalOutcomeValidator.validate(
            outcome,
            evidenceText: evidence,
            allowsDiningDollarsEstimate: true
        ).proposal
    }

    /// The inference needs an on-device Meal Exchange path. Both lines are
    /// grounded and no M notation exists in either selection below, so only the
    /// path requirement can withhold the returned count — even though the
    /// returned proposal itself claims Meal Exchange.
    func testExternalCountIsWithheldWhenTheResolvedPathIsNotMealExchange() {
        let noPath = "Your Pickup Order\nContinue to Checkout\n1 Build Your Own Bowl\n1 Create Your Own Pasta Bowl"
        let diningDollars = "Review your pickup order\nYour order\n1 Build Your Own Bowl\n1 Create Your Own Pasta Bowl\n"
            + "Your payment\nPayment method\nDining Dollars"

        let none = revalidate(returnedProposal(mealSwipes: 2), evidence: noPath)
        XCTAssertNil(none.menuPath, "a returned path is not evidence")
        XCTAssertNil(none.mealSwipes)

        let dining = revalidate(returnedProposal(mealSwipes: 2), evidence: diningDollars)
        XCTAssertNil(dining.menuPath)
        XCTAssertNil(dining.mealSwipes)
    }

    /// Two grounded top-level meals infer exactly 2. A returned count is kept
    /// only when it equals that independently inferred N.
    func testExternalReturnedCountUnequalToTheIndependentlyInferredCountIsWithheld() {
        XCTAssertEqual(revalidate(returnedProposal(mealSwipes: 2), evidence: evidence).mealSwipes, 2)
        for returnedCount in [1, 3, 5] {
            XCTAssertNil(
                revalidate(returnedProposal(mealSwipes: returnedCount), evidence: evidence).mealSwipes,
                "a returned \(returnedCount) must not survive an independently inferred 2"
            )
        }
    }

    // MARK: - Eligible-image boundary through the real workflow (W4-R4.1 review fix F5)

    private let workflow = RequesterOrderWorkflow(recognizer: SyntheticTextRecognizer())
    private let header = "View order\nOrder information\nUnlisted Cafe - Meal Exchange"
    private let ineligibleBrowse = "Menu browse popular items reviews rating\n1 Create Your Own Pasta Bowl"
    private let twoMealsRaw = RequesterOrderRawOutput(
        visibleVenueText: nil,
        foodItems: [
            .init(name: "Build Your Own Bowl", quantity: 1, modifiers: []),
            .init(name: "Create Your Own Pasta Bowl", quantity: 1, modifiers: []),
        ],
        mealSwipes: nil
    )

    private func admitted(
        _ texts: [String]
    ) async throws -> ScreenshotWorkflowEvaluation<RequesterOrderEvidence> {
        let selection = try XCTUnwrap(
            ScreenshotSelection(images: ScreenshotTestEvidence.inputs(texts.count) { texts[$0 - 1] })
        )
        let evaluation = await workflow.evaluate(selection)
        return try XCTUnwrap(evaluation, "at least one synthetic screenshot is eligible")
    }

    private func localProposal(
        _ evaluation: ScreenshotWorkflowEvaluation<RequesterOrderEvidence>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ScreenshotProposal {
        guard case .valid(let outcome, _) = workflow.validateLocal(
            ScreenshotProviderResult(output: twoMealsRaw), evaluation: evaluation, strategy: .ocrFlattenedText
        ) else {
            XCTFail("expected a valid local result", file: file, line: line)
            return ScreenshotProposal()
        }
        return outcome.proposal
    }

    private func externalProposal(
        _ evaluation: ScreenshotWorkflowEvaluation<RequesterOrderEvidence>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ScreenshotProposal {
        guard case .valid(let outcome, _) = workflow.validateExternal(
            ScreenshotProviderResult(output: returnedProposal(mealSwipes: 2)),
            evaluation: evaluation,
            strategy: .directImageMultimodal
        ) else {
            XCTFail("expected a valid external result", file: file, line: line)
            return ScreenshotProposal()
        }
        return outcome.proposal
    }

    func testTwoMealsGroundedInTwoEligibleScreenshotsAreCountedLocallyAndExternally() async throws {
        let evaluation = try await admitted([
            "\(header)\n1 Build Your Own Bowl",
            "\(header)\n1 Create Your Own Pasta Bowl",
        ])
        XCTAssertEqual(evaluation.selection.count, 2)

        let local = localProposal(evaluation)
        XCTAssertEqual(local.menuPath, .mealExchange)
        XCTAssertEqual(local.mealItems, items)
        XCTAssertEqual(local.mealSwipes, 2)
        XCTAssertEqual(externalProposal(evaluation).mealSwipes, 2)
    }

    func testAnIneligibleScreenshotsOCRNeverGroundsACountedMeal() async throws {
        // The browse screenshot is policy-ineligible, so the workflow drops it
        // from the selection and from the evidence — even though its OCR holds
        // the line that would ground the second meal if it were read.
        let evaluation = try await admitted([
            "\(header)\n1 Build Your Own Bowl",
            ineligibleBrowse,
        ])
        XCTAssertEqual(evaluation.selection.count, 1)
        XCTAssertEqual(evaluation.derived.orderedTexts(for: evaluation.selection), ["\(header)\n1 Build Your Own Bowl"])

        let local = localProposal(evaluation)
        XCTAssertEqual(local.menuPath, .mealExchange)
        XCTAssertEqual(local.mealItems, items, "the provider's meals are still proposed")
        XCTAssertNil(local.mealSwipes)
        XCTAssertNil(externalProposal(evaluation).mealSwipes)
    }
}
