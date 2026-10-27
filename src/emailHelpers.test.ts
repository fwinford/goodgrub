import { readFileSync } from "node:fs";
import type { IRequest, ISubscriber } from "../models/db.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("./requestAlertEmailDelivery.js", () => ({ assertRequestAlertEmailDeliveryActive: () => {} }));

const { resendSend } = vi.hoisted(() => ({
  resendSend: vi.fn(),
}));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));

import {
  EmailProviderTimeoutError,
  PARTICIPANT_VERIFICATION_SEND_LABEL,
  confirmationBaseUrl,
  sendFulfillmentEmail,
  sendNewRequestAlert,
  sendParticipantVerificationEmail,
  sendSubscriptionConfirmationEmail,
} from "./emailHelpers.js";
import {
  UNSUBSCRIBE_CREDENTIAL_PARAMETER,
  UNSUBSCRIBE_ROUTE_PATH,
  verifyUnsubscribeCredential,
} from "./unsubscribeCredential.js";

// A fixed injected secret rather than a stubbed environment variable, so these
// cases do not depend on process-wide state another suite could change.
const SIGNING_SECRET = Buffer.alloc(32, 5);
const SUBSCRIBER_ID = "64b000000000000000000002";

const requesterEmail = "requester-private@example.edu";
const requesterPhone = "555-0100";
const pickupName = "Requester Private Name";
const claimToken = "private-claim-token";

function request(overrides: Record<string, unknown> = {}): IRequest {
  return {
    _id: "64b000000000000000000001",
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName,
    pickupWindowText: "1:00 PM – 2:00 PM",
    email: requesterEmail,
    requesterPhone,
    claimToken,
    status: "open",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    updatedAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
    // Every request accepted since W3-C1 carries an integer 1-5, on every
    // accepted shape including the legacy web one, so an ordinary fixture
    // always supplies it.
    mealSwipes: 3,
    ...overrides,
  } as unknown as IRequest;
}

function subscriber(overrides: Record<string, unknown> = {}): ISubscriber {
  return {
    _id: SUBSCRIBER_ID,
    email: "helper@example.edu",
    status: "confirmed",
    unsubscribeCredentialVersion: 1,
    dailyCount: 0,
    bounced: false,
    ...overrides,
  } as unknown as ISubscriber;
}

/** The single `credential` query parameter carried by an emailed link. */
function credentialFrom(url: string): string | null {
  return new URL(url).searchParams.get(UNSUBSCRIBE_CREDENTIAL_PARAMETER);
}

function unsubscribeUrlIn(text: string): string {
  const match = text.match(
    new RegExp(`https?://[^\\s"'<>]*${UNSUBSCRIBE_ROUTE_PATH}\\?credential=[^\\s"'<>]+`)
  );
  expect(match).not.toBeNull();
  return match![0];
}

afterEach(() => {
  resendSend.mockReset();
  vi.unstubAllEnvs();
});

