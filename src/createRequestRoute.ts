import type { Request, Response } from "express";
import mongoose, { type Types } from "mongoose";
import { Resend } from "resend";
import { assertExternalProvidersAllowed, isReviewRuntime } from "./externalProviders.js";
import { z } from "zod";
import {
  type IRequest,
  Request as MealRequest,
  REQUEST_OPERATION_CREATED,
  REQUEST_OPERATION_NO_CREATE,
  RequestOperation,
} from "../models/db.js";
import { escapeHtml } from "./htmlEscape.js";
import {
  checkOperationAuthority,
  sendOperationAuthorityRefusal,
} from "./requestOperationAuthority.js";
import { startHelperNewRequestPush } from "./helperNewRequestPush.js";
import { isValidRawInstallationCredential } from "./installationCredential.js";
import { notifySubscribersForRequest } from "./notifySubscribers.js";
import { carriesModerationHold, isVisibleNow } from "./requestAvailability.js";
import {
  INITIAL_CONTENT_REVISION,
  INITIAL_NOTIFICATION_GENERATION,
} from "./requestRevision.js";
import { resolveRequestInstallationAssociation } from "./requestInstallationAssociation.js";
import {
  isSupportedVendor,
  UNSUPPORTED_VENDOR_MESSAGE,
} from "./supportedVendors.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";
import { formatMealRequestWindow } from "./utils/date.js";
import { countTodaysRequests, isUnderDailyLimit } from "./requestDailyQuota.js";
import {
  isAcceptableScheduledStart,
  resolveAsapTiming,
  resolveScheduledTiming,
  type RequestTimingWindow,
} from "./requestTiming.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import {
  RequesterSuspendedError,
  assertRequesterNotSuspendedWithinSession,
  PARTICIPANT_SUSPENDED_CODE,
  PARTICIPANT_SUSPENDED_MESSAGE,
} from "./moderationEnforcement.js";
import {
  touchParticipantAccountsInSession,
  ParticipantAccountFenceUnavailable,
} from "./participantAccountFence.js";
import {
  PARTICIPANT_PRINCIPAL_MISMATCH_CODE,
  PARTICIPANT_PRINCIPAL_MISMATCH_MESSAGE,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import {
  deriveFoodSummary,
  refineStructuredRequest,
  structuredAuthoredTexts,
  structuredRequestFields,
  type StructuredRequestInput,
} from "./structuredRequest.js";
import { sendDay4Error } from "./day4Errors.js";
import { isParticipantTextAllowed } from "./participantTextFilter.js";
import { emailSender } from "./emailSender.js";

/**
 * Per-IP create throttle that returns the structured error envelope. Because
 * create is non-idempotent, iOS must distinguish this definitive pre-write
 * refusal from an unreadable, potentially committed response.
 */
export const createRequestRateLimiter = createDay4MutationRateLimiter(5);

/**
 * W3-D1: the exact logical create-operation identity, carried in a header
 * rather than the body for the same reasons the participant credential is
 * (`participantAuthorityGate.ts`) — it is not request content, and keeping it
 * out of the `.strict()` create schemas means every existing shape stays
 * unchanged. Optional: a caller that sends none gets the exact pre-D1
 * behavior, so the legacy web form and any iOS build before Pass 2 wiring
 * remain fully valid.
 */
export const OPERATION_IDENTITY_HEADER = "x-commonplate-operation-id";

/** The presented operation identity was absent-but-malformed: present twice,
 * or present once but not a value the backend will ever accept as an exact
 * identity. Refused before any read or write, exactly like a malformed
 * payload field — never guessed at or heuristically repaired. */
export const INVALID_OPERATION_ID_CODE = "INVALID_OPERATION_ID";
export const INVALID_OPERATION_ID_MESSAGE =
  "Invalid request operation identity";

/**
 * The presented operation identity is already bound to a Request created by a
 * different participant. Refused generically, with no detail about the
 * existing request, so the identity cannot be used to discover, reconcile, or
 * retrieve another participant's private state.
 */
export const OPERATION_UNAUTHORIZED_CODE = "OPERATION_UNAUTHORIZED";
export const OPERATION_UNAUTHORIZED_MESSAGE =
  "This request cannot be completed with your current verification.";

/**
 * The presented operation identity was once bound to a Request, but that
 * Request has passed its bounded recovery horizon (`RequestOperation` in
 * `models/db.ts`) — it is no longer active/actionable, and MongoDB's TTL may
 * already have reclaimed the document. This is a terminal, definitive
 * non-create outcome: it must never fall through to a fresh create merely
 * because the original Request is gone. A later intentional submission uses
 * a new operation identity.
 */
export const OPERATION_EXPIRED_CODE = "OPERATION_EXPIRED";
export const OPERATION_EXPIRED_MESSAGE =
  "This request can no longer be recovered. Submit a new request if you still want one.";

/**
 * W4-U1.2 (Faith decision 2026-10-19): the exact operation did create its
 * Request, which has since become unavailable through moderation. Distinct
 * from `OPERATION_EXPIRED`, which keeps its meaning for a genuinely
 * expired/unrecoverable operation. Content-free: no request, marker or
 * reason is carried.
 */
export const REQUEST_CREATED_UNAVAILABLE_CODE = "REQUEST_CREATED_UNAVAILABLE";
export const REQUEST_CREATED_UNAVAILABLE_MESSAGE =
  "Your request was posted, but it's no longer available.";

/**
 * W4-D2 terminal NO-CREATE: backend authority has durably established that
 * this exact operation identity never created a Request and never will
 * (`requestOperationTerminalRoute.ts`). Definitive, permanent, and distinct
 * from `OPERATION_EXPIRED`, which says a Request once existed. Presenting the
 * same identity again never falls through to validation or a create.
 */
export const OPERATION_NOT_CREATED_CODE = "OPERATION_NOT_CREATED";
export const OPERATION_NOT_CREATED_MESSAGE =
  "This request was not posted. Submit a new request if you still want one.";

/**
 * W4-U1.1 definitive pre-mutation refusal: requester-authored request text
 * matched the participant-text filter (`participantTextFilter.ts`). Returned
 * only after canonical validation and only for a genuinely new create attempt
 * — an exact-operation replay is answered by reconciliation before this is
 * ever reached — and strictly before the daily-limit read, the Request and
 * `RequestOperation` writes, the requester confirmation, and both helper
 * notifications. Nothing is written, so the refusal is never ambiguous.
 *
 * The message is the approved neutral requester copy. Neither it nor any other
 * part of the response names the matched text, field, or term, and nothing
 * about the match is logged.
 */
export const REQUEST_TEXT_NOT_ALLOWED_CODE = "REQUEST_TEXT_NOT_ALLOWED";
export const REQUEST_TEXT_NOT_ALLOWED_MESSAGE =
  "Keep request details respectful and food-related.";

const OPERATION_ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;

export function isValidOperationId(value: string): boolean {
  return OPERATION_ID_PATTERN.test(value);
}

/**
 * Reads the presented operation identity header.
 *
 * `undefined` means no identity was presented at all — idempotency was not
 * requested, and the caller gets ordinary non-idempotent create behavior.
 * `null` means something was presented that can never be a valid identity —
 * Express collapses a repeated header into an array, and two identities is not
 * one exact identity, exactly the same reasoning the participant gate applies
 * to its own header.
 */
export function readOperationIdentity(req: Request): string | null | undefined {
  const header = req.headers?.[OPERATION_IDENTITY_HEADER];
  if (header === undefined) return undefined;
  if (typeof header === "string") return header;
  return null;
}

function isDuplicateKeyError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === 11000
  );
}

