import type { Express, NextFunction, Request, Response } from "express";
import express from "express";
import mongoose from "mongoose";
import { z } from "zod";
import { Participant, Request as MealRequest, RequestParticipation } from "../models/db.js";
import {
  ModerationReport as ReportModel,
  type IReportRequestSnapshot,
} from "../models/moderation.js";
import {
  createReportLedgerRow,
  lookupReportOperation,
  reconcileReportOperation,
} from "./reportSubmissionLedger.js";
import { buildReportRequestSnapshot } from "./reportRequestSnapshot.js";
import { REPORT_REASONS } from "./moderationConstants.js";
import { isParticipantPairFenced } from "./participantBlocks.js";
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { isEffectivelyAvailable } from "./requestAvailability.js";
import { isSafetyIdentityOperable, runModerationTransaction } from "./safetyIdentity.js";
import { readModeratorConfig } from "./moderatorSecurity.js";
import { readSafetyIdentityKeyring } from "./safetyIdentityKeyring.js";
import { isValidReportAuthorization } from "./reportAuthorization.js";
import { buildReportAlertContent, sendReportAlert } from "./reportAlerts.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { recordReportCase } from "./moderationRecords.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  captureMessagingReportContextInSession,
  ReportMessageCaptureDeniedError,
} from "./messagingLifecycle.js";

export const REPORT_SUBMISSION_ROUTE_PATH = "/api/request/:id/report";
export const REPORT_OPERATION_RECONCILE_ROUTE_PATH =
  "/api/participant/report-operations/:operationId/reconcile";
export const PARTICIPANT_RESTRICTION_ROUTE_PATH = "/api/participant/restriction";

const reportBodySchema = z
  .object({
    operationId: z.string().regex(/^rp1\.\d{13}\.[A-Za-z0-9_-]{22,64}$/),
    reason: z.enum(REPORT_REASONS),
    explanation: z.string().max(250).optional(),
    reportAuthorization: z.string().min(1).max(500).optional(),
  })
  .strict()
  .refine((body) => body.reason !== "Other concern" || (body.explanation?.trim().length ?? 0) > 0);

const REPORT_UNAVAILABLE_MESSAGE = "Reporting is temporarily unavailable.";
const REPORT_NOT_CONFIRMED_MESSAGE = "Report not confirmed.";
const REPORTING_UNAVAILABLE_CODE = "REPORTING_UNAVAILABLE";

interface ReportableRequest {
  _id: mongoose.Types.ObjectId;
  status: "open" | "claimed" | "placed";
  requesterParticipantId?: mongoose.Types.ObjectId;
  helperParticipantId?: mongoose.Types.ObjectId;
  claimExpiresAt?: Date | null;
  expiresAt?: Date | null;
  deleteAt?: Date | null;
  visibleFrom?: Date | null;
  externalOrderAffirmed?: boolean;
  moderationUnavailable?: boolean;
  reservationLapseHold?: boolean;
  requesterPickupConfirmedAt?: Date;
  vendor?: string;
  food?: string;
  pickupWindowText?: string;
  menuPath?: string;
  mealSwipes?: number;
  mealItems?: Array<{ name?: string; details?: string }>;
  orderDetails?: string;
  estimatedDiningDollarsCents?: number;
}

type ReportAuthority = {
  request: ReportableRequest;
  reportedParticipantId: mongoose.Types.ObjectId;
  reportedRole: "requester" | "helper";
  viaHandoff: boolean;
};

function requestIsRetained(request: ReportableRequest, now: Date): boolean {
  return !request.deleteAt || request.deleteAt.getTime() > now.getTime();
}

function requestHasActivePickupReportWindow(request: ReportableRequest, now: Date): boolean {
  return (
    MealRequest.schema.path("requesterPickupConfirmedAt") !== undefined &&
    request.status === "placed" &&
    Boolean(request.helperParticipantId) &&
    requestIsRetained(request, now) &&
    request.requesterPickupConfirmedAt === undefined
  );
}

