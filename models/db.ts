// System model for key/value store (e.g. round-robin cursor)
export interface ISystem extends Document {
  key: string;
  value: any;
}

const SystemSchema = new Schema<ISystem>({
  key: { type: String, required: true, unique: true },
  value: { type: Schema.Types.Mixed, required: true },
});

export const System = mongoose.models.System || mongoose.model<ISystem>("System", SystemSchema);
// db.ts
// Mongoose schemas for CommonPlate
// - Request: meal requests (TTL-deleted at private `deleteAt`)
// - Fulfillment: log when an order is placed

import mongoose, { Schema, Document, Types } from "mongoose";
import {
  INITIAL_PARTICIPANT_AUTHORITY_VERSION,
  MAXIMUM_PARTICIPANT_AUTHORITY_VERSION,
} from "../src/participantCredentials.js";
import {
  INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION,
} from "../src/unsubscribeCredential.js";
import {
  DINING_DOLLARS_PATH,
  MEAL_EXCHANGE_PATH,
  type MenuPath,
} from "../src/structuredRequest.js";
import {
  PLACEMENT_EVIDENCE_MAX_BYTES,
  PLACEMENT_EVIDENCE_MIME_TYPES,
} from "../src/placedOrderEvidence.js";

// Subscriber model
export interface ISubscriber extends Document {
  email: string;
  status: "pending" | "confirmed" | "unsubscribed";
  confirmationTokenDigest?: string;
  confirmationExpiresAt?: Date;
  confirmationSendAttemptId?: string;
  confirmationSendAttemptAt?: Date;
  lastConfirmedTokenDigest?: string;
  lastConfirmedTokenExpiresAt?: Date;
  unsubscribeCredentialVersion?: number;
  unsubscribedAt?: Date;
  // Legacy raw-token fields remain readable for exact rollback of old rows.
  confirmToken?: string;
  unsubToken?: string;
  lastSentAt?: Date;
  dailyCount: number;
  bounced: boolean;
}

const SubscriberSchema = new Schema<ISubscriber>({
  email: { type: String, required: true, unique: true, trim: true, lowercase: true },
  status: { type: String, enum: ["pending", "confirmed", "unsubscribed"], default: "pending" },
  confirmationTokenDigest: {
    type: String,
    required: function(this: ISubscriber) { return this.status === "pending"; },
    select: false,
  },
  confirmationExpiresAt: {
    type: Date,
    required: function(this: ISubscriber) { return this.status === "pending"; },
    select: false,
  },
  // This private owner serializes rotation with provider submission. It is
  // cleared after success and removed by digest-matched compensation on error.
  // Its timestamp bounds the claim: an attempt that dies mid-flight leaves the
  // owner behind, so ownership is honoured only inside a short lease and the
  // lifecycle stays recoverable instead of becoming permanently unconfirmable.
  confirmationSendAttemptId: { type: String, select: false },
  confirmationSendAttemptAt: { type: Date, select: false },
  // Receipt of the confirmation token that won the transition, kept only until
  // that token's original expiry. Reopening the same confirmation link is
  // ordinary user behaviour, so the redeemed digest must stay recognisable for
  // an idempotent success instead of degrading into an invalid-token answer.
  lastConfirmedTokenDigest: { type: String, select: false },
  lastConfirmedTokenExpiresAt: { type: Date, select: false },
  // The revocation counter behind the emailed unsubscribe link. No unsubscribe
  // credential is stored: it is signed on demand from `_id` and this version,
  // so every subscriber holds a revocable credential by construction and an
  // issued link stays valid until this number moves. Signup and confirmation
  // must never touch it, or an old emailed link would stop working.
  unsubscribeCredentialVersion: {
    type: Number,
    default: INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
    min: INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
    max: MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION,
    validate: {
      validator: Number.isInteger,
      message: "unsubscribeCredentialVersion must be an integer",
    },
  },
  unsubscribedAt: { type: Date },
  confirmToken: { type: String, select: false },
  // Legacy raw credential from pre-digest rows. Nothing issues or requires
  // one — the current unsubscribe credential is derived, never stored — so it
  // stays out of ordinary projections like every other private credential
  // field. Existing values are left in place; confirmation still clears the
  // field when it transitions a row that carries one.
  unsubToken: { type: String, select: false },
  lastSentAt: { type: Date, default: null },
  dailyCount: { type: Number, default: 0 },
  bounced: { type: Boolean, default: false },
});

export const Subscriber = mongoose.models.Subscriber || mongoose.model<ISubscriber>("Subscriber", SubscriberSchema);

// Notification delivery ledger and duplicate-send guard.
export interface ISendLog extends Document {
  subscriberId: Types.ObjectId;
  requestId?: Types.ObjectId;
  sentAt: Date;
  status: "sent" | "fail";
  error?: string;
}

const SendLogSchema = new Schema<ISendLog>({
  subscriberId: { type: Schema.Types.ObjectId, ref: "Subscriber", required: true },
  requestId: { type: Schema.Types.ObjectId, ref: "Request" },
  sentAt: { type: Date, default: Date.now },
  status: { type: String, enum: ["sent", "fail"], required: true },
  error: { type: String },
});

// Prevent duplicate SendLog entries for the same request+subscriber pair.
// This also enables an atomic 'claim' pattern where a process inserts a
// pending log before sending and updates it after the send completes.
SendLogSchema.index({ requestId: 1, subscriberId: 1 }, { unique: true });

export const SendLog = mongoose.models.SendLog || mongoose.model<ISendLog>("SendLog", SendLogSchema);


// ========================== Installation ============================
// One record per app installation that has ever synchronized push state
// (Week 3 Day 6 Slice 6A.1). Deliberately separate from Subscriber: an
// installation identity is not a person, account, or email address, and
// email delivery must stay wholly independent of push delivery.
export interface IInstallation extends Document {
  installationCredentialDigest: string;
  pushEnabled: boolean;
  apnsToken?: string | null;
  apnsEnvironment?: "development" | "production" | null;
  tokenUpdatedAt?: Date | null;
  invalidatedAt?: Date | null;
  /**
   * W4-N1 recipient authority (design §1). Device-routing metadata only — it
   * never becomes participant authority itself. Private (`select: false`):
   * written only by `PUT /api/installations/push` enable and N1's Change
   * Email handoff/Remove Email disassociation, and read only by the shared
   * Push eligibility predicate.
   */
  participantId?: Types.ObjectId | null;
  /**
   * The Participant's `authorityVersion` at the moment this Installation was
   * associated. The eligibility predicate requires this to still equal the
   * Participant's current `authorityVersion`; a revoked/replaced/deleted
   * Participant falls out of eligibility without any migration or sweep.
   */
  participantAuthorityVersion?: number | null;
  pushMutationVersion?: number;
  createdAt: Date;
  updatedAt: Date;
}

const InstallationSchema = new Schema<IInstallation>(
  {
    // SHA-256 digest of the opaque credential the app generates for itself.
    // Only the digest is ever persisted; the raw credential is never stored
    // or logged.
    installationCredentialDigest: {
      type: String,
      required: true,
      unique: true,
      select: false,
    },
    pushEnabled: { type: Boolean, required: true, default: false },
    // Left set (not cleared) when push is turned off, so a later
    // provider-invalidation notice for this exact token can still recognize
    // it as this installation's current token. See the Slice 6A APNs
    // invalidation boundary in the Week 3 spec.
    apnsToken: { type: String, select: false },
    apnsEnvironment: { type: String, enum: ["development", "production"] },
    tokenUpdatedAt: { type: Date },
    invalidatedAt: { type: Date },
    participantId: {
      type: Schema.Types.ObjectId,
      ref: "Participant",
      select: false,
    },
    participantAuthorityVersion: { type: Number, select: false },
    pushMutationVersion: { type: Number, select: false, min: 0, validate: Number.isSafeInteger },
  },
  { timestamps: true }
);

// Supports participant-scoped Installation lookup, including the P2 deletion adapter.
InstallationSchema.index({ participantId: 1 });

// At most one installation may be the eligible current owner of a given APNs
// token in a given environment. Enforced with a partial unique index, not a
// read-then-write check, so two installations registering the same token at
// once cannot both end up eligible: MongoDB itself rejects the second write,
// and the route demotes the prior owner and retries.
InstallationSchema.index(
  { apnsToken: 1, apnsEnvironment: 1 },
  {
    unique: true,
    partialFilterExpression: {
      pushEnabled: true,
      apnsToken: { $type: "string" },
    },
    name: "installation_push_eligible_token_unique",
  }
);

