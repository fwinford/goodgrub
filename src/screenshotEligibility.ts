/**
 * Deterministic W4-S1 eligibility gate (accident prevention, not authenticity
 * verification). Ported from the accepted `V1-C1-or-H5` rule recorded in
 * `eval/s1-eligibility-diagnosis/` — the cart/bag chrome sub-rule (C1) union
 * with the detailed-history core (H5): legible image, exact "View order"
 * title, "Order information" section heading, and a quantity-prefixed item
 * line. The eval harness computed these signals from local Tesseract OCR;
 * production computes them from `localEvidenceText` — on-device Apple Vision
 * OCR, produced on iOS and never derived from or trusted against the OpenAI
 * provider's own output (`screenshotProposalRoute.ts`) — instead, so the
 * service needs no OCR binary of its own. The rule and its regexes are
 * otherwise unchanged — this is evaluated against evidence, not a fixture id
 * or label.
 */

const LEGIBILITY_MIN_NON_WHITESPACE_CHARS = 20;

const RE_QUANTIFIED_ITEM =
  /(^|\s)(\d{1,2})\s?x?\s+[a-z][a-z'&()-]{2,}(\s+[a-z][a-z'&()-]+){0,6}/;
const RE_VIEW_ORDER = /\bview order\b(?! details)/;
const RE_ORDER_INFORMATION = /\border information\b/;

/** Cart/bag chrome phrases (C1). "review/place your ... order" is checkout,
 * not cart, and is deliberately excluded even though it contains the cart
 * phrase as a substring. */
const CART_CHROME_PHRASES = [
  "your pickup order",
  "your delivery order",
  "order instructions",
  "cilantro on the side",
  "continue to checkout",
  "add more items",
  "empty bag",
  "items subtotal",
] as const;

function normalize(text: string): string {
  return text.toLowerCase().replace(/\s+/g, " ").trim();
}

/**
 * W4-R4.1 Grubhub checkout/review category. A screenshot belongs to it only
 * when it carries the explicit order-review heading as its own line AND at
 * least one bounded order-specific section: a `Your order` section with a
 * quantity-prefixed item line, or a `Your payment` section with one bounded
 * `Payment method` summary row. Generic checkout words, `Place your ...
 * order` CTA text, prices, totals, or a cropped summary never qualify.
 *
 * The rule reads normalized (lower-cased, whitespace-collapsed) non-empty
 * lines of the independent on-device OCR text. The heading, section titles,
 * and row labels are literal whole labels. Vision may split a known label at
 * a word boundary, so only adjacent exact fragments of those labels rejoin.
 */
const CHECKOUT_REVIEW_HEADINGS = [
  "review your pickup order",
  "review your delivery order",
] as const;
const YOUR_ORDER_SECTION = "your order";
const YOUR_PAYMENT_SECTION = "your payment";
const PAYMENT_METHOD_LABEL = "payment method";
/** Other recognized top-level structures. Reaching one ends `Your payment`
 * attribution; none of them opens payment authority. */
const RECEIPT_SECTION = "receipt";
const ORDER_CONFIRMATION_SECTION = "order confirmation";
const ORDER_INFORMATION_SECTION = "order information";
const VIEW_ORDER_TITLE = "view order";
const RE_LINE_QUANTIFIED_ITEM =
  /^(\d{1,2})\s?x?\s+[a-z][a-z'&()-]{2,}(\s+[a-z][a-z'&()-]+){0,6}/;

/** Normalized, non-empty lines. Only CR/LF/CRLF split lines — the same rule
 * the on-device port reproduces — so line attribution cannot drift. */
function normalizedLines(text: string): string[] {
  return text
    .split(/\r\n|\r|\n/)
    .map(normalize)
    .filter((line) => line.length > 0);
}

/** The text after a `Payment method` label on the same line (`""` when the
 * line is the bare label), or `null` when the line is not a Payment method
 * row. A label glued to other letters is not a row. */
function paymentMethodRowRemainder(line: string): string | null {
  if (line === PAYMENT_METHOD_LABEL) return "";
  if (!line.startsWith(PAYMENT_METHOD_LABEL)) return null;
  const rest = line.slice(PAYMENT_METHOD_LABEL.length);
  if (rest.startsWith(" ")) return rest.trim();
  if (rest.startsWith(":")) return rest.slice(1).trim();
  return null;
}

/** Exact known label, whole on one line or split at word boundaries into at
 * most `maxLines` adjacent OCR observations. No arbitrary OCR words are joined. */
