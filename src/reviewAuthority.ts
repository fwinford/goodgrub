import { randomUUID } from "node:crypto";
import { Types, type ClientSession, type Connection } from "mongoose";
import {
  assertReviewDatabase, createReviewModels, type ReviewRole,
} from "../models/reviewDb.js";
import {
  digestReviewSession, generateReviewSession, hashReviewPassword,
  isReviewPassword, isReviewSession, verifyReviewPassword,
} from "./reviewCredentials.js";

export const REVIEW_SESSION_LIFETIME_MS = 12 * 60 * 60 * 1000;
const LOGIN_WINDOW_MS = 15 * 60 * 1000;
const LOGIN_ATTEMPTS = 10;
const GENERATION_ID = "review";

export interface ReviewActor {
  role: ReviewRole;
  actorId: string;
  principal: string;
  generation: string;
}

export type ReviewLoginResult =
  | { outcome: "authenticated"; token: string; expiresAt: Date; actor: ReviewActor }
  | { outcome: "invalid" }
  | { outcome: "limited" };

export function isReviewRole(value: unknown): value is ReviewRole {
  return value === "requester" || value === "helper";
}

// No default binding: reset must include the fictional lifecycle in this transaction.
export interface ReviewResetBinding {
  reset(session: ClientSession): Promise<void>;
}

export class ReviewAuthority {
  private readonly models;
  private initialized = false;
  private dummyHash = "";

  constructor(private readonly connection: Connection) {
    this.models = createReviewModels(connection);
  }

  isReady(): boolean {
    return this.initialized && process.env.NODE_ENV === "review" &&
      this.connection.readyState === 1 && this.connection.name === "commonplate_review";
  }

  async initialize(): Promise<void> {
    assertReviewDatabase(this.connection);
    await Promise.all(Object.values(this.models).map((model) => model.createIndexes()));
    await this.models.generation.updateOne(
      { _id: GENERATION_ID },
      { $setOnInsert: { generation: randomUUID(), serial: 0 } },
      { upsert: true }
    );
    for (const role of ["requester", "helper"] as const) {
      await this.models.limits.updateOne({ _id: role }, {
        $setOnInsert: { attempts: 0, windowEndsAt: new Date(0) },
      }, { upsert: true });
    }
    this.dummyHash = await hashReviewPassword(randomUUID());
    this.initialized = true;
  }

  private assertReady(): void {
    assertReviewDatabase(this.connection);
    if (!this.initialized) throw new Error("Review authority is not initialized");
  }

  private async transaction<T>(
    work: (session: ClientSession, generation: string) => Promise<T>
  ): Promise<T> {
    this.assertReady();
    return this.connection.transaction(async (session) => {
      // All authority changes share this write fence: reset/login/rotation cannot
      // commit based on an older generation or account-version snapshot.
      const state = await this.models.generation.findOneAndUpdate(
        { _id: GENERATION_ID }, { $inc: { serial: 1 } }, { new: true, session }
      ).lean().exec();
      if (!state) throw new Error("Review generation is unavailable");
      return work(session, state.generation);
    });
  }

  async setCredential(role: ReviewRole, password: string): Promise<void> {
    this.assertReady();
    if (!isReviewRole(role)) throw new Error("Invalid review role");
    const passwordHash = await hashReviewPassword(password);
    await this.transaction(async (session) => {
      const other = await this.models.accounts.findById(
        role === "requester" ? "helper" : "requester"
      ).select("+passwordHash").session(session).lean().exec();
      if (other && await verifyReviewPassword(password, other.passwordHash)) {
        throw new Error("Review roles require distinct credentials");
      }
      await this.models.accounts.updateOne({ _id: role }, {
        $set: { passwordHash, revoked: false },
        $inc: { version: 1 },
        $setOnInsert: { actorId: new Types.ObjectId() },
      }, { upsert: true, session });
      await this.models.sessions.deleteMany({ accountId: role }, { session });
    });
  }

