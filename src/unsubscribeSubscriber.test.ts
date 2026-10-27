import mongoose from "mongoose";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Subscriber } from "../models/db.js";
import {
  ACTIVE_CONFIRMATION_FIELDS,
  CONFIRMATION_RECEIPT_FIELDS,
  UNSUBSCRIBE_CLEARED_CONFIRMATION_FIELDS,
} from "./confirmSubscription.js";
import {
  INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES,
  UNSUBSCRIBE_SIGNING_SECRET_ENV,
  UnsubscribeCredentialConfigurationError,
  signUnsubscribeCredential,
  verifyUnsubscribeCredential,
} from "./unsubscribeCredential.js";
import {
  checkUnsubscribeCredential,
  unsubscribeSubscriber,
} from "./unsubscribeSubscriber.js";

/**
 * The redemption primitive in isolation: which links it accepts, what exactly
 * it writes, and what it refuses to touch. Real-Mongo behaviour — atomicity,
 * the rotation race, and the fields that survive — is proved in
 * `unsubscribeRoute.mongo.test.ts`.
 */
const SECRET = Buffer.alloc(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES, 1);
const OTHER_SECRET = Buffer.alloc(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES, 2);
const SUBSCRIBER_ID = "64b000000000000000000001";
const backendNow = new Date("2026-08-03T18:30:00.000Z");

function credential(
  version: number = INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  subscriberId: string = SUBSCRIBER_ID,
  secret: Buffer = SECRET
): string {
  return signUnsubscribeCredential(subscriberId, version, secret);
}

/**
 * A tampered copy of an authentic credential, guaranteed to differ from it.
 * Overwriting the final signature character with one fixed letter is a no-op
 * whenever the authentic signature already ends in that letter, which would
 * quietly turn a tampering case into a valid-credential case. Both letters
 * below are canonical trailing base64url characters, so the result stays well
 * formed and fails the signature comparison rather than the parser.
 * `unsubscribeCredential.test.ts` owns this helper's own regression coverage.
 */
function tamperCredentialSignature(value: string): string {
  const last = value.slice(-1);
  return `${value.slice(0, -1)}${last === "A" ? "E" : "A"}`;
}

function queryResult(value: unknown) {
  const query = {
    select: vi.fn(),
    lean: vi.fn(),
    exec: vi.fn().mockResolvedValue(value),
  };
  query.select.mockReturnValue(query);
  query.lean.mockReturnValue(query);
  return query as never;
}

/**
 * A stored row as the database physically holds it. `storedVersion` is passed
 * through untouched, so a case can describe a legacy document that has no
 * `unsubscribeCredentialVersion` field at all.
 */
function subscriberRow(storedVersion?: unknown) {
  const row: Record<string, unknown> = { _id: SUBSCRIBER_ID };
  if (arguments.length > 0) row.unsubscribeCredentialVersion = storedVersion;
  return row;
}

function mockLookup(row: unknown) {
  return vi.spyOn(Subscriber, "findById").mockReturnValue(queryResult(row));
}

function mockUpdate(matchedCount = 1) {
  return vi
    .spyOn(Subscriber, "updateOne")
    .mockReturnValue(queryResult({ acknowledged: true, matchedCount }));
}

