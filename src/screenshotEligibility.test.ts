import { describe, expect, it } from "vitest";
import {
  amountAuthorityEvidenceText,
  corroboratedMealSwipeCount,
  countMealSwipeMarkers,
  currentOrderTotalCents,
  evaluateEligibility,
  resolveMenuPath,
  type TotalGeometryEvidence,
} from "./screenshotEligibility.js";

describe("evaluateEligibility", () => {
  it("rejects an illegible/near-empty transcription", () => {
    expect(evaluateEligibility("hi")).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("accepts a Grubhub cart/bag screenshot via cart chrome", () => {
    const text =
      "Your Pickup Order Order Instructions Cilantro on the side Continue to Checkout";
    expect(evaluateEligibility(text)).toEqual({
      eligible: true,
      category: "cart",
    });
  });

  it("rejects review checkout screens even though they contain cart phrases as substrings", () => {
    const text =
      "Review your pickup order Review your delivery order please confirm this order today";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects a place-your-delivery-order checkout screen", () => {
    const text =
      "Order total is $13.00 Place\nYOUR   delivery order: 2M + $2.50";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects a place-your-pickup-order checkout screen", () => {
    const text = "Order total is $8.00 Place your pickup order to confirm";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("accepts a detailed historical order via the H5 core (view order + order information + quantified item)", () => {
    const text =
      "View order Order information 1 Create Your Own Bowl completed on July 4";
    expect(evaluateEligibility(text)).toEqual({
      eligible: true,
      category: "historical",
    });
  });

  it("rejects a historical screenshot missing the quantified item line", () => {
    const text = "View order Order information completed on July 4";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects an Orders-list/index screen (no single-order detail heading)", () => {
    const text =
      "Your Orders Past Orders Completed Reorder 1 Create Your Own Bowl";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects a menu/browse screen", () => {
    const text =
      "Popular items Chicken Bowl Vegetable Bowl Add to cart Free delivery over $12";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects a non-Grubhub screenshot", () => {
    const text = "Uber Eats Your order has been delivered Rate your order";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects adversarial vocabulary imitation that stays below legibility/rule thresholds", () => {
    const text = "view order order information";
    // Two required headings present but no quantified item line: still
    // rejected — the rule requires all three signals, not brand vocabulary
    // alone.
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });
});

describe("bounded device-derived Total geometry", () => {
  const cartLines = [
    "Your Pickup Order", "Continue to Checkout", "1 Bowl", "$9.00",
    "Items subtotal", "$14.00", "Sales tax", "$1.45", "Total", "Order actions", "$15.45",
  ];
  const cart = cartLines.join("\n");
  const observations: TotalGeometryEvidence["observations"] = [
    { id: 3, classification: "amount", cents: 900, geometryValid: true },
    { id: 5, classification: "amount", cents: 1_400, geometryValid: true },
    { id: 7, classification: "amount", cents: 145, geometryValid: true },
    { id: 8, classification: "total-label", geometryValid: true },
    { id: 10, classification: "amount", cents: 1_545, geometryValid: true },
  ];
  const evidence = (qualifyingAmountIDs: number[]): TotalGeometryEvidence => ({
    observations: observations.map((item) => ({ ...item })),
    relations: [3, 5, 7, 10].map((amountObservationID) => ({
      totalObservationID: 8,
      amountObservationID,
      sameRow: qualifyingAmountIDs.includes(amountObservationID),
      rightOf: qualifyingAmountIDs.includes(amountObservationID),
    })),
  });

  it("accepts one complete, internally consistent same-row/right-side relation", () => {
    expect(currentOrderTotalCents([cart], true, [evidence([10])])).toBe(1_545);
    expect(resolveMenuPath([cart], [evidence([10])])).toEqual({
      menuPath: "dining-dollars", conflict: false,
    });
  });

  it("preserves an existing valid text-only Total without geometry", () => {
    const textOnly = "Your Pickup Order\nContinue to Checkout\nTotal\n$15.45";
    expect(currentOrderTotalCents([textOnly])).toBe(1_545);
    expect(resolveMenuPath([textOnly])).toEqual({ menuPath: "dining-dollars", conflict: false });
  });

  it.each([
    ["no qualifying relation", evidence([])],
    ["two qualifying relations", evidence([7, 10])],
    ["missing evidence", undefined],
  ])("fails closed for %s", (_name, geometry) => {
    expect(currentOrderTotalCents([cart], true, [geometry])).toBeNull();
    expect(resolveMenuPath([cart], [geometry])).toEqual({ menuPath: null, conflict: false });
  });

  it("fails closed for unknown IDs, duplicate/contradictory pairs, and incomplete matrices", () => {
    const unknown = evidence([10]);
    unknown.relations[3] = { ...unknown.relations[3]!, amountObservationID: 99 };
    const duplicate = evidence([10]);
    duplicate.relations[2] = { ...duplicate.relations[3]!, sameRow: false, rightOf: false };
    const incomplete = evidence([10]);
    incomplete.relations.pop();
    for (const malformed of [unknown, duplicate, incomplete]) {
      expect(currentOrderTotalCents([cart], true, [malformed])).toBeNull();
    }
  });

  it("fails closed for class, cents, and geometry-validity mismatches", () => {
    const wrongClass = evidence([10]);
    wrongClass.observations = wrongClass.observations.map((item) =>
      item.id === 8
        ? { id: 8, classification: "amount", cents: 1_545, geometryValid: true }
        : item);
    const wrongCents = evidence([10]);
    wrongCents.observations = wrongCents.observations.map((item) =>
      item.id === 10 && item.classification === "amount" ? { ...item, cents: 1_544 } : item);
    const invalidGeometry = evidence([10]);
    invalidGeometry.observations = invalidGeometry.observations.map((item) =>
      item.id === 5 ? { ...item, geometryValid: false } : item);
    for (const malformed of [wrongClass, wrongCents, invalidGeometry]) {
      expect(currentOrderTotalCents([cart], true, [malformed])).toBeNull();
    }
  });

  it("requires one exact Total label and fails closed on a second Total", () => {
    const text = `${cart}\nTotal`;
    const malformed = evidence([10]);
    malformed.observations.push({ id: 11, classification: "total-label", geometryValid: true });
    malformed.relations.push(...[3, 5, 7, 10].map((amountObservationID) => ({
      totalObservationID: 11, amountObservationID, sameRow: false, rightOf: false,
    })));
    expect(currentOrderTotalCents([text], true, [malformed])).toBeNull();
  });

  it("never forms a relation across images", () => {
    const labelImage = "Your Pickup Order\nContinue to Checkout\nTotal";
    const amountImage = "Your Pickup Order\nContinue to Checkout\n$15.45";
    const labelEvidence: TotalGeometryEvidence = {
      observations: [{ id: 2, classification: "total-label", geometryValid: true }],
      relations: [{
        totalObservationID: 2, amountObservationID: 2, sameRow: true, rightOf: true,
      }],
    };
    expect(currentOrderTotalCents([labelImage, amountImage], true, [labelEvidence, undefined]))
      .toBeNull();
  });

  it("does not choose item, subtotal, tax, largest, last, or arithmetic values", () => {
    // Merely existing, being largest/last, or adding to another amount grants
    // no authority. Only the supplied Total relation can select a value.
    expect(currentOrderTotalCents([cart], true, [evidence([])])).toBeNull();
    expect(currentOrderTotalCents([cart], true, [evidence([10])])).toBe(1_545);
  });

  it("preserves cross-image conflict semantics", () => {
    const other = "Your Pickup Order\nContinue to Checkout\nTotal $12.00";
    expect(currentOrderTotalCents([cart, other], true, [evidence([10]), undefined])).toBeNull();
    expect(resolveMenuPath([cart, other], [evidence([10]), undefined])).toEqual({
      menuPath: null, conflict: false,
    });
  });
});

describe("countMealSwipeMarkers", () => {
  it("counts literal 1M markers", () => {
    expect(countMealSwipeMarkers("1M 1M 1M")).toBe(3);
    expect(countMealSwipeMarkers("Meals used (1M = $8.00)")).toBe(1);
  });

  it("returns zero when no marker is present", () => {
    expect(countMealSwipeMarkers("2 items, $14.00 total")).toBe(0);
  });

  it("does not count a numeric distractor that isn't the exact marker", () => {
    expect(countMealSwipeMarkers("Order #1234, 15 items")).toBe(0);
  });
});

describe("corroboratedMealSwipeCount", () => {
  it.each([
    ["1M", 1],
    ["2M", 2],
    ["3M + $2.00", 3],
    ["4M", 4],
    ["5 M", 5],
  ])("recognizes explicit bounded M notation in %s", (evidence, expected) => {
    expect(corroboratedMealSwipeCount(evidence)).toBe(expected);
  });

  it("keeps the accepted per-item 1M marker-count behavior", () => {
    expect(corroboratedMealSwipeCount("1M 1 M 1M")).toBe(3);
  });

  it("deduplicates repeated identical aggregate totals from overlap", () => {
    expect(corroboratedMealSwipeCount("3M + $2.00\n3 M + $2.00")).toBe(3);
  });

  it("fails closed for conflicting aggregate totals", () => {
    expect(corroboratedMealSwipeCount("2M\n3M")).toBeNull();
  });

  it("fails closed for an out-of-bounds explicit total", () => {
    expect(corroboratedMealSwipeCount("6M")).toBeNull();
    expect(corroboratedMealSwipeCount("3M 6M")).toBeNull();
    expect(corroboratedMealSwipeCount("0M")).toBeNull();
  });

  it("does not infer from malformed or non-M notation", () => {
    for (const evidence of ["M3", "3MM", "3.0M", "three M", "$2.00"]) {
      expect(corroboratedMealSwipeCount(evidence), evidence).toBeNull();
    }
  });
});

describe("W4-R4.1 checkout/review eligibility category", () => {
  const checkout = { eligible: true, category: "checkout" };
  const ineligible = { eligible: false, category: null };

  it.each([
    ["pickup heading with a Your order item line", "Review your pickup order\nYour order\n1 Chicken Bowl\nSubtotal 12.00"],
    ["delivery heading with a Your order item line", "Review your delivery order\nYour order\n2x Chicken Bowl\nSubtotal 12.00"],
    ["pickup heading with a Your payment/Payment method row", "Review your pickup order\nYour payment\nPayment method\nDining Dollars"],
    ["delivery heading with an inline Payment method row", "Review your delivery order\nYour payment\nPayment method Visa"],
    ["authorized pickup heading with split labels and later row", "Review your\npickup order\nYour\npayment\nSubtotal 12.00\nPayment\nmethod\nDining Dollars"],
  ])("accepts %s", (_name, text) => {
    expect(evaluateEligibility(text)).toEqual(checkout);
  });

  it("classifies checkout/review before the cart rule can admit it", () => {
    expect(
      evaluateEligibility(
        "Review your pickup order\nYour order\n1 Chicken Bowl\nOrder instructions\nAdd more items"
      )
    ).toEqual(checkout);
  });

  it.each([
    ["the heading alone", "Review your pickup order\nTotal due today\nEstimated total 12.00"],
    ["Your order without a quantity-prefixed item line", "Review your pickup order\nYour order\nSubtotal 12.00\nTax 1.06"],
    ["Your payment without a Payment method row", "Review your pickup order\nYour payment\nSubtotal 12.00\nTotal 13.06"],
    ["an item line that falls after the Your order section ended", "Review your pickup order\nYour order\nYour payment\nSubtotal 12.00\n1 Chicken Bowl"],
    ["the sections without the heading", "Your order\n1 Chicken Bowl\nYour payment\nPayment method\nDining Dollars"],
    ["a Place-your-order CTA instead of the heading", "Place your pickup order\nYour order\n1 Chicken Bowl"],
    ["the heading embedded in a longer line", "Please Review your pickup order today\nYour order\n1 Chicken Bowl"],
    ["a Payment method label glued to other letters", "Review your pickup order\nYour payment\nPayment methods\nDining Dollars"],
    ["generic checkout-looking content", "Checkout\nSubtotal 12.00\nTax 1.06\nTip 2.00\nTotal 15.06 Place order"],
  ])("does not newly admit %s", (_name, text) => {
    expect(evaluateEligibility(text)).toEqual(ineligible);
  });

  it("admits one later payment row but refuses duplicate rows and split labels without a heading", () => {
    expect(evaluateEligibility("Review your pickup order\nYour payment\nSubtotal 12.00\nPayment method\nDining Dollars"))
      .toEqual(checkout);
    expect(evaluateEligibility("Review your pickup order\nYour payment\nPayment method\nDining Dollars\nPayment method\nVisa"))
      .toEqual(ineligible);
    expect(evaluateEligibility("Menu browse popular items\nYour\npayment\nPayment\nmethod\nDining Dollars"))
      .toEqual(ineligible);
  });

  it("keeps cart/bag and strict H5 eligibility exactly as before", () => {
    expect(
      evaluateEligibility("Your Pickup Order\nContinue to Checkout\nYour payment\nPayment method\nDining Dollars")
    ).toEqual({ eligible: true, category: "cart" });
    expect(
      evaluateEligibility("View order\nOrder information\n2 x Chicken Bowl\nPayment method\nDining Dollars")
    ).toEqual({ eligible: true, category: "historical" });
    expect(
      evaluateEligibility("Review your pickup order\nOrder instructions\nAdd more items")
    ).toEqual({ eligible: true, category: "cart" });
    expect(
      evaluateEligibility("Menu browse popular items reviews rating delivery fee 3.99")
    ).toEqual(ineligible);
  });
});

describe("W4-R4.1 resolveMenuPath", () => {
  const CART = "Your Pickup Order\nContinue to Checkout";
  const review = (...lines: string[]) => ["Review your pickup order", ...lines].join("\n");
  const DINING_ROW = ["Your payment", "Payment method", "Dining Dollars"];

  it("establishes Meal Exchange from explicit wording, with no swipe count implied", () => {
    expect(resolveMenuPath([`${CART}\nCrave NYU - Meal Exchange`])).toEqual({
      menuPath: "meal-exchange",
      conflict: false,
    });
    expect(corroboratedMealSwipeCount(`${CART}\nCrave NYU - Meal Exchange`)).toBeNull();
  });

  it.each([1, 2, 3, 4, 5])("establishes Meal Exchange from %dM notation", (n) => {
    expect(resolveMenuPath([`${CART}\nTotal ${n}M`]).menuPath).toBe("meal-exchange");
  });

  it("applies the existing notation rule: out-of-range or conflicting totals establish nothing", () => {
    for (const text of ["6M", "0M", "Total 2M\nTotal 3M", "1.3M"]) {
      expect(resolveMenuPath([`${CART}\n${text}`])).toEqual({ menuPath: null, conflict: false });
    }
  });

  it("lets independent explicit wording stand when notation is unresolved, without repairing the count", () => {
    const text = `${CART}\nMeal Exchange\nTotal 2M\nTotal 3M`;
    expect(resolveMenuPath([text]).menuPath).toBe("meal-exchange");
    expect(corroboratedMealSwipeCount(text)).toBeNull();
  });

  it("establishes Meal Exchange from mixed-resource notation", () => {
    expect(resolveMenuPath(["Your pickup order\n3M + $2.00"]).menuPath).toBe("meal-exchange");
  });

  it("treats provider meal-based payment wording as Meal Exchange, without a count", () => {
    const text = `${CART}\nUse 1 Meal + Dining Dollars`;
    expect(resolveMenuPath([text])).toEqual({ menuPath: "meal-exchange", conflict: false });
    expect(corroboratedMealSwipeCount(text)).toBeNull();
  });

  it("does not treat bare meal wording, venue, or plausibility as evidence", () => {
    for (const text of [
      "Meal swipe bowl meal",
      "Palladium\nChicken Bowl\nSubtotal 12.00",
      "meal exchanges",
    ]) {
      expect(resolveMenuPath([`${CART}\n${text}`])).toEqual({ menuPath: null, conflict: false });
    }
  });

  it("establishes Dining Dollars only from the single Payment method row directly under Your payment", () => {
    for (const lines of [
      DINING_ROW,
      ["Your payment", "Payment method Dining Dollars"],
      ["Your payment", "Payment method: Dining Dollars"],
      ["Your payment", "Payment method", "Dining Dollars >"],
      ["YOUR  PAYMENT", "PAYMENT   METHOD", "dining\u00a0dollars"],
    ]) {
      expect(resolveMenuPath([review(...lines)])).toEqual({
        menuPath: "dining-dollars",
        conflict: false,
      });
    }
  });

  it("gives the same payment signal no authority outside the checkout/review category", () => {
    expect(resolveMenuPath([`${CART}\n${DINING_ROW.join("\n")}`]).menuPath).toBeNull();
    expect(
      resolveMenuPath([`View order\nOrder information\n2 x Chicken Bowl\n${DINING_ROW.join("\n")}`]).menuPath
    ).toBeNull();
  });

  it("rejects incidental text, alternative tender lists, other methods, and ambiguous layouts", () => {
    const cases: string[][] = [
      ["Your order", "1 Chicken Bowl", "Dining Dollars applied -$2.00"],
      ["Your order", "1 Chicken Bowl", "Payment method", "Dining Dollars", "Credit card"],
      ["Your payment", "Payment method", "Visa ending 1234"],
      ["Your payment", "Payment method", "Dining Dollars and Visa"],
      ["Your payment", "Payment method"],
      ["Your payment", "Payment method", "Dining Dollars", "Payment method", "Credit card"],
      ["Your payment", "Payment method", "Dining Dollars", "Payment method", "Dining Dollars"],
      ["Your payment", "Payment method", "Dining Dollars", "Your payment"],
      ["Your payment", "Payment method", "Dining Dollars", "Visa ending 1234"],
      ["Your payment", "Payment method", "Dining Dollars", "Visa1234"],
    ];
    for (const lines of cases) {
      expect(resolveMenuPath([review(...lines)])).toEqual({ menuPath: null, conflict: false });
    }
  });

  it("accepts a later uniquely attributed payment row", () => {
    expect(resolveMenuPath([review(
      "Your order", "1 Chicken Bowl", "Your payment", "Subtotal 12.00", "Payment method", "Dining Dollars"
    )])).toEqual({ menuPath: "dining-dollars", conflict: false });
  });

  it("never derives Dining Dollars from prices, totals, or missing meal notation", () => {
    expect(
      resolveMenuPath([review("Your order", "1 Chicken Bowl", "Subtotal $12.00", "Total $13.06")])
    ).toEqual({ menuPath: null, conflict: false });
  });

  it.each(["Crave", "Starbucks", "Dunkin'"])(
    "resolves a current %s dollar cart only from one labeled order Total",
    (venue) => {
      const text = `${CART}\n${venue}\n1 Coffee $4.25\nSubtotal $12.00\nTax $1.06\nTotal $13.06`;
      expect(resolveMenuPath([text])).toEqual({ menuPath: "dining-dollars", conflict: false });
      expect(currentOrderTotalCents([text])).toBe(1306);
    }
  );

  it("withholds item, subtotal, tax, fee, promo, conflicting totals and split tender", () => {
    const base = `${CART}\nStarbucks\n1 Coffee $4.25`;
    for (const suffix of [
      "", "Subtotal $4.25", "Tax $0.40", "Delivery fee $1.00",
      "Promo -$2.00", "Total $4.25\nTotal $5.25",
      "Total $4.25\nSplit payment",
      "Total $4.25\nSplit payment1234",
      "Total $13.06\nDining Dollars $5.00\nVisa $8.06",
    ]) {
      expect(resolveMenuPath([`${base}\n${suffix}`]).menuPath).toBeNull();
      expect(currentOrderTotalCents([`${base}\n${suffix}`])).toBeNull();
    }
  });

  it("keeps a bounded cart path but omits an out-of-bounds estimate", () => {
    const text = `${CART}\nDunkin'\nTotal $99.00`;
    expect(resolveMenuPath([text]).menuPath).toBe("dining-dollars");
    expect(currentOrderTotalCents([text])).toBeNull();
  });

  it("withholds a Total when split tender evidence is spread across screenshots", () => {
    const images = [
      `${CART}\nTotal $13.06\nDining Dollars $5.00`,
      `${CART}\nVisa $8.06`,
    ];
    expect(currentOrderTotalCents(images)).toBeNull();
    expect(resolveMenuPath(images).menuPath).toBeNull();
    const conflicting = [
      `${CART}\nTotal $13.06`,
      `${CART}\nTotal $14.06`,
    ];
    expect(currentOrderTotalCents(conflicting)).toBeNull();
    expect(resolveMenuPath(conflicting).menuPath).toBeNull();
  });

  it("does not infer a dollar-cart path past unresolved M notation in another eligible image", () => {
    const totalCart = `${CART}\nTotal $13.06`;
    for (const notation of ["6M", "0M", "Total 2M\nTotal 3M"]) {
      expect(resolveMenuPath([totalCart, `${CART}\n${notation}`])).toEqual({
        menuPath: null,
        conflict: false,
      });
    }
    expect(resolveMenuPath([totalCart, `${CART}\nTotal 1M`])).toEqual({
      menuPath: null,
      conflict: true,
    });
  });

  it("fails closed when accepted Meal Exchange and Dining Dollars evidence both exist", () => {
    const conflict = { menuPath: null, conflict: true };
    expect(resolveMenuPath([review("Your order", "1 Chicken Bowl", "3M + $2.00", ...DINING_ROW)])).toEqual(conflict);
    expect(resolveMenuPath([review("Crave NYU - Meal Exchange", ...DINING_ROW)])).toEqual(conflict);
    expect(resolveMenuPath([review(...DINING_ROW), `${CART}\nBowl 1M`])).toEqual(conflict);
  });

  it("attributes evidence per screenshot across a multi-image selection", () => {
    expect(
      resolveMenuPath([review(...DINING_ROW), review("Your order", "1 Chicken Bowl", ...DINING_ROW)]).menuPath
    ).toBe("dining-dollars");
    // A second checkout screenshot showing a different/unreadable method keeps
    // the path unproposed instead of guessing between them.
    expect(
      resolveMenuPath([review(...DINING_ROW), review("Your payment", "Payment method", "Visa ending 1234")])
    ).toEqual({ menuPath: null, conflict: false });
    // An ineligible screenshot contributes no evidence at all.
    expect(
      resolveMenuPath([
        `${CART}\nBowl 1M`,
        `Menu browse popular items reviews rating\n${DINING_ROW.join("\n")}`,
      ]).menuPath
    ).toBe("meal-exchange");
    expect(
      resolveMenuPath([`Menu browse popular items reviews rating\n${DINING_ROW.join("\n")}`])
    ).toEqual({ menuPath: null, conflict: false });
  });

  it("proposes nothing for no evidence", () => {
    expect(resolveMenuPath([`${CART}\nPalladium`, `${CART}\nCafe 370`])).toEqual({
      menuPath: null,
      conflict: false,
    });
    expect(resolveMenuPath([])).toEqual({ menuPath: null, conflict: false });
  });
});

describe("W4-R4.1 amountAuthorityEvidenceText", () => {
  const CART = "Your Pickup Order Order Instructions Cilantro on the side Continue to Checkout";
  const HISTORICAL = "View order Order information 1 Create Your Own Bowl";
  const CHECKOUT = "Review your pickup order\nYour order\n1 Chicken Bowl\n3M + $2.00";

  it("excludes checkout/review screenshots and keeps every other screenshot's text unchanged", () => {
    expect(evaluateEligibility(CHECKOUT).category).toBe("checkout");
    expect(amountAuthorityEvidenceText([CART, CHECKOUT, HISTORICAL])).toBe(`${CART}\n${HISTORICAL}`);
  });

  it("is the combined evidence, joined the same way, when no screenshot is a checkout/review one", () => {
    expect(evaluateEligibility(CART).category).toBe("cart");
    expect(evaluateEligibility(HISTORICAL).category).toBe("historical");
    expect(amountAuthorityEvidenceText([CART, HISTORICAL])).toBe([CART, HISTORICAL].join("\n"));
    expect(amountAuthorityEvidenceText([CART])).toBe(CART);
  });

  it("has no evidence when every screenshot is a checkout/review one", () => {
    expect(amountAuthorityEvidenceText([CHECKOUT, CHECKOUT])).toBe("");
    expect(amountAuthorityEvidenceText([])).toBe("");
  });
});

describe("W4-R4.1 canonical matrix: section boundaries and headings", () => {
  const H = "Review your pickup order";
  const checkout = { eligible: true, category: "checkout" };
  const dining = { menuPath: "dining-dollars", conflict: false };
  const none = { menuPath: null, conflict: false };

  it("does not authorize the generic `Review your order` heading, whole or split", () => {
    for (const text of [
      "Review your order\nYour order\n1 Chicken Bowl\nYour payment\nPayment method\nDining Dollars",
      "Review your\norder\nYour payment\nPayment method\nDining Dollars",
    ]) {
      expect(evaluateEligibility(text)).toEqual({ eligible: false, category: null });
      expect(resolveMenuPath([text])).toEqual(none);
    }
  });

  it("keeps the authorized pickup and delivery headings, including word-boundary splits", () => {
    for (const heading of [
      "Review your pickup order",
      "Review your delivery order",
      "Review your\npickup order",
      "Review\nyour\ndelivery order",
    ]) {
      expect(evaluateEligibility(`${heading}\nYour payment\nPayment method\nDining Dollars`)).toEqual(checkout);
    }
  });

  it.each([
    ["Receipt", "Receipt"],
    ["Order confirmation", "Order confirmation"],
    ["split Order confirmation", "Order\nconfirmation"],
    ["Order information", "Order information"],
    ["View order", "View order"],
    ["generic review boundary", "Review your order"],
    ["Your order", "Your order\n1 Chicken Bowl"],
    ["the place-order action", "Place your pickup order"],
  ])("ends Your payment attribution at %s", (_name, boundary) => {
    const text = `${H}\nYour order\n1 Chicken Bowl\nYour payment\n${boundary}\nPayment method\nDining Dollars`;
    expect(resolveMenuPath([text])).toEqual(none);
    expect(currentOrderTotalCents([`${text}\nTotal $4.30`])).toBeNull();
  });

  it("does not attribute a later row when the earlier payment section had none", () => {
    const text = `${H}\nYour payment\nReceipt\nPayment method\nDining Dollars`;
    expect(evaluateEligibility(text)).toEqual({ eligible: false, category: null });
    expect(resolveMenuPath([text])).toEqual(none);
  });

  it("keeps a later row inside the same payment section, with no line-distance cutoff", () => {
    const filler = Array.from({ length: 40 }, (_v, i) => `Detail ${i}`).join("\n");
    for (const text of [
      `${H}\nYour payment\nApply a promo code\nPayment method\nDining Dollars`,
      `${H}\nYour payment\nPayment method\nDining Dollars\nApply a promo code`,
      `${H}\nYour payment\n${filler}\nPayment method\nDining Dollars`,
    ]) {
      expect(evaluateEligibility(text)).toEqual(checkout);
      expect(resolveMenuPath([text])).toEqual(dining);
    }
  });

  it("fails closed for duplicate payment sections and duplicate or valueless rows", () => {
    for (const text of [
      `${H}\nYour payment\nPayment method\nDining Dollars\nYour payment\nPayment method\nDining Dollars`,
      `${H}\nYour payment\nPayment method\nDining Dollars\nPayment method\nDining Dollars`,
      `${H}\nYour order\n1 Chicken Bowl\nYour payment\nPayment method`,
      `${H}\nYour order\n1 Chicken Bowl\nYour payment\nPayment method\nApply a promo code`,
    ]) {
      expect(resolveMenuPath([text])).toEqual(none);
    }
  });

  it("stops the Your order scan at the first later Your payment heading", () => {
    const ineligible = { eligible: false, category: null };
    expect(evaluateEligibility(`${H}\nYour order\nYour payment\n1 Chicken Bowl`)).toEqual(ineligible);
    expect(evaluateEligibility(`${H}\nYour order\nYour payment\n1 Chicken Bowl\nYour payment`)).toEqual(ineligible);
    expect(
      evaluateEligibility(`${H}\nYour order\nYour payment\nPayment method\nYour payment\n1 Chicken Bowl`)
    ).toEqual(ineligible);
  });

  it("keeps an item already inside Your order eligible despite a malformed later payment section", () => {
    for (const tail of ["Your payment\nYour payment", "Your payment\nPayment method\nYour payment"]) {
      expect(evaluateEligibility(`${H}\nYour order\n1 Chicken Bowl\n${tail}`)).toEqual(checkout);
    }
  });

  it("classifies review before cart chrome, and cart chrome alone stays cart", () => {
    const chrome = "Your pickup order\nContinue to checkout\nOrder instructions";
    expect(evaluateEligibility(`${chrome}\n${H}\nYour payment\nPayment method\nDining Dollars`)).toEqual(checkout);
    expect(evaluateEligibility(`${chrome}\nPayment method\nDining Dollars`)).toEqual({
      eligible: true,
      category: "cart",
    });
  });

  it("resolves the real review layout: payment first, then order, with the labeled Total as the estimate", () => {
    const dd = `${H}\nYour payment\nPayment method\nDining Dollars\nApply a promo code\nYour order\n1 Coffee\nSubtotal $4.00\nTotal $4.30`;
    expect(resolveMenuPath([dd])).toEqual(dining);
    expect(currentOrderTotalCents([dd])).toBe(430);
    // A selected method alone supplies no amount.
    expect(currentOrderTotalCents([`${H}\nYour payment\nPayment method\nDining Dollars\nYour order\n1 Coffee`])).toBeNull();
  });

  it("never turns `Use 1 Meal + Dining Dollars` into Dining Dollars", () => {
    for (const text of [
      `${H}\nYour payment\nPayment method\nUse 1 Meal + Dining Dollars\nYour order\n1 Coffee`,
      `${H}\nYour payment\nPayment method Use 1 Meal + Dining Dollars\nYour order\n1 Coffee`,
      `${H}\nDunkin' at U-Hall - Meal Exchange\nYour payment\nPayment method\nUse 1 Meal + Dining Dollars\nYour order\n1 Coffee\nTotal 1M`,
    ]) {
      expect(resolveMenuPath([text])).toEqual({ menuPath: "meal-exchange", conflict: false });
    }
  });

  it("derives no Dining Dollars cart inference from item, subtotal, and tax price noise", () => {
    const text = "Your Pickup Order\nContinue to Checkout\nStarbucks\n1 Latte $5.00\nSubtotal $5.00\nTax $0.44";
    expect(resolveMenuPath([text])).toEqual(none);
    expect(currentOrderTotalCents([text])).toBeNull();
  });
});

describe("W4-R4.1 structural departures (boundary-only recognition)", () => {
  const H = "Review your pickup order";
  const checkout = { eligible: true, category: "checkout" };
  const ineligible = { eligible: false, category: null };
  const none = { menuPath: null, conflict: false };
  const DEPARTURES = [
    "Receipt ›",
    "Receipt >",
    "Order confirmation: 123",
    "Order confirmation #A1-23",
    "Place your pickup order ›",
    "Place your delivery order $4.30",
    "Order history",
    "Past order",
    "Past orders",
    "Order information ›",
    "View order ›",
    "Your order ›",
    "Review your delivery order ›",
  ];

  it.each(DEPARTURES)("ends Your payment attribution at %s", (departure) => {
    const text = `${H}\nYour order\n1 Chicken Bowl\nYour payment\n${departure}\nPayment method\nDining Dollars`;
    expect(resolveMenuPath([text])).toEqual(none);
    expect(currentOrderTotalCents([`${text}\nTotal $4.30`])).toBeNull();
  });

  it.each(DEPARTURES.filter((d) => d !== "Your order ›"))(
    "ends the Your order item scan at %s",
    (departure) => {
      expect(evaluateEligibility(`${H}\nYour order\n${departure}\n1 Chicken Bowl`)).toEqual(ineligible);
      expect(evaluateEligibility(`${H}\nYour order\n1 Chicken Bowl\n${departure}\n1 Pasta Bowl`)).toEqual(checkout);
    }
  );

  it("ends the Your order scan at a decorated later Your payment heading", () => {
    expect(evaluateEligibility(`${H}\nYour order\nYour payment ›\n1 Chicken Bowl`)).toEqual(ineligible);
    expect(evaluateEligibility(`${H}\nYour order\n1 Chicken Bowl\nYour payment ›\nYour payment`)).toEqual(checkout);
  });

  it("treats a decorated duplicate Your payment heading as ambiguous and fails closed", () => {
    expect(
      resolveMenuPath([`${H}\nYour payment\nPayment method\nDining Dollars\nYour payment ›`])
    ).toEqual(none);
  });

  it("grants no positive authority from any departure, decorated or not", () => {
    expect(evaluateEligibility(`${H}\n${DEPARTURES.join("\n")}`)).toEqual(ineligible);
    expect(evaluateEligibility(`${H}\nYour payment ›\nPayment method\nDining Dollars`)).toEqual(ineligible);
    expect(evaluateEligibility(`${H}\nYour order ›\n1 Chicken Bowl`)).toEqual(ineligible);
    for (const departure of DEPARTURES) {
      expect(resolveMenuPath([`${departure}\nPayment method\nDining Dollars`])).toEqual(none);
    }
  });

  it("does not treat look-alikes without a delimiter as departures", () => {
    for (const lookalike of ["Receipts", "Receipt of purchase", "Order confirmations", "View order details", "Order historyx"]) {
      const text = `${H}\nYour payment\n${lookalike}\nPayment method\nDining Dollars`;
      expect(resolveMenuPath([text])).toEqual({ menuPath: "dining-dollars", conflict: false });
    }
  });

  it("applies no line-count cutoff to either section", () => {
    const filler = Array.from({ length: 200 }, (_v, i) => `Detail ${i}`).join("\n");
    expect(evaluateEligibility(`${H}\nYour order\n${filler}\n1 Chicken Bowl`)).toEqual(checkout);
    expect(resolveMenuPath([`${H}\nYour payment\n${filler}\nPayment method\nDining Dollars`])).toEqual({
      menuPath: "dining-dollars",
      conflict: false,
    });
  });

  it("keeps promo controls inside the payment section, decorated or not", () => {
    for (const promo of ["Apply a promo code", "Apply a promo code ›"]) {
      const text = `${H}\nYour payment\n${promo}\nPayment method\nDining Dollars\n${promo}\nYour order\n1 Coffee\nTotal $4.30`;
      expect(resolveMenuPath([text])).toEqual({ menuPath: "dining-dollars", conflict: false });
      expect(currentOrderTotalCents([text])).toBe(430);
    }
  });
});
