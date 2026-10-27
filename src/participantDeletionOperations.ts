import { randomBytes, randomUUID } from "node:crypto";
import mongoose, { type ClientSession, type Types } from "mongoose";
import {
  ParticipantDeletionOperation,
  type ParticipantDeletionPhase,
} from "../models/db.js";
import {
  DELETION_AUTHORIZATION_LIFETIME_MS,
  DELETION_CHALLENGE_LIFETIME_MS,
  DELETION_CHALLENGE_MAXIMUM_ATTEMPTS,
  DELETION_CHALLENGE_RESEND_COOLDOWN_MS,
  deletionEmailBinding,
  digestDeletionChallenge,
  generateDeletionChallengeCode,
  isValidDeletionChallengeCode,
  type DeletionChallengeBinding,
} from "./participantDeletionSecurity.js";
import { readParticipantDeletionSigningSecret } from "./participantIdentityKeys.js";
import {
  deletionRecoveryCapabilityDigest,
  generateDeletionRecoveryCapability,
} from "./participantDeletionRecovery.js";
import {
  ParticipantAccountFenceUnavailable,
  touchParticipantAccountsInSession,
} from "./participantAccountFence.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import {
  DeletionNamespaceUnavailable,
  fenceDeletionNamespace,
  isDeletionNamespaceBinding,
} from "./participantDeletionNamespace.js";

export const ACTIVE_PHASES: ParticipantDeletionPhase[] = [
  "waiting",
  "ready",
  "challengeIssued",
  "authorized",
];

type ParticipantId = string | Types.ObjectId;

export interface DeletionOperationRow {
  operationId: string;
  namespaceBinding?: string;
  participantId: Types.ObjectId;
  emailBinding: string;
  authorityVersion: number;
  phase: ParticipantDeletionPhase;
  readinessGeneration: number;
  challengeGeneration: number;
  readyAt?: Date;
  challengeDigest?: string;
  challengeIssuedAt?: Date;
  challengeCooldownEndsAt?: Date;
  challengeExpiresAt?: Date;
  challengeAttemptsRemaining?: number;
  authorizedAt?: Date;
  authorizationExpiresAt?: Date;
  canceledAt?: Date;
  completedAt?: Date;
  recoveryExpiresAt?: Date;
  recoveryCapabilityDigest?: string;
}

export const SECURITY_SELECT = [
  "+namespaceBinding",
  "+participantId",
  "+emailBinding",
  "+authorityVersion",
  "+readyAt",
  "+challengeDigest",
  "+challengeIssuedAt",
  "+challengeCooldownEndsAt",
  "+challengeExpiresAt",
  "+challengeAttemptsRemaining",
  "+authorizedAt",
  "+authorizationExpiresAt",
  "+canceledAt",
  "+completedAt",
  "+recoveryExpiresAt",
  "+recoveryCapabilityDigest",
].join(" ");

export interface ParticipantDeletionDependencies {
  now: () => Date;
  readSecret: () => Buffer;
  generateOperationId: () => string;
  generateCode: () => string;
  generateRecoveryCapability: () => string;
  /**
   * Delivers a freshly issued deletion challenge's raw code to the exact
   * bound canonical email. Only `issueParticipantDeletionChallenge` calls
   * this. The default throws so a caller that forgot to wire real delivery
   * fails closed (surfaced as `"emailUnavailable"`) instead of silently
   * skipping the send; the real implementation is injected only by the
   * route layer (`src/participantDeletionRoute.ts`), the same layering
   * `participantVerification.ts`/`participantVerificationRoute.ts` already
   * use for the ordinary verification email.
   */
  sendChallengeEmail: (principal: string, code: string) => Promise<void>;
}

const defaultDependencies: ParticipantDeletionDependencies = {
  now: () => new Date(),
  readSecret: readParticipantDeletionSigningSecret,
  generateOperationId: randomUUID,
  generateCode: generateDeletionChallengeCode,
  generateRecoveryCapability: generateDeletionRecoveryCapability,
  sendChallengeEmail: async () => {
    throw new Error("participant deletion challenge email delivery is not configured");
  },
};

export function deps(
  overrides: Partial<ParticipantDeletionDependencies> = {}
): ParticipantDeletionDependencies {
  return { ...defaultDependencies, ...overrides };
}

function duplicateKey(error: unknown): boolean {
  return typeof error === "object" && error !== null &&
    "code" in error && (error as { code?: unknown }).code === 11000;
}