function updateArguments(update: ReturnType<typeof mockUpdate>) {
  const call = update.mock.calls[0] as unknown[];
  const stages = call[1] as Array<Record<string, unknown>>;
  return {
    filter: call[0] as Record<string, unknown>,
    stages,
    set: (stages.find((stage) => "$set" in stage)?.$set ?? {}) as Record<
      string,
      unknown
    >,
    unset: stages.find((stage) => "$unset" in stage)?.$unset as string[],
  };
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("credential authenticity", () => {
  const unusable: Array<[string, unknown]> = [
    ["a missing credential", undefined],
    ["a non-string credential", 42],
    ["an array of credentials", [credential()]],
    ["an empty string", ""],
    ["a malformed credential", "not-a-credential"],
    ["a credential with too few segments", `${SUBSCRIBER_ID}.1`],
    [
      "a non-hexadecimal subscriber id",
      credential().replace(SUBSCRIBER_ID, "z".repeat(24)),
    ],
    ["a tampered signature", tamperCredentialSignature(credential())],
    ["a credential signed with another secret", credential(1, SUBSCRIBER_ID, OTHER_SECRET)],
  ];

  it.each(unusable)("refuses %s without reading a Subscriber", async (_label, value) => {
    const lookup = mockLookup(subscriberRow(1));
    const update = mockUpdate();

    expect(await unsubscribeSubscriber(value, backendNow, SECRET)).toEqual({
      outcome: "invalid",
    });
    expect(await checkUnsubscribeCredential(value, SECRET)).toEqual({
      outcome: "invalid",
    });
    expect(lookup).not.toHaveBeenCalled();
    expect(update).not.toHaveBeenCalled();
  });

  it("tampers its fixture into a credential that genuinely differs and genuinely fails", () => {
    const authentic = credential();
    const tampered = tamperCredentialSignature(authentic);

    expect(tampered).not.toBe(authentic);
    expect(verifyUnsubscribeCredential(authentic, SECRET)).not.toBeNull();
    expect(verifyUnsubscribeCredential(tampered, SECRET)).toBeNull();
  });

  it("refuses a credential for a subscriber that no longer exists", async () => {
    mockLookup(null);
    const update = mockUpdate();

    expect(
      await unsubscribeSubscriber(credential(), backendNow, SECRET)
    ).toEqual({ outcome: "invalid" });
    expect(await checkUnsubscribeCredential(credential(), SECRET)).toEqual({
      outcome: "invalid",
    });
    expect(update).not.toHaveBeenCalled();
  });

  it("reads only identity and the revocation counter", async () => {
    const lookup = mockLookup(subscriberRow(1));
    mockUpdate();

    await unsubscribeSubscriber(credential(), backendNow, SECRET);

    expect(lookup).toHaveBeenCalledWith(SUBSCRIBER_ID);
    const query = lookup.mock.results[0].value as {
      select: ReturnType<typeof vi.fn>;
    };
    expect(query.select).toHaveBeenCalledWith("unsubscribeCredentialVersion");
  });

  it("reads the configured secret when none is supplied", async () => {
    vi.stubEnv(
      UNSUBSCRIBE_SIGNING_SECRET_ENV,
      "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES)
    );
    const configured = Buffer.from(
      "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES),
      "utf8"
    );
    mockLookup(subscriberRow(1));
    mockUpdate();

    expect(
      await unsubscribeSubscriber(
        signUnsubscribeCredential(SUBSCRIBER_ID, 1, configured),
        backendNow
      )
    ).toEqual({ outcome: "unsubscribed" });
    // A credential signed with a different secret is not authentic under the
    // configured one, so the default is genuinely the configured value.
    expect(await checkUnsubscribeCredential(credential())).toEqual({
      outcome: "invalid",
    });
  });

  it("surfaces a missing signing secret as a configuration error, not an invalid link", async () => {
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, undefined);
    const lookup = mockLookup(subscriberRow(1));

    await expect(
      unsubscribeSubscriber(credential(), backendNow)
    ).rejects.toBeInstanceOf(UnsubscribeCredentialConfigurationError);
    await expect(
      checkUnsubscribeCredential(credential())
    ).rejects.toBeInstanceOf(UnsubscribeCredentialConfigurationError);
    expect(lookup).not.toHaveBeenCalled();
  });
});

