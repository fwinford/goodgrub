import { isEffectivelyAvailable } from "./requestAvailability.js";

export type RequestResponseDate = Date | string;

export interface PublicRequestDocument {
  _id: unknown;
  vendor: string;
  /** The derived single-line summary of the structured fields below
   * (W4-R4, `deriveFoodSummary`). Retained on the wire because every
   * already-accepted helper surface renders it. */
  food: string;
  pickupWindowText: string;
  /**
   * V1 meal-swipe requirement (W3-C1), widened to 0-5 by W4-R4 so a
   * Dining-Dollars-only request can state that it needs none. Every shape
   * `POST /api/request` accepts, including the legacy web one, has required
   * an integer since C1 — that is the production boundary this projection
   * trusts, not something it re-validates. A document reaching this
   * projection without one is a malformed/pre-C1 stored row, not a supported
   * outcome of any accepted submission, and is out of scope for this
   * projection to paper over.
   */
  mealSwipes: number;
  /**
   * W4-R4 structured representation. Same privacy class as `food`, which is
   * derived from it: requester-entered request content that helpers have
   * always been shown, never a newly exposed private field. Projected
   * alongside `food` so a later, separately routed H1 consumption sync can
   * present the structure directly instead of parsing the summary string.
   */
  menuPath: string;
  /** Legacy strings may be read from disposable pre-final-R4 rows, but are
   * normalized to objects before any projection leaves this module. */
  mealItems?: Array<{ name: string; details?: string }> | string[] | null;
  orderDetails?: string | null;
  estimatedDiningDollarsCents?: number | null;
  windowStart?: RequestResponseDate | null;
  windowEnd?: RequestResponseDate | null;
  status: string;
  createdAt: RequestResponseDate;
  /**
   * When helpers begin seeing this request. Read for availability only; it is
   * deliberately not projected onto the public response, which already carries
   * the same instant as `windowStart` for a scheduled request and as
   * `createdAt` for an ASAP one.
   */
  visibleFrom?: RequestResponseDate | null;
  expiresAt: RequestResponseDate;
  claimExpiresAt?: RequestResponseDate | null;
  /**
   * W4-H2 participant-scoped ownership projection. Present on a document only
   * when the caller's query explicitly selected it
   * (`.select("+requesterParticipantId")`); never itself part of any public
   * wire response — the list and detail builders read it only through
   * `isCallerOwnRequest` to derive `isOwnRequest`, and never copy the raw id
   * onto a response.
   */
  requesterParticipantId?: unknown;
  /**
   * W4-R5 content revision. Present only when a read explicitly selected it
   * (`select: false` on the model); projected only by the single-request
   * detail response, where it lets a tapped notification say truthfully that
   * the request changed since it was sent. Never projected by the list.
   */
  contentRevision?: number | null;
}

export interface RequestListDocument
  extends Omit<PublicRequestDocument, "expiresAt"> {
  expiresAt?: RequestResponseDate | null;
  claimExpiresAt?: RequestResponseDate | null;
}

export interface PublicRequestResponse<Status extends string = string> {
  id: string;
  vendor: string;
  food: string;
  pickupWindowText: string;
  mealSwipes: number;
  /** W4-R4 structured representation; see `PublicRequestDocument`. */
  menuPath: string;
  mealItems: Array<{ name: string; details?: string }> | string[];
  orderDetails: string | null;
  estimatedDiningDollarsCents: number | null;
  windowStart: RequestResponseDate | null;
  windowEnd: RequestResponseDate | null;
  status: Status;
  createdAt: RequestResponseDate;
  expiresAt: RequestResponseDate;
  /**
   * W4-H2: present and `true` only for the exact verified participant whose
   * resolved authority produced this list response, on exactly their own
   * request. Absent for every other request in the same response and for
   * every anonymous/unresolved caller — never an explicit `false` — matching
   * the existing `alreadyParticipated` (W3-H2 detail) precedent of only
   * conveying an affirmative caller-relative signal.
   */
  isOwnRequest?: boolean;
  /** W4-R5: detail only; see `PublicRequestDocument.contentRevision`. */
  contentRevision?: number;
}

/**
 * The list advertises availability, not storage. An expired claim stays
 * persisted as `claimed` — nothing here mutates it — but a request that is
 * effectively available is advertised as `open`, so a single wire value never
 * has to mean both "claimable" and "someone is already helping".
 */
