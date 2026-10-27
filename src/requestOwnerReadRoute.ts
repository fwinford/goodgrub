import mongoose from "mongoose";
import type { Express, NextFunction, Request, Response } from "express";
import { Request as MealRequest } from "../models/db.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import {
  mapPublicRequestFields,
  type PublicRequestDocument,
  type PublicRequestResponse,
} from "./requestListResponse.js";
import { carriesModerationHold } from "./requestAvailability.js";
import { latestEditableScheduledStart } from "./requestTiming.js";

/**
 * W4-R5 owner reads (G3): the requester's own ongoing requests, resolved from
 * the *persisted* `requesterParticipantId` of the verified participant. Never
 * from an installation, a push token, a device, a raw email, a cached request
 * id or local history.
 *
 * These are private, caller-specific reads: `Cache-Control: private, no-store`
 * with `Vary` on the participant credential, set before any other work, so a
 * response can never be reused across callers. Each response is a narrow
 * allowlisted DTO (`OwnerRequestResponse`) that carries no helper identity, no
 * claim material, no moderation state and no other participant's data.
 *
 * Privacy by omission: a request that does not exist, belongs to someone else,
 * or is not part of the owner's ongoing work is answered by the *same* `404`,
 * so an id probes nothing about who owns what.
 */
export const OWNER_REQUEST_LIST_ROUTE_PATH = "/api/participant/requests";
export const OWNER_REQUEST_DETAIL_ROUTE_PATH = "/api/participant/request/:id";

/** The most ongoing requests one owner can have (the daily quota is 3, but
 * scheduled requests created earlier can still be ongoing). Bounded so the read
 * is never unbounded. */
export const OWNER_REQUEST_LIST_LIMIT = 25;

export const OWNER_REQUEST_NOT_FOUND_CODE = "REQUEST_NOT_FOUND";
export const OWNER_REQUEST_NOT_FOUND_MESSAGE = "This request could not be found.";

/** Owner-only neutral signal that moderation removed the owner's own live
 * request. Names no reporter, reason, or moderation state. */
export const OWNER_REQUEST_REMOVED_CODE = "REQUEST_REMOVED";
export const OWNER_REQUEST_REMOVED_MESSAGE = "This request is no longer available.";

export const ownerRequestReadRateLimiter = createDay4MutationRateLimiter(30);

/**
 * Where an owner's request is in its ongoing lifecycle, derived from stored
 * state and the backend clock — never written back.
 *
 * - `scheduled`: a Later request whose start has not arrived.
 * - `available`: visible to helpers now (including a request whose earlier
 *   reservation lapsed).
 * - `reserved`: a helper holds a live reservation, or the post-Yes
 *   external-order-risk authority holds it. Reveals nothing about who.
 */
export type OwnerRequestPhase = "scheduled" | "available" | "reserved";

export interface OwnerRequestDocument extends PublicRequestDocument {
  externalOrderAffirmed?: boolean | null;
  contentRevision?: number | null;
  moderationUnavailable?: boolean | null;
  reservationLapseHold?: boolean | null;
}

export interface OwnerRequestResponse
  extends Omit<
    PublicRequestResponse,
    "status" | "isOwnRequest" | "contentRevision"
  > {
  /** `asap` when helpers saw it from creation, `scheduled` for a Later start. */
  timing: "asap" | "scheduled";
  phase: OwnerRequestPhase;
  /** Absent only for a legacy row that was never given edit authority. */
  contentRevision: number | null;
  /** Backend-derived, so the client never recomputes eligibility from stale
   * state; the mutation itself re-checks atomically. */
  canEdit: boolean;
  canWithdraw: boolean;
  /** 11:30 PM `America/New_York` on the original creation day: the latest Later
   * start an edit may choose. */
  latestScheduledStart: string;
}

function dateValue(value: unknown): number {
  return value == null ? Number.NaN : new Date(value as Date | string).getTime();
}

/**
 * The owner's lifecycle phase, or `null` when the request is not ongoing work:
 * withdrawn, placed (R3 owns the placed continuation), or expired.
 */