// The requester's reservation-start window: a live reservation with a bound
// helper. Expiry never clears the binding, so a lapsed reservation is excluded.
function requestHasLiveReservation(request: ReportableRequest, now: Date): boolean {
  return (
    request.status === "claimed" &&
    Boolean(request.helperParticipantId) &&
    Boolean(request.claimExpiresAt && request.claimExpiresAt.getTime() > now.getTime()) &&
    Boolean(request.expiresAt && request.expiresAt.getTime() > now.getTime()) &&
    requestIsRetained(request, now)
  );
}

function requesterMayReportHelper(request: ReportableRequest, now: Date): boolean {
  return requestHasLiveReservation(request, now) || requestHasActivePickupReportWindow(request, now);
}

// A report-only handoff never outlives the accepted reporting cutoff: a
// confirmed pickup (or a retired request) denies it even within its ten minutes.
function handoffWindowOpen(request: ReportableRequest): boolean {
  return (
    MealRequest.schema.path("requesterPickupConfirmedAt") !== undefined &&
    request.requesterPickupConfirmedAt == null
  );
}

// The requester's handoff token is MAC-bound to the exact helper blocked, so it
// is resolved against the helpers who ever held this request (the durable
// participation set), never the live binding: a release, replacement or lapse
// cannot redirect it to someone else, and a replacement's token does not match.
async function resolveHandoffHelper(
  session: mongoose.ClientSession,
  requestObjectId: mongoose.Types.ObjectId,
  requester: mongoose.Types.ObjectId,
  handoff: string,
  keyring: ReturnType<typeof readSafetyIdentityKeyring>,
  requestId: string,
  now: Date
): Promise<mongoose.Types.ObjectId | null> {
  const rows = await RequestParticipation.find({ requestId: requestObjectId })
    .select("+participantId")
    .session(session)
    .lean<Array<{ participantId: mongoose.Types.ObjectId }>>()
    .exec();
  for (const row of rows) {
    if (row.participantId.equals(requester)) continue;
    if (
      isValidReportAuthorization(
        handoff, keyring, String(requester), requestId, now, String(row.participantId)
      )
    ) {
      return row.participantId;
    }
  }
  return null;
}

async function resolveReportAuthority(
  session: mongoose.ClientSession,
  requestId: string,
  participantId: string,
  handoff: string | undefined,
  keyring: ReturnType<typeof readSafetyIdentityKeyring>,
  now: Date
): Promise<ReportAuthority | null> {
  if (!mongoose.isValidObjectId(requestId)) return null;
  const request = (await MealRequest.findById(requestId)
    .select(
      "+requesterParticipantId +helperParticipantId +moderationUnavailable +reservationLapseHold +externalOrderAffirmed +requesterPickupConfirmedAt"
    )
    .session(session)
    .lean<ReportableRequest>()
    .exec()) as ReportableRequest | null;
  if (!request || !request.requesterParticipantId || !requestIsRetained(request, now)) return null;

  const caller = new mongoose.Types.ObjectId(participantId);
  const requester = request.requesterParticipantId;
  if (requester.equals(caller)) {
    if (handoff !== undefined) {
      if (!handoffWindowOpen(request)) return null;
      const helperId = await resolveHandoffHelper(
        session, request._id, requester, handoff, keyring, requestId, now
      );
      if (!helperId) return null;
      return { request, reportedParticipantId: helperId, reportedRole: "helper", viaHandoff: true };
    }
    if (requesterMayReportHelper(request, now)) {
      return {
        request,
        reportedParticipantId: request.helperParticipantId!,
        reportedRole: "helper",
        viaHandoff: false,
      };
    }
    return null;
  }

  if (handoff !== undefined) {
    if (
      !handoffWindowOpen(request) ||
      !isValidReportAuthorization(handoff, keyring, participantId, requestId, now, String(requester))
    ) {
      return null;
    }
    return { request, reportedParticipantId: requester, reportedRole: "requester", viaHandoff: true };
  }

  // Placed helper: the same unconfirmed-pickup window as the requester's
  // (Option A), so there is no post-pickup in-app reporting.
  if (
    request.helperParticipantId?.equals(caller) === true &&
    requestHasActivePickupReportWindow(request, now)
  ) {
    return { request, reportedParticipantId: requester, reportedRole: "requester", viaHandoff: false };
  }

  const holdsReservation =
    request.status === "claimed" &&
    request.helperParticipantId?.equals(caller) === true &&
    Boolean(request.claimExpiresAt && request.claimExpiresAt.getTime() > now.getTime()) &&
    Boolean(request.expiresAt && request.expiresAt.getTime() > now.getTime());
  if (holdsReservation) {
    return { request, reportedParticipantId: requester, reportedRole: "requester", viaHandoff: false };
  }

  const available = isEffectivelyAvailable(request, now);
  if (
    !available ||
    (await isParticipantPairFenced(participantId, requester, session))
  ) {
    return null;
  }
  return { request, reportedParticipantId: requester, reportedRole: "requester", viaHandoff: false };
}

