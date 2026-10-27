import { createHash } from "node:crypto";
import mongoose from "mongoose";
import type { Express, NextFunction, Request, Response } from "express";
import { z } from "zod";
import {
  Request as MealRequest,
  REQUEST_UPDATE_EDIT,
  REQUEST_UPDATE_WITHDRAW,
  RequestUpdateOperation,
  type RequestUpdateKind,
} from "../models/db.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import {
  INVALID_OPERATION_ID_CODE,
  INVALID_OPERATION_ID_MESSAGE,
  OPERATION_UNAUTHORIZED_CODE,
  OPERATION_UNAUTHORIZED_MESSAGE,
  REQUEST_TEXT_NOT_ALLOWED_CODE,
  REQUEST_TEXT_NOT_ALLOWED_MESSAGE,
  isValidOperationId,
  readOperationIdentity,
  requestWindowText,
} from "./createRequestRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  touchParticipantAccountsInSession,
  ParticipantAccountFenceUnavailable,
} from "./participantAccountFence.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { isParticipantTextAllowed } from "./participantTextFilter.js";
import {
  checkOperationAuthority,
  sendOperationAuthorityRefusal,
} from "./requestOperationAuthority.js";
import {
  buildOwnerRequestResponse,
  deriveOwnerPhase,
  OWNER_REQUEST_NOT_FOUND_CODE,
  OWNER_REQUEST_NOT_FOUND_MESSAGE,
  type OwnerRequestDocument,
} from "./requestOwnerReadRoute.js";
import {
  deriveFoodSummary,
  refineStructuredRequest,
  structuredAuthoredTexts,
  structuredRequestFields,
  type StructuredRequestInput,
} from "./structuredRequest.js";
import {
  isAcceptableScheduledStart,
  latestEditableScheduledStart,
  resolveAsapTiming,
  resolveScheduledTiming,
  type RequestTimingWindow,
} from "./requestTiming.js";
import { isSupportedVendor, UNSUPPORTED_VENDOR_MESSAGE } from "./supportedVendors.js";
import { endOfCampusDay } from "./utils/date.js";
import {
  RequesterSuspendedError,
  assertRequesterNotSuspendedWithinSession,
  PARTICIPANT_SUSPENDED_CODE,
  PARTICIPANT_SUSPENDED_MESSAGE,
} from "./moderationEnforcement.js";
import { carriesModerationHold } from "./requestAvailability.js";

/**
 * W4-R5 Edit and Withdraw of a requester's own existing request.
 *
 * Both are owner-authorized, atomic conditional mutations. Each is one
 * conditional update that checks, at mutation time, current ownership,
 * expiration, reservation state, placed/withdrawn state and (for Edit) the
 * expected content revision — so a claim, a placement, a simultaneous edit or a
 * withdrawal racing this call has exactly one backend-authoritative winner and
 * a stale client fails safely. The request update and the recovery-ledger row
 * that records its identity commit in one transaction.
 *
 * Neither is a create: neither consumes or refunds a daily slot, neither
 * touches D2's `RequestOperation` ledger, and neither sends a requester or
 * helper email or push. An explicit rescheduling only re-arms the existing
 * eligibility sweep (`helperNotification: "awaiting-eligibility"` plus a new
 * notification generation); an ordinary edit initiates no alert at all.
 *
 * `PUBLIC_ACTIONS_PAUSED` is not applied here: the accepted pause contract
 * enumerates exactly what it governs (create, signup, claim mutations, alert
 * delivery) and these are not on it. The alert delivery an explicit
 * rescheduling can eventually cause stays governed by the dispatchers' own pause
 * guards, unchanged.
 */
export const REQUEST_WITHDRAW_ROUTE_PATH = "/api/request/:id/withdraw";
export const REQUEST_EDIT_ROUTE_PATH = "/api/request/:id/edit";

export const requestWithdrawRateLimiter = createDay4MutationRateLimiter(10);
export const requestEditRateLimiter = createDay4MutationRateLimiter(10);

// Definitive refusals. All are written before any mutation, or by a
// conditional update that matched nothing, so none is ever ambiguous.
export const REQUEST_RESERVED_CODE = "REQUEST_RESERVED";
export const REQUEST_RESERVED_MESSAGE =
  "A helper is already working on this request.";
