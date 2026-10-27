
import {
  isSchedulerEnabled,
  registerScheduledJob,
} from "./src/scheduledJobs.js";
import { validateProductionRuntime } from "./src/productionRuntimeConfig.js";
import { registerHealthRoutes } from "./src/healthRoutes.js";
import { registerReviewBoundary, pauseRequestAction } from "./src/reviewRuntime.js";
import { registerReviewRuntimeIntegration } from "./src/reviewRuntimeIntegration.js";
import { assertExternalProvidersAllowed, isReviewRuntime } from "./src/externalProviders.js";

let runtimeReady = false;
const schedulerEnabled = isSchedulerEnabled();

function scheduleAppJob(
  expression: string,
  job: () => void | Promise<void>
): void {
  registerScheduledJob(expression, job, {
    enabled: schedulerEnabled,
    isReady: () => runtimeReady,
  });
}

// Hourly cron job: send digest emails for requests with no real-time notifications
scheduleAppJob("5 * * * *", async () => {
  try {
    const { isPublicActionsPaused, logPausedSkip } = await import("./src/publicActionsPause.js");
    // Checked before any query or send so a suppressed digest writes no
    // SendLog at all — a skipped notification must never look delivered.
    if (isPublicActionsPaused()) {
      logPausedSkip("hourly subscriber digest");
      return;
    }
    const { isRequestAlertEmailDeliveryActive } = await import("./src/requestAlertEmailDelivery.js");
    if (!isRequestAlertEmailDeliveryActive()) return;
    const { Request: MealRequest, Subscriber, SendLog } = await import("./models/db.js");
    const { sendDigestEmail } = await import("./src/sendDigestEmail.js");
    const { buildEffectiveAvailabilityFilter } = await import("./src/requestAvailability.js");
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const digestNow = new Date();
    const recentRequests = await MealRequest.find({
      createdAt: { $gte: oneHourAgo },
      ...buildEffectiveAvailabilityFilter(digestNow),
    }).lean();
    const notifiedRequestIds = new Set((await SendLog.find({ requestId: { $in: recentRequests.map(r => r._id) } }).lean()).map(l => String(l.requestId)));
    const unnotified = recentRequests.filter(r => !notifiedRequestIds.has(String(r._id)));
    if (!unnotified.length) return;
    const eligible = await Subscriber.find({
      status: "confirmed",
      bounced: false,
      dailyCount: { $lt: 4 },
      $or: [
        { lastSentAt: { $lt: oneHourAgo } },
        { lastSentAt: null },
      ],
    });
    for (const sub of eligible) {
      try {
  await sendDigestEmail(sub, unnotified as any);
        await Subscriber.updateOne(
          { _id: sub._id },
          { $set: { lastSentAt: new Date() }, $inc: { dailyCount: 1 } }
        );
        for (const req of unnotified) {
          await SendLog.create({
            subscriberId: sub._id,
            requestId: req._id,
            sentAt: new Date(),
            status: "sent",
            error: "digest"
          });
        }
      } catch {
        console.error("[digest] subscriber email submission failed");
      }
    }
    console.log(`[digest] attempted ${eligible.length} subscribers for ${unnotified.length} requests`);
  } catch {
    console.error("[digest] hourly job failed");
  }
});
// Daily cron job: reset dailyCount for all confirmed subscribers
scheduleAppJob("0 3 * * *", async () => {
  try {
    const { Subscriber } = await import("./models/db.js");
    const result = await Subscriber.updateMany({ status: "confirmed" }, { $set: { dailyCount: 0 } });
    console.log(`[cron] Reset dailyCount for ${result.modifiedCount} subscribers at ${new Date().toISOString()}`);
  } catch {
    console.error("[cron] daily subscriber reset failed");
  }
});

