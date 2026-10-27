import { SUPPORTED_VENDORS, type SupportedVendor } from "./supportedVendors.js";
import {
  amountAuthorityEvidenceText,
  corroboratedMealSwipeCount,
  currentOrderTotalCents,
  hasExplicitMealSwipeNotation,
  inferredMealSwipeCount,
  resolveMenuPath,
  type TotalGeometryEvidence,
} from "./screenshotEligibility.js";
import {
  FORBIDDEN_PROVIDER_FIELDS,
  ScreenshotProviderOutputSchema,
  type ScreenshotFoodItem,
  type ScreenshotProposal,
} from "./screenshotProposalTypes.js";

export type ProviderValidationFailure =
  | "forbidden_fields"
  | "schema_invalid";

export type ProviderValidationResult =
  | { ok: true; proposal: ScreenshotProposal }
  | { ok: false; reason: ProviderValidationFailure };

/**
 * A modifier consisting of only a bare affirmative/negative token, with no
 * other visible label attached, cannot be attributed to a parent item — the
 * screenshot may show a lone "yes"/"no" beside a prompt whose own label was
 * not captured as a modifier string. Genuinely labeled selections ("No
 * Side", "No Bag", "Yes Bag") are unaffected: this matches only an exact
 * standalone token after trim/case-fold.
 */
const BARE_AMBIGUOUS_MODIFIER_TOKENS = new Set(["yes", "no"]);

function isBareAmbiguousModifier(modifier: string): boolean {
  return BARE_AMBIGUOUS_MODIFIER_TOKENS.has(modifier.trim().toLowerCase());
}

function sanitizeModifiers(
  foodItems: ScreenshotFoodItem[]
): ScreenshotFoodItem[] {
  return foodItems.map((item) => ({
    ...item,
    modifiers: item.modifiers.filter((mod) => !isBareAmbiguousModifier(mod)),
  }));
}

function structuredFoodItem(item: ScreenshotFoodItem): { name: string; details?: string } | null {
  const name = item.name.trim();
  if (!name) return null;
  const quantityPrefix =
    item.quantity !== null && item.quantity > 0 ? `${item.quantity} ` : "";
  const details = item.modifiers.length ? item.modifiers.join(", ") : undefined;
  return { name: `${quantityPrefix}${name}`, ...(details ? { details } : {}) };
}

function itemIdentity(item: ScreenshotFoodItem): string {
  const normalize = (text: string) => text.trim().toLowerCase().replace(/\s+/g, " ");
  return JSON.stringify([
    normalize(item.name),
    item.quantity,
    item.modifiers.map(normalize).sort(),
  ]);
}

/**
 * W4-R4 overlap handling for multi-image evidence.
 *
 * Up to five screenshots describe ONE logical order, and real screenshots of
 * one order overlap. The provider is asked to report an item seen in several
 * screenshots once, but its output is one merged list with no record of
 * which screenshot each line came from. So when two lines share an exact
 * identity after normalization (same name, quantity, and modifier set), the
 * output cannot say whether that is one item seen twice or two identical
 * items ordered — collapsing to one, keeping both, or adding quantities
 * would each be a guess.
 *
 * The only provenance available is how many screenshots were analyzed:
 *
 * - One screenshot cannot overlap with itself, so repeated identical lines
 *   are separate order lines and every line is kept, as before W4-R4.
 * - With several screenshots, a repeated identity is ambiguous and is
 *   `null`: the caller proposes no meal items (and no swipe count, which
 *   depends on the same question) rather than a list that silently gained
 *   or lost an item. Lines that differ in quantity or any modifier are
 *   different items, never ambiguous with each other.
 */
function proposedMealItems(
  foodItems: ScreenshotFoodItem[],
  evidenceImageCount: number
): Array<{ name: string; details?: string }> | null {
  const seen = new Set<string>();
  const lines: Array<{ name: string; details?: string }> = [];

  for (const item of foodItems) {
    const line = structuredFoodItem(item);
    if (line === null) continue;
    const identity = itemIdentity(item);
    if (seen.has(identity) && evidenceImageCount > 1) return null;
    seen.add(identity);
    lines.push(line);
  }

  return lines;
}

/**
 * A deliberately narrow current-cart/order-level amount recognizer.  It
 * requires cart chrome and a literal aggregate resource expression on the
 * same evidence line: `3M + $2.00`.  Item-level price labels cannot satisfy
 * the order-level guard, and past-order language fails closed.
 */
const CURRENT_CART_MARKERS = /\b(?:your\s+(?:pickup\s+)?order|cart|checkout|continue\s+to\s+checkout)\b/i;
const PAST_ORDER_MARKERS = /\b(?:past\s+order|order\s+history|receipt|delivered|completed)\b/i;
const CART_DOLLAR_PATTERN = /(?<![\w.])(\d{1,2})\s?M\s*\+\s*\$(\d{1,2})(?:\.(\d{2}))?(?!\d)/g;

