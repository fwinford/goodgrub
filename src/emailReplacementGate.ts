import type { Request, Response } from "express";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { day4Error, sendDay4Error } from "./day4Errors.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
  type ParticipantAuthorityResolution,
} from "./participantAuthorityGate.js";
import { hasUnfinishedPlacedPickupObligation } from "./placedOrderRoutes.js";
import { deriveOwnerPhase } from "./requestOwnerReadRoute.js";

/**
 * W4-B1 active-activity gate for Change Email.
 *
 * A verified participant cannot replace their NYU email while they hold an
 * unfinished requester or helper obligation. The gate is evaluated by the
 * verification routes themselves, from authoritative request state, at the two
 * transitions that matter: before a replacement code is sent and before it is
 * redeemed into a credential. A refusal sends no code and consumes none, issues
 * no credential, and changes nothing.
 *
 * A request counts as a replacement attempt when the existing participant
 * credential rides along in the standard authority header. First-time and
 * revoked-identity verification carry none and are unaffected. The server
 * cannot tell a reinstall from a first verification, so this is a product
 * guard for the Change Email flow, not an anti-abuse boundary.
 *
 * Reads only; it never withdraws, cancels, releases, or otherwise mutates a
 * request or reservation.
 */
export const EMAIL_REPLACEMENT_ELIGIBILITY_ROUTE_PATH =
  "/api/participant/email-replacement-eligibility";
export const EMAIL_REPLACEMENT_BLOCKED_CODE = "EMAIL_REPLACEMENT_BLOCKED";
export const EMAIL_REPLACEMENT_BLOCKED_MESSAGE =
  "Finish your current requests and helping before changing your email.";

export const emailReplacementEligibilityRateLimiter =
  createDay4MutationRateLimiter(30);

/**
 * `ownRequestOpen`: the participant's own request is available or scheduled.
 * `ownRequestHelped`: someone holds a reservation on the participant's request.
 * `helping`: the participant holds an active helper reservation.
 * `ownPlacedPickup`: the participant's own order is placed and the requester
 * pickup obligation is unfinished (W4-R3 `hasUnfinishedPlacedPickupObligation`:
 * unconfirmed, retained, before the requester visibility cutoff). An invalid
 * obligation state rejects, so the gate fails closed.
 */
export type EmailReplacementBlocker =
  | "ownRequestOpen"
  | "ownRequestHelped"
  | "helping"
  | "ownPlacedPickup";

const BLOCKER_ORDER: EmailReplacementBlocker[] = [
  "helping",
  "ownPlacedPickup",
  "ownRequestHelped",
  "ownRequestOpen",
];

export async function listEmailReplacementBlockers(
  participantId: string,
  now: Date
): Promise<EmailReplacementBlocker[]> {
  const id = new mongoose.Types.ObjectId(participantId);
  const [owned, helping, placedPickup] = await Promise.all([
    MealRequest.find({
      requesterParticipantId: id,
      status: { $in: ["open", "claimed"] },
      expiresAt: { $gt: now },
    })
      .select("+externalOrderAffirmed +moderationUnavailable +reservationLapseHold")
      .lean()
      .exec(),
    MealRequest.exists({
      helperParticipantId: id,
      status: "claimed",
      $or: [
        { claimExpiresAt: { $gt: now } },
        { externalOrderAffirmed: true, expiresAt: { $gt: now } },
      ],
    }).exec(),
    hasUnfinishedPlacedPickupObligation(participantId, now),
  ]);

  const found = new Set<EmailReplacementBlocker>();
  if (helping) found.add("helping");
  if (placedPickup) found.add("ownPlacedPickup");
  for (const document of owned) {
    const phase = deriveOwnerPhase(
      document as unknown as Parameters<typeof deriveOwnerPhase>[0],
      now
    );
    if (phase === "reserved") found.add("ownRequestHelped");
    else if (phase !== null) found.add("ownRequestOpen");
  }
  return BLOCKER_ORDER.filter((blocker) => found.has(blocker));
}

export interface EmailReplacementGateDependencies {
  resolveAuthority: (req: Request) => Promise<ParticipantAuthorityResolution>;
  listBlockers: (
    participantId: string,
    now: Date
  ) => Promise<EmailReplacementBlocker[]>;
  now: () => Date;
}

export const defaultEmailReplacementGateDependencies: EmailReplacementGateDependencies =
  {
    resolveAuthority: resolveParticipantAuthority,
    listBlockers: listEmailReplacementBlockers,
    now: () => new Date(),
  };

function sendUnavailable(res: Response): Response {
  return sendDay4Error(
    res,
    503,
    "VERIFICATION_UNAVAILABLE",
    PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
  );
}

function sendBlocked(
  res: Response,
  blockers: EmailReplacementBlocker[]
): Response {
  return res
    .status(409)
    .json({
      ...day4Error(EMAIL_REPLACEMENT_BLOCKED_CODE, EMAIL_REPLACEMENT_BLOCKED_MESSAGE),
      blockers,
    });
}

/**
 * Returns `true` when it has already answered (refusal or failure) and the
 * caller must stop; `false` when the verification may proceed.
 *
 * `targetPrincipal` is the address being verified. Verifying the address the
 * credential already names is not a replacement and is never gated.
 */
export async function refuseBlockedEmailReplacement(
  req: Request,
  res: Response,
  targetPrincipal: string,
  dependencies: EmailReplacementGateDependencies = defaultEmailReplacementGateDependencies
): Promise<boolean> {
  const submitted = req.headers?.[PARTICIPANT_AUTHORITY_HEADER];
  if (submitted === undefined || submitted.length === 0) return false;

  let authority: ParticipantAuthorityResolution;
  try {
    authority = await dependencies.resolveAuthority(req);
  } catch {
    sendUnavailable(res);
    return true;
  }
  if (!authority.ok) {
    // A credential that is no longer usable protects no obligations a
    // replacement could strand, so re-verification proceeds. A gate that could
    // not answer fails closed.
    if (authority.refusal === "unavailable") {
      sendUnavailable(res);
      return true;
    }
    return false;
  }
  if (authority.participant.principal === targetPrincipal) return false;

  try {
    const blockers = await dependencies.listBlockers(
      authority.participant.participantId,
      dependencies.now()
    );
    if (blockers.length === 0) return false;
    sendBlocked(res, blockers);
    return true;
  } catch {
    console.error("[participant] Email replacement eligibility lookup failed");
    sendUnavailable(res);
    return true;
  }
}

/** `GET /api/participant/email-replacement-eligibility` — read-only preview. */
export function createEmailReplacementEligibilityHandler(
  dependencies: EmailReplacementGateDependencies = defaultEmailReplacementGateDependencies
) {
  return async function getEmailReplacementEligibility(
    req: Request,
    res: Response
  ): Promise<Response> {
    res.setHeader("Cache-Control", "private, no-store");
    res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);
    const authority = await dependencies.resolveAuthority(req);
    if (!authority.ok) {
      return sendParticipantAuthorityRefusal(res, authority.refusal);
    }
    try {
      const blockers = await dependencies.listBlockers(
        authority.participant.participantId,
        dependencies.now()
      );
      return res.json({ eligible: blockers.length === 0, blockers });
    } catch {
      console.error("[participant] Email replacement eligibility lookup failed");
      return sendUnavailable(res);
    }
  };
}
