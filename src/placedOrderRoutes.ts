import mongoose, { Types } from "mongoose";
import type { Express, NextFunction, Request, Response } from "express";
import {
  Fulfillment,
  Participant,
  PlacementEvidence,
  Request as MealRequest,
} from "../models/db.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { isParticipantPairFenced } from "./participantBlocks.js";
import {
  ETA_MINUTES,
  estimatedReadyAt,
  placedHomeVisibility,
  reportPlacedHomeInvariantFailure,
} from "./placedHomeVisibility.js";
import {
  mapPublicRequestFields,
  type PublicRequestDocument,
} from "./requestListResponse.js";
import { startHelperPickupConfirmedPush } from "./helperPickupConfirmedPush.js";

export const PLACED_ORDER_LIST_ROUTE_PATH = "/api/participant/placed-orders";
export const PLACED_ORDER_DETAIL_ROUTE_PATH =
  "/api/participant/placed-orders/:requestId";
export const HELPER_PLACEMENT_CONTACT_ROUTE_PATH =
  "/api/participant/helper-placements/:requestId/contact";
export const PLACED_ORDER_EVIDENCE_ROUTE_PATH =
  "/api/participant/placed-orders/:requestId/evidence";
export const PICKUP_CONFIRMATION_ROUTE_PATH =
  "/api/participant/placed-orders/:requestId/pickup-confirmation";

export const PLACED_ORDER_NOT_FOUND_CODE = "PLACED_ORDER_NOT_FOUND";
export const PLACED_ORDER_NOT_FOUND_MESSAGE =
  "This placed order is unavailable.";
export const PLACED_ORDERS_UNAVAILABLE_CODE = "PLACED_ORDERS_UNAVAILABLE";
export const PLACED_ORDERS_UNAVAILABLE_MESSAGE =
  "Placed orders are temporarily unavailable.";
export const PLACED_ORDER_EVIDENCE_UNAVAILABLE_CODE =
  "PLACED_ORDER_EVIDENCE_UNAVAILABLE";
export const PLACED_ORDER_EVIDENCE_UNAVAILABLE_MESSAGE =
  "The order confirmation is temporarily unavailable.";
export const PICKUP_CONFIRMATION_UNAVAILABLE_CODE =
  "PICKUP_CONFIRMATION_UNAVAILABLE";
export const PICKUP_CONFIRMATION_UNAVAILABLE_MESSAGE =
  "Pickup confirmation is temporarily unavailable.";

const orderNumberFormat = /^[0-9]{1,50}$/;

export const placedOrderReadRateLimiter = createDay4MutationRateLimiter(30);
export const pickupConfirmationRateLimiter =
  createDay4MutationRateLimiter(10);

interface PlacedOrderDocument extends PublicRequestDocument {
  _id: Types.ObjectId;
  orderNumber?: string | null;
  etaText?: string | null;
  placedAt?: Date | string | null;
  deleteAt?: Date | string | null;
  requesterPickupConfirmedAt?: Date | string | null;
  requesterParticipantId?: Types.ObjectId | null;
  helperParticipantId?: Types.ObjectId | null;
  fulfillerEmail?: string | null;
}

function setPrivateHeaders(res: Response): void {
  res.setHeader("Cache-Control", "private, no-store");
  res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);
}

export function placedOrderCacheIsolation(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  setPrivateHeaders(res);
  next();
}

function sendPlacedOrderNotFound(res: Response): Response {
  return sendDay4Error(
    res,
    404,
    PLACED_ORDER_NOT_FOUND_CODE,
    PLACED_ORDER_NOT_FOUND_MESSAGE
  );
}

function sendPlacedOrdersUnavailable(res: Response): Response {
  return sendDay4Error(
    res,
    503,
    PLACED_ORDERS_UNAVAILABLE_CODE,
    PLACED_ORDERS_UNAVAILABLE_MESSAGE
  );
}