function labelSpan(lines: string[], index: number, label: string, maxLines: number): number {
  for (let count = 1; count <= maxLines && index + count <= lines.length; count += 1) {
    if (lines.slice(index, index + count).join(" ") === label) return count;
  }
  return 0;
}

function headingSpan(lines: string[], index: number): number {
  for (const heading of CHECKOUT_REVIEW_HEADINGS) {
    const span = labelSpan(lines, index, heading, 3);
    if (span) return span;
  }
  return 0;
}

function paymentRow(lines: string[], index: number): { span: number; remainder: string } | null {
  const oneLine = paymentMethodRowRemainder(lines[index]!);
  if (oneLine !== null) return { span: 1, remainder: oneLine };
  if (lines[index] === "payment" && index + 1 < lines.length) {
    const second = lines[index + 1]!;
    if (second === "method") return { span: 2, remainder: "" };
    if (second.startsWith("method ")) return { span: 2, remainder: second.slice(7).trim() };
    if (second.startsWith("method:")) return { span: 2, remainder: second.slice(7).trim() };
  }
  return null;
}

/**
 * STRUCTURAL DEPARTURES (boundary recognition only).
 *
 * A departure is a line that shows the screenshot has left the section being
 * attributed (`Your payment` or `Your order`). Recognition here is deliberately
 * separate from positive evidence: a departure ends attribution and never
 * establishes review eligibility, a menu path, or a screenshot category.
 *
 * Each departure is an already-known structural label, either exactly (whole
 * on one line or split across adjacent lines, as for every other label) or with
 * one narrow decoration on its own line: a trailing affordance (`›`, `>`),
 * a `:`/`#` order-reference token (`: 123`), or a trailing price (CTA button).
 * The label must be followed by a delimiter, so `receipts` or `receipt of` are
 * not departures. There is no fuzzy matching and no line-distance cutoff.
 */
type Departure =
  | "your-order" | "your-payment" | "receipt" | "confirmation" | "information"
  | "history" | "view-order" | "heading" | "place-order";

const GENERIC_REVIEW_BOUNDARY = "review your order";
const DEPARTURE_LABELS: ReadonlyArray<readonly [Departure, readonly string[], number]> = [
  ["your-order", [YOUR_ORDER_SECTION], 2],
  ["your-payment", [YOUR_PAYMENT_SECTION], 2],
  ["receipt", [RECEIPT_SECTION], 2],
  ["confirmation", [ORDER_CONFIRMATION_SECTION], 2],
  ["information", [ORDER_INFORMATION_SECTION], 2],
  ["history", ["order history", "past order", "past orders"], 2],
  ["view-order", [VIEW_ORDER_TITLE], 2],
  ["heading", CHECKOUT_REVIEW_HEADINGS, 3],
  ["place-order", ["place your order", "place your pickup order", "place your delivery order"], 3],
];

/** What may follow a departure label on its line (lines are normalized, so the
 * only whitespace is a single space). */
