//
//  OwnerRequest.swift
//  CommonPlateios
//
//  W4-R5 owner-relative request model.
//

import Foundation

/// Where one of the participant's own requests is in its ongoing lifecycle,
/// exactly as the backend derived it for the exact participant authority that
/// produced it. Never computed from local state or a clock on this side.
enum OwnerRequestPhase: Equatable {
    /// A Later request whose start has not arrived.
    case scheduled
    /// Visible to helpers now (including one whose earlier reservation lapsed).
    case available
    /// A helper holds a live reservation (or the post-Yes external-order
    /// authority holds it). Reveals nothing about who.
    case reserved
}

/// One of the verified participant's own ongoing requests (W4-R5 G3).
///
/// Owner-relative and authority-bound: the backend resolved it from the
/// persisted requester binding of the exact participant authority this app
/// presented, so it is only ever installed for that authority (see
/// `RequestStore`). `canEdit` / `canWithdraw` are the backend's reading at
/// read time; the mutation re-checks atomically, so a stale `true` can only
/// ever produce a definitive refusal, never a wrong write.
struct OwnerRequest: Identifiable, Hashable {
    /// The request content. Always `ownership == .own`; its `status` is
    /// `.claimed` while `phase == .reserved` and `.open` otherwise.
    let request: FoodRequest
    let phase: OwnerRequestPhase
    /// The compare-and-swap authority for Edit. `nil` only for a legacy row
    /// that was never given edit authority (then `canEdit` is `false`).
    let contentRevision: Int?
    let canEdit: Bool
    let canWithdraw: Bool
    /// The latest start an edit may choose: 11:30 PM America/New_York on the
    /// request's **original** creation day. Presentation bound only; the
    /// backend enforces it.
    let latestScheduledStart: Date

    var id: String { request.id }
}

/// The decided result of an Edit: the revision it committed and the request as
/// it is now, or `nil` when it is no longer ongoing work (for example
/// withdrawn or expired since the edit committed). Never a fabricated copy.
struct EditOutcome: Equatable {
    let resultingRevision: Int
    let request: OwnerRequest?
}

extension OwnerRequest {
    /// A starting snapshot for a request this app knows only from a public
    /// read (for example one that was just created and is not yet in the owner
    /// list). It carries **no** authority: no revision, no Edit, no Withdraw.
    /// The owner detail re-reads the real owner truth on appearance and replaces
    /// it; until then nothing mutating is offered.
    static func provisional(from request: FoodRequest) -> OwnerRequest {
        OwnerRequest(
            request: request,
            phase: request.status == .claimed ? .reserved : .available,
            contentRevision: nil,
            canEdit: false,
            canWithdraw: false,
            latestScheduledStart: RequestFoodView.latestScheduledStart(
                on: request.createdAt,
                calendar: NYUCampusTime.calendar
            ) ?? request.createdAt
        )
    }
}