export function deriveOwnerPhase(
  document: {
    status?: string | null;
    expiresAt?: Date | string | null;
    visibleFrom?: Date | string | null;
    claimExpiresAt?: Date | string | null;
    externalOrderAffirmed?: boolean | null;
    moderationUnavailable?: boolean | null;
    reservationLapseHold?: boolean | null;
  },
  now: Date
): OwnerRequestPhase | null {
  if (carriesModerationHold(document)) return null;
  if (document.status !== "open" && document.status !== "claimed") return null;
  const expiration = dateValue(document.expiresAt);
  if (!Number.isFinite(expiration) || expiration <= now.getTime()) return null;
  if (document.externalOrderAffirmed === true) return "reserved";
  if (
    document.status === "claimed" &&
    dateValue(document.claimExpiresAt) > now.getTime()
  ) {
    return "reserved";
  }
  const visibleFrom = dateValue(document.visibleFrom);
  if (Number.isFinite(visibleFrom) && visibleFrom > now.getTime()) {
    return "scheduled";
  }
  return "available";
}

/**
 * Builds the owner DTO, or `null` when the request is not ongoing work. Edit
 * and Withdraw are offered only for a request no helper holds and that has not
 * expired; Edit additionally requires a stored revision (legacy rows are never
 * guessed into editable state).
 */
export function buildOwnerRequestResponse(
  document: OwnerRequestDocument & { createdAt: Date | string },
  now: Date
): OwnerRequestResponse | null {
  const phase = deriveOwnerPhase(document, now);
  if (phase === null) return null;

  const { status: _status, ...shared } = mapPublicRequestFields(document);
  const contentRevision =
    typeof document.contentRevision === "number" &&
    Number.isInteger(document.contentRevision) &&
    document.contentRevision >= 1
      ? document.contentRevision
      : null;
  const holdsNothing = phase !== "reserved";
  return {
    ...shared,
    timing: document.windowStart ? "scheduled" : "asap",
    phase,
    contentRevision,
    canEdit: holdsNothing && contentRevision !== null,
    canWithdraw: holdsNothing,
    latestScheduledStart: latestEditableScheduledStart(
      new Date(document.createdAt)
    ).toISOString(),
  };
}

/**
 * What an owner's own request that is no longer ongoing work *is*, for the
 * owner. `null` for anything that is not one of the three terminal states (so
 * it stays an indistinguishable `404`).
 */
export function terminalOwnerOutcome(document: {
  status?: string | null;
  expiresAt?: Date | string | null;
}): { status: number; code: string; message: string } | null {
  if (document.status === "withdrawn") {
    return { status: 410, code: "REQUEST_WITHDRAWN", message: "This request was withdrawn." };
  }
  if (document.status === "placed") {
    return {
      status: 409,
      code: "REQUEST_ALREADY_PLACED",
      message: "This request has already been placed.",
    };
  }
  if (document.status === "open" || document.status === "claimed") {
    return {
      status: 410,
      code: "REQUEST_EXPIRED",
      message: "This request is no longer available.",
    };
  }
  return null;
}

function isModerationRemovedLive(
  document: {
    status?: string | null;
    expiresAt?: Date | string | null;
    moderationUnavailable?: boolean | null;
  },
  now: Date
): boolean {
  if (document.moderationUnavailable !== true) return false;
  if (document.status !== "open" && document.status !== "claimed") return false;
  return dateValue(document.expiresAt) > now.getTime();
}

function setPrivateHeaders(res: Response): void {
  res.setHeader("Cache-Control", "private, no-store");
  res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);
}

/**
 * Sets the participant cache-isolation headers ahead of the rate limiter, so a
 * limiter-generated `429` is isolated per credential exactly like every other
 * outcome (same reasoning as the Q1 eligibility route).
 */
export function ownerRequestReadCacheIsolation(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  setPrivateHeaders(res);
  next();
}

const OWNER_SELECT =
  "+requesterParticipantId +externalOrderAffirmed +contentRevision +moderationUnavailable +reservationLapseHold";

function sendNotFound(res: Response): Response {
  return sendDay4Error(
    res,
    404,
    OWNER_REQUEST_NOT_FOUND_CODE,
    OWNER_REQUEST_NOT_FOUND_MESSAGE
  );
}

function sendUnavailable(res: Response): Response {
  return sendDay4Error(
    res,
    503,
    PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
    PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
  );
}

/** `GET /api/participant/requests` — the verified participant's ongoing
 * requests, oldest first. An empty list is an authoritative empty answer.
 * `removedNotice` is an owner-only boolean: true when moderation removed at
 * least one of the caller's own live requests (never listed here). */