export interface ReportAlertSender {
  (recipient: string, content: { subject: string; text: string }): Promise<void>;
}

export async function submitParticipantReport(
  req: Request,
  res: Response,
  sender: ReportAlertSender = sendReportAlert
): Promise<Response> {
  res.setHeader("Cache-Control", "private, no-store");
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);

  const parsed = reportBodySchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return sendDay4Error(res, 400, "REPORT_NOT_CONFIRMED", REPORT_NOT_CONFIRMED_MESSAGE);
  }
  const now = new Date();
  const moderatorConfig = readModeratorConfig();
  let keyring: ReturnType<typeof readSafetyIdentityKeyring>;
  try {
    keyring = readSafetyIdentityKeyring();
  } catch {
    return sendDay4Error(res, 503, REPORTING_UNAVAILABLE_CODE, REPORT_UNAVAILABLE_MESSAGE);
  }

  const captureFailures = new WeakSet<object>();
  const captureReportContext = async (
    session: mongoose.ClientSession,
    input: {
      handoff: boolean;
      requestId: mongoose.Types.ObjectId;
      reporterId: mongoose.Types.ObjectId;
      reportedId: mongoose.Types.ObjectId;
    }
  ) => {
    try {
      return await captureMessagingReportContextInSession(session, input);
    } catch (error) {
      if (!(error instanceof ReportMessageCaptureDeniedError) && error !== null && typeof error === "object") {
        captureFailures.add(error);
      }
      throw error;
    }
  };
  const executeReportTransaction = (captureFailed: boolean) =>
    runModerationTransaction(async (session) => {
      const operationInput = {
        keyring,
        operationId: parsed.data.operationId,
        participantId: authority.participant.participantId,
      };
      const replay = await lookupReportOperation(session, operationInput, now);
      if (replay.status !== "absent") return { replay, report: null };
      if (
        !moderatorConfig ||
        !(await isSafetyIdentityOperable(keyring))
      ) {
        return { unavailable: true as const };
      }

      const authorized = await resolveReportAuthority(
        session,
        String(req.params.id ?? ""),
        authority.participant.participantId,
        parsed.data.reportAuthorization,
        keyring,
        now
      );
      if (!authorized) return { refused: true as const };

      const reported = await Participant.findById(authorized.reportedParticipantId)
        .select("email +safetyIdentityRef")
        .session(session)
        .lean<{ _id: mongoose.Types.ObjectId; email: string; safetyIdentityRef?: mongoose.Types.ObjectId }>()
        .exec();
      if (!reported) return { refused: true as const };

      const ledger = await createReportLedgerRow(
        session,
        {
          ...operationInput,
          requestId: String(authorized.request._id),
          handoffValue: parsed.data.reportAuthorization,
        },
        now
      );
      if (ledger.status !== "created") return { ledger, report: null };

      const snapshot = buildReportRequestSnapshot(
        authorized.request as Parameters<typeof buildReportRequestSnapshot>[0],
        authorized.reportedRole
      ) as IReportRequestSnapshot;
      // Only after the ledger row is created, so an idempotent replay never
      // consumes a lease; any later failure rolls the capture back with it.
      const messageContext = captureFailed
        ? {
            captureStatus: "incomplete" as const,
            captureReason: "capture-failed" as const,
            messages: [],
          }
        : await captureReportContext(session, {
            handoff: authorized.viaHandoff,
            requestId: authorized.request._id,
            reporterId: new mongoose.Types.ObjectId(authority.participant.participantId),
            reportedId: authorized.reportedParticipantId,
          });
      const report = await recordReportCase(session, {
        keyring,
        reportedEmail: reported.email,
        snapshot,
        reason: parsed.data.reason,
        explanation: parsed.data.explanation,
        messageContext,
      });
      await Participant.updateOne(
        { _id: reported._id },
        { $set: { safetyIdentityRef: report.identityId } },
        { session }
      ).exec();
      return {
        ledger,
        report: {
          id: report.reportId,
          ref: report.ref,
          reason: parsed.data.reason,
          createdAt: now,
        },
      };
    });

  try {
    let transactionResult: Awaited<ReturnType<typeof executeReportTransaction>>;
    try {
      transactionResult = await executeReportTransaction(false);
    } catch (error) {
      if (error === null || typeof error !== "object" || !captureFailures.has(error)) throw error;
      // The failed capture transaction has rolled back; reauthorize and persist
      // an explicitly incomplete outcome in a fresh U1.2 transaction.
      transactionResult = await executeReportTransaction(true);
    }

    if ("refused" in transactionResult) {
      return sendDay4Error(res, 404, "REQUEST_NOT_FOUND", "Request not found.");
    }
    if ("unavailable" in transactionResult) {
      return sendDay4Error(res, 503, REPORTING_UNAVAILABLE_CODE, REPORT_UNAVAILABLE_MESSAGE);
    }
    if ("replay" in transactionResult && transactionResult.replay) {
      switch (transactionResult.replay.status) {
        case "created":
          return res.json({ outcome: "reported" });
        case "no-create":
          return sendDay4Error(res, 409, "REPORT_NOT_CREATED", REPORT_NOT_CONFIRMED_MESSAGE);
        case "expired":
          return sendDay4Error(res, 410, "OPERATION_EXPIRED", REPORT_NOT_CONFIRMED_MESSAGE);
        default:
          return sendDay4Error(res, 404, "REQUEST_NOT_FOUND", "Request not found.");
      }
    }
    if ("ledger" in transactionResult && transactionResult.ledger.status !== "created") {
      const ledger = transactionResult.ledger;
      if (ledger.status === "capped") {
        return sendDay4Error(res, 429, "REPORT_NOT_CONFIRMED", REPORT_NOT_CONFIRMED_MESSAGE);
      }
      if (ledger.status === "expired") {
        return sendDay4Error(res, 410, "OPERATION_EXPIRED", REPORT_NOT_CONFIRMED_MESSAGE);
      }
      if (ledger.status === "replay") return res.json({ outcome: "reported" });
      return sendDay4Error(res, 404, "REQUEST_NOT_FOUND", "Request not found.");
    }

    const report = transactionResult.report;
    if (report) {
      if (!moderatorConfig) {
        return sendDay4Error(res, 503, REPORTING_UNAVAILABLE_CODE, REPORT_UNAVAILABLE_MESSAGE);
      }
      const alertContent = buildReportAlertContent(report.ref, report.reason, report.createdAt);
      let alertStatus: "submitted" | "failed" = "failed";
      try {
        await sender(moderatorConfig.alertRecipient, alertContent);
        alertStatus = "submitted";
      } catch {
        alertStatus = "failed";
      }
      await ReportModel.updateOne(
        { _id: report.id },
        { $set: { alertStatus, alertAttemptedAt: new Date() } }
      ).exec();
    }
    return res.json({ outcome: "reported" });
  } catch (error) {
    if (error instanceof ReportMessageCaptureDeniedError) {
      return sendDay4Error(res, 404, "REQUEST_NOT_FOUND", "Request not found.");
    }
    console.error("[report] Submission could not be confirmed");
    return sendDay4Error(res, 503, "INTERNAL_FAILURE", REPORT_NOT_CONFIRMED_MESSAGE);
  }
}