function safeEtaText(value: string | null | undefined): string | null {
  return typeof value === "string" &&
    Object.prototype.hasOwnProperty.call(ETA_MINUTES, value)
    ? value
    : null;
}

function isValidOrderNumber(value: unknown): value is string {
  if (typeof value !== "string" || value.length < 1 || value.length > 50) {
    return false;
  }
  return orderNumberFormat.exec(value)?.[0] === value;
}

function buildPlacedOrderFields(
  document: PlacedOrderDocument
) {
  if (!isValidOrderNumber(document.orderNumber)) {
    console.error("[route] Placed-order fulfillment invariant failed");
    throw new Error("Placed-order fulfillment invariant failed");
  }
  const mapped = mapPublicRequestFields({
    ...document,
    status: "placed",
  });
  const acceptedEtaText = safeEtaText(document.etaText);
  const readyAt = estimatedReadyAt(document.placedAt, acceptedEtaText);
  if (!readyAt || !document.placedAt) {
    // H1a makes these values required for every supported placement. Keep the
    // read fail-safe and content-free if persisted truth violates that invariant.
    console.error("[route] Placed-order fulfillment invariant failed");
  }
  return {
    ...mapped,
    status: "placed" as const,
    isOwnRequest: true as const,
    orderNumber: document.orderNumber ?? null,
    etaText: acceptedEtaText,
    placedAt: document.placedAt ?? null,
    estimatedReadyAt: readyAt,
    // W4-R3 private requester projection: backend end of the campus day
    // containing `estimatedReadyAt`. Home visibility only, never retention.
    homeVisibleUntil: placedHomeVisibility(document)?.requesterVisibleUntil ?? null,
  };
}

function privateOrderProjection() {
  return [
    "_id",
    "vendor",
    "food",
    "pickupWindowText",
    "mealSwipes",
    "menuPath",
    "mealItems",
    "orderDetails",
    "estimatedDiningDollarsCents",
    "windowStart",
    "windowEnd",
    "status",
    "createdAt",
    "expiresAt",
    "orderNumber",
    "etaText",
    "placedAt",
    "deleteAt",
  ].join(" ");
}

function evidenceBytes(value: unknown): Buffer | null {
  if (Buffer.isBuffer(value)) return value;
  if (typeof value !== "object" || value === null) return null;

  const binary = value as { buffer?: unknown; position?: unknown };
  if (!Buffer.isBuffer(binary.buffer)) return null;
  const length =
    typeof binary.position === "number" &&
    Number.isInteger(binary.position) &&
    binary.position >= 0 &&
    binary.position <= binary.buffer.length
      ? binary.position
      : binary.buffer.length;
  return binary.buffer.subarray(0, length);
}

/**
 * Candidate query for the requester's active pickup obligation: `placed`,
 * retained (`deleteAt` after backend now) and no `requesterPickupConfirmedAt`.
 * Mongo cannot express the campus-day cutoff, so this is only the coarse
 * filter; `classifyPickupObligation` is the second, authoritative half.
 */
export function unfinishedPlacedObligationFilter(
  requesterParticipantId: string,
  now: Date
) {
  return {
    requesterParticipantId: new Types.ObjectId(requesterParticipantId),
    status: "placed" as const,
    requesterPickupConfirmedAt: { $exists: false },
    deleteAt: { $gt: now },
  };
}

export type PickupObligationState = "active" | "expired" | "invalid";

export class PlacedObligationInvariantError extends Error {
  constructor() {
    super("Placed-order fulfillment invariant failed");
    this.name = "PlacedObligationInvariantError";
  }
}

/**
 * W4-R3 asymmetric cleanup: the requester's actionable pickup obligation ends
 * at the earlier of pickup confirmation or `requesterVisibleUntil` (end of the
 * America/New_York day containing `estimatedReadyAt`). Time expiry is purely a
 * classification: it writes nothing and never touches status or retention. The
 * helper's earlier ETA+1h window plays no part.
 *
 * `invalid` is the required-ETA invariant failure: obligation truth cannot be
 * determined, so nothing is fabricated. Requester Home omits it; the B1 seam
 * must fail closed on it and never read it as "no obligation".
 */
