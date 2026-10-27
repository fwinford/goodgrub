import mongoose, { type ClientSession, type Types } from "mongoose";
import {
  ModerationReport,
  ReportSubmissionLedger,
  RetentionHold,
  SafetyIdentity,
  SafetyKeyCheck,
  Suspension,
  type ISafetyIdentity,
} from "../models/moderation.js";
import {
  deriveKeyCheck,
  deriveSafetyIdentityDigests,
  type SafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";

/**
 * Restricted safety-identity operations (W4-U1.2, P2 fixed mechanism).
 *
 * The identity is a set of keyed MACs of the exact normalized verified email,
 * one per configured key, each with the id of the key that minted it. It holds
 * no raw email, participant ID or deletion-binding material, and exists only
 * while an Open report, an Active suspension or an unreleased identity-bearing
 * hold references it.
 *
 * ## One identity per principal, across keys
 *
 * `entries.digest` carries a unique multikey index. Two instances whose
 * *current* keys differ (a rolling rotation) both look up under every
 * configured key and both create with every configured digest, so the second
 * creator either finds the first's identity or loses the unique insert and
 * retries into it. It can never mint a second identity for the same principal.
 *
 * ## Fail closed
 *
 * Every operation that could otherwise answer "no restriction" first proves the
 * keyring is readable, that no key id has been reused with different material
 * (`SafetyKeyCheck`), and that every live identity is reachable through at
 * least one configured key. An identity none of whose keys is configured is
 * invisible to a lookup, so treating that as "not found" would silently lift a
 * suspension. Such a state is `unavailable` instead, and callers refuse the
 * guarded action until the key is restored.
 *
 * ## Serialization
 *
 * `serial` is the anchor every creator, referencer, verifier, confirmer and
 * releaser writes inside its own transaction, so MongoDB's first-committer-wins
 * conflict detection orders them. Verification of an email with *no* identity
 * claims the unique digest slot by inserting a row and deleting it in the same
 * transaction, so a concurrent suspension that is creating the same identity
 * conflicts with it instead of skewing past it.
 */

export class SafetyIdentityUnavailableError extends Error {
  constructor(message = "The safety identity is unavailable.") {
    super(message);
    this.name = "SafetyIdentityUnavailableError";
  }
}

/**
 * A unique-index insert lost to a concurrent committer after this transaction's
 * snapshot. The whole transaction must be restarted so its new snapshot sees the
 * committed row; `runModerationTransaction` does so.
 */
export class ModerationConflictError extends Error {
  constructor(message = "A concurrent transaction committed the same record.") {
    super(message);
    this.name = "ModerationConflictError";
  }
}

export class SafetyIdentityConflictError extends ModerationConflictError {
  constructor() {
    super("A concurrent transaction created this safety identity.");
    this.name = "SafetyIdentityConflictError";
  }
}

export class InvalidSafetyIdentityPrincipalError extends Error {
  constructor() {
    super("The value is not an eligible participant principal.");
    this.name = "InvalidSafetyIdentityPrincipalError";
  }
}

const MAXIMUM_CONFLICT_ATTEMPTS = 4;

/**
 * Runs `work` in a MongoDB transaction, restarting the whole transaction when a
 * concurrent committer won a unique insert (`ModerationConflictError`). Transient
 * transaction errors are retried by `withTransaction` itself.
 */
export async function runModerationTransaction<T>(
  work: (session: ClientSession) => Promise<T>
): Promise<T> {
  const session = await mongoose.startSession();
  try {
    for (let attempt = 1; ; attempt += 1) {
      try {
        let result!: T;
        await session.withTransaction(async () => {
          result = await work(session);
        });
        return result;
      } catch (error) {
        if (error instanceof ModerationConflictError && attempt < MAXIMUM_CONFLICT_ATTEMPTS) {
          continue;
        }
        throw error;
      }
    }
  } finally {
    await session.endSession();
  }
}

/**
 * Compares each configured key's check value with the one recorded the first
 * time that key id was seen, and returns the ids that **do not match** (a key id
 * reused with different material). With `register`, an id never seen before is
 * recorded; without it, an unrecorded id is simply not a mismatch (read-only
 * health checks). Deliberately outside any transaction: it reads the latest
 * committed registry, and a lost first-insert race re-reads the winner.
 */
export async function findMismatchedKeyIds(
  keyring: SafetyIdentityKeyring,
  register: boolean
): Promise<string[]> {
  const mismatched: string[] = [];
  for (const keyId of keyring.keys.keys()) {
    const check = deriveKeyCheck(keyring, keyId);
    let recorded = await SafetyKeyCheck.findOne({ keyId }, { check: 1 })
      .lean<{ check: string }>()
      .exec();
    if (!recorded && register) {
      try {
        await SafetyKeyCheck.create({ keyId, check });
        recorded = { check };
      } catch (error) {
        if ((error as { code?: number }).code !== 11000) throw error;
        recorded = await SafetyKeyCheck.findOne({ keyId }, { check: 1 })
          .lean<{ check: string }>()
          .exec();
      }
    }
    if (recorded && recorded.check !== check) mismatched.push(keyId);
  }
  return mismatched;
}

/** The configured key ids that are also consistent with their recorded check. */
async function usableKeyIds(
  keyring: SafetyIdentityKeyring | null,
  register: boolean
): Promise<Set<string>> {
  if (!keyring) return new Set();
  const mismatched = new Set(await findMismatchedKeyIds(keyring, register));
  return new Set([...keyring.keys.keys()].filter((keyId) => !mismatched.has(keyId)));
}

/**
 * Proves the keyring is present, that no key id was reused with different
 * material, and that every live identity is reachable through at least one
 * configured key. Throws `SafetyIdentityUnavailableError` otherwise. Returns the
 * keyring so callers can chain.
 */
export async function assertSafetyIdentityKeysAvailable(
  keyring: SafetyIdentityKeyring | null,
  session?: ClientSession
): Promise<SafetyIdentityKeyring> {
  if (!keyring) throw new SafetyIdentityUnavailableError();
  const usable = await usableKeyIds(keyring, true);
  if (usable.size !== keyring.keys.size) throw new SafetyIdentityUnavailableError();
  const stranded = SafetyIdentity.exists({ "entries.keyId": { $nin: [...usable] } });
  if (session) stranded.session(session);
  if (await stranded) throw new SafetyIdentityUnavailableError();
  return keyring;
}

/** Whether keyed safety-identity operations are currently possible. */
export async function isSafetyIdentityOperable(
  keyring: SafetyIdentityKeyring | null
): Promise<boolean> {
  try {
    await assertSafetyIdentityKeysAvailable(keyring);
    return true;
  } catch {
    return false;
  }
}

export interface KeyDependentCounts {
  /** Configured key ids whose material differs from the first-recorded check. */
  mismatchedKeys: number;
  /** Live identities none of whose keys is usable. */
  identities: number;
  /** Live submission-ledger rows whose creating key is not usable. */
  ledgerRows: number;
}

/**
 * Read-only health input: how many live records depend on key material that is
 * missing, invalid or reused. Counts only; no id, key id or value is returned.
 */
export async function countKeyDependentRecordsUnavailable(
  keyring: SafetyIdentityKeyring | null
): Promise<KeyDependentCounts> {
  const usable = [...(await usableKeyIds(keyring, false))];
  const [identities, ledgerRows] = await Promise.all([
    SafetyIdentity.countDocuments({ "entries.keyId": { $nin: usable } }),
    ReportSubmissionLedger.countDocuments({ keyId: { $nin: usable } }),
  ]);
  return {
    mismatchedKeys: keyring ? keyring.keys.size - usable.length : 0,
    identities,
    ledgerRows,
  };
}

function digestsFor(keyring: SafetyIdentityKeyring, email: unknown) {
  const digests = deriveSafetyIdentityDigests(keyring, email);
  if (digests === null) throw new InvalidSafetyIdentityPrincipalError();
  return digests;
}

/**
 * The identity for a verified email under any configured key, or `null`.
 * Read-only: it writes nothing and does not serialize. More than one match is
 * corruption the unique index should make impossible and is treated as
 * unavailable rather than guessed at.
 */
export async function findSafetyIdentity(
  keyring: SafetyIdentityKeyring | null,
  email: unknown,
  session?: ClientSession
): Promise<ISafetyIdentity | null> {
  const verified = await assertSafetyIdentityKeysAvailable(keyring, session);
  const digests = digestsFor(verified, email).map((entry) => entry.digest);
  const query = SafetyIdentity.find({ "entries.digest": { $in: digests } }).limit(2);
  if (session) query.session(session);
  const found = await query.lean<ISafetyIdentity[]>().exec();
  if (found.length > 1) throw new SafetyIdentityUnavailableError();
  return found[0] ?? null;
}

export interface EnsuredSafetyIdentity {
  identityId: Types.ObjectId;
  created: boolean;
}

/**
 * Creates or reuses the identity for a verified email, inside the caller's
 * transaction. Reuse bumps `serial` and tops up any digest for a configured key
 * the identity does not yet carry (this is how an identity re-keys: the raw
 * email is only ever in hand at a moment like this). Creation writes every
 * configured digest. The caller writes its referencing row (report, suspension,
 * hold) in the same transaction.
 */
export async function ensureSafetyIdentity(
  keyring: SafetyIdentityKeyring | null,
  email: unknown,
  session: ClientSession
): Promise<EnsuredSafetyIdentity> {
  const verified = await assertSafetyIdentityKeysAvailable(keyring, session);
  const entries = digestsFor(verified, email);

  try {
    const existing = await SafetyIdentity.findOneAndUpdate(
      { "entries.digest": { $in: entries.map((entry) => entry.digest) } },
      { $inc: { serial: 1 }, $addToSet: { entries: { $each: entries } } },
      { session, new: true, projection: { _id: 1 } }
    )
      .lean<{ _id: Types.ObjectId }>()
      .exec();
    if (existing) return { identityId: existing._id, created: false };

    const [created] = await SafetyIdentity.create([{ entries, serial: 1 }], { session });
    return { identityId: created._id as Types.ObjectId, created: true };
  } catch (error) {
    if ((error as { code?: number }).code === 11000) throw new SafetyIdentityConflictError();
    throw error;
  }
}

/**
 * The single narrow, confirm-only operation P2's final deletion may invoke
 * (P2 fixed mechanism item 5). It answers ok / not-ok and nothing else: the
 * identity exists and one of its keys is usable. It reads no other moderation
 * state and returns no identity, reference, key id or moderation data.
 *
 * It runs in the caller's (P2's) transaction and **writes the identity's
 * serialization anchor**, so a concurrent release or attachment on the same
 * identity conflicts with it: an identity confirmed here cannot be released
 * before P2's deletion commits, and a deletion cannot commit on a stale
 * confirmation. A write conflict or any other database error propagates; only a
 * definitive "not there / not usable" answers `false`, so P2's STOP is never
 * satisfied by an error swallowed as a verdict.
 */
export async function confirmSafetyIdentity(
  identityId: Types.ObjectId | string,
  keyring: SafetyIdentityKeyring | null,
  session: ClientSession
): Promise<boolean> {
  if (!keyring || !mongoose.isValidObjectId(identityId)) return false;
  const usable = await usableKeyIds(keyring, true);
  const identity = await SafetyIdentity.findOneAndUpdate(
    { _id: identityId },
    { $inc: { serial: 1 } },
    { session, new: false, projection: { entries: 1 } }
  )
    .lean<Pick<ISafetyIdentity, "entries">>()
    .exec();
  return identity !== null && identity.entries.some((entry) => usable.has(entry.keyId));
}

export interface ParticipantCreationRestriction {
  /** An Active suspension references this email's identity. */
  restricted: boolean;
  /** The identity to link on the new participant, when one exists. */
  identityId: Types.ObjectId | null;
}

/**
 * The enforcement check that belongs at verification (participant creation or
 * recreation). Dormant in Checkpoint 1: nothing calls it yet.
 *
 * It **must** run in the same transaction that creates the participant, and it
 * always writes the identity's serialization anchor:
 * - an existing identity is bumped (and topped up with any missing configured
 *   key digest), so it conflicts with a concurrent suspension, reinstatement,
 *   attachment or release of that identity;
 * - an email with no identity claims the unique digest slot by inserting a row
 *   and deleting it again in this transaction, so a suspension creating that
 *   identity concurrently cannot skew past this check and leave a recreated,
 *   unrestricted participant.
 *
 * Throws `SafetyIdentityUnavailableError` when the keyring is missing or does
 * not cover a live identity, so the caller refuses creation as unavailable
 * rather than creating an unrestricted participant.
 */
export async function checkParticipantCreationRestriction(
  keyring: SafetyIdentityKeyring | null,
  email: unknown,
  session: ClientSession
): Promise<ParticipantCreationRestriction> {
  const { identityId, created } = await ensureSafetyIdentity(keyring, email, session);
  if (created) {
    // Nothing can reference an identity this transaction just made. Keeping it
    // would leave an unreferenced keyed record behind; the insert was the claim.
    await SafetyIdentity.deleteOne({ _id: identityId }, { session });
    return { restricted: false, identityId: null };
  }
  const active = await Suspension.exists({
    safetyIdentityRef: identityId,
    state: "active",
  }).session(session);
  return { restricted: active !== null, identityId };
}

export type SafetyIdentityReleaseResult =
  | "released"
  | "referenced"
  | "kept-key-unavailable"
  | "absent";

/**
 * The release guard, run **inside the caller's transaction** so a closing or
 * lifting transition can release in the same commit. It pins the transaction to
 * the identity record (writing `serial`) and then re-verifies **zero**
 * references from an Open report, an Active suspension and an unreleased hold,
 * whichever target the hold names. Age, a `reviewAt`, a successful closure
 * alone, a sweep guess or an unavailable key never releases it; a failed or
 * uncertain verification keeps it.
 */
export async function releaseSafetyIdentityIfUnreferenced(
  identityId: Types.ObjectId,
  keyring: SafetyIdentityKeyring | null,
  session: ClientSession
): Promise<SafetyIdentityReleaseResult> {
  const pinned = await SafetyIdentity.findOneAndUpdate(
    { _id: identityId },
    { $inc: { serial: 1 } },
    { session, new: false, projection: { entries: 1 } }
  )
    .lean<Pick<ISafetyIdentity, "entries">>()
    .exec();
  if (!pinned) return "absent";
  const usable = await usableKeyIds(keyring, true);
  if (!pinned.entries.some((entry) => usable.has(entry.keyId))) return "kept-key-unavailable";

  const [report, suspension, hold] = await Promise.all([
    ModerationReport.exists({ safetyIdentityRef: identityId }).session(session),
    Suspension.exists({ safetyIdentityRef: identityId }).session(session),
    RetentionHold.exists({ safetyIdentityRef: identityId }).session(session),
  ]);
  if (report || suspension || hold) return "referenced";

  await SafetyIdentity.deleteOne({ _id: identityId }, { session });
  return "released";
}

/**
 * The sweep's retry: the same guarded transaction, for an identity left
 * unreferenced.
 */
export async function releaseUnreferencedSafetyIdentity(
  identityId: Types.ObjectId,
  keyring: SafetyIdentityKeyring | null
): Promise<SafetyIdentityReleaseResult> {
  return runModerationTransaction((session) =>
    releaseSafetyIdentityIfUnreferenced(identityId, keyring, session)
  );
}