/** Whether a persisted Request's private requester binding is this exact
 * verified participant — the sole authority check on operation reconciliation. */
function operationBelongsToParticipant(
  document: { requesterParticipantId?: unknown },
  participantId: string
): boolean {
  return (
    document.requesterParticipantId !== undefined &&
    document.requesterParticipantId !== null &&
    String(document.requesterParticipantId) === participantId
  );
}

export type OperationReconciliation =
  | { outcome: "created"; document: PublicRequestDocument }
  | { outcome: "unauthorized" }
  | { outcome: "expired" }
  | { outcome: "created-unavailable" }
  | { outcome: "not-created" }
  | { outcome: "not-found" };

/**
 * The exact-identity lookup/authority check D1 requires, shared by the
 * pre-write reconciliation check and the post-write duplicate-key race
 * fallback below. Never matches on anything but the exact `operationId`
 * value — no payload, timestamp, or recency ever enters this query.
 *
 * The ledger row (`RequestOperation`), not the Request document, is the
 * durable identity: it survives the Request's own TTL cleanup. A ledger row
 * whose Request has since been reclaimed means the operation is outside its
 * bounded recovery horizon — a terminal `"expired"` outcome, never
 * `"not-found"`, so cleanup of the original Request can never make this exact
 * identity look like a fresh one.
 *
 * W4-D2: a terminal NO-CREATE row answers `"not-created"`, but only to the
 * participant that owns it — the ownership check runs first, so another
 * participant learns nothing about which terminal outcome the identity holds.
 * `"not-found"` remains what it always was: no row yet, which is never
 * terminal authority on its own.
 */
async function reconcileOperation(
  operationId: string,
  participantId: string
): Promise<OperationReconciliation> {
  const ledgerEntry = await RequestOperation.findOne({ operationId })
    .select("+participantId +requestId +ownerDeleted")
    .lean()
    .exec();
  if (!ledgerEntry) return { outcome: "not-found" };
  if (ledgerEntry.ownerDeleted === true) return { outcome: "unauthorized" };
  if (String(ledgerEntry.participantId) !== participantId) {
    return { outcome: "unauthorized" };
  }
  if (ledgerEntry.outcome === REQUEST_OPERATION_NO_CREATE) {
    return { outcome: "not-created" };
  }

  // `+externalOrderAffirmed` (W4-U1.3): the projection below derives effective
  // status from this document, and a request that must never read as available
  // cannot be told apart from one that may unless the private marker is read.
  const existing = await MealRequest.findOne({
    _id: ledgerEntry.requestId,
  }).select(
    "+requesterParticipantId +externalOrderAffirmed +moderationUnavailable +reservationLapseHold"
  );
  if (!existing) return { outcome: "expired" };
  if (!operationBelongsToParticipant(existing, participantId)) {
    // Defensive only: the ledger row is the authority check above already
    // relied on. A mismatch here would mean the ledger and the Request
    // disagree, which normal operation never produces.
    return { outcome: "unauthorized" };
  }
  // W4-U1.2: the operation did create this Request, but a hold (M or L) makes
  // it permanently unavailable. It is reported as created-then-unavailable,
  // never as available and never as expired. The ledger row still binds the
  // identity, so nothing can create a second Request. A placed request is
  // exempt: a moderation hold never undoes a placement.
  if (
    (existing as { status?: string }).status !== "placed" &&
    carriesModerationHold(existing)
  ) {
    return { outcome: "created-unavailable" };
  }
  return {
    outcome: "created",
    document: existing as unknown as PublicRequestDocument,
  };
}

/**
 * The outcome of an operation-scoped create attempt. `"fresh"` means this
 * exact call won the write and must be treated as an ordinary new creation —
 * `201`, requester confirmation email, and helper notification dispatch, the
 * same as a non-idempotent create. `"reconciled"` means this call lost a
 * concurrent race and is answering with someone else's already-decided
 * outcome instead, which must be treated exactly like the pre-write
 * reconciliation check above: a plain reconciliation response (or refusal),
 * never another `201` and never a second confirmation email or notification
 * dispatch for a Request this call did not actually create.
 */
type CreateWithOperationResult =
  | { kind: "fresh"; document: PublicRequestDocument }
  | { kind: "reconciled"; reconciliation: OperationReconciliation };

