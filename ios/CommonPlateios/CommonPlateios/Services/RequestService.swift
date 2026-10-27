//
//  RequestService.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Owns CommonPlate endpoint knowledge and DTO-to-domain mapping, per
// docs/system-contract.md. Talks to the backend only through
// APIClient; never calls URLSession directly. Contains no SwiftUI state and
// no user-facing copy. Never retries POST operations automatically.
import Foundation

/// Product-safe, structured failure surface for the request domain.
///
/// Decoded error envelopes remain code-agnostic here and are preserved as
/// `.serverError(code:message:)`; presentation layers map stable codes to
/// recovery and copy.
enum RequestServiceError: Error {
    /// A non-envelope HTTP 404, indicating that the route is absent at the
    /// configured base URL.
    case notFound
    /// A decoded `{ error: { code, message } }` whose `code` isn't yet
    /// mapped to a dedicated case. Carries the backend's own values as-is —
    /// this is not a guessed/invented code, just a passthrough.
    case serverError(code: String, message: String)
    /// A failure known not to represent an uncertain POST outcome.
    case transport(underlying: Error)
    /// Store-level precondition failure (W4-D2 FIX): the exact-operation
    /// recovery record could not be durably persisted before transmission.
    /// No create POST was sent — this is a pre-transmission local failure,
    /// never an uncertain write.
    case durablePersistenceFailed
    /// A create POST may have been applied server-side, but iOS did not
    /// receive and validate a usable success response.
    case ambiguousCreateOutcome(underlying: Error)
    /// A claim POST may have succeeded server-side, but iOS did not receive
    /// and validate the one-time claim credentials.
    case ambiguousClaimOutcome(underlying: Error)
    /// An extension POST may have been applied server-side, but iOS did not
    /// receive and validate the new expiration. Because only one extension is
    /// ever granted, the caller must neither retry nor advance its local
    /// expiration on this outcome.
    case ambiguousExtensionOutcome(underlying: Error)
    /// A fulfillment POST may have been applied server-side, but iOS did not
    /// receive and validate a usable success response.
    case ambiguousFulfillmentOutcome(underlying: Error)
    /// A block POST may have been applied server-side (W4-U1.3), but iOS did
    /// not receive and validate its confirmation. Never retried automatically
    /// and never presented as either a success or a release: the owner's own
    /// blocked-student list is the authoritative place to find out.
    case ambiguousBlockOutcome(underlying: Error)
    /// Client-side precondition failure, not a backend response: no local
    /// active claim exists for the request being fulfilled.
    case noActiveClaim
    /// Client-side precondition failure: the backend-provided claim deadline
    /// has passed, so iOS refused to start a fulfillment POST.
    case claimExpired
    /// A prior fulfillment POST is unresolved. The raw token and claimant
    /// context stay in memory, but another POST is forbidden.
    case unresolvedFulfillment
    /// W4-H1a store-level precondition failure: no placed-order screenshot is
    /// currently selected for this reservation, so no fulfillment POST was
    /// started. Not a backend response and never a fabricated placement state.
    case placedOrderScreenshotRequired
    /// Store-level precondition failure: an operation of the same kind is
    /// already running, so no second service call was started.
    case operationInProgress
    /// Store-level precondition failure: a claim for a *different* request is
    /// mid-flight. Kept distinct from `operationInProgress` because that case
    /// describes the request in front of the helper as already starting, which
    /// would be untrue here — nothing has been started for this one, and the
    /// wait is short rather than a commitment made elsewhere.
    case otherClaimInProgress
    // W4-H1 deliberately removes the former `unacknowledgedPlacement` case.
    // Authoritatively confirmed fulfillment completes the helper relationship
    // immediately, so no client-side acknowledgement of a placement result may
    // refuse a later claim. The case is not renamed or replaced: there is no
    // remaining store-level precondition that reads confirmation presentation
    // as claim authority.
    /// Store-level precondition failure: a confirmed claim on a *different*
    /// request is already held, so this one cannot be claimed. Kept distinct
    /// from `operationInProgress` because the helper's situation and next step
    /// are different — nothing is in flight, they are already committed
    /// elsewhere — and one message cannot honestly describe both.
    case existingActiveClaim
    /// A Withdraw or Edit POST (W4-R5) may have been applied server-side, but
    /// iOS did not receive and validate a usable decided response. Never
    /// retried automatically and never presented as edited, withdrawn or
    /// unchanged: recovery replays the **same** operation identity, which the
    /// backend answers exactly once.
    case ambiguousUpdateOutcome(underlying: Error)
    /// Store-level precondition failure (W4-R5): an earlier Edit or Withdraw has
    /// an unknown outcome and is unresolved, so no new update was started and
    /// nothing was sent. Resolved by replaying that operation, never by a new one.
    case unresolvedUpdate
    /// W4-R5 service-boundary precondition failure: a protected request read
    /// (`GET /api/requests`, `GET /api/request/:id`) needs participant
    /// authority and none was available, so **nothing was sent**. It is
    /// "authority required", never evidence about any request.
    case participantAuthorityRequired
}

/// How a refused or failed ordinary request read must be understood (W4-R5).
///
/// Three outcomes that must never be fabricated as one another: the backend
/// saying authority is required, the backend definitively rejecting the
/// credential it was shown (revoked or replaced), and everything else — a
/// `503`, a transport failure, a timeout, an undecodable answer — which is
/// *unknown*. Unknown is never an authoritative empty list, never
/// "unavailable", "withdrawn" or "not placed", and never a revocation.
enum RequestReadClassification: Equatable {
    /// No usable credential was presented (or none existed to present).
    case authorityRequired
    /// The backend definitively rejected the presented credential.
    case authorityInvalid
    /// Verification could not be established either way.
    case unavailableOrUnknown

    init(_ error: Error) {
        switch error as? RequestServiceError {
        case .participantAuthorityRequired:
            self = .authorityRequired
        case .serverError(let code, _)?:
            switch code {
            case ParticipantErrorCode.verificationRequired:
                self = .authorityRequired
            case ParticipantErrorCode.authorityInvalid:
                self = .authorityInvalid
            default:
                self = .unavailableOrUnknown
            }
        default:
            self = .unavailableOrUnknown
        }
    }
}

/// Result of a successful claim, mirroring the backend's claim response shape.
/// `claimToken`/`claimExpiresAt` are claim-private and are not folded into the
/// public `FoodRequest` mapping. W4-R4 removed `pickupName` from the request
/// contract, so the claim response no longer carries one either.
struct ClaimOutcome {
    let request: FoodRequest
    let claimToken: String
    let claimExpiresAt: Date
}

/// Result of the one permitted claim extension. The backend returns no request
/// object here, so there is nothing to validate against the path ID and nothing
/// to apply to the public collection — only the authoritative claim deadline.
struct ClaimExtensionOutcome {
    let claimExpiresAt: Date
    let claimExtendedAt: Date
}

/// `GET /api/participant/active-reservation`'s answer for the current verified
/// participant (W3-H1 continuation). Carries no claim token — it was never
/// persisted, so continuation cannot recover it.
struct ActiveReservationOutcome {
    let request: FoodRequest
    let claimExpiresAt: Date
    let claimExtendedAt: Date?
    /// W4-U1.3: `true` only when the backend says optional direct contact is
    /// unavailable for this reservation. `false` is "not established".
    var directContactRestricted: Bool = false
    /// W4-U1.3: `true` only when the backend says a confirmed Stop helping of
    /// this reservation ends at Home. Lifecycle truth, not Block truth: it says
    /// nothing about whether, or by whom, anyone was blocked.
    var stopReturnsHome: Bool = false
    /// Backend-authorized suspended-helper Stop question. Absence or `false`
    /// never prompts for external-order state.
    var stopAsksOrderQuestion: Bool = false
}