const DEPARTURE_DECORATION =
  /^(?: ?[>\u203A\u00BB\u276F\u2192\u2022\u00B7|\u2013\u2014-]| ?[:#] ?[a-z0-9][a-z0-9-]{0,31}| ?\$[0-9][0-9.,]*)*$/;

function decoratedLabel(line: string, label: string): boolean {
  return line.length > label.length && line.startsWith(label) &&
    DEPARTURE_DECORATION.test(line.slice(label.length));
}

function departureAt(lines: string[], index: number): Departure | null {
  if (lines[index] === GENERIC_REVIEW_BOUNDARY) return "heading";
  for (const [kind, labels, maxLines] of DEPARTURE_LABELS) {
    for (const label of labels) {
      if (labelSpan(lines, index, label, maxLines) > 0 || decoratedLabel(lines[index]!, label)) {
        return kind;
      }
    }
  }
  return null;
}

/** First departure at or after `from`, optionally ignoring `Your order`
 * (a second `Your order` heading does not leave the order section). */
function firstDeparture(lines: string[], from: number, ignoreYourOrder: boolean): number {
  for (let i = from; i < lines.length; i += 1) {
    const kind = departureAt(lines, i);
    if (kind !== null && !(ignoreYourOrder && kind === "your-order")) return i;
  }
  return lines.length;
}

/** The one bounded `Your payment` section, or `null` when the heading is
 * absent or duplicated, including a decorated duplicate (ambiguous payment
 * structure fails closed). Only the exact label opens the section. */
function paymentSection(lines: string[]): { start: number; end: number } | null {
  const starts = lines.flatMap((_line, index) =>
    labelSpan(lines, index, YOUR_PAYMENT_SECTION, 2) > 0 ? [index] : []);
  if (starts.length !== 1) return null;
  const start = starts[0]!;
  const span = labelSpan(lines, start, YOUR_PAYMENT_SECTION, 2);
  for (let i = 0; i < lines.length; i += 1) {
    if ((i < start || i >= start + span) && departureAt(lines, i) === "your-payment") return null;
  }
  const contentStart = start + span;
  return { start: contentStart, end: firstDeparture(lines, contentStart, false) };
}

function paymentRows(lines: string[]): Array<{ index: number; span: number; remainder: string }> {
  const rows: Array<{ index: number; span: number; remainder: string }> = [];
  for (let i = 0; i < lines.length; i += 1) {
    const row = paymentRow(lines, i);
    if (row) {
      rows.push({ index: i, ...row });
      i += row.span - 1;
    }
  }
  return rows;
}

function isCheckoutReview(lines: string[]): boolean {
  const headings = lines.flatMap((_line, index) => headingSpan(lines, index) ? [index] : []);
  if (headings.length !== 1) return false;
  const payment = paymentSection(lines);
  const orderIndex = lines.findIndex((_line, index) => labelSpan(lines, index, YOUR_ORDER_SECTION, 2) > 0);
  if (orderIndex >= 0) {
    // `Your order` ends at the first structural departure after it (first
    // later `Your payment`, receipt/confirmation/history, ...), whether or not
    // the payment section there is valid, duplicated, or malformed.
    const contentStart = orderIndex + labelSpan(lines, orderIndex, YOUR_ORDER_SECTION, 2);
    const end = firstDeparture(lines, contentStart, true);
    for (let i = contentStart; i < end; i += 1) {
      if (RE_LINE_QUANTIFIED_ITEM.test(lines[i]!)) return true;
    }
  }
  if (!payment || payment.start <= headings[0]!) return false;
  const rows = paymentRows(lines);
  return rows.length === 1 && rows[0]!.index >= payment.start && rows[0]!.index < payment.end;
}

function nonWhitespaceCharCount(text: string): number {
  return text.replace(/\s+/g, "").length;
}

function cartChromeCount(normalized: string): number {
  let count = 0;
  for (const phrase of CART_CHROME_PHRASES) {
    if (!normalized.includes(phrase)) continue;
    if (
      phrase === "your pickup order" &&
      (normalized.includes("review your pickup order") ||
        normalized.includes("place your pickup order"))
    ) {
      continue;
    }
    if (
      phrase === "your delivery order" &&
      (normalized.includes("review your delivery order") ||
        normalized.includes("place your delivery order"))
    ) {
      continue;
    }
    count += 1;
  }
  return count;
}

export type EligibleCategory = "cart" | "historical" | "checkout";

export interface EligibilityResult {
  eligible: boolean;
  category: EligibleCategory | null;
}

/**
 * Evaluates the accepted V1-C1-or-H5 rule, plus the W4-R4.1 checkout/review
 * category, against literal evidence text.
 * Never sees a fixture id, filename, or ground-truth label — only the text.
 */
export function evaluateEligibility(evidenceText: string): EligibilityResult {
  const nonWhitespaceChars = nonWhitespaceCharCount(evidenceText);
  if (nonWhitespaceChars < LEGIBILITY_MIN_NON_WHITESPACE_CHARS) {
    return { eligible: false, category: null };
  }

  // Checkout/review is classified first so a checkout screenshot is never
  // admitted as "cart" merely because it also carries a cart phrase.
  if (isCheckoutReview(normalizedLines(evidenceText))) {
    return { eligible: true, category: "checkout" };
  }

  const normalized = normalize(evidenceText);
  if (cartChromeCount(normalized) >= 1) {
    return { eligible: true, category: "cart" };
  }

  const detailedHistoryCore =
    RE_VIEW_ORDER.test(normalized) &&
    RE_ORDER_INFORMATION.test(normalized) &&
    RE_QUANTIFIED_ITEM.test(normalized);
  if (detailedHistoryCore) {
    return { eligible: true, category: "historical" };
  }

  return { eligible: false, category: null };
}

/**
 * Independent "1M" meal-swipe corroboration signal (unchanged from the
 * qualification harness). A candidate `mealSwipes` value survives only when
 * the literal marker count in the independent evidence text equals the
 * candidate exactly — evidence, not a guess from item count or price, and
 * never counted against anything the provider itself returned.
 */
const MEAL_SWIPE_MARKER_PATTERN = /\b1\s?M\b/g;

/**
 * Explicit aggregate Grubhub resource notation. The leading guard prevents a
 * suffix of a decimal (for example `3.0M`) or a longer word/number from being
 * treated as a valid total. Uppercase `M` is intentional: this recognizes the
 * literal provider notation already covered by the contract, not arbitrary
 * prose containing the letter m.
 */
const EXPLICIT_MEAL_SWIPE_TOTAL_PATTERN = /(?<![\w.])(\d{1,2})\s?M\b/g;
const MIN_MEAL_SWIPE_TOTAL = 1;
const MAX_MEAL_SWIPE_TOTAL = 5;

export function hasExplicitMealSwipeNotation(evidenceText: string): boolean {
  EXPLICIT_MEAL_SWIPE_TOTAL_PATTERN.lastIndex = 0;
  const present = EXPLICIT_MEAL_SWIPE_TOTAL_PATTERN.test(evidenceText);
  EXPLICIT_MEAL_SWIPE_TOTAL_PATTERN.lastIndex = 0;
  return present;
}

/** Count validated quantity-one meal lines only when each has its own
 * top-level OCR line. This never resolves the menu path or an explicit M
 * conflict; callers enforce those guards before using the result. */
export function inferredMealSwipeCount(
  mealItems: readonly { name: string }[],
  imageEvidenceTexts: readonly string[]
): number | null {
  if (mealItems.length < 2 || mealItems.length > 5) return null;
  const names: string[] = [];
  for (const item of mealItems) {
    const match = /^1 (.+)$/.exec(normalize(item.name));
    if (!match) return null;
    names.push(match[1]!);
  }
  if (imageEvidenceTexts.length > 1 && new Set(names).size !== names.length) return null;

  const candidates: string[] = [];
  const isTopLevelName = (name: string): boolean =>
    name.length > 0 && !/^[*•●▪◦–—-]/.test(name);
  for (const text of imageEvidenceTexts) {
    const lines = normalizedLines(text);
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index]!;
      if (line.startsWith("1 ") && isTopLevelName(line.slice(2))) candidates.push(line);
      if (line === "1" && index + 1 < lines.length && isTopLevelName(lines[index + 1]!)) {
        candidates.push(`1 ${lines[index + 1]!}`);
      }
    }
  }
  const used = new Set<number>();
  // A shorter name can prefix a longer one. Ground the longer one first so
  // an otherwise valid pair does not consume the only specific OCR line.
  for (const name of [...names].sort((a, b) => b.length - a.length)) {
    const prefix = `1 ${name}`;
    const index = candidates.findIndex((line, at) =>
      !used.has(at) && (line === prefix || line.startsWith(`${prefix} `))
    );
    if (index < 0) return null;
    used.add(index);
  }
  return names.length;
}