export function classifyPickupObligation(
  document: { placedAt?: Date | string | null; etaText?: string | null },
  now: Date
): PickupObligationState {
  const visibility = placedHomeVisibility(document);
  if (!visibility) return "invalid";
  return now.getTime() < visibility.requesterVisibleUntil.getTime()
    ? "active"
    : "expired";
}

/**
 * W4-R3 → W4-B1 handoff check for the email-replacement gate. Read-only. It
 * never catches: an unreadable store, a malformed identity or a placed row with
 * an invalid required ETA rejects, so the consuming gate fails closed and
 * preserves identity. Invalid is never reported as `false`.
 */
export async function hasUnfinishedPlacedPickupObligation(
  participantId: string,
  now: Date
): Promise<boolean> {
  const candidates = await MealRequest.find(
    unfinishedPlacedObligationFilter(participantId, now)
  )
    .select("placedAt etaText")
    .lean()
    .exec();
  const states = candidates.map((candidate) =>
    classifyPickupObligation(candidate, now)
  );
  if (states.includes("active")) return true;
  if (states.includes("invalid")) {
    reportPlacedHomeInvariantFailure();
    throw new PlacedObligationInvariantError();
  }
  return false;
}

/**
 * `GET /api/participant/placed-orders` — the current participant's complete
 * retained, unconfirmed placement set. Membership is resolved only from the
 * persisted requester binding and never from a supplied address or device.
 */
export async function getPlacedOrderList(
  req: Request,
  res: Response
): Promise<Response> {
  setPrivateHeaders(res);
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const serverNow = new Date();
  try {
    const documents = await MealRequest.find(
      unfinishedPlacedObligationFilter(
        authority.participant.participantId,
        serverNow
      )
    )
      .select(privateOrderProjection())
      .sort({ createdAt: -1 })
      .lean()
      .exec();

    // Same classification as the B1 seam, so Home and B1 agree on when the
    // actionable pickup obligation ends. An invalid row is omitted from Home
    // (never fabricated) with the content-free diagnostic.
    const visible = (documents as unknown as PlacedOrderDocument[]).filter(
      (document) => {
        const state = classifyPickupObligation(document, serverNow);
        if (state === "invalid") reportPlacedHomeInvariantFailure();
        return state === "active";
      }
    );

    return res.json({
      orders: visible.map((document) => buildPlacedOrderFields(document)),
      serverNow,
    });
  } catch {
    console.error("[route] Placed-order list lookup failed");
    return sendPlacedOrdersUnavailable(res);
  }
}

async function findOwnedRetainedPlacedOrder(
  requestId: string,
  participantId: string,
  serverNow: Date
): Promise<PlacedOrderDocument | null> {
  const document = await MealRequest.findOne({
    _id: requestId,
    requesterParticipantId: new Types.ObjectId(participantId),
    status: "placed",
    deleteAt: { $gt: serverNow },
  })
    .select(
    `${privateOrderProjection()} requesterParticipantId requesterPickupConfirmedAt helperParticipantId fulfillerEmail`
    )
    .lean()
    .exec();
  return document as unknown as PlacedOrderDocument | null;
}

export async function contactIsDisabledByModeration(
  requesterParticipantId: Types.ObjectId,
  helperParticipantId: Types.ObjectId
): Promise<boolean> {
  // U1.2 owns the private `Participant.suspended` marker. Use the collection
  // boundary so this R3 reader also fails closed on versions where the
  // moderation field is not yet part of the compiled schema.
  const suspended = await Participant.collection.findOne(
    {
      _id: { $in: [requesterParticipantId, helperParticipantId] },
      suspended: true,
    },
    { projection: { _id: 1 } }
  );
  return suspended !== null;
}