export interface PublicRequestListResponse {
  requests: PublicRequestResponse<"open">[];
}

export interface PublicRequestDetailResponse {
  request: PublicRequestResponse;
}

/**
 * Who, if anyone, this response's caller-relative ownership is being computed
 * for (W4-H2). The three cases are deliberately distinct on the wire:
 *
 * - `resolved` — a verified participant. Ownership is knowable, so the
 *   response states it either way (`true` or `false`).
 * - `anonymous` — no credential was presented at all. Creating a request
 *   requires participant authority, so an anonymous session owns nothing;
 *   the field is omitted and the client reads that, together with its own
 *   knowledge that it sent no credential, as "not own for an anonymous
 *   browser".
 * - `unresolved` — a credential *was* presented but could not be resolved
 *   (invalid, superseded, or a lookup/configuration failure). Ownership is
 *   genuinely unknown, the field is omitted, and the client must fail closed.
 *
 * Collapsing `unresolved` into `anonymous` is what previously let an
 * unusable credential read as an authoritative "not your request".
 */
export type CallerOwnershipContext =
  | { kind: "anonymous" }
  | { kind: "unresolved" }
  | { kind: "resolved"; participantId: string };

/**
 * The single caller-relative ownership comparison (W4-H2), shared by the list
 * and detail projections so the sensitive `requesterParticipantId` comparison
 * exists in exactly one place.
 *
 * Returns the exact value to serialize: `true`/`false` for a resolved caller,
 * and `undefined` — meaning "omit the field" — whenever ownership is not
 * knowable. The internal context enum is never serialized, and the raw
 * `requesterParticipantId` is never returned to any caller of this function.
 */
export function callerOwnershipFor(
  document: { requesterParticipantId?: unknown },
  context: CallerOwnershipContext
): boolean | undefined {
  if (context.kind !== "resolved") return undefined;
  return (
    Boolean(document.requesterParticipantId) &&
    String(document.requesterParticipantId) === context.participantId
  );
}

function dateValue(value: RequestResponseDate | null | undefined): number {
  return value == null ? Number.NaN : new Date(value).getTime();
}

/**
 * A legacy bare-string array (disposable pre-final-R4 rows) passes through
 * exactly as read — unchanged, existing read behavior this projection does
 * not alter. A structured array is rebuilt as plain `{ name, details? }`
 * objects rather than spread through as-is, which is what actually
 * guarantees no internal field (an embedded subdocument's own `_id`, or any
 * other Mongoose bookkeeping a live, non-`.lean()` document may carry)
 * reaches the wire.
 */
function normalizeMealItems(
  mealItems: Array<{ name: string; details?: string }> | string[] | null | undefined
): Array<{ name: string; details?: string }> | string[] {
  if (!mealItems) return [];
  if (mealItems.every((item): item is string => typeof item === "string")) {
    return mealItems;
  }
  return (mealItems as Array<{ name: string; details?: string }>).map((item) =>
    item.details !== undefined ? { name: item.name, details: item.details } : { name: item.name }
  );
}

function isAvailable(
  document: RequestListDocument,
  serverNow: Date
): document is RequestListDocument & {
  status: "open" | "claimed";
  expiresAt: RequestResponseDate;
} {
  return isEffectivelyAvailable(document, serverNow);
}

export function mapPublicRequestFields<Status extends string>(
  document: PublicRequestDocument & { status: Status }
): PublicRequestResponse<Status> {
  return {
    id: String(document._id),
    vendor: document.vendor,
    food: document.food,
    pickupWindowText: document.pickupWindowText,
    mealSwipes: document.mealSwipes,
    menuPath: document.menuPath,
    // Normalized to a definite shape on the wire — an array and two explicit
    // nulls — so no client has to distinguish "absent" from "none". The
    // allowlist itself is unchanged in kind: every value here is
    // requester-entered request content, and no private field is added.
    // New writes are structured objects. This preserves only read behavior
    // for disposable legacy documents that remain in broad route fixtures;
    // no create schema accepts the flat form.
    mealItems: normalizeMealItems(document.mealItems),
    orderDetails: document.orderDetails ?? null,
    estimatedDiningDollarsCents: document.estimatedDiningDollarsCents ?? null,
    windowStart: document.windowStart ?? null,
    windowEnd: document.windowEnd ?? null,
    status: document.status,
    createdAt: document.createdAt,
    expiresAt: document.expiresAt,
  };
}

