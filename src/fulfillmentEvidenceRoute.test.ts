import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import express, { type NextFunction, type Request, type Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { generateClaimToken } from "./claimToken.js";
import {
  Fulfillment,
  Participant,
  ParticipantIdentityKeyVersion,
  PlacementEvidence,
  Request as MealRequest,
} from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  BLOCK_SAFETY_HMAC_KEYRING_ENV,
  PARTICIPATION_HMAC_KEYRING_ENV,
} from "./participantIdentityKeys.js";
import {
  INVALID_PLACED_ORDER_SCREENSHOT_CODE,
  PLACEMENT_EVIDENCE_MAX_BYTES,
  validatePlacedOrderScreenshot,
} from "./placedOrderEvidence.js";

const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

import {
  FULFILLMENT_BODY_LIMIT,
  fulfillRequest,
  fulfillmentParserError,
  PLACED_RETENTION_MS,
  registerFulfillmentRoute,
} from "./fulfillmentRoute.js";

/**
 * W4-H1a required placed-order evidence at the fulfillment route (unit level,
 * plus real HTTP for the body-parser boundary). The atomic-transaction proof
 * (all-or-nothing against a real replica set) lives in
 * `fulfillmentRoute.mongo.test.ts`; this file proves what can be proved without
 * one: every refusal happens before any mutation, in both authorization shapes,
 * and the evidence is bound to the same session as the placement and ledger.
 */

const requestId = "64b000000000000000000001";
const helperParticipantId = new mongoose.Types.ObjectId(
  "64c0000000000000000000b2"
);
const boundHelperEmail = "helper@nyu.edu";
const participantSecretText = "participant-evidence-route-unit-test-secret";
const participationKey = Buffer.alloc(32, 0x31);
const blockSafetyKey = Buffer.alloc(32, 0x52);
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  Buffer.from(participantSecretText)
);
const placedAt = new Date("2026-08-01T12:00:00.000Z");

/* ------------------------------ image fixtures ------------------------------ */

const ONE_PIXEL_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

/** Test-local CRC-32, independent of the validator's own implementation. */
const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();
function crc32(buffer: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = CRC_TABLE[(crc ^ byte) & 0xff]! ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type: string, data: Buffer): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

/**
 * A structurally valid PNG of EXACTLY `totalBytes` bytes (signature + IHDR +
 * one IDAT of filler + IEND = 57 fixed bytes + filler). Lets the size-cap
 * boundary be tested with a real, valid image on each side of the limit.
 */
function pngOfSize(totalBytes: number): Buffer {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(1, 0); // width
  ihdr.writeUInt32BE(1, 4); // height
  ihdr[8] = 8; // bit depth
  ihdr[9] = 0; // grayscale
  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", Buffer.alloc(totalBytes - 57, 0x2a)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  expect(png.length).toBe(totalBytes);
  return png;
}

/** A hand-assembled structurally valid JPEG (SOI, APP0, SOF0, SOS, scan, EOI). */
function validJpeg(): Buffer {
  return Buffer.concat([
    Buffer.from([0xff, 0xd8]),
    Buffer.from([
      0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
      0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    ]),
    Buffer.from([0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00]),
    Buffer.from([0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00]),
    Buffer.alloc(60, 0x00),
    Buffer.from([0xff, 0xd9]),
  ]);
}

const png = (buffer: Buffer) => ({
  mimeType: "image/png",
  imageBase64: buffer.toString("base64"),
});
const jpeg = (buffer: Buffer) => ({
  mimeType: "image/jpeg",
  imageBase64: buffer.toString("base64"),
});
const validPng = () => ({ mimeType: "image/png", imageBase64: ONE_PIXEL_PNG_BASE64 });

/* --------------------------- the pure validator ----------------------------- */

