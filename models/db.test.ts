import { describe, expect, it } from "vitest";
import mongoose from "mongoose";
import {
  INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION,
} from "../src/unsubscribeCredential.js";
import {
  INITIAL_PARTICIPANT_AUTHORITY_VERSION,
  MAXIMUM_PARTICIPANT_AUTHORITY_VERSION,
} from "../src/participantCredentials.js";
import {
  Fulfillment,
  Installation,
  Participant,
  ParticipantVerification,
  Request as MealRequest,
  RequestParticipation,
  Subscriber,
} from "./db.js";

describe("Installation participant association schema (W4-N1 seam)", () => {
  it("keeps canonical participant identity and its authority fence private", () => {
    for (const field of ["participantId", "participantAuthorityVersion"]) {
      const path = Installation.schema.path(field) as unknown as {
        options: { select: boolean };
      };
      expect(path, `${field} is not modelled`).toBeDefined();
      expect(path.options.select).toBe(false);
    }
    const participantPath = Installation.schema.path(
      "participantId"
    ) as unknown as { options: { ref: string } };
    expect(participantPath.options.ref).toBe("Participant");
  });

  it("indexes participant-scoped deletion without changing Installation uniqueness", () => {
    expect(Installation.schema.indexes()).toEqual(
      expect.arrayContaining([
        [
          { participantId: 1 },
          expect.objectContaining({ background: true }),
        ],
        [
          { installationCredentialDigest: 1 },
          expect.objectContaining({ unique: true }),
        ],
        [
          { apnsToken: 1, apnsEnvironment: 1 },
          expect.objectContaining({
            unique: true,
            name: "installation_push_eligible_token_unique",
          }),
        ],
      ])
    );
  });
});

describe("Subscriber pending-confirmation schema", () => {
  it("keeps confirmation digests, expiry, ownership, and legacy raw state private", () => {
    for (const field of [
      "confirmationTokenDigest",
      "confirmationExpiresAt",
      "confirmationSendAttemptId",
      "confirmationSendAttemptAt",
      "confirmToken",
    ]) {
      expect((Subscriber.schema.path(field) as any).options.select).toBe(false);
    }
  });

  it("requires the digest and expiry for new pending subscribers", () => {
    const missingLifecycle = new Subscriber({ email: "helper@example.edu" });
    const validPending = new Subscriber({
      email: "helper@example.edu",
      status: "pending",
      confirmationTokenDigest: "a".repeat(64),
      confirmationExpiresAt: new Date("2026-08-04T00:00:00.000Z"),
    });

    expect(missingLifecycle.validateSync()?.errors).toHaveProperty(
      "confirmationTokenDigest"
    );
    expect(missingLifecycle.validateSync()?.errors).toHaveProperty(
      "confirmationExpiresAt"
    );
    expect(validPending.validateSync()).toBeUndefined();
  });
});