  async revoke(role: ReviewRole): Promise<void> {
    if (!isReviewRole(role)) throw new Error("Invalid review role");
    await this.transaction(async (session) => {
      await this.models.accounts.updateOne(
        { _id: role }, { $set: { revoked: true }, $inc: { version: 1 } }, { session }
      );
      await this.models.sessions.deleteMany({ accountId: role }, { session });
    });
  }

  async login(role: unknown, password: unknown): Promise<ReviewLoginResult> {
    this.assertReady();
    if (!isReviewRole(role) || !isReviewPassword(password)) return { outcome: "invalid" };
    const now = new Date();
    const result = await this.models.limits.findOneAndUpdate({ _id: role }, [{
      $set: {
        attempts: { $cond: [
          { $lte: [{ $ifNull: ["$windowEndsAt", new Date(0)] }, now] },
          1, { $add: ["$attempts", 1] },
        ] },
        windowEndsAt: { $cond: [
          { $lte: [{ $ifNull: ["$windowEndsAt", new Date(0)] }, now] },
          new Date(now.getTime() + LOGIN_WINDOW_MS), "$windowEndsAt",
        ] },
      },
    }], { new: true }).lean().exec();
    if (!result || result.attempts > LOGIN_ATTEMPTS) return { outcome: "limited" };
    const account = await this.models.accounts.findById(role).select("+passwordHash").lean().exec();
    const matches = await verifyReviewPassword(password, account?.passwordHash ?? this.dummyHash);
    if (!account || account.revoked || !matches) {
      return { outcome: "invalid" };
    }
    const token = generateReviewSession();
    const expiresAt = new Date(Date.now() + REVIEW_SESSION_LIFETIME_MS);
    return this.transaction(async (session, generation) => {
      const current = await this.models.accounts.findOne({
        _id: role, version: account.version, revoked: false,
      }).session(session).lean().exec();
      if (!current) return { outcome: "invalid" };
      await this.models.sessions.create([{
        _id: digestReviewSession(token), accountId: role, accountVersion: current.version,
        generation, expiresAt,
      }], { session });
      return {
        outcome: "authenticated", token, expiresAt,
        actor: { role, actorId: String(current.actorId),
          principal: `${role}@review.invalid`, generation },
      };
    });
  }

  async authenticate(token: unknown): Promise<ReviewActor | null> {
    this.assertReady();
    if (!isReviewSession(token)) return null;
    const stored = await this.models.sessions.findOne({
      _id: digestReviewSession(token), expiresAt: { $gt: new Date() },
    }).lean().exec();
    if (!stored) return null;
    const [account, state] = await Promise.all([
      this.models.accounts.findOne({
        _id: stored.accountId, version: stored.accountVersion, revoked: false,
      }).lean().exec(),
      this.models.generation.findById(GENERATION_ID).lean().exec(),
    ]);
    if (!account || !state || stored.generation !== state.generation) return null;
    return {
      role: account._id, actorId: String(account.actorId),
      principal: `${account._id}@review.invalid`, generation: state.generation,
    };
  }

  async logout(token: unknown): Promise<void> {
    this.assertReady();
    if (isReviewSession(token)) {
      await this.models.sessions.deleteOne({ _id: digestReviewSession(token) });
    }
  }

  // Caller must hold INF1's maintenance lock with ingress quarantined and the
  // entire review service stopped. This method never clears that quarantine.
  async reset(binding: ReviewResetBinding): Promise<void> {
    this.assertReady();
    if (!binding || typeof binding.reset !== "function") {
      throw new Error("Review lifecycle reset binding is required");
    }
    await this.transaction(async (session) => {
      await binding.reset(session);
      await this.models.generation.updateOne(
        { _id: GENERATION_ID }, { $set: { generation: randomUUID() } }, { session }
      );
      await this.models.sessions.deleteMany({}, { session });
    });
  }
}