/// The claimant-private fulfillment re-entry truth for a verified participant
/// who holds no active claimed reservation (W3-H2): a request they most
/// recently placed, still existing within its retention horizon.
/// `notificationStatus` is `nil` when the outcome never settled — never
/// guessed as sent or failed.
struct PlacedReservationOutcome {
    let request: FoodRequest
    let orderNumber: String
    let etaText: String
    /// Backend ready instant; `nil` only for a placement just confirmed in
    /// this process, before its first authoritative read.
    var estimatedReadyAt: Date? = nil
    let notificationStatus: NotificationDeliveryStatus?
    /// W4-U1.1: `true` only when the backend's durable, content-free marker
    /// proves the helper's optional Message was suppressed at placement.
    /// `false` means "not established", never "was sent".
    var messageSuppressed: Bool = false
    /// W4-R3: backend seconds until the helper's `Waiting for pickup` window
    /// ends, measured at the moment of the authoritative read. `nil` means no
    /// authoritative cutoff is known yet (a placement just confirmed in this
    /// process, before its first authoritative read) — never a guessed one.
    var helperVisibleRemainingAtRead: TimeInterval? = nil
    var monotonicReadAt: TimeInterval = ProcessInfo.processInfo.systemUptime

    var id: String { request.id }

    /// Advances only on the monotonic clock, so changing the device wall clock
    /// can neither extend nor shorten the helper's window.
    func isVisibleOnHelperHome(
        at monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let remaining = helperVisibleRemainingAtRead else { return true }
        return remaining - max(0, monotonicNow - monotonicReadAt) > 0
    }
}

/// One authoritative `active-reservation` answer: whether a claim is held, and
/// every placement the helper must still be shown as `Waiting for pickup`.
struct ParticipantReservationRead {
    let state: ParticipantReservationState
    let placements: [PlacedReservationOutcome]
    /// Authoritative requester pickup confirmations for this helper; never
    /// inferred from a placement leaving `placements`.
    var pickupConfirmedRequestIDs: [String] = []
}

struct PlacedOrderEvidence: Equatable {
    let data: Data
    let mimeType: String
}

/// Backend truth for `GET /api/participant/active-reservation` (W3-H1
/// continuation, extended by W3-H2 fulfillment re-entry): a verified
/// participant may currently hold an active claimed reservation, may hold
/// none but have most recently placed a still-existing request, or may hold
/// neither.
enum ParticipantReservationState {
    case reservation(ActiveReservationOutcome)
    case none
}

/// Result of a confirmed block (W4-U1.3).
struct BlockOutcome: Equatable {
    let student: BlockedStudent
    /// `true` only when the backend confirmed it ended the helper's reservation
    /// together with the block. Never inferred from the helper's own answer.
    let reservationReleased: Bool
    /// Private, time-limited handoff used only by the immediate report offer.
    let reportAuthorization: String?
}

/// Result of a successful fulfillment, mirroring the backend's fulfill response shape.
/// Core placement success (`request`) is independent of notification delivery.
struct FulfillOutcome {
    let request: FoodRequest
    let notificationStatus: NotificationDeliveryStatus
    /// W4-U1.1: `true` only when placement committed but the helper's optional
    /// Message was suppressed. Placement is a success either way.
    var messageSuppressed: Bool = false
}

/// Stable refusal codes the Withdraw / Edit routes answer with (W4-R5). Each is
/// a definitive, pre-write refusal; presentation maps them to copy and recovery.
/// `requestUpdateFailed` is the one exception — see `isAmbiguousUpdateCode`.
enum RequestUpdateErrorCode {
    static let requestReserved = "REQUEST_RESERVED"
    static let requestWithdrawn = "REQUEST_WITHDRAWN"
    static let requestAlreadyPlaced = "REQUEST_ALREADY_PLACED"
    static let requestExpired = "REQUEST_EXPIRED"
    static let requestNotFound = "REQUEST_NOT_FOUND"
    static let revisionConflict = "REQUEST_REVISION_CONFLICT"
    static let notEditable = "REQUEST_NOT_EDITABLE"
    static let horizonExceeded = "REQUEST_HORIZON_EXCEEDED"
    static let textNotAllowed = "REQUEST_TEXT_NOT_ALLOWED"
    static let invalidVendor = "INVALID_VENDOR"
    static let invalidRequest = "INVALID_REQUEST"
    static let operationConflict = "OPERATION_CONFLICT"
    static let operationUnauthorized = "OPERATION_UNAUTHORIZED"
    static let operationExpired = "OPERATION_EXPIRED"
    /// The backend could not classify a failure after the gate: the change may
    /// or may not have committed, so this is **ambiguous**, not a refusal.
    static let requestUpdateFailed = "REQUEST_UPDATE_FAILED"
    static let internalFailure = "INTERNAL_FAILURE"

    /// Refusals the update routes answer only *after* consulting this identity's
    /// ledger (or from the request's own state), so for a replayed identity they
    /// are the one kind of refusal that decides it. Anything else — the rate
    /// limiter, the participant or operation-authority gate, an unavailable
    /// verification — runs before the ledger and proves nothing about the
    /// earlier transmission.
    static func isLedgerDecidedRefusal(_ code: String) -> Bool {
        switch code {
        case requestReserved, requestWithdrawn, requestAlreadyPlaced, requestExpired,
             requestNotFound, revisionConflict, notEditable, horizonExceeded,
             textNotAllowed, invalidVendor, invalidRequest, operationConflict,
             operationUnauthorized, operationExpired:
            return true
        default:
            return false
        }
    }

    /// Whether a decoded error envelope leaves the mutation's outcome unknown.
    static func isAmbiguousUpdateCode(_ code: String) -> Bool {
        code == requestUpdateFailed || code == internalFailure
    }
}

struct RequestService {
    let client: APIClient

    /// W4-U1.3: a Message the backend withheld because of the blocked-pair
    /// contact restriction is not shown to the helper as a suppression card;
    /// only U1.1's text-filter suppression is presented.
    static func isFilterSuppression(suppressed: Bool?, withheld: Bool?) -> Bool {
        suppressed == true && withheld != true
    }

    init(client: APIClient) {
        self.client = client
    }

    /// The header the backend reads participant authority from (W3-I1). It has
    /// to match `PARTICIPANT_AUTHORITY_HEADER` in
    /// `src/participantAuthorityGate.ts`.
    static let participantAuthorityHeader = "x-commonplate-participant"

    /// The header the backend reads the W3-D1 request-create operation
    /// identity from. It has to match `OPERATION_IDENTITY_HEADER` in
    /// `src/createRequestRoute.ts`.
    static let operationIdentityHeader = "x-commonplate-operation-id"
    /// W4-D2: the ledger authority a create operation was recorded against.
    /// The backend serves such a request only from that ledger.
    static let operationAuthorityHeader = "x-commonplate-operation-authority"

    /// Builds the credential header, or none at all.
    ///
    /// An absent credential deliberately sends *no* header rather than an empty
    /// one: "this caller has not verified" and "this caller presented something
    /// unusable" are different backend answers, and only the first is true
    /// here. Conflating them would tell an unverified student their stored
    /// identity had been rejected.
    private static func participantHeaders(_ authority: String?) -> [String: String] {
        guard let authority, !authority.isEmpty else { return [:] }
        return [participantAuthorityHeader: authority]
    }

