import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import {
  Installation,
  Participant,
  ParticipantBlock,
  PushDelivery,
  Request as MealRequest,
  type IRequest,
} from "../models/db.js";
import type { ApnsConfiguration } from "./apnsConfig.js";
import type { ApnsConnection, ApnsOutcome, ApnsSubmission } from "./apnsClient.js";
import {
  REQUESTER_FULFILLMENT_PURPOSE,
  dispatchRequesterFulfillmentPush,
} from "./requesterFulfillmentPush.js";
import { digestInstallationCredential } from "./installationCredential.js";
import { resolveRequestInstallationAssociation } from "./requestInstallationAssociation.js";

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;
const requesterId = new mongoose.Types.ObjectId();

const configuration: ApnsConfiguration = {
  teamId: "ABCDE12345",
  keyId: "KEY1234567",
  bundleId: "org.commonplatenyu.CommonPlateios",
  authKeyPem: "unused: the provider token is injected",
};

const accepted: ApnsOutcome = {
  classification: "accepted",
  status: 200,
  reason: "Accepted",
  apnsId: "apns-accepted",
};
const unregistered: ApnsOutcome = {
  classification: "token-rejected",
  status: 410,
  reason: "Unregistered",
};

function credential(byte: number): string {
  return Buffer.alloc(32, byte).toString("base64url");
}

function apnsToken(byte: number): string {
  return Buffer.alloc(32, byte).toString("hex");
}

async function createPlacedRequest(
  overrides: Record<string, unknown> = {}
): Promise<IRequest> {
  const now = new Date();
  return MealRequest.create({
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    pickupWindowText: "ASAP (available for the next 3 hours)",
    status: "placed",
    requesterParticipantId: requesterId,
    placedAt: now,
    // Three hours, matching the W3-R1 ASAP lifetime this row's window text
    // states. `deleteAt` below is the separate placed-request retention.
    expiresAt: new Date(now.getTime() + 3 * 60 * 60 * 1000),
    deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
    ...overrides,
  });
}

async function createInstallation(
  byte: number,
  overrides: Record<string, unknown> = {}
) {
  await Participant.updateOne({ _id: requesterId }, { $setOnInsert: {
    email: "requester@nyu.edu", authorityVersion: 1, verifiedAt: new Date(),
  } }, { upsert: true });
  return Installation.create({
    installationCredentialDigest: digestInstallationCredential(credential(byte)),
    pushEnabled: true,
    apnsToken: apnsToken(byte),
    apnsEnvironment: "development",
    tokenUpdatedAt: new Date(),
    participantId: requesterId,
    participantAuthorityVersion: 1,
    ...overrides,
  });
}

interface RecordingConnections {
  openConnection: (origin: string) => ApnsConnection;
  submissions: ApnsSubmission[];
}

function connections(
  respond: (submission: ApnsSubmission) => ApnsOutcome | Promise<ApnsOutcome> = () =>
    accepted
): RecordingConnections {
  const submissions: ApnsSubmission[] = [];
  return {
    submissions,
    openConnection: () => ({
      async submit(submission) {
        submissions.push(submission);
        return respond(submission);
      },
      close() {},
    }),
  };
}

function dispatch(
  request: IRequest,
  overrides: Record<string, unknown> = {}
) {
  return dispatchRequesterFulfillmentPush(request, {
    isPaused: () => false,
    readConfiguration: () => configuration,
    providerToken: () => "provider-jwt",
    openConnection: () => ({
      async submit() {
        return accepted;
      },
      close() {},
    }),
    ...overrides,
  });
}