export function clearLiveSecurityMaterial() {
  return {
    challengeDigest: "",
    challengeIssuedAt: "",
    challengeExpiresAt: "",
    challengeAttemptsRemaining: "",
    authorizedAt: "",
    authorizationExpiresAt: "",
    recoveryCapabilityDigest: "",
  };
}

export async function readSecureOperation(
  filter: Record<string, unknown>,
  session?: ClientSession
): Promise<DeletionOperationRow | null> {
  const query = ParticipantDeletionOperation.findOne(filter);
  if (session) query.session(session);
  return query
    .select(SECURITY_SELECT)
    .lean<DeletionOperationRow | null>()
    .exec();
}

export async function withDeletionOwnerFence<T>(
  owner: Pick<DeletionOwner, "participantId" | "canonicalEmail" | "authorityVersion" | "namespaceBinding">,
  d: ParticipantDeletionDependencies,
  work: (session: ClientSession, secret: Buffer) => Promise<T>
): Promise<T> {
  const principal = normalizeParticipantPrincipal(owner.canonicalEmail);
  if (!principal || !Number.isInteger(owner.authorityVersion)) {
    throw new ParticipantAccountFenceUnavailable();
  }
  const secret = d.readSecret();
  const session = await mongoose.startSession();
  try {
    let result!: T;
    await session.withTransaction(
      async () => {
        if (owner.namespaceBinding !== undefined) {
          await fenceDeletionNamespace(session, owner.namespaceBinding);
        }
        const fenced = await touchParticipantAccountsInSession(
          [owner.participantId],
          session,
          new Map([[String(owner.participantId), owner.authorityVersion]])
        );
        if (fenced.get(String(owner.participantId))?.principal !== principal) {
          throw new ParticipantAccountFenceUnavailable();
        }
        result = await work(session, secret);
      },
      {
        readConcern: { level: "snapshot" },
        writeConcern: { w: "majority" },
      }
    );
    return result;
  } finally {
    await session.endSession();
  }
}

export interface DeletionOwner {
  operationId: string;
  namespaceBinding?: string;
  participantId: ParticipantId;
  canonicalEmail: string;
  authorityVersion: number;
}

export function ownerFilter(owner: DeletionOwner, secret: Buffer): Record<string, unknown> {
  return {
    operationId: owner.operationId,
    ...(owner.namespaceBinding !== undefined ? { namespaceBinding: owner.namespaceBinding } : {}),
    participantId: owner.participantId,
    emailBinding: deletionEmailBinding(owner.canonicalEmail, secret),
    authorityVersion: owner.authorityVersion,
  };
}

function challengeBinding(row: DeletionOperationRow): DeletionChallengeBinding {
  return {
    operationId: row.operationId,
    participantId: String(row.participantId),
    emailBinding: row.emailBinding,
    authorityVersion: row.authorityVersion,
    readinessGeneration: row.readinessGeneration,
    challengeGeneration: row.challengeGeneration,
  };
}

function assertExpectedGeneration(value: number): void {
  if (!Number.isInteger(value) || value < 0) {
    throw new Error("participant deletion requires a non-negative readiness generation");
  }
}

export interface ParticipantDeletionStatus {
  operationId: string;
  namespaceBinding?: string;
  phase: ParticipantDeletionPhase;
  readinessGeneration: number;
  challenge?: {
    expiresAt: Date;
    cooldownEndsAt: Date;
    attemptsRemaining: number;
  };
  authorization?: { expiresAt: Date };
}

export function statusProjection(row: DeletionOperationRow): ParticipantDeletionStatus {
  const result: ParticipantDeletionStatus = {
    operationId: row.operationId,
    ...(isDeletionNamespaceBinding(row.namespaceBinding) ? { namespaceBinding: row.namespaceBinding } : {}),
    phase: row.phase,
    readinessGeneration: row.readinessGeneration,
  };
  if (
    row.phase === "challengeIssued" &&
    row.challengeExpiresAt &&
    row.challengeIssuedAt &&
    typeof row.challengeAttemptsRemaining === "number"
  ) {
    result.challenge = {
      expiresAt: row.challengeExpiresAt,
      cooldownEndsAt: row.challengeCooldownEndsAt ??
        new Date(row.challengeIssuedAt.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS),
      attemptsRemaining: row.challengeAttemptsRemaining,
    };
  }
  if (row.phase === "authorized" && row.authorizationExpiresAt) {
    result.authorization = { expiresAt: row.authorizationExpiresAt };
  }
  return result;
}

