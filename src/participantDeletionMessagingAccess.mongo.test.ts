import mongoose, { type ClientSession, Types } from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { Participant, ParticipantDeletionOperation } from "../models/db.js";
import { getParticipantDeletionMessagingAccess } from "./participantDeletionMessagingAccess.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_del_msg_access`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

async function withSession<T>(
  work: (session: ClientSession) => Promise<T>
): Promise<T> {
  const session = await mongoose.startSession();
  try {
    let value!: T;
    await session.withTransaction(async () => {
      value = await work(session);
    });
    return value;
  } finally {
    await session.endSession();
  }
}

async function makeParticipant(email: string): Promise<Types.ObjectId> {
  const participantId = new Types.ObjectId();
  await Participant.create({
    _id: participantId,
    email,
    verifiedAt: new Date(),
    authorityVersion: 1,
    accountFenceEpoch: 0,
  });
  return participantId;
}

let opSeq = 0;
async function makeOperation(
  participantId: Types.ObjectId,
  phase: string,
  extra: Record<string, unknown> = {}
) {
  opSeq += 1;
  return ParticipantDeletionOperation.create({
    operationId: `op-${opSeq}-${participantId.toHexString()}`,
    participantId,
    emailBinding: phase === "completed" ? undefined : `binding-${opSeq}`,
    authorityVersion: phase === "completed" ? undefined : 1,
    phase,
    readinessGeneration: phase === "completed" ? undefined : 0,
    ...extra,
  });
}

describeMongo(
  "MSG1 real DeletionAccessPort: getParticipantDeletionMessagingAccess (against accepted P2 CP8)",
  () => {
    beforeAll(async () => {
      await mongoose.connect(mongoUri!);
    });

    afterEach(async () => {
      await Promise.all([
        Participant.deleteMany({}),
        ParticipantDeletionOperation.deleteMany({}),
      ]);
    });

    afterAll(async () => {
      await mongoose.connection.dropDatabase();
      await mongoose.disconnect();
    });

    it("returns none for a live participant with no deletion operation at all", async () => {
      const id = await makeParticipant("none@nyu.edu");
      const access = await withSession((session) =>
        getParticipantDeletionMessagingAccess(id, session)
      );
      expect(access).toBe("none");
    });

    it.each(["waiting", "ready", "challengeIssued", "authorized"])(
      "returns pending for active phase %s (FD-MSG1-3: all four active phases allowed)",
      async (phase) => {
        const id = await makeParticipant(`${phase}@nyu.edu`);
        await makeOperation(id, phase);
        const access = await withSession((session) =>
          getParticipantDeletionMessagingAccess(id, session)
        );
        expect(access).toBe("pending");
      }
    );

    it("returns none when the only operation history is canceled", async () => {
      const id = await makeParticipant("canceled@nyu.edu");
      await makeOperation(id, "canceled", { canceledAt: new Date() });
      const access = await withSession((session) =>
        getParticipantDeletionMessagingAccess(id, session)
      );
      expect(access).toBe("none");
    });

    it("returns final for a missing participant (never existed / actually deleted)", async () => {
      const id = new Types.ObjectId();
      const access = await withSession((session) =>
        getParticipantDeletionMessagingAccess(id, session)
      );
      expect(access).toBe("final");
    });

    it("isolates a recreated account: a new participantId never inherits a prior, different participant's completed deletion history", async () => {
      const oldId = await makeParticipant("recreated@nyu.edu");
      await makeOperation(oldId, "completed", { completedAt: new Date() });
      await Participant.deleteOne({ _id: oldId });
      const newId = await makeParticipant("recreated@nyu.edu");
      const access = await withSession((session) =>
        getParticipantDeletionMessagingAccess(newId, session)
      );
      expect(access).toBe("none");
    });

    it("fails closed (throws) on an unrecognized persisted phase rather than silently treating it as none", async () => {
      const id = await makeParticipant("malformed@nyu.edu");
      await ParticipantDeletionOperation.collection.insertOne({
        operationId: `malformed-${id.toHexString()}`,
        participantId: id,
        phase: "notARealPhase",
      });
      await expect(
        withSession((session) =>
          getParticipantDeletionMessagingAccess(id, session)
        )
      ).rejects.toThrow();
    });

    it("fails closed (throws) on a persisted operation row with the phase key entirely absent", async () => {
      const id = await makeParticipant("no-phase-key@nyu.edu");
      await ParticipantDeletionOperation.collection.insertOne({
        operationId: `no-phase-${id.toHexString()}`,
        participantId: id,
      });
      await expect(
        withSession((session) =>
          getParticipantDeletionMessagingAccess(id, session)
        )
      ).rejects.toThrow();
    });

    it("returns none for a terminal completed-phase row sitting alongside a still-live Participant (no active row)", async () => {
      const id = await makeParticipant("completed-but-live@nyu.edu");
      await makeOperation(id, "completed", { completedAt: new Date() });
      const access = await withSession((session) =>
        getParticipantDeletionMessagingAccess(id, session)
      );
      expect(access).toBe("none");
    });

    it("the accepted one-active-operation-per-participant index refuses a second concurrent active operation for the same participant", async () => {
      const id = await makeParticipant("contradiction@nyu.edu");
      await makeOperation(id, "ready");
      await expect(
        ParticipantDeletionOperation.collection.insertOne({
          operationId: `second-active-${id.toHexString()}`,
          participantId: id,
          emailBinding: "binding-x",
          authorityVersion: 1,
          phase: "authorized",
          readinessGeneration: 0,
        })
      ).rejects.toThrow();
      // The adapter still reads a single, consistent pending state afterward.
      const access = await withSession((session) =>
        getParticipantDeletionMessagingAccess(id, session)
      );
      expect(access).toBe("pending");
    });

    it("reevaluates fresh on every call: pending while active, none after cancellation", async () => {
      const id = await makeParticipant("transition@nyu.edu");
      const op = await makeOperation(id, "waiting");
      expect(
        await withSession((session) =>
          getParticipantDeletionMessagingAccess(id, session)
        )
      ).toBe("pending");
      await ParticipantDeletionOperation.updateOne(
        { _id: op._id },
        { $set: { phase: "canceled", canceledAt: new Date() } }
      );
      expect(
        await withSession((session) =>
          getParticipantDeletionMessagingAccess(id, session)
        )
      ).toBe("none");
    });

    it("evaluates requester and helper independently", async () => {
      const requester = await makeParticipant("requester@nyu.edu");
      const helper = await makeParticipant("helper@nyu.edu");
      await makeOperation(requester, "challengeIssued");
      const [r, h] = await withSession((session) =>
        Promise.all([
          getParticipantDeletionMessagingAccess(requester, session),
          getParticipantDeletionMessagingAccess(helper, session),
        ])
      );
      expect(r).toBe("pending");
      expect(h).toBe("none");
    });

    it("reads inside the caller's own transaction/session: an aborted transaction does not persist any side effect, and the next call still reads fresh state", async () => {
      const id = await makeParticipant("rollback@nyu.edu");
      await makeOperation(id, "ready");
      const session = await mongoose.startSession();
      try {
        await expect(
          session.withTransaction(async () => {
            const access = await getParticipantDeletionMessagingAccess(
              id,
              session
            );
            expect(access).toBe("pending");
            throw new Error("force abort");
          })
        ).rejects.toThrow("force abort");
      } finally {
        await session.endSession();
      }
      expect(
        await withSession((session2) =>
          getParticipantDeletionMessagingAccess(id, session2)
        )
      ).toBe("pending");
    });
  }
);