describeMongo("requester fulfillment push against real MongoDB", () => {
  beforeAll(async () => {
    // Its own database: Mongo test files run concurrently and several suites
    // clear their collections between cases, so a shared database would let
    // one suite delete another's fixtures mid-test.
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_requester_fulfillment_push_test",
    });
    await Installation.syncIndexes();
    await PushDelivery.syncIndexes();
    await MealRequest.syncIndexes();
  });

  beforeEach(() => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await Promise.all([
      Installation.deleteMany({}),
      PushDelivery.deleteMany({}),
      MealRequest.deleteMany({}),
      ParticipantBlock.deleteMany({}),
    ]);
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("excludes requester delivery across either direction of the placed helper pair fence", async () => {
    const installation = await createInstallation(73);
    const helper = new mongoose.Types.ObjectId();
    const request = await createPlacedRequest({
      installationId: installation._id, helperParticipantId: helper,
    });
    for (const [blockerParticipantId, blockedParticipantId] of [
      [requesterId, helper], [helper, requesterId],
    ]) {
      await ParticipantBlock.collection.insertOne({ blockerParticipantId, blockedParticipantId });
      const provider = connections();
      const result = await dispatch(request, { openConnection: provider.openConnection });
      expect(result.stop).toBe("no-eligible-installation");
      expect(provider.submissions).toHaveLength(0);
      await ParticipantBlock.deleteMany({});
    }
  });

  it("does not hand requester placement Push to B after a mid-dispatch A-to-B handoff", async () => {
    const installation = await createInstallation(72);
    const request = await createPlacedRequest({ installationId: installation._id });
    vi.spyOn(PushDelivery, "create").mockImplementationOnce((async (document: Record<string, unknown>) => {
      const claim = await new PushDelivery(document).save();
      await Installation.updateOne({ _id: installation._id }, {
        $set: { participantId: new mongoose.Types.ObjectId() },
      });
      return claim;
    }) as never);
    const provider = connections();
    const result = await dispatch(request, { openConnection: provider.openConnection });
    expect(provider.submissions).toHaveLength(0);
    expect(result.stop).toBe("no-eligible-installation");
    expect(await PushDelivery.countDocuments({})).toBe(0);
  });

  describe("request-to-installation association", () => {
    it("establishes a new, disabled installation identity from a credential no one has registered yet", async () => {
      const installationId = await resolveRequestInstallationAssociation(
        credential(1)
      );

      expect(installationId).toBeDefined();
      const stored = await Installation.findById(installationId)
        .select("+installationCredentialDigest")
        .lean();
      expect(stored?.pushEnabled).toBe(false);
      expect(stored?.installationCredentialDigest).toBe(
        digestInstallationCredential(credential(1))
      );
    });

    it("resolves to the same installation id on a repeated credential", async () => {
      const first = await resolveRequestInstallationAssociation(credential(2));
      const second = await resolveRequestInstallationAssociation(credential(2));

      expect(String(first)).toBe(String(second));
      expect(await Installation.countDocuments({})).toBe(1);
    });

    it("never enables push for an installation resolved this way", async () => {
      // A valid installation credential may establish/resolve identity even
      // while push is currently off — this path must never turn it on.
      await resolveRequestInstallationAssociation(credential(3));

      const stored = await Installation.findOne({}).lean();
      expect(stored?.pushEnabled).toBe(false);
      expect(stored?.apnsToken).toBeUndefined();
    });

    it("resolves to the existing installation and does not disturb its push state", async () => {
      const existing = await createInstallation(4);

      const resolved = await resolveRequestInstallationAssociation(credential(4));

      expect(String(resolved)).toBe(String(existing._id));
      const stored = await Installation.findById(existing._id)
        .select("+apnsToken")
        .lean();
      expect(stored?.pushEnabled).toBe(true);
      expect(stored?.apnsToken).toBe(apnsToken(4));
    });

    it("persists the association on the created request without exposing it publicly", async () => {
      const installationId = await resolveRequestInstallationAssociation(
        credential(5)
      );
      const request = await MealRequest.create({
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupName: "Requester Private Name",
        email: "requester@nyu.edu",
        pickupWindowText: "ASAP (available for the next 3 hours)",
        status: "open",
        expiresAt: new Date(Date.now() + 60 * 60 * 1000),
        deleteAt: new Date(Date.now() + 60 * 60 * 1000),
        installationId,
      });

      // Ordinary reads never select the private field.
      const ordinaryRead = await MealRequest.findById(request._id).lean();
      expect(ordinaryRead).not.toHaveProperty("installationId");

      const explicitRead = await MealRequest.findById(request._id)
        .select("+installationId")
        .lean();
      expect(String(explicitRead?.installationId)).toBe(String(installationId));
    });
  });

  describe("eligibility selection", () => {
    it("selects the request's own associated installation when it is push-eligible", async () => {
      const installation = await createInstallation(1);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });
      const provider = connections();

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.eligible).toBe(1);
      expect(provider.submissions).toHaveLength(1);
      expect(provider.submissions[0].deviceToken).toBe(apnsToken(1));
    });

    it.each([
      ["push disabled", { pushEnabled: false }],
      ["invalidated", { invalidatedAt: new Date() }],
    ])("skips quietly when the associated installation is %s", async (_name, overrides) => {
      const installation = await createInstallation(1, overrides);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });
      const provider = connections();

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.stop).toBe("no-eligible-installation");
      expect(provider.submissions).toHaveLength(0);
      expect(await PushDelivery.countDocuments({})).toBe(0);
    });

    it("skips with no fallback recipient for a web-created request with no association", async () => {
      const request = await createPlacedRequest();
      await createInstallation(1);
      const provider = connections();

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.stop).toBe("no-association");
      expect(provider.submissions).toHaveLength(0);
      expect(await PushDelivery.countDocuments({})).toBe(0);
    });
  });

  describe("deduplication", () => {
    it("rejects a second claim on the same identity triple", async () => {
      const installation = await createInstallation(1);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });
      await PushDelivery.create({
        requestId: request._id,
        installationId: installation._id,
        purpose: REQUESTER_FULFILLMENT_PURPOSE,
        status: "claimed",
        deleteAt: new Date(Date.now() + 60_000),
      });

      await expect(
        PushDelivery.create({
          requestId: request._id,
          installationId: installation._id,
          purpose: REQUESTER_FULFILLMENT_PURPOSE,
          status: "failed",
          deleteAt: new Date(Date.now() + 60_000),
        })
      ).rejects.toMatchObject({ code: 11000 });
    });

    it("shares the identity index with the helper new-request purpose without colliding", async () => {
      const installation = await createInstallation(1);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });

      await PushDelivery.create({
        requestId: request._id,
        installationId: installation._id,
        purpose: "helper-new-request",
        status: "accepted",
        deleteAt: new Date(Date.now() + 60_000),
      });

      const summary = await dispatch(request, {
        openConnection: connections().openConnection,
      });

      expect(summary.accepted).toBe(1);
      expect(await PushDelivery.countDocuments({})).toBe(2);
    });

    it("blocks a second intentional submission after a terminal failure", async () => {
      const installation = await createInstallation(1);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });
      const provider = connections(() => ({
        classification: "transient",
        status: 503,
        reason: "ServiceUnavailable",
      }));

      const first = await dispatch(request, { openConnection: provider.openConnection });
      const second = await dispatch(request, { openConnection: provider.openConnection });

      expect(first.failed).toBe(1);
      expect(second.duplicate).toBe(1);
      expect(provider.submissions).toHaveLength(1);
      expect(await PushDelivery.countDocuments({})).toBe(1);
    });

    it("stores no token, credential, or request content, and carries a TTL deleteAt", async () => {
      const installation = await createInstallation(1);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });

      await dispatch(request, { openConnection: connections().openConnection });

      const [row] = await PushDelivery.find({}).lean();
      expect(row.status).toBe("accepted");
      expect(row.apnsId).toBe("apns-accepted");
      expect(row.deleteAt).toBeInstanceOf(Date);
      const serialized = JSON.stringify(row);
      expect(serialized).not.toContain(apnsToken(1));
      expect(serialized).not.toContain(credential(1));
      expect(serialized).not.toContain("Campus Market");
      expect(serialized).not.toContain("requester@nyu.edu");
      expect(serialized).not.toContain("Requester Private Name");
    });
  });

  describe("exact-token invalidation", () => {
    it("retires only the exact rejected token", async () => {
      const installation = await createInstallation(1);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });
      const provider = connections(() => unregistered);

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.retired).toBe(1);
      const retired = await Installation.findById(installation._id).lean();
      expect(retired?.pushEnabled).toBe(false);
      expect(retired?.invalidatedAt).toBeInstanceOf(Date);
    });

    it("cannot retire a replacement token with a stale rejection", async () => {
      const installation = await createInstallation(1);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });
      const provider = connections(async () => {
        await Installation.updateOne(
          { _id: installation._id },
          { $set: { apnsToken: apnsToken(9), tokenUpdatedAt: new Date(), updatedAt: new Date() } }
        );
        return unregistered;
      });

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.rejected).toBe(1);
      expect(summary.retired).toBe(0);
      const stored = await Installation.findById(installation._id)
        .select("+apnsToken")
        .lean();
      expect(stored?.pushEnabled).toBe(true);
      expect(stored?.apnsToken).toBe(apnsToken(9));
    });
  });

  describe("isolation", () => {
    it("leaves the placed request untouched by every outcome", async () => {
      const installation = await createInstallation(1);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });
      const before = await MealRequest.findById(request._id).lean();

      await dispatch(request, { openConnection: connections(() => unregistered).openConnection });

      const after = await MealRequest.findById(request._id).lean();
      expect(after).toEqual(before);
    });

    it("writes no delivery record while public actions are paused", async () => {
      const installation = await createInstallation(1);
      const request = await createPlacedRequest({
        installationId: installation._id,
      });
      const provider = connections();

      const summary = await dispatch(request, {
        isPaused: () => true,
        openConnection: provider.openConnection,
      });

      expect(summary.stop).toBe("paused");
      expect(await PushDelivery.countDocuments({})).toBe(0);
      expect(provider.submissions).toHaveLength(0);
    });
  });
});