// Monitoring cron: check SendLog.fail spikes and notify operators if configured
scheduleAppJob("*/10 * * * *", async () => {
  try {
    const { SendLog } = await import("./models/db.js");
    const monitorEmails = (process.env.MONITOR_EMAILS || '').split(',').map(s => s.trim()).filter(Boolean);
    const threshold = parseInt(process.env.MONITOR_THRESHOLD || '10', 10);
    if (!monitorEmails.length) return;
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const failCount = await SendLog.countDocuments({ status: 'fail', sentAt: { $gte: oneHourAgo } });
    if (failCount >= threshold) {
      try {
        assertExternalProvidersAllowed();
        await resend.emails.send({
          from: emailSender(),
          to: monitorEmails,
          subject: `CommonPlate alert: ${failCount} failed sends in last hour`,
          html: `<p>Detected ${failCount} failed send attempts in the last hour. Please investigate send logs in the database.</p>`,
        });
        console.log(`[monitor] alert submitted (${failCount} failures, ${monitorEmails.length} recipients)`);
      } catch {
        console.error("[monitor] alert submission failed");
      }
    }
  } catch {
    console.error("[monitor] job failed");
  }
});
import express, { Request, Response, NextFunction } from "express";
import helmet from "helmet";

import mongoose from "mongoose";
import "dotenv/config";
import path from "path";
import { fileURLToPath } from "url";
import {
  Fulfillment,
  PlacementEvidence,
  Installation,
  Participant,
  ParticipantDeletionOperation,
  ParticipantBlock,
  ParticipantIdentityKeyVersion,
  ParticipantVerification,
  PushDelivery,
  Request as MealRequest,
  RequestParticipation,
  Subscriber,
} from "./models/db.js";
import rateLimit from "express-rate-limit";
import { Resend } from "resend";
import {
  PARTICIPANT_BLOCK_ROUTE_PATH,
  PARTICIPANT_BLOCKS_ROUTE_PATH,
  REQUEST_BLOCK_ROUTE_PATH,
  createParticipantBlock,
  createParticipantBlockRateLimiter,
  deleteParticipantBlock,
  deleteParticipantBlockRateLimiter,
  listParticipantBlocks,
  listParticipantBlocksRateLimiter,
} from "./src/participantBlockRoute.js";
import { assertParticipantIdentityIndexesMigrated } from "./src/participantIdentityMigration.js";
import { getPublicRequestDetail } from "./src/requestDetailRoute.js";
import { getPublicRequestList } from "./src/requestListRoute.js";
import {
  createRequest,
  createRequestRateLimiter,
} from "./src/createRequestRoute.js";
import { scheduleEligibilityNotificationSweep } from "./src/eligibilityNotificationSweep.js";
import { scheduleClosingSoonNotificationSweep } from "./src/closingSoonNotificationSweep.js";
import { establishModerationIndexes } from "./models/moderation.js";
import { scheduleModerationRetentionSweep } from "./src/moderationRetentionSweep.js";
import { scheduleParticipantDeletionReceiptSweep } from "./src/participantDeletionReceiptSweep.js";
import { registerFulfillmentRoute } from "./src/fulfillmentRoute.js";
import { registerPlacedOrderRoutes } from "./src/placedOrderRoutes.js";
import { registerHelperReservationContactRoute } from "./src/helperReservationContactRoute.js";
import { assertMongoTransactionsSupported } from "./src/mongoTransactions.js";
import { mongoConnectionOptions } from "./src/mongoConnectionOptions.js";
import { getStats } from "./src/statsRoute.js";
import {
  CLAIM_EXTENSION_ROUTE_PATH,
  CLAIM_RELEASE_ROUTE_PATH,
  CLAIM_ROUTE_PATH,
  claimExtensionRateLimiter,
  claimRateLimiter,
  claimReleaseRateLimiter,
  claimRequest,
  extendClaim,
  pauseDay4Mutation,
  releaseClaim,
} from "./src/claimRoute.js";
import {
  ACTIVE_RESERVATION_ROUTE_PATH,
  activeReservationRateLimiter,
  getActiveReservation,
} from "./src/reservationRoute.js";
import {
  EMAIL_ALERT_STATE_ROUTE_PATH,
  emailAlertStateRateLimiter,
  getEmailAlertState,
} from "./src/emailAlertStateRoute.js";
import {
  REQUEST_ELIGIBILITY_ROUTE_PATH,
  buildRequestEligibilityMiddlewareChain,
  requestEligibilityRateLimiter,
  getRequestEligibility,
} from "./src/requestEligibilityRoute.js";
import { registerOwnerRequestReadRoutes } from "./src/requestOwnerReadRoute.js";
import { registerRequestUpdateRoutes } from "./src/requestUpdateRoute.js";
import { readClaimTokenHmacSecret } from "./src/claimToken.js";
import { assertUnsubscribeSigningSecretForActivation } from "./src/unsubscribeCredential.js";
import { assertApnsConfigurationForActivation } from "./src/apnsConfig.js";
import { assertParticipantSigningSecretForActivation } from "./src/participantCredentials.js";
import { assertParticipantIdentityCredentialsForActivation } from "./src/participantIdentityKeys.js";
import { createProductionLegacyWebPageGuard } from "./src/legacyWebPageGuard.js";
import { emailSender } from "./src/emailSender.js";
import { registerParticipantVerificationRoutes } from "./src/participantVerificationRoutes.js";
import { registerReportRoutes } from "./src/reportRoutes.js";
import { registerModerationRoutes } from "./src/moderationRoutes.js";
import { registerParticipantEmailUnsubscribeRoute } from "./src/participantEmailUnsubscribeRoute.js";
import { registerParticipantDeletionRoutes } from "./src/participantDeletionRoutes.js";
import { registerScreenshotProposalRoute } from "./src/screenshotProposalRoute.js";
import { registerRequestOperationTerminalRoute } from "./src/requestOperationTerminalRoute.js";
import { assertQaBindHostConfiguration } from "./src/qaBindHost.js";
import { establishRequestOperationLedger } from "./src/requestOperationAuthority.js";
import {
  CREATE_UNAVAILABLE_MESSAGE,
  SUBSCRIBE_UNAVAILABLE_MESSAGE,
  isPublicActionsPaused,
  pausePublicAction,
} from "./src/publicActionsPause.js";
import { subscribe } from "./src/subscribeRoute.js";
import {
  INSTALLATION_PUSH_ROUTE_PATH,
  INSTALLATION_PUSH_UNAVAILABLE_MESSAGE,
  installationPushRateLimiter,
  synchronizeInstallationPush,
} from "./src/installationPushRoute.js";
import {
  CONFIRMATION_ROUTE_PATH,
  confirmSubscriptionPage,
  confirmationBodyParser,
  confirmationParserError,
  confirmationRateLimiter,
  confirmationSecurityHeaders,
  pauseConfirmationPage,
  showConfirmationPage,
} from "./src/confirmSubscriptionRoute.js";
import {
  UNSUBSCRIBE_ROUTE_PATH,
  pauseUnsubscribePage,
  showUnsubscribePage,
  unsubscribeBodyParser,
  unsubscribePage,
  unsubscribeParserError,
  unsubscribeRateLimiter,
  unsubscribeSecurityHeaders,
} from "./src/unsubscribeRoute.js";
import { registerPublicInfoRoutes } from "./src/publicInfoPages.js";

