import express, {
  type Express,
  type NextFunction,
  type Request,
  type Response,
} from "express";
import { z } from "zod";
import { isStrictBase64, isStructurallyValidImage } from "./imageStructure.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  pausePublicAction,
  PUBLIC_ACTIONS_PAUSED_ENV,
} from "./publicActionsPause.js";
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import {
  callScreenshotProvider,
  type ProviderCallResult,
} from "./screenshotProposalProvider.js";
import { validateProviderOutput } from "./screenshotProposalValidation.js";
import { evaluateEligibility } from "./screenshotEligibility.js";
import type { ScreenshotProposalResponseBody } from "./screenshotProposalTypes.js";

/**
 * W4-S1 non-authoritative proposal boundary. Deliberately not
 * `/api/request` or any `/api/request/:id/...` path: this route can never
 * call `createRequest`, mint/consume an operation identity, or touch
 * `RequestOperation`/D1, and a distinct path keeps that true by
 * construction rather than by handler discipline alone.
 */
export const SCREENSHOT_PROPOSAL_ROUTE_PATH = "/api/request/screenshot-proposal";

export const SCREENSHOT_ASSISTANCE_UNAVAILABLE_CODE = "SCREENSHOT_ASSISTANCE_UNAVAILABLE";
export const SCREENSHOT_ASSISTANCE_UNAVAILABLE_MESSAGE =
  "Screenshot assistance is unavailable. You can still fill out the form manually.";

interface ScreenshotProposalTestOptions {
  /** Only explicit in-process tests may exercise the preserved implementation. */
  enableForTests?: boolean;
}

function refuseExcludedScreenshotAssistance(res: Response): Response {
  return sendDay4Error(
    res,
    503,
    SCREENSHOT_ASSISTANCE_UNAVAILABLE_CODE,
    SCREENSHOT_ASSISTANCE_UNAVAILABLE_MESSAGE
  );
}

export const IMAGE_PROPOSAL_UNAVAILABLE_MESSAGE =
  "AI screenshot assistance is temporarily unavailable";

export const INVALID_IMAGE_CODE = "INVALID_IMAGE";
/** W4-R4: up to five screenshots may be submitted as evidence for one
 * logical order, so this no longer says "a single". */
export const INVALID_IMAGE_MESSAGE =
  "Choose up to 5 supported screenshot images.";

export const PROVIDER_UNAVAILABLE_CODE = "PROVIDER_UNAVAILABLE";
export const PROVIDER_UNAVAILABLE_MESSAGE =
  "We couldn’t analyze that screenshot right now. You can still fill out the form manually.";

export const PROPOSAL_FAILED_CODE = "SCREENSHOT_PROPOSAL_FAILED";
export const PROPOSAL_FAILED_MESSAGE =
  "We couldn’t analyze that screenshot. You can still fill out the form manually.";

/**
 * A single normalized screenshot, base64-encoded. iOS performs local
 * normalization (resize/compress) before upload (engineering-owned exact
 * dimensions/quality); this is still an explicit, bounded server-side cap —
 * independent of what any client claims to have sent — rather than trusting
 * client-side normalization alone.
 */
const MAX_IMAGE_BYTES = 5_000_000;

/**
 * W4-R4: the exact number of screenshots this route accepts as evidence for
 * one logical Grubhub order. Enforced here, server-side, independent of what
 * any client claims to have selected — a sixth image is refused
 * deterministically rather than silently dropped, so a requester is never
 * told an analysis covered evidence it never saw.
 */
export const MAX_SCREENSHOT_IMAGES = 5;

/**
 * The explicit bounded image transport this route owns, separate from the
 * 100 KB global JSON parser (`app.ts`) request-create and every other route
 * shares. Registered ahead of the global parser, exactly like
 * `registerParticipantVerificationRoutes`, so this route's own limit is what
 * actually governs its body rather than the global one rejecting it first.
 *
 * W4-R4 raises this from the single-image 7 MB ceiling to hold up to five
 * normalized screenshots plus their base64 expansion; `MAX_IMAGE_BYTES`
 * still bounds each individual decoded image.
 */
const SCREENSHOT_BODY_LIMIT = "34mb";

/**
 * Bounded so a caller cannot use this field to smuggle an arbitrarily large
 * payload past the image size cap. A real screenshot's on-device Vision OCR
 * transcription is a few hundred to a few thousand characters at most.
 */
const MAX_LOCAL_EVIDENCE_TEXT_LENGTH = 20_000;

const totalGeometryObservationSchema = z.discriminatedUnion("classification", [
  z.object({
    id: z.number().int().min(0).max(20_000),
    classification: z.literal("total-label"),
    geometryValid: z.boolean(),
  }).strict(),
  z.object({
    id: z.number().int().min(0).max(20_000),
    classification: z.literal("amount"),
    cents: z.number().int().min(0).max(999_999),
    geometryValid: z.boolean(),
  }).strict(),
]);