/**
 * Reserves the operation identity and creates the Request atomically, so a
 * process crash between the two writes can never leave a Request that TTL
 * cleanup could later make "fresh" again by silently freeing its identity —
 * the exact defect this correction fixes. The ledger insert
 * (`request_operation_ledger_identity_unique`), not this function, is what
 * makes "at most one Request per logical operation" true under real
 * concurrency: a racing insert for the same exact identity loses with a
 * duplicate-key error, and the whole transaction — Request included — rolls
 * back with it, leaving nothing to reconcile away.
 */
async function createRequestWithOperation(
  documentFields: Record<string, unknown>,
  operationId: string,
  participantId: string,
  principal: string,
  authorityVersion: number
): Promise<CreateWithOperationResult> {
  const session = await mongoose.startSession();
  try {
    let created: unknown = null;
    await session.withTransaction(async () => {
      // W4-U1.2 (boundary contract EO): the suspension gate and its
      // write-conflict anchor, inside the same transaction as the insert.
      await assertRequesterNotSuspendedWithinSession(participantId, session);
      const [createdDocument] = await MealRequest.create([documentFields], {
        session,
      });
      await RequestOperation.create(
        [
          {
            operationId,
            participantId,
            outcome: REQUEST_OPERATION_CREATED,
            requestId: createdDocument._id,
          },
        ],
        { session }
      );
      const fenced = await touchParticipantAccountsInSession(
        [participantId],
        session,
        new Map([[participantId, authorityVersion]])
      );
      if (fenced.get(participantId)?.principal !== principal) {
        throw new ParticipantAccountFenceUnavailable();
      }
      created = createdDocument;
    });
    return {
      kind: "fresh",
      document: created as unknown as PublicRequestDocument,
    };
  } catch (error) {
    // The concurrent-replay case (W3-D1 required proof: "same operation
    // identity submitted concurrently -> at most one Request"): this
    // transaction lost the race on `request_operation_ledger_identity_unique`
    // against another in-flight create for the same exact operation, and
    // aborted — including its Request insert. Reconciling here finds the
    // winner's row and answers with it instead of a spurious failure.
    // W4-D2: the winner may instead be terminalization's NO-CREATE row, in
    // which case this create resolves to that terminal outcome — never to a
    // write-uncertain failure merely because it lost the race.
    if (isDuplicateKeyError(error)) {
      const reconciliation = await reconcileOperation(
        operationId,
        participantId
      );
      if (reconciliation.outcome !== "not-found") {
        return { kind: "reconciled", reconciliation };
      }
    }
    throw error;
  } finally {
    await session.endSession();
  }
}

/**
 * W4-D2 exact-operation terminal authority. For one exact identity and the
 * participant already resolved from authority, answers the one terminal
 * outcome that identity holds, establishing NO-CREATE when nothing else has
 * won:
 *
 * - an identity that created answers `"created"` (or `"expired"` once that
 *   Request is gone) exactly as replay does;
 * - an identity owned by another participant answers `"unauthorized"`;
 * - an identity already terminalized answers `"not-created"` again;
 * - otherwise a NO-CREATE row is inserted and `"not-created"` is answered.
 *
 * The insert into `request_operation_ledger_identity_unique` — the same index
 * `createRequestWithOperation` inserts into inside its transaction — is the
 * linearization point. If the create's transaction commits first, this insert
 * loses with a duplicate-key error and the reconciliation below answers the
 * created outcome. If this insert commits first, the create's ledger insert
 * loses instead, its transaction (Request included) aborts, and that create
 * answers NO-CREATE. The leading read is only a fast path; it is never what
 * decides the outcome, so a missing row alone is never treated as terminal.
 *
 * Reads, stores, and needs no request content, and consumes no quota and
 * sends no notification: the only possible write is the NO-CREATE row.
 */
export async function terminalizeOperation(
  operationId: string,
  participantId: string,
  authorityVersion?: number
): Promise<Exclude<OperationReconciliation, { outcome: "not-found" }>> {
  const existing = await reconcileOperation(operationId, participantId);
  if (existing.outcome !== "not-found") return existing;

  const session = await mongoose.startSession();
  try {
    await session.withTransaction(async () => {
      const versions = authorityVersion === undefined
        ? new Map<string, number>()
        : new Map([[participantId, authorityVersion]]);
      await RequestOperation.create(
        [
          {
            operationId,
            participantId,
            outcome: REQUEST_OPERATION_NO_CREATE,
          },
        ],
        { session }
      );
      await touchParticipantAccountsInSession([participantId], session, versions);
    });
    return { outcome: "not-created" };
  } catch (error) {
    if (isDuplicateKeyError(error)) {
      const winner = await reconcileOperation(operationId, participantId);
      if (winner.outcome !== "not-found") return winner;
    }
    throw error;
  } finally {
    await session.endSession();
  }
}

async function createRequestWithoutOperation(
  documentFields: Record<string, unknown>,
  participantId: string,
  principal: string,
  authorityVersion: number
): Promise<IRequest> {
  const session = await mongoose.startSession();
  try {
    let created: IRequest | null = null;
    await session.withTransaction(async () => {
      // W4-U1.2 (boundary contract EO): the legacy no-operation create shares
      // the same suspension gate and write-conflict anchor.
      await assertRequesterNotSuspendedWithinSession(participantId, session);
      const [document] = await MealRequest.create([documentFields], { session });
      const fenced = await touchParticipantAccountsInSession(
        [participantId],
        session,
        new Map([[participantId, authorityVersion]])
      );
      if (fenced.get(participantId)?.principal !== principal) {
        throw new ParticipantAccountFenceUnavailable();
      }
      created = document;
    });
    if (!created) throw new Error("request creation transaction produced no document");
    return created;
  } finally {
    await session.endSession();
  }
}

const requesterString = z.string().trim().min(1);
/**
 * Shape only, and optional since W3-I1: the requester's identity is the
 * verified participant principal resolved from participant authority, never a
 * value from this payload. A client that still sends `email` is not refused for
 * the field's presence — the legacy web shape has always required it — but the
 * address it sends must be the one it verified, checked by
 * `matchesVerifiedPrincipal` below. Nothing here is ever persisted as the
 * requester.
 */