describe("stored credential version comparison", () => {
  it("treats a legacy row with no stored version as version 1", async () => {
    mockLookup(subscriberRow());
    const update = mockUpdate();

    expect(
      await unsubscribeSubscriber(credential(1), backendNow, SECRET)
    ).toEqual({ outcome: "unsubscribed" });
    expect(await checkUnsubscribeCredential(credential(1), SECRET)).toEqual({
      outcome: "match",
    });
    // The condition must describe the absence itself: an equality match on 1
    // would also accept a row that had meanwhile been written with a version.
    expect(updateArguments(update).filter).toEqual({
      _id: SUBSCRIBER_ID,
      unsubscribeCredentialVersion: { $exists: false },
    });
  });

  it("rejects a version-1 credential once the stored version is 2", async () => {
    mockLookup(subscriberRow(2));
    const update = mockUpdate();

    expect(
      await unsubscribeSubscriber(credential(1), backendNow, SECRET)
    ).toEqual({ outcome: "invalid" });
    expect(await checkUnsubscribeCredential(credential(1), SECRET)).toEqual({
      outcome: "invalid",
    });
    expect(update).not.toHaveBeenCalled();
  });

  it("accepts a version-2 credential against stored version 2", async () => {
    mockLookup(subscriberRow(2));
    const update = mockUpdate();

    expect(
      await unsubscribeSubscriber(credential(2), backendNow, SECRET)
    ).toEqual({ outcome: "unsubscribed" });
    expect(await checkUnsubscribeCredential(credential(2), SECRET)).toEqual({
      outcome: "match",
    });
    expect(updateArguments(update).filter).toEqual({
      _id: SUBSCRIBER_ID,
      unsubscribeCredentialVersion: 2,
    });
  });

  it("refuses a persisted null instead of treating it as a legacy absent field", async () => {
    // The two are different persisted states. Only a physically absent field is
    // a pre-field row that has never been revoked; a stored `null` is malformed
    // state, and accepting a version-1 credential against it would redeem a
    // link whose real revocation state nothing recorded.
    mockLookup(subscriberRow(null));
    const update = mockUpdate();

    expect(
      await unsubscribeSubscriber(credential(1), backendNow, SECRET)
    ).toEqual({ outcome: "invalid" });
    expect(await checkUnsubscribeCredential(credential(1), SECRET)).toEqual({
      outcome: "invalid",
    });
    expect(update).not.toHaveBeenCalled();
  });

  it("never writes a null version condition, which would also match an absent field", async () => {
    // `{unsubscribeCredentialVersion: null}` matches a physical null *and* a
    // document with no field at all, so it could never state either condition
    // exactly. No stored state may produce it.
    const cases: Array<[Record<string, unknown>, number]> = [
      [subscriberRow(), 1],
      [subscriberRow(1), 1],
      [subscriberRow(2), 2],
      [subscriberRow(null), 1],
    ];

    for (const [row, version] of cases) {
      mockLookup(row);
      const update = mockUpdate();

      await unsubscribeSubscriber(credential(version), backendNow, SECRET);

      for (const call of update.mock.calls) {
        const filter = call[0] as Record<string, unknown>;
        expect(filter.unsubscribeCredentialVersion).not.toBeNull();
      }
      vi.restoreAllMocks();
    }
  });

  it.each([0, -1, 1.5, "1", Number.NaN, 1_000_001])(
    "refuses a persisted version of %p without mutating",
    async (storedVersion) => {
      mockLookup(subscriberRow(storedVersion));
      const update = mockUpdate();

      expect(
        await unsubscribeSubscriber(credential(1), backendNow, SECRET)
      ).toEqual({ outcome: "invalid" });
      expect(await checkUnsubscribeCredential(credential(1), SECRET)).toEqual({
        outcome: "invalid",
      });
      expect(update).not.toHaveBeenCalled();
    }
  );

  it("reports a conditional-update miss as the same generic invalid result", async () => {
    // The row matched the version that was validated, then the version moved
    // (or the row went away) before the update ran. Nothing distinguishes the
    // two for the caller.
    mockLookup(subscriberRow(1));
    mockUpdate(0);

    expect(
      await unsubscribeSubscriber(credential(1), backendNow, SECRET)
    ).toEqual({ outcome: "invalid" });
  });
});

