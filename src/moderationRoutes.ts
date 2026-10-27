import type { Express, NextFunction, Request, Response } from "express";
import express from "express";
import mongoose from "mongoose";
import { z } from "zod";
import {
  Participant,
  Request as MealRequest,
} from "../models/db.js";
import {
  ModerationReport,
  ReportEvidence,
  RetentionHold,
  SafetyIdentity,
  Suspension,
  SuspensionRationale,
  type IReportMessageContext,
} from "../models/moderation.js";
import {
  HOLD_CLASSES,
  REPORT_OUTCOMES,
  SUSPENSION_RATIONALE_MAX_LENGTH,
  type HoldClass,
  type HoldTargetKind,
  type ReportOutcome,
} from "./moderationConstants.js";
import {
  createRetentionHold,
  releaseRetentionHold,
  reviewRetentionHold,
} from "./moderationHolds.js";
import {
  closeReportCase,
  getClosureOverlapIndicator,
  recordSuspension,
  liftSuspension,
} from "./moderationRecords.js";
import {
  reinstateParticipant,
  suspendHelper,
  suspendRequester,
} from "./moderationEnforcement.js";
import { appendSubjectAudit } from "./moderationAudit.js";
import { notPastDeleteAt } from "./moderationRetention.js";
import { getRetentionHealth } from "./moderationRetentionSweep.js";
import { runModerationTransaction } from "./safetyIdentity.js";
import { readModeratorConfig } from "./moderatorSecurity.js";
import { formatModeratorDate } from "./moderatorDates.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import { closeMessagingRequestInSession } from "./messagingLifecycle.js";
import {
  moderatorHtml,
  moderatorLogout,
  registerModeratorAuthRoutes,
  requireModerator,
  requireModeratorOriginAndCsrf,
  setModeratorSecurityHeaders,
  type ModeratorNavSection,
} from "./moderatorAuth.js";

const reportCloseSchema = z
  .object({
    _csrf: z.string().min(1).max(100),
    confirm: z.literal("close"),
    outcome: z.enum(REPORT_OUTCOMES),
    rationale: z.string().max(SUSPENSION_RATIONALE_MAX_LENGTH).optional(),
  })
  .strict();

const manualSuspensionSchema = z
  .object({
    _csrf: z.string().min(1).max(100),
    step: z.enum(["preview", "confirm"]),
    email: z.string().min(3).max(254),
    rationale: z.string().min(1).max(SUSPENSION_RATIONALE_MAX_LENGTH),
  })
  .strict();

const holdSchema = z
  .object({
    _csrf: z.string().min(1).max(100),
    targetKind: z.enum(["case", "suspension"]),
    targetRef: z.string().min(20).max(32),
    holdClass: z.enum(HOLD_CLASSES),
    reasonCode: z.string().min(1).max(40),
    note: z.string().max(500).optional(),
    endingCondition: z.string().min(1).max(300),
    reviewAt: z.string().min(1),
    relatedReportRef: z.string().min(20).max(32).optional(),
    keepSafetyIdentity: z.string().optional(),
  })
  .strict();

const HOLD_REVIEW_DAY_CHOICES = ["30", "60", "90"] as const;

// The dashboard form submits reviewInDays; reviewAt remains accepted as before.
const holdReviewSchema = z
  .object({
    _csrf: z.string().min(1).max(100),
    reviewAt: z.string().min(1).optional(),
    reviewInDays: z.enum(HOLD_REVIEW_DAY_CHOICES).optional(),
  })
  .strict()
  .refine((value) => (value.reviewAt === undefined) !== (value.reviewInDays === undefined));

const holdReleaseSchema = z
  .object({
    _csrf: z.string().min(1).max(100),
    confirm: z.literal("release"),
    endingConditionMet: z.literal("yes"),
  })
  .strict();

function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function messageCaptureReasonLabel(reason: string | undefined): string {
  switch (reason) {
    case "chat-not-authorized":
      return "The conversation was not available for evidence capture.";
    case "capture-failed":
      return "Message evidence could not be read.";
    case "conversation-closed":
      return "The conversation was closed without a report-only capture handoff.";
    case "conversation-erased":
      return "Conversation messages were already erased.";
    case "conversation-unavailable":
      return "The conversation source was unavailable.";
    case "handoff-unavailable":
      return "The report-only evidence handoff was unavailable or expired.";
    case "lifecycle-unavailable":
      return "The messaging evidence integration was unavailable.";
    case "message-history-incomplete":
      return "Some committed conversation messages were unavailable.";
    default:
      return "The capture limitation is not recorded.";
  }
}

