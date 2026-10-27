//
//  RequestDTOs.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Wire-level types for the request domain, per docs/system-contract.md.
// These decode/encode exactly what the backend contracts define. DTO-to-domain
// mapping (RequestResponseDTO -> FoodRequest) belongs to RequestService, not here.
import Foundation

// MARK: - Wire status

/// Persisted lifecycle vocabulary. Unknown values fail decoding rather than
/// being mapped to a guessed state.
enum RequestStatusWire: String, Decodable {
    case open
    case claimed
    case placed
    /// W4-R5: terminal for the request. Only the single-request detail read can
    /// report it; the list never advertises a withdrawn request.
    case withdrawn

    var domainStatus: RequestStatus {
        switch self {
        case .open: return .open
        case .claimed: return .claimed
        case .placed: return .placed
        case .withdrawn: return .withdrawn
        }
    }
}

/// Wire-level timing value accepted by `POST /api/request`. `Codable` (not
/// just `Encodable`) so it can round-trip through the W3-D1 durable
/// pending-operation record (`PendingRequestOperationStorage.swift`); nothing
/// about outbound encoding changes.
enum RequestTimingWire: String, Codable {
    case asap
    case scheduled
}

// MARK: - Public request

/// W4-R4 menu path. Exactly one of these describes how a request is paid
/// for. An unrecognized value fails decoding rather than being mapped to a
/// guessed path, matching `RequestStatusWire`.
enum RequestMenuPathWire: String, Codable {
    case mealExchange = "meal-exchange"
    case diningDollars = "dining-dollars"

    var domainMenuPath: RequestMenuPath {
        switch self {
        case .mealExchange: return .mealExchange
        case .diningDollars: return .diningDollars
        }
    }

    init(_ menuPath: RequestMenuPath) {
        switch menuPath {
        case .mealExchange: self = .mealExchange
        case .diningDollars: self = .diningDollars
        }
    }
}

/// Public request shape returned by list/detail/create/claim/fulfill.
/// Must never include requester email, claim token/hash, claim expiration, or
/// internal Mongo fields. Pickup name is not merely excluded here — since
/// W4-R4 it does not exist anywhere in the request contract.
struct RequestResponseDTO: Decodable {
    let id: String
    let vendor: String
    /// The backend-derived single-line summary of the structured fields
    /// below. Retained because every already-accepted helper surface renders
    /// it; it is never composed on this side.
    let food: String
    let pickupWindowText: String
    /// V1 meal-swipe requirement (W3-C1), widened to 0-5 by W4-R4 so a
    /// Dining-Dollars-only request can state that it needs none. Every shape
    /// `POST /api/request` accepts, including the legacy web one, has
    /// required an integer since that slice, so the backend always returns
    /// it; decoding fails on a response that omits it rather than this app
    /// fabricating a value.
    let mealSwipes: Int
    /// W4-R4 structured representation. Required for the same reason
    /// `mealSwipes` is: every accepted create shape supplies it, so a
    /// response omitting it is a malformed/pre-R4 stored row rather than a
    /// supported outcome, and this app must not invent a path for it.
    let menuPath: RequestMenuPathWire
    /// One entry per selected swipe on the Meal Exchange path; empty on a
    /// Dining-Dollars-only request.
    let mealItems: [MealItem]
    /// The single structured order-details value on a Dining-Dollars-only
    /// request; `nil` on a Meal Exchange one.
    let orderDetails: String?
    /// The requester's Dining Dollar estimate in exact cents — never a
    /// floating-point amount. `nil` means the requester needed none, which is
    /// deliberately distinct from `0`.
    let estimatedDiningDollarsCents: Int?
    let windowStart: Date?
    let windowEnd: Date?
    let status: RequestStatusWire
    let createdAt: Date
    let expiresAt: Date
    /// W4-H2 participant-scoped ownership projection. Present and `true` only
    /// on a list fetch made with a verified participant credential, on
    /// exactly that participant's own request; absent for every other
    /// request and every other caller, including anonymous browsing —
    /// matching `alreadyParticipated`'s existing affirmative-only shape.
    /// `nil` for every response shape that never carries it (detail, create,
    /// claim, fulfill), which `decodeIfPresent` tolerates.
    let isOwnRequest: Bool?
    /// W4-R5 content revision, stated by the single-request detail read only.
    /// `nil` for every other shape. Opaque: it is compared with the revision a
    /// notification carried, never interpreted.
    var contentRevision: Int? = nil
}

