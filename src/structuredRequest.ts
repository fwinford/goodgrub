/**
 * W4-R4 structured meal-request representation.
 *
 * This module owns the one authoritative shape a CommonPlate request is
 * submitted, validated, persisted, and projected in. It replaces the pre-R4
 * flat `food` + `pickupName` + meal-swipes-only representation.
 *
 * Two mutually exclusive menu paths exist, and a request is always exactly
 * one of them:
 *
 * - `meal-exchange` — 1 to 5 meal swipes, one required structured meal-detail
 *   entry per selected swipe, plus an optional Dining Dollar estimate.
 * - `dining-dollars` — exactly 0 meal swipes, one required structured
 *   order-details value, and a required Dining Dollar estimate.
 *
 * Currency is carried as an exact integer count of cents, never a float:
 * `12.34` is `1234`, and no accepted user-visible value can acquire
 * floating-point rounding behaviour on the way through validation,
 * persistence, projection, or W3-D1 replay.
 */
import { z } from "zod";

export const MEAL_EXCHANGE_PATH = "meal-exchange";
export const DINING_DOLLARS_PATH = "dining-dollars";

export type MenuPath = typeof MEAL_EXCHANGE_PATH | typeof DINING_DOLLARS_PATH;

/** The exact bounded swipe counts each path admits. Meal Exchange keeps the
 * accepted 1-5 range; Dining-Dollars-only is exactly 0, which is why the
 * shared integer field below now spans 0-5 rather than the pre-R4 1-5. */
export const MIN_MEAL_EXCHANGE_SWIPES = 1;
export const MAX_MEAL_SWIPES = 5;

/**
 * Accepted Dining Dollar estimate ceilings, in exact cents. The two paths
 * differ because the estimate means different things: a Meal Exchange
 * request's estimate is a small top-up beside the swipes, while a
 * Dining-Dollars-only request's estimate is the whole order.
 */
export const MAX_MEAL_EXCHANGE_DINING_DOLLARS_CENTS = 2_500;
export const MAX_DINING_DOLLARS_ONLY_CENTS = 5_000;

/** Required, non-blank free text, validated exactly as the pre-R4 `food`
 * field was. No per-field length ceiling is part of the request contract;
 * the shared 100 KB JSON body limit (`app.ts`) still bounds the payload. */
const structuredText = z.string().trim().min(1);

/** One requester-authored Meal Exchange line.  The two fields deliberately
 * remain separate all the way to persistence: `details` is not markup or a
 * suffix hidden inside `name`, and its absence is meaningful. */
export const structuredMealItem = z
  .object({
    name: structuredText,
    details: structuredText.optional(),
  })
  .strict();

export type StructuredMealItem = z.infer<typeof structuredMealItem>;

/**
 * An exact positive integer count of cents. `.int()` refuses a fractional
 * value outright rather than rounding it, so a client cannot submit
 * `1234.5` cents and have the backend silently decide what it meant.
 */
const diningDollarsCents = z.number().int().positive();

/**
 * The structured fields every accepted `POST /api/request` shape carries.
 * Spread into each create schema so the canonical iOS shapes and
 * `legacyWebSchema` validate one identical representation — there is
 * deliberately no second, weaker flat-food ingress path.
 *
 * Cross-field rules (which fields are required, forbidden, or bounded for
 * which path) are not expressible here; `refineStructuredRequest` below owns
 * them and must be applied to every schema that spreads these fields.
 */
export const structuredRequestFields = {
  menuPath: z.enum([MEAL_EXCHANGE_PATH, DINING_DOLLARS_PATH]),
  mealSwipes: z.number().int().min(0).max(MAX_MEAL_SWIPES),
  mealItems: z.array(structuredMealItem).max(MAX_MEAL_SWIPES).optional(),
  orderDetails: structuredText.optional(),
  estimatedDiningDollarsCents: diningDollarsCents.optional(),
};

/** The already-shape-validated structured half of a create payload. */
export interface StructuredRequestInput {
  menuPath: MenuPath;
  mealSwipes: number;
  mealItems?: StructuredMealItem[];
  orderDetails?: string;
  estimatedDiningDollarsCents?: number;
}

/**
 * The cross-path rules the per-field schemas above cannot express. Applied as
 * a `superRefine` on every create schema, so an invalid *combination* — a
 * Dining-Dollars-only request carrying meal entries, a Meal Exchange request
 * with fewer entries than swipes, an out-of-range estimate for the path
 * actually chosen — is refused with the same generic structural failure every
 * other malformed payload already produces.
 *
 * Nothing here repairs, defaults, or infers a missing value. A request whose
 * combination does not satisfy exactly one path is refused, never coerced
 * into the other one.
 */