const submittedRequesterEmail = z.string().trim().toLowerCase().min(1);
const isoTimestamp = z.iso.datetime({ offset: true });

/**
 * iOS sends its existing installation credential with request creation
 * (Week 3 Day 6 Slice 6E) so the backend can resolve/establish the
 * originating installation for a later best-effort fulfillment push. Web
 * requests carry none, and stay valid without one — this is optional on
 * every schema that has it, never required. A present-but-malformed value is
 * a structural failure, exactly like every other malformed field on this
 * route, rather than a dedicated error code of its own.
 */
const optionalInstallationCredential = z
  .string()
  .refine(isValidRawInstallationCredential)
  .optional();

/**
 * W4-R4: `food` and `pickupName` are both gone from every accepted shape.
 * `pickupName` is removed from the V1 request contract entirely, and `food`
 * is no longer client-supplied at all — it is derived at creation from the
 * structured representation (`src/structuredRequest.ts`), so there is exactly
 * one authoritative request representation with no second flat-food ingress
 * path. `.strict()` on each schema below means a client still sending either
 * key is refused as a structural failure rather than having it silently
 * ignored.
 */
const requesterFields = {
  vendor: requesterString,
  email: submittedRequesterEmail.optional(),
};

const canonicalAsapSchema = z
  .object({
    ...requesterFields,
    ...structuredRequestFields,
    timing: z.literal("asap"),
    installationCredential: optionalInstallationCredential,
  })
  .strict()
  .superRefine(refineStructuredRequest);

/**
 * The requester selects one instant, and only one. Under the W3-R1 timing
 * contract the end of a request's availability is derived from its start
 * (`src/requestTiming.ts`), so `windowEnd` is deliberately absent from this
 * shape rather than accepted and discarded: taking an end the backend cannot
 * honour would let the requester believe they chose something they did not.
 * `.strict()` therefore refuses a payload that still carries one.
 */
const canonicalScheduledSchema = z
  .object({
    ...requesterFields,
    ...structuredRequestFields,
    timing: z.literal("scheduled"),
    windowStart: isoTimestamp,
    installationCredential: optionalInstallationCredential,
  })
  .strict()
  .superRefine(refineStructuredRequest);

const canonicalSchema = z.union([
  canonicalAsapSchema,
  canonicalScheduledSchema,
]);

/**
 * The website form's shape, kept accepting exactly the keys it has always
 * sent. Two of them are now shape-only:
 *
 * - `pickupWindowText` is still required, because a payload missing it has
 *   always been `INVALID_REQUEST`, but the persisted display text is derived
 *   from the backend's timing decision rather than taken from here. A client
 *   cannot describe a window the backend did not grant.
 * - `windowEnd` is still validated as a well-formed timestamp after
 *   `windowStart`, but no longer decides expiration: the start alone does.
 *   The web form's second time input is consequently vestigial and is left for
 *   the separate web pass rather than removed here.
 */
const legacyWebSchema = z
  .object({
    ...requesterFields,
    ...structuredRequestFields,
    pickupWindowText: requesterString,
    windowStart: isoTimestamp.optional(),
    windowEnd: isoTimestamp.optional(),
  })
  .strict()
  .superRefine((value, context) => {
    // W4-R4: the legacy web shape validates the exact same structured
    // representation the canonical iOS shapes do. The legacy form has no
    // control that can supply it — exactly as it already had no meal-swipe
    // picker (`docs/system-contract.md` section 6.2) — so its submissions
    // stay rejected as ordinary missing-field failures until the separate
    // website-parity work supplies them. Accepting a weaker flat shape here
    // instead would reintroduce the second, unstructured ingress path R4
    // exists to remove.
    refineStructuredRequest(value, context);
    const { windowStart, windowEnd } = value;
    if ((windowStart === undefined) !== (windowEnd === undefined)) {
      context.addIssue({
        code: "custom",
        path: [windowStart === undefined ? "windowStart" : "windowEnd"],
        message: "Legacy scheduled requests require both window fields",
      });
      return;
    }

    if (
      windowStart !== undefined &&
      windowEnd !== undefined &&
      new Date(windowEnd).getTime() <= new Date(windowStart).getTime()
    ) {
      context.addIssue({
        code: "custom",
        path: ["windowEnd"],
        message: "windowEnd must be after windowStart",
      });
    }
  });

/**
 * The validated create request. `structured` carries the complete W4-R4
 * structured representation exactly as submitted — this route persists those
 * values as received and derives `food` from them, never a fallback,
 * migrated, or inferred value.
 */
interface ValidatedCreateRequest {
  vendor: string;
  structured: StructuredRequestInput;
  /**
   * What the caller claimed, when it claimed anything. Compared against the
   * verified principal and then discarded; the persisted requester is always
   * the principal.
   */
  submittedEmail?: string;
  timing: "asap" | "scheduled";
  /**
   * The accepted scheduled start, on scheduled requests only. It is the sole
   * requester-supplied timing input: `visibleFrom`, `expiresAt`, `windowEnd`,
   * and the display text are all derived from it plus the backend clock.
   */
  windowStart?: Date;
  /** Present only on the canonical iOS shapes; the legacy web shape has none. */
  installationCredential?: string;
}

/**
 * Lifts the structured half out of an already-parsed create payload. The
 * `mealItems` normalization is deliberate rather than cosmetic: a Meal
 * Exchange request always persists an explicit array, and a
 * Dining-Dollars-only request always persists an empty one, so no reader
 * downstream has to distinguish "absent" from "none".
 */
function structuredFrom(data: StructuredRequestInput): StructuredRequestInput {
  return {
    menuPath: data.menuPath,
    mealSwipes: data.mealSwipes,
    mealItems: data.mealItems ?? [],
    orderDetails: data.orderDetails,
    estimatedDiningDollarsCents: data.estimatedDiningDollarsCents,
  };
}

const resend = new Resend(isReviewRuntime() ? "review-disabled" : process.env.RESEND_API_KEY);

