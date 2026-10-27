import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { describe, expect, it, vi, beforeEach } from "vitest";
import type { Request, Response } from "express";
import { validateMessage, MessagingError, sweepMessageCleanup } from "./messaging.js";
import { createMessagingHandlers } from "./messagingRoutes.js";
import * as authority from "./participantAuthorityGate.js";
import { ConversationMessage, MessageConversation, MessageReceipt } from "../models/messaging.js";

describe("dormant messaging boundary", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("has no production registration, scheduler or model import", () => {
    const app = readFileSync(new URL("../app.ts", import.meta.url), "utf8");
    const db = readFileSync(new URL("../models/db.ts", import.meta.url), "utf8");
    expect(app).not.toMatch(/messaging|MessageConversation|ConversationMessage|MessageReceipt/);
    expect(db).not.toMatch(/messaging|MessageConversation|ConversationMessage|MessageReceipt/);
  });

  it("protects content and digests from ordinary projections, without TTL erasure of identities", () => {
    expect(ConversationMessage.schema.path("text").options.select).toBe(false);
    expect(ConversationMessage.schema.path("readAt").options.select).toBe(false);
    expect(MessageReceipt.schema.path("payloadDigest").options.select).toBe(false);
    for (const model of [ConversationMessage, MessageConversation, MessageReceipt]) {
      expect(model.schema.indexes().some(([, options]) => options.expireAfterSeconds !== undefined)).toBe(false);
    }
  });

  it.each(["", " ", "\n\t", "x".repeat(2001)])("refuses invalid text without echoing content", text => {
    expect(() => validateMessage(text, randomUUID())).toThrow(new MessagingError("invalid"));
  });

  it("accepts exact text without trimming and requires a canonical client UUID", () => {
    expect(() => validateMessage("  Meet at pickup  ", randomUUID())).not.toThrow();
    expect(() => validateMessage("valid", "arbitrary")).toThrow("invalid");
  });

  it("refuses cleanup without authoritative lifecycle integration", async () => {
    await expect(sweepMessageCleanup()).rejects.toThrow("unavailable");
  });

  it("resolves authority before validating any path or payload and sets private headers", async () => {
    vi.spyOn(authority, "resolveParticipantAuthority").mockResolvedValue({ ok: false, refusal: "missing" });
    const headers = new Map<string, string>();
    const res = {
      setHeader: vi.fn((key: string, value: string) => headers.set(key, value)),
      status: vi.fn().mockReturnThis(),
      json: vi.fn().mockReturnThis(),
    };
    await createMessagingHandlers().send(
      { headers: {}, params: {}, body: "PRIVATE INVALID CONTENT" } as Request,
      res as unknown as Response
    );
    expect(res.status).toHaveBeenCalledWith(401);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: expect.objectContaining({ code: "PARTICIPANT_VERIFICATION_REQUIRED" }),
    }));
    expect(headers.get("Cache-Control")).toBe("private, no-store");
    expect(headers.get("Vary")).toBe("x-commonplate-participant");
  });
});