/**
 * `GET /api/participant/placed-orders/:requestId` — current owned placement,
 * including its confirmed state for explicit reconciliation, never history.
 */
export async function getPlacedOrderDetail(
  req: Request,
  res: Response
): Promise<Response> {
  setPrivateHeaders(res);
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const requestId = String(req.params.requestId ?? "");
  if (!mongoose.isValidObjectId(requestId)) {
    return sendPlacedOrderNotFound(res);
  }

  const serverNow = new Date();
  let document: PlacedOrderDocument | null;
  try {
    document = await findOwnedRetainedPlacedOrder(
      requestId,
      authority.participant.participantId,
      serverNow
    );
  } catch {
    console.error("[route] Placed-order detail lookup failed");
    return sendPlacedOrdersUnavailable(res);
  }
  if (!document) return sendPlacedOrderNotFound(res);

  let placedOrderFields: ReturnType<typeof buildPlacedOrderFields>;
  try {
    placedOrderFields = buildPlacedOrderFields(document);
  } catch {
    return sendPlacedOrdersUnavailable(res);
  }

  const confirmedAt = document.requesterPickupConfirmedAt ?? null;
  // A confirmed read exists only for reconciliation: the continuation has
  // ended, so the helper address is no longer currently authorized.
  let contactHelperEmail: string | undefined;
  if (
    !confirmedAt &&
    document.fulfillerEmail &&
    document.requesterParticipantId &&
    document.helperParticipantId
  ) {
    try {
      const [pairFenced, contactDisabled] = await Promise.all([
        isParticipantPairFenced(
          document.requesterParticipantId,
          document.helperParticipantId
        ),
        contactIsDisabledByModeration(
          document.requesterParticipantId,
          document.helperParticipantId
        ),
      ]);
      if (!pairFenced && !contactDisabled) {
        contactHelperEmail = document.fulfillerEmail;
      }
    } catch {
      console.error("[route] Placed-order contact restriction check failed");
    }
  }

  return res.json({
    order: {
      ...placedOrderFields,
      pickupConfirmation: confirmedAt
        ? { status: "confirmed", confirmedAt }
        : { status: "pending" },
      ...(contactHelperEmail ? { contactHelperEmail } : {}),
    },
    serverNow,
  });
}

/**
 * `GET /api/participant/placed-orders/:requestId/evidence` — ownership and
 * logical retention are rechecked before the unique private evidence row and
 * its bytes are read.
 */
export async function getPlacedOrderEvidence(
  req: Request,
  res: Response
): Promise<Response> {
  setPrivateHeaders(res);
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const requestId = String(req.params.requestId ?? "");
  if (!mongoose.isValidObjectId(requestId)) {
    return sendPlacedOrderNotFound(res);
  }
  const serverNow = new Date();

  try {
    const ownedOrder = await MealRequest.findOne({
      _id: requestId,
      requesterParticipantId: new Types.ObjectId(
        authority.participant.participantId
      ),
      status: "placed",
      deleteAt: { $gt: serverNow },
    })
      .select("_id")
      .lean()
      .exec();
    if (!ownedOrder) return sendPlacedOrderNotFound(res);

    const evidence = await PlacementEvidence.findOne({
      requestId: new Types.ObjectId(requestId),
      deleteAt: { $gt: serverNow },
    })
      .select("+image mimeType byteLength")
      .lean()
      .exec();
    const image = evidenceBytes(evidence?.image);
    if (
      !evidence ||
      !image ||
      evidence.byteLength !== image.length ||
      (evidence.mimeType !== "image/jpeg" &&
        evidence.mimeType !== "image/png")
    ) {
      console.error("[route] Placed-order evidence invariant failed");
      return sendDay4Error(
        res,
        503,
        PLACED_ORDER_EVIDENCE_UNAVAILABLE_CODE,
        PLACED_ORDER_EVIDENCE_UNAVAILABLE_MESSAGE
      );
    }

    res.setHeader("X-Content-Type-Options", "nosniff");
    res.type(evidence.mimeType);
    return res.send(image);
  } catch {
    console.error("[route] Placed-order evidence lookup failed");
    return sendDay4Error(
      res,
      503,
      PLACED_ORDER_EVIDENCE_UNAVAILABLE_CODE,
      PLACED_ORDER_EVIDENCE_UNAVAILABLE_MESSAGE
    );
  }
}