export function countMealSwipeMarkers(evidenceText: string): number {
  return (evidenceText.match(MEAL_SWIPE_MARKER_PATTERN) || []).length;
}

/**
 * Resolves independent OCR evidence to one explicit meal-swipe count without
 * manufacturing a proposal. Literal `1M` markers retain the accepted S1
 * behavior: in the absence of an aggregate total, each marker represents one
 * swipe and the markers are counted. Numeric values above one are explicit
 * aggregate totals (`2M` ... `5M`): repeated observations of the same total
 * are overlap, not addition.
 *
 * Conflicting aggregate totals, or any explicit numeric M observation outside
 * the accepted 1...5 Meal Exchange bounds, fail closed. Per-item `1M` markers
 * may coexist with an aggregate total; the explicit aggregate is authoritative
 * evidence for the count rather than a value derived from those markers.
 */
export function corroboratedMealSwipeCount(evidenceText: string): number | null {
  const observedValues = Array.from(
    evidenceText.matchAll(EXPLICIT_MEAL_SWIPE_TOTAL_PATTERN),
    (match) => Number(match[1])
  );

  if (observedValues.length === 0) return null;
  if (
    observedValues.some(
      (value) => value < MIN_MEAL_SWIPE_TOTAL || value > MAX_MEAL_SWIPE_TOTAL
    )
  ) {
    return null;
  }

  const aggregateTotals = new Set(observedValues.filter((value) => value > 1));
  if (aggregateTotals.size > 1) return null;
  if (aggregateTotals.size === 1) return aggregateTotals.values().next().value ?? null;

  const markerCount = observedValues.length;
  return markerCount <= MAX_MEAL_SWIPE_TOTAL ? markerCount : null;
}

