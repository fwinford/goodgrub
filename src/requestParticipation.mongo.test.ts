import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import { RequestParticipation } from "../models/db.js";
import {
  filterRequestListForParticipant,
  findParticipatedRequestIds,
} from "./requestParticipation.js";
import {
  participationIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_request_participation`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

describeMongo("real MongoDB W3-H2 marketplace-presentation participation lookup", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await RequestParticipation.syncIndexes();
  });

  afterEach(async () => {
    await RequestParticipation.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("finds only this participant's own participated requests among the candidates", async () => {
    const participantId = new mongoose.Types.ObjectId();
    const otherParticipantId = new mongoose.Types.ObjectId();
    const participatedRequestId = new mongoose.Types.ObjectId();
    const otherParticipantRequestId = new mongoose.Types.ObjectId();
    const neverParticipatedRequestId = new mongoose.Types.ObjectId();

    await RequestParticipation.create([
      {
        requestId: participatedRequestId,
        participantId,
        ...participationIdentityFields(String(participatedRequestId), "p@nyu.edu"),
      },
      {
        requestId: otherParticipantRequestId,
        participantId: otherParticipantId,
        ...participationIdentityFields(
          String(otherParticipantRequestId),
          "q@nyu.edu"
        ),
      },
    ]);

    const result = await findParticipatedRequestIds(
      String(participantId),
      "p@nyu.edu",
      [participatedRequestId, otherParticipantRequestId, neverParticipatedRequestId]
    );

    expect(result).toEqual(new Set([String(participatedRequestId)]));
  });

  it("restricts the lookup to the supplied candidates rather than every participated request", async () => {
    const participantId = new mongoose.Types.ObjectId();
    const includedRequestId = new mongoose.Types.ObjectId();
    const excludedRequestId = new mongoose.Types.ObjectId();

    await RequestParticipation.create([
      { requestId: includedRequestId, participantId,
        ...participationIdentityFields(String(includedRequestId), "p@nyu.edu") },
      { requestId: excludedRequestId, participantId,
        ...participationIdentityFields(String(excludedRequestId), "p@nyu.edu") },
    ]);

    const result = await findParticipatedRequestIds(String(participantId), "p@nyu.edu", [
      includedRequestId,
    ]);

    expect(result).toEqual(new Set([String(includedRequestId)]));
  });

  it("excludes a request P has previously held from P's own list while leaving another eligible participant Q's list unaffected", async () => {
    const p = { participantId: String(new mongoose.Types.ObjectId()), principal: "p@nyu.edu", authorityVersion: 1 };
    const q = { participantId: String(new mongoose.Types.ObjectId()), principal: "q@nyu.edu", authorityVersion: 1 };
    const heldByP = new mongoose.Types.ObjectId();
    const neverHeld = new mongoose.Types.ObjectId();

    await RequestParticipation.create([
      { requestId: heldByP, participantId: new mongoose.Types.ObjectId(p.participantId),
        ...participationIdentityFields(String(heldByP), p.principal) },
    ]);

    const docs = [{ _id: heldByP }, { _id: neverHeld }];

    const pList = await filterRequestListForParticipant(docs, p);
    expect(pList).toEqual([{ _id: neverHeld }]);

    const qList = await filterRequestListForParticipant(docs, q);
    expect(qList).toBe(docs);

    const anonymousList = await filterRequestListForParticipant(docs, null);
    expect(anonymousList).toBe(docs);
  });
});