describe("validatePlacedOrderScreenshot", () => {
  it("accepts a supported PNG and returns the exact decoded bytes", () => {
    const result = validatePlacedOrderScreenshot(validPng());
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.evidence.mimeType).toBe("image/png");
    expect(result.evidence.image.equals(Buffer.from(ONE_PIXEL_PNG_BASE64, "base64"))).toBe(true);
    expect(result.evidence.byteLength).toBe(result.evidence.image.length);
  });

  it("accepts a supported JPEG", () => {
    const bytes = validJpeg();
    const result = validatePlacedOrderScreenshot(jpeg(bytes));
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.evidence.mimeType).toBe("image/jpeg");
  });

  it("accepts exactly the 1,500,000-byte cap and refuses one byte more", () => {
    expect(PLACEMENT_EVIDENCE_MAX_BYTES).toBe(1_500_000);
    const atCap = validatePlacedOrderScreenshot(png(pngOfSize(1_500_000)));
    expect(atCap.ok).toBe(true);
    if (atCap.ok) expect(atCap.evidence.byteLength).toBe(1_500_000);
    expect(validatePlacedOrderScreenshot(png(pngOfSize(1_500_001))).ok).toBe(false);
  });

  it.each([
    ["missing", undefined],
    ["null", null],
    ["a string", ONE_PIXEL_PNG_BASE64],
    ["an array", [validPng()]],
    ["an empty object", {}],
    ["a number", 7],
  ])("refuses %s", (_name, value) => {
    expect(validatePlacedOrderScreenshot(value).ok).toBe(false);
  });

  it.each([
    ["an unsupported MIME (heic)", { ...validPng(), mimeType: "image/heic" }],
    ["an unsupported MIME (gif)", { ...validPng(), mimeType: "image/gif" }],
    ["an unsupported MIME (webp)", { ...validPng(), mimeType: "image/webp" }],
    ["a wrong-case MIME", { ...validPng(), mimeType: "IMAGE/PNG" }],
    ["a non-string MIME", { ...validPng(), mimeType: 1 }],
    ["an extra key", { ...validPng(), url: "https://example.com/a.png" }],
    ["a client-supplied evidence id", { ...validPng(), evidenceId: "abc" }],
    ["a client-supplied path", { ...validPng(), path: "/tmp/a.png" }],
    ["no imageBase64", { mimeType: "image/png" }],
    ["an empty imageBase64", { mimeType: "image/png", imageBase64: "" }],
    ["a non-string imageBase64", { mimeType: "image/png", imageBase64: 5 }],
  ])("refuses %s", (_name, value) => {
    expect(validatePlacedOrderScreenshot(value).ok).toBe(false);
  });

  it.each([
    ["non-base64 characters", { mimeType: "image/png", imageBase64: "not base64 at all!" }],
    ["a length that is not a multiple of 4", { mimeType: "image/png", imageBase64: ONE_PIXEL_PNG_BASE64.slice(0, -1) }],
    ["interior padding", { mimeType: "image/png", imageBase64: "AAAA=AAA" }],
    ["url-safe alphabet", { mimeType: "image/png", imageBase64: ONE_PIXEL_PNG_BASE64.replace(/\+/g, "-").replace(/\//g, "_") + "-_-_" }],
    ["whitespace inside", { mimeType: "image/png", imageBase64: `${ONE_PIXEL_PNG_BASE64.slice(0, 8)}\n${ONE_PIXEL_PNG_BASE64.slice(8)}` }],
  ])("refuses malformed base64: %s", (_name, value) => {
    expect(validatePlacedOrderScreenshot(value).ok).toBe(false);
  });

  it("refuses bytes that do not match the declared type", () => {
    // PNG bytes labelled JPEG, and JPEG bytes labelled PNG.
    expect(validatePlacedOrderScreenshot({ ...validPng(), mimeType: "image/jpeg" }).ok).toBe(false);
    expect(validatePlacedOrderScreenshot({ ...jpeg(validJpeg()), mimeType: "image/png" }).ok).toBe(false);
  });

  it("refuses corrupt and truncated images", () => {
    const wholePng = Buffer.from(ONE_PIXEL_PNG_BASE64, "base64");
    expect(validatePlacedOrderScreenshot(png(wholePng.subarray(0, wholePng.length - 10))).ok).toBe(false);
    expect(validatePlacedOrderScreenshot(png(wholePng.subarray(0, 8))).ok).toBe(false);
    const flipped = Buffer.from(wholePng);
    flipped[flipped.length - 20] ^= 0xff; // breaks a chunk CRC
    expect(validatePlacedOrderScreenshot(png(flipped)).ok).toBe(false);
    const wholeJpeg = validJpeg();
    expect(validatePlacedOrderScreenshot(jpeg(wholeJpeg.subarray(0, wholeJpeg.length - 2))).ok).toBe(false);
    expect(validatePlacedOrderScreenshot(jpeg(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]))).ok).toBe(false);
    // The right magic bytes followed by garbage.
    expect(validatePlacedOrderScreenshot(png(Buffer.concat([wholePng.subarray(0, 8), Buffer.alloc(200, 7)]))).ok).toBe(false);
  });

  it("refuses an oversized base64 string without needing to decode it", () => {
    const tooLong = "A".repeat(Math.ceil(PLACEMENT_EVIDENCE_MAX_BYTES / 3) * 4 + 4);
    expect(validatePlacedOrderScreenshot({ mimeType: "image/png", imageBase64: tooLong }).ok).toBe(false);
  });

  it("returns only pass/fail: a refusal carries no reason that could leak", () => {
    const refused = validatePlacedOrderScreenshot({ ...validPng(), mimeType: "image/heic" });
    expect(refused).toEqual({ ok: false });
  });
});