describe("helper new-request alert email", () => {
  it("uses only public request fields and omits the unsupported website link", async () => {
    const configuredBaseUrl = "https://api.goodgrubapp.test";
    vi.stubEnv("BASE_URL", configuredBaseUrl);
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(subscriber(), request(), {
      unsubscribeSigningSecret: SIGNING_SECRET,
    });

    const email = resendSend.mock.calls[0][0] as {
      subject: string;
      html: string;
      text: string;
    };
    const allHelperContent = JSON.stringify(email);
    expect(email.subject).toBe(
      "New meal request: Campus Market · 1:00 PM – 2:00 PM"
    );
    expect(email.html).toContain("<strong>Vendor:</strong> Campus Market");
    expect(email.html).toContain(
      "<strong>Food:</strong> Vegetable rice bowl"
    );
    expect(email.html).toContain(
      "<strong>Pickup Window:</strong> 1:00 PM – 2:00 PM"
    );
    expect(allHelperContent).not.toContain("View meal request");
    expect(email.html).not.toContain(`href="${configuredBaseUrl}/"`);
    expect(allHelperContent).not.toContain(pickupName);
    expect(allHelperContent).not.toContain(requesterEmail);
    expect(allHelperContent).not.toContain(requesterPhone);
    expect(allHelperContent).not.toContain(claimToken);
    expect(allHelperContent).not.toContain("/fulfill");
    expect(allHelperContent).not.toMatch(/order this|fulfill this|claim/i);
  });

  it("includes the meal-swipe quantity concisely, in both text and HTML (W3-C1)", async () => {
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(subscriber(), request({ mealSwipes: 2 }), {
      unsubscribeSigningSecret: SIGNING_SECRET,
    });

    const email = resendSend.mock.calls[0][0] as {
      html: string;
      text: string;
    };
    expect(email.html).toContain("<strong>Meal swipes:</strong> 2");
    expect(email.text).toContain("Meal swipes: 2");
  });

  it("defensively omits the meal-swipe line for a malformed pre-C1 stored request with no quantity", async () => {
    // Every shape `POST /api/request` accepts, including the legacy web one,
    // has required an integer 1-5 since W3-C1; a `Request` document with none
    // is not a supported representation of any accepted submission, only a
    // stale/malformed stored row. This proves the composer degrades safely
    // rather than fabricating a value for that impossible state.
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(
      subscriber(),
      request({ mealSwipes: undefined }),
      { unsubscribeSigningSecret: SIGNING_SECRET }
    );

    const email = resendSend.mock.calls[0][0] as {
      html: string;
      text: string;
    };
    expect(email.html).not.toContain("Meal swipes");
    expect(email.text).not.toContain("Meal swipes");
  });

  it("renders requester markup as text without double escaping", async () => {
    resendSend.mockResolvedValue({});
    const injectedVendor = `Campus & <img src=x onerror="alert('vendor')">`;
    const injectedFood = `<a href="https://attacker.invalid">Free meal</a>`;
    const injectedPickupWindow = `5 < 6 & "soon"`;

    await sendNewRequestAlert(
      subscriber(),
      request({
        vendor: injectedVendor,
        food: injectedFood,
        pickupWindowText: injectedPickupWindow,
      }),
      { unsubscribeSigningSecret: SIGNING_SECRET }
    );

    const email = resendSend.mock.calls[0][0] as { html: string };
    expect(email.html).toContain(
      `Campus &amp; &lt;img src=x onerror=&quot;alert(&#39;vendor&#39;)&quot;&gt;`
    );
    expect(email.html).toContain(
      `&lt;a href=&quot;https://attacker.invalid&quot;&gt;Free meal&lt;/a&gt;`
    );
    expect(email.html).toContain(`5 &lt; 6 &amp; &quot;soon&quot;`);
    expect(email.html).not.toContain(injectedVendor);
    expect(email.html).not.toContain(injectedFood);
    expect(email.html).not.toContain(injectedPickupWindow);
    expect(email.html).not.toContain("&amp;amp;");
    expect(email.html).not.toContain("&amp;lt;");
  });
});