/**
 * W4-R4.1 deterministic menu-path evidence. The path is resolved ONLY from
 * independent on-device OCR text of eligible screenshots — never from
 * provider output or venue plausibility — and
 * `screenshotProposalValidation.ts` is the one place it enters a proposal.
 *
 * Meal Exchange evidence (any eligible screenshot):
 *  - explicit provider venue/menu identity containing `Meal Exchange`
 *    (no swipe count by itself), or
 *  - bounded literal `1M`..`5M` notation that the existing deterministic
 *    meal-swipe rule resolves without conflict (`corroboratedMealSwipeCount`,
 *    over the combined eligible evidence).
 * A provider's meal-based payment wording, including `Use 1 Meal + Dining
 * Dollars`, is Meal Exchange evidence without establishing a swipe count;
 * when a checkout row is present, its selected value must be uniquely
 * attributable inside the bounded payment section.
 *
 * Dining Dollars evidence: either the selected `Payment method` row on an
 * eligible review, or a supported current cart with one unambiguous labeled
 * order Total and no Meal Exchange evidence. A payment row alone supplies no
 * amount; the labeled Total is validated independently.
 *
 * Accepted evidence for both paths is a conflict: nothing is proposed and the
 * caller must omit branch-dependent values too.
 */
export type ProposedMenuPath = "meal-exchange" | "dining-dollars";

export interface MenuPathResolution {
  menuPath: ProposedMenuPath | null;
  /** Meal Exchange and Dining Dollars evidence both present. */
  conflict: boolean;
}

/** Privacy-safe relation evidence derived on device from one image's Vision
 * observations. `id` is that observation's flattened-line index. Coordinates
 * are deliberately absent; the backend trusts only the two narrow relation
 * claims and independently validates every text-derived fact. */
export interface TotalGeometryEvidence {
  observations: Array<
    | {
        id: number;
        classification: "total-label";
        geometryValid: boolean;
      }
    | {
        id: number;
        classification: "amount";
        cents: number;
        geometryValid: boolean;
      }
  >;
  relations: Array<{
    totalObservationID: number;
    amountObservationID: number;
    sameRow: boolean;
    rightOf: boolean;
  }>;
}

const RE_MEAL_EXCHANGE_IDENTITY = /^(?:meal exchange|.+ - meal exchange)$/;
const RE_MEAL_PAYMENT = /^(?:payment method:? )?use [1-5] meals? \+ dining dollars$/;
const DINING_DOLLARS_VALUE = "dining dollars";
const TRAILING_AFFORDANCE = /[\s>›»❯〈〉〉→]+$/;
const RE_TOTAL_WITH_AMOUNT = /^total\s+\$([0-9]{1,4})(?:\.([0-9]{2}))?$/;
const RE_AMOUNT_ONLY = /^\$([0-9]{1,4})(?:\.([0-9]{2}))?$/;
// Match the on-device normalized-letter boundaries. A tender label followed
// by account digits (for example Visa1234) remains conflicting tender text.
const RE_SPLIT_TENDER = /(?<![a-z])(?:split payment|split tender|multiple payment methods)(?![a-z])/;
const RE_OTHER_TENDER = /^(?:visa|mastercard|amex|american express|credit card|debit card|apple pay)(?![a-z])/;
const RE_MIXED_TENDER = /^(?:dining dollars|use [1-5] meals? \+ dining dollars) (?:and|\+) (?:visa|mastercard|amex|american express|credit card|debit card|apple pay)(?![a-z])/;
const RE_DINING_TENDER_AMOUNT = /^dining dollars\s+\$[0-9]/;
const RE_OTHER_TENDER_AMOUNT = /^(?:visa|mastercard|amex|american express|credit card|debit card|apple pay)(?![a-z]).*\$[0-9]/;

type PaymentRowState = "none" | "dining-dollars" | "meal-exchange" | "other";

function selectedTender(value: string): "dining-dollars" | "meal-exchange" | null {
  const bare = value.replace(TRAILING_AFFORDANCE, "");
  if (bare === DINING_DOLLARS_VALUE) return "dining-dollars";
  return RE_MEAL_PAYMENT.test(value) ? "meal-exchange" : null;
}