// MARK: - Response wrappers

struct RequestListResponseDTO: Decodable {
    let requests: [RequestResponseDTO]
}

/// Shared shape for single-request responses: detail fetch and create both
/// return `{ request: {...} }`. `alreadyParticipated` (W3-H2 stale detail
/// Reserve truth) is present and `true` only on a detail fetch made with a
/// verified participant credential that already holds a durable
/// one-successful-participation record for this exact request; absent for
/// every other caller, including anonymous browsing and `POST /api/request`'s
/// own reuse of this same wrapper shape, which `decodeIfPresent` tolerates.
struct RequestDetailResponseDTO: Decodable {
    let request: RequestResponseDTO
    let alreadyParticipated: Bool?
}

/// `GET /api/public-actions` → `{ "paused": boolean }`. Read-only and ungated.
/// It carries the pause decision and no configuration detail beyond it.
struct PublicActionsStateDTO: Decodable {
    let paused: Bool
}

// MARK: - Create

/// Payload for `POST /api/request`. Must never include backend-owned
/// lifecycle fields (id, status, createdAt, expiresAt, claim/fulfillment fields).
///
/// `installationCredential` (Week 3 Day 6 Slice 6E) is the app's existing,
/// stable installation credential — the same value `InstallationPushService`
/// sends — carried so the backend can resolve/establish the originating
/// installation for a later best-effort requester-fulfillment push. It is
/// notification-routing identity only, never push permission or push state,
/// and `RequestFoodView.makePayload` never sets it: `RequestStore.createRequest`
/// fills it in from the store's own installation-credential provider
/// immediately before sending, so this field defaults to absent for every
/// existing caller and test that constructs a payload directly.
/// `windowStart` is the only timing value this app sends, and only on a
/// scheduled request: it is the instant helpers begin seeing the request, and
/// the backend derives the expiration from it. There is deliberately no
/// `windowEnd` — the create shape is strict and would refuse one, because an
/// end the requester did not choose is not theirs to state.
///
/// There is also deliberately no `email` (W3-I1). The requester is the verified
/// participant behind the credential `RequestStore` attaches, the backend binds
/// the request to that principal, and an address here could only either repeat
/// it or contradict it.
/// W4-R4 additions:
///
/// There is deliberately no `food` and no `pickupName`. The backend derives
/// the single-line summary from the structured fields below, and pickup name
/// was removed from the V1 request contract entirely; the create schemas are
/// `.strict()`, so sending either would be refused.
///
/// `Codable` rather than only `Encodable` (W4-R4) so the complete submitted
/// payload can be frozen verbatim into the W3-D1 durable recovery record and
/// decoded back for replay. That makes exact-payload identity structural: a
/// field added here is carried through recovery automatically, and no
/// separate mirror type can drift out of sync with the payload it is supposed
/// to reproduce.
struct CreateRequestPayload: Codable, Equatable {
    let vendor: String
    let timing: RequestTimingWire
    let windowStart: Date?
    /// W4-R4 menu path. Requester-owned truth: Screenshot Assistance's
    /// deterministic proposal (W4-R4.1) only ever switches the form's selector,
    /// never this payload, and the requester can change it first.
    let menuPath: RequestMenuPathWire
    /// V1 meal-swipe requirement (W3-C1), widened to 0-5 by W4-R4: an exact
    /// integer chosen from `RequestFoodView`'s bounded control, 1 through 5
    /// on the Meal Exchange path and exactly 0 on the Dining-Dollars-only
    /// one. Always sent — the backend's canonical iOS schemas require it — so
    /// this app can never construct a value outside that bounded set.
    let mealSwipes: Int
    /// Exactly one entry per selected swipe, in the requester's own order.
    /// A meal field hidden by lowering the swipe count is excluded here by
    /// construction (`RequestFoodView.makePayload`), never sent and then
    /// filtered server-side.
    let mealItems: [MealItem]
    /// Required on the Dining-Dollars-only path, absent on Meal Exchange.
    let orderDetails: String?
    /// Exact cents, never a `Double`: optional on Meal Exchange (absent means
    /// the requester needs none, never a fabricated `$0.00`) and required on
    /// the Dining-Dollars-only path.
    let estimatedDiningDollarsCents: Int?
    /// Store-owned installation identity, filled in by
    /// `RequestStore.createRequest` immediately before sending. Deliberately
    /// excluded from the durable recovery record (see
    /// `PendingRequestOperationRecord`), which is why it is `var` and
    /// defaulted rather than part of the frozen request content.
    var installationCredential: String? = nil
}