export async function createOrResolveParticipantDeletionOperation(
  input: {
    participantId: ParticipantId;
    canonicalEmail: string;
    authorityVersion: number;
    initialPhase: "waiting" | "ready";
  },
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<{ outcome: "created" | "existing"; status: ParticipantDeletionStatus }> {
  const d = deps(overrides);
  // An operation-id collision is astronomically unlikely, but operation IDs
  // are permanent, so retry only that collision. A participant-active conflict
  // converges on its already-created lifecycle instead.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      return await withDeletionOwnerFence(input, d, async (session, secret) => {
        const namespaceBinding = await fenceDeletionNamespace(session);
        const active = await readSecureOperation(
          {
            participantId: input.participantId,
            phase: { $in: ACTIVE_PHASES },
          },
          session
        );
        if (active) {
          if (active.namespaceBinding !== namespaceBinding) throw new DeletionNamespaceUnavailable();
          return { outcome: "existing", status: statusProjection(active) };
        }
        const now = d.now();
        const operationId = d.generateOperationId();
        const [created] = await ParticipantDeletionOperation.create(
          [
            {
              operationId,
              namespaceBinding,
              participantId: input.participantId,
              emailBinding: deletionEmailBinding(input.canonicalEmail, secret),
              authorityVersion: input.authorityVersion,
              phase: input.initialPhase,
              readinessGeneration: input.initialPhase === "ready" ? 1 : 0,
              ...(input.initialPhase === "ready" ? { readyAt: now } : {}),
            },
          ],
          { session }
        );
        const row = await readSecureOperation({ _id: created._id }, session);
        if (!row) {
          throw new Error("created participant deletion operation is not readable");
        }
        return { outcome: "created", status: statusProjection(row) };
      });
    } catch (error) {
      if (!duplicateKey(error)) throw error;
      const winner = await withDeletionOwnerFence(input, d, async (session) => {
        const namespaceBinding = await fenceDeletionNamespace(session);
        const row = await readSecureOperation(
          {
            participantId: input.participantId,
            phase: { $in: ACTIVE_PHASES },
          },
          session
        );
        if (row && row.namespaceBinding !== namespaceBinding) throw new DeletionNamespaceUnavailable();
        return row;
      });
      if (winner) {
        return { outcome: "existing", status: statusProjection(winner) };
      }
    }
  }
  throw new Error("could not allocate a unique participant deletion operation id");
}