/** One observation may be crossed only when it has no independent payment or
 * structural authority. Its text never contributes evidence to the result. */
function inertPaymentObservation(lines: string[], index: number): boolean {
  const line = lines[index]!;
  return departureAt(lines, index) === null && paymentRow(lines, index) === null &&
    selectedTender(line) === null && !RE_OTHER_TENDER.test(line) &&
    !RE_MIXED_TENDER.test(line) &&
    !RE_SPLIT_TENDER.test(line) && !RE_DINING_TENDER_AMOUNT.test(line) &&
    !RE_OTHER_TENDER_AMOUNT.test(line) && !RE_MEAL_EXCHANGE_IDENTITY.test(line) &&
    !hasExplicitMealSwipeNotation(line) && !RE_TOTAL_WITH_AMOUNT.test(line) &&
    line !== "total" && !RE_AMOUNT_ONLY.test(line);
}

function hasMealExchangeIdentity(lines: readonly string[]): boolean {
  return lines.some((line, index) =>
    RE_MEAL_EXCHANGE_IDENTITY.test(line) ||
    (line === "meal" && lines[index + 1] === "exchange") ||
    (line.endsWith(" - meal") && lines[index + 1] === "exchange")
  );
}

function checkoutPaymentRowState(lines: string[]): PaymentRowState {
  const rows = paymentRows(lines);
  if (rows.length === 0) return "none";
  const section = paymentSection(lines);
  if (rows.length !== 1 || !section) return "other";
  const row = rows[0]!;
  if (row.index < section.start || row.index + row.span > section.end) return "other";
  const valueIndex = row.index + row.span;
  let tender = row.remainder.length > 0 ? selectedTender(row.remainder) : null;
  let tenderIndex = row.remainder.length > 0 ? row.index : valueIndex;
  if (row.remainder.length === 0) {
    if (valueIndex >= section.end) return "other";
    tender = selectedTender(lines[valueIndex]!);
    if (tender === null && inertPaymentObservation(lines, valueIndex) && valueIndex + 1 < section.end) {
      tenderIndex = valueIndex + 1;
      tender = selectedTender(lines[tenderIndex]!);
    }
  }
  if (tender === null) return "other";

  // Exactly one recognized tender belongs to this row. A second canonical
  // value, another known tender, or split payment makes attribution ambiguous.
  const recognized = lines.slice(section.start, section.end).flatMap((line, offset) => {
    const index = section.start + offset;
    if (index === row.index) return row.remainder && selectedTender(row.remainder) ? [index] : [];
    return selectedTender(line) ? [index] : [];
  });
  if (recognized.length !== 1 || recognized[0] !== tenderIndex ||
      lines.slice(section.start, section.end).some((line) =>
        RE_OTHER_TENDER.test(line) || RE_MIXED_TENDER.test(line) || RE_SPLIT_TENDER.test(line)) ||
      RE_OTHER_TENDER.test(lines[section.end] ?? "")) return "other";
  return tender;
}

/** A final order Total, bounded to eligible current cart/review screens.
 * A label/value pair must be exact; item prices, subtotal, tax and fees never
 * pass. Conflicting totals across one logical selection fail closed. */
function textOnlyCurrentOrderTotalCents(
  imageEvidenceTexts: readonly string[],
  withinEstimateBounds = true
): number | null {
  const totals: number[] = [];
  let diningTenderAmount = false;
  let otherTenderAmount = false;
  for (const text of imageEvidenceTexts) {
    const eligibility = evaluateEligibility(text);
    if (!eligibility.eligible || eligibility.category === "historical") continue;
    const lines = normalizedLines(text);
    if (lines.some((line) => RE_SPLIT_TENDER.test(line))) return null;
    diningTenderAmount ||= lines.some((line) => RE_DINING_TENDER_AMOUNT.test(line));
    otherTenderAmount ||= lines.some((line) => RE_OTHER_TENDER_AMOUNT.test(line));
    if (eligibility.category === "checkout" &&
        !["none", "dining-dollars"].includes(checkoutPaymentRowState(lines))) return null;
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index]!;
      const match = RE_TOTAL_WITH_AMOUNT.exec(line) ??
        (line === "total" ? RE_AMOUNT_ONLY.exec(lines[index + 1] ?? "") : null);
      if (line === "total" && !match) return null;
      if (!match) continue;
      totals.push(Number(match[1]) * 100 + Number(match[2] ?? "0"));
    }
  }
  if (diningTenderAmount && otherTenderAmount) return null;
  if (totals.length === 0 || new Set(totals).size !== 1) return null;
  const cents = totals[0]!;
  return !withinEstimateBounds || (cents >= 1 && cents <= 5_000) ? cents : null;
}

