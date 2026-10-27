import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  deriveFoodSummary,
  formatDiningDollars,
  MAX_DINING_DOLLARS_ONLY_CENTS,
  MAX_MEAL_EXCHANGE_DINING_DOLLARS_CENTS,
  refineStructuredRequest,
  structuredRequestFields,
  type StructuredRequestInput,
} from "./structuredRequest.js";

/**
 * The structured half exactly as every create schema composes it: the shared
 * fields, `.strict()`, and the cross-path refinement. Validating against this
 * proves the rules the real route applies rather than a restatement of them.
 */
const structuredSchema = z
  .object(structuredRequestFields)
  .strict()
  .superRefine(refineStructuredRequest);

function mealExchange(overrides: Record<string, unknown> = {}) {
  return {
    menuPath: "meal-exchange",
    mealSwipes: 2,
    mealItems: [{ name: "Rice bowl" }, { name: "Side salad" }],
    ...overrides,
  };
}

function diningDollars(overrides: Record<string, unknown> = {}) {
  return {
    menuPath: "dining-dollars",
    mealSwipes: 0,
    orderDetails: "Grain bowl with extra avocado",
    estimatedDiningDollarsCents: 1_850,
    ...overrides,
  };
}

describe("W4-R4 structured text length", () => {
  // No per-field ceiling exists in the request contract or the iOS form, so
  // long text is accepted exactly as the pre-R4 `food` field was.
  it.each([500, 501, 5_000])(
    "accepts a %d-character meal detail and order details",
    (length) => {
      const text = "x".repeat(length);

      expect(
        structuredSchema.safeParse(mealExchange({ mealSwipes: 1, mealItems: [{ name: text }] }))
          .success
      ).toBe(true);
      expect(
        structuredSchema.safeParse(diningDollars({ orderDetails: text })).success
      ).toBe(true);
    }
  );
});

describe("W4-R4 Meal Exchange validation", () => {
  it.each([1, 2, 3, 4, 5])(
    "accepts %d swipes with exactly one meal detail per swipe",
    (mealSwipes) => {
      const result = structuredSchema.safeParse(
        mealExchange({
          mealSwipes,
          mealItems: Array.from({ length: mealSwipes }, (_, i) => ({ name: `Item ${i + 1}` })),
        })
      );

      expect(result.success).toBe(true);
    }
  );

  it.each([0, -1, 6, 1.5])("refuses the swipe count %j", (mealSwipes) => {
    const result = structuredSchema.safeParse(
      mealExchange({ mealSwipes, mealItems: [{ name: "Rice bowl" }] })
    );

    expect(result.success).toBe(false);
  });

  it("refuses a request with fewer meal details than selected swipes", () => {
    const result = structuredSchema.safeParse(
      mealExchange({ mealSwipes: 3, mealItems: [{ name: "Rice bowl" }, { name: "Side salad" }] })
    );

    expect(result.success).toBe(false);
  });

  it("refuses a request carrying more meal details than selected swipes", () => {
    // This is the wire-level half of the requester-facing rule that a meal
    // field hidden by lowering the swipe count is excluded from the submitted
    // request: content above the active count is refused, not persisted.
    const result = structuredSchema.safeParse(
      mealExchange({
        mealSwipes: 1,
        mealItems: [{ name: "Rice bowl" }, { name: "Hidden fourth-swipe content" }],
      })
    );

    expect(result.success).toBe(false);
  });

  it.each([["  "], [""]])(
    "refuses a blank meal detail (%j) rather than accepting an empty swipe",
    (blank) => {
      const result = structuredSchema.safeParse(
        mealExchange({ mealSwipes: 2, mealItems: [{ name: "Rice bowl" }, { name: blank }]} )
      );

      expect(result.success).toBe(false);
    }
  );

  it("accepts a Meal Exchange request with no Dining Dollar estimate at all", () => {
    const result = structuredSchema.safeParse(mealExchange());

    expect(result.success).toBe(true);
    if (result.success) {
      // Absent, never defaulted to a fabricated zero.
      expect(result.data.estimatedDiningDollarsCents).toBeUndefined();
    }
  });

  it("refuses a fabricated $0.00 estimate, because empty already means none", () => {
    const result = structuredSchema.safeParse(
      mealExchange({ estimatedDiningDollarsCents: 0 })
    );

    expect(result.success).toBe(false);
  });

  it.each([1, 100, MAX_MEAL_EXCHANGE_DINING_DOLLARS_CENTS])(
    "accepts the optional estimate %d cents, at or below $25.00",
    (cents) => {
      const result = structuredSchema.safeParse(
        mealExchange({ estimatedDiningDollarsCents: cents })
      );

      expect(result.success).toBe(true);
    }
  );

  it("refuses a Meal Exchange estimate above $25.00", () => {
    const result = structuredSchema.safeParse(
      mealExchange({
        estimatedDiningDollarsCents: MAX_MEAL_EXCHANGE_DINING_DOLLARS_CENTS + 1,
      })
    );

    expect(result.success).toBe(false);
  });

  it("refuses a fractional cent rather than rounding it to something the requester did not enter", () => {
    const result = structuredSchema.safeParse(
      mealExchange({ estimatedDiningDollarsCents: 1234.5 })
    );

    expect(result.success).toBe(false);
  });

  it("refuses order details on the Meal Exchange path", () => {
    const result = structuredSchema.safeParse(
      mealExchange({ orderDetails: "Should not be here" })
    );

    expect(result.success).toBe(false);
  });
});

