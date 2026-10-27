import type { ClientSession } from "mongoose";
import {
  ReportCountBinding,
  ReportSubmissionLedger,
  type IReportSubmissionLedger,
} from "../models/moderation.js";
import {
  REPORT_CAP_WINDOW_MS,
  REPORT_MINT_SKEW_TOLERANCE_MS,
  REPORT_PER_REQUEST_CAP,
  REPORT_SUBMISSION_WINDOW_MS,
  REPORT_VOLUME_CAP,
} from "./moderationConstants.js";
import {
  ModerationConflictError,
  SafetyIdentityUnavailableError,
  findMismatchedKeyIds,
} from "./safetyIdentity.js";
import {
  deriveKeyedDigest,
  deriveKeyedDigests,
  type SafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";

/**
 * The private report-submission ledger and bounded counting bindings
 * (W4-U1.2, "Durable report-submission recovery" and "Report abuse controls").
 *
 * The ledger sits **outside the case record**: a row carries keyed digests, an
 * outcome and its server creation time, and no case reference, while a case
 * carries no ledger reference, so no field or index joins a reporter to a case.
 * Reconciliation is bound to one exact operation and never creates authority.
 *
 * ## Windows
 *
 * A submission window W (24 hours from the client-minted time embedded in the
 * operation identity) is strictly shorter than ledger retention R (48 hours,
 * enforced by the TTL index on `createdAt`). Within W a created row always
 * exists. At or beyond W, creation and terminalization are refused as
 * `expired`, so TTL deletion can never turn "created" into "absent" and a late
 * reconcile can never fabricate "not sent". The mint time is client-controlled,
 * so a mint more than 5 minutes in the future is a definitive validation
 * refusal, which keeps W + skew < R true.
 *
 * The report endpoint and reconcile route compose these operations with case
 * creation in the same transaction.
 */

/**
 * `rp1.<13-digit mint time in ms>.<22-64 base64url characters of entropy>`.
 * The embedded mint time is what bounds the window; the entropy makes the
 * identity unguessable. Payload similarity, timing and context are never
 * identity.
 */
export const REPORT_OPERATION_ID_PATTERN = /^rp1\.(\d{13})\.([A-Za-z0-9_-]{22,64})$/;

export function parseReportOperationId(value: unknown): { mintedAt: Date } | null {
  if (typeof value !== "string") return null;
  const match = REPORT_OPERATION_ID_PATTERN.exec(value);
  if (!match) return null;
  return { mintedAt: new Date(Number(match[1])) };
}

/** Read-only replay lookup performed before current interaction authorization. */
export async function lookupReportOperation(
  session: ClientSession,
  input: { keyring: SafetyIdentityKeyring | null; operationId: string; participantId: string },
  now: Date
): Promise<LookupReportOperationResult> {
  const keyring = await assertLedgerKeysAvailable(input.keyring, session);
  const parsed = parseReportOperationId(input.operationId);
  if (!parsed) return { status: "refused" };
  const window = classifyOperationWindow(parsed.mintedAt, now);
  if (window === "future") return { status: "future" };
  const existing = await findLedgerRow(keyring, input.operationId, session);
  if (existing) {
    const sameParticipant =
      participantBindingOf(keyring, existing.keyId, input.participantId) ===
      existing.participantBinding;
    if (!sameParticipant) return { status: "refused" };
    return { status: existing.outcome === "created" ? "created" : "no-create" };
  }
  return { status: window === "expired" ? "expired" : "absent" };
}

export type OperationWindow = "within" | "expired" | "future";

export function classifyOperationWindow(mintedAt: Date, now: Date): OperationWindow {
  if (mintedAt.getTime() > now.getTime() + REPORT_MINT_SKEW_TOLERANCE_MS) return "future";
  if (now.getTime() - mintedAt.getTime() >= REPORT_SUBMISSION_WINDOW_MS) return "expired";
  return "within";
}

export class ReportLedgerConflictError extends ModerationConflictError {
  constructor() {
    super("A concurrent transaction committed this report operation.");
    this.name = "ReportLedgerConflictError";
  }
}

async function assertLedgerKeysAvailable(
  keyring: SafetyIdentityKeyring | null,
  session: ClientSession
): Promise<SafetyIdentityKeyring> {
  if (!keyring) throw new SafetyIdentityUnavailableError();
  // A key id reused with different material makes every digest minted under the
  // original material unfindable, so a replay would read as "new".
  if ((await findMismatchedKeyIds(keyring, true)).length > 0) {
    throw new SafetyIdentityUnavailableError();
  }
  // A row whose creating key is no longer configured cannot have its
  // participant binding re-derived, and a replay could read as "new". Refuse
  // instead of duplicating.
  const stranded = await ReportSubmissionLedger.exists({
    keyId: { $nin: [...keyring.keys.keys()] },
  }).session(session);
  if (stranded) throw new SafetyIdentityUnavailableError();
  return keyring;
}

/**
 * The operation digest under every configured key. Stored whole and indexed
 * unique-multikey, so two instances with different current keys cannot both
 * create the same logical operation.
 */
function operationDigestsOf(keyring: SafetyIdentityKeyring, operationId: string): string[] {
  return deriveKeyedDigests(keyring, "report-operation", operationId).map((entry) => entry.digest);
}

function participantBindingOf(
  keyring: SafetyIdentityKeyring,
  keyId: string,
  participantId: string
): string {
  return deriveKeyedDigest(keyring, keyId, "report-participant", participantId);
}

async function findLedgerRow(
  keyring: SafetyIdentityKeyring,
  operationId: string,
  session: ClientSession
): Promise<IReportSubmissionLedger | null> {
  const digests = deriveKeyedDigests(keyring, "report-operation", operationId);
  return ReportSubmissionLedger.findOne(
    { operationDigests: { $in: digests.map((entry) => entry.digest) } },
    undefined,
    { session }
  )
    .lean<IReportSubmissionLedger>()
    .exec();
}

export type ReportCapRefusal = "volume" | "request";

/**
 * Best-effort rolling-window counting. A concurrent burst can exceed a cap by a
 * small margin; that is never a reason to drop or merge an accepted report.
 */
export async function checkReportCaps(
  session: ClientSession,
  keyring: SafetyIdentityKeyring,
  participantId: string,
  requestId: string,
  now: Date
): Promise<{ allowed: true } | { allowed: false; cap: ReportCapRefusal }> {
  const since = new Date(now.getTime() - REPORT_CAP_WINDOW_MS);
  const reporterBindings = deriveKeyedDigests(keyring, "report-participant", participantId).map(
    (entry) => entry.digest
  );
  const requestBindings = deriveKeyedDigests(
    keyring,
    "report-request",
    `${participantId}:${requestId}`
  ).map((entry) => entry.digest);

  const [volume, perRequest] = await Promise.all([
    ReportCountBinding.countDocuments(
      { reporterBinding: { $in: reporterBindings }, createdAt: { $gt: since } },
      { session }
    ),
    ReportCountBinding.countDocuments(
      { requestBinding: { $in: requestBindings }, createdAt: { $gt: since } },
      { session }
    ),
  ]);
  if (volume >= REPORT_VOLUME_CAP) return { allowed: false, cap: "volume" };
  if (perRequest >= REPORT_PER_REQUEST_CAP) return { allowed: false, cap: "request" };
  return { allowed: true };
}

export type CreateLedgerResult =
  /** First write of this operation: the caller commits the report with it. */
  | { status: "created" }
  /** The same operation by the same participant already created a report. */
  | { status: "replay" }
  /** A terminal no-create already won: the original must not commit. */
  | { status: "terminal-no-create" }
  /** Another participant's operation, or a value not usable as an operation. */
  | { status: "refused" }
  | { status: "expired" }
  | { status: "future" }
  | { status: "handoff-consumed" }
  | { status: "capped"; cap: ReportCapRefusal };

export type LookupReportOperationResult =
  | { status: "absent" }
  | { status: "created" }
  | { status: "no-create" }
  | { status: "refused" }
  | { status: "expired" }
  | { status: "future" };

export interface CreateLedgerInput {
  keyring: SafetyIdentityKeyring | null;
  operationId: string;
  participantId: string;
  requestId: string;
  /** The post-Block handoff value, when the submission presents one. */
  handoffValue?: string;
}

/**
 * The submission-ledger step of report creation, run in the **same transaction**
 * as the case it accompanies. Order matters: an
 * existing row answers first (so a replay returns the original even after a cap
 * is reached), then handoff consumption, then the caps, then the insert. A
 * definitive no-write outcome (`expired`, `future`, `capped`, `refused`,
 * `handoff-consumed`) writes nothing and so does not consume a handoff.
 */
export async function createReportLedgerRow(
  session: ClientSession,
  input: CreateLedgerInput,
  now: Date
): Promise<CreateLedgerResult> {
  const keyring = await assertLedgerKeysAvailable(input.keyring, session);
  const parsed = parseReportOperationId(input.operationId);
  if (!parsed) return { status: "refused" };

  const window = classifyOperationWindow(parsed.mintedAt, now);
  if (window === "future") return { status: "future" };

  const existing = await findLedgerRow(keyring, input.operationId, session);
  if (existing) {
    const sameParticipant =
      participantBindingOf(keyring, existing.keyId, input.participantId) ===
      existing.participantBinding;
    if (!sameParticipant) return { status: "refused" };
    return { status: existing.outcome === "created" ? "replay" : "terminal-no-create" };
  }
  if (window === "expired") return { status: "expired" };

  const current = keyring.currentKeyId;
  let handoffDigests: string[] | undefined;
  if (input.handoffValue !== undefined) {
    handoffDigests = deriveKeyedDigests(keyring, "report-handoff", input.handoffValue).map(
      (entry) => entry.digest
    );
    const consumed = await ReportSubmissionLedger.exists({
      handoffDigests: { $in: handoffDigests },
    }).session(session);
    if (consumed) return { status: "handoff-consumed" };
  }

  const caps = await checkReportCaps(session, keyring, input.participantId, input.requestId, now);
  if (!caps.allowed) return { status: "capped", cap: caps.cap };

  try {
    await ReportSubmissionLedger.create(
      [
        {
          keyId: current,
          operationDigests: operationDigestsOf(keyring, input.operationId),
          participantBinding: participantBindingOf(keyring, current, input.participantId),
          handoffDigests,
          outcome: "created",
          createdAt: now,
        },
      ],
      { session }
    );
    await ReportCountBinding.create(
      [
        {
          keyId: current,
          reporterBinding: participantBindingOf(keyring, current, input.participantId),
          requestBinding: deriveKeyedDigest(
            keyring,
            current,
            "report-request",
            `${input.participantId}:${input.requestId}`
          ),
          createdAt: now,
        },
      ],
      { session }
    );
  } catch (error) {
    if ((error as { code?: number }).code === 11000) throw new ReportLedgerConflictError();
    throw error;
  }
  return { status: "created" };
}

export type ReconcileLedgerResult =
  | { status: "created" }
  | { status: "no-create" }
  | { status: "refused" }
  | { status: "expired" };

/**
 * Reconciles exactly one operation, after participant authority. It returns the
 * original result when a row exists; otherwise, within W, it **atomically
 * establishes terminal no-create** (so a later-arriving original cannot
 * commit); beyond W with no row it answers `expired`, never "not sent". It
 * never creates a report and never creates new authority.
 */
export async function reconcileReportOperation(
  session: ClientSession,
  input: { keyring: SafetyIdentityKeyring | null; operationId: string; participantId: string },
  now: Date
): Promise<ReconcileLedgerResult> {
  const keyring = await assertLedgerKeysAvailable(input.keyring, session);
  const parsed = parseReportOperationId(input.operationId);
  if (!parsed) return { status: "refused" };
  const window = classifyOperationWindow(parsed.mintedAt, now);
  if (window === "future") return { status: "refused" };

  const existing = await findLedgerRow(keyring, input.operationId, session);
  if (existing) {
    const sameParticipant =
      participantBindingOf(keyring, existing.keyId, input.participantId) ===
      existing.participantBinding;
    if (!sameParticipant) return { status: "refused" };
    return { status: existing.outcome === "created" ? "created" : "no-create" };
  }
  if (window === "expired") return { status: "expired" };

  const current = keyring.currentKeyId;
  try {
    await ReportSubmissionLedger.create(
      [
        {
          keyId: current,
          operationDigests: operationDigestsOf(keyring, input.operationId),
          participantBinding: participantBindingOf(keyring, current, input.participantId),
          outcome: "no-create",
          createdAt: now,
        },
      ],
      { session }
    );
  } catch (error) {
    if ((error as { code?: number }).code === 11000) throw new ReportLedgerConflictError();
    throw error;
  }
  return { status: "no-create" };
}