export const REQUEST_WITHDRAWN_CODE = "REQUEST_WITHDRAWN";
export const REQUEST_WITHDRAWN_MESSAGE = "This request was withdrawn.";
export const REQUEST_REVISION_CONFLICT_CODE = "REQUEST_REVISION_CONFLICT";
export const REQUEST_REVISION_CONFLICT_MESSAGE =
  "This request changed. Review the latest version.";
export const REQUEST_NOT_EDITABLE_CODE = "REQUEST_NOT_EDITABLE";
export const REQUEST_NOT_EDITABLE_MESSAGE = "This request can't be edited.";
export const REQUEST_HORIZON_EXCEEDED_CODE = "REQUEST_HORIZON_EXCEEDED";
export const REQUEST_HORIZON_EXCEEDED_MESSAGE =
  "Choose a start time on the day this request was created.";
export const OPERATION_CONFLICT_CODE = "OPERATION_CONFLICT";
export const OPERATION_CONFLICT_MESSAGE =
  "This operation identity was already used for a different change.";

function errorEnvelope(code: string, message: string) {
  return { error: { code, message, fields: null } };
}

function isDuplicateKeyError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === 11000
  );
}

function setPrivateHeaders(res: Response): void {
  res.setHeader("Cache-Control", "private, no-store");
  res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);
}

/** Cache isolation ahead of the limiter, so a limiter-generated `429` is
 * isolated per credential like every other outcome. */
export function requestUpdateCacheIsolation(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  setPrivateHeaders(res);
  next();
}

const MUTATION_SELECT =
  "+requesterParticipantId +externalOrderAffirmed +contentRevision +notificationGeneration +moderationUnavailable +reservationLapseHold";

/** Thrown inside the transaction when the conditional update matched nothing, so
 * the transaction (and any ledger row) aborts. */
class ConditionalUpdateFailure extends Error {}

// ---------------------------------------------------------------------------
// Shared: identity, replay, refusal classification
// ---------------------------------------------------------------------------

type Authorized = {
  participantId: string;
  operationId: string;
  principal: string;
  authorityVersion: number;
};

/**
 * Participant authority, then the exact operation identity (required for both
 * mutations: the identity is what makes an ambiguous response recoverable), then
 * the ledger authority check. Returns `null` after answering a refusal.
 */
async function authorize(req: Request, res: Response): Promise<Authorized | null> {
  setPrivateHeaders(res);
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    sendParticipantAuthorityRefusal(res, authority.refusal);
    return null;
  }

  const operationHeader = readOperationIdentity(req);
  if (
    operationHeader === undefined ||
    operationHeader === null ||
    !isValidOperationId(operationHeader)
  ) {
    res
      .status(400)
      .json(errorEnvelope(INVALID_OPERATION_ID_CODE, INVALID_OPERATION_ID_MESSAGE));
    return null;
  }

  const authorityCheck = await checkOperationAuthority(req);
  if (authorityCheck === "mismatched" || authorityCheck === "unavailable") {
    sendOperationAuthorityRefusal(res, authorityCheck);
    return null;
  }

  return {
    participantId: authority.participant.participantId,
    operationId: operationHeader,
    principal: authority.participant.principal,
    authorityVersion: authority.participant.authorityVersion,
  };
}

interface LedgerRow {
  participantId?: unknown;
  requestId?: unknown;
  kind?: RequestUpdateKind;
  resultingRevision?: number;
  payloadDigest?: string;
  ownerDeleted?: boolean;
}

async function readLedgerRow(operationId: string): Promise<LedgerRow | null> {
  return (await RequestUpdateOperation.findOne({ operationId })
    .select(
      "+participantId +requestId +kind +resultingRevision +payloadDigest +ownerDeleted"
    )
    .lean()
    .exec()) as LedgerRow | null;
}

type Replay =
  | { outcome: "none" }
  | { outcome: "unauthorized" }
  | { outcome: "conflict" }
  | { outcome: "expired" }
  | {
      outcome: "decided";
      row: LedgerRow & { resultingRevision: number };
    };

/**
 * Exact-identity reconciliation. The ledger row — never payload, timing or
 * recency — is the authority, and the owner check runs before anything else is
 * revealed. An identity reused for a different request, a different kind of
 * change, or (for Edit) different submitted content is a definitive conflict;
 * it is never answered with another operation's result.
 */