describe("Subscriber unsubscribe credential version", () => {
  it("gives every new subscriber the initial version without being asked", () => {
    const created = new Subscriber({
      email: "helper@example.edu",
      status: "pending",
      confirmationTokenDigest: "a".repeat(64),
      confirmationExpiresAt: new Date("2026-08-04T00:00:00.000Z"),
    });

    expect(created.unsubscribeCredentialVersion).toBe(
      INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION
    );
    expect(INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION).toBe(1);
    expect(created.validateSync()).toBeUndefined();
  });

  it("keeps the version readable in ordinary projections", () => {
    // Alert and digest sends build the unsubscribe link from this field, so
    // unlike the confirmation digests it must not be `select: false`.
    const versionPath = Subscriber.schema.path(
      "unsubscribeCredentialVersion"
    ) as any;

    expect(versionPath.options.select).toBeUndefined();
  });

  it.each([
    ["zero", 0],
    ["a negative version", -1],
    ["a fractional version", 1.5],
    ["a version past the ceiling", MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION + 1],
  ])("rejects %s", (_label, version) => {
    const outOfRange = new Subscriber({
      email: "version@example.edu",
      status: "confirmed",
      unsubscribeCredentialVersion: version,
    });

    expect(outOfRange.validateSync()?.errors).toHaveProperty(
      "unsubscribeCredentialVersion"
    );
  });

  it("keeps the legacy raw unsubscribe token out of ordinary projections", () => {
    // Nothing reads it any more, so it should behave like every other private
    // credential field rather than riding along on ordinary Subscriber reads.
    expect(
      (Subscriber.schema.path("unsubToken") as any).options.select
    ).toBe(false);
  });

  it("no longer models a stored unsubscribe credential", () => {
    // The credential is signed on demand, so there is nothing to store and no
    // confirmed-row invariant that a stored digest could satisfy.
    expect(Subscriber.schema.path("unsubscribeTokenDigest")).toBeUndefined();
    expect(
      new Subscriber({
        email: "confirmed@example.edu",
        status: "confirmed",
      }).validateSync()
    ).toBeUndefined();
  });

  it.each(["pending", "confirmed", "unsubscribed"] as const)(
    "leaves a %s subscriber valid carrying only the derived credential",
    (status) => {
      const subscriber = new Subscriber({
        email: "lifecycle@example.edu",
        status,
        ...(status === "pending"
          ? {
              confirmationTokenDigest: "a".repeat(64),
              confirmationExpiresAt: new Date("2026-08-04T00:00:00.000Z"),
            }
          : {}),
      });

      expect(subscriber.validateSync()).toBeUndefined();
      expect(subscriber.unsubscribeCredentialVersion).toBe(
        INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION
      );
    }
  );
});

describe("Request lifecycle and retention schema", () => {
  it("uses only open, claimed, placed and (W4-R5) withdrawn with open as the default", () => {
    const statusPath = MealRequest.schema.path("status") as unknown as {
      options: { enum: string[]; default: string };
    };

    expect(statusPath.options.enum).toEqual([
      "open",
      "claimed",
      "placed",
      "withdrawn",
    ]);
    expect(statusPath.options.default).toBe("open");
    expect(new MealRequest().status).toBe("open");
  });

  it("keeps the W4-R5 revision, generation and withdrawal markers private and integral", () => {
    for (const field of ["contentRevision", "notificationGeneration", "withdrawnAt"]) {
      const path = MealRequest.schema.path(field) as unknown as {
        options: { select?: boolean };
      };
      expect(path.options.select, field).toBe(false);
    }
    const revision = new MealRequest({
      vendor: "v",
      food: "f",
      pickupWindowText: "p",
      email: "a@nyu.edu",
      contentRevision: 1.5,
      notificationGeneration: 0,
    });
    const error = revision.validateSync();
    expect(error?.errors.contentRevision).toBeDefined();
    expect(error?.errors.notificationGeneration).toBeDefined();
  });

  it("moves TTL responsibility from expiresAt to private deleteAt", () => {
    const indexes = MealRequest.schema.indexes();
    const ttlIndexes = indexes.filter(
      ([, options]) => options.expireAfterSeconds === 0
    );

    expect(ttlIndexes).toEqual([
      [
        { deleteAt: 1 },
        {
          expireAfterSeconds: 0,
          name: "request_deleteAt_ttl",
          background: true,
        },
      ],
    ]);
    expect(indexes).not.toEqual(
      expect.arrayContaining([
        [{ expiresAt: 1 }, expect.objectContaining({ expireAfterSeconds: 0 })],
      ])
    );
  });

  it("keeps the digest excluded from ordinary model projections", () => {
    const digestPath = MealRequest.schema.path(
      "claimTokenDigest"
    ) as unknown as {
      options: { select: boolean };
    };

    expect(digestPath.options.select).toBe(false);
  });

  it("models private placement and notification verification fields", () => {
    expect(MealRequest.schema.path("placedAt")).toBeDefined();
    expect(MealRequest.schema.path("fulfillerEmail")).toBeDefined();
    expect(
      MealRequest.schema.path("requesterPickupConfirmedAt")?.options.select
    ).toBe(false);
    // W4-U1.1: the helper Message is transient and never persisted, so there is
    // no stored Message field at all; only the content-free suppression marker
    // is durable, and it is private (`select: false`) like other lifecycle state.
    expect(MealRequest.schema.path("contactMessage")).toBeUndefined();
    expect(MealRequest.schema.path("contactMessageSuppressed")).toBeDefined();
    expect(
      (MealRequest.schema.path("contactMessageSuppressed") as any).options.select
    ).toBe(false);
    expect(MealRequest.schema.path("notificationAttemptedAt")).toBeDefined();
    expect(
      (MealRequest.schema.path("notificationStatus") as any).options.enum
    ).toEqual(["pending", "sent", "failed"]);
    expect(MealRequest.schema.path("helperPhone")).toBeUndefined();
  });

  it("models helper-notification ownership with no default state", () => {
    const path = MealRequest.schema.path("helperNotification") as unknown as {
      options: { enum: string[]; default?: unknown };
    };

    expect(path.options.enum).toEqual(["awaiting-eligibility", "initiated"]);
    // Absent is a third meaning — a row persisted before this field existed,
    // which the eligibility sweep must never select. A default would erase it
    // and hand every legacy row to the sweep.
    expect(path.options.default).toBeUndefined();
    expect(new MealRequest().helperNotification).toBeUndefined();
  });

  it("indexes only the requests still awaiting eligibility-time notification", () => {
    expect(MealRequest.schema.indexes()).toEqual(
      expect.arrayContaining([
        [
          { visibleFrom: 1 },
          expect.objectContaining({
            name: "request_helper_notification_awaiting",
            partialFilterExpression: {
              helperNotification: "awaiting-eligibility",
            },
          }),
        ],
      ])
    );
    // A selection index, not a uniqueness guarantee: exactly-once initiation
    // comes from the sweep's conditional update.
    const awaiting = MealRequest.schema
      .indexes()
      .find(
        ([, options]) =>
          options.name === "request_helper_notification_awaiting"
      );
    expect(awaiting?.[1].unique).toBeUndefined();
  });

  it("indexes requester placed-order reads without adding a lifecycle status", () => {
    expect(MealRequest.schema.indexes()).toEqual(
      expect.arrayContaining([
        [
          { requesterParticipantId: 1, status: 1, createdAt: -1 },
          expect.objectContaining({
            name: "request_requester_placed",
            partialFilterExpression: { status: "placed" },
          }),
        ],
      ])
    );
    expect(MealRequest.schema.path("status")?.options.enum).not.toContain(
      "picked_up"
    );
  });
});