/**
 * Backend-owned visibility and expiration. The client supplies neither — both
 * create schemas are `.strict()` — and both are written explicitly rather than
 * left to the schema's 24-hour `pre("save")` fallback, so what is persisted
 * always matches what the requester is told.
 *
 * ASAP: visible from the backend creation instant, for three hours.
 * Scheduled: visible from the accepted start, for three hours after it.
 *
 * `src/requestTiming.ts` owns both durations; nothing here recomputes them.
 */
function requestTimingWindow(
  validated: ValidatedCreateRequest,
  createdAt: Date
): RequestTimingWindow {
  if (validated.timing === "scheduled" && validated.windowStart) {
    return resolveScheduledTiming(validated.windowStart);
  }
  return resolveAsapTiming(createdAt);
}

function errorEnvelope(code: string, message: string) {
  return { error: { code, message } };
}

export function sendCreatedUnavailable(res: Response): Response {
  return res
    .status(410)
    .json(
      errorEnvelope(
        REQUEST_CREATED_UNAVAILABLE_CODE,
        REQUEST_CREATED_UNAVAILABLE_MESSAGE
      )
    );
}

function sendOperationNotCreated(res: Response): Response {
  return res
    .status(409)
    .json(errorEnvelope(OPERATION_NOT_CREATED_CODE, OPERATION_NOT_CREATED_MESSAGE));
}

function hasTiming(value: unknown): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    Object.prototype.hasOwnProperty.call(value, "timing")
  );
}

/**
 * A scheduled start must not already have passed, judged against this
 * handler's own `now` rather than any client clock.
 *
 * `src/requestTiming.ts` owns the rule and its boundary. Applying it here, in
 * shape validation, keeps the refusal ahead of the daily-limit read, the write,
 * the requester confirmation email, and both notification dispatches, so an
 * elapsed start produces no side effect of any kind.
 */
function isUsableScheduledStart(windowStart: Date, now: Date): boolean {
  return isAcceptableScheduledStart(windowStart, now);
}

/**
 * What helpers read on every ASAP request. The three-hour availability rule
 * is explained once, at the requester's timing choice (`RequestFoodView`'s
 * form / the legacy web form's radio label); this label deliberately does not
 * restate it, so every downstream surface that renders `pickupWindowText`
 * (lists, detail, requester/helper email) is not repeating policy the
 * requester already saw. `REQUEST_VISIBLE_DURATION_MS` remains the sole
 * source of the actual duration.
 */
export const ASAP_WINDOW_TEXT = "ASAP";

/**
 * What helpers read on every surface that renders a request. Derived here from
 * the backend's own timing decision, for both create shapes, so no client can
 * post display text that contradicts the availability it describes.
 *
 * The scheduled text is formatted in NYU campus time
 * (`formatMealRequestWindow`), so it reads the same to a helper in New York
 * and to one whose device is not.
 */
export function requestWindowText(
  timing: "asap" | "scheduled",
  window: RequestTimingWindow
): string {
  return timing === "asap"
    ? ASAP_WINDOW_TEXT
    : formatMealRequestWindow(window.visibleFrom, window.expiresAt);
}

function validateCreateShape(
  body: unknown,
  now: Date
): ValidatedCreateRequest | null {
  if (hasTiming(body)) {
    const result = canonicalSchema.safeParse(body);
    if (!result.success) return null;

    if (result.data.timing === "asap") {
      return {
        vendor: result.data.vendor,
        structured: structuredFrom(result.data),
        submittedEmail: result.data.email,
        timing: "asap",
        installationCredential: result.data.installationCredential,
      };
    }

    const windowStart = new Date(result.data.windowStart);
    if (!isUsableScheduledStart(windowStart, now)) return null;

    return {
      vendor: result.data.vendor,
      structured: structuredFrom(result.data),
      submittedEmail: result.data.email,
      timing: "scheduled",
      windowStart,
      installationCredential: result.data.installationCredential,
    };
  }

  const result = legacyWebSchema.safeParse(body);
  if (!result.success) return null;

  if (
    result.data.windowStart === undefined &&
    result.data.windowEnd === undefined
  ) {
    return {
      vendor: result.data.vendor,
      structured: structuredFrom(result.data),
      submittedEmail: result.data.email,
      timing: "asap",
    };
  }

  const windowStart = new Date(result.data.windowStart!);
  if (!isUsableScheduledStart(windowStart, now)) return null;

  return {
    vendor: result.data.vendor,
    structured: structuredFrom(result.data),
    submittedEmail: result.data.email,
    timing: "scheduled",
    windowStart,
  };
}

/**
 * Why a create payload was refused.
 *
 * `payload` is every structural failure this route has always answered with one
 * generic message: a missing, blank, or wrongly typed field, an unexpected key,
 * a bad `timing`, a mismatched window, or a scheduled start that has already
 * passed, on either create shape.
 * `vendor` is reserved for a vendor that is present and non-blank but is not
 * one of the supported catalog entries. `principal` is reserved for a payload
 * that names an address other than the one this caller verified.
 *
 * There is deliberately no address refusal left. The NYU allowlist still gates
 * every request — it decides who may become a participant at all, and
 * `resolveParticipantAuthority` re-applies it to the stored principal on every
 * use — but it is no longer something this payload can fail, because this
 * payload no longer supplies the requester.
 */
type CreateRefusal = "payload" | "vendor" | "principal";

type CreateValidation =
  | { ok: true; request: ValidatedCreateRequest }
  | { ok: false; refusal: CreateRefusal };

/**
 * The vendor allowlist and the principal check are strictly additive and run
 * after shape validation, so they can only refuse a payload that would
 * otherwise have been created. Every existing structural failure — and every
 * case where another field is also invalid — keeps the exact generic error it
 * has always returned.
 *
 * Both refusals happen here, before the daily-limit read, the write, the
 * requester confirmation email, and helper notification. The participant gate
 * itself has already run, further upstream still: an unverified caller is
 * refused before this function is reached, so it never learns whether its
 * payload would otherwise have been accepted.
 */