declare module "express-serve-static-core" {
  interface Application {
    listen(
      port: number | string,
      hostname: string | undefined
    ): import("node:http").Server;
  }
}

// --- Environment validation (fail fast with clear message) ---
const { MONGO_URI, RESEND_API_KEY } = process.env;
const PORT = Number(process.env.PORT || 3000);
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
  console.error("[config] PORT must be a valid TCP port");
  process.exit(1);
}
if (!MONGO_URI?.trim()) {
  console.error("Missing required environment variable: MONGO_URI");
  process.exit(1);
}
if (!isReviewRuntime() && !RESEND_API_KEY?.trim()) {
  console.error("Missing required environment variable: RESEND_API_KEY");
  process.exit(1);
}
const mongoOptions = mongoConnectionOptions(process.env);
if (!mongoOptions.ok) {
  console.error(`[config] ${mongoOptions.error}`);
  process.exit(1);
}
const productionConfigurationError = validateProductionRuntime(process.env);
if (productionConfigurationError) {
  console.error(`[config] ${productionConfigurationError}`);
  process.exit(1);
}
try {
  assertQaBindHostConfiguration();
} catch (error) {
  console.error(
    error instanceof Error ? error.message : "Invalid QA bind configuration"
  );
  process.exit(1);
}
try {
  readClaimTokenHmacSecret();
} catch (error) {
  console.error(
    error instanceof Error ? error.message : "Invalid claim-token HMAC secret"
  );
  process.exit(1);
}
// Required only once public actions are unpaused, and checked here — before the
// Express app exists, before any route is registered, before the database
// connection, and before this process listens — so an unpaused deployment
// cannot accept a signup, confirm an address, send an alert, deliver a digest,
// or serve an unsubscribe link without being able to sign one. The scheduled
// digest is registered above but cannot deliver: its callback needs the event
// loop, and this exit is synchronous. Paused startup reads nothing, so local
// and test processes still start without the secret.
try {
  assertUnsubscribeSigningSecretForActivation();
} catch (error) {
  console.error(
    error instanceof Error
      ? error.message
      : "Invalid unsubscribe signing secret"
  );
  process.exit(1);
}
// Also required only once public actions are unpaused, and checked in the same
// place for the same reason: an installation can already turn push on, and
// "push alerts are on" means this deployment is configured to submit through
// APNs. Without provider configuration that on-state would be true for nobody,
// so provider configuration gates activation instead of being discovered at
// the first send. Paused startup reads none of the four variables.
try {
  assertApnsConfigurationForActivation();
} catch (error) {
  console.error(
    error instanceof Error
      ? error.message
      : "Invalid APNs provider configuration"
  );
  process.exit(1);
}
// Required only once public actions are unpaused, checked in the same place
// for the same reason as the two above (W3-I1). Unpaused means requests can be
// created and claimed, and both now require a participant credential this
// process must be able to sign and verify. Without the secret every
// participant action would fail at its first attempt instead of at boot, and
// nobody could verify an address to begin with. Paused startup reads nothing.
try {
  assertParticipantSigningSecretForActivation();
} catch (error) {
  console.error(
    error instanceof Error
      ? error.message
      : "Invalid participant signing secret"
  );
  process.exit(1);
}
try {
  assertParticipantIdentityCredentialsForActivation();
} catch {
  console.error("[config] participant identity credentials unavailable");
  process.exit(1);
}