export async function reconcileParticipantReportOperation(
  req: Request,
  res: Response
): Promise<Response> {
  res.setHeader("Cache-Control", "private, no-store");
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);
  const operationId = String(req.params.operationId ?? "");
  try {
    const keyring = readSafetyIdentityKeyring();
    const result = await runModerationTransaction((session) =>
      reconcileReportOperation(
        session,
        {
          keyring,
          operationId,
          participantId: authority.participant.participantId,
        },
        new Date()
      )
    );
    switch (result.status) {
      case "created":
        return res.json({ outcome: "created" });
      case "no-create":
        return res.json({ outcome: "no-create" });
      case "expired":
        return sendDay4Error(res, 410, "OPERATION_EXPIRED", "Report not confirmed.");
      case "refused":
        return res.json({ outcome: "refused" });
    }
  } catch {
    return sendDay4Error(res, 503, REPORTING_UNAVAILABLE_CODE, REPORT_UNAVAILABLE_MESSAGE);
  }
}

export async function getParticipantRestriction(req: Request, res: Response): Promise<Response> {
  res.setHeader("Cache-Control", "private, no-store");
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);
  try {
    const participant = await Participant.findById(authority.participant.participantId)
      .select("+suspended")
      .lean<{ suspended?: boolean }>()
      .exec();
    if (!participant) return sendDay4Error(res, 401, "PARTICIPANT_AUTHORITY_INVALID", "Verify your NYU email again to continue.");
    return res.json(participant.suspended === true ? { restricted: true } : {});
  } catch {
    return sendDay4Error(res, 503, "PARTICIPANT_VERIFICATION_UNAVAILABLE", "We couldn’t check your NYU verification right now. Please try again in a moment.");
  }
}

