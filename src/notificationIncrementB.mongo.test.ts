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
  dispatchHelperClosingSoonPush,
  HELPER_CLOSING_SOON_PURPOSE,
} from "./helperClosingSoonPush.js";
import {
  dispatchHelperPickupConfirmedPush,
  HELPER_PICKUP_CONFIRMED_PURPOSE,
} from "./helperPickupConfirmedPush.js";
import { runClosingSoonNotificationSweep } from "./closingSoonNotificationSweep.js";
import { helperPushInitiation } from "./helperNewRequestPush.js";
import { digestInstallationCredential } from "./installationCredential.js";

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;
let now: Date;
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
  apnsId: "n1b-mongo-accepted",
};

interface RecordedProvider {
  openConnection: (origin: string) => ApnsConnection;
  submissions: ApnsSubmission[];
}

function provider(): RecordedProvider {
  const submissions: ApnsSubmission[] = [];
  return {
    submissions,
    openConnection: () => ({
      async submit(submission) {
        submissions.push(submission);
        return accepted;
      },
      close() {},
    }),
  };
}

async function createParticipant(email: string) {
  return Participant.create({
    email,
    authorityVersion: 1,
    verifiedAt: now,
  });
}

async function createInstallation(
  participantId: mongoose.Types.ObjectId,
  tokenByte: number
) {
  const credential = Buffer.alloc(32, tokenByte).toString("base64url");
  const apnsToken = Buffer.alloc(32, tokenByte).toString("hex");
  return Installation.create({
    installationCredentialDigest: digestInstallationCredential(credential),
    pushEnabled: true,
    apnsToken,
    apnsEnvironment: "development",
    tokenUpdatedAt: now,
    participantId,
    participantAuthorityVersion: 1,
  });
}

async function createOpenRequest(
  requesterParticipantId: mongoose.Types.ObjectId,
  overrides: Record<string, unknown> = {}
): Promise<IRequest> {
  const expiresAt = new Date(now.getTime() + 15 * 60_000);
  return MealRequest.create({
    vendor: "Crave NYU",
    food: "Burrito bowl",
    pickupName: "Private requester name",
    email: "requester@nyu.edu",
    pickupWindowText: "ASAP",
    menuPath: "meal-exchange",
    mealSwipes: 1,
    status: "open",
    visibleFrom: new Date(now.getTime() - 60_000),
    expiresAt,
    deleteAt: expiresAt,
    requesterParticipantId,
    helperNotification: "initiated",
    closingSoonNotification: "awaiting",
    notificationGeneration: 1,
    contentRevision: 1,
    ...overrides,
  }) as unknown as IRequest;
}

function dispatchDependencies(openConnection: RecordedProvider["openConnection"]) {
  return {
    now: () => now,
    isPaused: () => false,
    readConfiguration: () => configuration,
    providerToken: () => "provider-jwt",
    openConnection,
  };
}