const totalGeometryEvidenceSchema = z.object({
  observations: z.array(totalGeometryObservationSchema).max(512),
  relations: z.array(z.object({
    totalObservationID: z.number().int().min(0).max(20_000),
    amountObservationID: z.number().int().min(0).max(20_000),
    sameRow: z.boolean(),
    rightOf: z.boolean(),
  }).strict()).max(4_096),
}).strict();

/**
 * One selected screenshot and its own independent on-device evidence.
 * Evidence is per image, not per request: eligibility is decided for each
 * screenshot separately, so one unsupported image in a set cannot borrow
 * another's eligibility and an ineligible image is never forwarded to the
 * provider.
 */
const screenshotImageSchema = z
  .object({
    imageBase64: z.string().min(1),
    mimeType: z.enum(["image/jpeg", "image/png"]),
    /**
     * On-device Apple Vision OCR transcription of this exact screenshot —
     * a different engine than the OpenAI provider below, produced and sent
     * before that provider is ever called. This is the sole eligibility and
     * meal-swipe-corroboration evidence source; the provider's own output is
     * never used to validate itself. May be empty (an illegible/blank
     * image), which the eligibility rule below simply rejects.
     */
    localEvidenceText: z.string().max(MAX_LOCAL_EVIDENCE_TEXT_LENGTH),
    /** Complete privacy-safe relation evidence derived from this image's
     * transient Vision boxes. Coordinates are never accepted by this route. */
    localTotalGeometry: totalGeometryEvidenceSchema.optional(),
  })
  .strict();

/**
 * W4-R4: 1 to 5 screenshots, which are evidence for ONE logical order rather
 * than several independent analyses. `.strict()` and the explicit `max`
 * together mean a sixth image is a structural refusal, never a silent trim.
 */
const screenshotProposalBodySchema = z
  .object({
    images: z
      .array(screenshotImageSchema)
      .min(1)
      .max(MAX_SCREENSHOT_IMAGES),
  })
  .strict();

/** Finite bound (engineering-owned): a screenshot analysis attempt must
 * resolve or fail within this window rather than leaving the requester's
 * manual form blocked on the network. */
const PROVIDER_TIMEOUT_MS = 20_000;

/**
 * Every provider failure kind (auth/rate_limit/server/timeout/parse/unknown)
 * degrades identically for the requester — the form stays fully
 * manual-usable — so this returns one fixed refusal regardless of kind. The
 * distinction is preserved separately for content-free operational
 * analytics (`logProposalOutcome`'s `detail` argument), never for a
 * different requester-facing message.
 */
function classifyProviderFailure(
  _result: ProviderCallResult
): { status: number; code: string; message: string } {
  return {
    status: 503,
    code: PROVIDER_UNAVAILABLE_CODE,
    message: PROVIDER_UNAVAILABLE_MESSAGE,
  };
}

/**
 * Content-free operational analytics only (contract: no raw screenshot, OCR
 * output, or provider request/response content may ever be logged). Every
 * argument here is a closed classification value, never extracted text,
 * venue text, food items, or provider JSON.
 */
function logProposalOutcome(
  outcome: "eligible" | "ineligible" | "provider_error" | "invalid_output",
  detail?: string
): void {
  console.log(
    `[screenshot-proposal] ${outcome}${detail ? ` (${detail})` : ""}`
  );
}