// init Resend (email API)
const resendApiKey = process.env.RESEND_API_KEY;
const resend = new Resend(isReviewRuntime() ? "review-disabled" : resendApiKey);

// init express
const app = express();
// Security headers
app.use(helmet());
const reviewBoundary = registerReviewRuntimeIntegration(app, {
  connection: mongoose.connection,
  validateProductionRuntime,
  registerReviewBoundary,
  isRuntimeReady: () => runtimeReady,
});
// If the app is running behind a proxy (Render, Heroku, etc.) we should
// enable Express's `trust proxy` so middleware like express-rate-limit can
// correctly identify the client's IP from the X-Forwarded-For header.
// Control via env var TRUST_PROXY (set to '1' or 'true'). Default: enable
// in production environments.
const trustProxyEnv = (process.env.TRUST_PROXY || '').toLowerCase();
if (trustProxyEnv === '1' || trustProxyEnv === 'true' || process.env.NODE_ENV === 'production') {
  app.set('trust proxy', 1);
  console.log('[config] express trust proxy = 1');
}
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Browser confirmation flow for the emailed link. Both halves answer in HTML
// behind route-owned security headers and an HTML pause guard. The GET only
// renders a form and never mutates a Subscriber, because inbox scanners and
// prefetchers fetch links without a person acting; the explicit POST carries
// its own limiter bucket so confirming cannot spend the signup allowance.
//
// Registered ahead of the global body parsers deliberately. A global parser
// runs before route middleware, so a body it rejected would be answered by the
// global JSON error handler — bypassing these headers, the pause guard, and the
// HTML contract, and logging a parser error that can quote the raw token. This
// route parses its own body instead, after the pause and the limiter.
app.get(
  CONFIRMATION_ROUTE_PATH,
  confirmationSecurityHeaders,
  pauseConfirmationPage,
  showConfirmationPage
);
app.post(
  CONFIRMATION_ROUTE_PATH,
  confirmationSecurityHeaders,
  pauseConfirmationPage,
  confirmationRateLimiter,
  confirmationBodyParser,
  confirmSubscriptionPage,
  confirmationParserError
);

// Browser unsubscribe flow for the emailed link, registered alongside the
// confirmation flow, ahead of the global parsers, and for the same reasons.
// Opening the link only renders a form: inbox scanners and prefetchers fetch
// emailed links with nobody acting, so unsubscribing anyone on a GET would
// silence people who merely received an alert. The explicit POST owns the
// mutation and carries its own limiter bucket.
app.get(
  UNSUBSCRIBE_ROUTE_PATH,
  unsubscribeSecurityHeaders,
  pauseUnsubscribePage,
  showUnsubscribePage
);
app.post(
  UNSUBSCRIBE_ROUTE_PATH,
  unsubscribeSecurityHeaders,
  pauseUnsubscribePage,
  unsubscribeRateLimiter,
  unsubscribeBodyParser,
  unsubscribePage,
  unsubscribeParserError
);

