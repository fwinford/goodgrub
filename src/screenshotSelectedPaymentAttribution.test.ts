import { describe, expect, it } from "vitest";
import { currentOrderTotalCents, evaluateEligibility, resolveMenuPath } from "./screenshotEligibility.js";

const review = (...parts: string[]) => ["Review your pickup order", ...parts].join("\n");
const payment = ["Your payment", "Payment method"];
const none = { menuPath: null, conflict: false };
const dd = { menuPath: "dining-dollars", conflict: false };
const me = { menuPath: "meal-exchange", conflict: false };

describe("bounded selected-payment attribution", () => {
  it("accepts one inert observation for either canonical tender without granting amount authority", () => {
    const dining = review(...payment, "Payment detail", "Dining Dollars");
    const meal = review(...payment, "Payment detail", "Use 1 Meal + Dining Dollars");
    expect(evaluateEligibility(dining).category).toBe("checkout");
    expect(resolveMenuPath([dining])).toEqual(dd);
    expect(currentOrderTotalCents([dining])).toBeNull();
    expect(resolveMenuPath([meal])).toEqual(me);
    expect(resolveMenuPath([review(...payment, "Payment detail", "Dining Dollars", "Your order", "Total $4.30")])).toEqual(dd);
    expect(currentOrderTotalCents([review(...payment, "Payment detail", "Dining Dollars", "Your order", "Total $4.30")])).toBe(430);
  });

  it("preserves immediate, inline, and promo-elsewhere relationships", () => {
    for (const text of [
      review(...payment, "Dining Dollars"),
      review("Your payment", "Payment method Dining Dollars"),
      review("Your payment", "Apply a promo code", "Payment method", "Payment detail", "Dining Dollars", "Apply a promo code ›"),
    ]) expect(resolveMenuPath([text])).toEqual(dd);
  });

  it("refuses two observations, departures, duplicates, and recognized payment signals", () => {
    for (const text of [
      review(...payment, "Dining Dollars and Visa", "Dining Dollars"),
      review(...payment, "Detail A", "Detail B", "Dining Dollars"),
      review(...payment, "Detail A", "Detail B", "Use 1 Meal + Dining Dollars"),
      review("Your order", "1 Bowl", ...payment, "Payment detail", "Receipt", "Dining Dollars"),
      review(...payment, "Review your order", "Dining Dollars"),
      review("Your order", "1 Bowl", ...payment, "Payment detail", "Dining Dollars", "Payment method"),
      review(...payment, "Payment detail", "Dining Dollars", "Visa ending 1234"),
      review(...payment, "Payment detail", "Dining Dollars", "Dining Dollars"),
      review(...payment, "Dining Dollars", "Use 1 Meal + Dining Dollars"),
      review(...payment, "Visa ending 1234", "Dining Dollars"),
      review(...payment, "Split payment", "Dining Dollars"),
      review(...payment, "Dining Dollars $4.30", "Dining Dollars"),
      review(...payment, "Dining Dollars and Visa"),
      review(...payment, "Payment detail"),
    ]) expect(resolveMenuPath([text])).toEqual(none);
  });

  it("keeps unsupported and historical structures outside current DD authority", () => {
    expect(resolveMenuPath(["Review your order\nYour payment\nPayment method\nPayment detail\nDining Dollars"])).toEqual(none);
    expect(resolveMenuPath(["View order\nOrder information\nYour payment\nPayment method\nPayment detail\nDining Dollars"])).toEqual(none);
    expect(resolveMenuPath([review("Your order", "1 Bowl", ...payment, "Payment detail", "Order confirmation", "Dining Dollars")])).toEqual(none);
  });
});