function normalizedObservationLines(text: string): string[] {
  return text.split(/\r\n|\r|\n/).map(normalize);
}

type GeometryValidation =
  | { ok: true; cents: number }
  | { ok: false };

/** Validate the complete per-image relation claim against every deterministic
 * fact the backend can recompute from `localEvidenceText`. Raw geometry is not
 * available here and is intentionally not claimed to be independently
 * verified. */
function validateTotalGeometryEvidence(
  evidenceText: string,
  evidence: TotalGeometryEvidence | undefined
): GeometryValidation {
  if (!evidence) return { ok: false };
  const lines = normalizedObservationLines(evidenceText);
  const expected: Array<{
    id: number;
    classification: "total-label" | "amount";
    cents?: number;
  }> = [];
  lines.forEach((line, id) => {
    if (line === "total") {
      expected.push({ id, classification: "total-label" });
      return;
    }
    const amount = RE_AMOUNT_ONLY.exec(line);
    if (amount) {
      expected.push({
        id,
        classification: "amount",
        cents: Number(amount[1]) * 100 + Number(amount[2] ?? "0"),
      });
    }
  });
  if (evidence.observations.length !== expected.length) return { ok: false };

  const byID = new Map<number, TotalGeometryEvidence["observations"][number]>();
  for (const observation of evidence.observations) {
    if (byID.has(observation.id)) return { ok: false };
    byID.set(observation.id, observation);
  }
  for (const item of expected) {
    const supplied = byID.get(item.id);
    if (!supplied || supplied.classification !== item.classification ||
        !supplied.geometryValid) return { ok: false };
    if (item.classification === "amount" && supplied.classification === "amount" &&
        supplied.cents !== item.cents) return { ok: false };
  }

  const totalIDs = expected.filter((item) => item.classification === "total-label").map((item) => item.id);
  const amountIDs = expected.filter((item) => item.classification === "amount").map((item) => item.id);
  if (totalIDs.length !== 1) return { ok: false };
  const expectedPairs = new Set(totalIDs.flatMap((totalID) =>
    amountIDs.map((amountID) => `${totalID}:${amountID}`)));
  if (evidence.relations.length !== expectedPairs.size) return { ok: false };

  let qualifyingAmountID: number | null = null;
  const seenPairs = new Set<string>();
  for (const relation of evidence.relations) {
    const key = `${relation.totalObservationID}:${relation.amountObservationID}`;
    if (!expectedPairs.has(key) || seenPairs.has(key)) return { ok: false };
    seenPairs.add(key);
    if (relation.sameRow && relation.rightOf) {
      if (qualifyingAmountID !== null) return { ok: false };
      qualifyingAmountID = relation.amountObservationID;
    }
  }
  if (qualifyingAmountID === null) return { ok: false };
  const amount = byID.get(qualifyingAmountID);
  return amount?.classification === "amount" ? { ok: true, cents: amount.cents } : { ok: false };
}

/** Existing valid text-only association wins unchanged. Geometry is considered
 * only when that exact rule cannot establish one Total for the selection. */
