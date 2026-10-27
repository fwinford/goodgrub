import { z } from "zod";
import { isStrictBase64, isStructurallyValidImage } from "./imageStructure.js";

/**
 * W4-H1a placed-order evidence: the one screenshot a helper must attach to every
 * NEW fulfillment. This module is pure — it parses and validates the wire value
 * and nothing else. It reads no database, sends nothing, and never logs; the
 * bytes it returns are handed to the placement transaction by the route and go
 * nowhere else.
 *
 * The screenshot is evidence the helper supplied, not proof the order is real.
 * Nothing here recognizes text, checks for Grubhub content, or otherwise judges
 * authenticity: the only hard requirements are an attached, supported-type,
 * structurally valid, bounded image.
 */

/** Decoded-byte ceiling. Enforced on the client, here after base64 decode, and
 * by the `PlacementEvidence` schema on the stored `byteLength`. */
export const PLACEMENT_EVIDENCE_MAX_BYTES = 1_500_000;

/** The only wire/storage formats. Other source formats (HEIC, ...) are
 * normalized to JPEG on the device before they are ever sent. */
export const PLACEMENT_EVIDENCE_MIME_TYPES = ["image/jpeg", "image/png"] as const;
export type PlacementEvidenceMimeType =
  (typeof PLACEMENT_EVIDENCE_MIME_TYPES)[number];

/**
 * The longest base64 text that can still decode to at most
 * `PLACEMENT_EVIDENCE_MAX_BYTES`. Checked before decoding so an oversized
 * string is refused without allocating its decoded copy.
 */
const MAX_IMAGE_BASE64_LENGTH =
  Math.ceil(PLACEMENT_EVIDENCE_MAX_BYTES / 3) * 4;

/**
 * Dedicated structured code for definitive evidence refusal, deliberately
 * distinct from `INVALID_FULFILLMENT_PAYLOAD` so a client can tell "fix the
 * order details" from "choose another screenshot" without parsing prose.
 */
export const INVALID_PLACED_ORDER_SCREENSHOT_CODE =
  "INVALID_PLACED_ORDER_SCREENSHOT";
/** Content-free by construction: it never says which check failed. */
export const INVALID_PLACED_ORDER_SCREENSHOT_MESSAGE =
  "The order screenshot is missing or can’t be used.";

const placedOrderScreenshotWireSchema = z
  .object({
    mimeType: z.enum(PLACEMENT_EVIDENCE_MIME_TYPES),
    imageBase64: z.string().min(1).max(MAX_IMAGE_BASE64_LENGTH),
  })
  .strict();

export interface ValidatedPlacedOrderScreenshot {
  mimeType: PlacementEvidenceMimeType;
  image: Buffer;
  byteLength: number;
}

export type PlacedOrderScreenshotValidation =
  | { ok: true; evidence: ValidatedPlacedOrderScreenshot }
  | { ok: false };

/**
 * Validates the `fulfillment.placedOrderScreenshot` wire value. Returns only a
 * pass/fail: the reason is deliberately not surfaced, so no caller can leak it
 * to a response, a log line, or an error string.
 */
export function validatePlacedOrderScreenshot(
  value: unknown
): PlacedOrderScreenshotValidation {
  const parsed = placedOrderScreenshotWireSchema.safeParse(value);
  if (!parsed.success) return { ok: false };

  const { mimeType, imageBase64 } = parsed.data;
  if (!isStrictBase64(imageBase64)) return { ok: false };

  const image = Buffer.from(imageBase64, "base64");
  if (
    image.length === 0 ||
    image.length > PLACEMENT_EVIDENCE_MAX_BYTES ||
    !isStructurallyValidImage(image, mimeType)
  ) {
    return { ok: false };
  }

  return {
    ok: true,
    evidence: { mimeType, image, byteLength: image.length },
  };
}