export async function promoteParticipantDeletionReadiness(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<boolean> {
  assertExpectedGeneration(expectedReadinessGeneration);
  const d = deps(overrides);
  return withDeletionOwnerFence(owner, d, async (session, secret) => {
    const result = await ParticipantDeletionOperation.updateOne(
      {
        ...ownerFilter(owner, secret),
        phase: "waiting",
        readinessGeneration: expectedReadinessGeneration,
      },
      {
        $set: { phase: "ready", readyAt: d.now() },
        $inc: { readinessGeneration: 1 },
        $unset: clearLiveSecurityMaterial(),
      },
      { session }
    ).exec();
    return result.modifiedCount === 1;
  });
}

export async function demoteParticipantDeletionReadiness(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<boolean> {
  assertExpectedGeneration(expectedReadinessGeneration);
  const d = deps(overrides);
  return withDeletionOwnerFence(owner, d, async (session, secret) => {
    const result = await ParticipantDeletionOperation.updateOne(
      {
        ...ownerFilter(owner, secret),
        phase: { $in: ["ready", "challengeIssued", "authorized"] },
        readinessGeneration: expectedReadinessGeneration,
      },
      {
        $set: { phase: "waiting" },
        $unset: clearLiveSecurityMaterial(),
      },
      { session }
    ).exec();
    return result.modifiedCount === 1;
  });
}

export async function expireParticipantDeletionChallenge(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<boolean> {
  assertExpectedGeneration(expectedReadinessGeneration);
  const d = deps(overrides);
  return withDeletionOwnerFence(owner, d, async (session, secret) => {
    const now = d.now();
    const result = await ParticipantDeletionOperation.updateOne(
      {
        ...ownerFilter(owner, secret),
        phase: "challengeIssued",
        readinessGeneration: expectedReadinessGeneration,
        challengeExpiresAt: { $lte: now },
      },
      { $set: { phase: "ready", readyAt: now }, $unset: clearLiveSecurityMaterial() },
      { session }
    ).exec();
    return result.modifiedCount === 1;
  });
}

export async function expireParticipantDeletionAuthorization(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<boolean> {
  assertExpectedGeneration(expectedReadinessGeneration);
  const d = deps(overrides);
  return withDeletionOwnerFence(owner, d, async (session, secret) => {
    const now = d.now();
    const result = await ParticipantDeletionOperation.updateOne(
      {
        ...ownerFilter(owner, secret),
        phase: "authorized",
        readinessGeneration: expectedReadinessGeneration,
        authorizationExpiresAt: { $lte: now },
      },
      { $set: { phase: "ready", readyAt: now }, $unset: clearLiveSecurityMaterial() },
      { session }
    ).exec();
    return result.modifiedCount === 1;
  });
}

export type IssueParticipantDeletionChallengeResult =
  | { outcome: "issued"; code: string; status: ParticipantDeletionStatus }
  | { outcome: "cooldown" | "notReady" | "stale" | "emailUnavailable"; status: ParticipantDeletionStatus };

type InternalIssueResult =
  | {
      outcome: "issued";
      code: string;
      digest: string;
      challengeGeneration: number;
      status: ParticipantDeletionStatus;
    }
  | { outcome: "cooldown" | "notReady" | "stale"; status: ParticipantDeletionStatus };

/**
 * Writes the challenge, then delivers it, mirroring
 * `participantVerification.ts`'s `issueParticipantVerificationChallenge`:
 * the write commits first (its own transaction, below), the email is sent
 * only after that commit, and a failed send is compensated by a second,
 * separately fenced write that reverts *exactly this attempt's* challenge —
 * matched on its own digest and challenge generation only, so it can never
 * touch a newer reissue or a since-redeemed challenge. The database never
 * holds a live, unexpired challenge the participant could not have received.
 */
export async function issueParticipantDeletionChallenge(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<IssueParticipantDeletionChallengeResult> {
  assertExpectedGeneration(expectedReadinessGeneration);
  const d = deps(overrides);
  const written = await issueParticipantDeletionChallengeTransaction(
    owner,
    expectedReadinessGeneration,
    d
  );
  if (written.outcome !== "issued") return written;

  try {
    await d.sendChallengeEmail(owner.canonicalEmail, written.code);
  } catch {
    await withDeletionOwnerFence(owner, d, async (session, secret) => {
      await ParticipantDeletionOperation.updateOne(
        {
          ...ownerFilter(owner, secret),
          phase: "challengeIssued",
          challengeGeneration: written.challengeGeneration,
          challengeDigest: written.digest,
        },
        {
          $set: { phase: "ready", readyAt: d.now() },
          $unset: clearLiveSecurityMaterial(),
        },
        { session }
      ).exec();
    }).catch(() => {
      // Best effort, same philosophy as the ordinary verification precedent:
      // deliberately no operation id, email, digest, or error detail here.
      console.error(
        "[participant] Deletion challenge cleanup outcome is unknown after a failed send"
      );
    });
    const current = await readParticipantDeletionStatus(owner, d);
    if (!current) {
      throw new Error("participant deletion operation disappeared after a failed challenge send");
    }
    return { outcome: "emailUnavailable", status: current };
  }
  return { outcome: "issued", code: written.code, status: written.status };
}

async function issueParticipantDeletionChallengeTransaction(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  d: ParticipantDeletionDependencies
): Promise<InternalIssueResult> {
  return withDeletionOwnerFence(owner, d, async (session, secret) => {
    const filter = ownerFilter(owner, secret);
    let initial = await readSecureOperation(filter, session);
    if (!initial) {
      throw new Error("participant deletion operation was not found for its owner binding");
    }
    if (initial.readinessGeneration !== expectedReadinessGeneration) {
      return { outcome: "stale", status: statusProjection(initial) };
    }
    const now = d.now();
    if (
      initial.phase === "challengeIssued" &&
      initial.challengeExpiresAt &&
      initial.challengeExpiresAt <= now
    ) {
      await ParticipantDeletionOperation.updateOne(
        {
          ...filter,
          phase: "challengeIssued",
          readinessGeneration: expectedReadinessGeneration,
          challengeGeneration: initial.challengeGeneration,
          challengeExpiresAt: { $lte: now },
        },
        {
          $set: { phase: "ready", readyAt: now },
          $unset: clearLiveSecurityMaterial(),
        },
        { session }
      ).exec();
      initial = await readSecureOperation(filter, session);
      if (!initial) throw new Error("participant deletion operation disappeared");
    }
    if (initial.phase !== "ready" && initial.phase !== "challengeIssued") {
      return { outcome: "notReady", status: statusProjection(initial) };
    }
    if (initial.challengeCooldownEndsAt && initial.challengeCooldownEndsAt > now) {
      return { outcome: "cooldown", status: statusProjection(initial) };
    }
    const nextChallengeGeneration = initial.challengeGeneration + 1;
    const code = d.generateCode();
    if (!isValidDeletionChallengeCode(code)) {
      throw new Error("deletion challenge generator returned an invalid code");
    }
    const digest = digestDeletionChallenge(
      {
        ...challengeBinding(initial),
        challengeGeneration: nextChallengeGeneration,
      },
      code,
      secret
    );
    const result = await ParticipantDeletionOperation.updateOne(
      {
        ...filter,
        phase: initial.phase,
        readinessGeneration: expectedReadinessGeneration,
        challengeGeneration: initial.challengeGeneration,
        $or: [
          { challengeCooldownEndsAt: { $exists: false } },
          { challengeCooldownEndsAt: { $lte: now } },
        ],
      },
      {
        $set: {
          phase: "challengeIssued",
          challengeDigest: digest,
          challengeIssuedAt: now,
          challengeCooldownEndsAt: new Date(
            now.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS
          ),
          challengeExpiresAt: new Date(
            now.getTime() + DELETION_CHALLENGE_LIFETIME_MS
          ),
          challengeAttemptsRemaining: DELETION_CHALLENGE_MAXIMUM_ATTEMPTS,
        },
        $inc: { challengeGeneration: 1 },
        $unset: { authorizedAt: "", authorizationExpiresAt: "" },
      },
      { session }
    ).exec();
    if (result.modifiedCount !== 1) {
      const current = await readSecureOperation(filter, session);
      if (!current) throw new Error("participant deletion operation disappeared");
      return {
        outcome:
          current.readinessGeneration === expectedReadinessGeneration &&
          (current.phase === "challengeIssued" ||
            (current.phase === "ready" &&
              !!current.challengeCooldownEndsAt &&
              current.challengeCooldownEndsAt > now))
            ? "cooldown"
            : "stale",
        status: statusProjection(current),
      };
    }
    const updated = await readSecureOperation(filter, session);
    if (!updated) {
      throw new Error("issued participant deletion challenge is not readable");
    }
    return {
      outcome: "issued",
      code,
      digest,
      challengeGeneration: nextChallengeGeneration,
      status: statusProjection(updated),
    };
  });
}

export type RedeemParticipantDeletionChallengeResult =
  | {
      outcome: "authorized";
      status: ParticipantDeletionStatus;
      recoveryCapability: string;
    }
  | { outcome: "invalidCode" | "expired" | "notRedeemable" | "stale"; status: ParticipantDeletionStatus };

export async function redeemParticipantDeletionChallenge(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  code: unknown,
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<RedeemParticipantDeletionChallengeResult> {
  assertExpectedGeneration(expectedReadinessGeneration);
  const d = deps(overrides);
  return withDeletionOwnerFence(owner, d, async (session, secret) => {
    const filter = ownerFilter(owner, secret);
    const current = await readSecureOperation(filter, session);
    if (!current) {
      throw new Error("participant deletion operation was not found for its owner binding");
    }
    if (current.readinessGeneration !== expectedReadinessGeneration) {
      return { outcome: "stale", status: statusProjection(current) };
    }
    if (current.phase !== "challengeIssued") {
      return { outcome: "notRedeemable", status: statusProjection(current) };
    }
    const now = d.now();
    if (!current.challengeExpiresAt || current.challengeExpiresAt <= now) {
      await ParticipantDeletionOperation.updateOne(
        {
          ...filter,
          phase: "challengeIssued",
          readinessGeneration: expectedReadinessGeneration,
          challengeGeneration: current.challengeGeneration,
          challengeExpiresAt: { $lte: now },
        },
        {
          $set: { phase: "ready", readyAt: now },
          $unset: clearLiveSecurityMaterial(),
        },
        { session }
      ).exec();
      const afterExpiry = await readSecureOperation(filter, session);
      if (!afterExpiry) throw new Error("participant deletion operation disappeared");
      return { outcome: "expired", status: statusProjection(afterExpiry) };
    }
    if (!isValidDeletionChallengeCode(code)) {
      return { outcome: "invalidCode", status: statusProjection(current) };
    }
    const digest = digestDeletionChallenge(challengeBinding(current), code, secret);
    const recoveryCapability = d.generateRecoveryCapability();
    const recoveryCapabilityDigest =
      deletionRecoveryCapabilityDigest(recoveryCapability);
    const authorized = await ParticipantDeletionOperation.updateOne(
      {
        ...filter,
        phase: "challengeIssued",
        readinessGeneration: expectedReadinessGeneration,
        challengeGeneration: current.challengeGeneration,
        challengeDigest: digest,
        challengeExpiresAt: { $gt: now },
      },
      {
        $set: {
          phase: "authorized",
          authorizedAt: now,
          authorizationExpiresAt: new Date(
            now.getTime() + DELETION_AUTHORIZATION_LIFETIME_MS
          ),
          recoveryCapabilityDigest,
        },
        $unset: {
          challengeDigest: "",
          challengeIssuedAt: "",
          challengeExpiresAt: "",
          challengeAttemptsRemaining: "",
        },
      },
      { session }
    ).exec();
    if (authorized.modifiedCount === 1) {
      const row = await readSecureOperation(filter, session);
      if (!row) {
        throw new Error("authorized participant deletion operation is not readable");
      }
      return {
        outcome: "authorized",
        status: statusProjection(row),
        recoveryCapability,
      };
    }

    const nonmatching = { $ne: digest };
    const wrong = await ParticipantDeletionOperation.updateOne(
      {
        ...filter,
        phase: "challengeIssued",
        readinessGeneration: expectedReadinessGeneration,
        challengeGeneration: current.challengeGeneration,
        challengeDigest: nonmatching,
        challengeExpiresAt: { $gt: now },
        challengeAttemptsRemaining: { $gt: 1 },
      },
      { $inc: { challengeAttemptsRemaining: -1 } },
      { session }
    ).exec();
    if (wrong.modifiedCount !== 1) {
      await ParticipantDeletionOperation.updateOne(
        {
          ...filter,
          phase: "challengeIssued",
          readinessGeneration: expectedReadinessGeneration,
          challengeGeneration: current.challengeGeneration,
          challengeDigest: nonmatching,
          challengeExpiresAt: { $gt: now },
          challengeAttemptsRemaining: 1,
        },
        {
          $set: { phase: "ready", readyAt: now },
          $unset: clearLiveSecurityMaterial(),
        },
        { session }
      ).exec();
    }
    const row = await readSecureOperation(filter, session);
    if (!row) throw new Error("participant deletion operation disappeared");
    if (row.phase === "challengeIssued" || row.phase === "ready") {
      return { outcome: "invalidCode", status: statusProjection(row) };
    }
    return { outcome: "stale", status: statusProjection(row) };
  });
}

export async function cancelParticipantDeletionOperation(
  owner: DeletionOwner,
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<{ outcome: "canceled" | "alreadyCanceled" | "terminal"; status: ParticipantDeletionStatus }> {
  const d = deps(overrides);
  return withDeletionOwnerFence(owner, d, async (session, secret) => {
    const filter = ownerFilter(owner, secret);
    const result = await ParticipantDeletionOperation.updateOne(
      { ...filter, phase: { $in: ACTIVE_PHASES } },
      {
        $set: { phase: "canceled", canceledAt: d.now() },
        $unset: {
          ...clearLiveSecurityMaterial(),
          challengeCooldownEndsAt: "",
        },
      },
      { session }
    ).exec();
    const row = await readSecureOperation(filter, session);
    if (!row) {
      throw new Error("participant deletion operation was not found for its owner binding");
    }
    if (result.modifiedCount === 1) {
      return { outcome: "canceled", status: statusProjection(row) };
    }
    return {
      outcome: row.phase === "canceled" ? "alreadyCanceled" : "terminal",
      status: statusProjection(row),
    };
  });
}

/** Owner-bound status reconciliation. It may normalize a deadline down to
 * ready but cannot promote waiting or reveal private binding/security data. */
export async function readParticipantDeletionStatus(
  owner: DeletionOwner,
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<ParticipantDeletionStatus | null> {
  const d = deps(overrides);
  const filter = ownerFilter(owner, d.readSecret());
  let row = await readSecureOperation(filter);
  if (!row) return null;
  if (row.phase === "challengeIssued" && row.challengeExpiresAt && row.challengeExpiresAt <= d.now()) {
    await expireParticipantDeletionChallenge(owner, row.readinessGeneration, d);
    row = await readSecureOperation(filter);
  } else if (row.phase === "authorized" && row.authorizationExpiresAt && row.authorizationExpiresAt <= d.now()) {
    await expireParticipantDeletionAuthorization(owner, row.readinessGeneration, d);
    row = await readSecureOperation(filter);
  }
  return row ? statusProjection(row) : null;
}
