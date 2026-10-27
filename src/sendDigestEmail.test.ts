import type { IRequest, ISubscriber } from "../models/db.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
vi.mock("./requestAlertEmailDelivery.js", () => ({ assertRequestAlertEmailDeliveryActive: () => {} }));

const { sendEmailSafe } = vi.hoisted(() => ({
  sendEmailSafe: vi.fn(),
}));

vi.mock("./emailHelpers.js", () => ({
  sendEmailSafe,
}));

import { sendDigestEmail } from "./sendDigestEmail.js";
import {
  UNSUBSCRIBE_CREDENTIAL_PARAMETER,
  UNSUBSCRIBE_ROUTE_PATH,
  verifyUnsubscribeCredential,
} from "./unsubscribeCredential.js";

// Injected rather than stubbed into the environment, so these cases carry
// their own signing configuration.
const SIGNING_SECRET = Buffer.alloc(32, 6);
const SUBSCRIBER_ID = "64b000000000000000000003";

function request(
  id: string,
  privatePickupName: string,
  privateRequesterEmail: string,
  overrides: Record<string, unknown> = {}
): IRequest {
  return {
    _id: id,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: privatePickupName,
    pickupWindowText: "1:00 PM – 2:00 PM",
    email: privateRequesterEmail,
    requesterPhone: "555-0100",
    claimToken: "private-claim-token",
    status: "open",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    updatedAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
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

function unsubscribeUrlIn(text: string): string {
  const match = text.match(
    new RegExp(`https?://[^\\s"'<>]*${UNSUBSCRIBE_ROUTE_PATH}\\?credential=[^\\s"'<>]+`)
  );
  expect(match).not.toBeNull();
  return match![0];
}

function credentialFrom(url: string): string | null {
  return new URL(url).searchParams.get(UNSUBSCRIBE_CREDENTIAL_PARAMETER);
}

const signingOptions = { unsubscribeSigningSecret: SIGNING_SECRET };

// These cases describe the resumed send path; the paused case is asserted
// separately below.
beforeEach(() => {
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
});

afterEach(() => {
  sendEmailSafe.mockReset();
  vi.unstubAllEnvs();
});

describe("helper digest email while public actions are paused", () => {
  it("refuses to send rather than returning as if delivered", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    sendEmailSafe.mockResolvedValue({ success: true });

    await expect(
      sendDigestEmail(
        subscriber(),
        [
          request(
            "64b000000000000000000001",
            "Private Name",
            "private@example.edu"
          ),
        ],
        signingOptions
      )
    ).rejects.toThrow(PUBLIC_ACTIONS_PAUSED_ENV);

    expect(sendEmailSafe).not.toHaveBeenCalled();
  });
});

describe("helper digest email", () => {
  it("uses only public request fields and omits the unsupported website link", async () => {
    const configuredBaseUrl = "https://api.goodgrubapp.test";
    vi.stubEnv("BASE_URL", configuredBaseUrl);
    sendEmailSafe.mockResolvedValue({ success: true });
    const privateValues = [
      "First Private Pickup",
      "Second Private Pickup",
      "first-requester@example.edu",
      "second-requester@example.edu",
      "555-0100",
      "private-claim-token",
    ];

    await sendDigestEmail(subscriber(), [
      request(
        "64b000000000000000000001",
        privateValues[0],
        privateValues[2]
      ),
      request(
        "64b000000000000000000002",
        privateValues[1],
        privateValues[3]
      ),
    ], signingOptions);

    const email = sendEmailSafe.mock.calls[0][0] as {
      subject: string;
      html: string;
      text: string;
    };
    const allHelperContent = JSON.stringify(email);
    expect(email.subject).toBe("2 new meal requests in the last hour");
    expect(email.html).toContain(
      "<strong>Campus Market</strong> — Vegetable rice bowl"
    );
    expect(email.html).toContain("<em>1:00 PM – 2:00 PM</em>");
    expect(allHelperContent).not.toContain("View meal request");
    expect(email.html).not.toContain(`href="${configuredBaseUrl}/"`);
    for (const privateValue of privateValues) {
      expect(allHelperContent).not.toContain(privateValue);
    }
    expect(allHelperContent).not.toContain("/fulfill");
    expect(allHelperContent).not.toMatch(/order this|fulfill this|claim/i);
  });

  it("renders requester markup as text without double escaping", async () => {
    sendEmailSafe.mockResolvedValue({ success: true });
    const injectedVendor = `Campus & <img src=x onerror="alert('vendor')">`;
    const injectedFood = `<a href="https://attacker.invalid">Free meal</a>`;
    const injectedPickupWindow = `5 < 6 & "soon"`;

    await sendDigestEmail(subscriber(), [
      request(
        "64b000000000000000000001",
        "Private Pickup",
        "requester@example.edu",
        {
          vendor: injectedVendor,
          food: injectedFood,
          pickupWindowText: injectedPickupWindow,
        }
      ),
    ], signingOptions);

    const email = sendEmailSafe.mock.calls[0][0] as { html: string };
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

describe("helper digest unsubscribe link", () => {
  const digestRequests = () => [
    request("64b000000000000000000001", "Private Name", "private@example.edu"),
  ];

  // Vitest supplies its own `BASE_URL`, so the configured origin is stated
  // here rather than inherited from whatever the runner happens to set.
  beforeEach(() => {
    vi.stubEnv("BASE_URL", "https://commonplate.test/");
  });

  it("carries a correctly formed unsubscribe URL in both bodies", async () => {
    sendEmailSafe.mockResolvedValue({ success: true });

    await sendDigestEmail(subscriber(), digestRequests(), signingOptions);

    const email = sendEmailSafe.mock.calls[0][0] as {
      html: string;
      text: string;
    };
    const htmlUrl = unsubscribeUrlIn(email.html);

    expect(unsubscribeUrlIn(email.text)).toBe(htmlUrl);
    expect(
      htmlUrl.startsWith(`https://commonplate.test${UNSUBSCRIBE_ROUTE_PATH}?`)
    ).toBe(true);
    expect([...new URL(htmlUrl).searchParams.keys()]).toEqual([
      UNSUBSCRIBE_CREDENTIAL_PARAMETER,
    ]);
  });

  it("emails a credential that verifies for exactly this subscriber", async () => {
    sendEmailSafe.mockResolvedValue({ success: true });

    await sendDigestEmail(subscriber(), digestRequests(), signingOptions);

    const email = sendEmailSafe.mock.calls[0][0] as { html: string };

    expect(
      verifyUnsubscribeCredential(
        credentialFrom(unsubscribeUrlIn(email.html)),
        SIGNING_SECRET
      )
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 1 });
  });

  it("needs no stored raw unsubscribe token to build the link", async () => {
    sendEmailSafe.mockResolvedValue({ success: true });

    await sendDigestEmail(
      subscriber({ unsubscribeCredentialVersion: undefined }),
      digestRequests(),
      signingOptions
    );

    const email = sendEmailSafe.mock.calls[0][0] as { html: string };

    expect(
      verifyUnsubscribeCredential(
        credentialFrom(unsubscribeUrlIn(email.html)),
        SIGNING_SECRET
      )
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 1 });
  });

  it("signs the digest link at the subscriber's own credential version", async () => {
    sendEmailSafe.mockResolvedValue({ success: true });

    await sendDigestEmail(
      subscriber({ unsubscribeCredentialVersion: 4 }),
      digestRequests(),
      signingOptions
    );

    const email = sendEmailSafe.mock.calls[0][0] as { html: string };
    const verified = verifyUnsubscribeCredential(
      credentialFrom(unsubscribeUrlIn(email.html)),
      SIGNING_SECRET
    );

    expect(verified).toEqual({
      subscriberId: SUBSCRIBER_ID,
      credentialVersion: 4,
    });
    // A silent downgrade to version 1 would hand a revoked address a working
    // link, so the version is asserted directly rather than only via a match.
    expect(verified?.credentialVersion).not.toBe(1);
  });

  it("keeps the emailed link stable across sends", async () => {
    sendEmailSafe.mockResolvedValue({ success: true });

    await sendDigestEmail(subscriber(), digestRequests(), signingOptions);
    await sendDigestEmail(subscriber(), digestRequests(), signingOptions);

    const [first, second] = sendEmailSafe.mock.calls.map(
      (call: unknown[]) => (call[0] as { html: string }).html
    );
    // No rotation per email: a link the subscriber kept from an older alert
    // must still be the same credential the newest one carries.
    expect(unsubscribeUrlIn(second)).toBe(unsubscribeUrlIn(first));
  });
});
