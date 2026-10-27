import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import { readFileSync } from "node:fs";
import type { PublicMealRequest } from "./home.js";

let home: typeof import("./home.js");

beforeAll(async () => {
  vi.stubGlobal("document", {
    addEventListener: vi.fn(),
    createElement: () => {
      let innerHTML = "";

      return {
        get innerHTML() {
          return innerHTML;
        },
        set textContent(value: string) {
          innerHTML = value
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
        },
      };
    },
  });

  home = await import("./home.js");
});

afterAll(() => {
  vi.unstubAllGlobals();
});

afterEach(() => {
  vi.restoreAllMocks();
});

function publicRequest(
  overrides: Partial<PublicMealRequest> = {}
): PublicMealRequest {
  return {
    id: "request-123",
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupWindowText: "ASAP (available for the next 3 hours)",
    windowStart: null,
    windowEnd: null,
    status: "open",
    createdAt: "2026-07-26T18:00:00.000Z",
    expiresAt: "2026-07-26T22:00:00.000Z",
    ...overrides,
  };
}

describe("homepage subscription pause", () => {
  function subscriberCountRoot() {
    const activeCount = { textContent: "" };
    const heroCount = { textContent: "" };
    const elements: Record<string, unknown> = {
      "active-count": activeCount,
      "active-subscriber-hero": heroCount,
    };
    return {
      activeCount,
      heroCount,
      root: { getElementById: (id: string) => elements[id] ?? null } as unknown as Document,
    };
  }

  function heroRoot() {
    const subscribeBtn = { hidden: false };
    const subscribePanel = { hidden: false, style: { display: "block" } };
    const unavailable = { textContent: "", hidden: true };
    const elements: Record<string, unknown> = {
      "subscribe-cta-btn": subscribeBtn,
      "subscribe-panel": subscribePanel,
      "alerts-unavailable": unavailable,
    };

    return {
      subscribeBtn,
      subscribePanel,
      unavailable,
      root: {
        getElementById: (id: string) => elements[id] ?? null,
      } as unknown as Document,
    };
  }

  it("withholds the signup control and explains why", () => {
    const { subscribeBtn, subscribePanel, unavailable, root } = heroRoot();

    home.applySubscriptionPause(root);

    expect(subscribeBtn.hidden).toBe(true);
    expect(subscribePanel.hidden).toBe(true);
    expect(subscribePanel.style.display).toBe("none");
    expect(unavailable.textContent).toBe(home.ALERTS_UNAVAILABLE_MESSAGE);
    expect(unavailable.hidden).toBe(false);
  });

  it("fails closed when the pause state cannot be read", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));

    await expect(home.fetchPublicActionsPaused()).resolves.toBe(true);
  });

  it("restores the signup control only on an explicit false", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ paused: false }),
      })
    );

    await expect(home.fetchPublicActionsPaused()).resolves.toBe(false);
  });

  it("never describes subscribers as ready to fulfill after pause is established", () => {
    const { activeCount, heroCount, root } = subscriberCountRoot();

    home.applyActiveSubscriberCount(root, 4, true);

    expect(activeCount.textContent).toBe(home.VOLUNTEER_AVAILABILITY_PAUSED_MESSAGE);
    expect(heroCount.textContent).toBe(home.VOLUNTEER_AVAILABILITY_PAUSED_MESSAGE);
    expect(`${activeCount.textContent}${heroCount.textContent}`).not.toContain(
      "ready to fulfill"
    );
  });

  it("does not let a late subscriber count overwrite paused copy", () => {
    const { activeCount, heroCount, root } = subscriberCountRoot();

    home.applyActiveSubscriberCount(root, undefined, true);
    home.applyActiveSubscriberCount(root, 4, true);

    expect(activeCount.textContent).toBe(home.VOLUNTEER_AVAILABILITY_PAUSED_MESSAGE);
    expect(heroCount.textContent).toBe(home.VOLUNTEER_AVAILABILITY_PAUSED_MESSAGE);
  });

  it("keeps the normal ready-count copy when actions are available", () => {
    const { activeCount, heroCount, root } = subscriberCountRoot();

    home.applyActiveSubscriberCount(root, 1, false);

    expect(activeCount.textContent).toBe("1 volunteer ready to fulfill requests");
    expect(heroCount.textContent).toBe("1 volunteer ready to fulfill requests");
  });
});

