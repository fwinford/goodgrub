//
//  RequesterOrderOutputValidator.swift
//  CommonPlateios
//
// W4-S3 Requester adapter: the on-device Requester workflow validator, its raw
// provider output shape, and the external-result re-validation. Raw provider
// output — from the Apple on-device model or, defensively, anything an external result
// claims — is never proposal authority by itself. This is the on-device port
// of `validateProviderOutput` (`src/screenshotProposalValidation.ts`): the same
// forbidden-field refusal, `.strict()` schema, sanitization, overlap rule,
// grounded vendor resolution, meal-swipe corroboration, and current-cart
// Dining Dollars rule, evaluated only against independent on-device evidence.
// `shared/screenshot-conformance-vectors.json` is asserted against both this
// type and the backend so the two cannot drift silently.
import Foundation

/// Provider-produced order description in the exact shape the backend's
/// `.strict()` schema accepts, so one validator serves every provider class.
struct RequesterOrderRawOutput: Equatable {
    struct Item: Equatable {
        var name: String
        var quantity: Int?
        var modifiers: [String]
    }

    var visibleVenueText: String?
    var foodItems: [Item]
    var mealSwipes: Int?

    /// The JSON-object form the shared validator consumes.
    var jsonObject: [String: Any] {
        [
            "visibleVenueText": visibleVenueText.map { $0 as Any } ?? NSNull(),
            "foodItems": foodItems.map { item -> [String: Any] in
                [
                    "name": item.name,
                    "quantity": item.quantity.map { $0 as Any } ?? NSNull(),
                    "modifiers": item.modifiers,
                ]
            },
            "mealSwipes": mealSwipes.map { $0 as Any } ?? NSNull(),
        ]
    }
}

enum RequesterOrderOutputValidator {
    enum Failure: String, Equatable {
        case forbiddenFields
        case schemaInvalid
    }

    enum Result: Equatable {
        case valid(ScreenshotProposal)
        case invalid(Failure)
    }

    /// Fields that must never appear in provider output. Presence of any of
    /// them is refused before schema validation, independent of whether the
    /// rest of the payload is well formed — an authority boundary, not a shape
    /// convenience.
    static let forbiddenFields: Set<String> = [
        "pickupName", "timing", "preferredPickupTime", "action", "submit",
        "reasoning", "explanation", "menuPath", "orderDetails", "diningDollars",
        "estimatedDiningDollars", "estimatedDiningDollarsCents",
        "diningDollarsOrderTotalCents",
    ]

    /// - Parameters:
    ///   - raw: decoded provider JSON (or `RequesterOrderRawOutput.jsonObject`).
    ///   - evidenceText: the combined independent on-device OCR text of exactly
    ///     the eligible screenshots analyzed.
    ///   - evidenceImageCount: how many eligible screenshots were analyzed
    ///     together (drives the multi-screenshot overlap rule).
    ///   - imageEvidenceTexts: each eligible screenshot's own on-device OCR
    ///     text, in selection order, for the W4-R4.1 menu-path rule's
    ///     per-screenshot attribution. `nil` means `evidenceText` is one
    ///     screenshot, mirroring the backend default.
    ///   - allowsDiningDollarsEstimate: whether this evidence strategy may
    ///     propose the order-level Dining Dollars estimate at all. A strategy
    ///     that reads the same runtime OCR text as the corroborating evidence
    ///     may not (its proposal and the evidence are not independent); the
    ///     rule is Requester policy, decided by the caller through
    ///     `RequesterOrderPolicy.permitsDiningDollarsEstimate(for:)`.
    static func validate(
        raw: Any?,
        evidenceText: String,
        evidenceImageCount: Int,
        imageEvidenceTexts: [String]? = nil,
        imageTotalGeometryEvidence: [ScreenshotTotalGeometryEvidence?] = [],
        allowsDiningDollarsEstimate: Bool,
        vendors: [DiningSpot] = SupportedVendorCatalog.diningSpots
    ) -> Result {
        if let object = raw as? [String: Any],
           object.keys.contains(where: { forbiddenFields.contains($0) }) {
            return .invalid(.forbiddenFields)
        }
        guard let parsed = parseStrict(raw) else {
            return .invalid(.schemaInvalid)
        }
        return .valid(
            buildProposal(
                evidenceText: evidenceText,
                imageEvidenceTexts: imageEvidenceTexts ?? [evidenceText],
                imageTotalGeometryEvidence: imageTotalGeometryEvidence,
                evidenceImageCount: evidenceImageCount,
                visibleVenueText: parsed.visibleVenueText,
                foodItems: parsed.foodItems,
                mealSwipes: parsed.mealSwipes,
                allowsDiningDollarsEstimate: allowsDiningDollarsEstimate,
                vendors: vendors
            )
        )
    }