// MARK: - Claim

/// Claimant-private half of a successful `POST /api/request/:id/claim`.
/// Deliberately a separate type from `RequestResponseDTO`: these fields exist
/// only in the winning claimant's response and must never be added to the
/// public request DTO, the list DTO, or `FoodRequest`.
///
/// W4-R4 removed `pickupName` from the V1 request contract, so what remains
/// here is the claim authorization itself.
struct ClaimDetailsDTO: Decodable {
    let claimToken: String
    let claimExpiresAt: Date
}

/// Response for `POST /api/request/:id/claim`:
/// `{ request: {...}, claim: { claimToken, claimExpiresAt } }`.
/// The public projection and the private claim object stay separate all the way
/// through the DTO layer.
struct ClaimResponseDTO: Decodable {
    let request: RequestResponseDTO
    let claim: ClaimDetailsDTO
}

// MARK: - Claim extension

/// Payload for `POST /api/request/:id/claim/extend`. The backend rejects any
/// body with more than this one key, so no other field may be added here.
struct ClaimExtensionPayload: Encodable {
    let claimToken: String
}

/// Claim state after the one permitted extension. The response deliberately
/// repeats neither the raw token, the pickup name, nor the request.
struct ClaimExtensionDetailsDTO: Decodable {
    let claimExpiresAt: Date
    let claimExtendedAt: Date
}

/// Response for `POST /api/request/:id/claim/extend` → `{ claim: {...} }`.
struct ClaimExtensionResponseDTO: Decodable {
    let claim: ClaimExtensionDetailsDTO
}

// MARK: - Reservation release/continuation (W3-H1)

/// Response for `POST /api/request/:id/claim/release` → `{ released: true }`.
/// Nothing else is returned: the caller already holds the public request
/// state and clears its own claimant-private state locally on success.
struct ReleaseResponseDTO: Decodable {
    let released: Bool
}

/// The optional body used only for the contract-authorized suspended-helper
/// Stop question. Ordinary Stop continues to send its existing empty body.
struct StopOrderQuestionPayload: Encodable {
    let externalOrderPlaced: Bool
}

/// The claimant-private half of `GET /api/participant/active-reservation`.
/// Deliberately carries no claim token: the raw token is never persisted, so
/// continuation cannot recover it — only participant authority, which
/// `extendClaim`/`releaseClaim` accept as an additive authorization path.
struct ActiveReservationDetailsDTO: Decodable {
    let request: RequestResponseDTO
    let claimExpiresAt: Date
    let claimExtendedAt: Date?
    /// W4-U1.3: present and `true` only when optional direct contact is
    /// unavailable for this reservation. Affirmative-only, like
    /// `isOwnRequest`: absent is "not established", never "available".
    let directContactRestricted: Bool?
    /// W4-U1.3: present and `true` only when a confirmed Stop helping of this
    /// reservation must end at Home, and only while no direct-contact
    /// restriction is reported (that case already ends at Home). Affirmative-
    /// only: absent is "not established", never "ends elsewhere".
    let stopReturnsHome: Bool?
    /// W4-U1.2 FD-1 Option B: ask the suspended-helper Stop question only
    /// when the backend affirmatively includes this field.
    let stopAsksOrderQuestion: Bool?

    private enum CodingKeys: String, CodingKey {
        case request
        case claimExpiresAt
        case claimExtendedAt
        case directContactRestricted
        case stopReturnsHome
        case stopAsksOrderQuestion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let request = try container.decode(RequestResponseDTO.self, forKey: .request)
        guard request.status == .claimed else {
            throw DecodingError.dataCorruptedError(
                forKey: .request,
                in: container,
                debugDescription: "A non-null active reservation must embed a claimed request"
            )
        }

        self.request = request
        claimExpiresAt = try container.decode(Date.self, forKey: .claimExpiresAt)
        claimExtendedAt = try container.decodeIfPresent(Date.self, forKey: .claimExtendedAt)
        directContactRestricted = try container.decodeIfPresent(
            Bool.self,
            forKey: .directContactRestricted
        )
        stopReturnsHome = try container.decodeIfPresent(
            Bool.self,
            forKey: .stopReturnsHome
        )
        stopAsksOrderQuestion = try container.decodeIfPresent(
            Bool.self,
            forKey: .stopAsksOrderQuestion
        )
    }
}

