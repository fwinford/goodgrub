import type { Request, Response } from "express";
import { Participant } from "../models/db.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  readParticipantSigningSecret,
  verifyParticipantAuthority,
} from "./participantCredentials.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";

/**
 * The backend gate every participant action passes through (W3-I1).
 *
 * The credential travels in a header rather than in the body. Three reasons,
 * all of them structural: the claim route's body is empty and the extension
 * route's body is length-checked to exactly one key, so a body field would have
 * to loosen two accepted schemas; a header keeps person-identity credentials
 * out of payloads that get echoed into validation errors; and it means the gate
 * can run before body validation, so an unverified caller learns nothing about
 * whether their payload would otherwise have been accepted.
 *
 * Backend truth is authoritative here and nowhere else. A signature that
 * verifies is not enough — the named Participant must still exist and still be
 * at the version the credential was signed at — so a revoked or deleted
 * identity is refused even though the device still holds a well-formed
 * credential. That is what makes the client's remembered state presentation
 * rather than authority.
 */
export const PARTICIPANT_AUTHORITY_HEADER = "x-commonplate-participant";

/** No participant credential was presented at all. */
export const PARTICIPANT_VERIFICATION_REQUIRED_CODE =
  "PARTICIPANT_VERIFICATION_REQUIRED";
export const PARTICIPANT_VERIFICATION_REQUIRED_MESSAGE =
  "Verify your NYU email before posting or helping with a request.";

/**
 * A credential was presented and is not usable: malformed, unsigned, signed by
 * another deployment's secret, naming a participant that no longer exists, or
 * signed at a revoked version. Kept distinct from the code above because the
 * client's next step differs — this one must discard what it stored.
 */
export const PARTICIPANT_AUTHORITY_INVALID_CODE = "PARTICIPANT_AUTHORITY_INVALID";
export const PARTICIPANT_AUTHORITY_INVALID_MESSAGE =
  "Verify your NYU email again to continue.";

/**
 * The gate itself could not answer — the signing secret is unreadable, or the
 * participant lookup failed. A `503` rather than a `401`, because refusing a
 * caller who may well be verified must not read as "you are not verified", and
 * because on a non-idempotent create this has to be a definitive no-write
 * outcome rather than an unreadable one.
 */
export const PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE =
  "PARTICIPANT_VERIFICATION_UNAVAILABLE";
export const PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE =
  "We couldn’t check your NYU verification right now. Please try again in a moment.";

/**
 * A caller-supplied address that is not the verified principal. Never silently
 * substituted: acting as another address is a different person's action, not a
 * formatting mistake.
 */
export const PARTICIPANT_PRINCIPAL_MISMATCH_CODE =
  "PARTICIPANT_PRINCIPAL_MISMATCH";
export const PARTICIPANT_PRINCIPAL_MISMATCH_MESSAGE =
  "This action can only use the NYU email you verified.";

/** The resolved actor: an opaque participant id plus its exact principal. */
export interface ResolvedParticipant {
  participantId: string;
  principal: string;
  /**
   * The `authorityVersion` the presented credential verified at, which the
   * lookup below has just confirmed still matches the stored Participant.
   * W4-N1 records this at Installation association so the Push eligibility
   * predicate can later detect a revoked/replaced identity without a second
   * query back through this gate.
   */
  authorityVersion: number;
}

export type ParticipantAuthorityRefusal =
  | "missing"
  | "invalid"
  | "unavailable";

export type ParticipantAuthorityResolution =
  | { ok: true; participant: ResolvedParticipant }
  | { ok: false; refusal: ParticipantAuthorityRefusal };

function readSubmittedAuthority(req: Pick<Request, "headers">): string | undefined {
  // Optional chaining because "no headers at all" and "no credential" are the
  // same answer, and a gate must never throw its way past a refusal.
  const header = req.headers?.[PARTICIPANT_AUTHORITY_HEADER];
  if (typeof header === "string") return header;
  // Express collapses repeated headers into an array. Two credentials is not a
  // credential: refuse rather than picking one.
  return undefined;
}

/**
 * Resolves the verified participant behind a request, or the reason it cannot.
 *
 * Never throws. A configuration or database failure becomes `"unavailable"`, so
 * a gated route answers in the structured envelope instead of falling through
 * to the generic error handler with an unreadable body a non-idempotent client
 * would have to treat as ambiguous.
 */
export async function resolveParticipantAuthority(
  req: Pick<Request, "headers">
): Promise<ParticipantAuthorityResolution> {
  const submitted = readSubmittedAuthority(req);
  if (submitted === undefined || submitted.length === 0) {
    return { ok: false, refusal: "missing" };
  }

  let verified: ReturnType<typeof verifyParticipantAuthority>;
  try {
    verified = verifyParticipantAuthority(
      submitted,
      readParticipantSigningSecret()
    );
  } catch {
    // Deliberately no credential, header value, or variable value in the log.
    console.error("[participant] Participant authority could not be verified");
    return { ok: false, refusal: "unavailable" };
  }

  if (!verified) return { ok: false, refusal: "invalid" };

  let stored: { _id: unknown; email: string } | null;
  try {
    stored = await Participant.findOne({
      _id: verified.participantId,
      authorityVersion: verified.authorityVersion,
    })
      .select("email")
      .lean<{ _id: unknown; email: string }>()
      .exec();
  } catch {
    console.error("[participant] Participant lookup failed");
    return { ok: false, refusal: "unavailable" };
  }

  if (!stored) return { ok: false, refusal: "invalid" };

  // Re-normalized and re-checked against the allowlist on every use rather than
  // trusted because it is persisted. A stored row that is no longer an eligible
  // principal — a domain removed from the allowlist, a value written by some
  // future path that skipped normalization — must return the person to
  // verification, not act as an identity nothing would accept today.
  const principal = normalizeParticipantPrincipal(stored.email);
  if (!principal) return { ok: false, refusal: "invalid" };

  return {
    ok: true,
    participant: {
      participantId: String(stored._id),
      principal,
      authorityVersion: verified.authorityVersion,
    },
  };
}

/**
 * The one place a refusal becomes a response, so every gated route answers the
 * same situation with the same status, code, and sentence.
 */
export function sendParticipantAuthorityRefusal(
  res: Response,
  refusal: ParticipantAuthorityRefusal
): Response {
  switch (refusal) {
    case "missing":
      return sendDay4Error(
        res,
        401,
        PARTICIPANT_VERIFICATION_REQUIRED_CODE,
        PARTICIPANT_VERIFICATION_REQUIRED_MESSAGE
      );
    case "invalid":
      return sendDay4Error(
        res,
        401,
        PARTICIPANT_AUTHORITY_INVALID_CODE,
        PARTICIPANT_AUTHORITY_INVALID_MESSAGE
      );
    case "unavailable":
      return sendDay4Error(
        res,
        503,
        PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
        PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
      );
  }
}