/* ------------------------------ route harness ------------------------------- */

function routeContext(body: unknown, headers: Record<string, string> = {}) {
  const req = { params: { id: requestId }, body, headers } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}
const responseBody = (context: ReturnType<typeof routeContext>) =>
  context.json.mock.calls[0][0] as Record<string, any>;

const tokenBody = (placedOrderScreenshot: unknown, extra: Record<string, unknown> = {}) => ({
  claimToken: generateClaimToken(),
  fulfillment: {
    orderNumber: "70154321",
    eta: "15 minutes",
    contactMessage: "Your meal is ready",
    ...(placedOrderScreenshot === undefined ? {} : { placedOrderScreenshot }),
    ...extra,
  },
});
const continuationBody = (placedOrderScreenshot: unknown) => ({
  fulfillment: {
    orderNumber: "70154321",
    eta: "15 minutes",
    contactMessage: "Your meal is ready",
    ...(placedOrderScreenshot === undefined ? {} : { placedOrderScreenshot }),
  },
});
const continuationHeaders = { [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority };

function stubIdentity() {
  vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({ _id: helperParticipantId, email: boundHelperEmail }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
  vi.spyOn(MealRequest, "findById").mockImplementation(
    (() => ({
      select: (projection: string) => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue(
            projection === "+requesterParticipantId +helperParticipantId"
              ? { requesterParticipantId: null, helperParticipantId }
              : { helperParticipantId }
          ),
        }),
      }),
    })) as unknown as typeof MealRequest.findById
  );
  vi.spyOn(Participant, "findById").mockReturnValue({
    select: () => ({
      session: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue({
            _id: helperParticipantId,
            email: boundHelperEmail,
            authorityVersion: 1,
          }),
        }),
      }),
      lean: () => ({
        exec: vi.fn().mockResolvedValue({
          _id: helperParticipantId,
          email: boundHelperEmail,
          authorityVersion: 1,
        }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findById>);
  vi.spyOn(Participant, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ matchedCount: 1 }),
  } as unknown as ReturnType<typeof Participant.updateOne>);
}

function stubCommittedPlacement({
  evidenceCreate = vi.fn().mockResolvedValue([{}]),
  placed = null as unknown,
} = {}) {
  const placedRequest = placed ?? {
    _id: new mongoose.Types.ObjectId(requestId),
    status: "placed",
    vendor: "Palladium",
    food: "Vegetable rice bowl",
    pickupWindowText: "ASAP",
    windowStart: null,
    windowEnd: null,
    createdAt: placedAt,
    expiresAt: new Date(placedAt.getTime() + 3 * 60 * 60 * 1000),
    placedAt,
  };
  const findOneAndUpdate = vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
    select: () => ({ exec: vi.fn().mockResolvedValue(placedRequest) }),
  } as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>);
  const ledger = vi.spyOn(Fulfillment, "create").mockResolvedValue([{}] as never);
  const evidence = vi.spyOn(PlacementEvidence, "create").mockImplementation(evidenceCreate as never);
  const recordOutcome = vi.spyOn(MealRequest, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({}),
  } as unknown as ReturnType<typeof MealRequest.updateOne>);
  const session = {
    withTransaction: vi.fn(async (work: () => Promise<void>) => {
      await work();
    }),
    endSession: vi.fn().mockResolvedValue(undefined),
  };
  const startSession = vi.spyOn(mongoose, "startSession").mockResolvedValue(session as never);
  return { findOneAndUpdate, ledger, evidence, recordOutcome, session, startSession };
}