describe("W4-R4 Dining-Dollars-only validation", () => {
  it("accepts zero swipes with required order details and a required estimate", () => {
    const result = structuredSchema.safeParse(diningDollars());

    expect(result.success).toBe(true);
  });

  it.each([1, 2, 5])(
    "refuses a Dining-Dollars-only request claiming %d meal swipes",
    (mealSwipes) => {
      const result = structuredSchema.safeParse(diningDollars({ mealSwipes }));

      expect(result.success).toBe(false);
    }
  );

  it("refuses a Dining-Dollars-only request with no order details", () => {
    const body = diningDollars();
    delete (body as Record<string, unknown>).orderDetails;

    expect(structuredSchema.safeParse(body).success).toBe(false);
  });

  it("refuses blank order details", () => {
    expect(
      structuredSchema.safeParse(diningDollars({ orderDetails: "   " })).success
    ).toBe(false);
  });

  it("refuses a Dining-Dollars-only request with no estimate, which is required here", () => {
    const body = diningDollars();
    delete (body as Record<string, unknown>).estimatedDiningDollarsCents;

    expect(structuredSchema.safeParse(body).success).toBe(false);
  });

  it.each([1, 2_500, MAX_DINING_DOLLARS_ONLY_CENTS])(
    "accepts the required estimate %d cents, at or below $50.00",
    (cents) => {
      const result = structuredSchema.safeParse(
        diningDollars({ estimatedDiningDollarsCents: cents })
      );

      expect(result.success).toBe(true);
    }
  );

  it.each([0, -1, MAX_DINING_DOLLARS_ONLY_CENTS + 1])(
    "refuses the out-of-range estimate %d cents",
    (cents) => {
      const result = structuredSchema.safeParse(
        diningDollars({ estimatedDiningDollarsCents: cents })
      );

      expect(result.success).toBe(false);
    }
  );

  it("refuses meal details on the Dining-Dollars-only path", () => {
    const result = structuredSchema.safeParse(
      diningDollars({ mealItems: [{ name: "Rice bowl" }] })
    );

    expect(result.success).toBe(false);
  });
});