    /// `GET /api/requests`
    ///
    /// W4-R5: the list is served only to a usable, backend-verified
    /// participant, so `participantAuthority` is required. A caller with none
    /// gets `.participantAuthorityRequired` and **nothing is sent**; the
    /// service boundary never issues this read anonymously. The backend
    /// additionally removes any request this participant has ever
    /// successfully held from their own list (W3-H2 marketplace
    /// presentation).
    func fetchActiveRequests(participantAuthority: String) async throws -> [FoodRequest] {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        do {
            let response: RequestListResponseDTO = try await client.send(
                path: "/api/requests",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            // `GET /api/requests` derives caller-relative ownership for the
            // authority this call presented, so its answer is authoritative
            // for that authority.
            return try response.requests.map {
                try Self.mapPublicRequest(
                    $0,
                    ownership: Self.resolvedOwnership($0)
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// Privacy-safe `GET /api/request/:id`. The backend reports effective
    /// availability here (a claim-expired request reads back as `open`), not
    /// raw persisted status; it never authorizes fulfillment. Used once after
    /// an ambiguous fulfillment POST to see whether placement can be
    /// confirmed, and by helper new-request notification tap-routing to
    /// resolve whether the tapped request is still available.
    ///
    /// W4-R5: `participantAuthority` is required, exactly as for the list. A
    /// caller with none gets `.participantAuthorityRequired` and nothing is
    /// sent. The mapped `FoodRequest.isOwnRequest` reflects the resolving
    /// caller's own current identity.
    func fetchRequest(id: String, participantAuthority: String) async throws -> FoodRequest {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        do {
            let response: RequestDetailResponseDTO = try await client.send(
                path: "/api/request/\(id)",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            try Self.validateResponseRequestID(response.request.id, expected: id)
            // `GET /api/request/:id` derives the same caller-relative
            // ownership the list does (W4-H2 detail projection), so a detail
            // read is authoritative for the authority it presented.
            return try Self.mapPublicRequest(
                response.request,
                ownership: Self.resolvedOwnership(response.request)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - W4-R5 owner reads, Withdraw, Edit

    /// `GET /api/participant/requests` — the verified participant's own ongoing
    /// requests. Authority is required and nothing is sent without it. An empty
    /// array is an authoritative empty answer; every failure is *unknown* and
    /// never an empty list.
    func fetchOwnerRequests(participantAuthority: String) async throws -> [OwnerRequest] {
        try await fetchOwnerRequestList(participantAuthority: participantAuthority).requests
    }

    /// The same read, also returning the owner-only `removedNotice` boolean
    /// (missing on an older payload = `false`). The boolean carries no id,
    /// count, time or reason.
    func fetchOwnerRequestList(
        participantAuthority: String
    ) async throws -> (requests: [OwnerRequest], removedNotice: Bool) {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        do {
            let response: OwnerRequestListResponseDTO = try await client.send(
                path: "/api/participant/requests",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            return (
                try response.requests.map(Self.mapOwnerRequest),
                response.removedNotice
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `GET /api/participant/request/:id` — one of the participant's own
    /// ongoing requests. The backend answers a non-owner, a nonexistent id and
    /// a request that is no longer ongoing with the same `404`, which surfaces
    /// here as a decoded `REQUEST_NOT_FOUND` — never as evidence about whose
    /// request it was.
    func fetchOwnerRequest(id: String, participantAuthority: String) async throws -> OwnerRequest {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        do {
            let response: OwnerRequestDetailResponseDTO = try await client.send(
                path: "/api/participant/request/\(id)",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            try Self.validateResponseRequestID(response.request.id, expected: id)
            return try Self.mapOwnerRequest(response.request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - W4-R3 requester placed-order continuation

    /// Reconstructs the complete current placed-order set for one verified
    /// participant. The result uses the shared R5 request model for cards;
    /// placement-only fields remain in `PlacedOrder`.
    func fetchPlacedOrders(
        participantAuthority: String,
        monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async throws -> [PlacedOrder] {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        do {
            let response: PlacedOrderListResponseDTO = try await client.send(
                path: "/api/participant/placed-orders",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            // A row missing its H1a order number violates the placement
            // invariant, so fail the read rather than hide a partial list.
            return try response.orders.map {
                try Self.mapPlacedOrder($0, serverNow: response.serverNow, monotonicNow: monotonicNow)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// Reads one exact placed order, including confirmed state for safe
    /// reconciliation. A navigation snapshot is never treated as authority.
    func fetchPlacedOrder(
        id: String,
        participantAuthority: String,
        monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async throws -> PlacedOrderDetail {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        do {
            let response: PlacedOrderDetailResponseDTO = try await client.send(
                path: "/api/participant/placed-orders/\(id)",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            try Self.validateResponseRequestID(response.order.id, expected: id)
            let order = try Self.mapPlacedOrder(
                response.order,
                serverNow: response.serverNow,
                monotonicNow: monotonicNow
            )
            guard let pickupDTO = response.order.pickupConfirmation else {
                throw Self.malformedResponse("Placed-order detail omitted pickup state")
            }
            let pickup: PlacedOrderPickupConfirmation
            switch pickupDTO.status {
            case .pending:
                guard pickupDTO.confirmedAt == nil else {
                    throw Self.malformedResponse("Pending pickup carried a confirmation timestamp")
                }
                pickup = .pending
            case .confirmed:
                guard let confirmedAt = pickupDTO.confirmedAt else {
                    throw Self.malformedResponse("Confirmed pickup omitted its timestamp")
                }
                pickup = .confirmed(confirmedAt)
            }
            return PlacedOrderDetail(
                placedOrder: order,
                pickupConfirmation: pickup,
                contactHelperEmail: response.order.contactHelperEmail
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// Fetches H1a bytes on demand. The private route returns no URL or cache
    /// handle, and the client accepts only the two persisted image types.
    func fetchPlacedOrderEvidence(
        requestID: String,
        participantAuthority: String
    ) async throws -> PlacedOrderEvidence {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        do {
            let response = try await client.sendData(
                path: "/api/participant/placed-orders/\(requestID)/evidence",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            let mimeType = response.contentType?
                .split(separator: ";", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard let mimeType,
                  mimeType == "image/jpeg" || mimeType == "image/png",
                  !response.data.isEmpty else {
                throw Self.malformedResponse("Placed-order evidence response was not an image")
            }
            return PlacedOrderEvidence(data: response.data, mimeType: mimeType)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// The requester's contact address, offered to the placing helper only
    /// while the exchange is active. Any refusal (404) means no contact.
    func fetchHelperPlacementContact(
        requestID: String,
        participantAuthority: String
    ) async throws -> String {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        struct ContactDTO: Decodable { let contactRequesterEmail: String }
        do {
            let response: ContactDTO = try await client.send(
                path: "/api/participant/helper-placements/\(requestID)/contact",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            return response.contactRequesterEmail
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// The requester's contact address, offered to the helper holding the
    /// live reservation only. Any refusal (404) means no contact.
    func fetchHelperReservationContact(
        requestID: String,
        participantAuthority: String
    ) async throws -> String {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        struct ContactDTO: Decodable { let contactRequesterEmail: String }
        do {
            let response: ContactDTO = try await client.send(
                path: "/api/participant/active-reservation/\(requestID)/contact",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            return response.contactRequesterEmail
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// The mutation has no body or client timestamp. Any unusable success
    /// response is an uncertain outcome and must be reconciled by the store.
    func confirmPlacedOrderPickup(
        requestID: String,
        participantAuthority: String
    ) async throws -> Date {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        do {
            let response: PickupConfirmationResponseDTO = try await client.send(
                path: "/api/participant/placed-orders/\(requestID)/pickup-confirmation",
                method: .post,
                headers: Self.participantHeaders(participantAuthority)
            )
            try Self.validateResponseRequestID(response.requestId, expected: requestID)
            guard response.pickupConfirmation.status == .confirmed,
                  let confirmedAt = response.pickupConfirmation.confirmedAt else {
                throw Self.malformedResponse("Pickup mutation did not confirm the request")
            }
            return confirmedAt
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request/:id/withdraw` under one exact operation identity.
    ///
    /// Returns normally only for a decoded `withdrawn` outcome for this exact
    /// request. A definitive backend refusal is thrown as a decoded
    /// `.serverError`. Anything that leaves the outcome unknown — transport
    /// loss after the body may have been sent, a timeout, an undecodable answer,
    /// an unclassified 5xx, a cancellation after dispatch — is
    /// `.ambiguousUpdateOutcome`, and is recovered only by replaying the same
    /// `operationId`.
    func withdrawRequest(
        id: String,
        operationId: String,
        participantAuthority: String,
        operationLedger: String? = nil
    ) async throws {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        let response: WithdrawResponseDTO = try await sendUpdate(
            path: "/api/request/\(id)/withdraw",
            body: EmptyBody(),
            operationId: operationId,
            participantAuthority: participantAuthority,
            operationLedger: operationLedger
        )
        guard response.outcome == "withdrawn", response.requestId == id else {
            throw RequestServiceError.ambiguousUpdateOutcome(
                underlying: RequestServiceError.notFound
            )
        }
    }

    /// `POST /api/request/:id/edit` under one exact operation identity. Same
    /// ambiguity discipline as `withdrawRequest`.
    func editRequest(
        id: String,
        payload: EditRequestPayload,
        operationId: String,
        participantAuthority: String,
        operationLedger: String? = nil
    ) async throws -> EditOutcome {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        let response: EditResponseDTO = try await sendUpdate(
            path: "/api/request/\(id)/edit",
            body: payload,
            operationId: operationId,
            participantAuthority: participantAuthority,
            operationLedger: operationLedger
        )
        do {
            guard response.outcome == "edited", response.resultingRevision >= 1 else {
                throw RequestServiceError.notFound
            }
            let current = try response.request.map { dto -> OwnerRequest in
                try Self.validateResponseRequestID(dto.id, expected: id)
                return try Self.mapOwnerRequest(dto)
            }
            return EditOutcome(resultingRevision: response.resultingRevision, request: current)
        } catch {
            throw RequestServiceError.ambiguousUpdateOutcome(underlying: error)
        }
    }

    /// The one POST path for both mutations, classifying every failure as
    /// definitive or ambiguous in one place so Edit and Withdraw cannot drift.
    private func sendUpdate<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        operationId: String,
        participantAuthority: String,
        operationLedger: String?
    ) async throws -> Response {
        try Task.checkCancellation()

        var headers = Self.participantHeaders(participantAuthority)
        headers[Self.operationIdentityHeader] = operationId
        if let operationLedger {
            headers[Self.operationAuthorityHeader] = operationLedger
        }

        do {
            return try await client.send(
                path: path,
                method: .post,
                body: body,
                headers: headers
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousUpdateOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            // A non-envelope 404 is definitive at the HTTP level: the route does
            // not exist at this base URL, so nothing was written.
            case .unexpectedStatus(404):
                throw RequestServiceError.notFound
            // A decoded envelope is a decided answer, except the two codes the
            // backend uses for "could not classify after the gate".
            case .apiError(let code, let message):
                if RequestUpdateErrorCode.isAmbiguousUpdateCode(code) {
                    throw RequestServiceError.ambiguousUpdateOutcome(underlying: error)
                }
                throw RequestServiceError.serverError(code: code, message: message)
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousUpdateOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }
    }

    private static func mapPlacedOrder(
        _ dto: PlacedOrderResponseDTO,
        serverNow: Date,
        monotonicNow: TimeInterval
    ) throws -> PlacedOrder {
        let validOrderNumber = dto.orderNumber.map { value in
            let bytes = value.utf8
            return (1...50).contains(bytes.count) &&
                bytes.allSatisfy { (48...57).contains($0) }
        } ?? false
        guard dto.status == .placed, dto.isOwnRequest,
              let orderNumber = dto.orderNumber, validOrderNumber else {
            throw malformedResponse("Placed-order read returned an invalid owner state")
        }
        let spot = SupportedVendorCatalog.diningSpots.first { $0.name == dto.vendor }
            ?? DiningSpot(name: dto.vendor, address: nil)
        let request = FoodRequest(
            id: dto.id,
            diningSpot: spot,
            foodDescription: dto.food,
            pickupWindowText: dto.pickupWindowText,
            mealSwipes: dto.mealSwipes,
            resource: RequestResource(
                menuPath: dto.menuPath.domainMenuPath,
                mealItems: dto.mealItems,
                orderDetails: dto.orderDetails,
                estimatedDiningDollarsCents: dto.estimatedDiningDollarsCents
            ),
            windowStart: dto.windowStart,
            windowEnd: dto.windowEnd,
            createdAt: dto.createdAt,
            expiresAt: dto.expiresAt,
            status: .placed,
            ownership: .own
        )
        return PlacedOrder(
            request: request,
            orderNumber: orderNumber,
            etaText: dto.etaText,
            placedAt: dto.placedAt,
            estimatedReadyAt: dto.estimatedReadyAt,
            homeVisibleUntil: dto.homeVisibleUntil,
            serverNow: serverNow,
            monotonicReadAt: monotonicNow
        )
    }

    private static func malformedResponse(_ description: String) -> RequestServiceError {
        .transport(
            underlying: APIClientError.decoding(
                DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: description)
                )
            )
        )
    }

    private static func mapOwnerRequest(_ dto: OwnerRequestResponseDTO) throws -> OwnerRequest {
        let phase: OwnerRequestPhase
        switch dto.phase {
        case .scheduled: phase = .scheduled
        case .available: phase = .available
        case .reserved: phase = .reserved
        }
        let request = FoodRequest(
            id: dto.id,
            diningSpot: DiningSpot(name: dto.vendor, address: nil),
            foodDescription: dto.food,
            pickupWindowText: dto.pickupWindowText,
            mealSwipes: dto.mealSwipes,
            resource: RequestResource(
                menuPath: dto.menuPath.domainMenuPath,
                mealItems: dto.mealItems,
                orderDetails: dto.orderDetails,
                estimatedDiningDollarsCents: dto.estimatedDiningDollarsCents
            ),
            windowStart: dto.windowStart,
            windowEnd: dto.windowEnd,
            createdAt: dto.createdAt,
            expiresAt: dto.expiresAt,
            // The owner DTO carries no status; `.claimed` only while a helper
            // holds it, so a reserved request is never presented as open.
            status: phase == .reserved ? .claimed : .open,
            // The backend resolved this list from the requester binding of the
            // authority presented, so every row is that participant's own.
            ownership: .own
        )
        return OwnerRequest(
            request: request,
            phase: phase,
            contentRevision: dto.contentRevision,
            canEdit: dto.canEdit,
            canWithdraw: dto.canWithdraw,
            latestScheduledStart: dto.latestScheduledStart
        )
    }

    /// Participant-aware `GET /api/request/:id` (W3-H2 stale detail Reserve
    /// truth). Reports whether the verified participant behind
    /// `participantAuthority` already holds a durable one-successful-
    /// participation record for this exact request, so a detail screen
    /// reached through stale navigation can withdraw its Reserve affordance
    /// instead of only discovering the refusal after a tap.
    ///
    /// Deliberately separate from `fetchRequest` above: that method's two
    /// existing callers (ambiguous-fulfillment confirmation and helper
    /// notification tap-routing) need no participation truth, and must not
    /// gain a dependency on this field's presence or decoding.
    func fetchAlreadyParticipated(
        id: String,
        participantAuthority: String
    ) async throws -> Bool {
        guard !participantAuthority.isEmpty else {
            throw RequestServiceError.participantAuthorityRequired
        }
        do {
            let response: RequestDetailResponseDTO = try await client.send(
                path: "/api/request/\(id)",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            try Self.validateResponseRequestID(response.request.id, expected: id)
            return response.alreadyParticipated ?? false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `GET /api/public-actions`
    ///
    /// Returns the backend's pause decision for public mutations. Read-only
    /// and ungated, so it is safe to call before the requester has entered
    /// anything. This method does not decide the fail-closed policy — it
    /// reports success or throws, and the caller treats any failure as
    /// "posting unavailable".
    func fetchPublicActionsPaused() async throws -> Bool {
        do {
            let response: PublicActionsStateDTO = try await client.send(
                path: "/api/public-actions",
                method: .get
            )
            return response.paused
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request`
    ///
    /// The requester is the verified participant behind `participantAuthority`,
    /// not the payload: the backend derives and binds identity from the
    /// credential and ignores any address the payload happens to carry.
    ///
    /// `operationId`, when present, is the W3-D1 exact logical-operation
    /// identity (`RequestStore` mints and reuses it across every recovery
    /// attempt for one intentional submission). `nil` sends no identity header
    /// at all and gets the exact pre-D1, non-idempotent create behavior — this
    /// default exists so a caller with no operation concept (a direct
    /// `RequestService` test) does not have to invent one.
    ///
    /// Generic over the body only so W3-D1 recovery can replay a pre-R4
    /// pending operation with its exact original body
    /// (`LegacyCreateRequestPayload`); every new create sends
    /// `CreateRequestPayload`.
    ///
    /// `operationLedger` (W4-D2) is the ledger authority the pending operation
    /// recorded. When present, only a backend holding exactly that ledger will
    /// read or create under `operationId`; any other answers
    /// `OPERATION_AUTHORITY_MISMATCH` before touching its ledger.
    func createRequest<Payload: Encodable>(
        _ payload: Payload,
        operationId: String? = nil,
        participantAuthority: String? = nil,
        operationLedger: String? = nil
    ) async throws -> FoodRequest {
        try Task.checkCancellation()

        var headers = Self.participantHeaders(participantAuthority)
        if let operationId {
            headers[Self.operationIdentityHeader] = operationId
        }
        if let operationLedger {
            headers[Self.operationAuthorityHeader] = operationLedger
        }

        let response: RequestDetailResponseDTO
        do {
            response = try await client.send(
                path: "/api/request",
                method: .post,
                body: payload,
                headers: headers
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousCreateOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            // A 404 is definitive at the HTTP level: this route does not exist
            // at this base URL, so nothing was created. Classifying it as
            // ambiguous would lock request creation for the rest of the
            // process over a misconfigured host or an unmounted route.
            case .unexpectedStatus(404):
                throw RequestServiceError.notFound
            // Everything else that reaches here is genuinely indeterminate:
            // transport loss or a timeout after the body may already have been
            // sent, an undecodable success body, or a status whose response
            // does not prove that no write occurred. An unreadable 5xx stays
            // ambiguous — being an error is not proof of a rollback.
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousCreateOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        do {
            let request = try Self.mapPublicRequest(response.request, ownership: .unresolved)
            try Self.validateResponseStatus(request.status, expected: .open)
            return request
        } catch {
            throw RequestServiceError.ambiguousCreateOutcome(underlying: error)
        }
    }

    /// W4-D2: where this service sends request-create operations — the
    /// normalized configured base URL (scheme, host, effective port, and path;
    /// never credentials, query, or fragment). Only half of an operation
    /// authority: the same origin can front a reset or replaced ledger, which
    /// `fetchOperationLedger()` distinguishes.
    var operationAuthorityOrigin: String {
        Self.operationAuthorityOrigin(for: client.configuration.baseURL)
    }

    static func operationAuthorityOrigin(for baseURL: URL) -> String {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            // Not a usable network origin; this still never matches a
            // well-formed origin recorded by another configuration.
            return baseURL.absoluteString
        }
        let port = components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(renderedHost):\(port)\(path)"
    }

    /// `GET /api/request-operation/authority` (W4-D2).
    ///
    /// The identity of the operation ledger behind this service right now. A
    /// create records it before transmission and sends it with the create;
    /// recovery compares it with what was recorded. Anything but a
    /// well-formed identity throws: no ledger is ever assumed.
    func fetchOperationLedger() async throws -> String {
        do {
            let response: RequestOperationAuthorityResponseDTO = try await client.send(
                path: "/api/request-operation/authority",
                method: .get
            )
            guard RequestOperationAuthorityIdentity.isValidLedger(response.operationAuthority) else {
                throw APIClientError.decoding(
                    DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "Malformed operation ledger identity")
                    )
                )
            }
            return response.operationAuthority
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request-operation/terminal` (W4-D2).
    ///
    /// Asks backend authority for the one terminal outcome of the exact
    /// operation `operationId`, establishing terminal NO-CREATE when nothing
    /// has created it — only in the ledger `operationLedger` names, which the
    /// backend enforces. Sends no request content. Every thrown error means the
    /// outcome was not established by this call: a decoded envelope stays a
    /// `.serverError` for the caller to classify, and everything else —
    /// transport loss, an unreadable or unrecognized answer, a bare 404 — is
    /// inconclusive. Never retried here.
    func reconcileRequestOperationTerminal(
        operationId: String,
        participantAuthority: String,
        operationLedger: String
    ) async throws -> RequestOperationTerminalOutcome {
        var headers = Self.participantHeaders(participantAuthority)
        headers[Self.operationIdentityHeader] = operationId
        headers[Self.operationAuthorityHeader] = operationLedger
        do {
            let response: RequestOperationTerminalResponseDTO = try await client.send(
                path: "/api/request-operation/terminal",
                method: .post,
                headers: headers
            )
            switch response.outcome {
            case .notCreated:
                guard response.request == nil else {
                    throw APIClientError.decoding(
                        DecodingError.dataCorrupted(
                            .init(codingPath: [], debugDescription: "A not-created outcome carried a request")
                        )
                    )
                }
                return .notCreated
            case .created:
                guard let dto = response.request else {
                    throw APIClientError.decoding(
                        DecodingError.dataCorrupted(
                            .init(codingPath: [], debugDescription: "A created outcome carried no request")
                        )
                    )
                }
                // Any current lifecycle status is authoritative here: the
                // explicit outcome, not the request's present status, says
                // this operation created it.
                return .created(try Self.mapPublicRequest(dto, ownership: .unresolved))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request/:id/claim`
    ///
    /// The reservation is bound to the verified participant behind
    /// `participantAuthority`, and fulfillment later reuses that binding rather
    /// than asking for a helper address.
    func claimRequest(
        id: String,
        participantAuthority: String? = nil
    ) async throws -> ClaimOutcome {
        try Task.checkCancellation()

        let response: ClaimResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/claim",
                method: .post,
                body: EmptyBody(),
                headers: Self.participantHeaders(participantAuthority)
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousClaimOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            // A readable claim INTERNAL_FAILURE does not prove the conditional
            // mutation was rejected: MongoDB may have applied it before the
            // driver lost its acknowledgement. The one-time credentials then
            // cannot be reconstructed, so preserve the existing no-retry
            // ambiguous-claim recovery rather than inviting another claim.
            case .apiError(let code, _) where code == ClaimErrorCode.internalFailure:
                throw RequestServiceError.ambiguousClaimOutcome(underlying: error)
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousClaimOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        do {
            try Self.validateResponseRequestID(response.request.id, expected: id)
            let request = try Self.mapPublicRequest(response.request, ownership: .unresolved)
            try Self.validateResponseStatus(request.status, expected: .claimed)
            guard !response.claim.claimToken.isEmpty else {
                throw APIClientError.decoding(
                    DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "Claim response did not include usable authorization")
                    )
                )
            }
            return ClaimOutcome(
                request: request,
                claimToken: response.claim.claimToken,
                claimExpiresAt: response.claim.claimExpiresAt
            )
        } catch {
            throw RequestServiceError.ambiguousClaimOutcome(underlying: error)
        }
    }

    /// `POST /api/request/:id/claim/extend`
    ///
    /// Proves claim ownership by submitting the raw token the winning claim
    /// returned. Only one extension is ever granted, so a failed or
    /// unconfirmed attempt is never retried here — an outcome iOS cannot
    /// validate is reported as `ambiguousExtensionOutcome` so the caller keeps
    /// its current expiration rather than assuming five more minutes.
    func extendClaim(id: String, claimToken: String) async throws -> ClaimExtensionOutcome {
        try Task.checkCancellation()

        let response: ClaimExtensionResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/claim/extend",
                method: .post,
                body: ClaimExtensionPayload(claimToken: claimToken)
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousExtensionOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousExtensionOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        return ClaimExtensionOutcome(
            claimExpiresAt: response.claim.claimExpiresAt,
            claimExtendedAt: response.claim.claimExtendedAt
        )
    }

    /// `POST /api/request/:id/claim/extend`, authorizing with verified
    /// participant authority instead of the raw claim token (W3-H1
    /// continuation) — for the case the raw token is gone after termination
    /// and relaunch. An empty JSON object body plus the credential header is
    /// the accepted second request shape the backend authorizes.
    func extendClaim(id: String, participantAuthority: String) async throws -> ClaimExtensionOutcome {
        try Task.checkCancellation()

        let response: ClaimExtensionResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/claim/extend",
                method: .post,
                body: EmptyBody(),
                headers: Self.participantHeaders(participantAuthority)
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousExtensionOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousExtensionOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        return ClaimExtensionOutcome(
            claimExpiresAt: response.claim.claimExpiresAt,
            claimExtendedAt: response.claim.claimExtendedAt
        )
    }

    /// `POST /api/request/:id/claim/release` (W3-H1), authorizing with the raw
    /// claim token. Safe to retry: a repeated release of an already-released
    /// or otherwise-ended claim is refused, never duplicated, so an outcome
    /// iOS cannot confirm needs no ambiguity recovery of its own — the caller
    /// simply leaves its local claim state untouched and may try again.
    func releaseClaim(id: String, claimToken: String) async throws {
        try Task.checkCancellation()
        do {
            let response: ReleaseResponseDTO = try await client.send(
                path: "/api/request/\(id)/claim/release",
                method: .post,
                body: ClaimExtensionPayload(claimToken: claimToken)
            )
            try Self.validateConfirmedRelease(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request/:id/claim/release`, authorizing with verified
    /// participant authority instead of the raw claim token (W3-H1
    /// continuation).
    func releaseClaim(id: String, participantAuthority: String) async throws {
        try Task.checkCancellation()
        do {
            let response: ReleaseResponseDTO = try await client.send(
                path: "/api/request/\(id)/claim/release",
                method: .post,
                body: EmptyBody(),
                headers: Self.participantHeaders(participantAuthority)
            )
            try Self.validateConfirmedRelease(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request/:id/claim/release` for the one suspended-helper
    /// question authorized by `active-reservation`. Returns the backend's
    /// release fact: `false` after Yes preserves Helping; `true` after No
    /// releases it. Ordinary Stop continues through the empty-body methods.
    func answerStopOrderQuestion(
        id: String,
        participantAuthority: String,
        externalOrderPlaced: Bool
    ) async throws -> Bool {
        try Task.checkCancellation()
        do {
            let response: ReleaseResponseDTO = try await client.send(
                path: "/api/request/\(id)/claim/release",
                method: .post,
                body: StopOrderQuestionPayload(externalOrderPlaced: externalOrderPlaced),
                headers: Self.participantHeaders(participantAuthority)
            )
            guard response.released == !externalOrderPlaced else {
                throw APIClientError.decoding(
                    DecodingError.dataCorrupted(
                        .init(
                            codingPath: [],
                            debugDescription: "Stop answer did not confirm its expected reservation outcome"
                        )
                    )
                )
            }
            return response.released
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `GET /api/participant/active-reservation` (W3-H1 continuation,
    /// extended by W3-H2 fulfillment re-entry).
    ///
    /// Resolves the verified participant's current active reservation from
    /// backend truth; when they hold none, the same read additionally
    /// resolves whether they most recently placed a still-existing request.
    /// W4-H1 uses that placed answer as a safety read only: a relaunched
    /// client reconciles it to helper-available state and reconstructs no
    /// success presentation. Never fabricates either from local
    /// state — only a confirmed backend answer, or a thrown error the caller
    /// must treat as "truth not established", is returned.
    func fetchParticipantReservationState(
        participantAuthority: String,
        monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async throws -> ParticipantReservationRead {
        try Task.checkCancellation()

        let response: ActiveReservationResponseDTO
        do {
            response = try await client.send(
                path: "/api/participant/active-reservation",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }

        if let reservation = response.reservation {
            let request = try Self.mapPublicRequest(reservation.request, ownership: .unresolved)
            return ParticipantReservationRead(
                state: .reservation(ActiveReservationOutcome(
                    request: request,
                    claimExpiresAt: reservation.claimExpiresAt,
                    claimExtendedAt: reservation.claimExtendedAt,
                    directContactRestricted: reservation.directContactRestricted == true,
                    stopReturnsHome: reservation.stopReturnsHome == true,
                    stopAsksOrderQuestion: reservation.stopAsksOrderQuestion == true
                )),
                placements: try Self.mapPlacements(response, monotonicNow: monotonicNow),
                pickupConfirmedRequestIDs: (response.pickupConfirmations ?? []).map(\.requestId)
            )
        }
        return ParticipantReservationRead(
            state: .none,
            placements: try Self.mapPlacements(response, monotonicNow: monotonicNow),
            pickupConfirmedRequestIDs: (response.pickupConfirmations ?? []).map(\.requestId)
        )
    }

    /// Every placement the helper must still see, keyed by request identity in
    /// the backend's order. `placement` is only the legacy single-value field
    /// of a backend that predates `placements`.
    private static func mapPlacements(
        _ response: ActiveReservationResponseDTO,
        monotonicNow: TimeInterval
    ) throws -> [PlacedReservationOutcome] {
        let details = response.placements ?? response.placement.map { [$0] } ?? []
        var seen = Set<String>()
        return try details.compactMap { placement in
            let request = try mapPublicRequest(placement.request, ownership: .unresolved)
            guard seen.insert(request.id).inserted else { return nil }
            let remaining: TimeInterval?
            if let until = placement.helperVisibleUntil, let serverNow = response.serverNow {
                remaining = until.timeIntervalSince(serverNow)
            } else {
                remaining = nil
            }
            return PlacedReservationOutcome(
                request: request,
                orderNumber: placement.orderNumber,
                etaText: placement.etaText,
                estimatedReadyAt: placement.estimatedReadyAt,
                notificationStatus: placement.notification?.status,
                messageSuppressed: isFilterSuppression(
                    suppressed: placement.messageSuppressed,
                    withheld: placement.messageWithheld
                ),
                helperVisibleRemainingAtRead: remaining,
                monotonicReadAt: monotonicNow
            )
        }
    }

    // MARK: - Participant blocking (W4-U1.3)

    private static func mapBlockedStudent(_ dto: ParticipantBlockDTO) -> BlockedStudent {
        BlockedStudent(
            id: dto.id,
            role: dto.blockedRole == .helper ? .helper : .requester,
            diningLocation: dto.diningLocation,
            interactionAt: dto.interactionAt
        )
    }

    /// `POST /api/request/:id/block`.
    ///
    /// The backend resolves the other party from the request itself; nothing
    /// here names a participant. `externalOrderPlaced` is meaningful only while
    /// the caller holds the live reservation on `id`.
    ///
    /// Idempotent on the backend, but never retried here: an outcome iOS cannot
    /// confirm is `ambiguousBlockOutcome`, and the caller must neither retry it
    /// nor present it as a success or as a release.
    func blockParticipant(
        forRequestID id: String,
        externalOrderPlaced: Bool?,
        participantAuthority: String
    ) async throws -> BlockOutcome {
        try Task.checkCancellation()

        let response: CreateParticipantBlockResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/block",
                method: .post,
                body: CreateParticipantBlockPayload(externalOrderPlaced: externalOrderPlaced),
                headers: Self.participantHeaders(participantAuthority)
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousBlockOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            // A readable INTERNAL_FAILURE does not prove nothing committed.
            case .apiError(let code, _) where code == ClaimErrorCode.internalFailure:
                throw RequestServiceError.ambiguousBlockOutcome(underlying: error)
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousBlockOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        return BlockOutcome(
            student: Self.mapBlockedStudent(response.block),
            reservationReleased: response.reservationReleased,
            reportAuthorization: response.reportAuthorization
        )
    }

    /// `POST /api/request/:id/report`. A report write is never retried here;
    /// an unresolved outcome is reconciled by the owning store.
    func submitParticipantReport(
        requestID: String,
        payload: ParticipantReportSubmissionPayload,
        participantAuthority: String
    ) async throws {
        try Task.checkCancellation()
        do {
            let response: ParticipantReportSubmissionResponseDTO = try await client.send(
                path: "/api/request/\(requestID)/report",
                method: .post,
                body: payload,
                headers: Self.participantHeaders(participantAuthority)
            )
            guard response.outcome == .reported else {
                throw APIClientError.decoding(
                    DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "Report response did not confirm submission")
                    )
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// Reconcile one exact report operation. This endpoint is reconcile-only:
    /// it never sends report content or creates authority.
    func reconcileParticipantReportOperation(
        operationID: String,
        participantAuthority: String
    ) async throws -> ParticipantReportOperationOutcomeDTO {
        try Task.checkCancellation()
        do {
            let response: ParticipantReportOperationResponseDTO = try await client.send(
                path: "/api/participant/report-operations/\(operationID)/reconcile",
                method: .post,
                headers: Self.participantHeaders(participantAuthority)
            )
            return response.outcome
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `GET /api/participant/restriction`; absent is affirmative-only
    /// "not established as restricted", never a server assertion of false.
    func fetchParticipantRestriction(participantAuthority: String) async throws -> Bool {
        try Task.checkCancellation()
        do {
            let response: ParticipantRestrictionResponseDTO = try await client.send(
                path: "/api/participant/restriction",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            return response.restricted == true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `GET /api/participant/blocks` — the caller's own blocks, as context.
    func fetchBlockedStudents(participantAuthority: String) async throws -> [BlockedStudent] {
        try Task.checkCancellation()
        do {
            let response: ParticipantBlockListResponseDTO = try await client.send(
                path: "/api/participant/blocks",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            return response.blocks.map(Self.mapBlockedStudent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `DELETE /api/participant/blocks/:blockId`. Prospective only; the
    /// backend deletes the owner's row and nothing else. Safe to repeat: a
    /// block that is already gone is a definitive `BLOCK_NOT_FOUND`.
    func removeBlockedStudent(id: String, participantAuthority: String) async throws {
        try Task.checkCancellation()
        do {
            let response: RemoveParticipantBlockResponseDTO = try await client.send(
                path: "/api/participant/blocks/\(id)",
                method: .delete,
                headers: Self.participantHeaders(participantAuthority)
            )
            guard response.removed else {
                throw APIClientError.decoding(
                    DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "Unblock was not confirmed")
                    )
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `GET /api/participant/request-eligibility` (W4-Q1).
    ///
    /// Bounded participant-authorized prerequisite for a future
    /// requester-entry eligibility check (R2 UI is not implemented here).
    /// Reports whether the verified participant behind `participantAuthority`
    /// is presently `eligible` or `exhausted` under the existing best-effort
    /// three-per-NYU-campus-day quota — the same shared authority
    /// `POST /api/request` uses as its own final create-time check
    /// (`src/requestDailyQuota.ts`). Advisory and current-as-of-read only: an
    /// `eligible` result never reserves quota and never guarantees a later
    /// `POST /api/request` will succeed.
    func fetchRequestCreationEligibility(
        participantAuthority: String
    ) async throws -> RequestEligibilityWire {
        try Task.checkCancellation()
        do {
            let response: RequestEligibilityResponseDTO = try await client.send(
                path: "/api/participant/request-eligibility",
                method: .get,
                headers: Self.participantHeaders(participantAuthority)
            )
            return response.eligibility
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/request/:id/fulfill`
    /// The helper is whoever the claim is bound to, so this deliberately takes
    /// no address: the backend derives it from the reservation and refuses a
    /// payload that carries one.
    func fulfillRequest(
        id: String,
        claimToken: String,
        orderNumber: String,
        eta: String,
        contactMessage: String?,
        placedOrderScreenshot: PlacedOrderScreenshot
    ) async throws -> FulfillOutcome {
        let payload = FulfillRequestPayload(
            claimToken: claimToken,
            fulfillment: FulfillmentPayload(
                orderNumber: orderNumber,
                eta: eta,
                contactMessage: contactMessage,
                placedOrderScreenshot: PlacedOrderScreenshotPayload(placedOrderScreenshot)
            )
        )
        try Task.checkCancellation()

        let response: FulfillResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/fulfill",
                method: .post,
                body: payload
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            // A readable fulfillment INTERNAL_FAILURE can follow a committed
            // transaction whose acknowledgement was lost. It is therefore not
            // a definitive ordinary failure: retain the original payload for
            // the existing one-read, one-resend ambiguity recovery flow.
            case .apiError(let code, _) where code == ClaimErrorCode.internalFailure:
                throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        do {
            try Self.validateResponseRequestID(response.request.id, expected: id)
            let request = try Self.mapPublicRequest(response.request, ownership: .unresolved)
            try Self.validateResponseStatus(request.status, expected: .placed)
            return FulfillOutcome(
                request: request,
                notificationStatus: response.notification.status,
                messageSuppressed: Self.isFilterSuppression(
                    suppressed: response.messageSuppressed,
                    withheld: response.messageWithheld
                )
            )
        } catch {
            throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
        }
    }

    /// `POST /api/request/:id/fulfill`, authorizing with verified participant
    /// authority instead of the raw claim token (W3-H1 continuation) — for a
    /// reservation restored by `fetchActiveReservation` after the raw token
    /// was already lost to process termination. The backend accepts this as
    /// an additive authorization path and never persists the (never sent)
    /// raw token; see `fulfillRequest(id:claimToken:...)` above for the
    /// still-unchanged in-process path.
    func fulfillRequest(
        id: String,
        participantAuthority: String,
        orderNumber: String,
        eta: String,
        contactMessage: String?,
        placedOrderScreenshot: PlacedOrderScreenshot
    ) async throws -> FulfillOutcome {
        let payload = FulfillContinuationRequestPayload(
            fulfillment: FulfillmentPayload(
                orderNumber: orderNumber,
                eta: eta,
                contactMessage: contactMessage,
                placedOrderScreenshot: PlacedOrderScreenshotPayload(placedOrderScreenshot)
            )
        )
        try Task.checkCancellation()

        let response: FulfillResponseDTO
        do {
            response = try await client.send(
                path: "/api/request/\(id)/fulfill",
                method: .post,
                body: payload,
                headers: Self.participantHeaders(participantAuthority)
            )
        } catch is CancellationError {
            throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            switch error {
            case .apiError(let code, _) where code == ClaimErrorCode.internalFailure:
                throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
            case .transport, .decoding, .unexpectedStatus:
                throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
            default:
                throw Self.translate(error)
            }
        } catch {
            throw Self.translate(error)
        }

        do {
            try Self.validateResponseRequestID(response.request.id, expected: id)
            let request = try Self.mapPublicRequest(response.request, ownership: .unresolved)
            try Self.validateResponseStatus(request.status, expected: .placed)
            return FulfillOutcome(
                request: request,
                notificationStatus: response.notification.status,
                messageSuppressed: Self.isFilterSuppression(
                    suppressed: response.messageSuppressed,
                    withheld: response.messageWithheld
                )
            )
        } catch {
            throw RequestServiceError.ambiguousFulfillmentOutcome(underlying: error)
        }
    }

    // MARK: - Mapping

    private static func validateResponseRequestID(_ responseID: String, expected requestID: String) throws {
        guard responseID == requestID else {
            throw APIClientError.decoding(
                DecodingError.dataCorrupted(
                    .init(
                        codingPath: [],
                        debugDescription: "Response request ID does not match the requested resource"
                    )
                )
            )
        }
    }

    /// A decoded 2xx body is not itself release truth. Only the backend's
    /// explicit affirmative result permits `RequestStore` to retire the local
    /// reservation; `false` follows the existing ordinary release-failure path.
    private static func validateConfirmedRelease(_ response: ReleaseResponseDTO) throws {
        guard response.released else {
            throw APIClientError.decoding(
                DecodingError.dataCorrupted(
                    .init(
                        codingPath: [],
                        debugDescription: "Release response did not confirm release"
                    )
                )
            )
        }
    }

    private static func validateResponseStatus(_ status: RequestStatus, expected: RequestStatus) throws {
        guard status.rawValue == expected.rawValue else {
            throw APIClientError.decoding(
                DecodingError.dataCorrupted(
                    .init(
                        codingPath: [],
                        debugDescription: "Response lifecycle status \(status.rawValue) does not match expected status \(expected.rawValue)"
                    )
                )
            )
        }
    }

    /// Maps a public `RequestResponseDTO` (list/detail/create/claim/fulfill's
    /// embedded `request`) to the canonical domain model. Never fabricates
    /// requester-private fields (`email`, `phoneNumber`) — the public wire
    /// shape never carries them, and `FoodRequest` has no properties in which
    /// to store them. Pickup name is not among them because W4-R4 removed it
    /// from the request contract entirely.
    ///
    /// An unrecognized wire status value throws (via `RequestStatusWire`'s
    /// `Decodable` conformance failing at decode time) rather than silently
    /// mapping to an incorrect lifecycle state.
    /// `ownership` is required rather than defaulted (W4-H2): only a caller
    /// that knows the response actually carries current-authority
    /// caller-relative ownership may claim a resolved answer. Every other
    /// endpoint must pass `.unresolved`, so an absent `isOwnRequest` on a
    /// response shape that never derives ownership can no longer become an
    /// actionable "not own".
    private static func mapPublicRequest(
        _ dto: RequestResponseDTO,
        ownership: RequestOwnership
    ) throws -> FoodRequest {
        return FoodRequest(
            id: dto.id,
            diningSpot: DiningSpot(name: dto.vendor, address: nil),
            foodDescription: dto.food,
            pickupWindowText: dto.pickupWindowText,
            mealSwipes: dto.mealSwipes,
            // W4-R4: the structured representation exactly as the backend
            // projected it. Passed explicitly at this one mapping site — the
            // sole production decode path — so no surface ever sees the
            // `.unspecified` placeholder `FoodRequest.init` defaults to.
            resource: RequestResource(
                menuPath: dto.menuPath.domainMenuPath,
                mealItems: dto.mealItems,
                orderDetails: dto.orderDetails,
                estimatedDiningDollarsCents: dto.estimatedDiningDollarsCents
            ),
            windowStart: dto.windowStart,
            windowEnd: dto.windowEnd,
            createdAt: dto.createdAt,
            expiresAt: dto.expiresAt,
            status: dto.status.domainStatus,
            ownership: ownership,
            contentRevision: dto.contentRevision
        )
    }

    /// Ownership as answered by a route that genuinely derives it
    /// (`GET /api/requests`, `GET /api/request/:id`).
    ///
    /// Deliberately *not* `dto.isOwnRequest ?? false`: field absence is
    /// "unknown", never "not yours".
    ///
    /// - Field `true`/`false` → the server resolved the presented authority
    ///   and stated the answer.
    /// - Field absent → the server could not resolve the presented authority
    ///   into an ownership answer. Ownership is unknown; fail closed.
    ///
    /// Both ordinary reads now require a credential (W4-R5), so there is no
    /// anonymous reading of an absent field.
    private static func resolvedOwnership(_ dto: RequestResponseDTO) -> RequestOwnership {
        switch dto.isOwnRequest {
        case .some(true): return .own
        case .some(false): return .notOwn
        case .none: return .unresolved
        }
    }

    /// Translates a client/transport failure into the product-safe error surface.
    /// A decoded error envelope is passed through as `.serverError(code:message:)`
    /// verbatim, and only a non-envelope HTTP 404 (unambiguous regardless of code
    /// string) maps to a dedicated case. Mapping stable codes to copy and
    /// recovery is the presentation layer's job, not this one's.
    private static func translate(_ error: Error) -> RequestServiceError {
        guard let clientError = error as? APIClientError else {
            return .transport(underlying: error)
        }

        switch clientError {
        case .apiError(let code, let message):
            return .serverError(code: code, message: message)
        case .unexpectedStatus(let statusCode):
            if statusCode == 404 {
                return .notFound
            }
            return .transport(underlying: clientError)
        case .encoding, .decoding, .invalidURL:
            return .transport(underlying: clientError)
        case .transport(let underlying):
            return .transport(underlying: underlying)
        }
    }
}

/// Empty JSON body for POSTs (e.g. claim) that carry no request payload.
private struct EmptyBody: Encodable {}