async function reconcile(
  operationId: string,
  participantId: string,
  expect: { kind: RequestUpdateKind; requestId: string; payloadDigest?: string }
): Promise<Replay> {
  const row = await readLedgerRow(operationId);
  if (!row) return { outcome: "none" };
  if (row.ownerDeleted === true) return { outcome: "unauthorized" };
  if (String(row.participantId) !== participantId) {
    return { outcome: "unauthorized" };
  }
  if (
    row.kind !== expect.kind ||
    !row.requestId ||
    typeof row.resultingRevision !== "number" ||
    String(row.requestId) !== expect.requestId ||
    (expect.kind === REQUEST_UPDATE_EDIT &&
      row.payloadDigest !== expect.payloadDigest)
  ) {
    return { outcome: "conflict" };
  }
  return {
    outcome: "decided",
    row: row as LedgerRow & { resultingRevision: number },
  };
}

function sendReplayRefusal(
  res: Response,
  replay: Extract<Replay, { outcome: "unauthorized" | "conflict" | "expired" }>
): Response {
  if (replay.outcome === "unauthorized") {
    return res
      .status(403)
      .json(errorEnvelope(OPERATION_UNAUTHORIZED_CODE, OPERATION_UNAUTHORIZED_MESSAGE));
  }
  if (replay.outcome === "conflict") {
    return res
      .status(409)
      .json(errorEnvelope(OPERATION_CONFLICT_CODE, OPERATION_CONFLICT_MESSAGE));
  }
  return res
    .status(410)
    .json(
      errorEnvelope(
        "OPERATION_EXPIRED",
        "This change can no longer be recovered."
      )
    );
}

function sendNotFound(res: Response): Response {
  return res
    .status(404)
    .json(errorEnvelope(OWNER_REQUEST_NOT_FOUND_CODE, OWNER_REQUEST_NOT_FOUND_MESSAGE));
}

/**
 * Any failure after the gate that this module cannot classify. Deliberately a
 * plain `500` with no definitive meaning: the mutation may or may not have
 * committed, so a client treats it as ambiguous and recovers by replaying the
 * *same* operation identity — never by guessing, and never with a new one.
 */
export const REQUEST_UPDATE_FAILED_CODE = "REQUEST_UPDATE_FAILED";
export const REQUEST_UPDATE_FAILED_MESSAGE = "Unable to update this request.";

function sendUpdateFailed(res: Response): Response {
  return sendDay4Error(
    res,
    500,
    REQUEST_UPDATE_FAILED_CODE,
    REQUEST_UPDATE_FAILED_MESSAGE
  );
}

interface StoredForUpdate extends OwnerRequestDocument {
  createdAt: Date;
  vendor: string;
  notificationGeneration?: number | null;
}

/** The owner's request, or null for anything else — one indistinguishable
 * answer for nonexistent and not-yours. */
async function loadOwnedRequest(
  requestId: string,
  participantId: string
): Promise<StoredForUpdate | null> {
  if (!mongoose.isValidObjectId(requestId)) return null;
  return (await MealRequest.findOne({
    _id: requestId,
    requesterParticipantId: participantId,
  })
    .select(MUTATION_SELECT)
    .lean()
    .exec()) as StoredForUpdate | null;
}

/**
 * Why a conditional update matched nothing, read after the fact from the
 * current document. The order is the order of what is most final: placed,
 * withdrawn, expired, then reserved, then (Edit only) revision and legacy.
 */
