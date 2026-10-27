//
//  ScreenshotProposal.swift
//  CommonPlateios
//
// W4-S1 non-authoritative proposal domain shape. Distinct from
// `CreateRequestPayload`: this can never reach `RequestStore.createRequest`
// directly, only `RequestFoodFormDraft` via `ScreenshotProposalStore`'s
// manual-precedence application.
import Foundation

/// The allowlisted proposal fields: location, literal food, meal swipes.
/// Every field is independently optional — partial and empty proposals are
/// both ordinary outcomes, never a failure.
///
/// W4-R4 proposals use the same `MealItem` shape as manual entry.  A current
/// cart's order-level amount may also be proposed as an estimate, but never
/// submits anything. W4-R4.1 adds the deterministic `menuPath` proposal.
struct ScreenshotProposal: Equatable {
    /// W4-R4.1: the deterministic menu path, established only by CommonPlate's
    /// independent on-device evidence rule (`RequesterOrderDeterministicEvidence
    /// .resolveMenuPath`) — never a provider-produced field. Proposal-only: the
    /// requester remains able to change it, and it never submits anything.
    var menuPath: RequestMenuPath?
    var selectedDiningSpot: DiningSpot?
    var mealItems: [MealItem]?
    var mealSwipes: Int?
    var estimatedDiningDollarsCents: Int?
    var diningDollarsOrderTotalCents: Int?

    static let empty = ScreenshotProposal()
}

/// One completed analysis attempt. `eligible` distinguishes an unsupported
/// screenshot category from a supported one that simply yielded nothing
/// safe to propose, so presentation can explain the two differently without
/// either one ever becoming a hard failure.
struct ScreenshotProposalOutcome: Equatable {
    let eligible: Bool
    let proposal: ScreenshotProposal
    /// Requester-local R4.2 anchoring state. It is never Codable, sent over
    /// the wire, persisted, or derived from provider output.
    let venueDisposition: RequesterVenueDisposition?

    init(
        eligible: Bool,
        proposal: ScreenshotProposal,
        venueDisposition: RequesterVenueDisposition? = nil
    ) {
        self.eligible = eligible
        self.proposal = proposal
        self.venueDisposition = venueDisposition
    }

    func withVenueDisposition(_ disposition: RequesterVenueDisposition) -> ScreenshotProposalOutcome {
        ScreenshotProposalOutcome(eligible: eligible, proposal: proposal, venueDisposition: disposition)
    }

    var isEmpty: Bool {
        proposal.menuPath == nil
            && proposal.selectedDiningSpot == nil
            && (proposal.mealItems?.isEmpty ?? true)
            && proposal.mealSwipes == nil
            && proposal.estimatedDiningDollarsCents == nil
            && proposal.diningDollarsOrderTotalCents == nil
    }
}