function renderMessageCapture(context: IReportMessageContext | undefined): string {
  if (!context) return "";
  const status = context.captureStatus === "complete"
    ? context.messages.length
      ? `Capture complete: ${context.messages.length} committed message${context.messages.length === 1 ? "" : "s"} attached.`
      : "Capture complete: no committed messages were available in the authorized conversation."
    : `Capture incomplete: ${escapeHtml(messageCaptureReasonLabel(context.captureReason))} ${
        context.messages.length
          ? `${context.messages.length} safely available message${context.messages.length === 1 ? " was" : "s were"} attached.`
          : "No conversation messages were attached."
      }`;
  const messages = context.messages.length
    ? `<ol>${context.messages
        .map(
          (entry) =>
            `<li><strong>${entry.sender === "reporter" ? "Reporter" : "Reported participant"}</strong> <span class="ref-text">${escapeHtml(entry.createdAt.toISOString())}</span><br><span class="explanation-text">${escapeHtml(entry.text)}</span></li>`
        )
        .join("")}</ol>`
    : "";
  return `<section><h2>Conversation context</h2><p>${status}</p>${messages}</section>`;
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function timeHtml(value: unknown, className = ""): string {
  const label = formatModeratorDate(value);
  if (!label) return `<span class="muted${className ? ` ${className}` : ""}">Not recorded</span>`;
  const iso = (value as Date).toISOString();
  return `<time datetime="${escapeHtml(iso)}"${className ? ` class="${className}"` : ""}>${escapeHtml(label)}</time>`;
}

function hiddenCsrf(token: string): string {
  return `<input type="hidden" name="_csrf" value="${escapeHtml(token)}">`;
}

function page(
  res: Response,
  title: string,
  content: string,
  csrf: string | undefined,
  section?: ModeratorNavSection
): Response {
  return res.type("html").send(moderatorHtml(escapeHtml(title), content, csrf, section));
}

function failure(res: Response): Response {
  return res.status(503).type("html").send("Moderator service unavailable.");
}

function validRef(value: string): boolean {
  return /^[A-Za-z0-9_-]{20,32}$/.test(value);
}

function requestSnapshot(evidence: { snapshot?: Record<string, unknown> }): Record<string, unknown> {
  return evidence.snapshot ?? {};
}

function renderSnapshot(snapshot: Record<string, unknown>): string {
  const items = Array.isArray(snapshot.mealItems)
    ? snapshot.mealItems
        .map((entry) => {
          const item = entry as { name?: unknown; details?: unknown };
          return `<li>${escapeHtml(item.name)}${item.details ? ` — ${escapeHtml(item.details)}` : ""}</li>`;
        })
        .join("")
    : "";
  return `<dl><dt>Request status</dt><dd>${escapeHtml(snapshot.requestStatus)}</dd><dt>Reported party role</dt><dd>${escapeHtml(snapshot.reportedRole)}</dd><dt>Dining location</dt><dd>${escapeHtml(snapshot.vendor)}</dd><dt>Food</dt><dd>${escapeHtml(snapshot.food)}</dd><dt>Pickup window</dt><dd>${escapeHtml(snapshot.pickupWindowText)}</dd><dt>Order details</dt><dd>${escapeHtml(snapshot.orderDetails)}</dd></dl><ul>${items}</ul>`;
}

function isOutcomeWithSuspension(outcome: ReportOutcome): boolean {
  return outcome === "participant-suspended" || outcome === "request-removed-and-participant-suspended";
}

function isOutcomeWithRemoval(outcome: ReportOutcome): boolean {
  return outcome === "request-removed" || outcome === "request-removed-and-participant-suspended";
}

type ReportListState = "open" | "closed";

const CLOSED_VIEW_NOTE =
  '<aside class="help"><h2>About closed reports</h2><p>Closed reports are read-only. Report evidence (the explanation and request details) is deleted 90 days after the report is closed. The minimal case history (outcome and dates) is deleted one year after closing. Neither is deleted while a linked suspension is active or an authorized retention hold is in place; after that, the normal deadline or the release date applies, whichever is later.</p></aside>';

function outcomeLabel(outcome: string | undefined): string {
  if (!outcome) return "Not recorded";
  const text = outcome.replace(/-/g, " ");
  return text.charAt(0).toUpperCase() + text.slice(1);
}

const OUTCOME_CHOICES: Record<ReportOutcome, string> = {
  "no-action": "No action",
  "request-removed": "Remove the request",
  "participant-suspended": "Suspend the participant",
  "request-removed-and-participant-suspended": "Remove the request and suspend the participant",
};

function reportViewSwitch(active: ReportListState): string {
  const current = (state: ReportListState): string => (state === active ? ' aria-current="page"' : "");
  return `<nav class="view-switch" aria-label="Report status"><a href="/moderation"${current("open")}>Open reports</a><a href="/moderation/closed"${current("closed")}>Closed reports</a></nav>`;
}

async function renderReportList(req: Request, res: Response, state: ReportListState): Promise<Response> {
  const csrf = req.moderator!.csrfToken;
  const now = new Date();
  try {
    const rows = await ModerationReport.find({ state, ...notPastDeleteAt(now) })
      .sort(state === "open" ? { createdAt: 1 } : { closedAt: -1, createdAt: -1 })
      .limit(100)
      .select("ref createdAt closedAt outcome")
      .lean<
        Array<{
          _id: mongoose.Types.ObjectId;
          ref: string;
          createdAt: Date;
          closedAt?: Date;
          outcome?: string;
        }>
      >()
      .exec();
    const evidence = await ReportEvidence.find({
      reportId: { $in: rows.map((row) => row._id) },
      kind: "explanation",
      ...notPastDeleteAt(now),
    })
      .select("reportId reason")
      .lean<Array<{ reportId: mongoose.Types.ObjectId; reason?: string }>>()
      .exec();
    const reasonByReport = new Map(evidence.map((entry) => [String(entry.reportId), entry.reason]));
    const badge =
      state === "open"
        ? '<span class="status-badge status-open">Open</span>'
        : '<span class="status-badge status-closed">Closed</span>';
    const list = rows
      .map((row) => {
        const reason = reasonByReport.get(String(row._id));
        const reasonText = reason
          ? escapeHtml(reason)
          : state === "closed"
            ? "Reason no longer retained"
            : "Reason unavailable";
        const closedInfo =
          state === "closed"
            ? `<span class="outcome">${escapeHtml(outcomeLabel(row.outcome))} · Closed ${timeHtml(row.closedAt)}</span>`
            : "";
        const action = state === "open" ? "Review case" : "View case";
        return `<li>${badge}<span class="reason">${reasonText}</span><a class="row-open" href="/moderation/reports/${encodeURIComponent(row.ref)}">${action}<span class="visually-hidden"> ${escapeHtml(row.ref)}</span></a><span class="row-meta">${state === "closed" ? closedInfo : `<span class="timestamp">Submitted ${timeHtml(row.createdAt)}</span>`}</span></li>`;
      })
      .join("");
    const body =
      rows.length > 0
        ? `<ul>${list}</ul>`
        : `<div class="empty-state"><p>${state === "open" ? "No open reports." : "No closed reports."}</p></div>`;
    const note = state === "closed" ? CLOSED_VIEW_NOTE : "";
    const healthLink =
      '<p class="footer-link"><a href="/moderation/health">System health &amp; retention</a></p>';
    return page(res, "Reports", `${reportViewSwitch(state)}${body}${note}${healthLink}`, csrf, "reports");
  } catch {
    return failure(res);
  }
}

async function getInbox(req: Request, res: Response): Promise<Response> {
  return renderReportList(req, res, "open");
}

async function getClosedReports(req: Request, res: Response): Promise<Response> {
  return renderReportList(req, res, "closed");
}

async function getReportDetail(req: Request, res: Response): Promise<Response> {
  const ref = String(req.params.ref ?? "");
  if (!validRef(ref)) return res.status(404).type("html").send("Report not available.");
  const now = new Date();
  try {
    const data = await runModerationTransaction(async (session) => {
      const report = await ModerationReport.findOne({ ref, ...notPastDeleteAt(now) })
        .session(session)
        .lean()
        .exec();
      if (!report) return null;
      const closed = report.state === "closed";
      const [evidence, identity] = await Promise.all([
        ReportEvidence.find({ reportId: report._id, ...notPastDeleteAt(now) })
          .session(session)
          .lean()
          .exec(),
        !closed && report.safetyIdentityRef
          ? SafetyIdentity.findById(report.safetyIdentityRef).session(session).lean().exec()
          : null,
      ]);
      // An open report must still resolve its identity; a closed one has released it.
      if (!closed && (!report.safetyIdentityRef || !identity)) return null;
      const participant =
        !closed && report.safetyIdentityRef
          ? await Participant.findOne({ safetyIdentityRef: report.safetyIdentityRef })
              .select("email")
              .session(session)
              .lean<{ email?: string }>()
              .exec()
          : null;
      const snapshot = evidence.find((entry) => entry.kind === "request-snapshot");
      const explanation = evidence.find((entry) => entry.kind === "explanation");
      const conversation = evidence.find((entry) => entry.kind === "message-context");
      const overlap = await getClosureOverlapIndicator(report._id as mongoose.Types.ObjectId, session);
      await appendSubjectAudit(
        session,
        "report-viewed",
        "case",
        report._id as mongoose.Types.ObjectId,
        req.moderator?.actor
      );
      return {
        report,
        closed,
        hasSnapshot: Boolean(snapshot),
        hasExplanation: Boolean(explanation),
        snapshot: requestSnapshot(snapshot ?? {}),
        reason: explanation?.reason,
        explanation: explanation?.text,
        messages: conversation?.messageContext?.messages ?? [],
        messageCapture: conversation?.messageContext,
        reportedEmail: participant?.email,
        identityRef: String(report.safetyIdentityRef ?? ""),
        overlap,
      };
    });
    if (!data) return res.status(404).type("html").send("Report not available.");

    const csrf = req.moderator!.csrfToken;
    const statusBadge = data.closed
      ? '<span class="status-badge status-closed">Closed</span>'
      : '<span class="status-badge status-open">Open</span>';
    const backLink = data.closed
      ? '<p><a href="/moderation/closed">← Back to closed reports</a></p>'
      : '<p><a href="/moderation">← Back to open reports</a></p>';
    const reasonText = data.reason ? escapeHtml(data.reason) : "No longer retained";
    const summaryRows = [
      `<dt>Status</dt><dd>${statusBadge}</dd>`,
      `<dt>Reason</dt><dd>${reasonText}</dd>`,
      `<dt>Submitted</dt><dd>${timeHtml(data.report.createdAt)}</dd>`,
      data.closed
        ? `<dt>Closed</dt><dd>${timeHtml(data.report.closedAt)}</dd><dt>Outcome</dt><dd>${data.report.outcome ? escapeHtml(outcomeLabel(data.report.outcome)) : "Not recorded"}</dd>`
        : `<dt>Reported participant</dt><dd>${escapeHtml(data.reportedEmail ?? `Restricted safety identifier ${data.identityRef}`)}</dd>`,
      `<dt>Reference</dt><dd><span class="ref-text">${escapeHtml(ref)}</span></dd>`,
    ].join("");
    const summary = `<section><h2>Report summary</h2><dl>${summaryRows}</dl></section>`;
    const explanation = data.hasExplanation
      ? `<section><h2>Explanation</h2><p class="explanation-text">${escapeHtml(data.explanation)}</p></section>`
      : "";
    const snapshotSection = data.hasSnapshot
      ? `<section><h2>Request snapshot</h2>${renderSnapshot(data.snapshot)}</section>`
      : "";
    const conversationSection = renderMessageCapture(data.messageCapture);

    if (data.closed) {
      const retained =
        data.hasExplanation || data.hasSnapshot
          ? ""
          : "<p>The report evidence is no longer retained. Only the minimal case history remains.</p>";
      return page(res, "Report detail", `${backLink}${summary}${retained}${explanation}${snapshotSection}${conversationSection}`, csrf, "reports");
    }

    const overlap = data.overlap
      ? `<p class="notice">${data.overlap.otherOpenReport || data.overlap.activeSuspension ? [data.overlap.otherOpenReport ? "This participant has another open report." : "", data.overlap.activeSuspension ? "This participant is already suspended." : ""].filter(Boolean).join(" ") : "No other open reports or active suspension for this participant."}</p>`
      : "";
    const closeForm = `<section class="decision"><h2>Close report</h2><form method="post" action="/moderation/reports/${encodeURIComponent(ref)}/close">${hiddenCsrf(csrf)}<label>Outcome <select name="outcome" required>${REPORT_OUTCOMES.map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(OUTCOME_CHOICES[value])}</option>`).join("")}</select></label><label>Notes <span class="field-hint">(required if the outcome suspends the participant)</span> <textarea name="rationale" maxlength="${SUSPENSION_RATIONALE_MAX_LENGTH}"></textarea></label><label><input type="checkbox" name="confirm" value="close" required>I confirm the selected outcome</label><button type="submit" class="btn-danger">Apply and close report</button></form></section>`;
    return page(res, "Report detail", `${backLink}${summary}${explanation}${snapshotSection}${conversationSection}${overlap}${closeForm}`, csrf, "reports");
  } catch {
    return failure(res);
  }
}

async function closeReport(req: Request, res: Response): Promise<Response | void> {
  const parsed = reportCloseSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).type("html").send("Report could not be closed.");
  const ref = String(req.params.ref ?? "");
  if (!validRef(ref)) return res.status(404).type("html").send("Report not available.");
  const outcome = parsed.data.outcome;
  const rationale = text(parsed.data.rationale).trim();
  if (
    isOutcomeWithSuspension(outcome) &&
    (rationale.length === 0 ||
      rationale.length > SUSPENSION_RATIONALE_MAX_LENGTH ||
      /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i.test(rationale))
  ) {
    return page(
      res.status(400),
      "Report detail",
      `<section><p role="alert">Notes are required when the outcome suspends the participant. Notes must not contain an email address.</p><p><a href="/moderation/reports/${encodeURIComponent(ref)}">Back to report</a></p></section>`,
      req.moderator?.csrfToken,
      "reports"
    );
  }
  const now = new Date();
  try {
    const result = await runModerationTransaction(async (session) => {
      const report = await ModerationReport.findOne({ ref, state: "open", ...notPastDeleteAt(now) })
        .session(session)
        .lean()
        .exec();
      if (!report || !report.safetyIdentityRef) return { status: "not-found" as const };
      const evidence = await ReportEvidence.findOne({
        reportId: report._id,
        kind: "request-snapshot",
        ...notPastDeleteAt(now),
      })
        .session(session)
        .lean()
        .exec();
      const snapshot = evidence?.snapshot as Record<string, unknown> | undefined;
      if (isOutcomeWithRemoval(outcome) && snapshot) {
        const requestId = snapshot.requestId;
        if (!mongoose.isValidObjectId(requestId)) throw new Error("Report evidence is unavailable.");
        const requestObjectId = new mongoose.Types.ObjectId(String(requestId));
        const request = await MealRequest.findById(requestObjectId)
          .select("+requesterParticipantId +helperParticipantId")
          .session(session)
          .lean<{ requesterParticipantId?: mongoose.Types.ObjectId; helperParticipantId?: mongoose.Types.ObjectId }>()
          .exec();
        const removal = await MealRequest.updateOne(
          { _id: requestObjectId, moderationUnavailable: { $ne: true } },
          { $set: { moderationUnavailable: true, updatedAt: now } },
          { session }
        ).exec();
        if (removal.matchedCount === 1) {
          await appendSubjectAudit(
            session,
            "request-removed",
            "case",
            report._id as mongoose.Types.ObjectId,
            req.moderator?.actor
          );
        } else {
          const current = await MealRequest.findById(requestId)
            .select("status +moderationUnavailable")
            .session(session)
            .lean<{ status?: string; moderationUnavailable?: boolean }>()
            .exec();
          if (current && current.moderationUnavailable !== true) {
            throw new Error("Request removal was not applied.");
          }
        }
        // Retire existing request/helper conversations set-wise and tombstone
        // the current helper relationship in this removal transaction.
        await closeMessagingRequestInSession(
          requestObjectId,
          request?.helperParticipantId ?? null,
          session
        );
      } else if (isOutcomeWithRemoval(outcome)) {
        throw new Error("Report evidence is unavailable.");
      }
      if (isOutcomeWithSuspension(outcome)) {
        const keyring = req.moderator!.config.keyring;
        const participant = await Participant.findOne({
          safetyIdentityRef: report.safetyIdentityRef,
        })
          .select("_id")
          .session(session)
          .lean<{ _id: mongoose.Types.ObjectId }>()
          .exec();
        if (participant) {
          const enforcement = {
            session,
            now,
            keyring,
            participantId: participant._id,
            safetyIdentityId: report.safetyIdentityRef as mongoose.Types.ObjectId,
            origin: "report" as const,
            reportId: report._id as mongoose.Types.ObjectId,
            rationale,
            actor: req.moderator?.actor,
          };
          await suspendRequester(enforcement);
          await suspendHelper(enforcement);
        } else {
          await recordSuspension(session, {
            keyring,
            safetyIdentityId: report.safetyIdentityRef as mongoose.Types.ObjectId,
            origin: "report",
            reportId: report._id as mongoose.Types.ObjectId,
            rationale,
            actor: req.moderator?.actor,
          });
        }
      }
      const closed = await closeReportCase(
        session,
        {
          reportId: report._id as mongoose.Types.ObjectId,
          outcome,
          enforcementApplied: true,
          keyring: req.moderator!.config.keyring,
          actor: req.moderator?.actor,
        },
        now
      );
      return closed.status === "closed" ? { status: "closed" as const } : { status: "not-found" as const };
    });
    if (result.status !== "closed") return res.status(404).type("html").send("Report not available.");
    return res.redirect(303, "/moderation");
  } catch {
    return res.status(409).type("html").send("Report could not be closed. No outcome was confirmed.");
  }
}

function manualForm(csrf: string, email = "", rationale = "", confirmation = false): string {
  const action = "/moderation/suspensions/manual";
  const buttonClass = confirmation ? ' class="btn-danger"' : "";
  return `<form method="post" action="${action}">${hiddenCsrf(csrf)}<input type="hidden" name="step" value="${confirmation ? "confirm" : "preview"}"><label>Verified email <span class="field-hint">(required)</span> <input name="email" type="email" maxlength="254" required value="${escapeHtml(email)}"></label><label>Notes <span class="field-hint">(required)</span> <textarea name="rationale" maxlength="${SUSPENSION_RATIONALE_MAX_LENGTH}" required>${escapeHtml(rationale)}</textarea></label>${confirmation ? "<p>Confirm this manual suspension?</p>" : ""}<button type="submit"${buttonClass}>${confirmation ? "Confirm suspension" : "Review suspension"}</button>${confirmation ? ' <a href="/moderation/suspensions">Cancel</a>' : ""}</form>`;
}

async function manualSuspension(req: Request, res: Response): Promise<Response | void> {
  const parsed = manualSuspensionSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).type("html").send("Manual suspension could not be confirmed.");
  const email = normalizeParticipantPrincipal(parsed.data.email);
  if (!email) return res.status(400).type("html").send("Manual suspension could not be confirmed.");
  const rationale = parsed.data.rationale.trim();
  if (
    rationale.length === 0 ||
    /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i.test(rationale)
  ) {
    return res.status(400).type("html").send("A private rationale is required.");
  }
  try {
    const participant = await Participant.findOne({ email }).select("_id").lean().exec();
    if (!participant) {
      return page(res, "Manual suspension", `<section><p>No verified participant was found.</p>${manualForm(req.moderator!.csrfToken)}</section>`, req.moderator!.csrfToken, "suspensions");
    }
    if (parsed.data.step === "preview") {
      return page(
        res,
        "Confirm manual suspension",
        `<section><p><strong>Participant:</strong> ${escapeHtml(email)}</p>${manualForm(req.moderator!.csrfToken, email, rationale, true)}</section>`,
        req.moderator!.csrfToken,
        "suspensions"
      );
    }

    const now = new Date();
    await runModerationTransaction(async (session) => {
      const current = await Participant.findOne({ _id: participant._id, email })
        .select("+safetyIdentityRef")
        .session(session)
        .lean<{ _id: mongoose.Types.ObjectId }>()
        .exec();
      if (!current) throw new Error("Participant is no longer available.");
      const input = {
        session,
        now,
        keyring: req.moderator!.config.keyring,
        participantId: current._id,
        email,
        origin: "manual" as const,
        rationale,
        actor: req.moderator?.actor,
      };
      await suspendRequester(input);
      await suspendHelper(input);
    });
    return res.redirect(303, "/moderation/suspensions");
  } catch {
    return res.status(409).type("html").send("Manual suspension could not be confirmed.");
  }
}

async function listSuspensions(req: Request, res: Response): Promise<Response> {
  const now = new Date();
  try {
    const rows = await runModerationTransaction(async (session) => {
      const suspensions = await Suspension.find({ state: "active" })
        .sort({ createdAt: 1 })
        .limit(200)
        .session(session)
        .lean()
        .exec();
      for (const row of suspensions) {
        await appendSubjectAudit(
          session,
          "suspension-viewed",
          "suspension",
          row._id as mongoose.Types.ObjectId,
          req.moderator?.actor
        );
      }
      return Promise.all(
        suspensions.map(async (row) => {
          const [participant, rationale] = await Promise.all([
            row.safetyIdentityRef
              ? Participant.findOne({ safetyIdentityRef: row.safetyIdentityRef })
                  .select("email")
                  .session(session)
                  .lean<{ email?: string }>()
                  .exec()
              : null,
            SuspensionRationale.findOne({ suspensionId: row._id, ...notPastDeleteAt(now) })
              .select("text")
              .session(session)
              .lean<{ text?: string }>()
              .exec(),
          ]);
          return {
            row,
            email: participant?.email,
            rationale: rationale?.text,
          };
        })
      );
    });
    const csrf = req.moderator!.csrfToken;
    const content = rows.length
      ? `<ul>${rows
          .map(
            ({ row, email, rationale }) =>
              `<li><p class="susp-meta"><span class="status-badge status-active">Active</span><span class="participant">${escapeHtml(email ?? "Restricted safety identifier")}</span><span class="origin-chip">Origin: ${escapeHtml(row.origin)}</span><span class="timestamp">Suspended ${timeHtml(row.createdAt)}</span><span class="ref-chip">${escapeHtml(row.ref)}</span></p><p class="rationale">${rationale ? escapeHtml(rationale) : "Rationale no longer retained"}</p><form method="post" class="action-row" action="/moderation/suspensions/${encodeURIComponent(row.ref)}/reinstate">${hiddenCsrf(csrf)}<button type="submit" class="btn-secondary">Reinstate</button></form></li>`
          )
          .join("")}</ul>`
      : '<div class="empty-state"><p>No active suspensions.</p></div>';
    return page(
      res,
      "Active suspensions",
      `${content}<section><h2>Manual suspension</h2>${manualForm(csrf)}</section>`,
      csrf,
      "suspensions"
    );
  } catch {
    return failure(res);
  }
}

async function reinstate(req: Request, res: Response): Promise<Response | void> {
  const ref = String(req.params.ref ?? "");
  if (!validRef(ref)) return res.status(404).type("html").send("Suspension not available.");
  try {
    await runModerationTransaction(async (session) => {
      const suspension = await Suspension.findOne({ ref, state: "active" })
        .session(session)
        .lean()
        .exec();
      if (!suspension) return;
      const participant = suspension.safetyIdentityRef
        ? await Participant.findOne({ safetyIdentityRef: suspension.safetyIdentityRef })
            .select("_id")
            .session(session)
            .lean<{ _id: mongoose.Types.ObjectId }>()
            .exec()
        : null;
      if (participant) {
        await reinstateParticipant({
          session,
          now: new Date(),
          keyring: req.moderator!.config.keyring,
          suspensionId: suspension._id as mongoose.Types.ObjectId,
          participantId: participant._id,
          actor: req.moderator?.actor,
        });
      } else {
        await liftSuspension(
          session,
          {
            suspensionId: suspension._id as mongoose.Types.ObjectId,
            keyring: req.moderator!.config.keyring,
            actor: req.moderator?.actor,
          },
          new Date()
        );
      }
    });
    return res.redirect(303, "/moderation/suspensions");
  } catch {
    return res.status(409).type("html").send("Reinstatement could not be confirmed.");
  }
}

async function createHold(req: Request, res: Response): Promise<Response | void> {
  const parsed = holdSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).type("html").send("Retention hold could not be created.");
  const values = parsed.data;
  const reviewAt = new Date(values.reviewAt);
  if (!Number.isFinite(reviewAt.getTime())) {
    return res.status(400).type("html").send("Retention hold could not be created.");
  }
  try {
    await runModerationTransaction(async (session) => {
      const target =
        values.targetKind === "case"
          ? await ModerationReport.findOne({ ref: values.targetRef }).session(session).lean().exec()
          : await Suspension.findOne({ ref: values.targetRef }).session(session).lean().exec();
      if (!target) throw new Error("Target is unavailable.");
      let relatedReportId: mongoose.Types.ObjectId | undefined;
      if (values.relatedReportRef) {
        const related = await ModerationReport.findOne({ ref: values.relatedReportRef })
          .session(session)
          .lean()
          .exec();
        if (!related) throw new Error("Related report is unavailable.");
        relatedReportId = related._id as mongoose.Types.ObjectId;
      }
      await createRetentionHold(
        session,
        {
          targetKind: values.targetKind as HoldTargetKind,
          targetId: target._id as mongoose.Types.ObjectId,
          holdClass: values.holdClass as HoldClass,
          reasonCode: values.reasonCode,
          note: values.note || undefined,
          endingCondition: values.endingCondition,
          reviewAt,
          relatedReportId,
          keepSafetyIdentity: values.keepSafetyIdentity === "yes",
          actor: req.moderator?.actor,
        },
        new Date()
      );
    });
    return res.redirect(303, "/moderation");
  } catch {
    return res.status(409).type("html").send("Retention hold could not be created.");
  }
}

async function reviewHold(req: Request, res: Response): Promise<Response | void> {
  const parsed = holdReviewSchema.safeParse(req.body);
  const ref = String(req.params.ref ?? "");
  const reviewFailed = (status: number): Response =>
    holdFailure(res, status, "The review could not be recorded. The hold may have been released, or the date is not allowed (it must be in the future and within 90 days).");
  if (!parsed.success || !validRef(ref)) return reviewFailed(400);
  const reviewAt = parsed.data.reviewInDays
    ? new Date(Date.now() + Number(parsed.data.reviewInDays) * 24 * 60 * 60 * 1000)
    : new Date(parsed.data.reviewAt ?? "");
  if (!Number.isFinite(reviewAt.getTime())) return reviewFailed(400);
  try {
    await runModerationTransaction(async (session) => {
      const hold = await RetentionHold.findOne({ ref, state: "active" })
        .session(session)
        .lean()
        .exec();
      if (!hold) throw new Error("Hold is unavailable.");
      await reviewRetentionHold(
        session,
        hold._id as mongoose.Types.ObjectId,
        reviewAt,
        new Date(),
        req.moderator?.actor
      );
    });
    return res.redirect(303, "/moderation/health?hold=reviewed");
  } catch {
    return reviewFailed(409);
  }
}

async function releaseHold(req: Request, res: Response): Promise<Response | void> {
  const parsed = holdReleaseSchema.safeParse(req.body);
  const ref = String(req.params.ref ?? "");
  const releaseFailed = (status: number): Response =>
    holdFailure(res, status, "The hold could not be released. It may already have been released, or the confirmation was not checked.");
  if (!parsed.success || !validRef(ref)) return releaseFailed(400);
  try {
    await runModerationTransaction(async (session) => {
      const hold = await RetentionHold.findOne({ ref, state: "active" })
        .session(session)
        .lean()
        .exec();
      if (!hold) throw new Error("Hold is unavailable.");
      await releaseRetentionHold(
        session,
        hold._id as mongoose.Types.ObjectId,
        { endingConditionMet: true },
        new Date(),
        req.moderator!.config.keyring,
        req.moderator?.actor
      );
    });
    return res.redirect(303, "/moderation/health?hold=released");
  } catch {
    return releaseFailed(409);
  }
}

const HEALTH_INTRO =
  '<p class="help">This page is not part of the main navigation. It is the destination of retention alert emails. It shows whether old report data is being deleted on schedule and whether operator alerts are being delivered. If every count is 0 and nothing is flagged, no action is needed.</p>';

const RETENTION_ALERT_REASON_LABELS: Record<string, string> = {
  "last-run-failed": "The last retention run failed",
  "stale-run": "The retention sweep has not run recently",
  "overdue-records": "Records are past their deletion date",
  "invariant-violation": "Records have no deletion date or reason to be kept",
  "key-unavailable": "Safety-identity key material is unavailable",
  "hold-review-due": "A retention hold is past its review date",
};

function retentionAlertReasons(reasons: string[]): string {
  return reasons.map((reason) => escapeHtml(RETENTION_ALERT_REASON_LABELS[reason] ?? reason)).join("; ");
}

const HOLD_CLASS_LABELS: Record<string, string> = {
  "overlapping-case": "Overlapping case",
  "legal-preservation": "Legal preservation",
};

function holdFailure(res: Response, status: number, message: string): Response {
  return res
    .status(status)
    .type("html")
    .send(
      moderatorHtml(
        "System health &amp; retention",
        `<p class="notice" role="alert">${escapeHtml(message)}</p><p><a href="/moderation/health">Back to System health &amp; retention</a></p>`,
        undefined
      )
    );
}

type HealthHold = {
  ref: string;
  targetKind: string;
  targetId: unknown;
  holdClass: string;
  reasonCode: string;
  note?: string;
  endingCondition: string;
  reviewAt: Date;
  lastReviewedAt?: Date;
  reviewPromptRaisedAt?: Date;
  createdAt?: Date;
};

function renderHoldCard(hold: HealthHold, targetRef: string | undefined, csrf: string, now: Date): string {
  const due = hold.reviewAt.getTime() <= now.getTime() || hold.reviewPromptRaisedAt !== undefined;
  const target = targetRef
    ? hold.targetKind === "case"
      ? `Report <a class="ref-link" href="/moderation/reports/${encodeURIComponent(targetRef)}">${escapeHtml(targetRef)}</a>`
      : `Suspension <span class="ref-text">${escapeHtml(targetRef)}</span>`
    : "Not available";
  const id = escapeHtml(hold.ref);
  const note = hold.note ? `<dt>Note</dt><dd>${escapeHtml(hold.note)}</dd>` : "";
  return `<li><h3><span class="status-badge status-hold">Active</span>${escapeHtml(HOLD_CLASS_LABELS[hold.holdClass] ?? hold.holdClass)}${due ? ' <span class="review-due-note">Review due</span>' : ""}</h3><dl><dt>Case</dt><dd>${target}</dd><dt>Reason</dt><dd>${escapeHtml(hold.reasonCode)}</dd>${note}<dt>Ends when</dt><dd>${escapeHtml(hold.endingCondition)}</dd><dt>Placed</dt><dd>${timeHtml(hold.createdAt)}</dd><dt>Next review</dt><dd>${timeHtml(hold.reviewAt)}</dd><dt>Last review</dt><dd>${hold.lastReviewedAt ? timeHtml(hold.lastReviewedAt) : '<span class="muted">Not yet reviewed</span>'}</dd></dl><div class="hold-actions"><form method="post" action="/moderation/holds/${encodeURIComponent(hold.ref)}/review">${hiddenCsrf(csrf)}<label for="review-${id}">Next review in</label><select id="review-${id}" name="reviewInDays" required><option value="30">30 days</option><option value="60">60 days</option><option value="90">90 days</option></select><button type="submit" class="btn-secondary">Record review</button></form><form method="post" action="/moderation/holds/${encodeURIComponent(hold.ref)}/release">${hiddenCsrf(csrf)}<input type="hidden" name="confirm" value="release"><label><input type="checkbox" name="endingConditionMet" value="yes" required>I confirm the ending condition above is met.</label><p class="help">Releasing lets the normal retention and deletion rules apply again. Evidence already deleted is not restored.</p><button type="submit" class="btn-danger">Release hold</button></form></div></li>`;
}

async function renderHoldsSection(csrf: string, now: Date, notice: string): Promise<string> {
  const holds = (await RetentionHold.find({ state: "active", ...notPastDeleteAt(now) })
    .sort({ reviewAt: 1, createdAt: 1 })
    .select("ref targetKind targetId holdClass reasonCode note endingCondition reviewAt lastReviewedAt reviewPromptRaisedAt createdAt")
    .lean()
    .exec()) as unknown as HealthHold[];
  const caseIds = holds.filter((h) => h.targetKind === "case").map((h) => h.targetId);
  const suspensionIds = holds.filter((h) => h.targetKind === "suspension").map((h) => h.targetId);
  const [cases, suspensions] = await Promise.all([
    caseIds.length > 0 ? ModerationReport.find({ _id: { $in: caseIds } }, { _id: 1, ref: 1 }).lean().exec() : [],
    suspensionIds.length > 0 ? Suspension.find({ _id: { $in: suspensionIds } }, { _id: 1, ref: 1 }).lean().exec() : [],
  ]);
  const refs = new Map([...cases, ...suspensions].map((t) => [String(t._id), t.ref as string]));
  const body =
    holds.length > 0
      ? `<ul class="hold-list">${holds.map((hold) => renderHoldCard(hold, refs.get(String(hold.targetId)), csrf, now)).join("")}</ul>`
      : '<p class="empty-state">No retention holds are active.</p>';
  return `<section><h2>Retention holds</h2>${notice}<p class="help">A retention hold keeps a case’s evidence from being deleted on the normal schedule while it is still needed. Record a review to keep it, or release it once its ending condition is met.</p>${body}</section>`;
}

const HOLD_NOTICES: Record<string, string> = {
  reviewed: "Review recorded. The next review date has been updated.",
  released: "Hold released. Normal retention and deletion rules now apply to that case.",
};

async function moderatorHealth(req: Request, res: Response): Promise<Response | void> {
  try {
    const now = new Date();
    const noticeKey = typeof req.query.hold === "string" ? req.query.hold : "";
    const noticeText = Object.hasOwn(HOLD_NOTICES, noticeKey) ? HOLD_NOTICES[noticeKey] : undefined;
    const notice = noticeText ? `<p class="notice" role="status">${escapeHtml(noticeText)}</p>` : "";
    const holds = await renderHoldsSection(req.moderator!.csrfToken, now, notice);
    const [retention, failedAlerts, pendingAlerts] = await Promise.all([
      getRetentionHealth(now),
      ModerationReport.countDocuments({ state: "open", alertStatus: "failed", ...notPastDeleteAt(now) }),
      ModerationReport.countDocuments({
        state: "open",
        alertStatus: "pending",
        ...notPastDeleteAt(now),
      }),
    ]);
    const metric = (label: string, value: string, help: string): string =>
      `<dt>${label}</dt><dd>${value}<small class="help"> ${help}</small></dd>`;
    const count = (value: number): string => String(value);
    const sweep = `<section><h2>Retention sweep</h2><dl>${metric("Last retention run", timeHtml(retention.lastRunAt), "When the retention sweep last ran.")}${metric("Last successful retention run", timeHtml(retention.lastSuccessAt), "When a sweep last completed successfully.")}${metric("Retention run status", retention.lastRunStatus ? escapeHtml(retention.lastRunStatus) : "Not recorded", "Outcome of the most recent sweep.")}${metric("Overdue records", count(retention.overdueNow), "Records past their deletion date that have not been deleted yet.")}${metric("Retention invariant violations", count(retention.invariantViolationsLastRun), "Records found in the last run with neither a deletion date nor a live reason to be kept.")}${metric("Safety-key issues", count(retention.keyIssuesNow), "Records that depend on safety-identity key material that is missing or invalid.")}</dl></section>`;
    const alerts = `<section><h2>Alerts &amp; notifications</h2><dl>${metric("Retention alert needed", retention.alertNeeded ? retentionAlertReasons(retention.alertReasons) : "no", "Whether the sweep currently needs an operator alert.")}${metric("Retention alert submission status", retention.alertDeliveryStatus ? escapeHtml(retention.alertDeliveryStatus) : "Not recorded", "Provider acceptance, not confirmed delivery.")}${metric("Last retention alert attempt", timeHtml(retention.alertLastAttemptAt), "When an operator alert was last attempted.")}${metric("Failed report alerts", count(failedAlerts), "Open reports whose operator alert failed.")}${metric("Stale report alerts", count(pendingAlerts), "Open reports whose operator alert is still pending.")}</dl></section>`;
    return page(res, "System health & retention", `${HEALTH_INTRO}${sweep}${alerts}${holds}`, req.moderator!.csrfToken);
  } catch {
    return failure(res);
  }
}

const moderatorFormParser = express.urlencoded({ extended: false, limit: "32kb" });

function parserError(error: unknown, _req: Request, res: Response, next: NextFunction): void {
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
    type === "request.aborted" ||
    type === "parameters.too.many"
  ) {
    res.status(400).type("html").send("Request could not be confirmed.");
    return;
  }
  next(error);
}

export function registerModerationRoutes(app: Express): boolean {
  const config = readModeratorConfig();
  if (!config) return false;
  registerModeratorAuthRoutes(app, moderatorFormParser);
  const protectedRoute = [setModeratorSecurityHeaders, moderatorFormParser, requireModerator];
  const mutationRoute = [...protectedRoute, requireModeratorOriginAndCsrf];
  app.get("/moderation", setModeratorSecurityHeaders, requireModerator, getInbox);
  app.get("/moderation/closed", setModeratorSecurityHeaders, requireModerator, getClosedReports);
  app.get("/moderation/reports/:ref", setModeratorSecurityHeaders, requireModerator, getReportDetail);
  app.post("/moderation/reports/:ref/close", ...mutationRoute, closeReport, parserError);
  app.get("/moderation/suspensions", setModeratorSecurityHeaders, requireModerator, listSuspensions);
  app.get("/moderation/health", setModeratorSecurityHeaders, requireModerator, moderatorHealth);
  app.post("/moderation/suspensions/manual", ...mutationRoute, manualSuspension, parserError);
  app.post("/moderation/suspensions/:ref/reinstate", ...mutationRoute, reinstate, parserError);
  app.post("/moderation/holds", ...mutationRoute, createHold, parserError);
  app.post("/moderation/holds/:ref/review", ...mutationRoute, reviewHold, parserError);
  app.post("/moderation/holds/:ref/release", ...mutationRoute, releaseHold, parserError);
  return true;
}