/// The claimant-private half of a W3-H2 fulfillment re-entry read: a request
/// this participant most recently placed, still existing within its
/// retention horizon. `notification` is `nil` when the outcome never settled
/// (mirrors `notificationStatus == nil` in `RequestStore.applyConfirmedFulfillment`)
/// — never guessed as sent or failed.
struct PlacedReservationDetailsDTO: Decodable {
    let request: RequestResponseDTO
    let orderNumber: String
    let etaText: String
    /// Backend instant the order is ready; `nil` until an authoritative read.
    let estimatedReadyAt: Date?
    let notification: NotificationStatusDTO?
    /// W4-R3: backend instant (`estimatedReadyAt` + 1 hour) after which this
    /// helper no longer sees `Waiting for pickup`. Home visibility only.
    let helperVisibleUntil: Date?
    /// W4-U1.1 content-free suppression truth: present and `true` only when
    /// the backend's durable marker proves the helper's optional Message was
    /// suppressed at placement. Affirmative-only like `isOwnRequest`; absent
    /// means "not established as suppressed", never a claim about the Message,
    /// and it carries no Message text at all.
    let messageSuppressed: Bool?
    /// W4-U1.3: affirmative-only refinement; see `FulfillResponseDTO`.
    let messageWithheld: Bool?

    private enum CodingKeys: String, CodingKey {
        case request
        case orderNumber
        case etaText
        case estimatedReadyAt
        case notification
        case helperVisibleUntil
        case messageSuppressed
        case messageWithheld
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let request = try container.decode(RequestResponseDTO.self, forKey: .request)
        guard request.status == .placed else {
            throw DecodingError.dataCorruptedError(
                forKey: .request,
                in: container,
                debugDescription: "A placement re-entry read must embed a placed request"
            )
        }

        self.request = request
        orderNumber = try container.decode(String.self, forKey: .orderNumber)
        etaText = try container.decode(String.self, forKey: .etaText)
        estimatedReadyAt = try container.decodeIfPresent(Date.self, forKey: .estimatedReadyAt)
        notification = try container.decodeIfPresent(NotificationStatusDTO.self, forKey: .notification)
        helperVisibleUntil = try container.decodeIfPresent(Date.self, forKey: .helperVisibleUntil)
        messageSuppressed = try container.decodeIfPresent(Bool.self, forKey: .messageSuppressed)
        messageWithheld = try container.decodeIfPresent(Bool.self, forKey: .messageWithheld)
    }
}

/// `{ reservation: null, placement: null }` when the verified participant
/// holds neither an active reservation nor a still-existing placement.
/// `placement` is only meaningful when `reservation` is `nil` — a held
/// reservation always takes priority — and is absent from every response
/// this app sent before W3-H2, which `decodeIfPresent` tolerates.
struct ActiveReservationResponseDTO: Decodable {
    let reservation: ActiveReservationDetailsDTO?
    let placement: PlacedReservationDetailsDTO?
    /// W4-R3: every placement this helper must still see as `Waiting for
    /// pickup`, independent of whether a reservation is held. Absent from a
    /// backend that predates it, which decodes as none.
    let placements: [PlacedReservationDetailsDTO]?
    /// Requests this helper placed whose requester has confirmed pickup, inside
    /// the helper-visibility window. Identity only; absent from an older backend.
    let pickupConfirmations: [PickupConfirmationDTO]?
    let serverNow: Date?
}

struct PickupConfirmationDTO: Decodable, Equatable {
    let requestId: String
}

// MARK: - Request creation eligibility (W4-Q1)

/// The exact two successful values `GET /api/participant/request-eligibility`
/// answers with. An unrecognized value fails decoding rather than being
/// mapped to a guessed state, matching `RequestStatusWire` above — never
/// silently coerced to `eligible`.
enum RequestEligibilityWire: String, Decodable {
    case eligible
    case exhausted
}

struct RequestEligibilityResponseDTO: Decodable {
    let eligibility: RequestEligibilityWire
}

// MARK: - Fulfillment

