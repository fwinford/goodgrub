import { readFileSync } from "node:fs";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

let newRequest: typeof import("./new-request.js");

beforeAll(async () => {
  vi.stubGlobal("document", {
    addEventListener: vi.fn(),
  });

  newRequest = await import("./new-request.js");
});

afterAll(() => {
  vi.unstubAllGlobals();
});

afterEach(() => {
  vi.restoreAllMocks();
});

function formRoot() {
  const notice = { textContent: "", hidden: true };
  const fields = { disabled: false };
  const submitBtn = {
    disabled: false,
    attributes: {} as Record<string, string>,
    setAttribute(name: string, value: string) {
      this.attributes[name] = value;
    },
  };
  const elements: Record<string, unknown> = {
    "pause-notice": notice,
    "request-fields": fields,
    "submit-btn": submitBtn,
  };

  return {
    notice,
    fields,
    submitBtn,
    root: {
      getElementById: (id: string) => elements[id] ?? null,
    } as unknown as Document,
  };
}

/**
 * W3-I1 cross-client boundary correction: the legacy website must not present
 * an actionable request form once the backend requires verified participant
 * authority it cannot supply. Posting is unconditionally non-actionable here
 * — not tied to `PUBLIC_ACTIONS_PAUSED` — until Week 6 website participant
 * verification exists.
 */
describe("web request form unavailability (W3-I1 cross-client boundary)", () => {
  it("reveals the notice and disables the whole field set, not only the submit button", () => {
    const { notice, fields, submitBtn, root } = formRoot();

    newRequest.applyRequestFormUnavailable(root);

    expect(notice.textContent).toBe(
      newRequest.WEBSITE_REQUEST_CREATION_UNAVAILABLE_MESSAGE
    );
    expect(notice.hidden).toBe(false);
    expect(fields.disabled).toBe(true);
    expect(submitBtn.disabled).toBe(true);
    expect(submitBtn.attributes["aria-disabled"]).toBe("true");
  });

  it("is scoped to the web, not a repeat of the old pause sentence", () => {
    expect(newRequest.WEBSITE_REQUEST_CREATION_UNAVAILABLE_MESSAGE).toContain(
      "web"
    );
  });
});

describe("web request form reads the canonical create response", () => {
  it("confirms submission and takes the request id from the canonical wrapper", () => {
    const message = newRequest.submissionSuccessText(
      "64b000000000000000000001"
    );

    expect(message).toBe(
      "Request submitted successfully! Request ID: 64b000000000000000000001"
    );
    expect(message).toContain("submitted successfully");
    expect(message).toContain("64b000000000000000000001");
  });

  it("never renders an undefined request id", () => {
    expect(newRequest.submissionSuccessText(undefined)).toBe(
      "Request submitted successfully!"
    );
    expect(newRequest.submissionSuccessText(undefined)).not.toContain(
      "undefined"
    );
  });

  /// Persistence succeeds independently of requester email delivery, so the
  /// success message must not promise a message that may never be sent.
  it("promises no email delivery", () => {
    for (const message of [
      newRequest.submissionSuccessText("64b000000000000000000001"),
      newRequest.submissionSuccessText(undefined),
    ]) {
      for (const forbidden of [
        "email",
        "e-mail",
        "confirmation",
        "confirm",
        "inbox",
        "sent",
        "send",
        "receive",
        "check your",
      ]) {
        expect(message.toLowerCase()).not.toContain(forbidden);
      }
    }
  });

  it("reads the message out of the structured error envelope", () => {
    expect(
      newRequest.errorMessage({
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      })
    ).toBe("You have reached the daily limit of 3 meal requests");
  });

  it("still reads the legacy flat error string", () => {
    expect(newRequest.errorMessage("missing fields")).toBe("missing fields");
    expect(newRequest.errorMessage(undefined)).toBeUndefined();
  });

  /**
   * `POST /api/request` now requires participant authority regardless of
   * client, so any of these codes is what a direct API caller — never this
   * page, whose form is unconditionally disabled — would decode. `errorMessage`
   * is generic decoding shared by every caller of the create endpoint's error
   * envelope, so it is pinned here too: a raw code or `[object Object]` must
   * never reach a reader through this path either.
   */
  it.each([
    [
      "PARTICIPANT_VERIFICATION_REQUIRED",
      "Verify your NYU email before posting or helping with a request.",
    ],
    ["PARTICIPANT_AUTHORITY_INVALID", "Verify your NYU email again to continue."],
    [
      "PARTICIPANT_VERIFICATION_UNAVAILABLE",
      "We couldn’t check your NYU verification right now. Please try again in a moment.",
    ],
  ])("renders the participant refusal %s as a readable sentence", (code, message) => {
    const rendered = newRequest.errorMessage({ code, message });

    expect(rendered).toBe(message);
    expect(rendered).not.toContain(code);
    expect(rendered).not.toContain("[object Object]");
  });
});

/**
 * The email hint is static markup, so it is asserted against the page source
 * rather than through the bundled script. The same sentence is asserted on
 * iOS in `RequestCreationViewTests`; both halves must exist or the two
 * requester forms can explain the same required field differently.
 */
describe("web request form explains why it needs an email", () => {
  const pageSource = readFileSync(
    new URL("../../public/new-request.html", import.meta.url),
    "utf8"
  );

  function emailHint(): string {
    const match = pageSource.match(
      /<input[^>]*id="email"[^>]*>\s*<small>([^<]*)<\/small>/
    );
    expect(match, "no <small> hint found after the email input").not.toBeNull();
    return match![1];
  }

  it("states the purpose and the privacy guarantee", () => {
    expect(emailHint()).toBe(
      "We use your email to coordinate updates about your request. Helpers never see it."
    );
  });

  /// Requester confirmation is sent after persistence and cannot undo it, so
  /// a `201` does not prove any message was sent.
  it("guarantees no email delivery", () => {
    const hint = emailHint().toLowerCase();

    for (const forbidden of [
      "we'll send",
      "we will send",
      "confirmation",
      "confirm",
      "notify",
      "inbox",
      "receipt",
      "check your",
    ]) {
      expect(hint).not.toContain(forbidden);
    }
  });
});

describe("web request form privacy disclosure", () => {
  const pageSource = readFileSync(
    new URL("../../public/new-request.html", import.meta.url),
    "utf8"
  );

  it("states the scoped data sharing and retention facts without an absolute", () => {
    for (const expected of [
      "The helper’s email may be sent to the requester for coordination",
      "Placed Request data is retained for seven days",
      "Fulfillment records may be retained longer",
    ]) {
      expect(pageSource).toContain(expected);
    }
    expect(pageSource).not.toContain(
      "We never share your personal information"
    );
    // W4-R4 removed pickup name from the request contract.
    expect(pageSource).not.toMatch(/pickup name/i);
  });
});