export const Installation =
  (mongoose.models.Installation as mongoose.Model<IInstallation>) ||
  mongoose.model<IInstallation>("Installation", InstallationSchema);


// ============================ Request =============================
/**
 * Which path owns starting this request's helper new-request notification, and
 * whether that has happened yet (W3-N3). The product event that initiates
 * helper notification is *the request becoming helper-eligible*, which for an
 * ASAP request is its creation instant and for a future Later request is its
 * `visibleFrom` — an instant that can arrive hours after `createdAt`.
 *
 * - `"initiated"`: helper email and push dispatch have been started for this
 *   request. Nothing may start them again.
 * - `"awaiting-eligibility"`: the request was not helper-eligible when it was
 *   created, so creation-time dispatch deliberately did nothing and the
 *   eligibility sweep (`src/eligibilityNotificationSweep.ts`) owns it.
 *
 * Absent is a third, deliberate state: rows persisted before this field existed
 * were dispatched for (or not) at creation exactly as they always were, and the
 * sweep never selects them. Nothing migrates them, for the same reason nothing
 * migrates `visibleFrom`.
 */
export type HelperNotificationState = "awaiting-eligibility" | "initiated";

export interface IRequest extends Document {
  vendor: string;
  /**
   * The single-line summary every already-accepted downstream projection,
   * email, push payload, and digest line renders. Since W4-R4 this is derived
   * once at creation from the structured fields below
   * (`deriveFoodSummary`, `src/structuredRequest.ts`) rather than supplied
   * flat by a client — the structured representation is the authority, and
   * this is its compatibility rendering.
   */
  food: string;
  pickupWindowText: string;
  /**
   * W4-R4 structured menu path. Exactly one of `meal-exchange` (1-5 swipes,
   * one meal-detail entry each, optional Dining Dollar estimate) or
   * `dining-dollars` (0 swipes, required order details and estimate).
   * Requester-owned truth written once at creation, never inferred from the
   * other fields.
   */
  menuPath?: MenuPath;
  /**
   * The exact integer count of meal swipes this request needs. W3-C1
   * established the 1-5 Meal Exchange range; W4-R4 widens the stored bound to
   * 0-5 so a Dining-Dollars-only request can record that it needs none.
   * Requester-owned truth, required by every accepted `POST /api/request`
   * shape (enforced in `createRequestRoute.ts`, the authoritative validator)
   * and written once at creation, never recomputed or defaulted. Not
   * `required` at the schema level so that fixtures and Mongo suites
   * unrelated to this slice, across many pre-existing Request documents and
   * test files, are not forced to supply it; existing database contents are
   * disposable test data, not a migration target.
   */
  mealSwipes?: number;
  /**
   * One structured meal-detail entry per selected swipe (W4-R4), in the
   * requester's own order. Empty on a Dining-Dollars-only request. Entries a
   * requester hid by lowering their swipe count are excluded by the client
   * before submission and refused by validation if sent anyway, so this array
   * always describes exactly the swipes the request actually needs.
   */
  mealItems?: Array<{ name: string; details?: string }>;
  /** The single structured order-details value a Dining-Dollars-only request
   * requires (W4-R4). Absent on a Meal Exchange request. */
  orderDetails?: string;
  /**
   * The requester's Dining Dollar estimate in exact cents (W4-R4) — never a
   * float, so no accepted user-visible value can acquire rounding behaviour.
   * Absent means no Dining Dollars are needed; it is never persisted as `0`,
   * because a fabricated `$0.00` would claim the requester stated something
   * they deliberately left empty. Always present on a Dining-Dollars-only
   * request, where it is required. An estimate, never a guarantee of the
   * provider's final total.
   */
  estimatedDiningDollarsCents?: number;
  email: string;
  windowStart?: Date;
  windowEnd?: Date;
  status: "open" | "claimed" | "placed" | "withdrawn";
  orderNumber?: string;
  eta?: Date;
  etaText?: string;
  placedAt?: Date;
  /** Requester-owned pickup acknowledgement; independent of `status: placed`. */
  requesterPickupConfirmedAt?: Date;
  fulfillerEmail?: string;
  /**
   * W4-U1.1 content-free suppression marker: `true` only when the helper's
   * optional fulfillment Message was refused by the participant-text filter
   * and the placement committed without it. Written in the same atomic
   * placement update that sets `status: "placed"`, so it can never disagree
   * with committed placement, and it carries no Message text, term, or
   * lexicon content. It exists solely so same-flow placed-result recovery
   * (`GET /api/participant/active-reservation`) can truthfully report
   * `placed + Message suppressed`; absence means "not established as
   * suppressed", never a claim about what was sent.
   *
   * There is deliberately no stored Message field at all. The helper Message
   * is transient fulfillment/email-only context (W4-U1.1): it lives in
   * request memory for the immediate requester email attempt and is never
   * persisted on the Request, the Fulfillment ledger, or anywhere else.
   */
  contactMessageSuppressed?: boolean;
  /**
   * W4-U1.3 content-free refinement of `contactMessageSuppressed`: `true` only
   * when the optional Message was not shared because of the blocked-pair
   * contact restriction rather than the participant-text filter. Always
   * written together with `contactMessageSuppressed`, in the same placement
   * update. It carries no direction, no reason beyond "restricted", and no
   * identity, and is reported only to the placing helper.
   */
  contactMessageWithheld?: boolean;
  /**
   * W4-U1.3 durable post-Yes external-order-risk authority. Set to `true`,
   * atomically with the successful Block, only when the helper who holds the
   * live reservation answered that the real external order is already placed.
   * Request-scoped, content-free, and never projected: it carries no identity,
   * no direction, and no timing. While set, this request is never claimable and
   * never advertised again — not after Stop, not after passive reservation
   * expiry, not after Unblock — and it ends only with the Request itself
   * (`deleteAt`). Fulfillment may still commit against a live reservation.
   */
  externalOrderAffirmed?: boolean;
  /**
   * W4-R5 monotonic content revision. Written as `1` at creation and advanced
   * by exactly one in the same atomic conditional update that commits a
   * content or timing edit — never by anything else. It is the compare-and-swap
   * authority for Edit (a stale expected revision fails safely) and the
   * truthful basis for an updated-since-notification notice. It is *not* the
   * notification generation below. Absent means a legacy row that was never
   * given edit authority: Edit refuses it rather than guessing a revision.
   */
  contentRevision?: number;
  /**
   * W4-R5 notification generation. Separate from `contentRevision` on purpose:
   * an ordinary edit changes content but must not initiate new helper alerts,
   * while an explicit rescheduling (and a withdrawal) advances this so any
   * dispatch started under an earlier generation can detect, before claiming a
   * delivery and again immediately before provider handoff, that the request
   * it was about to advertise is no longer the one it was started for. Private
   * (`select: false`); absent reads as the initial generation.
   */
  notificationGeneration?: number;
  /** When the requester withdrew the request. Private; present exactly when
   * `status === "withdrawn"`. */
  withdrawnAt?: Date;
  /**
   * W4-U1.2 (boundary contract EO) — "M". Permanent non-availability, written
   * by the Remove-request moderation outcome and by requester suspension.
   * Separate from, and never inferred from or merged with,
   * `externalOrderAffirmed`: neither clears or implies the other, and both may
   * coexist. Nothing clears M once set — not Stop, release, passive expiry,
   * retry, recovery, Unblock, reinstatement, Edit, or Withdraw. `select: false`
   * and never projected, read only by the shared availability predicate, the
   * claim filter, the release mutation, and the failure classifiers.
   */
  moderationUnavailable?: boolean;
  /**
   * W4-U1.2 (boundary contract EO) — "L". Written only by helper suspension,
   * pinned to the exact live reservation it was set against (same helper
   * binding and deadline). Means "this reservation's order-placement status is
   * Unknown": while set, neither a passive lapse nor a plain Stop makes the
   * request claimable again. Cleared only by a confirmed No (the accepted
   * release mutation's `confirmedNo` input) or by a placement; never by
   * expiry, Stop, Unblock, or reinstatement. `select: false`, never projected.
   */
  reservationLapseHold?: boolean;
  notificationStatus?: "pending" | "sent" | "failed";
  notificationAttemptedAt?: Date;
  visibleFrom?: Date;
  helperNotification?: HelperNotificationState;
  /**
   * W4-N1 Increment B. Tracks the single, separate T-15 closing-soon
   * discovery notification exactly like `helperNotification` tracks the
   * initial one — a second independent one-shot latch, not a second state on
   * the same field, so an initial-notification retry or edit can never be
   * confused with a closing-soon send. Written `"awaiting"` at creation
   * (every request will eventually reach T-15 or stop being available
   * first) and reset to `"awaiting"` by an explicit reschedule alongside
   * `notificationGeneration`, exactly like `helperNotification`. A request
   * persisted before this field existed carries none, which the sweep reads
   * as "awaiting" (the same legacy allowance `helperNotification`'s
   * transition branch uses), never as "already sent."
   */
  closingSoonNotification?: "awaiting" | "initiated";
  expiresAt?: Date;
  deleteAt?: Date;
  claimedAt?: Date;
  claimExpiresAt?: Date;
  claimExtendedAt?: Date | null;
  claimTokenDigest?: string;
  installationId?: Types.ObjectId | null;
  requesterParticipantId?: Types.ObjectId | null;
  helperParticipantId?: Types.ObjectId | null;
  createdAt: Date;
  updatedAt: Date;
}

