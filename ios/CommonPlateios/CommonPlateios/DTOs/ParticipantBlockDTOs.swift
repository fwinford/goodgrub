//
//  ParticipantBlockDTOs.swift
//  CommonPlateios
//
// Wire-level types for participant blocking (W4-U1.3). These carry interaction
// context only. There is deliberately no field anywhere in this file that could
// hold another participant's identity: the backend resolves the other party
// from the request, and returns the owner nothing but a handle for the block
// itself and what the owner was already shown.
import Foundation

/// `POST /api/request/:id/block`. `externalOrderPlaced` is sent only while the
/// helper holds the live reservation on that request; it is omitted otherwise
/// and the backend rejects any other key.
struct CreateParticipantBlockPayload: Encodable {
    let externalOrderPlaced: Bool?
}

/// The role the *blocked* participant had in the interaction.
enum BlockedParticipantRoleDTO: String, Decodable {
    case requester
    case helper
}

struct ParticipantBlockDTO: Decodable {
    /// A handle for this block row alone, usable only by its owner. Not a
    /// participant identifier.
    let id: String
    let blockedRole: BlockedParticipantRoleDTO
    let diningLocation: String
    let interactionAt: Date
    let createdAt: Date
}

struct CreateParticipantBlockResponseDTO: Decodable {
    let block: ParticipantBlockDTO
    /// `true` only when the backend confirmed it ended the caller's reservation
    /// in the same transaction that created the block.
    let reservationReleased: Bool
    /// W4-U1.2 one-time path into reporting the newly blocked participant.
    /// Kept private to the block response/store boundary and never persisted.
    let reportAuthorization: String?
}

struct ParticipantBlockListResponseDTO: Decodable {
    let blocks: [ParticipantBlockDTO]
}

struct RemoveParticipantBlockResponseDTO: Decodable {
    let removed: Bool
}

/// Stable backend codes for the block routes, centralized like `ClaimErrorCode`.
enum ParticipantBlockErrorCode {
    /// The helper holds a live reservation on this request and must say whether
    /// the real Grubhub order already exists before a block can be recorded.
    static let externalOrderAnswerRequired = "BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED"
    /// The reservation changed after the attempt began; nothing was committed.
    static let reservationStateChanged = "RESERVATION_STATE_CHANGED"
    static let blockNotFound = "BLOCK_NOT_FOUND"
}