function classifyRefusal(
  document: StoredForUpdate | null,
  now: Date,
  expected: { kind: RequestUpdateKind; contentRevision?: number }
): { status: number; code: string; message: string } {
  if (!document) {
    return {
      status: 404,
      code: OWNER_REQUEST_NOT_FOUND_CODE,
      message: OWNER_REQUEST_NOT_FOUND_MESSAGE,
    };
  }
  if (document.status === "placed") {
    return {
      status: 409,
      code: "REQUEST_ALREADY_PLACED",
      message: "This request has already been placed.",
    };
  }
  if (carriesModerationHold(document)) {
    return {
      status: 404,
      code: OWNER_REQUEST_NOT_FOUND_CODE,
      message: OWNER_REQUEST_NOT_FOUND_MESSAGE,
    };
  }
  if (document.status === "withdrawn") {
    return { status: 410, code: REQUEST_WITHDRAWN_CODE, message: REQUEST_WITHDRAWN_MESSAGE };
  }
  const expiration = document.expiresAt ? new Date(document.expiresAt).getTime() : NaN;
  if (!Number.isFinite(expiration) || expiration <= now.getTime()) {
    return {
      status: 410,
      code: "REQUEST_EXPIRED",
      message: "This request is no longer available.",
    };
  }
  if (deriveOwnerPhase(document, now) === "reserved") {
    return { status: 409, code: REQUEST_RESERVED_CODE, message: REQUEST_RESERVED_MESSAGE };
  }
  if (expected.kind === REQUEST_UPDATE_EDIT) {
    const stored = document.contentRevision;
    if (typeof stored !== "number") {
      return {
        status: 409,
        code: REQUEST_NOT_EDITABLE_CODE,
        message: REQUEST_NOT_EDITABLE_MESSAGE,
      };
    }
    if (stored !== expected.contentRevision) {
      return {
        status: 409,
        code: REQUEST_REVISION_CONFLICT_CODE,
        message: REQUEST_REVISION_CONFLICT_MESSAGE,
      };
    }
  }
  return {
    status: 500,
    code: "INTERNAL_FAILURE",
    message: "Unable to update this request right now.",
  };
}

/** The common eligibility clause of both conditional updates. A reservation that
 * lapsed leaves the request `claimed` with a past deadline; it is ordinary again
 * and is eligible, exactly as `buildEffectiveAvailabilityFilter` treats it. */
function eligibilityFilter(now: Date) {
  return {
    expiresAt: { $gt: now },
    externalOrderAffirmed: { $ne: true },
    moderationUnavailable: { $ne: true },
    reservationLapseHold: { $ne: true },
    $or: [
      { status: "open" },
      { status: "claimed", claimExpiresAt: { $lte: now } },
    ],
  };
}

/** Wraps a user-supplied value so an aggregation-pipeline update treats a
 * string beginning with `$` as text, never as a field path. */
const literal = <T,>(value: T) => ({ $literal: value });

const ADVANCE_GENERATION = {
  $add: [{ $ifNull: ["$notificationGeneration", 1] }, 1],
};

async function runUpdateTransaction(
  owner: Pick<Authorized, "participantId" | "principal" | "authorityVersion">,
  apply: (session: mongoose.ClientSession) => Promise<{ revision: number } | null>,
  ledger: (
    session: mongoose.ClientSession,
    result: { revision: number }
  ) => Promise<unknown>
): Promise<{ revision: number } | "refused"> {
  const session = await mongoose.startSession();
  try {
    let outcome: { revision: number } | "refused" = "refused";
    await session.withTransaction(async () => {
      const fenced = await touchParticipantAccountsInSession(
        [owner.participantId],
        session,
        new Map([[owner.participantId, owner.authorityVersion]])
      );
      if (fenced.get(owner.participantId)?.principal !== owner.principal) {
        throw new ParticipantAccountFenceUnavailable();
      }
      const result = await apply(session);
      if (!result) throw new ConditionalUpdateFailure();
      await ledger(session, result);
      outcome = result;
    });
    return outcome;
  } catch (error) {
    if (error instanceof ConditionalUpdateFailure) return "refused";
    throw error;
  } finally {
    await session.endSession();
  }
}

// ---------------------------------------------------------------------------
// Withdraw
// ---------------------------------------------------------------------------

export interface WithdrawResponse {
  outcome: "withdrawn";
  requestId: string;
}

