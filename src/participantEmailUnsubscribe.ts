import type { ClientSession } from "mongoose";
import { Subscriber } from "../models/db.js";
import { UNSUBSCRIBE_CLEARED_CONFIRMATION_FIELDS } from "./confirmSubscription.js";

/**
 * W3-N2 participant-authorized email unsubscribe.
 *
 * A second path to the same declarative Off result `unsubscribeSubscriber.ts`
 * already reaches from an emailed credential. This one is reached from a
 * backend-resolved participant principal instead of a signed link: the caller
 * (`participantEmailUnsubscribeRoute.ts`) never supplies an email or a
 * Subscriber ID — the exact normalized address comes only from
 * `resolveParticipantAuthority`.
 *
 * Absent, pending, confirmed, and already-unsubscribed all converge to the
 * same result and the same atomic shape: no lookup-then-branch that could let
 * a caller learn which one it found. No Participant ID, participant
 * principal-resolution detail, or Subscriber identifier is written back onto
 * the Subscriber; the only new relationship this operation creates is the
 * mutation itself.
 *
 * Does not touch `unsubscribeCredentialVersion` — the same reason the emailed
 * credential's redemption does not: unsubscribing is not revocation, and an
 * already-emailed unsubscribe link must keep working afterwards.
 */
export type ParticipantEmailUnsubscribeResult = { outcome: "unsubscribed" };

/**
 * `email` must already be the exact backend-resolved, normalized participant
 * principal — this function performs no normalization or eligibility check of
 * its own and trusts the caller to have done so via
 * `resolveParticipantAuthority`.
 *
 * A missing Subscriber is not an error: there is nothing to turn off, and the
 * declarative result is already true. Matching by email rather than by a
 * pre-read `_id` keeps this one unconditional atomic mutation, matching the
 * shape of every other lifecycle transition in this file's neighbors, with no
 * read-then-write race between resolving the principal and writing the
 * update.
 */
export async function unsubscribeSubscriberByPrincipal(
  email: string,
  now: Date,
  session: ClientSession
): Promise<ParticipantEmailUnsubscribeResult> {
  await Subscriber.updateOne({ email }, [
    {
      $set: {
        status: "unsubscribed",
        unsubscribedAt: { $ifNull: ["$unsubscribedAt", now] },
      },
    },
    { $unset: [...UNSUBSCRIBE_CLEARED_CONFIRMATION_FIELDS] },
  ], { session }).exec();

  return { outcome: "unsubscribed" };
}