function currentCartDiningDollarsCents(evidenceText: string): number | null {
  if (!CURRENT_CART_MARKERS.test(evidenceText) || PAST_ORDER_MARKERS.test(evidenceText)) {
    return null;
  }
  const candidates = Array.from(evidenceText.matchAll(CART_DOLLAR_PATTERN), (match) => ({
    swipes: Number(match[1]),
    cents: Number(match[2]) * 100 + Number(match[3] ?? "0"),
  }));
  if (candidates.length === 0) return null;
  const distinct = new Set(candidates.map(({ swipes, cents }) => `${swipes}:${cents}`));
  if (distinct.size !== 1) return null;
  const candidate = candidates[0]!;
  if (candidate.swipes < 1 || candidate.swipes > 5 || candidate.cents <= 0 || candidate.cents > 2_500) {
    return null;
  }
  return candidate.cents;
}

function normalizeVenueText(text: string): string {
  return text.toLowerCase().replace(/\s+/g, " ").trim();
}

/**
 * Whether normalized observed text names `vendor`. Deliberately narrow:
 *
 * - `normalized === full` / `normalized === base` — an exact match to the
 *   complete catalog name, or to its base label before " - " (the only
 *   accepted abbreviation: the two current Upstein entries share exactly
 *   this base, which is what makes a bare "Upstein" ambiguous rather than a
 *   match — see `resolveVendor` below).
 * - `normalized.includes(full)` — the complete canonical name appears
 *   verbatim somewhere within longer observed text (a real screenshot's OCR
 *   naturally carries surrounding chrome/labels around the venue name).
 *
 * Deliberately NOT `full.includes(normalized)`: that direction would let any
 * short or generic fragment ("Burger", "Coffee", "Cafe") match merely
 * because it happens to be a substring of some catalog entry's full name —
 * exactly the fuzzy-guessing false-positive this rule must not produce.
 */
export function matchesVendorText(normalized: string, vendor: SupportedVendor): boolean {
  const full = vendor.name.toLowerCase();
  const base = full.split(" - ")[0]?.trim() ?? full;
  return normalized === full || normalized === base || normalized.includes(full);
}

export function groundedVendorMatches(text: string | null): SupportedVendor[] {
  if (!text) return [];
  const normalized = normalizeVenueText(text);
  if (!normalized) return [];
  return SUPPORTED_VENDORS.filter((vendor) => matchesVendorText(normalized, vendor));
}

/**
 * Resolves a canonical `shared/vendors.json` entry, grounded in
 * `evidenceText` — the independent on-device Vision OCR text — never in the
 * provider's own `visibleVenueText` alone. A provider claiming a venue the
 * independent evidence does not itself establish cannot select a vendor by
 * itself; raw provider text is not visible-location evidence on its own.
 *
 * Two catalog entries that share a base label before " - " (the two current
 * Upstein entries) are deliberately ambiguous when only the shared base
 * label is visible in the independent evidence — a match against every
 * entry sharing that label, not the first one, so a generic/historical
 * "Upstein" screenshot omits rather than guesses.
 *
 * If the provider's `visibleVenueText` is present and names a different
 * vendor than the one independent evidence grounded, the two disagree and
 * the proposal omits location rather than trusting either side alone. An
 * absent or consistent provider candidate does not block the grounded
 * result.
 */
function resolveVendor(
  evidenceText: string,
  visibleVenueText: string | null
): SupportedVendor | null {
  const groundedMatches = groundedVendorMatches(evidenceText);
  const groundedNames = new Set(groundedMatches.map((vendor) => vendor.name));
  if (groundedNames.size !== 1) return null;
  const grounded = groundedMatches[0]!;

  if (visibleVenueText) {
    const providerNames = new Set(
      groundedVendorMatches(visibleVenueText).map((vendor) => vendor.name)
    );
    if (providerNames.size > 0 && !providerNames.has(grounded.name)) {
      return null;
    }
  }

  return grounded;
}

