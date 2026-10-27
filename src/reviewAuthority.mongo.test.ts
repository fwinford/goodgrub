import mongoose, { type Connection } from "mongoose";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { REVIEW_DATABASE, type ReviewAccount, type ReviewSession } from "../models/reviewDb.js";
import { ReviewAuthority, REVIEW_SESSION_LIFETIME_MS } from "./reviewAuthority.js";
import { digestReviewSession } from "./reviewCredentials.js";

const uri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = uri ? describe : describe.skip;
const password = "fictional-test-password-not-live-".repeat(2);
const helperPassword = "fictional-helper-password-not-live-".repeat(2);
const replacement = "fictional-replacement-not-live-".repeat(2);
let connection: Connection;
let authority: ReviewAuthority;

describeMongo("isolated reviewer authority on a real replica set", () => {
  beforeAll(async () => {
    vi.stubEnv("NODE_ENV", "review");
    connection = await mongoose.createConnection(uri!, { dbName: REVIEW_DATABASE }).asPromise();
    authority = new ReviewAuthority(connection);
    await authority.initialize();
  });
  beforeEach(async () => {
    for (const name of [
      "review_accounts", "review_sessions", "review_login_limits",
      "requests", "requestoperations", "requestupdateoperations", "requestparticipations",
    ]) await connection.collection(name).deleteMany({});
    await authority.initialize();
    await authority.setCredential("requester", password);
    await authority.setCredential("helper", helperPassword);
  });
  afterAll(async () => {
    if (connection) await connection.close();
    vi.unstubAllEnvs();
  });

  async function login(role: "requester" | "helper" = "requester") {
    const result = await authority.login(role, role === "helper" ? helperPassword : password);
    if (result.outcome !== "authenticated") throw new Error("Fixture login failed");
    return result;
  }

  it("binds role, synthetic actor and generation without student records", async () => {
    const start = Date.now();
    const requester = await login();
    const helper = await login("helper");
    expect(requester.actor.role).toBe("requester");
    expect(helper.actor.role).toBe("helper");
    expect(helper.actor.actorId).not.toBe(requester.actor.actorId);
    expect(requester.actor.principal).toBe("requester@review.invalid");
    expect(requester.expiresAt.getTime()).toBeGreaterThanOrEqual(start + REVIEW_SESSION_LIFETIME_MS);
    expect(await authority.authenticate(requester.token)).toEqual(requester.actor);
    const collections = (await connection.db!.listCollections().toArray()).map((item) => item.name);
    expect(collections).not.toContain("participants");
  });

  it("persists neither raw credentials nor session tokens", async () => {
    const result = await login();
    const account = await connection.collection<ReviewAccount>("review_accounts").findOne({ _id: "requester" });
    const session = await connection.collection<ReviewSession>("review_sessions").findOne({});
    expect(JSON.stringify(account)).not.toContain(password);
    expect(account?.passwordHash).toMatch(/^scrypt:/);
    expect(JSON.stringify(session)).not.toContain(result.token);
    expect(session?._id).toBe(digestReviewSession(result.token));
    const ordinary = await connection.model("ReviewAccount").findById("requester").lean().exec();
    expect(ordinary).not.toHaveProperty("passwordHash");
  });

  it("rejects student credentials, invalid passwords and role escalation", async () => {
    for (const [role, candidate] of [
      ["student@nyu.edu", password], ["admin", password],
      ["requester", replacement], ["requester", "123456"],
    ]) expect(await authority.login(role, candidate)).toEqual({ outcome: "invalid" });
    expect(await authority.authenticate("student-signed-authority")).toBeNull();
  });

  it("makes rotation and revocation immediately reject old sessions", async () => {
    const initial = await login();
    await authority.setCredential("requester", replacement);
    expect(await authority.authenticate(initial.token)).toBeNull();
    expect(await authority.login("requester", password)).toEqual({ outcome: "invalid" });
    const rotated = await authority.login("requester", replacement);
    if (rotated.outcome !== "authenticated") throw new Error("Rotation login failed");
    expect(rotated.actor.actorId).toBe(initial.actor.actorId);
    await authority.revoke("requester");
    expect(await authority.authenticate(rotated.token)).toBeNull();
    expect(await authority.login("requester", replacement)).toEqual({ outcome: "invalid" });
    expect((await authority.login("helper", helperPassword)).outcome).toBe("authenticated");
  });

  it("rejects expired sessions even before TTL deletion", async () => {
    const result = await login();
    await connection.collection<ReviewSession>("review_sessions").updateOne(
      { _id: digestReviewSession(result.token) }, { $set: { expiresAt: new Date(0) } }
    );
    expect(await authority.authenticate(result.token)).toBeNull();
  });

  it("invalidates exactly the signed-out session", async () => {
    const first = await login();
    const second = await login();
    await authority.logout(first.token);
    expect(await authority.authenticate(first.token)).toBeNull();
    expect(await authority.authenticate(second.token)).not.toBeNull();
  });

  it("bounds concurrent account guesses persistently across service restarts", async () => {
    const attempts = await Promise.all(Array.from({ length: 12 }, () =>
      authority.login("requester", replacement)));
    expect(attempts.filter((item) => item.outcome === "invalid")).toHaveLength(10);
    expect(attempts.filter((item) => item.outcome === "limited")).toHaveLength(2);
    const restarted = new ReviewAuthority(connection);
    await restarted.initialize();
    expect(await restarted.login("requester", password)).toEqual({ outcome: "limited" });
  });

  it("never shares credentials between requester/helper roles", async () => {
    await expect(authority.setCredential("helper", password)).rejects.toThrow("distinct credentials");
    expect(await authority.login("helper", password)).toEqual({ outcome: "invalid" });
    expect(await authority.login("requester", helperPassword)).toEqual({ outcome: "invalid" });
    expect((await login("helper")).actor.role).toBe("helper");
  });

  it("keeps expiry and generation authoritative after service restart", async () => {
    const old = await login();
    const restarted = new ReviewAuthority(connection);
    expect(restarted.isReady()).toBe(false);
    await restarted.initialize();
    expect(await restarted.authenticate(old.token)).toEqual(old.actor);
    await restarted.revoke("requester");
    expect(await authority.authenticate(old.token)).toBeNull();
  });

  it("retains accounts/replay evidence while atomically advancing generation", async () => {
    const old = await login();
    const oldHelper = await login("helper");
    const ledgers = ["requestoperations", "requestupdateoperations", "requestparticipations"];
    for (const name of [...ledgers, "requests"]) {
      await connection.collection(name).insertOne({ fixture: "preserved-operation" });
    }
    await authority.reset({ reset: async (session) => {
      await connection.collection("requests").deleteMany({}, { session });
    } });
    expect(await authority.authenticate(old.token)).toBeNull();
    expect(await authority.authenticate(oldHelper.token)).toBeNull();
    const fresh = await login();
    expect(fresh.actor.generation).not.toBe(old.actor.generation);
    expect(fresh.actor.actorId).toBe(old.actor.actorId);
    expect(await connection.collection("requests").countDocuments()).toBe(0);
    for (const name of ledgers) expect(await connection.collection(name).countDocuments()).toBe(1);
  });

  it("rolls back generation/session/lifecycle changes when reset fails", async () => {
    const old = await login();
    await connection.collection("requests").insertOne({ fixture: "still-present" });
    await expect(authority.reset({ reset: async (session) => {
      await connection.collection("requests").deleteMany({}, { session });
      throw new Error("fictional reset failure");
    } })).rejects.toThrow("fictional reset failure");
    expect(await authority.authenticate(old.token)).toEqual(old.actor);
    expect(await connection.collection("requests").countDocuments()).toBe(1);
  });

  it("does not restore pre-reset authority or operation identity on replay", async () => {
    const old = await login();
    const oldRow = await connection.collection<ReviewSession>("review_sessions").findOne({
      _id: digestReviewSession(old.token),
    });
    await authority.reset({ reset: async () => {} });
    if (!oldRow) throw new Error("Missing fixture session");
    await connection.collection<ReviewSession>("review_sessions").insertOne(oldRow);
    expect(await authority.authenticate(old.token)).toBeNull();
  });

  it("serializes reset with concurrent logins", async () => {
    const old = await login();
    const results = await Promise.all([
      authority.reset({ reset: async () => {} }), authority.login("requester", password),
    ]);
    expect(await authority.authenticate(old.token)).toBeNull();
    const result = results[1];
    if (result.outcome !== "authenticated") throw new Error("Concurrent fixture login failed");
    const actor = await authority.authenticate(result.token);
    if (actor) expect(actor.generation).not.toBe(old.actor.generation);
  });

  it("refuses a different database and production runtime before any models exist", async () => {
    const other = await mongoose.createConnection(uri!, { dbName: "commonplate_rev1_forbidden" }).asPromise();
    try {
      expect(() => new ReviewAuthority(other)).toThrow("isolated review");
      expect(other.modelNames()).toEqual([]);
      vi.stubEnv("NODE_ENV", "production");
      expect(authority.isReady()).toBe(false);
      await expect(authority.authenticate("anything")).rejects.toThrow("isolated review");
    } finally {
      vi.stubEnv("NODE_ENV", "review");
      await other.close();
    }
  });
});