export const reportBodyParser = express.json({ limit: "8kb", strict: true });
export const reportReconcileBodyParser = express.json({ limit: "1kb", strict: true });
export const reportRateLimiter = createDay4MutationRateLimiter(10);
export const reportReconcileRateLimiter = createDay4MutationRateLimiter(10);

export function participantReportParserError(
  error: unknown,
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  const type =
    error && typeof error === "object" && "type" in error
      ? (error as { type?: unknown }).type
      : undefined;
  if (
    type === "entity.parse.failed" ||
    type === "entity.too.large" ||
    type === "encoding.unsupported" ||
    type === "charset.unsupported" ||
    type === "request.size.invalid" ||
    type === "request.aborted"
  ) {
    res.setHeader("Cache-Control", "private, no-store");
    sendDay4Error(res, 400, "REPORT_NOT_CONFIRMED", REPORT_NOT_CONFIRMED_MESSAGE);
    return;
  }
  next(error);
}

export function registerReportRoutes(
  app: Express,
  sender: ReportAlertSender = sendReportAlert
): void {
  app.post(
    REPORT_SUBMISSION_ROUTE_PATH,
    reportRateLimiter,
    reportBodyParser,
    (req: Request, res: Response) => submitParticipantReport(req, res, sender),
    participantReportParserError
  );
  app.post(
    REPORT_OPERATION_RECONCILE_ROUTE_PATH,
    reportReconcileRateLimiter,
    reportReconcileBodyParser,
    reconcileParticipantReportOperation,
    participantReportParserError
  );
  app.get(PARTICIPANT_RESTRICTION_ROUTE_PATH, getParticipantRestriction);
}
