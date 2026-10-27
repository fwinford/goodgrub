import mongoose from "mongoose";
import {
  Participant,
  ParticipantVerification,
  type IParticipant,
} from "../models/db.js";
import { rebindRetainedParticipantBlocks } from "./participantBlockSafety.js";
import {
  INITIAL_PARTICIPANT_AUTHORITY_VERSION,
  digestVerificationCode,
  generateVerificationCode,
  isValidRawVerificationCode,
  readParticipantSigningSecret,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  ModerationConflictError,
  checkParticipantCreationRestriction,
} from "./safetyIdentity.js";
import {
  tryReadSafetyIdentityKeyring,
  type SafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";

/**
 * The participant verification challenge lifecycle: issue, supersede, redeem.
 *
 * Every state transition here is one conditional atomic mutation. Reading a
 * challenge and then writing a decided outcome would let two concurrent
 * redemptions both observe the same live challenge and both succeed, or let two
 * concurrent wrong guesses both spend the same remaining attempt. The
 * conditional mutations below let exactly one caller win each transition, so a
 * concurrent redemption yields one coherent authoritative answer.
 *
 * Nothing in this module returns, stores, or logs a raw code. The code exists
 * in exactly two places for exactly as long as it takes to leave: the local
 * variable that sends the email, and the recipient's inbox.
 */

/**
 * Ten minutes. Long enough to switch to a mail app, find the message, and type
 * six digits without racing; short enough that a code sitting in an unattended
 * inbox stops being usable within the same sitting.
 */
export const VERIFICATION_CODE_LIFETIME_MS = 10 * 60 * 1000;

/**
 * One minute between issues for one address. This is the anti-mail-bomb bound:
 * without it, "Resend" is a button that mails a stranger's inbox as fast as it
 * can be tapped. It is deliberately per-address and enforced from the persisted
 * `issuedAt`, so it survives process restarts and applies across devices, not
 * just within one client's memory.
 */
export const VERIFICATION_RESEND_COOLDOWN_MS = 60 * 1000;

/**
 * Five wrong codes retire the challenge. Combined with the six-digit space and
 * the ten-minute lifetime, an attacker gets five of a million per challenge and
 * has to mail the victim to get another five.
 */
export const VERIFICATION_MAXIMUM_ATTEMPTS = 5;

/**
 * How long a spent or lapsed challenge row survives past its own expiry, purely
 * so redemption can answer a duplicate submission coherently. It matches nothing
 * after `expiresAt`; this is retention, not lifetime.
 */
export const VERIFICATION_RETENTION_MS = 60 * 60 * 1000;

/**
 * How long after a successful redemption the *same* code still answers as the
 * success it already was.
 *
 * This window exists for exactly one reason: a duplicate submission — the loser
 * of a concurrent redemption, a retried request, a double tap — must be told
 * the truth rather than "that code is incorrect". One minute covers every one
 * of those and nothing else.
 *
 * It is deliberately much shorter than the ten-minute lifetime. A redeemed code
 * that kept issuing authority until expiry would be a six-digit bearer
 * credential sitting in an inbox with nine minutes left on it; after this window
 * the code is spent, and the honest answer is to request a new one.
 */
export const VERIFICATION_REDEMPTION_REPLAY_MS = 60 * 1000;

export type ChallengeIssueResult =
  | { outcome: "issued"; expiresAt: Date; resendAvailableAt: Date }
  /** A challenge for this address was issued inside the cooldown window. */
  | { outcome: "cooldown"; resendAvailableAt: Date }
  /** The code could not be mailed. Nothing usable was left behind. */
  | { outcome: "emailUnavailable" };

export type RedemptionResult =
  /** Backend-authoritative: this caller controls this mailbox. */
  | { outcome: "verified"; principal: string; participant: IParticipant }
  | { outcome: "invalidCode" }
  | { outcome: "expired" }
  | { outcome: "tooManyAttempts" }
  /** No live challenge exists for this address at all. */
  | { outcome: "noChallenge" };

export interface ParticipantVerificationDependencies {
  now: () => Date;
  generateCode: () => string;
  readSecret: () => Buffer;
  sendVerificationEmail: (principal: string, code: string) => Promise<void>;
  readSafetyKeyring?: () => SafetyIdentityKeyring | null;
}

function isDuplicateKey(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === 11000
  );
}