describeMongo("W4-N1 Increment B delivery against real MongoDB", () => {
  let requesterId: mongoose.Types.ObjectId;
  let helperId: mongoose.Types.ObjectId;
  let otherId: mongoose.Types.ObjectId;

  beforeAll(async () => {
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_n1_increment_b_push_test",
    });
    await Promise.all([
      Participant.init(),
      Installation.init(),
      ParticipantBlock.init(),
      PushDelivery.init(),
      MealRequest.init(),
    ]);
  }, 30_000);

  beforeEach(async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    now = new Date();
    requesterId = new mongoose.Types.ObjectId();
    helperId = new mongoose.Types.ObjectId();
    otherId = new mongoose.Types.ObjectId();
    await Participant.create([
      { _id: requesterId, email: "n1b-requester@nyu.edu", authorityVersion: 1, verifiedAt: now },
      { _id: helperId, email: "n1b-helper@nyu.edu", authorityVersion: 1, verifiedAt: now },
      { _id: otherId, email: "n1b-other@nyu.edu", authorityVersion: 1, verifiedAt: now },
    ]);
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await Promise.all([
      Installation.deleteMany({}),
      PushDelivery.deleteMany({}),
      MealRequest.deleteMany({}),
      ParticipantBlock.deleteMany({}),
      Participant.deleteMany({}),
    ]);
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("sends and durably consumes exactly one eligible T-15 closing-soon chance", async () => {
    await createInstallation(helperId, 61);
    const request = await createOpenRequest(requesterId);
    const apns = provider();
    const dispatchPush = async (candidate: IRequest) =>
      helperPushInitiation(
        await dispatchHelperClosingSoonPush(
          candidate,
          dispatchDependencies(apns.openConnection)
        )
      );
    const sweepDependencies = {
      now: () => now,
      isPaused: () => false,
      dispatchPush,
      maximumRequests: 50,
    };

    const first = await runClosingSoonNotificationSweep(sweepDependencies);
    const second = await runClosingSoonNotificationSweep(sweepDependencies);

    expect(first).toMatchObject({ candidates: 1, initiated: 1, deferred: 0 });
    expect(second).toMatchObject({ candidates: 0, initiated: 0 });
    expect(apns.submissions).toHaveLength(1);
    expect(JSON.parse(apns.submissions[0].payload).aps.alert).toEqual({
      title: "1 meal swipe",
      subtitle: "Closing in 15 min",
      body: "Crave NYU",
    });
    expect(
      JSON.stringify(JSON.parse(apns.submissions[0].payload))
    ).not.toContain("Private requester name");
    expect(await MealRequest.findById(request._id).select("+closingSoonNotification").then(
      (stored) => stored?.closingSoonNotification
    )).toBe("initiated");
    expect(await PushDelivery.countDocuments({
      requestId: request._id,
      purpose: HELPER_CLOSING_SOON_PURPOSE,
      status: "accepted",
    })).toBe(1);
  });

  it("cancels closing-soon delivery if the request is claimed after its ledger claim", async () => {
    await createInstallation(helperId, 62);
    const request = await createOpenRequest(requesterId);
    const apns = provider();
    vi.spyOn(PushDelivery, "create").mockImplementation(
      (async (document: Record<string, unknown>) => {
        const claim = await new PushDelivery(document).save();
        await MealRequest.updateOne(
          { _id: request._id },
          {
            $set: {
              status: "claimed",
              claimExpiresAt: new Date(now.getTime() + 60_000),
            },
          }
        );
        return claim;
      }) as never
    );

    const summary = await dispatchHelperClosingSoonPush(
      request,
      dispatchDependencies(apns.openConnection)
    );

    expect(summary.stop).toBe("unavailable");
    expect(apns.submissions).toHaveLength(0);
    expect(await PushDelivery.countDocuments({ requestId: request._id })).toBe(0);
  });

  it("targets only the recorded helper and uses per-installation purpose dedup for pickup confirmation", async () => {
    const helperInstallation = await createInstallation(helperId, 63);
    await createInstallation(requesterId, 64);
    const apns = provider();
    const target = {
      requestId: new mongoose.Types.ObjectId(),
      helperParticipantId: helperId,
      requesterParticipantId: requesterId,
    };

    const first = await dispatchHelperPickupConfirmedPush(target, {
      now: () => now,
      isPaused: () => false,
      readConfiguration: () => configuration,
      providerToken: () => "provider-jwt",
      openConnection: apns.openConnection,
    });
    const replay = await dispatchHelperPickupConfirmedPush(target, {
      now: () => now,
      isPaused: () => false,
      readConfiguration: () => configuration,
      providerToken: () => "provider-jwt",
      openConnection: apns.openConnection,
    });

    expect(first.accepted).toBe(1);
    expect(replay.duplicate).toBe(1);
    expect(apns.submissions).toHaveLength(1);
    expect(await PushDelivery.countDocuments({
      requestId: target.requestId,
      purpose: HELPER_PICKUP_CONFIRMED_PURPOSE,
    })).toBe(1);
    expect(apns.submissions[0].deviceToken).toBe(helperInstallation.apnsToken);
  });

  it.each(["suspended", "revoked", "blocked", "rebound"])(
    "rechecks shared helper authority and pair eligibility before pickup-confirmation handoff (%s)",
    async (change) => {
      const installation = await createInstallation(helperId, 65);
      const apns = provider();
      const target = {
        requestId: new mongoose.Types.ObjectId(),
        helperParticipantId: helperId,
        requesterParticipantId: requesterId,
      };
      vi.spyOn(PushDelivery, "create").mockImplementation(
        (async (document: Record<string, unknown>) => {
          const claim = await new PushDelivery(document).save();
          if (change === "suspended") {
            await Participant.updateOne({ _id: helperId }, { $set: { suspended: true } });
          } else if (change === "revoked") {
            await Participant.updateOne({ _id: helperId }, { $inc: { authorityVersion: 1 } });
          } else if (change === "blocked") {
            await ParticipantBlock.collection.insertOne({
              blockerParticipantId: requesterId,
              blockedParticipantId: helperId,
            });
          } else {
            await Installation.updateOne(
              { _id: installation._id },
              { $set: { participantId: otherId } }
            );
          }
          return claim;
        }) as never
      );

      const summary = await dispatchHelperPickupConfirmedPush(target, {
        now: () => now,
        isPaused: () => false,
        readConfiguration: () => configuration,
        providerToken: () => "provider-jwt",
        openConnection: apns.openConnection,
      });

      expect(summary.invalidated).toBe(1);
      expect(apns.submissions).toHaveLength(0);
      expect(await PushDelivery.countDocuments({ requestId: target.requestId })).toBe(0);
    }
  );
});