/**
 * Unlike the list, the detail response advertises a real, individually
 * fetched request, so an unavailable one still needs a truthful status
 * rather than being dropped. A claim-expired request is effectively
 * available again; every other status is reported as persisted.
 */
export function buildPublicRequestDetailResponse(
  document: PublicRequestDocument,
  serverNow: Date,
  /**
   * Who this response's ownership is computed for (W4-H2). Never changes the
   * request content or status — only whether the response also states
   * `isOwnRequest`, exactly as the list projection does. Detail previously
   * derived no ownership at all, which left an owner's own request
   * indistinguishable on this route from a stranger's.
   */
  ownershipContext: CallerOwnershipContext = { kind: "anonymous" },
  /**
   * W4-R5: whether to project `contentRevision`. Only the single-request
   * detail read does; the create and claim responses keep their accepted wire
   * shape unchanged.
   */
  options: { includeContentRevision?: boolean } = {}
): PublicRequestDetailResponse {
  const mapped = mapPublicRequestFields(document);
  const request: PublicRequestResponse = {
    ...mapped,
    status: isEffectivelyAvailable(document, serverNow) ? "open" : mapped.status,
  };
  // `undefined` means omit — ownership is not knowable for this caller. The
  // raw `requesterParticipantId` never reaches the wire
  // (`mapPublicRequestFields` does not read it).
  const isOwnRequest = callerOwnershipFor(document, ownershipContext);
  const withRevision: PublicRequestResponse =
    options.includeContentRevision === true &&
    typeof document.contentRevision === "number" &&
    Number.isInteger(document.contentRevision) &&
    document.contentRevision >= 1
      ? { ...request, contentRevision: document.contentRevision }
      : request;
  if (isOwnRequest === undefined) return { request: withRevision };
  return { request: { ...withRevision, isOwnRequest } };
}

/**
 * Ordering only; membership is decided by `isEffectivelyAvailable` above.
 *
 * The imminent-versus-later split predates the W3-R1 visibility rule. Now that
 * a request is withheld until its own start, every document reaching this sort
 * has already begun, so the split no longer separates anything and the result
 * is creation order. It is left in place because it still orders correctly for
 * rows persisted before `visibleFrom` existed, which carry a future
 * `windowStart` and are advertised immediately. Retiring it is an ordering
 * decision, not part of the timing contract.
 */
export function buildPublicRequestListResponse(
  documents: RequestListDocument[],
  serverNow: Date,
  /**
   * Who this response's ownership is computed for (W4-H2). Never changes
   * membership or order — only whether an already-included request also
   * states `isOwnRequest`.
   */
  ownershipContext: CallerOwnershipContext = { kind: "anonymous" }
): PublicRequestListResponse {
  const hourLater = serverNow.getTime() + 60 * 60 * 1000;
  const available = documents.filter((document) =>
    isAvailable(document, serverNow)
  );

  available.sort((left, right) => {
    const leftWindowStart = dateValue(left.windowStart);
    const rightWindowStart = dateValue(right.windowStart);
    const leftIsAsap =
      Number.isNaN(leftWindowStart) || leftWindowStart <= hourLater;
    const rightIsAsap =
      Number.isNaN(rightWindowStart) || rightWindowStart <= hourLater;

    if (leftIsAsap !== rightIsAsap) {
      return leftIsAsap ? -1 : 1;
    }

    if (leftIsAsap) {
      return dateValue(left.createdAt) - dateValue(right.createdAt);
    }

    return leftWindowStart - rightWindowStart;
  });

  return {
    requests: available.slice(0, 20).map((document) => {
      const mapped = {
        ...mapPublicRequestFields(document),
        // Derived from effective availability, never written back to the record.
        status: "open" as const,
      };
      // W4-H2: stated either way for a resolved caller, omitted when
      // ownership is not knowable. `requesterParticipantId` itself is never
      // copied onto the response above (`mapPublicRequestFields` does not
      // read it), so this is the sole place ownership truth reaches the wire.
      const isOwnRequest = callerOwnershipFor(document, ownershipContext);
      if (isOwnRequest === undefined) return mapped;
      return { ...mapped, isOwnRequest };
    }),
  };
}