/**
 * When another issue owns the cooldown, the instant it reopens.
 *
 * Read after losing the conditional mutation, purely to answer "when may I ask
 * again". It is a hint, not authority: the winner's persisted `issuedAt` is
 * what the next attempt is actually judged against, and if the row has since
 * vanished the caller is told a full cooldown rather than being handed a moment
 * that has already passed.
 */
async function resendAvailableAtFor(
  principal: string,
  now: Date
): Promise<Date> {
  const existing = await ParticipantVerification.findOne({ email: principal })
    .select("issuedAt")
    .lean<{ issuedAt?: Date }>()
    .exec();
  const issuedAt = existing?.issuedAt;
  return new Date(
    (issuedAt ? issuedAt.getTime() : now.getTime()) +
      VERIFICATION_RESEND_COOLDOWN_MS
  );
}

/**
 * Issues a fresh challenge for `principal`, superseding any earlier one.
 *
 * The cooldown is enforced *by* the write, not by a read taken before it. That
 * is the whole difference between this and a read-then-write: two concurrent
 * resends both read a cooldown-eligible challenge, and if the write were
 * unconditional both would mail a code and the second would overwrite the
 * first's digest — leaving one participant holding two codes, exactly one of
 * which the database still recognizes, and no way to tell which. The
 * conditional filter below lets exactly one of them own the transition.
 *
 * The write happens before the send, and the send failure path removes exactly
 * the row this attempt wrote — matched on both its digest *and* its issuing
 * instant, so a rollback can only ever delete its own attempt's challenge and
 * never a newer winner's. That ordering keeps the database from holding a code
 * the participant could not have received, and a failed send leaves no
 * challenge and no cooldown, so the participant can ask again immediately
 * rather than waiting out a minute for a code that never arrived.
 */
export async function issueParticipantVerificationChallenge(
  principal: string,
  dependencies: ParticipantVerificationDependencies
): Promise<ChallengeIssueResult> {
  const now = dependencies.now();
  const cooldownCutoff = new Date(
    now.getTime() - VERIFICATION_RESEND_COOLDOWN_MS
  );

  const secret = dependencies.readSecret();
  const code = dependencies.generateCode();
  const codeDigest = digestVerificationCode(principal, code, secret);
  const expiresAt = new Date(now.getTime() + VERIFICATION_CODE_LIFETIME_MS);

  try {
    // One conditional upsert on the unique address. This *is* both the cooldown
    // and the supersede: it matches only an address whose last issue is already
    // outside the cooldown, and replaces that row's digest, attempts, and
    // redemption receipt in a single write. There is never a moment when two
    // codes are live for one address, and never a read-then-write window
    // another issue could slip through.
    //
    // A row that exists but is inside the cooldown does not match, so the
    // upsert attempts an insert instead and loses on the unique index. A
    // genuinely concurrent issue loses the same way. Both are the same answer:
    // somebody else owns the live code, and this attempt must not mail a second
    // one.
    await ParticipantVerification.findOneAndUpdate(
      { email: principal, issuedAt: { $lte: cooldownCutoff } },
      {
        $set: {
          codeDigest,
          issuedAt: now,
          expiresAt,
          attemptsRemaining: VERIFICATION_MAXIMUM_ATTEMPTS,
          deleteAt: new Date(expiresAt.getTime() + VERIFICATION_RETENTION_MS),
        },
        $unset: { redeemedAt: "" },
      },
      { upsert: true, new: true, runValidators: true }
    )
      .select("_id")
      .lean()
      .exec();
  } catch (error) {
    if (!isDuplicateKey(error)) throw error;
    return {
      outcome: "cooldown",
      resendAvailableAt: await resendAvailableAtFor(principal, now),
    };
  }

  try {
    await dependencies.sendVerificationEmail(principal, code);
  } catch {
    try {
      // Pinned to this attempt's own write: its digest and its issuing instant
      // together. A newer challenge another request issued in the meantime has
      // a different `issuedAt` and so is never removed here, and an already
      // redeemed challenge is left alone rather than being un-redeemed.
      await ParticipantVerification.deleteOne({
        email: principal,
        codeDigest,
        issuedAt: now,
        redeemedAt: { $exists: false },
      }).exec();
    } catch {
      // Best effort. The participant is told the code could not be sent either
      // way, and the challenge expires on its own. Deliberately no address,
      // code, or digest in the log.
      console.error(
        "[participant] Verification challenge cleanup outcome is unknown after a failed send"
      );
    }
    return { outcome: "emailUnavailable" };
  }

  return {
    outcome: "issued",
    expiresAt,
    resendAvailableAt: new Date(
      now.getTime() + VERIFICATION_RESEND_COOLDOWN_MS
    ),
  };
}

