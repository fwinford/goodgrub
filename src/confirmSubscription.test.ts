import { createHash } from "node:crypto";
import mongoose from "mongoose";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Subscriber } from "../models/db.js";
import { confirmSubscription } from "./confirmSubscription.js";
vi.mock("./requestAlertEmailDelivery.js", () => ({ isRequestAlertEmailDeliveryActive: () => true }));
import {
  SUBSCRIPTION_TOKEN_BYTES,
  digestSubscriptionToken,
  generateSubscriptionToken,
  isValidRawSubscriptionToken,
} from "./subscriptionTokens.js";

const backendNow = new Date("2026-08-03T18:30:00.000Z");

function rawToken(byte: number): string {
  return Buffer.alloc(SUBSCRIPTION_TOKEN_BYTES, byte).toString("base64url");
}

function queryResult(value: unknown) {
  const query = {
    select: vi.fn(),
    lean: vi.fn(),
    exec: vi.fn().mockResolvedValue(value),
  };
  query.select.mockReturnValue(query);
  query.lean.mockReturnValue(query);
  return query as any;
}

/** The `$set` and `$unset` stages of the conditional transition pipeline. */
function transitionStages(update: unknown) {
  const pipeline = update as Record<string, any>[];
  expect(Array.isArray(pipeline)).toBe(true);
  return {
    set: pipeline.find((stage) => stage.$set)?.$set as Record<string, unknown>,
    unset: pipeline.find((stage) => stage.$unset)?.$unset as string[],
  };
}