    // MARK: - Strict schema

    private struct Parsed {
        var visibleVenueText: String?
        var foodItems: [RequesterOrderRawOutput.Item]
        var mealSwipes: Int?
    }

    private static let topLevelKeys: Set<String> = ["visibleVenueText", "foodItems", "mealSwipes"]
    private static let itemKeys: Set<String> = ["name", "quantity", "modifiers"]

    /// JSON integer, distinguishing a boolean from a number and refusing
    /// anything that is not a safe integer (stricter than the backend only for
    /// values no provider ever emits).
    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) <= 9_007_199_254_740_991 else {
            return nil
        }
        return Int(double)
    }

    private static func optionalString(_ value: Any) -> (ok: Bool, value: String?) {
        if value is NSNull { return (true, nil) }
        if let string = value as? String { return (true, string) }
        return (false, nil)
    }

    private static func optionalInteger(_ value: Any) -> (ok: Bool, value: Int?) {
        if value is NSNull { return (true, nil) }
        if let int = integer(value) { return (true, int) }
        return (false, nil)
    }

    private static func parseStrict(_ raw: Any?) -> Parsed? {
        guard let object = raw as? [String: Any], Set(object.keys) == topLevelKeys else { return nil }
        let venue = optionalString(object["visibleVenueText"]!)
        guard venue.ok else { return nil }
        let mealSwipes = optionalInteger(object["mealSwipes"]!)
        guard mealSwipes.ok else { return nil }
        guard let rawItems = object["foodItems"] as? [Any] else { return nil }

        var items: [RequesterOrderRawOutput.Item] = []
        for rawItem in rawItems {
            guard let itemObject = rawItem as? [String: Any], Set(itemObject.keys) == itemKeys,
                  let name = itemObject["name"] as? String,
                  let rawModifiers = itemObject["modifiers"] as? [Any] else { return nil }
            let quantity = optionalInteger(itemObject["quantity"]!)
            guard quantity.ok else { return nil }
            var modifiers: [String] = []
            for rawModifier in rawModifiers {
                guard let modifier = rawModifier as? String else { return nil }
                modifiers.append(modifier)
            }
            items.append(.init(name: name, quantity: quantity.value, modifiers: modifiers))
        }
        return Parsed(visibleVenueText: venue.value, foodItems: items, mealSwipes: mealSwipes.value)
    }

    // MARK: - Proposal construction

    private static func isBareAmbiguousModifier(_ modifier: String) -> Bool {
        let token = ScreenshotJSText.trimmed(modifier).lowercased()
        return token == "yes" || token == "no"
    }

    private static func structuredMealItem(
        _ item: RequesterOrderRawOutput.Item,
        sanitizedModifiers: [String]
    ) -> MealItem? {
        let name = ScreenshotJSText.trimmed(item.name)
        guard !name.isEmpty else { return nil }
        let prefix = (item.quantity ?? 0) > 0 ? "\(item.quantity!) " : ""
        let joined = sanitizedModifiers.joined(separator: ", ")
        return MealItem(name: "\(prefix)\(name)", details: joined.isEmpty ? nil : joined)
    }

    private struct ItemIdentity: Hashable {
        let name: String
        let quantity: Int?
        let modifiers: [String]
    }

    private static func identity(
        _ item: RequesterOrderRawOutput.Item,
        sanitizedModifiers: [String]
    ) -> ItemIdentity {
        func normalize(_ text: String) -> String {
            ScreenshotJSText.collapsingWhitespace(ScreenshotJSText.trimmed(text).lowercased())
        }
        return ItemIdentity(
            name: normalize(item.name),
            quantity: item.quantity,
            modifiers: sanitizedModifiers.map(normalize).sorted()
        )
    }

    /// One entry per observed order line. Up to five screenshots describe ONE
    /// logical order, so with several screenshots a repeated identical line is
    /// ambiguous between overlap and a real repeat and yields `nil` (no items
    /// and no swipe count). One screenshot cannot overlap with itself, so
    /// repeated lines are kept.
    private static func proposedMealItems(
        _ foodItems: [RequesterOrderRawOutput.Item],
        evidenceImageCount: Int
    ) -> [MealItem]? {
        var seen = Set<ItemIdentity>()
        var lines: [MealItem] = []
        for item in foodItems {
            let modifiers = item.modifiers.filter { !isBareAmbiguousModifier($0) }
            guard let line = structuredMealItem(item, sanitizedModifiers: modifiers) else { continue }
            let itemIdentity = identity(item, sanitizedModifiers: modifiers)
            if seen.contains(itemIdentity), evidenceImageCount > 1 { return nil }
            seen.insert(itemIdentity)
            lines.append(line)
        }
        return lines
    }

    private static func buildProposal(
        evidenceText: String,
        imageEvidenceTexts: [String],
        imageTotalGeometryEvidence: [ScreenshotTotalGeometryEvidence?],
        evidenceImageCount: Int,
        visibleVenueText: String?,
        foodItems: [RequesterOrderRawOutput.Item],
        mealSwipes: Int?,
        allowsDiningDollarsEstimate: Bool,
        vendors: [DiningSpot]
    ) -> ScreenshotProposal {
        var proposal = ScreenshotProposal()

        proposal.selectedDiningSpot = RequesterOrderDeterministicEvidence.resolveVendor(
            evidenceText: evidenceText,
            visibleVenueText: visibleVenueText,
            vendors: vendors
        )

        // W4-R4.1: the path comes only from independent deterministic
        // evidence and is resolved before anything branch-dependent. Disputed
        // evidence proposes no path AND omits every value whose meaning
        // depends on the path (items, swipes, the top-up estimate); the shared
        // location stays.
        let pathResolution = RequesterOrderDeterministicEvidence.resolveMenuPath(
            imageEvidenceTexts: imageEvidenceTexts,
            imageTotalGeometryEvidence: imageTotalGeometryEvidence
        )
        proposal.menuPath = pathResolution.menuPath
        if pathResolution.conflict { return proposal }
        if pathResolution.menuPath != .mealExchange {
            proposal.diningDollarsOrderTotalCents =
                RequesterOrderDeterministicEvidence.currentOrderTotalCents(
                    imageEvidenceTexts: imageEvidenceTexts,
                    imageTotalGeometryEvidence: imageTotalGeometryEvidence
                )
        }

        let mealItems = proposedMealItems(foodItems, evidenceImageCount: evidenceImageCount)
        if let mealItems, !mealItems.isEmpty {
            proposal.mealItems = mealItems
        }

        if mealItems != nil, let mealSwipes, (1...5).contains(mealSwipes),
           RequesterOrderDeterministicEvidence.corroboratedMealSwipeCount(evidenceText) == mealSwipes {
            proposal.mealSwipes = mealSwipes
            if allowsDiningDollarsEstimate {
                // Checkout/review screenshots grant no amount authority of
                // their own.
                proposal.estimatedDiningDollarsCents =
                    RequesterOrderDeterministicEvidence.currentCartDiningDollarsCents(
                        RequesterOrderDeterministicEvidence.amountAuthorityEvidenceText(
                            imageEvidenceTexts: imageEvidenceTexts
                        )
                    )
            }
        }
        if pathResolution.menuPath == .mealExchange, let mealItems,
           !RequesterOrderDeterministicEvidence.hasExplicitMealSwipeNotation(evidenceText) {
            let sourceItems = foodItems.filter { !ScreenshotJSText.trimmed($0.name).isEmpty }
            if sourceItems.count == mealItems.count && sourceItems.allSatisfy({ $0.quantity == 1 }) {
                proposal.mealSwipes = RequesterOrderDeterministicEvidence.inferredMealSwipeCount(
                    mealItems: mealItems, imageEvidenceTexts: imageEvidenceTexts
                )
            }
        }
        return proposal
    }
}

