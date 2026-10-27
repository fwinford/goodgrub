import type { Request, Response } from "express";
import mongoose, { type ClientSession } from "mongoose";
import { RequestParticipation } from "../models/db.js";
import {
  deriveParticipantIdentityAliases,
  loadParticipantIdentityManifest,
  PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS,
  ParticipantIdentityConfigurationError,
} from "./participantIdentityKeys.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
  type ResolvedParticipant,
} from "./participantAuthorityGate.js";
import type { CallerOwnershipContext } from "./requestListResponse.js";

/**
 * Resolves the caller's verified participant identity when one is presented,
 * without ever refusing the call when it is not (W3-H2).
 *
 * A missing, malformed, or no-longer-valid credential degrades to `null`
 * rather than a refusal. The two ordinary request reads no longer use this
 * (W4-R5: they refuse through `requireVerifiedCallerForRead`).
 */
export async function resolveOptionalParticipantAuthority(
  req: Request
): Promise<ResolvedParticipant | null> {
  const resolution = await resolveParticipantAuthority(req);
  return resolution.ok ? resolution.participant : null;
}

/**
 * The verified caller behind a request read (W4-R5): the resolved participant
 * and the ownership context derived from that same resolution, so the pair
 * fence, the W3-H2 participation filter, and `isOwnRequest` can never describe
 * different callers for one read.
 */
export type VerifiedRequestReadCaller = {
  participant: ResolvedParticipant;
  ownershipContext: CallerOwnershipContext;
};

export class ParticipantParticipationReadCancelled extends Error {}

/**
 * Verified-only gate for the two ordinary request reads, `GET /api/requests`
 * and `GET /api/request/:id` (W4-R5).
 *
 * Resolves participant authority through the shared gate and, when it cannot,
 * sends the shared structured refusal and returns `null` — the caller must
 * return immediately. There is no anonymous or unresolved fallback: a missing,
 * malformed, independently revoked or unverifiable credential never reaches any
 * request-dependent work. Callers invoke this before id validation, any
 * database lookup, the pair fence, and the visibility check, so the answer to
 * an unauthorized caller is identical whether or not the id exists, is fenced,
 * or is not yet visible.
 *
 * The no-store headers are set here, ahead of any response, so a refusal is
 * never reusable across callers.
 */
export async function requireVerifiedCallerForRead(
  req: Request,
  res: Response
): Promise<VerifiedRequestReadCaller | null> {
  res.setHeader("Cache-Control", "private, no-store");
  res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);

  const resolution = await resolveParticipantAuthority(req);
  if (!resolution.ok) {
    sendParticipantAuthorityRefusal(res, resolution.refusal);
    return null;
  }
  return {
    participant: resolution.participant,
    ownershipContext: {
      kind: "resolved",
      participantId: resolution.participant.participantId,
    },
  };
}

/**
 * The exact set of request ids this verified participant has ever
 * successfully held (the W3-H2 durable one-successful-participation record),
 * restricted to the supplied candidate ids.
 *
 * Used to remove a request from a verified participant's own marketplace
 * list after they have released or expired out of it — every other eligible
 * participant's view is unaffected, because this read and its filter are
 * always scoped to exactly one caller's own participant id.
 */
export async function findParticipatedRequestIds(
  participantId: string,
  principal: string,
  candidateRequestIds: unknown[],
  session?: ClientSession,
  isCanceled: () => boolean = () => false
): Promise<Set<string>> {
  if (isCanceled()) throw new ParticipantParticipationReadCancelled();
  if (candidateRequestIds.length === 0) return new Set();

  const { ring, entries } = await loadParticipantIdentityManifest(
    "participation",
    session
  );
  if (isCanceled()) throw new ParticipantParticipationReadCancelled();
  const validVersions = entries.map((entry) => entry.version);
  const unsafeRowsQuery = RequestParticipation.find({
    requestId: { $in: candidateRequestIds },
    $or: [
      { participationKeyVersion: { $exists: false } },
      { participationHmac: { $exists: false } },
      { participationKeyVersion: { $nin: validVersions } },
    ],
  });
  if (session) unsafeRowsQuery.session(session);
  const unsafeRows = await unsafeRowsQuery
    .maxTimeMS(PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS)
    .select("_id")
    .limit(1)
    .lean()
    .exec();
  if (isCanceled()) throw new ParticipantParticipationReadCancelled();
  if (unsafeRows.length > 0) {
    throw new ParticipantIdentityConfigurationError(
      "Request participation identity data is unavailable"
    );
  }

  const aliases = candidateRequestIds.flatMap((candidate) =>
    deriveParticipantIdentityAliases(
      "participation",
      ring,
      entries,
      String(candidate),
      principal
    ).map((alias) => ({
      requestId: candidate,
      participationKeyVersion: alias.version,
      participationHmac: alias.digest,
    }))
  );
  const query = RequestParticipation.find({
    $or: [
      {
        participantId: new mongoose.Types.ObjectId(participantId),
        requestId: { $in: candidateRequestIds },
      },
      ...aliases,
    ],
  });
  if (session) query.session(session);
  let rows: unknown[];
  try {
    rows = await query
      .maxTimeMS(PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS)
      .select("requestId")
      .lean()
      .exec();
  } catch {
    // The lookup filter contains keyed pseudonymous identity. Do not pass a
    // database error containing that filter to the global error logger.
    throw new ParticipantIdentityConfigurationError(
      "Request participation identity data is unavailable"
    );
  }
  if (isCanceled()) throw new ParticipantParticipationReadCancelled();

  return new Set(
    rows.map((row) => String((row as { requestId: unknown }).requestId))
  );
}

/**
 * The W3-H2 marketplace-presentation filter behind `GET /api/requests`:
 * removes every request the resolved caller has ever successfully held from
 * their own list. `participant` is `null` only for a caller with no resolved
 * authority, which returns `docs` unfiltered and untouched rather than
 * querying anything; since W4-R5 the list route never reaches this with
 * `null` (it refuses first). Every other eligible participant's own list
 * is unaffected, because the lookup and filter are always scoped to exactly
 * this one caller's own participant id.
 *
 * Extracted from the `GET /api/requests` handler in `app.ts` so this
 * behavior — list correctly excludes previously-held requests, other
 * eligible participants' lists are unaffected — has direct focused/Mongo
 * test coverage rather than only source inspection.
 */
export async function filterRequestListForParticipant<
  T extends { _id: unknown }
>(
  docs: T[],
  participant: ResolvedParticipant | null,
  session?: ClientSession,
  isCanceled: () => boolean = () => false
): Promise<T[]> {
  if (isCanceled()) throw new ParticipantParticipationReadCancelled();
  if (!participant || docs.length === 0) return docs;

  const participatedIds = await findParticipatedRequestIds(
    participant.participantId,
    participant.principal,
    docs.map((doc) => doc._id),
    session,
    isCanceled
  );
  if (isCanceled()) throw new ParticipantParticipationReadCancelled();
  if (participatedIds.size === 0) return docs;

  return docs.filter((doc) => !participatedIds.has(String(doc._id)));
}