function validateCreateRequest(
  body: unknown,
  now: Date,
  principal: string
): CreateValidation {
  const request = validateCreateShape(body, now);
  if (!request) return { ok: false, refusal: "payload" };
  if (!isSupportedVendor(request.vendor)) {
    return { ok: false, refusal: "vendor" };
  }
  // A payload may repeat the address it verified; it may not name a different
  // one. Substituting the principal silently would let a client believe it had
  // posted as someone else, and refusing generically would hide which of the
  // two identities the request would actually have carried.
  if (
    request.submittedEmail !== undefined &&
    request.submittedEmail !== principal
  ) {
    return { ok: false, refusal: "principal" };
  }
  return { ok: true, request };
}

async function attemptRequesterConfirmation(
  request: ValidatedCreateRequest,
  food: string,
  requesterEmail: string,
  pickupWindowText: string,
  requestId: string
): Promise<void> {
  const htmlVendor = escapeHtml(request.vendor);
  // The same derived summary persisted on the Request and shown to helpers
  // (W4-R4), so the requester's confirmation describes exactly the request
  // that exists. The `Pickup Name` line is gone with the field itself.
  const htmlFood = escapeHtml(food);
  // The same backend-derived, NYU-campus-time text helpers see, so the
  // requester's confirmation cannot state a window the request does not have.
  const htmlPickupWindow = escapeHtml(pickupWindowText);

  try {
    assertExternalProvidersAllowed();
    const result = await resend.emails.send({
      from: emailSender(),
      to: requesterEmail,
      subject: "Request Confirmed - CommonPlate",
      html: `
        <h2>Your meal request has been submitted!</h2>
        <p><strong>Vendor:</strong> ${htmlVendor}</p>
        <p><strong>Food:</strong> ${htmlFood}</p>
        <p><strong>Pickup Window:</strong> ${htmlPickupWindow}</p>
        <p>When someone helps, CommonPlate will attempt to email you the order details. Request creation does not guarantee that later email will be delivered.</p>
        <p>Request ID: ${requestId}</p>
      `,
      text: `Your meal request has been submitted!\nVendor: ${request.vendor}\nFood: ${food}\nPickup Window: ${pickupWindowText}\nWhen someone helps, CommonPlate will attempt to email you the order details. Request creation does not guarantee that later email will be delivered.\nRequest ID: ${requestId}`,
    });

    if (result.error) {
      console.error(
        `[email] Request confirmation failed after persistence for request ${requestId}`
      );
    }
  } catch {
    console.error(
      `[email] Request confirmation failed after persistence for request ${requestId}`
    );
  }
}

/**
 * The route-facing entry point for real-time helper-email fan-out, and a
 * **total** function: an ordinary non-`async` function that never throws and
 * returns nothing the route can await. Mirrors `startHelperNewRequestPush`.
 *
 * Both guards are load-bearing. The attached `.catch` contains every
 * asynchronous rejection from `notifySubscribersForRequest` — a query
 * failure, a provider error escaping its own per-subscriber isolation. The
 * synchronous `try`/`catch` contains a setup error thrown before any promise
 * exists.
 *
 * This matters because `createRequest` calls it *after* the `201` has been
 * sent. Full-fanout selection makes this call's duration unbounded with
 * confirmed-subscriber count, so it must never be awaited, and an escaping
 * throw or unhandled rejection here would attempt a second response on a
 * request whose headers are already flushed.
 */
function startNotifySubscribersForRequest(
  request: Parameters<typeof notifySubscribersForRequest>[0]
): void {
  let requestId = "unknown";
  try {
    requestId = String(request._id);
    void notifySubscribersForRequest(request).catch((error: unknown) => {
      console.error(
        `[notify] Helper email dispatch failed for request ${requestId}`,
        error
      );
    });
  } catch (error) {
    console.error(
      `[notify] Helper email dispatch could not start for request ${requestId}`,
      error
    );
  }
}

/**
 * Focused handler for POST /api/request.
 *
 * Validation and persistence are core. Requester confirmation happens only
 * after the canonical response has been built from the persisted document,
 * and cannot change the creation result. Helper email and helper push
 * dispatch are both started after the response is sent and neither is
 * awaited, so email and push fail independently of each other, of requester
 * confirmation, and of creation — and neither can delay the requester's
 * `201`, regardless of confirmed-subscriber count.
 */