export async function withdrawRequest(
  req: Request,
  res: Response
): Promise<Response> {
  const authorized = await authorize(req, res);
  if (!authorized) return res;
  const { participantId, operationId } = authorized;
  const requestId = String(req.params.id ?? "");

  try {
    const replay = await reconcile(operationId, participantId, {
      kind: REQUEST_UPDATE_WITHDRAW,
      requestId,
    });
    if (replay.outcome === "unauthorized" || replay.outcome === "conflict") {
      return sendReplayRefusal(res, replay);
    }
    if (replay.outcome === "decided") {
      const owned = await loadOwnedRequest(requestId, participantId);
      if (!owned) {
        return sendReplayRefusal(res, { outcome: "expired" });
      }
      return res.status(200).json({ outcome: "withdrawn", requestId });
    }

    const owned = await loadOwnedRequest(requestId, participantId);
    if (!owned) return sendNotFound(res);

    const now = new Date();
    const result = await runUpdateTransaction(
      { participantId, principal: authorized.principal, authorityVersion: authorized.authorityVersion },
      async (session) => {
        await assertRequesterNotSuspendedWithinSession(participantId, session);
        const updated = await MealRequest.findOneAndUpdate(
          {
            _id: requestId,
            requesterParticipantId: participantId,
            ...eligibilityFilter(now),
          },
          [
            {
              $set: {
                status: "withdrawn",
                withdrawnAt: now,
                updatedAt: now,
                notificationGeneration: ADVANCE_GENERATION,
              },
            },
          ],
          {
            session,
            new: true,
            updatePipeline: true,
          }
        )
          .select("+contentRevision")
          .lean()
          .exec();
        if (!updated) return null;
        // Retention: a withdrawn request is kept through the original-creation
        // day's quota boundary and never shortened below what it already had.
        // `$max` makes that one update, inside the same transaction.
        await MealRequest.updateOne(
          { _id: requestId },
          { $max: { deleteAt: endOfCampusDay(new Date(updated.createdAt)) } },
          { session }
        ).exec();
        return {
          revision:
            typeof (updated as { contentRevision?: number }).contentRevision ===
            "number"
              ? (updated as { contentRevision: number }).contentRevision
              : 1,
        };
      },
      (session, applied) =>
        RequestUpdateOperation.create(
          [
            {
              operationId,
              participantId,
              requestId,
              kind: REQUEST_UPDATE_WITHDRAW,
              resultingRevision: applied.revision,
            },
          ],
          { session }
        )
    );

    if (result === "refused") {
      // The conditional update matched nothing. That is either a real refusal
      // or a concurrent duplicate of this very identity that committed first
      // (its effect is why this one matched nothing), so the ledger is asked
      // again before the refusal is classified.
      const late = await reconcile(operationId, participantId, {
        kind: REQUEST_UPDATE_WITHDRAW,
        requestId,
      });
      if (late.outcome === "decided") {
        return res.status(200).json({ outcome: "withdrawn", requestId });
      }
      if (late.outcome === "unauthorized" || late.outcome === "conflict") {
        return sendReplayRefusal(res, late);
      }
      const current = await loadOwnedRequest(requestId, participantId);
      const refusal = classifyRefusal(current, now, { kind: REQUEST_UPDATE_WITHDRAW });
      return res
        .status(refusal.status)
        .json(errorEnvelope(refusal.code, refusal.message));
    }
    return res.status(200).json({ outcome: "withdrawn", requestId });
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
    if (isDuplicateKeyError(error)) {
      // A concurrent duplicate of this exact identity won the ledger insert and
      // this transaction (request update included) rolled back: answer with the
      // winner's decision, never a second effect.
      try {
        const winner = await reconcile(operationId, participantId, {
          kind: REQUEST_UPDATE_WITHDRAW,
          requestId,
        });
        if (winner.outcome === "decided") {
          return res.status(200).json({ outcome: "withdrawn", requestId });
        }
        if (winner.outcome === "unauthorized" || winner.outcome === "conflict") {
          return sendReplayRefusal(res, winner);
        }
      } catch {
        // fall through to the generic failure below
      }
    }
    console.error("[route] Request withdrawal failed");
    return sendUpdateFailed(res);
  }
}

// ---------------------------------------------------------------------------
// Edit
// ---------------------------------------------------------------------------

const isoTimestamp = z.iso.datetime({ offset: true });

/**
 * The edit payload. It carries the same structured representation as create,
 * the expected content revision (the compare-and-swap authority), and an
 * explicit statement about timing: `unchanged` leaves the availability window
 * exactly as it is; `asap` and `scheduled` are an explicit change that
 * recalculates the three-hour window. `.strict()` refuses anything else —
 * notably `email`, `installationCredential`, `food` and any window end.
 */
const editSchema = z
  .object({
    vendor: z.string().trim().min(1),
    ...structuredRequestFields,
    timing: z.enum(["unchanged", "asap", "scheduled"]),
    windowStart: isoTimestamp.optional(),
    expectedContentRevision: z.number().int().min(1),
  })
  .strict()
  .superRefine((value, context) => {
    refineStructuredRequest(value, context);
    if (value.timing === "scheduled" && value.windowStart === undefined) {
      context.addIssue({
        code: "custom",
        path: ["windowStart"],
        message: "A scheduled edit requires a start",
      });
    }
    if (value.timing !== "scheduled" && value.windowStart !== undefined) {
      context.addIssue({
        code: "custom",
        path: ["windowStart"],
        message: "Only a scheduled edit carries a start",
      });
    }
  });