describe("the unsubscribe mutation", () => {
  it("is one conditional atomic update", async () => {
    mockLookup(subscriberRow(1));
    const update = mockUpdate();
    const save = vi.spyOn(mongoose.Model.prototype, "save");

    await unsubscribeSubscriber(credential(1), backendNow, SECRET);

    expect(update).toHaveBeenCalledOnce();
    expect(save).not.toHaveBeenCalled();
  });

  it("sets the unsubscribed status and preserves an existing unsubscribe timestamp", async () => {
    mockLookup(subscriberRow(1));
    const update = mockUpdate();

    await unsubscribeSubscriber(credential(1), backendNow, SECRET);

    const { set } = updateArguments(update);
    expect(set.status).toBe("unsubscribed");
    // `$ifNull` keeps the first unsubscribe of the current lifecycle, so a
    // repeated press moves nothing. Confirmation clears the field, so a
    // reconfirmed address that unsubscribes again records the new time.
    expect(set.unsubscribedAt).toEqual({
      $ifNull: ["$unsubscribedAt", backendNow],
    });
  });

  it("clears every confirmation credential the row can hold, active or spent", async () => {
    mockLookup(subscriberRow(1));
    const update = mockUpdate();

    await unsubscribeSubscriber(credential(1), backendNow, SECRET);

    const { unset } = updateArguments(update);
    // Reused from the confirmation definitions rather than restated, and with
    // the unsubscribe timestamp left out because this path writes it.
    expect(unset).toEqual([...UNSUBSCRIBE_CLEARED_CONFIRMATION_FIELDS]);
    for (const field of ACTIVE_CONFIRMATION_FIELDS) {
      expect(unset).toContain(field);
    }
    expect(unset).toContain("confirmationTokenDigest");
    expect(unset).toContain("confirmationExpiresAt");
    expect(unset).toContain("confirmationSendAttemptId");
    expect(unset).toContain("confirmationSendAttemptAt");
    expect(unset).toContain("confirmToken");
    expect(unset).toContain("unsubToken");
    // The bounded receipt goes with them: a spent token that can still be
    // answered *already confirmed* is a credential this row no longer has.
    expect(unset).toContain("lastConfirmedTokenDigest");
    expect(unset).toContain("lastConfirmedTokenExpiresAt");
    expect(CONFIRMATION_RECEIPT_FIELDS.every((field) => unset.includes(field))).toBe(
      true
    );
    expect(unset).not.toContain("unsubscribedAt");
  });

  it("never rotates the credential version, resets counters, or deletes the row", async () => {
    mockLookup(subscriberRow(1));
    const update = mockUpdate();
    const deleteOne = vi.spyOn(Subscriber, "deleteOne");
    const deleteMany = vi.spyOn(Subscriber, "deleteMany");

    await unsubscribeSubscriber(credential(1), backendNow, SECRET);

    const { stages, set, unset } = updateArguments(update);
    const written = JSON.stringify(stages);
    for (const preserved of [
      "unsubscribeCredentialVersion",
      "dailyCount",
      "lastSentAt",
      "bounced",
      "email",
    ]) {
      expect(set).not.toHaveProperty(preserved);
      expect(unset).not.toContain(preserved);
    }
    // The version appears in the filter, never in what is written.
    expect(written).not.toContain("unsubscribeCredentialVersion");
    expect(written).not.toContain("$inc");
    expect(deleteOne).not.toHaveBeenCalled();
    expect(deleteMany).not.toHaveBeenCalled();
  });

  it("sends no email", async () => {
    // The primitive imports no mail path at all; this pins that it stays that
    // way, because an unsubscribe confirmation email is itself an alert.
    const source = await import("node:fs").then(({ readFileSync }) =>
      readFileSync(new URL("./unsubscribeSubscriber.ts", import.meta.url), "utf8")
    );

    expect(source).not.toContain("emailHelpers");
    expect(source).not.toContain("resend");
    expect(source).not.toContain("sendDigestEmail");
  });
});

describe("the safe check", () => {
  it("performs no mutation on any path, including repeated checks", async () => {
    mockLookup(subscriberRow(1));
    const update = mockUpdate();
    const updateMany = vi.spyOn(Subscriber, "updateMany");
    const findOneAndUpdate = vi.spyOn(Subscriber, "findOneAndUpdate");

    for (let attempt = 0; attempt < 3; attempt++) {
      expect(await checkUnsubscribeCredential(credential(1), SECRET)).toEqual({
        outcome: "match",
      });
    }

    expect(update).not.toHaveBeenCalled();
    expect(updateMany).not.toHaveBeenCalled();
    expect(findOneAndUpdate).not.toHaveBeenCalled();
  });

  it("answers the same way whatever status the row holds", async () => {
    for (const status of ["pending", "confirmed", "unsubscribed"]) {
      mockLookup({ ...subscriberRow(1), status });

      expect(await checkUnsubscribeCredential(credential(1), SECRET)).toEqual({
        outcome: "match",
      });
      vi.restoreAllMocks();
    }
  });
});