/// Defense in depth for a result that has already been through the backend's
/// own validation. External results also pass the on-device workflow rules
/// before they become applyable: the backend's proposal is re-checked against
/// the same independent on-device evidence, and any field that evidence does
/// not itself support is dropped. CommonPlate's deterministic boundary — not the
/// provider or the backend's answer alone — decides what may reach the form.
enum RequesterOrderExternalOutcomeValidator {
    /// `allowsDiningDollarsEstimate` is the same Requester policy the local
    /// validator receives (`RequesterOrderPolicy.permitsDiningDollarsEstimate(for:)`),
    /// applied to the external provider's declared evidence strategy.
    static func validate(
        _ outcome: ScreenshotProposalOutcome,
        evidenceText: String,
        imageEvidenceTexts: [String]? = nil,
        imageTotalGeometryEvidence: [ScreenshotTotalGeometryEvidence?] = [],
        allowsDiningDollarsEstimate: Bool,
        vendors: [DiningSpot] = SupportedVendorCatalog.diningSpots
    ) -> ScreenshotProposalOutcome {
        // Eligibility was decided on-device before anything was sent and can
        // never be established by a returned flag.
        guard outcome.eligible else { return ScreenshotProposalOutcome(eligible: false, proposal: .empty) }

        var validated = ScreenshotProposal()

        // W4-R4.1: a returned path survives only when CommonPlate's own
        // on-device evidence independently establishes exactly that path; a
        // disputed selection drops every branch-dependent value as well.
        let pathResolution = RequesterOrderDeterministicEvidence.resolveMenuPath(
            imageEvidenceTexts: imageEvidenceTexts ?? [evidenceText],
            imageTotalGeometryEvidence: imageTotalGeometryEvidence
        )
        if let proposed = outcome.proposal.menuPath, proposed == pathResolution.menuPath {
            validated.menuPath = proposed
        }

        if let spot = outcome.proposal.selectedDiningSpot,
           let grounded = RequesterOrderDeterministicEvidence.resolveVendor(
               evidenceText: evidenceText,
               visibleVenueText: nil,
               vendors: vendors
           ),
           grounded.name == spot.name {
            validated.selectedDiningSpot = grounded
        }
        if pathResolution.conflict {
            return ScreenshotProposalOutcome(eligible: true, proposal: validated)
        }
        if pathResolution.menuPath != .mealExchange,
           let total = outcome.proposal.diningDollarsOrderTotalCents,
           RequesterOrderDeterministicEvidence.currentOrderTotalCents(
               imageEvidenceTexts: imageEvidenceTexts ?? [evidenceText],
               imageTotalGeometryEvidence: imageTotalGeometryEvidence
           ) == total {
            validated.diningDollarsOrderTotalCents = total
        }

        let items = (outcome.proposal.mealItems ?? []).compactMap { item -> MealItem? in
            let name = ScreenshotJSText.trimmed(item.name)
            guard !name.isEmpty else { return nil }
            let details = item.details.map(ScreenshotJSText.trimmed).flatMap { $0.isEmpty ? nil : $0 }
            return MealItem(name: name, details: details)
        }
        if !items.isEmpty {
            validated.mealItems = items
        }

        if let swipes = outcome.proposal.mealSwipes,
           (1...5).contains(swipes),
           RequesterOrderDeterministicEvidence.corroboratedMealSwipeCount(evidenceText) == swipes {
            validated.mealSwipes = swipes
            if allowsDiningDollarsEstimate,
               let cents = outcome.proposal.estimatedDiningDollarsCents,
               RequesterOrderDeterministicEvidence.currentCartDiningDollarsCents(
                   RequesterOrderDeterministicEvidence.amountAuthorityEvidenceText(
                       imageEvidenceTexts: imageEvidenceTexts ?? [evidenceText]
                   )
               ) == cents {
                validated.estimatedDiningDollarsCents = cents
            }
        }
        if pathResolution.menuPath == .mealExchange,
           !RequesterOrderDeterministicEvidence.hasExplicitMealSwipeNotation(evidenceText),
           let swipes = outcome.proposal.mealSwipes,
           RequesterOrderDeterministicEvidence.inferredMealSwipeCount(
               mealItems: items, imageEvidenceTexts: imageEvidenceTexts ?? [evidenceText]
           ) == swipes {
            validated.mealSwipes = swipes
        }
        return ScreenshotProposalOutcome(eligible: true, proposal: validated)
    }
}