export async function createRequest(
  req: Request,
  res: Response
): Promise<Response> {
  // One backend creation-time value for the whole handler: scheduled-start
  // validation, the daily-limit window, and the ASAP visibility window are all
  // measured from the same instant.
  const now = new Date();

  // The participant gate runs first: before shape validation, before the
  // daily-limit read, before the write, and before either notification. An
  // unverified caller therefore produces no side effect and learns nothing
  // about its payload — including, deliberately, whether the address it sent
  // would have been accepted.
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }
  const { participantId, principal, authorityVersion } = authority.participant;

  // The W3-D1 operation-identity gate runs immediately after participant
  // authority and before shape validation, quota, or the write: exact
  // identity — never payload — decides whether this call is a replay, so an
  // already-resolved operation must reconcile even against a payload that
  // would otherwise fail validation.
  const operationHeader = readOperationIdentity(req);
  if (
    operationHeader === null ||
    (operationHeader !== undefined && !isValidOperationId(operationHeader))
  ) {
    return res
      .status(400)
      .json(errorEnvelope(INVALID_OPERATION_ID_CODE, INVALID_OPERATION_ID_MESSAGE));
  }
  const operationId = operationHeader;

  // W4-D2: a caller that names the ledger authority it recorded for this
  // operation is served only by that ledger. Checked before the ledger is
  // read, so a different or reset database behind the same URL can neither
  // answer for the operation nor create under its identity. A caller that
  // names none keeps the unchanged pre-D2 behavior.
  const authorityCheck = await checkOperationAuthority(req);
  if (authorityCheck === "mismatched" || authorityCheck === "unavailable") {
    return sendOperationAuthorityRefusal(res, authorityCheck);
  }

  if (operationId !== undefined) {
    let reconciliation: OperationReconciliation;
    try {
      reconciliation = await reconcileOperation(operationId, participantId);
    } catch {
      console.error(
        "[route] Failed to check existing request operation identity"
      );
      return res.status(500).json(
        errorEnvelope("REQUEST_CREATION_FAILED", "Unable to create request")
      );
    }
    if (reconciliation.outcome === "unauthorized") {
      return res
        .status(403)
        .json(
          errorEnvelope(OPERATION_UNAUTHORIZED_CODE, OPERATION_UNAUTHORIZED_MESSAGE)
        );
    }
    if (reconciliation.outcome === "expired") {
      // Terminal and definitive: this exact identity once created a Request,
      // but that Request has passed its bounded recovery horizon. It must
      // never fall through to a fresh create merely because the original
      // Request is gone — that would resurrect the exact "cleanup makes an
      // expired operation fresh again" defect this correction fixes.
      return res
        .status(410)
        .json(errorEnvelope(OPERATION_EXPIRED_CODE, OPERATION_EXPIRED_MESSAGE));
    }
    if (reconciliation.outcome === "created-unavailable") {
      return sendCreatedUnavailable(res);
    }
    if (reconciliation.outcome === "not-created") {
      // W4-D2: terminal and permanent. A terminalized identity never falls
      // through to validation, quota, or a create.
      return sendOperationNotCreated(res);
    }
    if (reconciliation.outcome === "created") {
      return res
        .status(200)
        .json(buildPublicRequestDetailResponse(reconciliation.document, now));
    }
    // "not-found": no Request is bound to this operation yet. Fall through to
    // ordinary validation and creation below, exactly as an unrecognized
    // identity should — it is indistinguishable from a first attempt.
  }

  const validation = validateCreateRequest(req.body, now, principal);
  if (!validation.ok) {
    // `INVALID_VENDOR` and `PARTICIPANT_PRINCIPAL_MISMATCH` are each a distinct
    // code for one specific, otherwise-valid field, rather than extra meanings
    // loaded onto `INVALID_REQUEST`. Clients that do not know either code still
    // render the message.
    if (validation.refusal === "vendor") {
      return res
        .status(400)
        .json(errorEnvelope("INVALID_VENDOR", UNSUPPORTED_VENDOR_MESSAGE));
    }
    if (validation.refusal === "principal") {
      return res
        .status(403)
        .json(
          errorEnvelope(
            PARTICIPANT_PRINCIPAL_MISMATCH_CODE,
            PARTICIPANT_PRINCIPAL_MISMATCH_MESSAGE
          )
        );
    }
    return res
      .status(400)
      .json(errorEnvelope("INVALID_REQUEST", "Invalid request payload"));
  }
  const validated = validation.request;

  // W4-U1.1: authoritative filtering of requester-authored request text for a
  // genuinely new create attempt. Deliberately placed after participant
  // authority, exact-operation reconciliation, and canonical validation, and
  // before the quota read and every creation side effect: a refusal here
  // creates no Request, writes no operation ledger row, consumes no quota, and
  // starts no confirmation, helper email, or helper push. `food` is derived
  // from these same values, so it is not filtered separately.
  if (
    !structuredAuthoredTexts(validated.structured).every(isParticipantTextAllowed)
  ) {
    return sendDay4Error(
      res,
      422,
      REQUEST_TEXT_NOT_ALLOWED_CODE,
      REQUEST_TEXT_NOT_ALLOWED_MESSAGE
    );
  }

  try {
    // This serial read-before-write is intentionally best-effort abuse control,
    // not a transactional quota guarantee under concurrent requests. The day
    // boundary is the NYU campus calendar day, not the Node process's local
    // timezone, so quota reset time does not depend on where this process runs.
    // Shared with the W4-Q1 participant-authorized eligibility read
    // (`src/requestDailyQuota.ts`), so the two paths cannot drift into
    // different eligibility semantics.
    try {
      // Counted against the verified principal, so the daily allowance now
      // belongs to a proved mailbox rather than to whatever address a caller
      // typed. The exact-principal rule matters here too: `+tag` variants are
      // separate participants and therefore separate allowances, which is the
      // accepted consequence of not canonicalizing aliases into one human.
      const todaysCount = await countTodaysRequests(principal, now);
      if (!isUnderDailyLimit(todaysCount)) {
        return res.status(429).json(
          errorEnvelope(
            "REQUEST_LIMIT_REACHED",
            "You have reached the daily limit of 3 meal requests"
          )
        );
      }
    } catch {
      console.error("[route] Failed to enforce request daily limit");
      return res.status(500).json(
        errorEnvelope("REQUEST_CREATION_FAILED", "Unable to create request")
      );
    }

    const { visibleFrom, expiresAt } = requestTimingWindow(validated, now);
    const pickupWindowText = requestWindowText(validated.timing, {
      visibleFrom,
      expiresAt,
    });

    // Notification-routing identity only, and strictly best-effort: a failure
    // to resolve it must never block the core act of creating a food request.
    let installationId: Types.ObjectId | undefined;
    try {
      installationId = await resolveRequestInstallationAssociation(
        validated.installationCredential
      );
    } catch {
      console.error(
        "[route] Could not resolve the request-installation association"
      );
    }

    // W4-R4: the structured representation is persisted exactly as submitted,
    // and `food` is derived from it once, here, so the stored summary can
    // never contradict the structured fields it summarizes.
    const { structured } = validated;
    const food = deriveFoodSummary(structured);

    const documentFields = {
      vendor: validated.vendor,
      food,
      menuPath: structured.menuPath,
      mealSwipes: structured.mealSwipes,
      mealItems: structured.mealItems ?? [],
      // Spread conditionally rather than written as an explicit `undefined`:
      // an absent Dining Dollar estimate means the requester needs none, and
      // the persisted document says so by carrying no field at all rather
      // than by carrying a key whose value happens to be undefined.
      ...(structured.orderDetails !== undefined
        ? { orderDetails: structured.orderDetails }
        : {}),
      ...(structured.estimatedDiningDollarsCents !== undefined
        ? { estimatedDiningDollarsCents: structured.estimatedDiningDollarsCents }
        : {}),
      // Both written from the resolved participant, never from the payload.
      // `email` stays the requester address every downstream path already
      // reads; `requesterParticipantId` is the durable binding to the identity
      // that proved it, which is what W3-H1 and W3-M1 can later consume.
      email: principal,
      requesterParticipantId: participantId,
      pickupWindowText,
      windowStart: validated.windowStart,
      // The advertised window is the availability window. Persisting the
      // derived expiration here — rather than whatever end a client sent —
      // keeps the public `windowEnd`, the display text, and `expiresAt` from
      // being three different claims about one request.
      windowEnd: validated.timing === "scheduled" ? expiresAt : undefined,
      status: "open",
      // W4-R5: the initial content revision and notification generation are
      // written explicitly, so a request created from here on is editable and
      // fenceable; rows that predate this carry neither and are never guessed
      // into editable state.
      contentRevision: INITIAL_CONTENT_REVISION,
      notificationGeneration: INITIAL_NOTIFICATION_GENERATION,
      visibleFrom,
      // Which path owns starting helper notification for this request (W3-N3).
      // Decided by the one visibility rule every other path applies, so this
      // records what the two dispatches started below will actually do rather
      // than a second opinion about it: a request that is helper-visible now is
      // being dispatched for now, and a future Later request is not — its
      // dispatches will both find it unavailable and do nothing, and the
      // eligibility sweep picks it up at `visibleFrom` instead.
      helperNotification: isVisibleNow(visibleFrom, now)
        ? "initiated"
        : "awaiting-eligibility",
      // W4-N1 Increment B: every new request starts awaiting its one T-15
      // closing-soon chance, regardless of ASAP/Later — unlike
      // `helperNotification`, this is about nearing `expiresAt`, not about
      // visibility, so there is no "already initiated at creation" case.
      closingSoonNotification: "awaiting",
      expiresAt,
      deleteAt: expiresAt,
      ...(installationId ? { installationId } : {}),
    };

    let document: IRequest;
    if (operationId !== undefined) {
      // Reserves the operation identity and creates the Request in one
      // transaction (`createRequestWithOperation`), so the two writes can
      // never diverge — no crash window can leave a Request that later TTL
      // cleanup could make "fresh" again by silently freeing its identity.
      const result = await createRequestWithOperation(
        documentFields,
        operationId,
        participantId,
        principal,
        authorityVersion
      );
      if (result.kind === "reconciled") {
        // This exact call lost a concurrent race for the operation identity:
        // answer with the winner's already-decided outcome, exactly like the
        // pre-write reconciliation check above — never a second `201`, and
        // never a second confirmation email or notification dispatch for a
        // Request this call did not actually create.
        const { reconciliation } = result;
        if (reconciliation.outcome === "unauthorized") {
          return res
            .status(403)
            .json(
              errorEnvelope(
                OPERATION_UNAUTHORIZED_CODE,
                OPERATION_UNAUTHORIZED_MESSAGE
              )
            );
        }
        if (reconciliation.outcome === "expired") {
          return res
            .status(410)
            .json(
              errorEnvelope(OPERATION_EXPIRED_CODE, OPERATION_EXPIRED_MESSAGE)
            );
        }
        if (reconciliation.outcome === "created-unavailable") {
          return sendCreatedUnavailable(res);
        }
        if (reconciliation.outcome === "not-created") {
          // Terminalization won the identity before this transaction's
          // ledger insert, so the transaction — Request included — rolled
          // back. Nothing was created, and nothing ever will be.
          return sendOperationNotCreated(res);
        }
        if (reconciliation.outcome === "not-found") {
          // Unreachable in practice: `createRequestWithOperation` only
          // reaches reconciliation after a duplicate-key error, which means
          // some attempt already won and inserted this exact identity.
          throw new Error(
            "Unexpected operation reconciliation state after create"
          );
        }
        return res
          .status(200)
          .json(buildPublicRequestDetailResponse(reconciliation.document, now));
      }
      // `result.document` is `PublicRequestDocument`-shaped (the same
      // reconciliation type the pre-write check above returns), but it is the
      // exact document this route just created — the same underlying
      // `IRequest` every other path here works with.
      document = result.document as unknown as IRequest;
    } else {
      document = await createRequestWithoutOperation(
        documentFields,
        participantId,
        principal,
        authorityVersion
      );
    }

    const response = buildPublicRequestDetailResponse(
      document as unknown as PublicRequestDocument,
      now
    );
    const requestId = String(document._id);

    await attemptRequesterConfirmation(
      validated,
      food,
      principal,
      pickupWindowText,
      requestId
    );

    res.status(201).json(response);
    // Both started after the response is sent and deliberately not awaited: a
    // slow, timed-out, or misconfigured APNs submission, or a large or slow
    // confirmed-subscriber email fan-out, must not delay the requester's
    // `201`, turn a successful creation into `REQUEST_CREATION_FAILED`, or
    // alter the created request. Both start functions are total — neither
    // throws, and neither returns anything to await — so nothing here can
    // reach the outer `catch` after the headers are flushed.
    startHelperNewRequestPush(document);
    startNotifySubscribersForRequest(document);
    return res;
  } catch (error) {
    if (error instanceof RequesterSuspendedError) {
      return sendDay4Error(
        res,
        403,
        PARTICIPANT_SUSPENDED_CODE,
        PARTICIPANT_SUSPENDED_MESSAGE
      );
    }
    if (error instanceof ParticipantAccountFenceUnavailable) {
      return sendDay4Error(
        res,
        503,
        "PARTICIPANT_VERIFICATION_UNAVAILABLE",
        "We couldn’t check your NYU verification right now. Please try again in a moment."
      );
    }
    console.error("[route] Request creation failed");
    return res.status(500).json(
      errorEnvelope(
        "REQUEST_CREATION_FAILED",
        "Unable to create request"
      )
    );
  }
}