export function refineStructuredRequest(
  value: StructuredRequestInput,
  context: z.RefinementCtx
): void {
  const mealItems = value.mealItems ?? [];

  if (value.menuPath === MEAL_EXCHANGE_PATH) {
    if (
      value.mealSwipes < MIN_MEAL_EXCHANGE_SWIPES ||
      value.mealSwipes > MAX_MEAL_SWIPES
    ) {
      context.addIssue({
        code: "custom",
        path: ["mealSwipes"],
        message: "Meal Exchange requires 1 to 5 meal swipes",
      });
      return;
    }
    // Exactly one active meal-detail entry per selected swipe. Both
    // directions are refused: a missing entry would post an incomplete
    // request, and an extra one would post content the requester hid by
    // lowering their swipe count.
    if (mealItems.length !== value.mealSwipes) {
      context.addIssue({
        code: "custom",
        path: ["mealItems"],
        message: "Each selected meal swipe requires one meal detail",
      });
    }
    if (value.orderDetails !== undefined) {
      context.addIssue({
        code: "custom",
        path: ["orderDetails"],
        message: "Meal Exchange requests carry meal details, not order details",
      });
    }
    // Optional. Absent means no Dining Dollars are needed — never a
    // fabricated `$0.00`, which is why absence is valid and zero is not
    // (`diningDollarsCents` is `.positive()`).
    if (
      value.estimatedDiningDollarsCents !== undefined &&
      value.estimatedDiningDollarsCents > MAX_MEAL_EXCHANGE_DINING_DOLLARS_CENTS
    ) {
      context.addIssue({
        code: "custom",
        path: ["estimatedDiningDollarsCents"],
        message: "Meal Exchange Dining Dollars may not exceed $25.00",
      });
    }
    return;
  }

  if (value.mealSwipes !== 0) {
    context.addIssue({
      code: "custom",
      path: ["mealSwipes"],
      message: "Dining-Dollars-only requests use no meal swipes",
    });
  }
  if (mealItems.length !== 0) {
    context.addIssue({
      code: "custom",
      path: ["mealItems"],
      message: "Dining-Dollars-only requests carry order details, not meal details",
    });
  }
  if (value.orderDetails === undefined) {
    context.addIssue({
      code: "custom",
      path: ["orderDetails"],
      message: "Dining-Dollars-only requests require order details",
    });
  }
  if (value.estimatedDiningDollarsCents === undefined) {
    context.addIssue({
      code: "custom",
      path: ["estimatedDiningDollarsCents"],
      message: "Dining-Dollars-only requests require a Dining Dollar estimate",
    });
  } else if (
    value.estimatedDiningDollarsCents > MAX_DINING_DOLLARS_ONLY_CENTS
  ) {
    context.addIssue({
      code: "custom",
      path: ["estimatedDiningDollarsCents"],
      message: "Dining Dollars may not exceed $50.00",
    });
  }
}

/**
 * Every requester-authored free-text value in the structured representation:
 * each Meal item's `name` and `details`, and `orderDetails`. These are the only
 * request fields another participant can read that the requester typed — `food`
 * is derived from them, and `vendor` is allowlisted — so they are exactly what
 * W4-U1.1 filters before a request may be persisted or shown to a helper.
 */
export function structuredAuthoredTexts(
  structured: StructuredRequestInput
): string[] {
  const texts: string[] = [];
  for (const item of structured.mealItems ?? []) {
    texts.push(item.name);
    if (item.details !== undefined) texts.push(item.details);
  }
  if (structured.orderDetails !== undefined) texts.push(structured.orderDetails);
  return texts;
}

/**
 * Exact cents to an exact display string. Integer arithmetic only — no
 * division into a float, and no `toFixed` on a value that could already have
 * lost precision — so `1234` is always `$12.34` and never `$12.33999…`.
 */
export function formatDiningDollars(cents: number): string {
  const dollars = Math.trunc(cents / 100);
  const remainder = cents % 100;
  return `$${dollars}.${String(remainder).padStart(2, "0")}`;
}

/**
 * The persisted single-line `food` summary, derived once at creation from the
 * structured representation above.
 *
 * `food` remains the compatibility surface every already-accepted downstream
 * projection, email, push payload, and digest line renders (`requestListResponse.ts`,
 * `emailHelpers.ts`, `helperPushPayload.ts`, `sendDigestEmail.ts`), which is
 * what lets R4 change the request *representation* without redesigning H1's
 * Helping page or H2/H4's Home presentation. It is a deterministic composition
 * of values the requester themselves entered — never an inference, a default,
 * or content the requester did not supply — and the structured fields it is
 * derived from are projected alongside it so a later, separately routed H1
 * consumption sync can present them directly instead of parsing this string.
 */
export function deriveFoodSummary(structured: StructuredRequestInput): string {
  const estimate =
    structured.estimatedDiningDollarsCents !== undefined
      ? formatDiningDollars(structured.estimatedDiningDollarsCents)
      : null;

  if (structured.menuPath === DINING_DOLLARS_PATH) {
    // The estimate is required on this path, so it is always present here.
    return `${structured.orderDetails} (${estimate} Dining Dollars)`;
  }

  const items = (structured.mealItems ?? [])
    .map((item) => (item.details ? `${item.name} (${item.details})` : item.name))
    .join("; ");
  return estimate ? `${items} + ${estimate} Dining Dollars` : items;
}
