import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

let fulfill: typeof import("./fulfill.js");

beforeAll(async () => {
  vi.stubGlobal("document", {
    addEventListener: vi.fn(),
  });

  fulfill = await import("./fulfill.js");
});

afterAll(() => {
  vi.unstubAllGlobals();
});

describe("legacy web fulfillment pause", () => {
  it("keeps legacy web ordering unavailable", () => {
    expect(fulfill.isLegacyWebOrderingAvailable()).toBe(false);
  });

  it("replaces direct-navigation content with honest unavailable copy", () => {
    const form = { hidden: false };
    const submitBtn = { disabled: false };
    const errorMsg = { textContent: "", style: { display: "none" } };
    const summary = { textContent: "Loading..." };
    const elements: Record<string, unknown> = {
      "fulfill-form": form,
      "submit-btn": submitBtn,
      "error-message": errorMsg,
      "request-summary": summary,
    };
    const root = {
      getElementById: (id: string) => elements[id] ?? null,
    } as unknown as Document;

    fulfill.showLegacyWebOrderingUnavailable(root);

    expect(form.hidden).toBe(true);
    expect(submitBtn.disabled).toBe(true);
    expect(errorMsg.textContent).toBe(
      fulfill.WEB_ORDERING_UNAVAILABLE_MESSAGE
    );
    expect(errorMsg.style.display).toBe("block");
    expect(summary.textContent).toBe(
      fulfill.WEB_ORDERING_UNAVAILABLE_MESSAGE
    );
  });
});

describe("web fulfillment page copy", () => {
  it("does not refer to the removed pickup name", () => {
    const pageSource = readFileSync(
      new URL("../../public/fulfill.html", import.meta.url),
      "utf8"
    );
    // W4-R4 removed pickup name from the request contract.
    expect(pageSource).not.toMatch(/pickup name/i);
  });
});
