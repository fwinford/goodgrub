//
//  CommonPlateModels.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import Foundation

struct DiningSpot: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    /// Nil when the address is unavailable, e.g. a backend-sourced request whose
    /// wire representation is only a `vendor` name string. Not a fabricated "".
    let address: String?
}

enum RequestTiming: String, CaseIterable, Identifiable {
    case asap = "ASAP"
    case later = "Later"

    var id: String { rawValue }
}

/// Canonical lifecycle status. Backend wire values `open`/`claimed`/`placed`
/// map to `.open`/`.claimed`/`.placed` — see RequestDTOs.swift for the wire mapping.
enum RequestStatus: String {
    case open = "Open"
    case claimed = "Claimed"
    case placed = "Placed"
    /// W4-R5: the requester withdrew the request. Terminal for that request;
    /// only a single-request read can report it (the list never advertises one).
    case withdrawn = "Withdrawn"
}

/// W4-H2 caller-relative ownership, always relative to one exact participant
/// authority. Deliberately three-state: `.notOwn` means current-authority
/// server evidence established that this request belongs to someone else,
/// while `.unresolved` means no such evidence exists yet — because the
/// response carried no ownership metadata, because the authority that
/// produced it is no longer current, or because the read has not returned.
/// Only `.notOwn` may expose helper affordances; `.unresolved` fails closed.
///
/// Ownership is never inferred from a locally created request id, the
/// installation, the device, a previous participant, a previous email, or UI
/// history. The single exception is a request this app just created under a
/// still-current authenticated authority, which is direct knowledge from the
/// authenticated operation that created it rather than a heuristic — see
/// `RequestStore.applyConfirmed`.
enum RequestOwnership: Equatable, Hashable {
    case own
    case notOwn
    case unresolved
}

/// W4-R4 menu path, in domain vocabulary. Requester-owned truth resolved by
/// the backend; nothing on this side infers it from the other fields.
enum RequestMenuPath: Hashable {
    case mealExchange
    case diningDollars
}

/// The one canonical meal representation used by manual entry, Screenshot
/// Assistance, request payloads, and responses.  Details are intentionally a
/// separate optional field — never text formatting embedded in the name.
struct MealItem: Hashable, Codable, ExpressibleByStringLiteral {
    var name: String
    var details: String?

    init(name: String, details: String? = nil) {
        self.name = name
        self.details = details
    }

    init(stringLiteral value: String) {
        self.init(name: value)
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            name = try container.decode(String.self, forKey: .name)
            details = try container.decodeIfPresent(String.self, forKey: .details)
        } else {
            // Read compatibility for disposable pre-final-R4 response rows;
            // all new payloads encode the structured object below.
            name = try decoder.singleValueContainer().decode(String.self)
            details = nil
        }
    }
}

/// The W4-R4 structured representation of what a request actually needs,
/// carried alongside `FoodRequest.foodDescription` — which remains the
/// backend-derived single-line summary every currently accepted helper
/// surface renders.
///
/// R4 supplies this representation; it deliberately does not change how any
/// helper surface presents it. The later, separately routed H1 consumption
/// sync is what will present the structure directly instead of the summary
/// string.
struct RequestResource: Hashable {
    let menuPath: RequestMenuPath
    /// One entry per selected swipe on the Meal Exchange path; empty on a
    /// Dining-Dollars-only request.
    let mealItems: [MealItem]
    /// The single structured order-details value on a Dining-Dollars-only
    /// request; `nil` on a Meal Exchange one.
    let orderDetails: String?
    /// Exact cents. `nil` means the requester needed no Dining Dollars, which
    /// is deliberately not the same as `0` — a fabricated `$0.00` would claim
    /// they stated an amount they left empty.
    let estimatedDiningDollarsCents: Int?

    /// The neutral value used only by construction sites that do not exercise
    /// the structured representation (see `FoodRequest.init`'s `resource`
    /// parameter). It states a Meal Exchange request with no entries, which
    /// is not a shape the backend can produce, so it can never be mistaken
    /// for decoded truth.
    static let unspecified = RequestResource(
        menuPath: .mealExchange,
        mealItems: [],
        orderDetails: nil,
        estimatedDiningDollarsCents: nil
    )
}