function buildProposal(
  evidenceText: string,
  imageEvidenceTexts: readonly string[],
  imageTotalGeometryEvidence: readonly (TotalGeometryEvidence | undefined)[],
  evidenceImageCount: number,
  visibleVenueText: string | null,
  foodItems: ScreenshotFoodItem[],
  mealSwipes: number | null
): ScreenshotProposal {
  const proposal: ScreenshotProposal = {};

  const vendor = resolveVendor(evidenceText, visibleVenueText);
  if (vendor) {
    proposal.selectedDiningSpot = { name: vendor.name, address: vendor.address };
  }

  // W4-R4.1: the path comes only from independent deterministic evidence and
  // is resolved before anything branch-dependent. Disputed evidence proposes
  // no path AND omits every value whose meaning depends on the path (meal
  // items, swipes, the top-up estimate); the shared location stays.
  const pathResolution = resolveMenuPath(imageEvidenceTexts, imageTotalGeometryEvidence);
  if (pathResolution.menuPath) {
    proposal.menuPath = pathResolution.menuPath;
  }
  if (pathResolution.conflict) {
    return proposal;
  }

  // A labeled current order Total is a separate whole-order estimate. It is
  // useful even without provider food output and can fill a requester-owned
  // Dining Dollars path; Meal Exchange evidence never grants this amount.
  if (pathResolution.menuPath !== "meal-exchange") {
    const total = currentOrderTotalCents(
      imageEvidenceTexts, true, imageTotalGeometryEvidence
    );
    if (total !== null) proposal.diningDollarsOrderTotalCents = total;
  }

  // W4-R4: one entry per observed order line. `null` means repeated
  // identical lines across several screenshots could be overlap or a real
  // repeat, so neither meal items nor a swipe count is proposed.
  const mealItems = proposedMealItems(sanitizeModifiers(foodItems), evidenceImageCount);
  if (mealItems?.length) {
    proposal.mealItems = mealItems;
  }

  if (mealItems !== null && mealSwipes !== null && mealSwipes >= 1 && mealSwipes <= 5) {
    // Independent corroboration (accepted numeric M-style signal): the
    // candidate survives only when the explicit count in `evidenceText` —
    // the on-device Apple Vision OCR text this provider never saw or produced
    // — matches it exactly. A mismatch drops the value rather than coercing
    // it. This is never evaluated against anything the provider returned.
    //
    // W4-R4 multi-image consequence, and an intended one: `evidenceText` is
    // the combined evidence of every eligible screenshot, so an item visible
    // in two overlapping screenshots still makes repeated per-item `1M`
    // evidence ambiguous. Explicit aggregate totals such as `3M`, however,
    // are values rather than additive markers: repeated identical totals are
    // overlap, while conflicting totals fail closed.
    if (corroboratedMealSwipeCount(evidenceText) === mealSwipes) {
      proposal.mealSwipes = mealSwipes;
      // Checkout/review screenshots grant no amount authority of their own.
      const estimatedDiningDollarsCents = currentCartDiningDollarsCents(
        amountAuthorityEvidenceText(imageEvidenceTexts)
      );
      if (estimatedDiningDollarsCents !== null) {
        proposal.estimatedDiningDollarsCents = estimatedDiningDollarsCents;
      }
    }
  }

  if (pathResolution.menuPath === "meal-exchange" && mealItems !== null &&
      !hasExplicitMealSwipeNotation(evidenceText)) {
    const sourceItems = sanitizeModifiers(foodItems).filter((item) => item.name.trim());
    if (sourceItems.length === mealItems.length && sourceItems.every((item) => item.quantity === 1)) {
      const inferred = inferredMealSwipeCount(mealItems, imageEvidenceTexts);
      if (inferred !== null) proposal.mealSwipes = inferred;
    }
  }

  return proposal;
}

/**
 * The one deterministic validation boundary raw provider output passes
 * through before any of it can reach a proposal. Forbidden-field presence is
 * checked ahead of schema parsing, independent of whether the rest of the
 * shape is otherwise valid, so an attempted authority-field smuggling attempt
 * is refused on its own rather than folded into an ordinary shape error.
 *
 * Callers must only reach this function for a screenshot the independent
 * `localEvidenceText` rule (`screenshotEligibility.ts`) has already found
 * eligible — `screenshotProposalRoute.ts` evaluates that rule and refuses to
 * call the provider at all otherwise, so an ineligible screenshot never
 * reaches this function or the provider. `evidenceText` is that same
 * independent evidence, passed through here only for meal-swipe
 * corroboration; it is never re-derived from, or trusted against, anything
 * the provider itself returned. `evidenceImageCount` is how many eligible
 * screenshots the provider analyzed together (see `proposedMealItems`).
 * `imageEvidenceTexts` is each eligible screenshot's own evidence, which the
 * W4-R4.1 menu-path rule needs for per-screenshot attribution; it defaults to
 * `evidenceText` as one screenshot.
 */
export function validateProviderOutput(
  raw: unknown,
  evidenceText: string,
  evidenceImageCount: number,
  imageEvidenceTexts: readonly string[] = [evidenceText],
  imageTotalGeometryEvidence: readonly (TotalGeometryEvidence | undefined)[] = []
): ProviderValidationResult {
  if (raw && typeof raw === "object") {
    for (const key of Object.keys(raw as Record<string, unknown>)) {
      if ((FORBIDDEN_PROVIDER_FIELDS as readonly string[]).includes(key)) {
        return { ok: false, reason: "forbidden_fields" };
      }
    }
  }

  const result = ScreenshotProviderOutputSchema.safeParse(raw);
  if (!result.success) {
    return { ok: false, reason: "schema_invalid" };
  }

  const { visibleVenueText, foodItems, mealSwipes } = result.data;
  return {
    ok: true,
    proposal: buildProposal(
      evidenceText,
      imageEvidenceTexts,
      imageTotalGeometryEvidence,
      evidenceImageCount,
      visibleVenueText,
      foodItems,
      mealSwipes
    ),
  };
}