const RequestSchema = new Schema<IRequest>({
  vendor: { type: String, required: true, trim: true },
  food: { type: String, required: true, trim: true },
  pickupWindowText: { type: String, required: true, trim: true },
  menuPath: {
    type: String,
    enum: [MEAL_EXCHANGE_PATH, DINING_DOLLARS_PATH],
  },
  mealSwipes: {
    // W4-R4: `0` admits the Dining-Dollars-only path. The integer/range
    // enforcement is otherwise unchanged in kind and applies identically to
    // whichever shape was submitted.
    type: Number,
    min: 0,
    max: 5,
    validate: {
      validator: Number.isInteger,
      message: "mealSwipes must be an integer",
    },
  },
  mealItems: {
    // `_id: false`: each entry is `{ name, details }` only — Mongoose's
    // default per-subdocument `_id` is an internal artifact never part of
    // the accepted structured representation, and must not leak into any
    // projection.
    type: [
      {
        name: { type: String, required: true, trim: true },
        details: { type: String, trim: true },
        _id: false,
      },
    ],
    default: undefined,
  },
  orderDetails: { type: String, trim: true },
  estimatedDiningDollarsCents: {
    type: Number,
    min: 1,
    validate: {
      validator: Number.isInteger,
      message: "estimatedDiningDollarsCents must be an integer",
    },
  },
  email: { type: String, required: true, trim: true, lowercase: true },
  windowStart: { type: Date },
  windowEnd: { type: Date },
  status: {
    type: String,
    enum: ["open", "claimed", "placed", "withdrawn"],
    default: "open",
  },
  orderNumber: { type: String, trim: true },
  eta: { type: Date },
  etaText: { type: String, trim: true },
  placedAt: { type: Date },
  requesterPickupConfirmedAt: { type: Date, select: false },
  fulfillerEmail: { type: String, trim: true, lowercase: true },
  // Private like every other lifecycle marker: never part of a public
  // projection, selected explicitly only by the participant-scoped placed read.
  contactMessageSuppressed: { type: Boolean, select: false },
  contactMessageWithheld: { type: Boolean, select: false },
  // W4-U1.3: private like every other lifecycle marker. Read only by the
  // availability predicate, the claim filter, the release mutation, and the
  // failure classifiers; never copied onto any response.
  externalOrderAffirmed: { type: Boolean, select: false },
  // W4-R5: see `IRequest`. `contentRevision` is read by the owner reads and the
  // Edit mutation only; `notificationGeneration` and `withdrawnAt` are private
  // lifecycle markers read by the dispatchers and the mutations. Integers only,
  // so a revision can never be fractional or negative.
  contentRevision: {
    type: Number,
    min: 1,
    validate: {
      validator: Number.isInteger,
      message: "contentRevision must be an integer",
    },
    select: false,
  },
  notificationGeneration: {
    type: Number,
    min: 1,
    validate: {
      validator: Number.isInteger,
      message: "notificationGeneration must be an integer",
    },
    select: false,
  },
  withdrawnAt: { type: Date, select: false },
  // W4-U1.2 markers M and L (boundary contract EO). Private like every other
  // lifecycle marker: read only by the shared availability predicate, the
  // claim filter, the release mutation, and the failure classifiers.
  moderationUnavailable: { type: Boolean, select: false },
  reservationLapseHold: { type: Boolean, select: false },
  notificationStatus: {
    type: String,
    enum: ["pending", "sent", "failed"],
  },
  notificationAttemptedAt: { type: Date },
  // When helpers begin seeing this request: the backend creation instant for
  // ASAP, the accepted scheduled start for Later. Written explicitly at
  // creation and never by a client. Requests persisted before this field
  // existed carry no value, and availability treats that absence as "visible
  // from creation" rather than migrating them.
  visibleFrom: { type: Date },
  // Written explicitly at creation from the same visibility rule the
  // dispatchers apply, and never by a client. Internal lifecycle bookkeeping
  // like `notificationStatus`, kept out of responses by the allowlisted public
  // projection rather than by a projection default. See
  // `HelperNotificationState` above. No schema default: an absent value is the
  // legacy meaning, not a new request's meaning.
  helperNotification: {
    type: String,
    enum: ["awaiting-eligibility", "initiated"],
  },
  // W4-N1 Increment B. See `IRequest`. Independent of `helperNotification`:
  // this is the closing-soon latch, not a second value for the initial one.
  closingSoonNotification: {
    type: String,
    enum: ["awaiting", "initiated"],
  },
  expiresAt: { type: Date },
  deleteAt: {
    type: Date,
    index: {
      expireAfterSeconds: 0,
      name: "request_deleteAt_ttl",
    },
  },
  claimedAt: { type: Date },
  claimExpiresAt: { type: Date },
  claimExtendedAt: { type: Date, default: null },
  claimTokenDigest: { type: String, select: false },
  // The originating app installation, when the request was created from iOS
  // with an installation credential (Week 3 Day 6 Slice 6E). Notification-
  // routing identity only — never a person, account, or auth identity — and
  // never exposed through any public projection, so it stays out of ordinary
  // reads like every other private lifecycle field.
  installationId: { type: Schema.Types.ObjectId, ref: "Installation", select: false },
  // The verified participant who created this request (W3-I1). Written from
  // backend-resolved participant authority, never from the payload, and paired
  // with `email`, which is written from the same principal in the same call.
  // Person identity, unlike `installationId` above — which is notification
  // routing and nothing else — so it is `select: false` like every other
  // private field and never reaches a public projection.
  requesterParticipantId: {
    type: Schema.Types.ObjectId,
    ref: "Participant",
    select: false,
  },
  // The verified participant holding the current reservation (W3-I1). Written
  // by the claim mutation from resolved participant authority and retained
  // through placement, because it is who actually placed the order: fulfillment
  // derives `fulfillerEmail` from this binding instead of accepting a helper
  // address from the caller.
  helperParticipantId: {
    type: Schema.Types.ObjectId,
    ref: "Participant",
    select: false,
  },
}, { timestamps: true });

// `expiresAt` is the availability deadline; `deleteAt` owns physical retention.
// They match until placement, after which fulfillment moves only `deleteAt` to
// the placed-request retention deadline.
RequestSchema.pre("save", function (next) {
  if (!this.expiresAt) {
    const dayMs = 24 * 60 * 60 * 1000;
    this.expiresAt = new Date(Date.now() + dayMs);
  }
  if (this.status !== "placed" && !this.deleteAt) {
    this.deleteAt = this.expiresAt;
  }
  next();
});

// Index to support fast per-email daily count queries
RequestSchema.index({ email: 1, createdAt: 1 });

// W4-R5 owner reads: "this verified participant's ongoing requests", oldest
// first. Keyed on the persisted requester binding, never on an email.
RequestSchema.index(
  { requesterParticipantId: 1, createdAt: 1 },
  { name: "request_requester_ongoing" }
);

// The eligibility sweep's candidate set: requests whose helper notification has
// not been initiated yet, ordered by the instant it becomes due. Partial on the
// awaiting state, so the index holds only the future Later requests still
// waiting — never the ASAP requests that are the overwhelming majority — and
// disappears from it the moment one is initiated or TTL-deleted.
//
// This is a selection index, not a correctness guarantee: exactly-once
// initiation comes from the conditional update the sweep writes, not from here.
RequestSchema.index(
  { visibleFrom: 1 },
  {
    name: "request_helper_notification_awaiting",
    partialFilterExpression: { helperNotification: "awaiting-eligibility" },
  }
);