interface ValidatedEdit {
  vendor: string;
  structured: StructuredRequestInput;
  timing: "unchanged" | "asap" | "scheduled";
  windowStart?: Date;
  expectedContentRevision: number;
}

function structuredFrom(data: StructuredRequestInput): StructuredRequestInput {
  return {
    menuPath: data.menuPath,
    mealSwipes: data.mealSwipes,
    mealItems: data.mealItems ?? [],
    orderDetails: data.orderDetails,
    estimatedDiningDollarsCents: data.estimatedDiningDollarsCents,
  };
}

function validateEditShape(body: unknown): ValidatedEdit | null {
  const result = editSchema.safeParse(body);
  if (!result.success) return null;
  const data = result.data;
  return {
    vendor: data.vendor,
    structured: structuredFrom(data),
    timing: data.timing,
    windowStart: data.windowStart ? new Date(data.windowStart) : undefined,
    expectedContentRevision: data.expectedContentRevision,
  };
}

/** Canonical digest of what was submitted, so a replay that reuses an identity
 * for different content is told so instead of being answered with the old
 * result. Keys are fixed and ordered; nothing here is secret. */
function editDigest(edit: ValidatedEdit): string {
  const canonical = JSON.stringify([
    edit.vendor,
    edit.structured.menuPath,
    edit.structured.mealSwipes,
    (edit.structured.mealItems ?? []).map((item) => [item.name, item.details ?? null]),
    edit.structured.orderDetails ?? null,
    edit.structured.estimatedDiningDollarsCents ?? null,
    edit.timing,
    edit.windowStart ? edit.windowStart.toISOString() : null,
    edit.expectedContentRevision,
  ]);
  return createHash("sha256").update(canonical).digest("hex");
}

export interface EditResponse {
  outcome: "edited";
  resultingRevision: number;
  /** The request as it is now, or null when it is no longer ongoing work (for
   * example withdrawn or expired since this change committed). */
  request: ReturnType<typeof buildOwnerRequestResponse>;
}

async function editResponseFor(
  requestId: string,
  participantId: string,
  resultingRevision: number
): Promise<EditResponse> {
  const current = await loadOwnedRequest(requestId, participantId);
  return {
    outcome: "edited",
    resultingRevision,
    request: current
      ? buildOwnerRequestResponse(current, new Date())
      : null,
  };
}

function editWindow(
  edit: ValidatedEdit,
  now: Date
): { window: RequestTimingWindow; pickupWindowText: string } | null {
  if (edit.timing === "unchanged") return null;
  if (edit.timing === "asap") {
    const window = resolveAsapTiming(now);
    return { window, pickupWindowText: requestWindowText("asap", window) };
  }
  const window = resolveScheduledTiming(edit.windowStart as Date);
  return { window, pickupWindowText: requestWindowText("scheduled", window) };
}