/**
 * Redeems a submitted code against backend `now`.
 *
 * Five conditional reads and writes, in this order and for these reasons:
 *
 * 1. The success mutation. It matches the digest, the unexpired deadline, and
 *    remaining attempts together, and stamps `redeemedAt` in the same write, so
 *    exactly one concurrent submission can win.
 * 2. The receipt, bounded by the replay window and by remaining attempts. It is
 *    checked only after the mutation lost, so the loser of a concurrent
 *    redemption — or the same person's retry — reports the success that already
 *    happened rather than an invalid code.
 * 3. The digest-matched-but-unusable read. A code that is *right* but arrives
 *    after its replay window closed, or against a challenge whose attempts are
 *    spent, is not a wrong guess and must not spend one.
 * 4. The attempt decrement. Reached only by a code that is genuinely wrong.
 *    Deliberately not conditioned on `redeemedAt`: a redeemed challenge is
 *    still one whose code yields authority, so guessing against it has to be
 *    bounded by the same five attempts. Without that, redemption would open an
 *    unlimited guessing window against a live credential.
 * 5. Classification of the remainder, which mutates nothing.
 */
export async function redeemParticipantVerificationCode(
  principal: string,
  rawCode: unknown,
  dependencies: ParticipantVerificationDependencies
): Promise<RedemptionResult> {
  if (!isValidRawVerificationCode(rawCode)) {
    // Answered from shape alone: a malformed submission never reaches the
    // database, so it cannot spend one of the five real attempts.
    return { outcome: "invalidCode" };
  }

  const secret = dependencies.readSecret();
  const codeDigest = digestVerificationCode(principal, rawCode, secret);

  const initial = await establishFromVerificationChallenge(
    principal,
    codeDigest,
    "initial",
    dependencies
  );
  if (initial) return initial;
  const replay = await establishFromVerificationChallenge(
    principal,
    codeDigest,
    "replay",
    dependencies
  );
  if (replay) return replay;

  const now = dependencies.now();
  // The submitted code matches this address's challenge but the challenge is no
  // longer redeemable: its replay window closed, its attempts are spent, or it
  // has expired. Not a guess, so it spends nothing — and deliberately not
  // "incorrect", which would be untrue and would send the participant looking
  // for a typo instead of requesting a new code.
  const matched = await ParticipantVerification.findOne({
    email: principal,
    codeDigest,
  })
    .select("expiresAt attemptsRemaining")
    .lean<{ expiresAt: Date; attemptsRemaining: number }>()
    .exec();
  if (matched) {
    return matched.attemptsRemaining <= 0
      ? { outcome: "tooManyAttempts" }
      : { outcome: "expired" };
  }

  const spent = await ParticipantVerification.findOneAndUpdate(
    {
      email: principal,
      expiresAt: { $gt: now },
      attemptsRemaining: { $gt: 0 },
    },
    { $inc: { attemptsRemaining: -1 } },
    { new: true }
  )
    .select("attemptsRemaining")
    .lean<{ attemptsRemaining: number }>()
    .exec();

  if (spent) {
    return spent.attemptsRemaining <= 0
      ? { outcome: "tooManyAttempts" }
      : { outcome: "invalidCode" };
  }

  // Nothing was decremented, so no live challenge with attempts left exists.
  const stale = await ParticipantVerification.findOne({ email: principal })
    .select("expiresAt attemptsRemaining")
    .lean<{ expiresAt: Date; attemptsRemaining: number }>()
    .exec();
  if (!stale) return { outcome: "noChallenge" };
  if (stale.expiresAt.getTime() <= now.getTime()) return { outcome: "expired" };
  if (stale.attemptsRemaining <= 0) return { outcome: "tooManyAttempts" };
  // A challenge that is live, has attempts, and matched none of the above was
  // superseded or redeemed between this call's own reads. Requesting a new code
  // is the honest answer; nothing here may invent authority from a lost race.
  return { outcome: "invalidCode" };
}