describe("public request-list web contract", () => {
  it("decodes requests from the canonical response wrapper", () => {
    const request = publicRequest();

    expect(home.requestsFromResponse({ requests: [request] })).toEqual([
      request,
    ]);
  });

  it("renders a card with the public id and public display fields only", () => {
    const request = {
      ...publicRequest(),
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      claimToken: "private-token",
    };

    const html = home.renderPublicRequestCard(request);

    expect(html).toContain('data-request-id="request-123"');
    expect(html).toContain("Vegetable rice bowl");
    expect(html).toContain("Campus Market");
    expect(html).toContain(home.WEB_ORDERING_UNAVAILABLE_MESSAGE);
    expect(html).toContain("disabled");
    expect(html).not.toContain("Order This");
    expect(html).not.toContain("/fulfill");
    expect(html).not.toContain("Requester Private Name");
    expect(html).not.toContain("requester@example.edu");
    expect(html).not.toContain("private-token");
  });

  it("renders public request detail without expecting or displaying private fields", () => {
    const request = {
      ...publicRequest(),
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      claimToken: "private-token",
    };

    const html = home.renderPublicRequestDetail(request);

    expect(html).toContain('class="modal-body"');
    expect(html).toContain("ASAP (available for the next 3 hours)");
    expect(html).toContain("Vegetable rice bowl");
    expect(html).toContain("Campus Market");
    expect(html).not.toContain("Requester Private Name");
    expect(html).not.toContain("requester@example.edu");
    expect(html).not.toContain("private-token");
    expect(html).not.toContain("Pickup Name");
  });

  it("does not render a homepage link or action to the legacy fulfillment route", () => {
    const cardHtml = home.renderPublicRequestCard(publicRequest());
    const modalHtml = home.renderPublicRequestModal(publicRequest());

    expect(modalHtml).toContain(home.WEB_ORDERING_UNAVAILABLE_MESSAGE);
    expect(modalHtml).toContain("disabled");
    expect(modalHtml).not.toContain("I'll Order This");
    expect(`${cardHtml}${modalHtml}`).not.toMatch(
      /href=|\/request\/.*\/fulfill/
    );
  });

  it("uses canonical timing display fields without consulting device time", () => {
    const dateNow = vi.spyOn(Date, "now").mockImplementation(() => {
      throw new Error("device time must not be consulted");
    });

    expect(home.publicRequestWindowText(publicRequest())).toBe(
      "ASAP (available for the next 3 hours)"
    );
    expect(
      home.publicRequestWindowText(
        publicRequest({
          pickupWindowText: "Jul 26, 4:00 PM – 5:00 PM",
          windowStart: "2026-07-26T20:00:00.000Z",
          windowEnd: "2026-07-26T21:00:00.000Z",
        })
      )
    ).toBe("Jul 26, 4:00 PM – 5:00 PM");

    expect(dateNow).not.toHaveBeenCalled();
  });
});

describe("homepage truthfulness copy", () => {
  const pageSource = readFileSync(
    new URL("../../public/home.html", import.meta.url),
    "utf8"
  );
  const readme = readFileSync(new URL("../../README.md", import.meta.url), "utf8");
  const normalizedReadme = readme.replace(/\s+/g, " ");

  it("describes confirmation and fulfillment email as attempts", () => {
    expect(pageSource).toContain(
      "CommonPlate attempts to send a confirmation email; delivery is not guaranteed"
    );
    expect(pageSource).toContain(
      "When someone helps, CommonPlate attempts to email the pickup details; delivery is not guaranteed"
    );
    expect(pageSource).toContain(
      "CommonPlate attempts to email the requester the order details"
    );
    expect(pageSource).not.toContain("Requester automatically receives");

    expect(normalizedReadme).toContain(
      "CommonPlate attempts requester confirmation and fulfillment emails; request creation and provider submission do not guarantee delivery"
    );
    expect(normalizedReadme).not.toContain(
      "requesters get confirmation and fulfillment emails"
    );
  });

  it("states the scoped data sharing and retention facts", () => {
    for (const expected of [
      "The helper’s email may be sent to the requester for coordination",
      "Placed Request data is retained for seven days",
      "Fulfillment records may be retained longer",
    ]) {
      expect(pageSource).toContain(expected);
    }
    expect(pageSource).not.toContain(
      "No personal data stored after requests are completed"
    );
    // W4-R4 removed pickup name from the request contract.
    expect(pageSource).not.toMatch(/pickup name/i);
  });
});