describe("helper alert unsubscribe link", () => {
  // Vitest supplies its own `BASE_URL`, so the configured origin is stated
  // here rather than inherited from whatever the runner happens to set.
  beforeEach(() => {
    vi.stubEnv("BASE_URL", "https://commonplate.test/");
  });

  it("carries a correctly formed unsubscribe URL in both bodies", async () => {
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(subscriber(), request(), {
      unsubscribeSigningSecret: SIGNING_SECRET,
    });

    const email = resendSend.mock.calls[0][0] as {
      html: string;
      text: string;
    };
    const htmlUrl = unsubscribeUrlIn(email.html);
    const textUrl = unsubscribeUrlIn(email.text);

    expect(htmlUrl).toBe(textUrl);
    // Configured origin, accepted path, one `credential` parameter, and no
    // doubled separator from the trailing slash in `BASE_URL`.
    expect(htmlUrl.startsWith(`https://commonplate.test${UNSUBSCRIBE_ROUTE_PATH}?`)).toBe(true);
    expect([...new URL(htmlUrl).searchParams.keys()]).toEqual([
      UNSUBSCRIBE_CREDENTIAL_PARAMETER,
    ]);
  });

  it("emails a credential that verifies for exactly this subscriber", async () => {
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(subscriber(), request(), {
      unsubscribeSigningSecret: SIGNING_SECRET,
    });

    const email = resendSend.mock.calls[0][0] as { html: string };
    const credential = credentialFrom(unsubscribeUrlIn(email.html));

    expect(
      verifyUnsubscribeCredential(credential, SIGNING_SECRET)
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 1 });
  });

  it("needs no stored raw unsubscribe token to build the link", async () => {
    resendSend.mockResolvedValue({});
    // Neither a raw token nor a stored digest exists on this document, and a
    // subscriber written before the version field carries no version either.
    const withoutStoredCredential = subscriber({
      unsubscribeCredentialVersion: undefined,
    });

    await sendNewRequestAlert(withoutStoredCredential, request(), {
      unsubscribeSigningSecret: SIGNING_SECRET,
    });

    const email = resendSend.mock.calls[0][0] as { html: string };
    expect(
      verifyUnsubscribeCredential(
        credentialFrom(unsubscribeUrlIn(email.html)),
        SIGNING_SECRET
      )
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 1 });
  });

  it("reflects a raised credential version in the emailed link", async () => {
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(
      subscriber({ unsubscribeCredentialVersion: 4 }),
      request(),
      { unsubscribeSigningSecret: SIGNING_SECRET }
    );

    const email = resendSend.mock.calls[0][0] as { html: string };
    expect(
      verifyUnsubscribeCredential(
        credentialFrom(unsubscribeUrlIn(email.html)),
        SIGNING_SECRET
      )
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 4 });
  });
});