async function establishFromVerificationChallenge(
  principal: string,
  codeDigest: string,
  mode: "initial" | "replay",
  dependencies: ParticipantVerificationDependencies
): Promise<RedemptionResult | null> {
  const session = await mongoose.startSession();
  try {
    let participant: IParticipant | null = null;
    let redeemed = false;
    // A concurrent first-time safety-identity insert surfaces as a conflict that
    // a fresh transaction resolves (W4-U1.2); retry a bounded number of times.
    for (let attempt = 1; ; attempt += 1) {
      try {
        await session.withTransaction(
          async () => {
            participant = null;
            redeemed = false;
            const now = dependencies.now();
            const candidate = await ParticipantVerification.findOne({
              email: principal,
              codeDigest,
            })
              .select("_id")
              .session(session)
              .lean<{ _id: mongoose.Types.ObjectId } | null>()
              .exec();
            if (!candidate) return;

            const filter: Record<string, unknown> = {
              _id: candidate._id,
              email: principal,
              codeDigest,
              expiresAt: { $gt: now },
              attemptsRemaining: { $gt: 0 },
            };
            let update: Record<string, unknown>;
            if (mode === "initial") {
              filter.redeemedAt = { $exists: false };
              update = { $set: { redeemedAt: now } };
            } else {
              filter.redeemedAt = {
                $gt: new Date(now.getTime() - VERIFICATION_REDEMPTION_REPLAY_MS),
              };
              update = { $inc: { redemptionFenceEpoch: 1 } };
            }
            const challenge = await ParticipantVerification.findOneAndUpdate(
              filter,
              update,
              { new: true, session }
            )
              .select("_id")
              .lean()
              .exec();
            if (!challenge) return;

            const established = await establishParticipant(
              principal,
              now,
              session,
              dependencies.readSafetyKeyring ?? tryReadSafetyIdentityKeyring
            );
            await rebindRetainedParticipantBlocks(
              {
                participantId: new mongoose.Types.ObjectId(String(established._id)),
                principal,
                expectedAuthorityVersion: established.authorityVersion,
              },
              session
            );
            participant = established;
            redeemed = true;
          },
          {
            readConcern: { level: "snapshot" },
            writeConcern: { w: "majority" },
          }
        );
        break;
      } catch (error) {
        if (error instanceof ModerationConflictError && attempt < 4) continue;
        throw error;
      }
    }
    if (!redeemed || !participant) return null;
    return { outcome: "verified", principal, participant };
  } finally {
    await session.endSession();
  }
}

/**
 * Establishes or refreshes the Participant row a verified principal names, and
 * returns it. Upserted rather than read-then-created so two concurrent
 * verifications of a brand-new address produce one participant, not a duplicate
 * key failure the caller has to interpret.
 *
 * `authorityVersion` is written only on insert. Verifying again must never
 * raise it: doing so would revoke this person's other device the moment they
 * re-verified on this one.
 */
async function establishParticipant(
  principal: string,
  now: Date,
  session: mongoose.ClientSession,
  readKeyring: () => SafetyIdentityKeyring | null
): Promise<IParticipant> {
  const restriction = await checkParticipantCreationRestriction(
    readKeyring(),
    principal,
    session
  );
  const setFields: Record<string, unknown> = { verifiedAt: now };
  if (restriction.identityId) setFields.safetyIdentityRef = restriction.identityId;
  if (restriction.restricted) setFields.suspended = true;

  const participant = await Participant.findOneAndUpdate(
    { email: principal },
    {
      $set: setFields,
      $setOnInsert: {
        authorityVersion: INITIAL_PARTICIPANT_AUTHORITY_VERSION,
      },
    },
    { upsert: true, new: true, runValidators: true, session }
  ).exec();

  return participant;
}

/**
 * The credential the app stores and presents on later participant actions.
 * Signed from the participant's own identity and revocation counter, so nothing
 * derived from it is persisted and revoking is a single counter increment.
 */
export function issueParticipantAuthority(
  participant: Pick<IParticipant, "_id" | "authorityVersion">,
  secret: Buffer = readParticipantSigningSecret()
): string {
  return signParticipantAuthority(
    participant._id,
    participant.authorityVersion,
    secret
  );
}

export const defaultParticipantVerificationDependencies: Omit<
  ParticipantVerificationDependencies,
  "sendVerificationEmail"
> = {
  now: () => new Date(),
  generateCode: generateVerificationCode,
  readSecret: () => readParticipantSigningSecret(),
};
