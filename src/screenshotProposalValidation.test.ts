import { describe, expect, it } from "vitest";
import { validateProviderOutput } from "./screenshotProposalValidation.js";

/**
 * Independent on-device Vision OCR evidence text — never provider output.
 * By the time `validateProviderOutput` is called, `screenshotProposalRoute.ts`
 * has already established eligibility from this exact kind of text and the
 * provider has already been called; these fixtures represent that
 * independent evidence for the corroboration/grounding tests below.
 */
const cartEvidenceText =
  "Your Pickup Order Order Instructions Cilantro on the side Continue to Checkout";

describe("validateProviderOutput", () => {
  it("refuses a payload carrying a forbidden authority field ahead of schema validation", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [],
        mealSwipes: null,
        action: "submit",
      },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({ ok: false, reason: "forbidden_fields" });
  });

  it("refuses a malformed/wrong-shape payload", () => {
    const result = validateProviderOutput(
      { foodItems: "not-an-array" },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({ ok: false, reason: "schema_invalid" });
  });

  it("refuses provider output still attempting to smuggle a visibleText field (removed from the accepted schema)", () => {
    const result = validateProviderOutput(
      {
        visibleText: "fabricated evidence claiming eligibility/corroboration",
        visibleVenueText: null,
        foodItems: [],
        mealSwipes: null,
      },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({ ok: false, reason: "schema_invalid" });
  });

  it("returns an empty proposal when nothing safe was extracted (no useful extraction)", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: null },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({ ok: true, proposal: {} });
  });

  it("produces a partial proposal — food only — when location is absent", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [{ name: "Create Your Own Bowl", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({
      ok: true,
      proposal: { mealItems: [{ name: "1 Create Your Own Bowl" }] },
    });
  });

  it("formats multi-item quantity and labeled-modifier food lines literally", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [
          { name: "Create Your Own Bowl", quantity: 1, modifiers: ["No Cilantro"] },
          { name: "Soda", quantity: 2, modifiers: [] },
        ],
        mealSwipes: null,
      },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealItems).toEqual([
        { name: "1 Create Your Own Bowl", details: "No Cilantro" },
        { name: "2 Soda" },
      ]);
    }
  });

  it("strips a bare unlabeled yes/no modifier but keeps genuinely labeled values", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [
          {
            name: "Burger",
            quantity: 1,
            modifiers: ["yes", "No Side", "No Bag", "Yes Bag", " NO "],
          },
        ],
        mealSwipes: null,
      },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealItems).toEqual([
        { name: "1 Burger", details: "No Side, No Bag, Yes Bag" },
      ]);
    }
  });

  // MARK: - Meal-swipe corroboration (independent evidence only)

  it("keeps mealSwipes only when corroborated by an exact-matching count of literal 1M markers in the independent evidence text", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 2 },
      `${cartEvidenceText} 1M 1M`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBe(2);
    }
  });

  it("drops mealSwipes when the 1M marker count in the independent evidence does not match the candidate", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 2 },
      `${cartEvidenceText} 1M`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBeUndefined();
    }
  });

  it("drops mealSwipes when uncorroborated (no 1M marker at all in the independent evidence)", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 3 },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBeUndefined();
    }
  });

  it("keeps mealSwipes when one explicit aggregate M total matches", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 3 },
      `${cartEvidenceText} 3M + $2.00`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.proposal.mealSwipes).toBe(3);
  });

  it("proposes the current-cart order-level Dining Dollars estimate with a corroborated aggregate", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 3 },
      `${cartEvidenceText} 3M + $2.00`,
      1
    );
    expect(result).toEqual({
      ok: true,
      proposal: { menuPath: "meal-exchange", mealSwipes: 3, estimatedDiningDollarsCents: 200 },
    });
  });

  it.each([
    ["item-level modifier price", `${cartEvidenceText} Burger add bacon +$2.00 3M`],
    ["ambiguous money", `${cartEvidenceText} 3M + $2.00 3M + $3.00`],
    ["past order", `Order history Completed order 3M + $2.00`],
  ])("fails closed for %s", (_label, evidence) => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 3 },
      evidence,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.estimatedDiningDollarsCents).toBeUndefined();
    }
  });

  it("treats repeated identical aggregate totals as overlap rather than addition", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 3 },
      `${cartEvidenceText} 3M + $2.00\n${cartEvidenceText} 3 M + $2.00`,
      2
    );
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.proposal.mealSwipes).toBe(3);
  });

  it("drops mealSwipes when explicit aggregate totals conflict", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 3 },
      `${cartEvidenceText} 2M\n${cartEvidenceText} 3M`,
      2
    );
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.proposal.mealSwipes).toBeUndefined();
  });

  it("drops rather than replacing a provider value that mismatches the explicit total", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 2 },
      `${cartEvidenceText} 3M`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.proposal.mealSwipes).toBeUndefined();
  });

  it("does not corroborate from out-of-bounds or malformed M notation", () => {
    for (const evidence of ["6M", "0M", "3.0M", "M3", "3MM"]) {
      const result = validateProviderOutput(
        { visibleVenueText: null, foodItems: [], mealSwipes: 3 },
        `${cartEvidenceText} ${evidence}`,
        1
      );
      expect(result.ok).toBe(true);
      if (result.ok) expect(result.proposal.mealSwipes, evidence).toBeUndefined();
    }
  });

  it("never accepts a mealSwipes candidate outside the 1...5 integer range even with marker corroboration", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 6 },
      `${cartEvidenceText} 1M 1M 1M 1M 1M 1M`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBeUndefined();
    }
  });

  it("does not corroborate mealSwipes from provider-manufactured evidence — only real independent evidence text counts", () => {
    // The accepted schema no longer accepts a provider transcription field
    // at all, so this simply confirms a provider swipe claim is dropped when
    // the real independent evidence carries no corroborating markers.
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 5 },
      cartEvidenceText, // zero "1M" markers
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBeUndefined();
    }
  });

  // MARK: - Vendor location: grounded in independent evidence

  it("resolves an unambiguous canonical vendor grounded in independent evidence, provider text absent", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: null },
      `${cartEvidenceText} Jasper Kane Cafe`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toEqual({
        name: "Jasper Kane Cafe",
        address: "BROOKLYN, Rogers Hall",
      });
    }
  });

  it("resolves an unambiguous canonical vendor when independent evidence and a consistent provider candidate agree", () => {
    const result = validateProviderOutput(
      { visibleVenueText: "Jasper Kane Cafe", foodItems: [], mealSwipes: null },
      `${cartEvidenceText} Jasper Kane Cafe`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot?.name).toBe("Jasper Kane Cafe");
    }
  });

  it("resolves an unambiguous full canonical Upstein entry grounded in independent evidence", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: "Upstein - Vedge Craft & Smoothie Lab",
        foodItems: [],
        mealSwipes: null,
      },
      `${cartEvidenceText} Upstein - Vedge Craft & Smoothie Lab`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot?.name).toBe(
        "Upstein - Vedge Craft & Smoothie Lab"
      );
    }
  });

  it("omits location for a generic/historical 'Upstein' venue text ambiguous across the two current entries", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: "Upstein",
        foodItems: [{ name: "Smoothie", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
      "View order Order information 1 Smoothie Upstein",
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
      // Other safe fields still survive independently.
      expect(result.proposal.mealItems).toEqual([{ name: "1 Smoothie" }]);
    }
  });

  it("omits location when venue text does not resolve to any current catalog entry", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: "Some Random Off-Campus Diner",
        foodItems: [],
        mealSwipes: null,
      },
      `${cartEvidenceText} Some Random Off-Campus Diner`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("never resolves location from provider text alone when independent evidence names no vendor at all (Burger fragment)", () => {
    // The provider fragment "Burger" is a substring of the catalog entry
    // "True Burger at UHall", but nothing in independent evidence grounds
    // it — raw provider text is not visible-location evidence on its own.
    const result = validateProviderOutput(
      { visibleVenueText: "Burger", foodItems: [], mealSwipes: null },
      cartEvidenceText, // no vendor name anywhere in independent evidence
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("never resolves location from provider text alone for a short generic fragment (Coffee)", () => {
    const result = validateProviderOutput(
      { visibleVenueText: "Coffee", foodItems: [], mealSwipes: null },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("never resolves location from a short/partial provider fragment even when independent evidence is otherwise present", () => {
    // Independent evidence establishes eligibility but never names any
    // vendor; the provider's short fragment cannot ground itself.
    const result = validateProviderOutput(
      { visibleVenueText: "Cafe", foodItems: [], mealSwipes: null },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("omits location when independent evidence and provider text disagree on the vendor", () => {
    const result = validateProviderOutput(
      { visibleVenueText: "Jasper Kane Cafe", foodItems: [], mealSwipes: null },
      `${cartEvidenceText} Crave NYU`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("corroborates using the real Crave two-swipe case: independent evidence establishes both the venue and exactly two markers", () => {
    const result = validateProviderOutput(
      { visibleVenueText: "Crave NYU", foodItems: [], mealSwipes: 2 },
      "Crave NYU View order Order information 1 Bowl 1M 1M",
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBe(2);
      expect(result.proposal.selectedDiningSpot?.name).toBe("Crave NYU");
    }
  });

  // MARK: - Repeated identical lines (W4-R4 multi-image ambiguity)

  const repeatedBurger = {
    visibleVenueText: null,
    foodItems: [
      { name: "Burger", quantity: 1, modifiers: ["No Bag"] },
      { name: "Fries", quantity: 1, modifiers: [] },
      { name: " burger ", quantity: 1, modifiers: ["no  bag"] },
    ],
    mealSwipes: 3,
  };

  it("keeps genuinely repeated identical lines from a single screenshot, which cannot overlap itself", () => {
    const result = validateProviderOutput(
      repeatedBurger,
      `${cartEvidenceText} Jasper Kane Cafe 1M 1M 1M`,
      1
    );
    expect(result).toEqual({
      ok: true,
      proposal: {
        selectedDiningSpot: {
          name: "Jasper Kane Cafe",
          address: "BROOKLYN, Rogers Hall",
        },
        mealItems: [{ name: "1 Burger", details: "No Bag" }, { name: "1 Fries" }, { name: "1 burger", details: "no  bag" }],
        mealSwipes: 3,
        menuPath: "meal-exchange",
      },
    });
  });

  it("proposes neither meal items nor swipes when several screenshots repeat an identical line", () => {
    // Overlap (one burger seen twice) and a real repeat (two burgers) are
    // indistinguishable here, so neither one, two, nor a summed quantity is
    // proposed — for either the items or the swipe count that depends on
    // the same question.
    const result = validateProviderOutput(
      repeatedBurger,
      `${cartEvidenceText} Jasper Kane Cafe 1M 1M 1M`,
      2
    );
    expect(result).toEqual({
      ok: true,
      proposal: {
        selectedDiningSpot: {
          name: "Jasper Kane Cafe",
          address: "BROOKLYN, Rogers Hall",
        },
        // The path comes from the independent `1M` evidence, not from the
        // ambiguous provider item list, so it survives the dropped items.
        menuPath: "meal-exchange",
      },
    });
  });

  it("keeps every line from several screenshots when no identity repeats", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [
          { name: "Burger", quantity: 1, modifiers: ["No Bag"] },
          { name: "Burger", quantity: 2, modifiers: ["No Bag"] },
          { name: "Burger", quantity: 1, modifiers: ["No Side"] },
          { name: "Burger", quantity: null, modifiers: ["No Bag"] },
        ],
        mealSwipes: 2,
      },
      `${cartEvidenceText} 1M 1M`,
      3
    );
    expect(result).toEqual({
      ok: true,
      proposal: {
        mealItems: [
          { name: "1 Burger", details: "No Bag" },
          { name: "2 Burger", details: "No Bag" },
          { name: "1 Burger", details: "No Side" },
          { name: "Burger", details: "No Bag" },
        ],
        mealSwipes: 2,
        menuPath: "meal-exchange",
      },
    });
  });

  it("treats lines that repeat only after bare yes/no modifiers are removed as repeated", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [
          { name: "Bowl", quantity: 1, modifiers: ["yes"] },
          { name: "Bowl", quantity: 1, modifiers: [] },
        ],
        mealSwipes: null,
      },
      cartEvidenceText,
      2
    );
    expect(result).toEqual({ ok: true, proposal: {} });
  });
});

describe("W4-R4.1 deterministic menu path in validated proposals", () => {
  const review = (...lines: string[]) => ["Review your pickup order", ...lines].join("\n");
  const DINING_ROW = ["Your payment", "Payment method", "Dining Dollars"];
  const bowl = { name: "Chicken Bowl", quantity: 1, modifiers: [] };
  const empty = { visibleVenueText: null, foodItems: [], mealSwipes: null };

  it("proposes Dining Dollars path and a separate labeled Total estimate", () => {
    const text = review("Your order", "1 Chicken Bowl", "Subtotal $12.00", "Total $13.06", ...DINING_ROW);
    expect(validateProviderOutput(empty, text, 1)).toEqual({
      ok: true,
      proposal: { menuPath: "dining-dollars", diningDollarsOrderTotalCents: 1306 },
    });
    const withItems = validateProviderOutput(
      { visibleVenueText: null, foodItems: [bowl], mealSwipes: 2 },
      text,
      1
    );
    expect(withItems).toEqual({
      ok: true,
      proposal: {
        menuPath: "dining-dollars",
        mealItems: [{ name: "1 Chicken Bowl" }],
        diningDollarsOrderTotalCents: 1306,
      },
    });
  });

  it("omits a whole-order estimate for conflicting, split, or out-of-bounds Totals", () => {
    const cart = "Your Pickup Order\nContinue to Checkout\nStarbucks";
    expect(validateProviderOutput(empty, `${cart}\nTotal $99.00`, 1)).toEqual({
      ok: true, proposal: { menuPath: "dining-dollars" },
    });
    for (const suffix of [
      "Total $12.00\nTotal $13.00",
      "Total $12.00\nSplit payment",
      "Subtotal $12.00\nTax $1.00",
    ]) {
      expect(validateProviderOutput(empty, `${cart}\n${suffix}`, 1)).toEqual({
        ok: true, proposal: {},
      });
    }
  });

  it("proposes Meal Exchange from explicit wording without a swipe count or amount", () => {
    expect(
      validateProviderOutput(
        { visibleVenueText: null, foodItems: [bowl], mealSwipes: 2 },
        `${cartEvidenceText}\nMeal Exchange`,
        1
      )
    ).toEqual({
      ok: true,
      proposal: { menuPath: "meal-exchange", mealItems: [{ name: "1 Chicken Bowl" }] },
    });
  });

  it.each([
    ["pickup heading", "Review your pickup order"],
    ["delivery heading", "Review your delivery order"],
  ])(
    "grants no amount authority to a checkout/review screenshot: `3M + $2.00` under the %s proposes the path but no amount",
    (_label, heading) => {
      expect(
        validateProviderOutput(
          { visibleVenueText: null, foodItems: [bowl], mealSwipes: 3 },
          [heading, "Your order", "1 Chicken Bowl", "3M + $2.00"].join("\n"),
          1
        )
      ).toEqual({
        ok: true,
        proposal: {
          menuPath: "meal-exchange",
          mealItems: [{ name: "1 Chicken Bowl" }],
          mealSwipes: 3,
        },
      });
    }
  );

  it("does not let checkout chrome (Checkout word, Place-your-order CTA) stand in for a current-cart marker", () => {
    expect(
      validateProviderOutput(
        { visibleVenueText: null, foodItems: [bowl], mealSwipes: 3 },
        review("Checkout", "Your order", "1 Chicken Bowl", "3M + $2.00", "Place your pickup order"),
        1
      )
    ).toEqual({
      ok: true,
      proposal: {
        menuPath: "meal-exchange",
        mealItems: [{ name: "1 Chicken Bowl" }],
        mealSwipes: 3,
      },
    });
  });

  describe("amount authority across a mixed per-screenshot selection", () => {
    const cartWithAmount = "Your pickup order\nItems subtotal\n3M + $2.00";
    const cartWithoutAmount = "Your pickup order\nItems subtotal\nContinue to checkout";
    const checkoutItems = review("Your order", "1 Chicken Bowl");
    const checkoutWithAmount = review("Your order", "1 Chicken Bowl", "3M + $2.00");
    const select = (images: string[]) =>
      validateProviderOutput(
        { visibleVenueText: null, foodItems: [bowl], mealSwipes: 3 },
        images.join("\n"),
        images.length,
        images
      );

    it("keeps the existing current-cart amount when a cart screenshot carries both marker and amount", () => {
      expect(select([cartWithAmount, checkoutItems])).toEqual({
        ok: true,
        proposal: {
          menuPath: "meal-exchange",
          mealItems: [{ name: "1 Chicken Bowl" }],
          mealSwipes: 3,
          estimatedDiningDollarsCents: 200,
        },
      });
    });

    it("does not let a cart screenshot's marker carry an amount that only a checkout screenshot shows", () => {
      expect(select([cartWithoutAmount, checkoutWithAmount])).toEqual({
        ok: true,
        proposal: {
          menuPath: "meal-exchange",
          mealItems: [{ name: "1 Chicken Bowl" }],
          mealSwipes: 3,
        },
      });
    });
  });

  it("proposes neither a path nor a branch-dependent value when evidence conflicts, but keeps the shared location", () => {
    const text = review("Your order", "1 Chicken Bowl", "Jasper Kane Cafe", "3M + $2.00", ...DINING_ROW);
    expect(
      validateProviderOutput(
        { visibleVenueText: "Jasper Kane Cafe", foodItems: [bowl], mealSwipes: 3 },
        text,
        1
      )
    ).toEqual({
      ok: true,
      proposal: {
        selectedDiningSpot: { name: "Jasper Kane Cafe", address: "BROOKLYN, Rogers Hall" },
      },
    });
  });

  it("treats `Use 1 Meal + Dining Dollars` as Meal Exchange, with no count or amount", () => {
    expect(
      validateProviderOutput(
        { visibleVenueText: null, foodItems: [bowl], mealSwipes: 1 },
        `${cartEvidenceText}\nUse 1 Meal + Dining Dollars`,
        1
      )
    ).toEqual({ ok: true, proposal: {
      menuPath: "meal-exchange", mealItems: [{ name: "1 Chicken Bowl" }],
    } });
  });

  it("rejects a provider-supplied menuPath outright, and a valid path never needs the provider", () => {
    const dining = review(...DINING_ROW);
    for (const menuPath of ["dining-dollars", "meal-exchange", "MEAL_EXCHANGE", null]) {
      expect(validateProviderOutput({ ...empty, menuPath }, dining, 1)).toEqual({
        ok: false,
        reason: "forbidden_fields",
      });
    }
    expect(validateProviderOutput(empty, dining, 1)).toEqual({
      ok: true,
      proposal: { menuPath: "dining-dollars" },
    });
  });

  it("uses per-screenshot evidence when supplied, defaulting the combined text to one screenshot", () => {
    const images = [review(...DINING_ROW), review("Your payment", "Payment method", "Visa ending 1234")];
    expect(
      validateProviderOutput(empty, images.join("\n"), 2, images)
    ).toEqual({ ok: true, proposal: {} });
    // The combined text alone is one screenshot with two Payment method rows,
    // which is equally an ambiguous layout.
    expect(validateProviderOutput(empty, images.join("\n"), 2)).toEqual({ ok: true, proposal: {} });
  });

  it("turns a supported cart's complete derived Total relation into DD plus its editable estimate", () => {
    const text = [
      "Your Pickup Order", "Continue to Checkout", "$9.00", "Items subtotal",
      "$14.00", "Sales tax", "$1.45", "Total", "Order actions", "$15.45",
    ].join("\n");
    const geometry = {
      observations: [
        { id: 2, classification: "amount" as const, cents: 900, geometryValid: true },
        { id: 4, classification: "amount" as const, cents: 1_400, geometryValid: true },
        { id: 6, classification: "amount" as const, cents: 145, geometryValid: true },
        { id: 7, classification: "total-label" as const, geometryValid: true },
        { id: 9, classification: "amount" as const, cents: 1_545, geometryValid: true },
      ],
      relations: [2, 4, 6, 9].map((amountObservationID) => ({
        totalObservationID: 7,
        amountObservationID,
        sameRow: amountObservationID === 9,
        rightOf: amountObservationID === 9,
      })),
    };
    expect(validateProviderOutput(empty, text, 1, [text], [geometry])).toEqual({
      ok: true,
      proposal: {
        menuPath: "dining-dollars",
        diningDollarsOrderTotalCents: 1_545,
      },
    });
  });
});
