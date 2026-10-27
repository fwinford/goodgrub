import { Subscriber } from "../models/db.js";
import { UNSUBSCRIBE_CLEARED_CONFIRMATION_FIELDS } from "./confirmSubscription.js";
import {
  readUnsubscribeSigningSecret,
  resolveUnsubscribeCredentialVersion,
  verifyUnsubscribeCredential,
} from "./unsubscribeCredential.js";

/**
 * Redemption half of the stable unsubscribe credential (`unsubscribeCredential.ts`).
 *
 * Two operations share one eligibility check: the safe page render, which
 * decides only whether to show a form, and the explicit unsubscribe, which
 * mutates. Neither reports anything about the subscriber it found — a link is
 * either usable or it is not — so an authentic credential cannot be used to
 * learn whether an address is pending, confirmed, or already unsubscribed.
 *
 * Nothing here rotates `unsubscribeCredentialVersion`. Unsubscribing is not
 * revocation: the same emailed link must keep working afterwards, across
 * re-signup and reconfirmation, so the credential outlives the status it acts
 * on.
 */
export type UnsubscribeCredentialCheck = "match" | "invalid";

export type UnsubscribeOutcome = "unsubscribed" | "invalid";

export interface UnsubscribeResult {
  outcome: UnsubscribeOutcome;
}

/**
 * The persisted version state that was actually validated, expressed as an
 * update filter. A row that physically lacked the field must still lack it, and
 * a row that carried one must still carry that exact value: those are different
 * conditions, and only the second can be written as an equality match.
 *
 * The value side is always a number, never `null`: `{field: null}` matches a
 * document with no field at all as well as one holding a physical null, so it
 * could never state either condition exactly. A stored null never reaches here.
 */
type StoredVersionCondition =
  | { unsubscribeCredentialVersion: { $exists: false } }
  | { unsubscribeCredentialVersion: number };

interface MatchedSubscriber {
  subscriberId: string;
  storedVersionCondition: StoredVersionCondition;
}

interface VersionedSubscriber {
  _id: unknown;
  unsubscribeCredentialVersion?: unknown;
}

/**
 * Cryptographic authenticity first, then the stored revocation counter.
 *
 * The comparison runs through `resolveUnsubscribeCredentialVersion`, so a
 * document that physically lacks the field is version 1 and accepts a version-1
 * credential. A direct `stored !== credentialVersion` would reject every legacy
 * row instead, since `undefined !== 1`. Absence is the only fallback: a
 * persisted `null`, like any other malformed stored value, makes the link
 * unusable rather than resolving to version 1.
 */
async function matchCredential(
  rawCredential: unknown,
  secret: Buffer
): Promise<MatchedSubscriber | null> {
  const verified = verifyUnsubscribeCredential(rawCredential, secret);
  if (!verified) return null;

  // Only identity and the revocation counter. The address, status, counters,
  // and send history are none of this path's business.
  const subscriber = await Subscriber.findById(verified.subscriberId)
    .select("unsubscribeCredentialVersion")
    .lean<VersionedSubscriber | null>()
    .exec();
  if (!subscriber) return null;

  const storedVersion = subscriber.unsubscribeCredentialVersion;
  let resolvedVersion: number;
  try {
    resolvedVersion = resolveUnsubscribeCredentialVersion(storedVersion);
  } catch {
    // A persisted version outside the accepted range — including a `null` this
    // schema never writes — is a defect, not a decision this route may make.
    // The link is simply unusable.
    return null;
  }
  if (resolvedVersion !== verified.credentialVersion) return null;

  return {
    subscriberId: verified.subscriberId,
    storedVersionCondition:
      storedVersion === undefined
        ? { unsubscribeCredentialVersion: { $exists: false } }
        : // Resolution succeeded and the field was present, so the stored value
          // is exactly this integer.
          { unsubscribeCredentialVersion: resolvedVersion },
  };
}

/**
 * Whether a credential is currently redeemable. Reads only; the safe GET page
 * is rendered from this and must never mutate, because inbox scanners and
 * prefetchers open emailed links with nobody acting.
 */
export async function checkUnsubscribeCredential(
  rawCredential: unknown,
  secret: Buffer = readUnsubscribeSigningSecret()
): Promise<{ outcome: UnsubscribeCredentialCheck }> {
  const matched = await matchCredential(rawCredential, secret);
  return { outcome: matched ? "match" : "invalid" };
}

/**
 * Moves a subscriber to `unsubscribed` in one conditional atomic update.
 *
 * Reading the document and saving a decided status would let a credential
 * rotation that lands between the two be overwritten, reviving alerts for an
 * address whose links were just revoked. The update therefore repeats the same
 * persisted version state the check validated, and a filter miss — rotated
 * version, or a row that no longer exists — is reported as the one generic
 * invalid result, disclosing neither.
 *
 * The transition is accepted from `pending`, `confirmed`, and `unsubscribed`
 * alike, so a repeated press of the button is a no-op rather than an error.
 */
export async function unsubscribeSubscriber(
  rawCredential: unknown,
  now: Date,
  secret: Buffer = readUnsubscribeSigningSecret()
): Promise<UnsubscribeResult> {
  const matched = await matchCredential(rawCredential, secret);
  if (!matched) return { outcome: "invalid" };

  const result = await Subscriber.updateOne(
    { _id: matched.subscriberId, ...matched.storedVersionCondition },
    // A pipeline, because the first unsubscribe timestamp has to be preserved
    // from the document itself: reading it first and deciding here would
    // reopen the race this single update exists to close.
    [
      {
        $set: {
          status: "unsubscribed",
          // Existing unsubscribe history stands. Confirmation clears this
          // field, so a reconfirmed address that unsubscribes again records
          // the new lifecycle's timestamp rather than an ancient one.
          unsubscribedAt: { $ifNull: ["$unsubscribedAt", now] },
        },
      },
      // Every confirmation credential the row holds — the active token and its
      // send-attempt fields, and the bounded receipt of the token already
      // spent. A pending row's outstanding link cannot activate an address that
      // has now asked to stop, and a confirmed row's original link can no
      // longer be answered *already confirmed*, which stopped being true the
      // moment this update ran. Delivery counters, send history, `_id`, and the
      // credential version are untouched.
      { $unset: [...UNSUBSCRIBE_CLEARED_CONFIRMATION_FIELDS] },
    ]
  ).exec();

  if (!result?.matchedCount) return { outcome: "invalid" };

  return { outcome: "unsubscribed" };
}