// Static GoodGrub public information pages (W4-T1): read-only, no database.
registerPublicInfoRoutes(app);

// api: participant verification (W3-I1). Registered here, ahead of the global
// parsers, alongside the two emailed-link flows above and for a stricter
// version of the same reason: this route's body is the one place in the service
// where a raw verification code arrives from the wire, and a body the global
// parser rejected would be answered by the global error handler, which logs the
// parser error — and a parser error quotes the body. The focused production
// registration function owns both complete middleware chains; the real-byte
// HTTP tests invoke that same function.
//
// Both halves are paused ahead of their limiters, parsers, and handlers, so a
// paused deployment mails no code, writes no challenge, and issues no
// participant authority — nobody may become verified for actions that are
// themselves refused. Separate limiter buckets keep submitting a code from
// spending the allowance for requesting one.
registerParticipantVerificationRoutes(app);

// api: participant-authorized email-alert unsubscribe (W3-N2). Registered
// alongside participant verification, ahead of the global parsers, for the
// same body-shape reason: there is no body to parse for this route, but pause
// and the participant-authority gate must still run before any global
// middleware could otherwise see the request.
registerParticipantEmailUnsubscribeRoute(app);

// api: W4-P2 account deletion (Checkpoint 8). Registered alongside the other
// participant-authority routes, ahead of the global parsers, for the same
// pause/authority-before-body reason.
registerParticipantDeletionRoutes(app);

// api: W4-S1 non-authoritative AI screenshot proposal. Registered ahead of
// the global parsers for the same reason as the two routes above, plus one
// more: this route needs a larger body limit than the global 100 KB parser
// for a normalized screenshot, so it owns its own bounded JSON parser rather
// than widening the shared one every other route uses.
registerScreenshotProposalRoute(app);

// api: W4-H1a fulfillment, which now carries one base64 placed-order screenshot
// and therefore needs a larger body limit than the global 100 KB parser. The
// route owns a bounded 3 MB parser and is registered ahead of the global
// parsers for the same reason as the S1 route above: a global parser would
// refuse the body first, answering through the global error handler. A valid
// active claim is still the only authorization for placement. This route is
// intentionally not exposed through the disabled legacy web ordering UI, and is
// not paused by PUBLIC_ACTIONS_PAUSED.
registerFulfillmentRoute(app);

// api: W4-R3 private requester reads, evidence bytes, and pickup confirmation.
// Registered ahead of the shared parsers so authority and cache isolation run
// before any request-dependent handler work.
registerPlacedOrderRoutes(app);

// api: W4-N1 requester email to the helper holding the live reservation,
// behind the same participant authority, cache isolation and limiter.
registerHelperReservationContactRoute(app);

// api: W4-D2 exact-operation terminal reconciliation for an already-issued
// request-create operation, and the ledger authority identity a create
// records. Registered ahead of the global parsers for the same reason as the
// participant-authorized routes above: the terminal route takes no body, and a
// malformed or oversized one must not reach the global parser and error
// handler before its cache isolation, pause, limiter, and participant
// authority run. Their order is owned by the registration function.
registerRequestOperationTerminalRoute(app);

// W4-U1.2 CP3: report submission owns its bounded parser and sanitized parser
// failures; the private moderator surface is mounted only with valid config.
// Both route groups precede the global parsers so private report content and
// moderator form values cannot reach the generic error logger.
registerReportRoutes(app);
registerModerationRoutes(app);

// middleware to parse JSON and serve static files
app.use(express.json({ limit: '100kb' }));
app.use(express.urlencoded({ extended: true, limit: '100kb' }));
app.use(createProductionLegacyWebPageGuard());
app.use(express.static(path.join(process.cwd(), "public")));

// rate limiting middleware - apply only to form endpoints
// Request creation has its own bucket (`createRequestRateLimiter`) so that its
// refusal can carry the structured error envelope iOS needs; this one now
// covers subscribe alone.
const limiter = rateLimit({ windowMs: 60_000, max: 5 }); // up to 5/min/IP