describe("Fulfillment all-time ledger schema", () => {
  it("enforces one durable fulfillment per request", () => {
    expect(Fulfillment.schema.indexes()).toEqual(
      expect.arrayContaining([
        [
          { requestId: 1 },
          expect.objectContaining({
            unique: true,
            name: "fulfillment_request_unique",
          }),
        ],
      ])
    );
  });

  it("keeps only the request-scoped helper pseudonym and pickup terminal proof private", async () => {
    for (const field of [
      "helperParticipationKeyVersion",
      "helperParticipationHmac",
      "requesterPickupConfirmedAt",
    ]) {
      expect((Fulfillment.schema.path(field) as any).options.select).toBe(false);
    }
    const invalid = await new Fulfillment({
      requestId: new mongoose.Types.ObjectId(),
      orderNumber: "123",
      helperParticipationKeyVersion: 1,
    })
      .validate()
      .then(() => null, (error: { errors: Record<string, unknown> }) => error);
    expect(invalid?.errors).toHaveProperty("helperParticipationHmac");
  });
});

describe("RequestParticipation participant lookup", () => {
  it("indexes all request-scoped helper claims by their live Participant binding", () => {
    expect(RequestParticipation.schema.indexes()).toEqual(
      expect.arrayContaining([
        [
          { participantId: 1 },
          expect.objectContaining({
            name: "request_participation_participant_lookup",
          }),
        ],
      ])
    );
  });
});