// W4-N1 Increment B: the closing-soon sweep's candidate set, ordered by
// `expiresAt` since that (not `visibleFrom`) is the deadline this
// notification is relative to. Same partial-index reasoning as the index
// above: only requests still awaiting their one closing-soon chance belong
// in it, and a request leaves it the moment it is initiated or TTL-deleted.
RequestSchema.index(
  { expiresAt: 1 },
  {
    name: "request_closing_soon_notification_awaiting",
    partialFilterExpression: { closingSoonNotification: "awaiting" },
  }
);

// Supports W3-H1 continuation: "does this verified participant currently hold
// an active reservation, and which request". Partial on `status: "claimed"`
// for the same reason as the index above — only the requests this lookup can
// ever match belong in it.
RequestSchema.index(
  { helperParticipantId: 1, status: 1 },
  {
    name: "request_helper_active_reservation",
    partialFilterExpression: { status: "claimed" },
  }
);

// Supports W3-H2 fulfillment re-entry: "does this verified participant have
// no active reservation but most recently place a still-existing request".
// Partial on `status: "placed"` for the same reason as the index above, and
// ordered by `placedAt` descending so the most recent placement is the first
// match without an in-memory sort.
RequestSchema.index(
  { helperParticipantId: 1, status: 1, placedAt: -1 },
  {
    name: "request_helper_placed_participation",
    partialFilterExpression: { status: "placed" },
  }
);

// W4-R3: one private, retained requester read of unconfirmed placements,
// ordered newest-first. Confirmation truth stays on the Request and is not a
// new lifecycle status.
RequestSchema.index(
  { requesterParticipantId: 1, status: 1, createdAt: -1 },
  {
    name: "request_requester_placed",
    partialFilterExpression: { status: "placed" },
  }
);

// W4-U1.2: supports the requester-suspension transaction's bulk write, which
// sets M on every non-placed request of the suspended requester (boundary
// contract EO). Not partial: MongoDB rejects `$ne` in a partial index filter,
// and the write's own `status: { $ne: "placed" }` is applied after this lookup.
RequestSchema.index(
  { requesterParticipantId: 1 },
  { name: "request_requester_moderation" }
);

/* ========================== RequestOperation =========================== */
// The durable exact-identity ledger behind bounded W3-D1 request-create
// recovery. Deliberately its own collection rather than a field on `Request`
// (the Pass 1 design): `Request` is TTL-deleted (`deleteAt`) once a request
// stops being active/actionable, and Pass 1 stored the only durable
// `operationId` record on that same document. Deleting the Request silently
// freed its identity for reuse — the exact "cleanup makes an expired
// operation fresh again" defect the amended contract forbids.
//
// This ledger row is never reclaimed by that TTL, so an operation's identity
// stays distinguishable from "genuinely new" long after its Request is gone.
// It is a minimal identity tombstone, not request history: no request
// content lives here, only the exact operation identity, the participant
// that owns it, and a pointer to the Request it created.
// `POST /api/request` follows that pointer at read time — if the referenced
// Request document still exists, the operation is still recoverable; once
// MongoDB's TTL has reclaimed it, presenting the same identity again
// resolves as terminal expired/unrecoverable instead of falling through to a
// fresh create. Rows are kept indefinitely rather than on their own TTL: each
// is a handful of bytes, and the alternative — freeing them after some
// duration — would eventually let the exact defect above resurface, only
// delayed rather than fixed.
//
// W4-D2 adds the second terminal outcome an exact identity can hold. A
// `"no-create"` row is terminal NO-CREATE: backend authority's durable answer
// that this exact operation never created a Request and never will. It
// occupies the same unique identity slot a created row does, so whichever of
// the create transaction and terminalization inserts first is the one winner
// for that identity forever. It carries no `requestId` and, like every row
// here, no request content. Rows written before W4-D2 have no `outcome` and
// always a `requestId`; they are created rows.
export const REQUEST_OPERATION_CREATED = "created";
export const REQUEST_OPERATION_NO_CREATE = "no-create";
export type RequestOperationOutcome =
  | typeof REQUEST_OPERATION_CREATED
  | typeof REQUEST_OPERATION_NO_CREATE;

export interface IRequestOperation extends Document {
  operationId: string;
  participantId?: Types.ObjectId;
  ownerDeleted?: boolean;
  /** Absent means created (every pre-W4-D2 row). */
  outcome?: RequestOperationOutcome;
  /** Present exactly when the row is a created row. */
  requestId?: Types.ObjectId;
  createdAt: Date;
  updatedAt: Date;
}

const RequestOperationSchema = new Schema<IRequestOperation>(
  {
    operationId: { type: String, required: true, trim: true },
    outcome: {
      type: String,
      enum: [REQUEST_OPERATION_CREATED, REQUEST_OPERATION_NO_CREATE],
    },
    // Private lookup/authority fields, `select: false` like their `Request`
    // counterparts: never a public read target and never returned by an
    // ordinary query on this collection.
    participantId: {
      type: Schema.Types.ObjectId,
      ref: "Participant",
      required: function (this: IRequestOperation) {
        return this.ownerDeleted !== true;
      },
      select: false,
    },
    ownerDeleted: { type: Boolean, select: false },
    requestId: {
      type: Schema.Types.ObjectId,
      ref: "Request",
      // A created row always points at its Request; a terminal NO-CREATE row
      // never does, because no Request exists or ever will for it.
      required: function (this: IRequestOperation) {
        return (
          this.ownerDeleted !== true &&
          this.outcome !== REQUEST_OPERATION_NO_CREATE
        );
      },
      select: false,
    },
  },
  { timestamps: true }
);

RequestOperationSchema.pre("validate", function () {
  if (this.ownerDeleted === true) {
    if (!this.outcome) this.outcome = REQUEST_OPERATION_CREATED;
    if (this.participantId != null || this.requestId != null) {
      this.invalidate("ownerDeleted", "owner-deleted rows cannot retain account links");
    }
    return;
  }
  if (!this.participantId) {
    this.invalidate("participantId", "a live operation requires an owner");
  }
  if (
    this.outcome === REQUEST_OPERATION_NO_CREATE
      ? this.requestId != null
      : !this.requestId
  ) {
    this.invalidate("requestId", "the operation outcome has an invalid request link");
  }
});

// The sole uniqueness/concurrency primitive behind "at most one Request per
// logical operation": a create first reserves this row inside the same
// transaction that creates the Request, and a concurrent racer for the same
// exact identity loses this insert with a duplicate-key error. Not sparse —
// unlike the retired `Request.operationId` index — because every row here
// corresponds to exactly one terminal outcome for one identity (a succeeded
// create, or since W4-D2 a terminal NO-CREATE); there is no legacy/absent case
// to keep separate from a shared `undefined`. Terminalization inserts into
// this same index, which is what makes created vs NO-CREATE one-winner.
RequestOperationSchema.index(
  { operationId: 1 },
  { unique: true, name: "request_operation_ledger_identity_unique" }
);

export const RequestOperation =
  (mongoose.models.RequestOperation as mongoose.Model<IRequestOperation>) ||
  mongoose.model<IRequestOperation>(
    "RequestOperation",
    RequestOperationSchema
  );

// W4-D2 ledger authority identity: one non-secret random identifier minted
// the first time a process establishes the `RequestOperation` ledger in this
// database, and never changed afterwards. It lives in the same database as
// the ledger it names, so a reset, replaced, or different database behind the
// same URL carries a different identifier (or none), and a client can tell
// that the authority it recorded is not the one it is now talking to. It is
// not a credential and authorizes nothing. Exactly one row, under a fixed
// `_id`; see `src/requestOperationAuthority.ts`.
export interface IRequestOperationAuthority {
  _id: string;
  authorityId: string;
  createdAt: Date;
  deletionFenceEpoch?: number;
}

const RequestOperationAuthoritySchema = new Schema<IRequestOperationAuthority>(
  {
    _id: { type: String, required: true },
    authorityId: { type: String, required: true },
    createdAt: { type: Date, required: true },
    deletionFenceEpoch: { type: Number, min: 0, select: false },
  },
  { versionKey: false }
);

export const RequestOperationAuthority =
  (mongoose.models.RequestOperationAuthority as mongoose.Model<IRequestOperationAuthority>) ||
  mongoose.model<IRequestOperationAuthority>(
    "RequestOperationAuthority",
    RequestOperationAuthoritySchema
  );