describe("W4-R4 cross-path combinations", () => {
  it("refuses an unrecognized menu path rather than inferring one from the other fields", () => {
    expect(
      structuredSchema.safeParse(mealExchange({ menuPath: "swipes" })).success
    ).toBe(false);
    expect(
      structuredSchema.safeParse(mealExchange({ menuPath: undefined })).success
    ).toBe(false);
  });

  it("refuses a request that satisfies neither path cleanly", () => {
    // Zero swipes on the Meal Exchange path and a full Dining-Dollars body:
    // the combination looks like one path's data under the other's label, and
    // is refused rather than silently reinterpreted as the path it resembles.
    const result = structuredSchema.safeParse({
      menuPath: "meal-exchange",
      mealSwipes: 0,
      orderDetails: "Grain bowl",
      estimatedDiningDollarsCents: 1_850,
    });

    expect(result.success).toBe(false);
  });

  it("refuses a pickupName key on the structured shape", () => {
    // `.strict()` is what makes W4-R4's removal enforceable rather than
    // advisory: a client still sending the removed field is refused, not
    // silently stripped.
    const result = structuredSchema.safeParse(
      mealExchange({ pickupName: "Requester Private Name" })
    );

    expect(result.success).toBe(false);
  });

  it("refuses a client-supplied food summary, which the backend derives", () => {
    const result = structuredSchema.safeParse(
      mealExchange({ food: "Client-written summary" })
    );

    expect(result.success).toBe(false);
  });
});

describe("exact currency representation", () => {
  it.each([
    [1, "$0.01"],
    [5, "$0.05"],
    [99, "$0.99"],
    [100, "$1.00"],
    [1_005, "$10.05"],
    [1_234, "$12.34"],
    [2_500, "$25.00"],
    [5_000, "$50.00"],
  ])("formats %d cents as %s with no rounding drift", (cents, expected) => {
    expect(formatDiningDollars(cents)).toBe(expected);
  });

  it("formats every cent value up to $50.00 without ever losing a cent", () => {
    // The exhaustive version of the table above: integer arithmetic means the
    // rendered value and the stored value agree for every accepted amount,
    // which is what "currency must remain exact" actually requires.
    for (let cents = 1; cents <= MAX_DINING_DOLLARS_ONLY_CENTS; cents += 1) {
      const formatted = formatDiningDollars(cents);
      const [dollarPart, centPart] = formatted.slice(1).split(".");
      expect(centPart).toHaveLength(2);
      expect(Number(dollarPart) * 100 + Number(centPart)).toBe(cents);
    }
  });
});

describe("derived food summary", () => {
  it("joins Meal Exchange entries in the requester's own order", () => {
    const structured: StructuredRequestInput = {
      menuPath: "meal-exchange",
      mealSwipes: 3,
      mealItems: [{ name: "Rice bowl" }, { name: "Side salad", details: "No onions" }, { name: "Iced tea" }],
    };

    expect(deriveFoodSummary(structured)).toBe(
      "Rice bowl; Side salad (No onions); Iced tea"
    );
  });

  it("names the optional Meal Exchange estimate exactly when there is one", () => {
    expect(
      deriveFoodSummary({
        menuPath: "meal-exchange",
        mealSwipes: 1,
        mealItems: [{ name: "Rice bowl" }],
        estimatedDiningDollarsCents: 1_250,
      })
    ).toBe("Rice bowl + $12.50 Dining Dollars");
  });

  it("says nothing about Dining Dollars when the requester needed none", () => {
    const summary = deriveFoodSummary({
      menuPath: "meal-exchange",
      mealSwipes: 1,
      mealItems: [{ name: "Rice bowl" }],
    });

    expect(summary).toBe("Rice bowl");
    expect(summary).not.toContain("$");
    // Specifically not a fabricated zero, which would tell a helper the
    // requester stated an amount they deliberately left empty.
    expect(summary).not.toContain("$0.00");
  });

  it("states the order and the exact estimate on the Dining-Dollars-only path", () => {
    expect(
      deriveFoodSummary({
        menuPath: "dining-dollars",
        mealSwipes: 0,
        orderDetails: "Grain bowl with extra avocado",
        estimatedDiningDollarsCents: 1_850,
      })
    ).toBe("Grain bowl with extra avocado ($18.50 Dining Dollars)");
  });

  it("derives only from values the requester supplied", () => {
    // The summary is a rendering of the structured fields, never an addition
    // to them: every token in it comes from the entries or the estimate.
    const summary = deriveFoodSummary({
      menuPath: "meal-exchange",
      mealSwipes: 2,
      mealItems: [{ name: "Rice bowl" }, { name: "Side salad" }],
    });

    expect(summary.replace(/[;\s]/g, "")).toBe("RicebowlSidesalad");
  });
});