export async function getOwnerRequestList(
  req: Request,
  res: Response
): Promise<Response> {
  setPrivateHeaders(res);
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  try {
    const now = new Date();
    const documents = await MealRequest.find({
      requesterParticipantId: authority.participant.participantId,
      status: { $in: ["open", "claimed"] },
      expiresAt: { $gt: now },
      moderationUnavailable: { $ne: true },
      reservationLapseHold: { $ne: true },
    })
      .select(OWNER_SELECT)
      .sort({ createdAt: 1 })
      .limit(OWNER_REQUEST_LIST_LIMIT)
      .lean()
      .exec();

    const requests = documents
      .map((document) =>
        buildOwnerRequestResponse(document as unknown as OwnerRequestDocument & {
          createdAt: Date;
        }, now)
      )
      .filter((response): response is OwnerRequestResponse => response !== null);

    // One owner-scoped, bounded existence check (served by the requester
    // index prefix) using the same removal definition as the detail read. A
    // boolean only: no id, count, time or reason, and it ends with the
    // request's own expiry. A failure here fails the whole read (below) rather
    // than reporting a guessed `false`.
    const removed = await MealRequest.findOne({
      requesterParticipantId: authority.participant.participantId,
      status: { $in: ["open", "claimed"] },
      expiresAt: { $gt: now },
      moderationUnavailable: true,
    })
      .select("_id")
      .lean()
      .exec();
    return res.json({ requests, removedNotice: removed !== null });
  } catch {
    console.error("[route] Owner request list lookup failed");
    return sendUnavailable(res);
  }
}

/** `GET /api/participant/request/:id` — one of the verified participant's own
 * ongoing requests. Anything else is the single indistinguishable `404`. */
export async function getOwnerRequestDetail(
  req: Request,
  res: Response
): Promise<Response> {
  setPrivateHeaders(res);
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  try {
    const id = String(req.params.id ?? "");
    if (!mongoose.isValidObjectId(id)) return sendNotFound(res);

    const now = new Date();
    const document = await MealRequest.findOne({
      _id: id,
      requesterParticipantId: authority.participant.participantId,
    })
      .select(OWNER_SELECT)
      .lean()
      .exec();
    if (!document) return sendNotFound(res);
    // Reached only for the verified owner's own document (the query is keyed
    // on the persisted requester binding), so a non-owner and a nonexistent id
    // never see this code. Only M (Remove-request / requester suspension) on a
    // live request is a removal. Everything else, including a held request
    // that is withdrawn, expired, or placed, keeps its ordinary terminal
    // answer below, so a hold is never inferable from the status code; a live
    // L-only (helper suspension) request is not ongoing and stays the uniform
    // 404.
    if (isModerationRemovedLive(document, now)) {
      return sendDay4Error(
        res,
        410,
        OWNER_REQUEST_REMOVED_CODE,
        OWNER_REQUEST_REMOVED_MESSAGE
      );
    }

    const response = buildOwnerRequestResponse(
      document as unknown as OwnerRequestDocument & { createdAt: Date },
      now
    );
    if (
      !response &&
      carriesModerationHold(document) &&
      (document.status === "open" || document.status === "claimed") &&
      dateValue(document.expiresAt) > now.getTime()
    ) {
      // A live request held only by a helper suspension (L) is neither
      // expired nor removed, so it must not borrow the expired answer.
      return sendNotFound(res);
    }
    if (!response) {
      // The document is this participant's own (the query is keyed on the
      // persisted requester binding), so its terminal state is theirs to know.
      // Answered with the codes the Edit/Withdraw refusals already use. A
      // non-owner, and a nonexistent id, never reach this branch and keep the
      // single indistinguishable `404` above.
      const terminal = terminalOwnerOutcome(
        document as { status?: string | null; expiresAt?: Date | string | null }
      );
      return terminal
        ? sendDay4Error(res, terminal.status, terminal.code, terminal.message)
        : sendNotFound(res);
    }
    return res.json({ request: response });
  } catch {
    console.error("[route] Owner request detail lookup failed");
    return sendUnavailable(res);
  }
}

export function registerOwnerRequestReadRoutes(app: Express): void {
  app.get(
    OWNER_REQUEST_LIST_ROUTE_PATH,
    ownerRequestReadCacheIsolation,
    ownerRequestReadRateLimiter,
    getOwnerRequestList
  );
  app.get(
    OWNER_REQUEST_DETAIL_ROUTE_PATH,
    ownerRequestReadCacheIsolation,
    ownerRequestReadRateLimiter,
    getOwnerRequestDetail
  );
}