/* ======================== RequestUpdateOperation ======================== */
// W4-R5 durable exact-identity ledger for a requester's Edit and Withdraw of an
// existing Request. Deliberately its own collection and its own identity space:
// it is *not* D2's create-operation ledger (`RequestOperation`) and never
// changes quota, because an update is never a create. A row is written once,
// inside the same transaction as the conditional Request mutation it records,
// so "the mutation committed" and "its identity is recorded" can never
// disagree: an exact replay of the same identity by the same participant
// answers the already-decided outcome with no repeated effect, and a client
// never has to guess whether an ambiguous response committed.
//
// A minimal identity tombstone like `RequestOperation`: the exact operation
// identity, who owns it, which Request it targets, which kind of mutation it
// was, the revision the request carried after it committed, and the digest of
// the submitted edit so a replay that tries to reuse the identity for
// *different* content is refused instead of silently answered. No request
// content lives here. Kept indefinitely (a handful of bytes per row) for the
// same reason `RequestOperation` is: letting rows lapse would eventually make
// an old identity look fresh again.
export const REQUEST_UPDATE_EDIT = "edit";
export const REQUEST_UPDATE_WITHDRAW = "withdraw";
export type RequestUpdateKind =
  | typeof REQUEST_UPDATE_EDIT
  | typeof REQUEST_UPDATE_WITHDRAW;

export interface IRequestUpdateOperation extends Document {
  operationId: string;
  participantId?: Types.ObjectId;
  requestId?: Types.ObjectId;
  kind?: RequestUpdateKind;
  /** The request's `contentRevision` immediately after this mutation. */
  resultingRevision?: number;
  /** SHA-256 of the canonical submitted edit; present on edit rows only. */
  payloadDigest?: string;
  ownerDeleted?: boolean;
  createdAt: Date;
  updatedAt: Date;
}

const RequestUpdateOperationSchema = new Schema<IRequestUpdateOperation>(
  {
    operationId: { type: String, required: true, trim: true },
    participantId: {
      type: Schema.Types.ObjectId,
      ref: "Participant",
      required: function (this: IRequestUpdateOperation) {
        return this.ownerDeleted !== true;
      },
      select: false,
    },
    requestId: {
      type: Schema.Types.ObjectId,
      ref: "Request",
      required: function (this: IRequestUpdateOperation) {
        return this.ownerDeleted !== true;
      },
      select: false,
    },
    kind: {
      type: String,
      enum: [REQUEST_UPDATE_EDIT, REQUEST_UPDATE_WITHDRAW],
      required: function (this: IRequestUpdateOperation) {
        return this.ownerDeleted !== true;
      },
      select: false,
    },
    resultingRevision: {
      type: Number,
      required: function (this: IRequestUpdateOperation) {
        return this.ownerDeleted !== true;
      },
      min: 1,
      select: false,
    },
    payloadDigest: { type: String, select: false },
    ownerDeleted: { type: Boolean, select: false },
  },
  { timestamps: true }
);

RequestUpdateOperationSchema.pre("validate", function () {
  if (this.ownerDeleted === true) {
    if (
      this.participantId != null ||
      this.requestId != null ||
      this.kind != null ||
      this.resultingRevision != null ||
      this.payloadDigest != null
    ) {
      this.invalidate("ownerDeleted", "owner-deleted rows cannot retain account or content links");
    }
    return;
  }
  if (
    !this.participantId ||
    !this.requestId ||
    !this.kind ||
    typeof this.resultingRevision !== "number" ||
    !Number.isInteger(this.resultingRevision) ||
    this.resultingRevision < 1
  ) {
    this.invalidate("ownerDeleted", "a live update operation is incomplete");
  }
});

// The sole uniqueness/concurrency primitive: a mutation inserts this row inside
// the transaction that applies it, and a racing duplicate of the same exact
// identity loses with a duplicate-key error and rolls its Request update back.
RequestUpdateOperationSchema.index(
  { operationId: 1 },
  { unique: true, name: "request_update_operation_identity_unique" }
);

export const RequestUpdateOperation =
  (mongoose.models.RequestUpdateOperation as mongoose.Model<IRequestUpdateOperation>) ||
  mongoose.model<IRequestUpdateOperation>(
    "RequestUpdateOperation",
    RequestUpdateOperationSchema
  );

/* ========================= RequestParticipation ========================= */
// The durable, append-only one-successful-participation ledger behind W3-H2:
// once verified participant P has successfully acquired reservation
// authority over request R, P can never successfully acquire R again —
// durably, across releases, expiry, devices, reinstalls, and identity
// replacement.
//
// Deliberately its own collection, following the `RequestOperation`
// precedent above, rather than a field on `Request`: `Request.
// helperParticipantId` is only current-holder state (overwritten on reclaim,
// `$unset` on release in `claimRoute.ts`), never history, and a field would
// be cleared by the exact operations this record has to survive.
//
// A row is written once, atomically inside the same transaction that grants
// a claim (`claimRequest`, `src/claimRoute.ts`), immediately after the
// conditional grant commits, and is never updated or deleted by release,
// expiry, or reacquisition attempts. `claimRequest` consults this collection
// before its own conditional grant filter, so a participant who already
// holds a row for this exact request is refused before any mutation runs.
//
// No TTL: historical participation naturally stops mattering once `Request`
// itself is reclaimed by its own `deleteAt` TTL — a fresh `Request._id` is
// never reused, so a row referencing a since-deleted request can never match
// a later claim attempt. Rows are kept indefinitely, like `RequestOperation`,
// rather than on their own retention window.
export interface IRequestParticipation extends Document {
  requestId: Types.ObjectId;
  participantId?: Types.ObjectId;
  participationKeyVersion?: number;
  participationHmac?: string;
  createdAt: Date;
  updatedAt: Date;
}

const RequestParticipationSchema = new Schema<IRequestParticipation>(
  {
    // Private lookup fields, `select: false` like their `Request`/
    // `RequestOperation` counterparts: never a public read target.
    requestId: {
      type: Schema.Types.ObjectId,
      ref: "Request",
      required: true,
      select: false,
    },
    participantId: {
      type: Schema.Types.ObjectId,
      ref: "Participant",
      select: false,
    },
    participationKeyVersion: {
      type: Number,
      min: 1,
      validate: Number.isInteger,
      select: false,
    },
    participationHmac: {
      type: String,
      match: /^[0-9a-f]{64}$/,
      select: false,
    },
  },
  { timestamps: true }
);

// The sole uniqueness/concurrency primitive behind "P can never successfully
// acquire R again": the claim grant transaction inserts this row exactly
// once per (requestId, participantId), and a reacquisition attempt that
// raced past the pre-check still loses this insert with a duplicate-key
// error, aborting the whole transaction alongside it.
RequestParticipationSchema.index(
  { requestId: 1, participantId: 1 },
  {
    unique: true,
    partialFilterExpression: { participantId: { $type: "objectId" } },
    name: "request_participation_identity_live_unique",
  }
);
RequestParticipationSchema.index(
  { participantId: 1 },
  { name: "request_participation_participant_lookup" }
);
RequestParticipationSchema.pre("validate", function () {
  const hasVersion = this.participationKeyVersion != null;
  const hasHmac = this.participationHmac != null;
  if (
    hasVersion !== hasHmac ||
    (!this.participantId && !(hasVersion && hasHmac))
  ) {
    this.invalidate(
      "participationHmac",
      "participation identity must be complete and retain a live or pseudonymous owner"
    );
  }
});
RequestParticipationSchema.index(
  { requestId: 1, participationKeyVersion: 1, participationHmac: 1 },
  {
    unique: true,
    partialFilterExpression: { participationHmac: { $type: "string" } },
    name: "request_participation_hmac_unique",
  }
);

export const RequestParticipation =
  (mongoose.models.RequestParticipation as mongoose.Model<IRequestParticipation>) ||
  mongoose.model<IRequestParticipation>(
    "RequestParticipation",
    RequestParticipationSchema
  );