export async function handleScreenshotProposal(
  req: Request,
  res: Response,
  options: ScreenshotProposalTestOptions = {}
): Promise<Response> {
  if (options.enableForTests !== true) {
    return refuseExcludedScreenshotAssistance(res);
  }

  // Participant authority first: an unverified caller triggers no image
  // decoding, no provider call, and learns nothing about whether its image
  // would otherwise have been accepted — the same ordering every other
  // gated mutation in this repository uses.
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const parsedBody = screenshotProposalBodySchema.safeParse(req.body);
  if (!parsedBody.success) {
    return sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
  }

  // Every image is structurally validated before any of them is analyzed: a
  // set containing one malformed image is refused as a whole rather than
  // quietly analyzed without it, so the requester is never shown a result
  // that silently covered less evidence than they chose.
  for (const image of parsedBody.data.images) {
    if (!isStrictBase64(image.imageBase64)) {
      return sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
    }

    let imageBuffer: Buffer;
    try {
      imageBuffer = Buffer.from(image.imageBase64, "base64");
    } catch {
      return sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
    }

    if (
      imageBuffer.length === 0 ||
      imageBuffer.length > MAX_IMAGE_BYTES ||
      !isStructurallyValidImage(imageBuffer, image.mimeType)
    ) {
      return sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
    }
  }

  // Independent eligibility gate, evaluated from on-device Vision OCR text
  // ONLY — never from anything the provider below could say. Applied per
  // image, so an ineligible screenshot is never forwarded to OpenAI even
  // when it arrives alongside eligible ones, and no provider claim can
  // reverse this decision.
  const eligibleImages = parsedBody.data.images.filter(
    (image) => evaluateEligibility(image.localEvidenceText).eligible
  );
  if (eligibleImages.length === 0) {
    logProposalOutcome("ineligible");
    const body: ScreenshotProposalResponseBody = { eligible: false, proposal: {} };
    return res.status(200).json(body);
  }

  // The corroboration evidence for this one logical order: the combined
  // independent OCR text of exactly the images that will actually be sent.
  // An ineligible image contributes neither bytes nor evidence.
  const combinedEvidenceText = eligibleImages
    .map((image) => image.localEvidenceText)
    .join("\n");

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    // Fail closed: missing provider configuration is not a signal to skip
    // straight to "no useful extraction" as if the provider legitimately
    // found nothing — the requester is told analysis is unavailable, and
    // manual entry remains the answer either way.
    console.error(
      "[screenshot-proposal] OPENAI_API_KEY is not configured"
    );
    return sendDay4Error(
      res,
      503,
      PROVIDER_UNAVAILABLE_CODE,
      PROVIDER_UNAVAILABLE_MESSAGE
    );
  }

  // One call carrying every eligible image, not one call per image: they are
  // evidence for one order, and analyzing them jointly is what lets the
  // provider describe that single order instead of returning several
  // independent results a caller would then have to merge.
  const providerResult = await callScreenshotProvider({
    images: eligibleImages.map((image) => ({
      imageBase64: image.imageBase64,
      mimeType: image.mimeType,
    })),
    apiKey,
    timeoutMs: PROVIDER_TIMEOUT_MS,
  });

  if (!providerResult.ok) {
    logProposalOutcome("provider_error", providerResult.errorKind);
    const failure = classifyProviderFailure(providerResult);
    return sendDay4Error(res, failure.status, failure.code, failure.message);
  }

  const validation = validateProviderOutput(
    providerResult.rawJson,
    combinedEvidenceText,
    eligibleImages.length,
    eligibleImages.map((image) => image.localEvidenceText),
    eligibleImages.map((image) => image.localTotalGeometry)
  );
  if (!validation.ok) {
    // The provider returned a well-formed HTTP response but content this
    // service cannot trust as proposal authority (forbidden field, wrong
    // shape). Never surfaced as raw output to iOS, logs, or storage — only
    // the classification.
    logProposalOutcome("invalid_output", validation.reason);
    return sendDay4Error(
      res,
      503,
      PROPOSAL_FAILED_CODE,
      PROPOSAL_FAILED_MESSAGE
    );
  }

  logProposalOutcome("eligible");

  const body: ScreenshotProposalResponseBody = {
    eligible: true,
    proposal: validation.proposal,
  };
  return res.status(200).json(body);
}

/**
 * Final error boundary for this route's body parser
 * (`express.json({ limit: SCREENSHOT_BODY_LIMIT })` below). A malformed or
 * oversized body makes `express.json` call `next(err)` instead of running
 * the handler; without this, that error would fall through to the global
 * error handler in `app.ts`, which logs the error object — and a body-parser
 * `SyntaxError` can carry a slice of the raw request body, which for this
 * route may contain screenshot/OCR content. Mirrors
 * `confirmationParserError` (`confirmSubscriptionRoute.ts`): nothing about
 * the error is ever logged, only the same structured `INVALID_IMAGE`
 * refusal a request this route rejected for any other shape reason would
 * get.
 */
export function screenshotProposalParserError(
  error: unknown,
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (res.headersSent) {
    next(error);
    return;
  }
  sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
}

/**
 * Registered ahead of the global JSON parser (`app.ts`), like
 * `registerParticipantVerificationRoutes` — this route owns its complete
 * middleware chain, including a body-size limit sized for a normalized
 * screenshot rather than the 100 KB shared by every other route.
 */
export function registerScreenshotProposalRoute(
  app: Express,
  options: ScreenshotProposalTestOptions = {}
): void {
  const enableForTests = options.enableForTests === true;
  app.post(
    SCREENSHOT_PROPOSAL_ROUTE_PATH,
    (_req: Request, res: Response, next: NextFunction) => {
      if (!enableForTests) {
        refuseExcludedScreenshotAssistance(res);
        return;
      }
      next();
    },
    // A discretionary AI side-feature that sends bytes off-device is exactly
    // the kind of surface an incident response should be able to shut off
    // independent of ordinary request creation; fails closed with every
    // other public action when `PUBLIC_ACTIONS_PAUSED_ENV` is unset.
    pausePublicAction(IMAGE_PROPOSAL_UNAVAILABLE_MESSAGE, PUBLIC_ACTIONS_PAUSED_ENV),
    screenshotProposalRateLimiter,
    express.json({ limit: SCREENSHOT_BODY_LIMIT }),
    (req: Request, res: Response) => handleScreenshotProposal(req, res, { enableForTests }),
    // Error-handling middleware (4 args) is matched by arity, not position:
    // Express skips forward to it from wherever `next(err)` was called
    // within this same route's chain, exactly like
    // `confirmationParserError`'s registration in `app.ts`.
    screenshotProposalParserError
  );
}

export const screenshotProposalRateLimiter = createDay4MutationRateLimiter(10);