let consoleError: ReturnType<typeof vi.spyOn>;
let consoleInfo: ReturnType<typeof vi.spyOn>;
let consoleLog: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "unit-test-claim-hmac-secret-material");
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
  vi.stubEnv(
    PARTICIPATION_HMAC_KEYRING_ENV,
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": participationKey.toString("base64") },
    })
  );
  vi.stubEnv(
    BLOCK_SAFETY_HMAC_KEYRING_ENV,
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": blockSafetyKey.toString("base64") },
    })
  );
  vi.spyOn(ParticipantIdentityKeyVersion, "find").mockImplementation(
    ((filter: { purpose: string }) => {
      const rows = [
        {
          purpose: filter.purpose,
          version: 1,
          normalizationVersion: 1,
        },
      ];
      const chain = {
        maxTimeMS: () => chain,
        select: () => chain,
        session: () => chain,
        lean: () => chain,
        exec: vi.fn().mockResolvedValue(rows),
      };
      return chain as never;
    }) as never
  );
  stubIdentity();
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
  consoleInfo = vi.spyOn(console, "info").mockImplementation(() => {});
  consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  sendFulfillmentEmail.mockReset();
});

/* --------------------------- refusal before mutation ------------------------- */

describe("required placed-order screenshot: refusal happens before any mutation", () => {
  const badEvidence: Array<[string, unknown]> = [
    ["a missing screenshot", undefined],
    ["a null screenshot", null],
    ["an unsupported MIME", { ...validPng(), mimeType: "image/heic" }],
    ["malformed base64", { mimeType: "image/png", imageBase64: "%%%%" }],
    ["a MIME/bytes mismatch", { ...validPng(), mimeType: "image/jpeg" }],
    ["a truncated image", png(Buffer.from(ONE_PIXEL_PNG_BASE64, "base64").subarray(0, 30))],
    ["an oversized image", png(pngOfSize(1_500_001))],
    ["an extra key", { ...validPng(), url: "https://example.com/x.png" }],
  ];

  it.each(badEvidence)("refuses %s in the claim-token shape", async (_name, evidence) => {
    const mutations = stubCommittedPlacement();
    const context = routeContext(tokenBody(evidence));

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe(INVALID_PLACED_ORDER_SCREENSHOT_CODE);
    expect(responseBody(context).error.code).not.toBe("INVALID_FULFILLMENT_PAYLOAD");
    expect(mutations.startSession).not.toHaveBeenCalled();
    expect(mutations.findOneAndUpdate).not.toHaveBeenCalled();
    expect(mutations.ledger).not.toHaveBeenCalled();
    expect(mutations.evidence).not.toHaveBeenCalled();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it.each(badEvidence)("refuses %s in the participant-continuation shape", async (_name, evidence) => {
    const mutations = stubCommittedPlacement();
    const context = routeContext(continuationBody(evidence), continuationHeaders);

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe(INVALID_PLACED_ORDER_SCREENSHOT_CODE);
    expect(mutations.startSession).not.toHaveBeenCalled();
    expect(mutations.findOneAndUpdate).not.toHaveBeenCalled();
    expect(mutations.ledger).not.toHaveBeenCalled();
    expect(mutations.evidence).not.toHaveBeenCalled();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("answers an evidence refusal without naming the failing check or echoing any image text", async () => {
    stubCommittedPlacement();
    const marker = "SENTINEL-IMAGE-TEXT-NEVER-ECHOED";
    const context = routeContext(tokenBody({ mimeType: "image/png", imageBase64: marker }));

    await fulfillRequest(context.req, context.res);

    const serialized = JSON.stringify(responseBody(context));
    expect(serialized).not.toContain(marker);
    expect(responseBody(context).error.fields).toBeNull();
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(marker);
    expect(JSON.stringify(consoleLog.mock.calls)).not.toContain(marker);
  });

  it("keeps the ordinary payload refusal first: a bad order number is still INVALID_FULFILLMENT_PAYLOAD", async () => {
    const mutations = stubCommittedPlacement();
    const context = routeContext(
      tokenBody(validPng(), { orderNumber: "7015 4321" })
    );

    await fulfillRequest(context.req, context.res);

    expect(responseBody(context).error.code).toBe("INVALID_FULFILLMENT_PAYLOAD");
    expect(mutations.startSession).not.toHaveBeenCalled();
  });

  it("refuses a missing screenshot before the participant-continuation authority is trusted for payload truth", async () => {
    // Authority is still checked first: an unverified caller learns nothing
    // about whether its evidence would have been accepted.
    const mutations = stubCommittedPlacement();
    const context = routeContext(continuationBody(undefined));

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe("PARTICIPANT_VERIFICATION_REQUIRED");
    expect(mutations.startSession).not.toHaveBeenCalled();
  });

  it("evidence validity is independent of Message filtering, and refuses before it", async () => {
    // A filter-blocked Message with bad evidence is an EVIDENCE refusal (the
    // filter has not run), and nothing is mutated.
    const mutations = stubCommittedPlacement();
    const context = routeContext(
      tokenBody(undefined, { contactMessage: "Thanks, you stupid bitch" })
    );

    await fulfillRequest(context.req, context.res);

    expect(responseBody(context).error.code).toBe(INVALID_PLACED_ORDER_SCREENSHOT_CODE);
    expect(mutations.findOneAndUpdate).not.toHaveBeenCalled();
  });
});

/* ------------------------------ accepted evidence --------------------------- */

describe("required placed-order screenshot: accepted evidence joins the placement transaction", () => {
  it.each([
    ["PNG", () => validPng(), "image/png"],
    ["JPEG", () => jpeg(validJpeg()), "image/jpeg"],
  ])("persists a %s with the exact bytes, MIME, length, and Request horizon", async (_label, make, mime) => {
    const mutations = stubCommittedPlacement();
    const evidence = make();
    const context = routeContext(tokenBody(evidence));

    await fulfillRequest(context.req, context.res);

    expect(context.status).not.toHaveBeenCalled();
    expect(mutations.evidence).toHaveBeenCalledOnce();
    const [documents, options] = mutations.evidence.mock.calls[0] as any[];
    expect(documents).toHaveLength(1);
    const [row] = documents;
    expect(String(row.requestId)).toBe(requestId);
    expect(Buffer.isBuffer(row.image)).toBe(true);
    expect(row.image.equals(Buffer.from(evidence.imageBase64, "base64"))).toBe(true);
    expect(row.mimeType).toBe(mime);
    expect(row.byteLength).toBe(row.image.length);
    expect(Object.keys(row).sort()).toEqual(["byteLength", "deleteAt", "image", "mimeType", "requestId"]);

    // One horizon for both: the placed Request and its evidence expire together.
    const [, update] = mutations.findOneAndUpdate.mock.calls[0] as any[];
    expect(update.$set.deleteAt).toEqual(row.deleteAt);
    expect(row.deleteAt.getTime() - update.$set.placedAt.getTime()).toBe(PLACED_RETENTION_MS);

    // Same session as the placement and the ledger row, ledger first.
    const [, , placementOptions] = mutations.findOneAndUpdate.mock.calls[0] as any[];
    const [, ledgerOptions] = mutations.ledger.mock.calls[0] as any[];
    expect(options.session).toBe(mutations.session);
    expect(ledgerOptions.session).toBe(mutations.session);
    expect(placementOptions.session).toBe(mutations.session);
    expect(mutations.ledger.mock.invocationCallOrder[0]).toBeLessThan(
      mutations.evidence.mock.invocationCallOrder[0]
    );
  });

  it("persists evidence in the participant-continuation shape too, bound to the exact placed Request", async () => {
    const mutations = stubCommittedPlacement();
    const context = routeContext(continuationBody(validPng()), continuationHeaders);

    await fulfillRequest(context.req, context.res);

    expect(context.status).not.toHaveBeenCalled();
    expect(mutations.evidence).toHaveBeenCalledOnce();
    const [[row]] = mutations.evidence.mock.calls[0] as any[];
    expect(String(row.requestId)).toBe(requestId);
  });

  it("writes evidence only after a successful conditional placement: a wrong token or helper writes none", async () => {
    // A conditional-update miss (wrong token, other helper, expired, released)
    // means no placed Request exists, so no evidence may be written for it.
    const mutations = stubCommittedPlacement();
    mutations.findOneAndUpdate.mockReturnValue({
      select: () => ({ exec: vi.fn().mockResolvedValue(null) }),
    } as never);
    vi.spyOn(MealRequest, "findById").mockImplementation(
      (() => ({
        select: () => ({
          lean: () => ({
            exec: vi.fn().mockResolvedValue({
              status: "claimed",
              claimExpiresAt: new Date(Date.now() + 60_000),
              helperParticipantId: new mongoose.Types.ObjectId("64c0000000000000000000c9"),
            }),
          }),
        }),
      })) as unknown as typeof MealRequest.findById
    );
    const context = routeContext(continuationBody(validPng()), continuationHeaders);

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
    expect(mutations.ledger).not.toHaveBeenCalled();
    expect(mutations.evidence).not.toHaveBeenCalled();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("an evidence insert failure surfaces as a failed placement, with no email and no success body", async () => {
    // Inside the real transaction this rejection aborts Request + ledger +
    // evidence together (proved in the Mongo suite); here the route must treat
    // it as a failed placement rather than answering success.
    const mutations = stubCommittedPlacement({
      evidenceCreate: vi.fn().mockRejectedValue(new Error("E11000 duplicate key")),
    });
    const context = routeContext(tokenBody(validPng()));

    await fulfillRequest(context.req, context.res);

    expect(mutations.evidence).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context).error.code).toBe("INTERNAL_FAILURE");
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    expect(mutations.recordOutcome).not.toHaveBeenCalled();
  });

  it("a suppressed Message still commits placement and evidence", async () => {
    const mutations = stubCommittedPlacement();
    const context = routeContext(
      tokenBody(validPng(), { contactMessage: "Thanks, you stupid bitch" })
    );

    await fulfillRequest(context.req, context.res);

    expect(context.status).not.toHaveBeenCalled();
    expect(mutations.evidence).toHaveBeenCalledOnce();
    expect(responseBody(context).messageSuppressed).toBe(true);
    expect(sendFulfillmentEmail.mock.calls[0][3]).toBeUndefined();
  });

  it("an email failure after commit leaves placement and evidence in place", async () => {
    const mutations = stubCommittedPlacement();
    sendFulfillmentEmail.mockRejectedValue(new Error("provider down"));
    const context = routeContext(tokenBody(validPng()));

    await fulfillRequest(context.req, context.res);

    expect(mutations.evidence).toHaveBeenCalledOnce();
    expect(context.status).not.toHaveBeenCalled();
    expect(responseBody(context).notification).toEqual({ status: "failed" });
  });
});

/* ------------------------------- privacy ------------------------------------ */

describe("placed-order evidence never leaves the placement transaction", () => {
  it("is absent from the helper response, the fulfillment email, the Request update, and every log line", async () => {
    const mutations = stubCommittedPlacement();
    const evidence = validPng();
    const context = routeContext(tokenBody(evidence));

    await fulfillRequest(context.req, context.res);

    const [, update] = mutations.findOneAndUpdate.mock.calls[0] as any[];
    const surfaces = {
      response: JSON.stringify(responseBody(context)),
      requestUpdate: JSON.stringify(update),
      email: JSON.stringify(sendFulfillmentEmail.mock.calls),
      logs: JSON.stringify([
        consoleError.mock.calls,
        consoleInfo.mock.calls,
        consoleLog.mock.calls,
      ]),
      outcome: JSON.stringify(mutations.recordOutcome.mock.calls),
      ledger: JSON.stringify(mutations.ledger.mock.calls),
    };
    for (const [surface, text] of Object.entries(surfaces)) {
      expect(text, surface).not.toContain(evidence.imageBase64);
      expect(text, surface).not.toContain("placedOrderScreenshot");
    }
    expect(Object.keys(responseBody(context)).sort()).toEqual(["notification", "request"]);
  });
});

/* ------------------------- body parser boundary (real HTTP) ----------------- */

describe("fulfillment body parser boundary", () => {
  async function withServer<T>(
    configure: (app: express.Express) => void,
    run: (url: string) => Promise<T>
  ): Promise<T> {
    const app = express();
    configure(app);
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
      const { port } = server.address() as AddressInfo;
      return await run(`http://127.0.0.1:${port}/api/request/${requestId}/fulfill`);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  }

  const post = (url: string, body: string) =>
    fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body });

  it("holds a body the global 100 KB parser would refuse, when registered ahead of it", async () => {
    expect(FULFILLMENT_BODY_LIMIT).toBe("3mb");
    // A real, valid, near-cap image: far larger than 100 KB once base64-encoded.
    const big = png(pngOfSize(1_400_000));
    const body = JSON.stringify(tokenBody(big));
    expect(body.length).toBeGreaterThan(1_800_000);
    // Stop right after the validation boundary so no transaction is needed.
    const startSession = vi.spyOn(mongoose, "startSession").mockRejectedValue(new Error("stop after validation"));

    await withServer(
      (app) => {
        registerFulfillmentRoute(app);
        // Exactly how app.ts orders it: the global parser comes AFTER.
        app.use(express.json({ limit: "100kb" }));
      },
      async (url) => {
        const response = await post(url, body);
        // The handler ran (it reached the transaction boundary and failed
        // there), rather than a 413 from the global parser.
        expect(response.status).toBe(500);
        expect((await response.json()).error.code).toBe("INTERNAL_FAILURE");
        expect(startSession).toHaveBeenCalledOnce();
      }
    );
  });

  it("control: the same body is refused by a 100 KB parser registered first", async () => {
    const body = JSON.stringify(tokenBody(png(pngOfSize(1_400_000))));
    const startSession = vi.spyOn(mongoose, "startSession");

    await withServer(
      (app) => {
        app.use(express.json({ limit: "100kb" }));
        registerFulfillmentRoute(app);
        app.use((_error: unknown, _req: Request, res: Response, _next: NextFunction) => {
          res.status(413).json({ refusedByGlobalParser: true });
        });
      },
      async (url) => {
        const response = await post(url, body);
        expect(response.status).toBe(413);
        expect(startSession).not.toHaveBeenCalled();
      }
    );
  });

  it("answers an over-3 MB body with the evidence refusal, content-free, before the handler", async () => {
    const startSession = vi.spyOn(mongoose, "startSession");
    const sentinel = "SENTINEL-OVERSIZED-BODY-NEVER-LOGGED";
    const body = JSON.stringify({
      claimToken: generateClaimToken(),
      fulfillment: {
        orderNumber: "70154321",
        eta: "15 minutes",
        placedOrderScreenshot: { mimeType: "image/png", imageBase64: sentinel + "A".repeat(3_200_000) },
      },
    });

    await withServer(registerFulfillmentRoute, async (url) => {
      const response = await post(url, body);
      expect(response.status).toBe(400);
      await expect(response.json()).resolves.toEqual({
        error: {
          code: INVALID_PLACED_ORDER_SCREENSHOT_CODE,
          message: "The order screenshot is missing or can’t be used.",
          fields: null,
        },
      });
    });
    expect(startSession).not.toHaveBeenCalled();
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(sentinel);
    expect(JSON.stringify(consoleLog.mock.calls)).not.toContain(sentinel);
  });

  it("answers malformed JSON with the ordinary payload refusal and never logs the body", async () => {
    const sentinel = "SENTINEL-MALFORMED-BODY-NEVER-LOGGED";
    await withServer(registerFulfillmentRoute, async (url) => {
      const response = await post(url, `{"fulfillment":{"placedOrderScreenshot":"${sentinel}`);
      expect(response.status).toBe(400);
      expect((await response.json()).error.code).toBe("INVALID_FULFILLMENT_PAYLOAD");
    });
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(sentinel);
    expect(JSON.stringify(consoleLog.mock.calls)).not.toContain(sentinel);
  });

  it("does not turn a post-parse handler failure into a definitive 400", () => {
    // Express 5 forwards a rejected async handler to this same error
    // middleware. A non-parser error (which could follow a committed
    // placement) must pass through untouched, never become a "400, nothing
    // happened".
    const res = { headersSent: false, status: vi.fn(), json: vi.fn() } as unknown as Response;
    const next = vi.fn();
    const failure = new Error("buildPublicRequestDetailResponse exploded");

    fulfillmentParserError(failure, {} as Request, res, next);

    expect(next).toHaveBeenCalledWith(failure);
    expect(res.status).not.toHaveBeenCalled();
  });

  it("registers the 3 MB parser after the rate limiter and before the handler", () => {
    const routes: string[] = [];
    const app = { post: vi.fn((...args: unknown[]) => routes.push(String(args[0]))) } as unknown as express.Express;
    registerFulfillmentRoute(app);
    const [path, ...chain] = (app.post as any).mock.calls[0];
    expect(path).toBe("/api/request/:id/fulfill");
    expect(chain).toHaveLength(4);
    expect(chain[2]).toBe(fulfillRequest);
    expect(chain[3]).toBe(fulfillmentParserError);
  });
});