registerHealthRoutes(
  app,
  () => runtimeReady && mongoose.connection.readyState === 1 && reviewBoundary.isReady()
);

// serve home page
app.get("/", (req: Request, res: Response) => {
  res.sendFile(path.join(process.cwd(), "public", "home.html"));
});

// serve new request form
app.get("/request/new", (req: Request, res: Response) => {
  res.sendFile(path.join(process.cwd(), "public", "new-request.html"));
});

// Read-only pause state for the web pages, which cannot read server
// environment values. Carries no configuration detail beyond the decision
// itself; the pages fail closed if this request does not succeed.
app.get("/api/public-actions", (req: Request, res: Response) => {
  res.json({ paused: isPublicActionsPaused() });
});

// api: subscribe to digest emails (creates a pending Subscriber and sends confirmation)
// The pause runs ahead of the limiter so no subscriber is created or confirmed,
// no confirmation email is sent, and no recent-request alerts are dispatched.
app.post('/api/subscribe', pausePublicAction(SUBSCRIBE_UNAVAILABLE_MESSAGE), limiter, subscribe);

// api: synchronize one app installation's complete current push state
// (Week 3 Day 6 Slice 6A.1). This declares on/off and, when on, the current
// APNs token; it sends no notification. The pause runs ahead of the limiter
// and the handler so a paused request performs no credential hashing,
// installation lookup, or mutation.
app.put(
  INSTALLATION_PUSH_ROUTE_PATH,
  pausePublicAction(INSTALLATION_PUSH_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
  installationPushRateLimiter,
  synchronizeInstallationPush
);

// serve fulfill page for a specific request
app.get("/request/:id/fulfill", (req: Request, res: Response) => {
  res.sendFile(path.join(process.cwd(), "public", "fulfill.html"));
});

// api: get all active requests
app.get("/api/requests", getPublicRequestList);

// api: get single request by id
app.get("/api/request/:id", getPublicRequestDetail);

// api: get stats (total meals shared)
app.get("/api/stats", getStats);

// api: get count of active (confirmed, not bounced) subscribers
app.get("/api/active-subscriber-count", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const count = await Subscriber.countDocuments({ status: "confirmed", bounced: false });
    res.json({ count });
  } catch (err) {
    next(err);
  }
});