/* ============================ Fulfillment ============================= */
export interface IFulfillment extends Document {
  requestId: mongoose.Types.ObjectId;
  orderNumber: string;
  eta?: Date;
  etaText?: string;
  note?: string;
  helperParticipationKeyVersion?: number;
  helperParticipationHmac?: string;
  requesterPickupConfirmedAt?: Date;
  placedAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const FulfillmentSchema = new Schema<IFulfillment>(
  {
    requestId: { type: Schema.Types.ObjectId, ref: "Request", required: true },
    orderNumber: { type: String, trim: true, required: true },
    eta: { type: Date },
    etaText: { type: String, trim: true },
    note: { type: String, trim: true },
    helperParticipationKeyVersion: {
      type: Number,
      min: 1,
      validate: Number.isInteger,
      select: false,
    },
    helperParticipationHmac: {
      type: String,
      match: /^[0-9a-f]{64}$/,
      select: false,
    },
    requesterPickupConfirmedAt: { type: Date, select: false },
    placedAt: { type: Date, default: Date.now },
  },
  { timestamps: true }
);

FulfillmentSchema.pre("validate", function () {
  const hasVersion = this.helperParticipationKeyVersion != null;
  const hasHmac = this.helperParticipationHmac != null;
  if (hasVersion !== hasHmac) {
    this.invalidate(
      "helperParticipationHmac",
      "helper participation identity must include both key version and HMAC"
    );
  }
});

// The durable fulfillment record is the all-time counting ledger. The Request
// transition and this insert commit in one transaction, while this index is the
// final database-level guard against counting one request more than once.
FulfillmentSchema.index(
  { requestId: 1 },
  { unique: true, name: "fulfillment_request_unique" }
);


/* ================================ Export ============================== */
// Guard against OverwriteModelError in development

export const Request = 
  (mongoose.models.Request as mongoose.Model<IRequest>) || 
  mongoose.model<IRequest>("Request", RequestSchema);

export const Fulfillment = 
  (mongoose.models.Fulfillment as mongoose.Model<IFulfillment>) || 
  mongoose.model<IFulfillment>("Fulfillment", FulfillmentSchema);


/* ========================== PlacementEvidence ========================== */
// The helper's required placed-order screenshot (W4-H1a): one private row per
// placed Request, inserted in the SAME transaction that places the Request and
// writes its Fulfillment ledger row, so the three commit or abort together. It
// is deliberately not a general attachment system — no upload lifecycle, object
// storage, signed URL, or filesystem path exists, and the image is a BSON
// Buffer on this row alone.
//
// Private by construction: `image` is `select: false`, and nothing in the public
// Request projection, the helper success response, the fulfillment email, or any
// log reads this collection. A requester-authorized read is a later slice's
// concern (W4-R3).
//
// Retention: `deleteAt` is the exact `placedAt + PLACED_RETENTION_MS` horizon the
// placed Request carries — one value computed once and written to both — so the
// evidence is never kept longer, or shorter, than the placement it supports.
export interface IPlacementEvidence extends Document {
  requestId: mongoose.Types.ObjectId;
  image: Buffer;
  mimeType: (typeof PLACEMENT_EVIDENCE_MIME_TYPES)[number];
  byteLength: number;
  deleteAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const PlacementEvidenceSchema = new Schema<IPlacementEvidence>(
  {
    requestId: { type: Schema.Types.ObjectId, ref: "Request", required: true },
    image: {
      type: Buffer,
      required: true,
      select: false,
      // The persistence-boundary half of the 1.5 MB cap: a bypass of the route
      // validator still cannot store an oversized or empty image.
      validate: {
        validator: (value: Buffer) =>
          value.length > 0 && value.length <= PLACEMENT_EVIDENCE_MAX_BYTES,
        message: "Placement evidence image is empty or exceeds the size cap.",
      },
    },
    mimeType: {
      type: String,
      enum: PLACEMENT_EVIDENCE_MIME_TYPES,
      required: true,
    },
    byteLength: {
      type: Number,
      required: true,
      validate: {
        validator: (value: number) =>
          Number.isInteger(value) &&
          value > 0 &&
          value <= PLACEMENT_EVIDENCE_MAX_BYTES,
        message: "Placement evidence byteLength is outside the size cap.",
      },
    },
    deleteAt: {
      type: Date,
      required: true,
      index: {
        expireAfterSeconds: 0,
        name: "placement_evidence_deleteAt_ttl",
      },
    },
  },
  { timestamps: true }
);

// One evidence row per Request. The placement transaction inserts it exactly
// once; this index is the final database-level guard that a resend or a race can
// never produce a second row (or replace the first).
PlacementEvidenceSchema.index(
  { requestId: 1 },
  { unique: true, name: "placement_evidence_request_unique" }
);

export const PlacementEvidence =
  (mongoose.models.PlacementEvidence as mongoose.Model<IPlacementEvidence>) ||
  mongoose.model<IPlacementEvidence>(
    "PlacementEvidence",
    PlacementEvidenceSchema
  );


/* =========================== PushDelivery ============================ */
// One row per intentional APNs submission for a (request, installation,
// purpose) triple (Week 3 Day 6 Slice 6D). Deliberately not `SendLog`: that
// collection requires a `subscriberId` and is uniquely indexed on
// (requestId, subscriberId), so push rows would need a subscriber that does
// not exist, and it would entangle the two channels this contract requires to
// fail independently.
//
// `"requester-fulfillment"` (Slice 6E) shares this same collection and unique
// index rather than widening it — the collection was shaped for exactly this
// from the start (see `purpose` below).
export type PushDeliveryPurpose = "helper-new-request" | "requester-fulfillment";
export type PushDeliveryStatus = "claimed" | "accepted" | "rejected" | "failed";

export interface IPushDelivery extends Document {
  installationId: Types.ObjectId;
  requestId: Types.ObjectId;
  purpose: PushDeliveryPurpose;
  status: PushDeliveryStatus;
  submittedAt?: Date | null;
  apnsId?: string | null;
  deleteAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const PushDeliverySchema = new Schema<IPushDelivery>(
  {
    installationId: {
      type: Schema.Types.ObjectId,
      ref: "Installation",
      required: true,
    },
    requestId: { type: Schema.Types.ObjectId, ref: "Request", required: true },
    // Present from the start so a later requester-fulfillment purpose shares
    // this collection without widening the uniqueness key afterwards. W4-N1
    // Increment B adds two more purposes the same way: the closing-soon
    // discovery notification and the helper pickup-confirmation
    // notification. Each is additive to the enum and the existing unique
    // `(requestId, installationId, purpose)` index — no migration, no
    // backfill, same TTL/claim-before-submit semantics as the first two.
    purpose: {
      type: String,
      enum: [
        "helper-new-request",
        "requester-fulfillment",
        "helper-new-request-closing-soon",
        "requester-pickup-confirmed",
      ],
      required: true,
    },
    // `status: "accepted"` means exactly "APNs returned 200 for this
    // submission". It is never delivery, display, opening, or reading.
    status: {
      type: String,
      enum: ["claimed", "accepted", "rejected", "failed"],
      required: true,
      default: "claimed",
    },
    submittedAt: { type: Date },
    apnsId: { type: String },
    // TTL. Set to the request's expiration plus a day, so the duplicate guard
    // outlives every window in which a second dispatch is plausible and
    // nothing accumulates indefinitely.
    deleteAt: {
      type: Date,
      required: true,
      index: {
        expireAfterSeconds: 0,
        name: "push_delivery_deleteAt_ttl",
      },
    },
  },
  { timestamps: true }
);

// Claim-before-submit: the dispatcher inserts a `claimed` row and treats a
// duplicate-key error as "another dispatch owns this triple". A row in ANY
// state blocks a second submission — unlike SendLog, which permits a retry
// after a failure — because V1 has no push retry path, so a `failed` or
// `rejected` row is terminal and re-submitting would be a duplicate rather
// than a recovery.
PushDeliverySchema.index(
  { requestId: 1, installationId: 1, purpose: 1 },
  { unique: true, name: "push_delivery_identity_unique" }
);

export const PushDelivery =
  (mongoose.models.PushDelivery as mongoose.Model<IPushDelivery>) ||
  mongoose.model<IPushDelivery>("PushDelivery", PushDeliverySchema);


/* ============================ Participant ============================= */
// One record per NYU address that has proved control of its mailbox (W3-I1).
//
// Deliberately separate from Subscriber and from Installation, and not derived
// from either. A Subscriber is an address that asked for alerts — its whole
// lifecycle is about delivery consent and it is never proof of anything. An
// Installation is a copy of the app — notification-routing identity, replaced
// by a reinstall, and never a person. A Participant is the one thing neither of
// them is: a human who demonstrated they can read mail at an allowed NYU
// address, and therefore the only identity a request or a reservation may be
// bound to.
//
// This still verifies control of an eligible NYU-domain address. It is not
// authentication, not NetID, and not proof of enrollment, and two addresses
// belonging to one human remain two participants.
export interface IParticipant extends Document {
  email: string;
  authorityVersion: number;
  verifiedAt: Date;
  activeReservationRequestId?: Types.ObjectId | null;
  activeReservationClaimExpiresAt?: Date | null;
  /**
   * W4-U1.3 block-fence serialization counter. Never read for its value:
   * block creation increments it on both participants of the pair so that a
   * concurrent claim or extension, which always writes the claiming helper's
   * own Participant document, conflicts with the block and is retried against
   * a snapshot that contains it. See `src/participantBlocks.ts`.
   */
  blockFenceEpoch?: number;
  /** Restricted U1.2 linkage used only to resolve an account's safety history. */
  safetyIdentityRef?: Types.ObjectId | null;
  /**
   * W4-U1.2 (boundary contract EO). Private suspended state, server-enforced
   * at create, claim, edit, and withdraw (never UI-only). Written only by the
   * suspension/reinstatement transactions (`src/moderationEnforcement.ts`).
   * `select: false`, never projected; absence means "never suspended", the
   * same legacy-absence convention every other private field here uses.
   */
  suspended?: boolean;
  /**
   * W4-U1.2 write-conflict anchor, the same role `blockFenceEpoch` plays for
   * Block: never read for its value. Create's conditional write and the
   * suspension transaction's write both touch this field on the same
   * document, so a concurrent create and requester-suspension conflict and
   * retry against a fresh snapshot instead of silently both committing.
   */
  suspensionFenceEpoch?: number;
  accountFenceEpoch?: number;
  createdAt: Date;
  updatedAt: Date;
}

const ParticipantSchema = new Schema<IParticipant>(
  {
    // The principal itself: the exact normalized verified address. Unique, so
    // one address is one participant no matter how many times it verifies.
    email: {
      type: String,
      required: true,
      unique: true,
      trim: true,
      lowercase: true,
    },
    // The revocation lever behind every issued authority credential. No
    // credential is stored: it is signed on demand from `_id` and this number,
    // so raising it invalidates every credential already on every device that
    // holds this identity, and nothing else does.
    authorityVersion: {
      type: Number,
      required: true,
      default: INITIAL_PARTICIPANT_AUTHORITY_VERSION,
      min: INITIAL_PARTICIPANT_AUTHORITY_VERSION,
      max: MAXIMUM_PARTICIPANT_AUTHORITY_VERSION,
      validate: {
        validator: Number.isInteger,
        message: "authorityVersion must be an integer",
      },
    },
    // The most recent successful verification. History, not authority: it never
    // expires the identity, because the accepted contract has no routine
    // periodic reverification while usable authority remains.
    verifiedAt: { type: Date, required: true },
    // The one-active-reservation-per-verified-helper lock (W3-H1). Not
    // participant-facing state — `select: false` like every other private
    // field — and deliberately kept on this single, already-unique-by-`_id`
    // document rather than a new collection: MongoDB's per-document write
    // conflict detection is what makes the claim transaction's conditional
    // update here safe against two concurrent claims by the same principal on
    // two *different* Request documents, which a cross-collection query alone
    // could not serialize. Absence (from a Participant that predates this
    // field, or one that has never held a reservation) matches a `null`
    // query the same way every other legacy-absent field in this file does.
    // `activeReservationClaimExpiresAt` in the past means the lock is stale
    // and does not block a new reservation, without any explicit cleanup step
    // — the same passive-expiry meaning `claimExpiresAt` already carries on
    // `Request`.
    activeReservationRequestId: {
      type: Schema.Types.ObjectId,
      ref: "Request",
      select: false,
      default: null,
    },
    activeReservationClaimExpiresAt: {
      type: Date,
      select: false,
      default: null,
    },
    // W4-U1.3: a write-conflict anchor, not state. Absent reads as zero.
    blockFenceEpoch: { type: Number, select: false },
    // Moderator-only relation; never projected to participant responses.
    safetyIdentityRef: { type: Schema.Types.ObjectId, ref: "SafetyIdentity", select: false },
    // W4-U1.2 (boundary contract EO): server-enforced suspension state and its
    // write-conflict anchor. Absent reads as zero/not-suspended, like every
    // other private field here.
    suspended: { type: Boolean, select: false },
    suspensionFenceEpoch: { type: Number, select: false },
    accountFenceEpoch: { type: Number, select: false },
  },
  { timestamps: true }
);

export const Participant =
  (mongoose.models.Participant as mongoose.Model<IParticipant>) ||
  mongoose.model<IParticipant>("Participant", ParticipantSchema);

/* ============== ParticipantIdentityKeyVersion ========================= */
export type ParticipantIdentityPurpose = "participation" | "block-safety";

export interface IParticipantIdentityKeyVersion extends Document {
  purpose: ParticipantIdentityPurpose;
  version: number;
  normalizationVersion: number;
}

const ParticipantIdentityKeyVersionSchema =
  new Schema<IParticipantIdentityKeyVersion>(
    {
      purpose: {
        type: String,
        enum: ["participation", "block-safety"],
        required: true,
      },
      version: { type: Number, required: true, min: 1 },
      normalizationVersion: { type: Number, required: true, min: 1 },
    },
    { versionKey: false }
  );

ParticipantIdentityKeyVersionSchema.index(
  { purpose: 1, version: 1 },
  { unique: true, name: "participant_identity_key_version_unique" }
);

export const ParticipantIdentityKeyVersion =
  (mongoose.models.ParticipantIdentityKeyVersion as mongoose.Model<IParticipantIdentityKeyVersion>) ||
  mongoose.model<IParticipantIdentityKeyVersion>(
    "ParticipantIdentityKeyVersion",
    ParticipantIdentityKeyVersionSchema
  );

/* ================= ParticipantDeletionOperation ================= */
// W4-P2's dormant deletion foundation. This is deliberately separate from
// ParticipantVerification: proving mailbox control for deletion must never be
// redeemable as ordinary participant verification or authority.
export const PARTICIPANT_DELETION_PHASES = [
  "waiting",
  "ready",
  "challengeIssued",
  "authorized",
  "completed",
  "canceled",
] as const;

export type ParticipantDeletionPhase = (typeof PARTICIPANT_DELETION_PHASES)[number];

export interface IParticipantDeletionOperation extends Document {
  operationId: string;
  namespaceBinding?: string;
  participantId?: Types.ObjectId;
  emailBinding?: string;
  authorityVersion?: number;
  phase?: ParticipantDeletionPhase;
  readinessGeneration?: number;
  challengeGeneration?: number;
  readyAt?: Date;
  challengeDigest?: string;
  challengeIssuedAt?: Date;
  challengeCooldownEndsAt?: Date;
  challengeExpiresAt?: Date;
  challengeAttemptsRemaining?: number;
  authorizedAt?: Date;
  authorizationExpiresAt?: Date;
  canceledAt?: Date;
  completedAt?: Date;
  recoveryCapabilityDigest?: string;
  recoveryExpiresAt?: Date;
  createdAt?: Date;
  updatedAt?: Date;
}

const ParticipantDeletionOperationSchema = new Schema<IParticipantDeletionOperation>(
  {
    // Opaque, server-created identity. Unlike a Request operation identity,
    // no client ever supplies or reuses this value.
    operationId: { type: String, required: true, trim: true, unique: true },
    namespaceBinding: { type: String, match: /^dn1_[0-9a-f]{64}$/, select: false },
    participantId: {
      type: Schema.Types.ObjectId,
      ref: "Participant",
      required: function (this: IParticipantDeletionOperation) {
        return this.phase !== "completed" && this.phase !== undefined;
      },
      select: false,
    },
    // Purpose-separated HMAC of the normalized verified address. Keeping this
    // binding rather than the address itself lets every later security command
    // prove the intended mailbox without duplicating ordinary account data.
    emailBinding: {
      type: String,
      required: function (this: IParticipantDeletionOperation) {
        return this.phase !== "completed" && this.phase !== undefined;
      },
      select: false,
    },
    authorityVersion: {
      type: Number,
      required: function (this: IParticipantDeletionOperation) {
        return this.phase !== "completed" && this.phase !== undefined;
      },
      min: INITIAL_PARTICIPANT_AUTHORITY_VERSION,
      max: MAXIMUM_PARTICIPANT_AUTHORITY_VERSION,
      validate: {
        validator: Number.isInteger,
        message: "authorityVersion must be an integer",
      },
      select: false,
    },
    phase: { type: String, enum: PARTICIPANT_DELETION_PHASES },
    // Advances only when an authoritative waiting->ready reconciliation wins.
    // It fences stale readiness/challenge decisions without persisting a
    // blocker inventory or answer.
    readinessGeneration: {
      type: Number,
      required: function (this: IParticipantDeletionOperation) {
        return this.phase !== "completed" && this.phase !== undefined;
      },
      min: 0,
    },
    // Advances on every issue/reissue. It survives challenge cleanup so a
    // current challenge cannot be confused with a superseded one.
    challengeGeneration: { type: Number, min: 0, default: 0 },
    readyAt: { type: Date, select: false },
    challengeDigest: { type: String, select: false },
    challengeIssuedAt: { type: Date, select: false },
    // The last issue's cooldown survives exhaustion of its live challenge.
    challengeCooldownEndsAt: { type: Date, select: false },
    challengeExpiresAt: { type: Date, select: false },
    challengeAttemptsRemaining: { type: Number, min: 0, select: false },
    authorizedAt: { type: Date, select: false },
    authorizationExpiresAt: { type: Date, select: false },
    canceledAt: { type: Date, select: false },
    completedAt: { type: Date, select: false },
    recoveryExpiresAt: { type: Date, select: false },
    recoveryCapabilityDigest: {
      type: String,
      match: /^[0-9a-f]{64}$/,
      select: false,
    },
  },
  { timestamps: true, versionKey: false }
);

// Terminal history is deliberately retained, but one participant can own only
// one live lifecycle. This is the concurrency primitive; callers must never
// substitute a read-before-insert check for it.
ParticipantDeletionOperationSchema.index(
  { participantId: 1 },
  {
    unique: true,
    partialFilterExpression: {
      phase: { $in: ["waiting", "ready", "challengeIssued", "authorized"] },
    },
    name: "participant_deletion_one_active_operation_per_participant",
  }
);
// Internal reconciliation/status queries only. These are not TTL indexes: an
// expired deadline changes phase only when an internal command observes it.
ParticipantDeletionOperationSchema.index(
  { participantId: 1, phase: 1 },
  { name: "participant_deletion_owner_phase" }
);
ParticipantDeletionOperationSchema.index(
  { phase: 1, challengeExpiresAt: 1 },
  { name: "participant_deletion_challenge_expiry" }
);
ParticipantDeletionOperationSchema.index(
  { phase: 1, authorizationExpiresAt: 1 },
  { name: "participant_deletion_authorization_expiry" }
);
ParticipantDeletionOperationSchema.index(
  { phase: 1, recoveryExpiresAt: 1 },
  { name: "participant_deletion_recovery_expiry" }
);

export const ParticipantDeletionOperation =
  (mongoose.models.ParticipantDeletionOperation as mongoose.Model<IParticipantDeletionOperation>) ||
  mongoose.model<IParticipantDeletionOperation>(
    "ParticipantDeletionOperation",
    ParticipantDeletionOperationSchema
  );


/* ====================== ParticipantVerification ======================= */
// The live emailed-code challenge for one address (W3-I1). At most one exists
// per address at a time — that is what makes a resend *supersede* the previous
// code rather than leave two working codes in two inboxes — and it is enforced
// by the unique index below, not by reading first and deciding.
export interface IParticipantVerification extends Document {
  email: string;
  codeDigest: string;
  issuedAt: Date;
  expiresAt: Date;
  attemptsRemaining: number;
  redemptionFenceEpoch?: number;
  redeemedAt?: Date | null;
  deleteAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const ParticipantVerificationSchema = new Schema<IParticipantVerification>(
  {
    email: {
      type: String,
      required: true,
      unique: true,
      trim: true,
      lowercase: true,
    },
    // HMAC-SHA256 of the emailed code, keyed by the participant signing secret
    // and bound to this address (`src/participantCredentials.ts`). The raw code
    // exists only in the email; nothing persists or logs it, and `select: false`
    // keeps the digest out of ordinary reads like every other credential field.
    codeDigest: { type: String, required: true, select: false },
    // When this challenge was issued. The resend cooldown is measured from it,
    // so a supersede cannot be used to mail an address repeatedly.
    issuedAt: { type: Date, required: true },
    expiresAt: { type: Date, required: true },
    // Counts down on each wrong code, by conditional atomic decrement, so
    // concurrent guesses cannot both spend the same remaining attempt.
    attemptsRemaining: { type: Number, required: true, min: 0 },
    redemptionFenceEpoch: { type: Number, min: 0, select: false },
    // Set by the one mutation that wins redemption. The row survives to its
    // original expiry afterwards so a duplicate submission of the same code —
    // a double tap, a retried request — is answered as the success it already
    // was rather than as an invalid code.
    redeemedAt: { type: Date },
    // TTL. Set past `expiresAt`, so a spent or lapsed challenge stops being
    // matchable long before it stops existing, and nothing accumulates.
    deleteAt: {
      type: Date,
      required: true,
      index: {
        expireAfterSeconds: 0,
        name: "participant_verification_deleteAt_ttl",
      },
    },
  },
  { timestamps: true }
);

export const ParticipantVerification =
  (mongoose.models.ParticipantVerification as mongoose.Model<IParticipantVerification>) ||
  mongoose.model<IParticipantVerification>(
    "ParticipantVerification",
    ParticipantVerificationSchema
  );


/* =========================== ParticipantBlock ========================= */
// One participant's block of one other participant (W4-U1.3).
//
// A row is owned by `blockerParticipantId` and is the only thing that blocker
// may later remove. Two participants who block each other hold two rows, and
// removing one never restores eligibility while the other remains. Whether a
// pair is fenced is decided by the existence of a row in *either* direction;
// nothing here, and nothing on any wire, says who initiated it.
//
// Deliberately its own collection, following the `RequestParticipation`
// precedent, rather than a field on `Request`: `Request` is TTL-deleted
// (`deleteAt`), and a block has to outlive the interaction it came from. It has
// no TTL of its own either — a row with a lapsed context is exactly the
// indistinguishable `Blocked student` entry the contract forbids.
//
// The context snapshot is the minimum that lets the owner recognise the block
// later without learning anything new: the blocked party's role in the
// interaction, the request's dining location, and the request's creation time.
// All three were already shown to the owner. No name, address, participant
// identifier, or order content is stored, and nothing here is copied from a
// private field. The snapshot is deleted with the row on Unblock.
export type ParticipantBlockedRole = "requester" | "helper";

export interface IParticipantBlock extends Document {
  blockerParticipantId: Types.ObjectId;
  blockedParticipantId?: Types.ObjectId;
  blockedSafetyKeyVersion: number;
  blockedSafetyHmac: string;
  /** The role the *blocked* participant had in the interaction. */
  blockedRole: ParticipantBlockedRole;
  diningLocation: string;
  interactionAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const ParticipantBlockSchema = new Schema<IParticipantBlock>(
  {
    // Private identity fields, `select: false` like every other participant
    // reference in this file: never a public read target and never projected.
    blockerParticipantId: {
      type: Schema.Types.ObjectId,
      ref: "Participant",
      required: true,
      select: false,
    },
    blockedParticipantId: {
      type: Schema.Types.ObjectId,
      ref: "Participant",
      select: false,
    },
    blockedSafetyKeyVersion: {
      type: Number,
      required: true,
      min: 1,
      validate: Number.isInteger,
      select: false,
    },
    blockedSafetyHmac: {
      type: String,
      required: true,
      match: /^[0-9a-f]{64}$/,
      select: false,
    },
    blockedRole: {
      type: String,
      enum: ["requester", "helper"],
      required: true,
    },
    diningLocation: { type: String, required: true, trim: true },
    interactionAt: { type: Date, required: true },
  },
  { timestamps: true }
);

// One owned row per ordered pair: re-blocking the same participant is an
// idempotent no-op rather than a second row, and the pair's two directions
// remain two independent rows.
ParticipantBlockSchema.index(
  { blockerParticipantId: 1, blockedParticipantId: 1 },
  {
    unique: true,
    partialFilterExpression: { blockedParticipantId: { $type: "objectId" } },
    name: "participant_block_owner_target_live_unique",
  }
);

ParticipantBlockSchema.index(
  {
    blockerParticipantId: 1,
    blockedSafetyKeyVersion: 1,
    blockedSafetyHmac: 1,
  },
  {
    unique: true,
    partialFilterExpression: { blockedSafetyHmac: { $type: "string" } },
    name: "participant_block_owner_safety_unique",
  }
);

ParticipantBlockSchema.index(
  { blockedSafetyKeyVersion: 1, blockedSafetyHmac: 1 },
  {
    partialFilterExpression: { blockedSafetyHmac: { $type: "string" } },
    name: "participant_block_safety_lookup",
  }
);

// The reverse direction of the fence: "who has blocked this participant".
// Fence checks and board exclusion read both directions for one caller.
ParticipantBlockSchema.index(
  { blockedParticipantId: 1 },
  {
    partialFilterExpression: { blockedParticipantId: { $type: "objectId" } },
    name: "participant_block_blocked_lookup",
  }
);

export const ParticipantBlock =
  (mongoose.models.ParticipantBlock as mongoose.Model<IParticipantBlock>) ||
  mongoose.model<IParticipantBlock>("ParticipantBlock", ParticipantBlockSchema);