/// Strict nested fields accepted by `POST /api/request/:id/fulfill`.
/// `eta` is the request-body key; `etaText` is backend persistence vocabulary
/// and must not be sent by iOS. `contactMessage` is the only optional field.
///
/// W4-H1a: `placedOrderScreenshot` is REQUIRED on every new fulfillment, in both
/// authorization shapes. It is deliberately not optional here: the type system,
/// not a convention, is what keeps a screenshot-less new placement from being
/// expressible. There is no evidence ID, URL, or path — the bytes travel inline
/// in this one POST, and nothing about them is persisted by the client.
///
/// There is deliberately no `fulfillerEmail` (W3-I1): the helper is the
/// verified participant the claim is already bound to, the backend reads that
/// binding, and the strict schema refuses an address here — which is what stops
/// the requester's coordination email from naming anyone else.
struct FulfillmentPayload: Encodable {
    let orderNumber: String
    let eta: String
    let contactMessage: String?
    let placedOrderScreenshot: PlacedOrderScreenshotPayload
}

/// The wire form of the helper's placed-order screenshot: a MIME type
/// (`image/jpeg` or `image/png`) and standard base64 of the exact normalized
/// bytes. Built only from an already-validated `PlacedOrderScreenshot`.
struct PlacedOrderScreenshotPayload: Encodable {
    let mimeType: String
    let imageBase64: String

    init(_ screenshot: PlacedOrderScreenshot) {
        mimeType = screenshot.mimeType
        imageBase64 = screenshot.imageBase64
    }
}

/// Payload for `POST /api/request/:id/fulfill`.
struct FulfillRequestPayload: Encodable {
    let claimToken: String
    let fulfillment: FulfillmentPayload
}

/// Payload for `POST /api/request/:id/fulfill` when authorizing with verified
/// participant authority instead of the raw claim token (W3-H1 continuation).
/// The backend distinguishes this shape from `FulfillRequestPayload` by the
/// absence of the `claimToken` key, exactly as it already does for
/// `ClaimExtensionPayload` versus the empty-body release/extend continuation
/// requests — so this is a distinct type rather than an optional field on the
/// one above.
struct FulfillContinuationRequestPayload: Encodable {
    let fulfillment: FulfillmentPayload
}

enum NotificationDeliveryStatus: String, Decodable {
    case sent
    case failed
}

struct NotificationStatusDTO: Decodable {
    let status: NotificationDeliveryStatus
}

/// Response for `POST /api/request/:id/fulfill`. Core placement success
/// (`request`) is independent of notification success (`notification`).
struct FulfillResponseDTO: Decodable {
    let request: RequestResponseDTO
    let notification: NotificationStatusDTO
    /// W4-U1.1: present and `true` only when the placement committed but the
    /// helper's optional Message was suppressed by the backend's filter. The
    /// placement is a success either way; this only says the Message was not
    /// sent. Absent from every response that suppressed nothing, which
    /// `decodeIfPresent` tolerates.
    let messageSuppressed: Bool?
    /// W4-U1.3: present and `true` only when the Message was not shared because
    /// of the blocked-pair contact restriction rather than the text filter.
    /// Always accompanies `messageSuppressed`; it only selects the copy, and
    /// says nothing about direction, reason, or the other participant.
    let messageWithheld: Bool?
}

// MARK: - Errors

struct APIErrorDetail: Decodable {
    let code: String
    let message: String
}

/// Standard error envelope: `{ "error": { "code", "message" } }`.
struct APIErrorResponse: Decodable {
    let error: APIErrorDetail
}

// MARK: - Owner reads (W4-R5)

/// One of the verified participant's own ongoing requests, from
/// `GET /api/participant/requests` and `GET /api/participant/request/:id`.
///
/// A narrow allowlisted DTO: it has no status (the owner's `phase` replaces it),
/// no helper identity, no claim material and no moderation state, because the
/// backend sends none. Backend-derived `canEdit` / `canWithdraw` are state this
/// app reads, never recomputes from stale local data; the mutation re-checks
/// atomically either way.
struct OwnerRequestResponseDTO: Decodable {
    let id: String
    let vendor: String
    let food: String
    let pickupWindowText: String
    let mealSwipes: Int
    let menuPath: RequestMenuPathWire
    let mealItems: [MealItem]
    let orderDetails: String?
    let estimatedDiningDollarsCents: Int?
    let windowStart: Date?
    let windowEnd: Date?
    let createdAt: Date
    let expiresAt: Date
    let timing: OwnerRequestTimingWire
    let phase: OwnerRequestPhaseWire
    /// `nil` only for a legacy row that was never given edit authority.
    let contentRevision: Int?
    let canEdit: Bool
    let canWithdraw: Bool
    /// 11:30 PM America/New_York on the request's original creation day.
    let latestScheduledStart: Date
}