function sendPickupConfirmationUnavailable(res: Response): Response {
  return sendDay4Error(
    res,
    503,
    PICKUP_CONFIRMATION_UNAVAILABLE_CODE,
    PICKUP_CONFIRMATION_UNAVAILABLE_MESSAGE
  );
}

function pickupConfirmationResponse(
  res: Response,
  requestId: string,
  confirmedAt: Date | string
): Response {
  return res.json({
    requestId,
    pickupConfirmation: {
      status: "confirmed",
      confirmedAt,
    },
  });
}

/**
 * `POST /api/participant/placed-orders/:requestId/pickup-confirmation` — the
 * requester-owned conditional transition. It writes one backend timestamp and
 * leaves the placed lifecycle status and evidence retention untouched.
 */
export async function confirmPlacedOrderPickup(
  req: Request,
  res: Response
): Promise<Response> {
  setPrivateHeaders(res);
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const requestId = String(req.params.requestId ?? "");
  if (!mongoose.isValidObjectId(requestId)) {
    return sendPlacedOrderNotFound(res);
  }

  const serverNow = new Date();
  const ownedRequest = new Types.ObjectId(
    authority.participant.participantId
  );
  let session: mongoose.ClientSession | undefined;
  let confirmedAt: Date | null = null;
  let pushTarget: { helperParticipantId?: Types.ObjectId | null } | null = null;
  try {
    session = await mongoose.startSession();
    await session.withTransaction(async () => {
      confirmedAt = null;
      pushTarget = null;
      const updated = await MealRequest.findOneAndUpdate(
      {
        _id: requestId,
        requesterParticipantId: ownedRequest,
        status: "placed",
        deleteAt: { $gt: serverNow },
        requesterPickupConfirmedAt: { $exists: false },
      },
      { $set: { requesterPickupConfirmedAt: serverNow } },
      { new: true, runValidators: true, session }
    )
      .select("+requesterPickupConfirmedAt +helperParticipantId")
      .lean()
      .exec();
      const timestamp = updated?.requesterPickupConfirmedAt;
      if (timestamp instanceof Date && !Number.isNaN(timestamp.getTime())) {
        confirmedAt = timestamp;
        pushTarget = { helperParticipantId: updated?.helperParticipantId };
      } else {
        const current = await MealRequest.findOne({
      _id: requestId,
      requesterParticipantId: ownedRequest,
      status: "placed",
      deleteAt: { $gt: serverNow },
    })
      .select("+requesterPickupConfirmedAt")
      .session(session!)
      .lean()
      .exec();
        const existingTimestamp = current?.requesterPickupConfirmedAt;
        if (existingTimestamp instanceof Date && !Number.isNaN(existingTimestamp.getTime())) {
          confirmedAt = existingTimestamp;
        }
      }
      if (!confirmedAt) return;
      const ledger = await Fulfillment.updateOne(
        { requestId: new Types.ObjectId(requestId) },
        { $set: { requesterPickupConfirmedAt: confirmedAt } },
        { session }
      ).exec();
      if (ledger.matchedCount !== 1) {
        throw new Error("Placed-order fulfillment ledger is unavailable");
      }
    }, {
      readConcern: { level: "snapshot" },
      writeConcern: { w: "majority" },
    });
    // Only the committed transition winner dispatches, never a transaction
    // retry, idempotent replay, or an unestablished commit.
    if (pushTarget) {
      startHelperPickupConfirmedPush({
        requestId,
        helperParticipantId: (pushTarget as { helperParticipantId?: Types.ObjectId | null }).helperParticipantId,
        requesterParticipantId: ownedRequest,
      });
    }
    if (confirmedAt) return pickupConfirmationResponse(res, requestId, confirmedAt);
    return sendPlacedOrderNotFound(res);
  } catch {
    // A database error can follow a committed write. Even a structured 503 is
    // ambiguous to the client and must never be treated as a definitive no-write.
    console.error("[route] Pickup confirmation outcome is unavailable");
    return sendPickupConfirmationUnavailable(res);
  } finally {
    await session?.endSession();
  }
}