describe("subscription confirmation email", () => {
  it("places the raw token only in the submitted confirmation URL", async () => {
    vi.stubEnv("BASE_URL", "https://commonplate.test/");
    resendSend.mockResolvedValue({ data: { id: "email-id" }, error: null });
    const rawToken = Buffer.alloc(32, 7).toString("base64url");

    await sendSubscriptionConfirmationEmail("helper@example.edu", rawToken);

    const email = resendSend.mock.calls[0][0] as {
      to: string;
      subject: string;
      html: string;
      text: string;
    };
    const expectedUrl = `https://commonplate.test/api/subscribe/confirm?token=${rawToken}`;
    expect(email.to).toBe("helper@example.edu");
    expect(email.subject).toBe("Confirm your CommonPlate subscription");
    expect(email.html).toContain(expectedUrl);
    expect(email.text).toContain(expectedUrl);
  });

  it("builds the confirmation URL only from trusted configuration", () => {
    vi.stubEnv("BASE_URL", "https://commonplate.test");
    expect(confirmationBaseUrl()).toBe("https://commonplate.test");

    // No request is reachable from here at all, so no `Host`,
    // `X-Forwarded-Host`, or forwarded protocol can reach a bearer-token link.
    const source = readFileSync(
      new URL("./emailHelpers.ts", import.meta.url),
      "utf8"
    );
    const confirmationStart = source.indexOf(
      "export async function sendSubscriptionConfirmationEmail"
    );
    expect(confirmationStart).toBeGreaterThanOrEqual(0);
    const confirmationEnd = source.indexOf(
      "export async function sendNewRequestAlert",
      confirmationStart
    );
    expect(confirmationEnd).toBeGreaterThan(confirmationStart);
    const confirmationSource = source.slice(confirmationStart, confirmationEnd);
    expect(confirmationSource).not.toMatch(/req\b|host|protocol|forwarded/i);
  });

  it.each([
    ["returned error", () => resendSend.mockResolvedValue({ error: { message: "rejected" } })],
    ["thrown error", () => resendSend.mockRejectedValue(new Error("offline"))],
  ])("rejects a provider %s", async (_label, arrange) => {
    arrange();

    await expect(
      sendSubscriptionConfirmationEmail(
        "helper@example.edu",
        Buffer.alloc(32, 8).toString("base64url")
      )
    ).rejects.toThrow();
  });

  it("hands the provider a real abort signal and cancels it at the deadline", async () => {
    vi.useFakeTimers();
    try {
      let capturedSignal: AbortSignal | undefined;
      // Never settles on its own: only a genuine abort can end this call, so a
      // racing promise that left the request in flight would time the test out.
      resendSend.mockImplementation(
        (_payload: unknown, options: { signal?: AbortSignal }) =>
          new Promise((_resolve, reject) => {
            capturedSignal = options?.signal;
            options?.signal?.addEventListener("abort", () =>
              reject(new Error("The operation was aborted"))
            );
          })
      );

      const pending = sendSubscriptionConfirmationEmail(
        "helper@example.edu",
        Buffer.alloc(32, 9).toString("base64url"),
        1_000
      );
      const settled = expect(pending).rejects.toBeInstanceOf(
        EmailProviderTimeoutError
      );

      expect(capturedSignal).toBeInstanceOf(AbortSignal);
      expect(capturedSignal!.aborted).toBe(false);
      await vi.advanceTimersByTimeAsync(1_000);
      expect(capturedSignal!.aborted).toBe(true);

      await settled;
      // Pinned: `subscribeRoute.mongo.test.ts` drives the compensation path
      // with an error carrying exactly this name.
      await expect(pending).rejects.toMatchObject({
        name: "EmailProviderTimeoutError",
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("clears its deadline once the provider answers", async () => {
    vi.useFakeTimers();
    try {
      resendSend.mockResolvedValue({ data: { id: "email-id" }, error: null });

      await sendSubscriptionConfirmationEmail(
        "helper@example.edu",
        Buffer.alloc(32, 10).toString("base64url")
      );

      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("requester email separation", () => {
  it("retains pickup and order information in the requester fulfillment email", async () => {
    resendSend.mockResolvedValue({});

    await sendFulfillmentEmail(
      request(),
      "70154321",
      "15 minutes",
      "Your meal is ready",
      "helper@example.edu"
    );

    // Asserts the option name the Resend SDK actually reads. The SDK builds its
    // request body from `replyTo` alone, so asserting the wire name `reply_to`
    // here would pass while the sent email carried no Reply-To at all.
    const email = resendSend.mock.calls[0][0] as {
      to: string;
      html: string;
      text: string;
      replyTo: string;
      reply_to?: string;
    };

    expect(email.to).toBe(requesterEmail);
    // W4-R4 removed pickup name from the V1 request contract, so the
    // fulfillment email no longer carries one. `pickupName` is still on the
    // fixture, so this proves removal from the composition rather than merely
    // an absent input.
    expect(email.html).not.toContain("Pickup name");
    expect(email.html).not.toContain(pickupName);
    expect(email.text).not.toContain("Pickup name");
    expect(email.text).not.toContain(pickupName);
    expect(email.html).toContain("Order number:</strong> 70154321");
    expect(email.html).toContain("Pickup window:</strong> 1:00 PM – 2:00 PM");
    expect(email.html).toContain("ETA:</strong> 15 minutes");
    expect(email.html).toContain("Your meal is ready");
    expect(email.text).toContain("Order number: 70154321");
    expect(email.text).toContain("Pickup window: 1:00 PM – 2:00 PM");
    expect(email.text).toContain("ETA: 15 minutes");
    expect(email.text).toContain("Your meal is ready");
    expect(email.replyTo).toBe("helper@example.edu");
    expect(email.reply_to).toBeUndefined();
  });

  // The helper types their address into the fulfillment form, so the one way
  // this notification can go wrong without failing is by treating that address
  // as the destination. The student is the recipient; the helper is only ever
  // the Reply-To.
  it("never lets the helper become the recipient of the fulfillment email", async () => {
    resendSend.mockResolvedValue({});
    const helperEmail = "helper@example.edu";

    await sendFulfillmentEmail(
      request(),
      "70154321",
      "ASAP",
      undefined,
      helperEmail
    );

    const email = resendSend.mock.calls[0][0] as {
      to: string;
      replyTo?: string;
    };
    expect(email.to).toBe(requesterEmail);
    expect(email.to).not.toBe(helperEmail);
    expect(email.replyTo).toBe(helperEmail);
  });

  // A request with no stored student address cannot be notified. Failing loudly
  // keeps the route's post-commit catch honest — placement stays recorded and
  // the response reports `failed` — instead of silently sending nowhere.
  it("refuses to send when the request carries no student email", async () => {
    resendSend.mockResolvedValue({});

    await expect(
      sendFulfillmentEmail(
        request({ email: undefined }),
        "70154321",
        "ASAP",
        undefined,
        "helper@example.edu"
      )
    ).rejects.toThrow();
    expect(resendSend).not.toHaveBeenCalled();
  });

  /**
   * The grandfathered pre-I1 placement (W3-I1). A claim granted before verified
   * helper identity existed has no verified principal to offer, and the payload
   * no longer carries one either, so this email is built with no reply address
   * at all. Rendered directly rather than through a mocked route seam: what
   * matters is the message the requester actually receives.
   */
  it("omits the reply line entirely when there is no verified helper address", async () => {
    resendSend.mockResolvedValue({});

    await sendFulfillmentEmail(
      request(),
      "70154321",
      "15 minutes",
      "Your meal is ready",
      undefined
    );

    const email = resendSend.mock.calls[0][0] as {
      to: string;
      html: string;
      text: string;
      replyTo?: string;
    };

    // An empty `mailto:` looks like contact the requester has and does not, and
    // tapping it opens a blank message to nobody.
    expect(email.html).not.toContain("mailto:");
    expect(email.html).not.toContain("You can reply to them at");
    expect(email.text).not.toContain("You can reply to them at");
    expect(email.replyTo).toBeUndefined();

    // Everything that actually lets the requester collect their food survives.
    expect(email.to).toBe(requesterEmail);
    // W4-R4 removed pickup name from the V1 request contract, so the
    // fulfillment email no longer carries one. `pickupName` is still on the
    // fixture, so this proves removal from the composition rather than merely
    // an absent input.
    expect(email.html).not.toContain("Pickup name");
    expect(email.html).not.toContain(pickupName);
    expect(email.text).not.toContain("Pickup name");
    expect(email.text).not.toContain(pickupName);
    expect(email.html).toContain("Order number:</strong> 70154321");
    expect(email.html).toContain("Pickup window:</strong> 1:00 PM – 2:00 PM");
    expect(email.html).toContain("ETA:</strong> 15 minutes");
    expect(email.html).toContain("Your meal is ready");
    expect(email.text).toContain("Order number: 70154321");
    expect(email.text).toContain("ETA: 15 minutes");
    expect(email.text).toContain("Your meal is ready");
    expect(email.text).toContain("Thanks for using CommonPlate!");
  });

  it("keeps requester confirmation window information intact and carries no pickup name", () => {
    const routeSource = readFileSync(
      new URL("./createRequestRoute.ts", import.meta.url),
      "utf8"
    );
    const confirmationStart = routeSource.indexOf(
      'subject: "Request Confirmed - CommonPlate"'
    );
    // The actual close of the `resend.emails.send({...})` call this
    // confirmation email is built from — not an incidental later "});" match
    // elsewhere in the route, which is fragile to unrelated refactors.
    const confirmationEnd = routeSource.indexOf(
      "    });",
      confirmationStart
    );
    const requesterConfirmation = routeSource.slice(
      confirmationStart,
      confirmationEnd
    );

    expect(confirmationStart).toBeGreaterThan(-1);
    expect(confirmationEnd).toBeGreaterThan(confirmationStart);
    // The window the backend actually granted is still stated, in both parts.
    expect(requesterConfirmation).toContain(
      "<strong>Pickup Window:</strong> ${htmlPickupWindow}"
    );
    expect(requesterConfirmation).toContain(
      "Pickup Window: ${pickupWindowText}"
    );
    // W4-R4: pickup name is gone from the V1 request contract, so the
    // requester confirmation must no longer compose one in either part.
    expect(requesterConfirmation).not.toContain("Pickup Name");
    expect(requesterConfirmation).not.toContain("pickupName");
  });
});

/**
 * The verification code email (W3-I1).
 *
 * This send is unlike every other one in this module: its subject line and both
 * of its bodies contain a live six-digit credential. A provider error, request
 * object, response body, or thrown exception can echo any of them back, so
 * nothing provider-supplied may be logged or re-thrown from here.
 */
describe("participant verification code email", () => {
  const code = "424242";
  const participantEmail = "student@nyu.edu";
  let consoleError: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  /** Everything a provider could plausibly hand back that quotes the send. */
  function leakyProviderValue() {
    return {
      message: `422 rejected: to=${participantEmail} subject="${code} is your CommonPlate verification code"`,
      name: "validation_error",
      request: { to: participantEmail, text: `code ${code}` },
      response: { body: `<p>${code}</p>` },
    };
  }

  function loggedText() {
    return JSON.stringify(consoleError.mock.calls);
  }

  it("carries the code to the recipient and nowhere else on success", async () => {
    resendSend.mockResolvedValue({});

    await sendParticipantVerificationEmail(participantEmail, code, 10);

    const email = resendSend.mock.calls[0][0] as {
      to: string;
      subject: string;
      html: string;
      text: string;
    };
    expect(email.to).toBe(participantEmail);
    expect(email.subject).toContain(code);
    expect(email.html).toContain(code);
    expect(email.text).toContain(code);
    expect(consoleError).not.toHaveBeenCalled();
  });

  it("logs and rethrows nothing provider-supplied when the provider returns an error", async () => {
    resendSend.mockResolvedValue({ error: leakyProviderValue() });

    await expect(
      sendParticipantVerificationEmail(participantEmail, code, 10)
    ).rejects.toThrow(PARTICIPANT_VERIFICATION_SEND_LABEL);

    for (const forbidden of [code, participantEmail, "validation_error"]) {
      expect(loggedText()).not.toContain(forbidden);
    }
    expect(loggedText()).toContain(PARTICIPANT_VERIFICATION_SEND_LABEL);
  });

  it("logs and rethrows nothing provider-supplied when the provider throws", async () => {
    resendSend.mockRejectedValue(
      Object.assign(new Error(leakyProviderValue().message), {
        response: leakyProviderValue().response,
      })
    );

    // The thrown error is a new one, not the provider's: the caller must not be
    // handed an object whose message quotes the code.
    const thrown = await sendParticipantVerificationEmail(
      participantEmail,
      code,
      10
    ).then(
      () => null,
      (error: unknown) => error as Error
    );

    expect(thrown).toBeInstanceOf(Error);
    expect(thrown!.message).toBe(
      `${PARTICIPANT_VERIFICATION_SEND_LABEL} send failed`
    );
    for (const forbidden of [code, participantEmail]) {
      expect(thrown!.message).not.toContain(forbidden);
      expect(loggedText()).not.toContain(forbidden);
    }
  });

  it("reports its own deadline without quoting the send", async () => {
    resendSend.mockImplementation(
      (_opts: unknown, requestOptions: { signal?: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          requestOptions.signal?.addEventListener("abort", () =>
            reject(new Error(`aborted while sending ${code}`))
          );
        })
    );

    const thrown = await sendParticipantVerificationEmail(
      participantEmail,
      code,
      10,
      5
    ).then(
      () => null,
      (error: unknown) => error as Error
    );

    expect(thrown).toBeInstanceOf(EmailProviderTimeoutError);
    expect(thrown!.message).not.toContain(code);
    expect(loggedText()).not.toContain(code);
    expect(loggedText()).not.toContain(participantEmail);
  });

  it("does not log raw provider diagnostics for other senders", async () => {
    // The provider's response can carry recipient or request details. Keep the
    // existing thrown error for caller behavior, but never put it in logs.
    resendSend.mockResolvedValue({ error: { message: "quota exceeded" } });

    await expect(
      sendNewRequestAlert(subscriber(), request(), {
        unsubscribeSigningSecret: SIGNING_SECRET,
      })
    ).rejects.toThrow("quota exceeded");
    expect(loggedText()).not.toContain("quota exceeded");
    expect(loggedText()).toContain("[Resend] provider request failed");
  });
});