enum OwnerRequestTimingWire: String, Decodable {
    case asap
    case scheduled
}

enum OwnerRequestPhaseWire: String, Decodable {
    case scheduled
    case available
    case reserved
}

struct OwnerRequestListResponseDTO: Decodable {
    let requests: [OwnerRequestResponseDTO]
    /// Owner-only boolean: moderation removed one of the caller's live
    /// requests. Additive; an older payload without it decodes as `false`.
    let removedNotice: Bool

    private enum CodingKeys: String, CodingKey {
        case requests
        case removedNotice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requests = try container.decode([OwnerRequestResponseDTO].self, forKey: .requests)
        removedNotice = try container.decodeIfPresent(Bool.self, forKey: .removedNotice) ?? false
    }
}

struct OwnerRequestDetailResponseDTO: Decodable {
    let request: OwnerRequestResponseDTO
}

// MARK: - Requester placed-order continuation (W4-R3)

/// Private requester-scoped placement projection. Deliberately separate from
/// `RequestResponseDTO`: these fields never widen the public Request DTO.
struct PlacedOrderResponseDTO: Decodable {
    let id: String
    let vendor: String
    let food: String
    let pickupWindowText: String
    let mealSwipes: Int
    let menuPath: RequestMenuPathWire
    let mealItems: [MealItem]
    let orderDetails: String?
    let estimatedDiningDollarsCents: Int?
    let windowStart: Date?
    let windowEnd: Date?
    let status: RequestStatusWire
    let createdAt: Date
    let expiresAt: Date
    let isOwnRequest: Bool
    let orderNumber: String?
    let etaText: String?
    let placedAt: Date?
    let estimatedReadyAt: Date?
    /// W4-R3: backend end of the America/New_York day containing
    /// `estimatedReadyAt`; Home visibility only, never retention.
    let homeVisibleUntil: Date?
    let pickupConfirmation: PlacedOrderPickupConfirmationDTO?
    let contactHelperEmail: String?
}

struct PlacedOrderListResponseDTO: Decodable {
    let orders: [PlacedOrderResponseDTO]
    let serverNow: Date
}

enum PlacedOrderPickupStatusWire: String, Decodable {
    case pending
    case confirmed
}

struct PlacedOrderPickupConfirmationDTO: Decodable {
    let status: PlacedOrderPickupStatusWire
    let confirmedAt: Date?
}

struct PlacedOrderDetailResponseDTO: Decodable {
    let order: PlacedOrderResponseDTO
    let serverNow: Date
}

struct PickupConfirmationResponseDTO: Decodable {
    let requestId: String
    let pickupConfirmation: PlacedOrderPickupConfirmationDTO
}

// MARK: - Withdraw / Edit (W4-R5)

/// `POST /api/request/:id/withdraw` → `{ outcome: "withdrawn", requestId }`.
/// The same shape answers a fresh withdrawal and an exact replay.
struct WithdrawResponseDTO: Decodable {
    let outcome: String
    let requestId: String
}

/// `POST /api/request/:id/edit`. `request` is the request as it is now, or
/// `nil` when it is no longer ongoing work (withdrawn or expired since this
/// change committed) — never a fabricated "edited" copy.
struct EditResponseDTO: Decodable {
    let outcome: String
    let resultingRevision: Int
    let request: OwnerRequestResponseDTO?
}

/// Whether an edit changes the availability window. `unchanged` is the
/// ordinary edit and leaves the window exactly as it is; `asap` and
/// `scheduled` are an explicit change that recalculates the three-hour window.
/// `Codable` so an unresolved edit can round-trip through its durable record.
enum EditTimingWire: String, Codable {
    case unchanged
    case asap
    case scheduled
}

/// Payload for `POST /api/request/:id/edit`. Carries the same structured
/// representation as create plus the expected content revision (the
/// compare-and-swap authority). Never carries a requester address, a flat
/// `food`, a window end or an installation credential: the backend's strict
/// schema refuses all of them.
struct EditRequestPayload: Codable, Equatable {
    let vendor: String
    let menuPath: RequestMenuPathWire
    let mealSwipes: Int
    let mealItems: [MealItem]
    let orderDetails: String?
    let estimatedDiningDollarsCents: Int?
    let timing: EditTimingWire
    let windowStart: Date?
    let expectedContentRevision: Int
}