export async function editRequest(
  req: Request,
  res: Response
): Promise<Response> {
  const authorized = await authorize(req, res);
  if (!authorized) return res;
  const { participantId, operationId } = authorized;
  const requestId = String(req.params.id ?? "");

  try {
    const prior = await readLedgerRow(operationId);
    if (
      prior?.ownerDeleted === true ||
      (prior?.participantId != null &&
        String(prior.participantId) !== participantId)
    ) {
      return sendReplayRefusal(res, { outcome: "unauthorized" });
    }
    let edit: ValidatedEdit | null | undefined;
    if (prior) {
      edit = validateEditShape(req.body);
      const replay = await reconcile(operationId, participantId, {
        kind: REQUEST_UPDATE_EDIT,
        requestId,
        payloadDigest: edit ? editDigest(edit) : undefined,
      });
      if (replay.outcome === "unauthorized" || replay.outcome === "conflict") {
        return sendReplayRefusal(res, replay);
      }
      if (replay.outcome === "decided") {
        const owned = await loadOwnedRequest(requestId, participantId);
        if (!owned) {
          return sendReplayRefusal(res, { outcome: "expired" });
        }
        return res
          .status(200)
          .json(
            await editResponseFor(
              requestId,
              participantId,
              replay.row.resultingRevision
            )
          );
      }
    }
    const owned = await loadOwnedRequest(requestId, participantId);
    if (!owned) {
      // Identity that belongs to someone else must still say so before 404, so
      // an owner's replay of a request that has since been TTL-deleted is
      // `expired`, and a stranger learns nothing about the identity.
      const ledgerOnly = prior;
      if (ledgerOnly && String(ledgerOnly.participantId) !== participantId) {
        return sendReplayRefusal(res, { outcome: "unauthorized" });
      }
      if (ledgerOnly) return sendReplayRefusal(res, { outcome: "expired" });
      return sendNotFound(res);
    }

    // Validation follows the owner lookup, so payload validity can never be
    // used to probe whether a request exists or is someone else's.
    edit ??= validateEditShape(req.body);
    const replay = await reconcile(operationId, participantId, {
      kind: REQUEST_UPDATE_EDIT,
      requestId,
      payloadDigest: edit ? editDigest(edit) : undefined,
    });
    if (replay.outcome === "unauthorized" || replay.outcome === "conflict") {
      return sendReplayRefusal(res, replay);
    }
    if (replay.outcome === "decided") {
      return res
        .status(200)
        .json(await editResponseFor(requestId, participantId, replay.row.resultingRevision));
    }

    if (!edit) {
      return res
        .status(400)
        .json(errorEnvelope("INVALID_REQUEST", "Invalid request payload"));
    }

    const now = new Date();

    if (edit.vendor !== owned.vendor && !isSupportedVendor(edit.vendor)) {
      return res
        .status(400)
        .json(errorEnvelope("INVALID_VENDOR", UNSUPPORTED_VENDOR_MESSAGE));
    }

    if (edit.timing === "scheduled") {
      const start = edit.windowStart as Date;
      if (!isAcceptableScheduledStart(start, now)) {
        return res
          .status(400)
          .json(errorEnvelope("INVALID_REQUEST", "Invalid request payload"));
      }
    }
    // Every explicit timing selection — a scheduled start or "now" — must begin
    // by the original creation day's horizon. `unchanged` is never held to it.
    if (edit.timing !== "unchanged") {
      const selectedStart =
        edit.timing === "scheduled" ? (edit.windowStart as Date) : now;
      if (selectedStart.getTime() > latestEditableScheduledStart(owned.createdAt).getTime()) {
        return res
          .status(422)
          .json(
            errorEnvelope(
              REQUEST_HORIZON_EXCEEDED_CODE,
              REQUEST_HORIZON_EXCEEDED_MESSAGE
            )
          );
      }
    }

    // U1.1: authoritative filtering of requester-authored text on edit, exactly
    // as on create, before any mutation. A refusal writes nothing.
    if (!structuredAuthoredTexts(edit.structured).every(isParticipantTextAllowed)) {
      return sendDay4Error(
        res,
        422,
        REQUEST_TEXT_NOT_ALLOWED_CODE,
        REQUEST_TEXT_NOT_ALLOWED_MESSAGE
      );
    }

    const timing = editWindow(edit, now);
    const food = deriveFoodSummary(edit.structured);
    const structured = edit.structured;

    const setFields: Record<string, unknown> = {
      vendor: literal(edit.vendor),
      food: literal(food),
      menuPath: literal(structured.menuPath),
      mealSwipes: literal(structured.mealSwipes),
      mealItems: literal(structured.mealItems ?? []),
      contentRevision: { $add: ["$contentRevision", 1] },
      updatedAt: now,
    };
    const unsetFields: string[] = [];
    if (structured.orderDetails !== undefined) {
      setFields.orderDetails = literal(structured.orderDetails);
    } else {
      unsetFields.push("orderDetails");
    }
    if (structured.estimatedDiningDollarsCents !== undefined) {
      setFields.estimatedDiningDollarsCents = literal(
        structured.estimatedDiningDollarsCents
      );
    } else {
      unsetFields.push("estimatedDiningDollarsCents");
    }
    if (timing) {
      const { window, pickupWindowText } = timing;
      setFields.pickupWindowText = literal(pickupWindowText);
      setFields.visibleFrom = window.visibleFrom;
      setFields.expiresAt = window.expiresAt;
      setFields.deleteAt = window.expiresAt;
      // The advertised window is the availability window, as on create.
      if (edit.timing === "scheduled") {
        setFields.windowStart = edit.windowStart;
        setFields.windowEnd = window.expiresAt;
      } else {
        unsetFields.push("windowStart", "windowEnd");
      }
      // An explicit rescheduling re-arms eligibility-time initiation for the
      // new generation. Delivery-dedupe identities do not change, so nobody
      // already notified is alerted again.
      setFields.helperNotification = "awaiting-eligibility";
      // W4-N1 Increment B: the closing-soon latch is independent of the
      // initial one but re-arms for the same reason and at the same
      // generation boundary — a reschedule moves `expiresAt`, so whoever was
      // already sent a closing-soon alert for the old deadline must get a
      // fresh chance at the new one, and nobody already notified for the old
      // deadline can be alerted a second time for it (the generation fence
      // on the sweep's conditional update prevents that independently of
      // this reset).
      setFields.closingSoonNotification = "awaiting";
      setFields.notificationGeneration = ADVANCE_GENERATION;
    }

    const pipeline: Array<Record<string, unknown>> = [{ $set: setFields }];
    if (unsetFields.length) pipeline.push({ $unset: unsetFields });

    const result = await runUpdateTransaction(
      { participantId, principal: authorized.principal, authorityVersion: authorized.authorityVersion },
      async (session) => {
        await assertRequesterNotSuspendedWithinSession(participantId, session);
        const updated = await MealRequest.findOneAndUpdate(
          {
            _id: requestId,
            requesterParticipantId: participantId,
            contentRevision: edit.expectedContentRevision,
            ...eligibilityFilter(now),
          },
          pipeline as never,
          { session, new: true, updatePipeline: true }
        )
          .select("+contentRevision")
          .lean()
          .exec();
        if (!updated) return null;
        return { revision: (updated as { contentRevision: number }).contentRevision };
      },
      (session, applied) =>
        RequestUpdateOperation.create(
          [
            {
              operationId,
              participantId,
              requestId,
              kind: REQUEST_UPDATE_EDIT,
              resultingRevision: applied.revision,
              payloadDigest: editDigest(edit),
            },
          ],
          { session }
        )
    );

    if (result === "refused") {
      // Same reasoning as Withdraw: a concurrent duplicate of this identity may
      // have committed first.
      const late = await reconcile(operationId, participantId, {
        kind: REQUEST_UPDATE_EDIT,
        requestId,
        payloadDigest: editDigest(edit),
      });
      if (late.outcome === "decided") {
        return res
          .status(200)
          .json(await editResponseFor(requestId, participantId, late.row.resultingRevision));
      }
      if (late.outcome === "unauthorized" || late.outcome === "conflict") {
        return sendReplayRefusal(res, late);
      }
      const current = await loadOwnedRequest(requestId, participantId);
      const refusal = classifyRefusal(current, now, {
        kind: REQUEST_UPDATE_EDIT,
        contentRevision: edit.expectedContentRevision,
      });
      return res
        .status(refusal.status)
        .json(errorEnvelope(refusal.code, refusal.message));
    }
    return res
      .status(200)
      .json(await editResponseFor(requestId, participantId, result.revision));
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
    if (isDuplicateKeyError(error)) {
      try {
        const edit = validateEditShape(req.body);
        const winner = await reconcile(operationId, participantId, {
          kind: REQUEST_UPDATE_EDIT,
          requestId,
          payloadDigest: edit ? editDigest(edit) : undefined,
        });
        if (winner.outcome === "decided") {
          return res
            .status(200)
            .json(
              await editResponseFor(requestId, participantId, winner.row.resultingRevision)
            );
        }
        if (winner.outcome === "unauthorized" || winner.outcome === "conflict") {
          return sendReplayRefusal(res, winner);
        }
      } catch {
        // fall through to the generic failure below
      }
    }
    console.error("[route] Request edit failed");
    return sendUpdateFailed(res);
  }
}

export function registerRequestUpdateRoutes(app: Express): void {
  app.post(
    REQUEST_WITHDRAW_ROUTE_PATH,
    requestUpdateCacheIsolation,
    requestWithdrawRateLimiter,
    withdrawRequest
  );
  app.post(
    REQUEST_EDIT_ROUTE_PATH,
    requestUpdateCacheIsolation,
    requestEditRateLimiter,
    editRequest
  );
}