describe("Request participant binding schema (W3-I1)", () => {
  it("keeps both participant bindings out of ordinary projections", () => {
    // Person identity, unlike `installationId`, which is notification routing.
    // Neither may reach a public projection, so both stay `select: false` like
    // every other private field.
    for (const field of ["requesterParticipantId", "helperParticipantId"]) {
      const path = MealRequest.schema.path(field) as unknown as {
        options: { select: boolean; ref: string };
      };
      expect(path, `${field} is not modelled`).toBeDefined();
      expect(path.options.select).toBe(false);
      expect(path.options.ref).toBe("Participant");
    }
  });

  it("gives a new request neither binding by default", () => {
    // Both are written explicitly from resolved authority; a schema default
    // would be a binding nobody proved.
    const request = new MealRequest();
    expect(request.requesterParticipantId).toBeUndefined();
    expect(request.helperParticipantId).toBeUndefined();
  });
});

describe("Participant schema (W3-I1)", () => {
  it("makes one address one participant", () => {
    const email = Participant.schema.path("email") as unknown as {
      options: { unique: boolean; lowercase: boolean; trim: boolean };
    };

    expect(email.options.unique).toBe(true);
    expect(email.options.lowercase).toBe(true);
    expect(email.options.trim).toBe(true);
  });

  it("starts every participant at the initial revocation version", () => {
    const participant = new Participant({
      email: "student@nyu.edu",
      verifiedAt: new Date(),
    });

    expect(participant.authorityVersion).toBe(
      INITIAL_PARTICIPANT_AUTHORITY_VERSION
    );
  });

  it("bounds the revocation counter to a small comparable integer", () => {
    const path = Participant.schema.path("authorityVersion") as unknown as {
      options: { min: number; max: number };
    };

    expect(path.options.min).toBe(INITIAL_PARTICIPANT_AUTHORITY_VERSION);
    expect(path.options.max).toBe(MAXIMUM_PARTICIPANT_AUTHORITY_VERSION);
  });

  it("stores no credential of any kind", () => {
    // The authority credential is signed on demand from `_id` and the version,
    // so there is nothing here for a database leak to replay.
    const fields = Object.keys(Participant.schema.paths);
    for (const forbidden of [
      "authority",
      "authorityDigest",
      "credential",
      "token",
      "codeDigest",
    ]) {
      expect(fields).not.toContain(forbidden);
    }
  });

  it("is not derived from Subscriber or Installation", () => {
    // A subscriber is an address that asked for alerts; an installation is a
    // copy of the app. Neither is a person, and neither may become one.
    const fields = Object.keys(Participant.schema.paths);
    for (const foreign of [
      "status",
      "bounced",
      "dailyCount",
      "pushEnabled",
      "apnsToken",
      "installationCredentialDigest",
    ]) {
      expect(fields).not.toContain(foreign);
    }
  });
});

describe("ParticipantVerification schema (W3-I1)", () => {
  it("allows only one live challenge per address", () => {
    // This is what makes a resend supersede the previous code rather than leave
    // two working codes in two inboxes.
    const email = ParticipantVerification.schema.path("email") as unknown as {
      options: { unique: boolean };
    };

    expect(email.options.unique).toBe(true);
  });

  it("keeps the code digest out of ordinary projections", () => {
    const path = ParticipantVerification.schema.path(
      "codeDigest"
    ) as unknown as { options: { select: boolean; required: boolean } };

    expect(path.options.select).toBe(false);
    expect(path.options.required).toBe(true);
  });

  it("models no raw code field at all", () => {
    const fields = Object.keys(ParticipantVerification.schema.paths);
    expect(fields).not.toContain("code");
    expect(fields).not.toContain("rawCode");
  });

  it("retires a spent or lapsed challenge with a TTL", () => {
    const path = ParticipantVerification.schema.path("deleteAt") as unknown as {
      options: {
        required: boolean;
        index: { expireAfterSeconds: number; name: string };
      };
    };

    expect(path.options.required).toBe(true);
    expect(path.options.index).toMatchObject({
      expireAfterSeconds: 0,
      name: "participant_verification_deleteAt_ttl",
    });
  });

  it("bounds attempts at zero rather than going negative", () => {
    const path = ParticipantVerification.schema.path(
      "attemptsRemaining"
    ) as unknown as { options: { required: boolean; min: number } };

    expect(path.options.required).toBe(true);
    expect(path.options.min).toBe(0);
  });
});