/// Canonical backend-backed request model. `id`, `createdAt`, `expiresAt`, and `status`
/// are backend-owned truth (see docs/system-contract.md); they are never
/// computed or generated by iOS in the production path. Requester-private data
/// (email, phone) is intentionally not modeled here — the public wire shape
/// never carries it. Pickup name is not modeled either, and since W4-R4 it
/// does not exist anywhere in the request contract to model.
/// `Hashable` so a request can be a navigation *value*: the helper flow's
/// destinations live in an app-owned path array rather than in view-local
/// presentation flags, which is what makes leaving a completed flow a single
/// deterministic truncation instead of a chain of `dismiss()` calls.
struct FoodRequest: Identifiable, Hashable {
    let id: String
    let diningSpot: DiningSpot
    let foodDescription: String
    let pickupWindowText: String
    /// V1 meal-swipe requirement (W3-C1). Every request this app can fetch or
    /// create carries one — the backend requires it on every accepted shape,
    /// including the legacy web one — so this is never a placeholder for an
    /// absent value.
    let mealSwipes: Int
    /// W4-R4 structured representation of what this request needs. Decoded
    /// from the backend projection, never composed locally.
    let resource: RequestResource
    let windowStart: Date?
    let windowEnd: Date?
    let timing: RequestTiming
    let preferredPickupTime: Date?
    let createdAt: Date
    let expiresAt: Date
    var status: RequestStatus
    /// W4-H2 participant-scoped ownership, resolved for the exact participant
    /// authority that produced this value. Backend-owned truth, never a
    /// locally derived heuristic (e.g. comparing against a locally remembered
    /// created-request id) — see `docs/week-4-ios-testflight-spec.md` W4-H2.
    ///
    /// This is deliberately a three-state value rather than a `Bool`. A
    /// boolean cannot distinguish "the server resolved this caller's
    /// ownership and the answer is no" from "no current-authority server
    /// evidence exists yet", and collapsing the second into the first is
    /// what previously let a response that carries no ownership metadata at
    /// all — a create result, or a detail read taken before the route derived
    /// ownership — present an owner's own request as an ordinary helpable
    /// one. `.unresolved` fails closed instead.
    let ownership: RequestOwnership
    /// W4-R5 opaque content revision, stated only by the single-request detail
    /// read (`nil` everywhere else, and for a legacy row). Never interpreted:
    /// a notification tap compares it with the revision the notification
    /// carried, to say truthfully that the request changed since.
    let contentRevision: Int?

    /// All backend-owned values are supplied explicitly and never generated
    /// locally in the production path.
    init(
        id: String,
        diningSpot: DiningSpot,
        foodDescription: String,
        pickupWindowText: String,
        mealSwipes: Int,
        /// Defaults to `.unspecified` for the same reason `ownership` below
        /// defaults: the construction sites that do not exercise the W4-R4
        /// structured representation stay unchanged. The production decode
        /// path never relies on it — `RequestService` passes the decoded
        /// resource at every mapping site — so a defaulted value can never
        /// reach a surface as if it were backend truth.
        resource: RequestResource = .unspecified,
        windowStart: Date?,
        windowEnd: Date?,
        createdAt: Date,
        expiresAt: Date,
        status: RequestStatus,
        /// Defaults to `.notOwn` only so the many existing construction sites
        /// that do not exercise ownership stay unchanged. The production
        /// decode path never relies on this default: `RequestService` passes
        /// an explicit resolution at every mapping site, precisely so an
        /// endpoint that carries no ownership metadata cannot silently
        /// produce an actionable "not own".
        ownership: RequestOwnership = .notOwn,
        contentRevision: Int? = nil
    ) {
        self.id = id
        self.diningSpot = diningSpot
        self.foodDescription = foodDescription
        self.pickupWindowText = pickupWindowText
        self.mealSwipes = mealSwipes
        self.resource = resource
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.timing = windowStart != nil || windowEnd != nil ? .later : .asap
        self.preferredPickupTime = windowStart ?? windowEnd
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
        self.ownership = ownership
        self.contentRevision = contentRevision
    }

    /// The caller's own request, affirmed by current-authority server
    /// evidence. Drives the `YOUR REQUEST` treatment only.
    var isOwnRequest: Bool { ownership == .own }

    /// Whether helper affordances (Reserve/Help) may be exposed at all.
    /// Only an established `.notOwn` qualifies — `.unresolved` fails closed,
    /// so an unanswered or superseded ownership read can never be mistaken
    /// for permission. This gate is presentation-level defense in depth; the
    /// backend's atomic self-claim guard remains the mutation authority.
    var allowsHelperAction: Bool { ownership == .notOwn }