export function currentOrderTotalCents(
  imageEvidenceTexts: readonly string[],
  withinEstimateBounds = true,
  imageTotalGeometryEvidence: readonly (TotalGeometryEvidence | undefined)[] = []
): number | null {
  const textOnly = textOnlyCurrentOrderTotalCents(imageEvidenceTexts, withinEstimateBounds);
  if (textOnly !== null) return textOnly;

  const totals: number[] = [];
  let diningTenderAmount = false;
  let otherTenderAmount = false;
  for (const [imageIndex, text] of imageEvidenceTexts.entries()) {
    const eligibility = evaluateEligibility(text);
    if (!eligibility.eligible || eligibility.category === "historical") continue;
    const lines = normalizedLines(text);
    if (lines.some((line) => RE_SPLIT_TENDER.test(line))) return null;
    diningTenderAmount ||= lines.some((line) => RE_DINING_TENDER_AMOUNT.test(line));
    otherTenderAmount ||= lines.some((line) => RE_OTHER_TENDER_AMOUNT.test(line));
    if (eligibility.category === "checkout" &&
        !["none", "dining-dollars"].includes(checkoutPaymentRowState(lines))) return null;

    const totalsBeforeImage = totals.length;
    let needsGeometry = false;
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index]!;
      const inline = RE_TOTAL_WITH_AMOUNT.exec(line);
      if (inline) {
        totals.push(Number(inline[1]) * 100 + Number(inline[2] ?? "0"));
      } else if (line === "total") {
        const adjacent = RE_AMOUNT_ONLY.exec(lines[index + 1] ?? "");
        if (adjacent) {
          totals.push(Number(adjacent[1]) * 100 + Number(adjacent[2] ?? "0"));
        } else {
          needsGeometry = true;
        }
      }
    }
    if (needsGeometry) {
      // Geometry may resolve one otherwise-unassociated exact Total label in
      // this image; it may not coexist with another text-associated Total.
      if (totals.length !== totalsBeforeImage) return null;
      const result = validateTotalGeometryEvidence(text, imageTotalGeometryEvidence[imageIndex]);
      if (!result.ok) return null;
      totals.push(result.cents);
    }
  }
  if (diningTenderAmount && otherTenderAmount) return null;
  if (totals.length === 0 || new Set(totals).size !== 1) return null;
  const cents = totals[0]!;
  return !withinEstimateBounds || (cents >= 1 && cents <= 5_000) ? cents : null;
}

/**
 * The evidence that may carry the pre-existing current-cart/order-level
 * Meal Exchange TOP-UP authority: every screenshot except checkout/review,
 * joined as combined evidence. A review's `3M + $2.00` never becomes a
 * top-up. This is separate from the new labeled whole-order Total rule.
 */
export function amountAuthorityEvidenceText(imageEvidenceTexts: readonly string[]): string {
  return imageEvidenceTexts
    .filter((text) => evaluateEligibility(text).category !== "checkout")
    .join("\n");
}

export function resolveMenuPath(
  imageEvidenceTexts: readonly string[],
  imageTotalGeometryEvidence: readonly (TotalGeometryEvidence | undefined)[] = []
): MenuPathResolution {
  const eligible = imageEvidenceTexts.filter((text) => evaluateEligibility(text).eligible);
  const hasAnyExplicitM = eligible.some(hasExplicitMealSwipeNotation);

  let mealExchangeEvidence = false;
  let diningDollarsRows = 0;
  let otherPaymentRows = 0;
  let currentCartWithTotal = false;
  for (const [imageIndex, text] of imageEvidenceTexts.entries()) {
    if (!evaluateEligibility(text).eligible) continue;
    const lines = normalizedLines(text);
    const category = evaluateEligibility(text).category;
    if (hasMealExchangeIdentity(lines) ||
        ((category !== "checkout" || paymentRows(lines).length === 0) &&
          lines.some((line) => RE_MEAL_PAYMENT.test(line)))) {
      mealExchangeEvidence = true;
    }
    if (category === "cart" &&
        !hasMealExchangeIdentity(lines) &&
        !hasExplicitMealSwipeNotation(text) &&
        !lines.some((line) => RE_MEAL_PAYMENT.test(line)) &&
        currentOrderTotalCents(
          [text], false, [imageTotalGeometryEvidence[imageIndex]]
        ) !== null) {
      currentCartWithTotal = true;
    }
    if (category === "checkout") {
      const state = checkoutPaymentRowState(lines);
      if (state === "dining-dollars") diningDollarsRows += 1;
      if (state === "meal-exchange") mealExchangeEvidence = true;
      if (state === "other") otherPaymentRows += 1;
    }
  }
  if (corroboratedMealSwipeCount(eligible.join("\n")) !== null) mealExchangeEvidence = true;

  const diningDollarsEvidence =
    (diningDollarsRows > 0 && otherPaymentRows === 0) ||
    (currentCartWithTotal && otherPaymentRows === 0 &&
      currentOrderTotalCents(
        imageEvidenceTexts, false, imageTotalGeometryEvidence
      ) !== null &&
      // Unresolved M elsewhere cannot grant the cart path. An independently
      // established Meal Exchange signal still exposes the existing conflict.
      (!hasAnyExplicitM || mealExchangeEvidence));
  if (mealExchangeEvidence && diningDollarsEvidence) {
    return { menuPath: null, conflict: true };
  }
  if (mealExchangeEvidence) return { menuPath: "meal-exchange", conflict: false };
  if (diningDollarsEvidence) return { menuPath: "dining-dollars", conflict: false };
  return { menuPath: null, conflict: false };
}
