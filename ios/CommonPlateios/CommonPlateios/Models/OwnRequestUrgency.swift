//
//  OwnRequestUrgency.swift
//  CommonPlateios
//
//  W4-R3 recorded scope addition (Faith 2026-10-19): `Your Requests` is
//  ordered by urgency group, newest-created-first within a group. One order
//  feeds both Home's two-card preview and `See all`.
//

import Foundation

enum OwnRequestUrgency: Int, Comparable {
    case confirmPickup = 0
    case ordered
    case reserved
    case available
    case scheduled

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The group for one owned request, from backend-derived truth only: the
    /// placed order's server-anchored attention state, or the owner phase. A
    /// request with no owner phase yet (a public-board gap) falls back to its
    /// public status, the same reading `OwnerRequest.provisional` uses.
    static func group(
        for request: FoodRequest,
        ownerPhase: OwnerRequestPhase?,
        needsPickupConfirmation: Bool
    ) -> OwnRequestUrgency {
        if request.status == .placed {
            return needsPickupConfirmation ? .confirmPickup : .ordered
        }
        switch ownerPhase {
        case .scheduled: return .scheduled
        case .reserved: return .reserved
        case .available: return .available
        case nil: return request.status == .claimed ? .reserved : .available
        }
    }

    static func ordered(
        _ requests: [FoodRequest],
        group: (FoodRequest) -> OwnRequestUrgency
    ) -> [FoodRequest] {
        requests
            .map { (request: $0, group: group($0)) }
            .sorted { lhs, rhs in
                if lhs.group != rhs.group { return lhs.group < rhs.group }
                if lhs.request.createdAt != rhs.request.createdAt {
                    return lhs.request.createdAt > rhs.request.createdAt
                }
                return lhs.request.id < rhs.request.id
            }
            .map(\.request)
    }
}
