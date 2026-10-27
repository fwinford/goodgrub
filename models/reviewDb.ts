import { Schema, type Connection, type Types } from "mongoose";

export const REVIEW_DATABASE = "commonplate_review";
export type ReviewRole = "requester" | "helper";

export interface ReviewAccount {
  _id: ReviewRole;
  actorId: Types.ObjectId;
  passwordHash: string;
  version: number;
  revoked: boolean;
}

export interface ReviewSession {
  _id: string;
  accountId: ReviewRole;
  accountVersion: number;
  generation: string;
  expiresAt: Date;
}

interface ReviewGeneration {
  _id: string;
  generation: string;
  serial: number;
}

interface ReviewLoginLimit {
  _id: ReviewRole;
  attempts: number;
  windowEndsAt: Date;
}

export function assertReviewDatabase(connection: Connection): void {
  if (process.env.NODE_ENV !== "review" ||
      connection.readyState !== 1 || connection.name !== REVIEW_DATABASE) {
    throw new Error("Review authority requires the isolated review database/runtime");
  }
}

export function createReviewModels(connection: Connection) {
  assertReviewDatabase(connection);
  const account = new Schema<ReviewAccount>({
    _id: { type: String, enum: ["requester", "helper"], required: true },
    actorId: { type: Schema.Types.ObjectId, required: true, unique: true },
    passwordHash: { type: String, required: true, select: false },
    version: { type: Number, required: true, min: 1, validate: Number.isSafeInteger },
    revoked: { type: Boolean, required: true },
  }, { versionKey: false });
  const session = new Schema<ReviewSession>({
    _id: { type: String, required: true, select: false },
    accountId: { type: String, enum: ["requester", "helper"], required: true },
    accountVersion: { type: Number, required: true },
    generation: { type: String, required: true },
    expiresAt: { type: Date, required: true },
  }, { versionKey: false });
  session.index({ expiresAt: 1 }, { expireAfterSeconds: 0 });
  const generation = new Schema<ReviewGeneration>({
    _id: { type: String, required: true },
    generation: { type: String, required: true },
    serial: { type: Number, required: true },
  }, { versionKey: false });
  const limit = new Schema<ReviewLoginLimit>({
    _id: { type: String, enum: ["requester", "helper"], required: true },
    attempts: { type: Number, required: true },
    windowEndsAt: { type: Date, required: true },
  }, { versionKey: false });
  return {
    accounts: connection.models.ReviewAccount
      ? connection.model<ReviewAccount>("ReviewAccount")
      : connection.model<ReviewAccount>("ReviewAccount", account, "review_accounts"),
    sessions: connection.models.ReviewSession
      ? connection.model<ReviewSession>("ReviewSession")
      : connection.model<ReviewSession>("ReviewSession", session, "review_sessions"),
    generation: connection.models.ReviewGeneration
      ? connection.model<ReviewGeneration>("ReviewGeneration")
      : connection.model<ReviewGeneration>("ReviewGeneration", generation, "review_generation"),
    limits: connection.models.ReviewLoginLimit
      ? connection.model<ReviewLoginLimit>("ReviewLoginLimit")
      : connection.model<ReviewLoginLimit>("ReviewLoginLimit", limit, "review_login_limits"),
  };
}