function confirmingModel(confirmedId: mongoose.Types.ObjectId) {
  const update = vi
    .spyOn(Subscriber, "findOneAndUpdate")
    .mockReturnValue(queryResult({ _id: confirmedId }));
  const find = vi.spyOn(Subscriber, "findOne");
  const exists = vi.spyOn(Subscriber, "exists");
  return { update, find, exists };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("subscription token shape and hashing", () => {
  it("issues cryptographically random-shaped 32-byte base64url tokens", () => {
    const tokens = Array.from({ length: 20 }, generateSubscriptionToken);

    expect(new Set(tokens)).toHaveLength(tokens.length);
    for (const token of tokens) {
      expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
      expect(Buffer.from(token, "base64url")).toHaveLength(
        SUBSCRIPTION_TOKEN_BYTES
      );
      expect(isValidRawSubscriptionToken(token)).toBe(true);
    }
  });

  it("hashes a raw token to its SHA-256 hex digest", () => {
    const token = rawToken(1);

    expect(digestSubscriptionToken(token)).toBe(
      createHash("sha256").update(token).digest("hex")
    );
    expect(digestSubscriptionToken(token)).toMatch(/^[a-f0-9]{64}$/);
    expect(digestSubscriptionToken(token)).not.toContain(token);
    expect(digestSubscriptionToken(token)).not.toBe(
      digestSubscriptionToken(rawToken(2))
    );
  });

  it.each([
    ["a non-string", 12345],
    ["null", null],
    ["an empty string", ""],
    ["a short token", "too-short"],
    ["a non-base64url alphabet", `${"a".repeat(42)}+`],
    ["an over-long token", `${"a".repeat(44)}`],
  ])("rejects %s", (_label, candidate) => {
    expect(isValidRawSubscriptionToken(candidate)).toBe(false);
  });
});

describe("confirmation token redemption", () => {
  it("transitions only an unexpired pending digest, with one conditional mutation", async () => {
    const id = new mongoose.Types.ObjectId();
    const { update, find, exists } = confirmingModel(id);
    const token = rawToken(3);

    const result = await confirmSubscription(token, backendNow);

    expect(result.outcome).toBe("confirmed");
    expect(result.subscriberId).toBe(String(id));
    expect(update).toHaveBeenCalledOnce();
    expect(find).not.toHaveBeenCalled();
    expect(exists).not.toHaveBeenCalled();
    const [filter] = update.mock.calls[0] as unknown as [Record<string, unknown>];
    expect(filter).toEqual({
      status: "pending",
      confirmationTokenDigest: digestSubscriptionToken(token),
      confirmationExpiresAt: { $gt: backendNow },
    });
  });

  it("clears the active confirmation, send ownership, lease, unsubscribe timestamp, and legacy raw credentials", async () => {
    const { update } = confirmingModel(new mongoose.Types.ObjectId());

    await confirmSubscription(rawToken(3), backendNow);

    const { set, unset } = transitionStages(
      (update.mock.calls[0] as unknown[])[1]
    );
    expect(set.status).toBe("confirmed");
    expect(unset).toEqual([
      "confirmationTokenDigest",
      "confirmationExpiresAt",
      "confirmationSendAttemptId",
      "confirmationSendAttemptAt",
      "unsubscribedAt",
      "confirmToken",
      "unsubToken",
    ]);
  });

  it("resets bounce and delivery counters", async () => {
    const { update } = confirmingModel(new mongoose.Types.ObjectId());

    await confirmSubscription(rawToken(3), backendNow);

    const { set } = transitionStages((update.mock.calls[0] as unknown[])[1]);
    expect(set.bounced).toEqual({ $literal: false });
    expect(set.dailyCount).toEqual({ $literal: 0 });
    expect(set.lastSentAt).toEqual({ $literal: null });
  });

  it("issues no unsubscribe credential and returns none to its caller", async () => {
    const { update } = confirmingModel(new mongoose.Types.ObjectId());

    const result = await confirmSubscription(rawToken(3), backendNow);

    // The unsubscribe link is signed on demand from `_id` and the credential
    // version, so there is no token to generate, return, persist, or leak.
    expect(result).toEqual({ outcome: "confirmed", subscriberId: expect.any(String) });
    const { set, unset } = transitionStages(
      (update.mock.calls[0] as unknown[])[1]
    );
    expect(set).not.toHaveProperty("unsubscribeTokenDigest");
    expect(JSON.stringify(update.mock.calls[0])).not.toContain(rawToken(3));
    // The revocation counter is the one thing a delivered unsubscribe link
    // depends on. Confirmation must neither set nor clear it.
    expect(set).not.toHaveProperty("unsubscribeCredentialVersion");
    expect(unset).not.toContain("unsubscribeCredentialVersion");
  });

  it("leaves a confirmed subscriber valid under the Subscriber schema", async () => {
    confirmingModel(new mongoose.Types.ObjectId());

    await confirmSubscription(rawToken(3), backendNow);

    // Nothing beyond `status` is required of a confirmed row now: every
    // subscriber holds a derived unsubscribe credential by construction.
    const confirmedByThisLifecycle = new Subscriber({
      email: "helper@example.edu",
      status: "confirmed",
    });

    expect(confirmedByThisLifecycle.validateSync()).toBeUndefined();
    expect(confirmedByThisLifecycle.unsubscribeCredentialVersion).toBe(1);
  });

  it("keeps a receipt of the used token carrying its original expiry", async () => {
    const { update } = confirmingModel(new mongoose.Types.ObjectId());

    await confirmSubscription(rawToken(3), backendNow);

    const { set } = transitionStages((update.mock.calls[0] as unknown[])[1]);
    // Copied from the document, not recomputed: the spent link stays
    // recognisable for exactly as long as it would have been valid.
    expect(set.lastConfirmedTokenDigest).toBe("$confirmationTokenDigest");
    expect(set.lastConfirmedTokenExpiresAt).toBe("$confirmationExpiresAt");
  });

  it("answers a malformed token without touching the database", async () => {
    const update = vi.spyOn(Subscriber, "findOneAndUpdate");
    const find = vi.spyOn(Subscriber, "findOne");
    const exists = vi.spyOn(Subscriber, "exists");

    const result = await confirmSubscription("not-a-token", backendNow);

    expect(result).toEqual({ outcome: "invalid" });
    expect(update).not.toHaveBeenCalled();
    expect(find).not.toHaveBeenCalled();
    expect(exists).not.toHaveBeenCalled();
  });

  it("reports an unknown well-formed token as invalid without mutating", async () => {
    const update = vi
      .spyOn(Subscriber, "findOneAndUpdate")
      .mockReturnValue(queryResult(null));
    vi.spyOn(Subscriber, "findOne").mockReturnValue(queryResult(null));
    vi.spyOn(Subscriber, "exists").mockResolvedValue(null as never);

    const result = await confirmSubscription(rawToken(8), backendNow);

    expect(result).toEqual({ outcome: "invalid" });
    // The conditional filter is the only guard that ran; nothing matched it.
    expect(update).toHaveBeenCalledOnce();
  });

  it("reports an expired pending token without mutating", async () => {
    const update = vi
      .spyOn(Subscriber, "findOneAndUpdate")
      .mockReturnValue(queryResult(null));
    vi.spyOn(Subscriber, "findOne").mockReturnValue(queryResult(null));
    const exists = vi
      .spyOn(Subscriber, "exists")
      .mockResolvedValue({ _id: new mongoose.Types.ObjectId() } as never);
    const token = rawToken(9);

    const result = await confirmSubscription(token, backendNow);

    expect(result).toEqual({ outcome: "expired" });
    expect(exists).toHaveBeenCalledWith({
      confirmationTokenDigest: digestSubscriptionToken(token),
      confirmationExpiresAt: { $lte: backendNow },
    });
  });

  it("returns alreadyConfirmed for a repeated token inside its original expiry", async () => {
    const id = new mongoose.Types.ObjectId();
    const update = vi
      .spyOn(Subscriber, "findOneAndUpdate")
      .mockReturnValue(queryResult(null));
    const find = vi
      .spyOn(Subscriber, "findOne")
      .mockReturnValue(queryResult({ _id: id }));
    const exists = vi.spyOn(Subscriber, "exists");
    const token = rawToken(11);

    const result = await confirmSubscription(token, backendNow);

    expect(result).toEqual({
      outcome: "alreadyConfirmed",
      subscriberId: String(id),
    });
    expect(find).toHaveBeenCalledWith({
      status: "confirmed",
      lastConfirmedTokenDigest: digestSubscriptionToken(token),
      lastConfirmedTokenExpiresAt: { $gt: backendNow },
    });
    expect(exists).not.toHaveBeenCalled();
    // No second lifecycle mutation: the repeated read is the only work, and
    // the conditional update matched nothing.
    expect(update).toHaveBeenCalledOnce();
  });
});