/**
 * `GET /api/participant/helper-placements/:requestId/contact` — the requester's
 * address, to the placing helper only, while the exchange is still active.
 * Every refusal is the same 404 so it reveals nothing about the request.
 */
export async function getHelperPlacementContact(
  req: Request,
  res: Response
): Promise<Response> {
  setPrivateHeaders(res);
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const requestId = String(req.params.requestId ?? "");
  if (!mongoose.isValidObjectId(requestId)) {
    return sendPlacedOrderNotFound(res);
  }

  try {
    const helperId = new Types.ObjectId(authority.participant.participantId);
    const now = new Date();
    const document = (await MealRequest.findOne({
      _id: requestId,
      helperParticipantId: helperId,
      status: "placed",
      requesterPickupConfirmedAt: null,
      deleteAt: { $gt: now },
    })
      .select("requesterParticipantId helperParticipantId placedAt etaText")
      .lean()
      .exec()) as unknown as {
      requesterParticipantId?: Types.ObjectId | null;
      helperParticipantId?: Types.ObjectId | null;
      placedAt?: Date | string | null;
      etaText?: string | null;
    } | null;
    if (!document?.requesterParticipantId || !document.helperParticipantId) {
      return sendPlacedOrderNotFound(res);
    }
    // Same helper window as the placements list: no email after it lapses.
    const visibility = placedHomeVisibility(
      document as Parameters<typeof placedHomeVisibility>[0]
    );
    if (!visibility || now.getTime() >= visibility.helperVisibleUntil.getTime()) {
      return sendPlacedOrderNotFound(res);
    }

    const [pairFenced, contactDisabled, requester] = await Promise.all([
      isParticipantPairFenced(document.requesterParticipantId, helperId),
      contactIsDisabledByModeration(document.requesterParticipantId, helperId),
      Participant.findById(document.requesterParticipantId)
        .select("email")
        .lean()
        .exec(),
    ]);
    if (pairFenced || contactDisabled || !requester?.email) {
      return sendPlacedOrderNotFound(res);
    }
    return res.json({ contactRequesterEmail: requester.email });
  } catch {
    console.error("[route] Helper placement contact lookup failed");
    return sendPlacedOrderNotFound(res);
  }
}

export function registerPlacedOrderRoutes(app: Express): void {
  app.get(
    HELPER_PLACEMENT_CONTACT_ROUTE_PATH,
    placedOrderCacheIsolation,
    placedOrderReadRateLimiter,
    getHelperPlacementContact
  );
  app.get(
    PLACED_ORDER_LIST_ROUTE_PATH,
    placedOrderCacheIsolation,
    placedOrderReadRateLimiter,
    getPlacedOrderList
  );
  app.get(
    PLACED_ORDER_DETAIL_ROUTE_PATH,
    placedOrderCacheIsolation,
    placedOrderReadRateLimiter,
    getPlacedOrderDetail
  );
  app.get(
    PLACED_ORDER_EVIDENCE_ROUTE_PATH,
    placedOrderCacheIsolation,
    placedOrderReadRateLimiter,
    getPlacedOrderEvidence
  );
  app.post(
    PICKUP_CONFIRMATION_ROUTE_PATH,
    placedOrderCacheIsolation,
    pickupConfirmationRateLimiter,
    confirmPlacedOrderPickup
  );
}