    /// Returns a copy carrying a different ownership resolution. Used when a
    /// participant-authority change invalidates previously resolved
    /// caller-relative truth without discarding the public request data.
    func withOwnership(_ ownership: RequestOwnership) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: diningSpot,
            foodDescription: foodDescription,
            pickupWindowText: pickupWindowText,
            mealSwipes: mealSwipes,
            resource: resource,
            windowStart: windowStart,
            windowEnd: windowEnd,
            createdAt: createdAt,
            expiresAt: expiresAt,
            status: status,
            ownership: ownership,
            contentRevision: contentRevision
        )
    }

    /// Reflects backend-provided lifecycle state; it never compares `expiresAt`
    /// with device time.
    var isActive: Bool {
        status == .open
    }

    var shouldShowInASAPSection: Bool {
        switch timing {
        case .asap:
            return true

        case .later:
            guard let preferredPickupTime else {
                return false
            }

            let oneHourFromNow = Date().addingTimeInterval(60 * 60)
            return preferredPickupTime <= oneHourFromNow
        }
    }

    /// A currently retained, requester-owned placement reconstructed from R3's
    /// private backend read. `request` remains the shared R5 card model; the
    /// placement values never enter the public Request DTO or persisted client data.
    struct PlacedOrder: Identifiable, Equatable {
        let request: FoodRequest
        let orderNumber: String
        let etaText: String?
        let placedAt: Date?
        let estimatedReadyAt: Date?
        let homeVisibleUntil: Date?
        let serverNow: Date
        private let remainingAtRead: TimeInterval?
        private let homeVisibleRemainingAtRead: TimeInterval?
        private let monotonicReadAt: TimeInterval

        var id: String { request.id }

        init(
            request: FoodRequest,
            orderNumber: String,
            etaText: String?,
            placedAt: Date?,
            estimatedReadyAt: Date?,
            homeVisibleUntil: Date? = nil,
            serverNow: Date,
            monotonicReadAt: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) {
            self.request = request
            self.orderNumber = orderNumber
            self.etaText = etaText
            self.placedAt = placedAt
            self.estimatedReadyAt = estimatedReadyAt
            self.homeVisibleUntil = homeVisibleUntil
            self.serverNow = serverNow
            self.remainingAtRead = estimatedReadyAt.map {
                max(0, $0.timeIntervalSince(serverNow))
            }
            self.homeVisibleRemainingAtRead = homeVisibleUntil.map {
                $0.timeIntervalSince(serverNow)
            }
            self.monotonicReadAt = monotonicReadAt
        }

        /// W4-R3 requester Home cutoff: the end of the campus day containing
        /// `estimatedReadyAt`, as backend time advanced by the monotonic clock.
        /// `nil` means the backend sent no cutoff (it already excludes a row
        /// without a valid ETA from the list), so the client adds none of its own.
        func isVisibleOnRequesterHome(
            at monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) -> Bool {
            guard let remaining = homeVisibleRemainingAtRead else { return true }
            return remaining - max(0, monotonicNow - monotonicReadAt) > 0
        }

        /// Seconds until this card leaves requester Home, for the one attention timer.
        func secondsUntilHomeCutoff(
            at monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) -> TimeInterval? {
            guard let remaining = homeVisibleRemainingAtRead else { return nil }
            return max(0, remaining - max(0, monotonicNow - monotonicReadAt))
        }

        func secondsUntilPickupAttention(
            at monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) -> TimeInterval? {
            guard let remainingAtRead else { return nil }
            return max(0, remainingAtRead - max(0, monotonicNow - monotonicReadAt))
        }

        func shouldConfirmPickup(
            at monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) -> Bool {
            guard let remaining = secondsUntilPickupAttention(at: monotonicNow) else {
                return false
            }
            return remaining <= 0
        }
    }

    enum PlacedOrderPickupConfirmation: Equatable {
        case pending
        case confirmed(Date)
    }

    struct PlacedOrderDetail: Equatable {
        let placedOrder: PlacedOrder
        let pickupConfirmation: PlacedOrderPickupConfirmation
        let contactHelperEmail: String?

        var request: FoodRequest { placedOrder.request }
    }

    enum PickupConfirmationAttemptResult: Equatable {
        case confirmed
        case unresolved
        case notFound
    }

    var timingDescription: String {
        pickupWindowText
    }

    var listTimingDescription: String {
        pickupWindowText
    }
}

typealias PlacedOrder = FoodRequest.PlacedOrder
typealias PlacedOrderPickupConfirmation = FoodRequest.PlacedOrderPickupConfirmation
typealias PlacedOrderDetail = FoodRequest.PlacedOrderDetail
typealias PickupConfirmationAttemptResult = FoodRequest.PickupConfirmationAttemptResult