// api: create a new meal request
// The pause runs ahead of the limiter and the handler so a paused create
// performs no validation side effect, sends no confirmation email, writes no
// request, and notifies no subscribers. Nobody may post a meal that nobody
// can fulfill while the fulfillment path is unavailable.
// The limiter refuses before validation, email, and the write, so a throttled
// attempt is a definitive no-write outcome. It answers with the structured
// `RATE_LIMITED` envelope rather than a plain-string body, because iOS must be
// able to tell that refusal apart from an unreadable response on a
// non-idempotent POST — see "Definitive versus ambiguous create failures".
app.post("/api/request", pauseRequestAction(CREATE_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"), createRequestRateLimiter, createRequest);

// Claim mutations are paused before their independent rate-limit buckets and
// before token generation or database work.
app.post(
  CLAIM_ROUTE_PATH,
  pauseDay4Mutation,
  claimRateLimiter,
  claimRequest
);
app.post(
  CLAIM_EXTENSION_ROUTE_PATH,
  pauseDay4Mutation,
  claimExtensionRateLimiter,
  extendClaim
);
app.post(
  CLAIM_RELEASE_ROUTE_PATH,
  pauseDay4Mutation,
  claimReleaseRateLimiter,
  releaseClaim
);

// W4-U1.3 participant blocking. Block and Unblock are safety controls and are
// deliberately NOT behind `pauseDay4Mutation` (accepted 2026-10-13
// operational-pause clarification): `PUBLIC_ACTIONS_PAUSED` governs only the
// mutations it explicitly names. The one pause-governed part is reservation
// release, which `createParticipantBlock` checks itself for the `No` branch so
// that Block and release commit together or not at all.
app.post(
  REQUEST_BLOCK_ROUTE_PATH,
  createParticipantBlockRateLimiter,
  createParticipantBlock
);
app.get(
  PARTICIPANT_BLOCKS_ROUTE_PATH,
  listParticipantBlocksRateLimiter,
  listParticipantBlocks
);
app.delete(
  PARTICIPANT_BLOCK_ROUTE_PATH,
  deleteParticipantBlockRateLimiter,
  deleteParticipantBlock
);

// A read of the caller's own already-granted reservation truth (W3-H1
// continuation), not a new mutation, so it is not paused by
// `PUBLIC_ACTIONS_PAUSED` — matching `GET /api/request/:id` above.
app.get(
  ACTIVE_RESERVATION_ROUTE_PATH,
  activeReservationRateLimiter,
  getActiveReservation
);

// W4-N0: a read of the caller's own current Email Request Alert state, not a
// new mutation, so it is not paused by `PUBLIC_ACTIONS_PAUSED` — matching
// `GET /api/participant/active-reservation` immediately above.
app.get(
  EMAIL_ALERT_STATE_ROUTE_PATH,
  emailAlertStateRateLimiter,
  getEmailAlertState
);

// W4-Q1: a read of the caller's own current request-creation eligibility
// under the shared daily quota authority, not a new mutation, so it is not
// paused by `PUBLIC_ACTIONS_PAUSED` — matching
// `GET /api/participant/email-alerts/state` immediately above.
// The middleware ordering itself (cache isolation ahead of the rate limiter
// and handler) is single-sourced in `buildRequestEligibilityMiddlewareChain`
// so this registration cannot silently drift from the mounted rate-limit
// proof in `requestEligibilityRoute.test.ts`.
app.get(
  REQUEST_ELIGIBILITY_ROUTE_PATH,
  ...buildRequestEligibilityMiddlewareChain(
    requestEligibilityRateLimiter,
    getRequestEligibility
  )
);

// W4-R5 owner reads: a read of the caller's own ongoing requests, not a new
// mutation, so not paused by `PUBLIC_ACTIONS_PAUSED`. Registered by its own
// module, which also owns the cache-isolation-then-limiter ordering.
registerOwnerRequestReadRoutes(app);

// W4-R5 Edit and Withdraw of the caller's own request: owner-authorized atomic
// conditional mutations with their own recovery ledger. Registered by their own
// module (which owns the cache-isolation-then-limiter ordering); neither is on
// the enumerated `PUBLIC_ACTIONS_PAUSED` list.
registerRequestUpdateRoutes(app);

// The fulfillment route (`registerFulfillmentRoute`) is registered above,
// ahead of the global body parsers.

// ---- node-cron: cleanup expired documents (backup to TTL) ----
// Runs every hour to delete expired requests
if (process.env.CRON_ENABLED === 'true') {
  scheduleAppJob("0 * * * *", async () => {
    try {
      const now = new Date();
      const result = await MealRequest.deleteMany({ deleteAt: { $lte: now } });
      console.log(`[cron] Deleted ${result.deletedCount} expired requests at ${now.toISOString()}`);
    } catch {
      console.error("[cron] expired-request cleanup failed");
    }
  });
} else {
  console.log('[cron] disabled — set CRON_ENABLED=true to enable scheduled cleanup');
}

// A request whose helper eligibility begins after its creation — a future Later
// request (W3-R1) — is deliberately not dispatched for at creation. This is
// what starts the existing helper email and push lifecycle at its `visibleFrom`
// instead. Registered independently of `CRON_ENABLED`, like the digest and the
// other notification jobs, because it is not a cleanup backup: without it those
// requests are never notified about at all.
scheduleEligibilityNotificationSweep({
  enabled: schedulerEnabled,
  isReady: () => runtimeReady,
});

// W4-N1 Increment B: the one additional T-15 closing-soon discovery
// notification. Independent cron job, independent one-shot latch
// (`closingSoonNotification`) — see `src/closingSoonNotificationSweep.ts`.
scheduleClosingSoonNotificationSweep({
  enabled: schedulerEnabled,
  isReady: () => runtimeReady,
});

// ---- error handler (must be last) ----
app.use((err: Error, req: Request, res: Response, _next: NextFunction) => {
  console.error("[http] request failed");
  res.status(500).json({ error: "Internal server error" });
});

// connect to db and start server
let startupStage = "Atlas connection";
try {
  await mongoose.connect(MONGO_URI, mongoOptions.options);
  startupStage = "MongoDB transaction capability";
  await assertMongoTransactionsSupported(mongoose.connection);
  startupStage = "participant identity index migration";
  await assertParticipantIdentityIndexesMigrated(
    new Map([
      ["requestparticipations", RequestParticipation.collection],
      ["participantblocks", ParticipantBlock.collection],
    ])
  );
  startupStage = "required index setup";
// Do not accept placement traffic until the database has established the
// one-request/one-ledger-record uniqueness guarantee. Existing duplicates make
// this fail visibly at startup instead of weakening the contract.
await Fulfillment.createIndexes();
// Same for the placed-order evidence row (W4-H1a): its unique requestId index is
// the database-level backstop that one Request can never hold two screenshots,
// whatever a resend or a race attempts.
await PlacementEvidence.createIndexes();
// Do not accept installation push-state traffic until the database has
// established the single-eligible-owner-per-token guarantee that the
// installation push route relies on instead of a race-prone read-then-write.
await Installation.createIndexes();
// Do not submit a push notification until the database has established the
// (requestId, installationId, purpose) uniqueness the dispatcher claims
// against: without it, two concurrent dispatches would both submit for the
// same installation, and V1 has no retry path that could repair a duplicate.
await PushDelivery.createIndexes();
// Do not accept participant traffic until the database has established the
// one-participant-per-address and one-live-challenge-per-address guarantees
// (W3-I1). Without them two concurrent verifications could create two
// Participant rows for one principal, and a resend could leave two working
// codes live for one inbox instead of superseding the first.
await Participant.createIndexes();
await ParticipantVerification.createIndexes();
await ParticipantIdentityKeyVersion.createIndexes();
// The dormant P2 commands also depend on permanent operation identity and
// one-active-operation uniqueness. Fail startup if either cannot be installed.
await ParticipantDeletionOperation.createIndexes();
// Do not accept claim traffic until the database has established the
// one-successful-participation-per-(request, participant) uniqueness
// guarantee (W3-H2). Without it, `claimRequest`'s pre-check and insert are
// only a best-effort race guard, not a durable invariant.
await RequestParticipation.createIndexes();
// Do not accept block traffic until the one-owned-block-per-(owner, target)
// uniqueness (W4-U1.3) is established: it is what makes a repeated Block an
// idempotent no-op rather than a second row.
await ParticipantBlock.createIndexes();
// Establish the moderation collections' unique and TTL indexes (W4-U1.2)
// before anything can write to them. Rejects, and so stops startup before
// listening, if any cannot be established.
await establishModerationIndexes();
// W4-U1.2 retention verifier, scheduled only now that the database is connected
// and the moderation indexes exist, so a run can never race startup. Registered
// independently of `CRON_ENABLED` and without reading `PUBLIC_ACTIONS_PAUSED`:
// it verifies a privacy promise rather than backing up an optional cleanup. It
// reads, writes and deletes only moderation collections.
scheduleModerationRetentionSweep();
// P2 completion receipts have a fixed seven-day lifetime. Scrub their private
// recovery fields independently of optional application jobs, after Mongo is
// connected and the deletion-operation indexes have been established.
scheduleParticipantDeletionReceiptSweep();
// Do not accept request-create or terminal-reconciliation traffic until the
// database has established the unique operation-identity index that makes a
// created operation and a terminal NO-CREATE one-winner (W3-D1/W4-D2), and the
// ledger authority identity clients record with a pending create. Rejects —
// and so stops startup before listening — if either cannot be established.
await establishRequestOperationLedger();
startupStage = "review runtime initialization";
await reviewBoundary.initialize();
} catch {
  console.error(`[startup] ${startupStage} failed; process will not listen`);
  process.exit(1);
}
// QA_BIND_HOST is validated at startup (assertQaBindHostConfiguration) and is
// accepted only as 127.0.0.1 inside the disposable local QA runtime.
const HOST = process.env.QA_BIND_HOST || process.env.HOST || "0.0.0.0";
runtimeReady = true;
const server = app.listen(PORT, HOST, () => {
  const PUBLIC_BASE = process.env.BASE_URL || `http://localhost:${PORT}`;
  console.log(`[startup] ready on ${PUBLIC_BASE}`);
});
server.on("error", () => {
  runtimeReady = false;
  console.error("[startup] HTTP listener failed");
  process.exit(1);
});
