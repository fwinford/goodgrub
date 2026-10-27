import { readFileSync } from "node:fs";
import { describe, expect, it, vi, beforeEach } from "vitest";
import type { Request, Response } from "express";
import * as authority from "./participantAuthorityGate.js";

const service = vi.hoisted(() => ({ read: vi.fn(), history: vi.fn(), open: vi.fn(), send: vi.fn(), reconcile: vi.fn() }));
vi.mock("./messaging.js", async importOriginal => ({
  ...(await importOriginal<typeof import("./messaging.js")>()),
  createMessagingService: () => service,
}));

const { createMessagingHandlers } = await import("./messagingRoutes.js");
const { MessagingError, createMessagingService, MESSAGE_HISTORY_DEFAULT_LIMIT } =
  await vi.importActual<typeof import("./messaging.js")>("./messaging.js");

const REQUEST = "a".repeat(24);
const CONVERSATION = "b".repeat(24);

async function call(query: Record<string, unknown>) {
  const headers = new Map<string, string>();
  const res = {
    setHeader: vi.fn((key: string, value: string) => headers.set(key, value)),
    status: vi.fn().mockReturnThis(),
    json: vi.fn().mockReturnThis(),
  };
  const req = {
    headers: { "x-commonplate-participant": "credential" },
    params: { id: REQUEST, conversationId: CONVERSATION },
    query,
  } as unknown as Request;
  await createMessagingHandlers().read(req, res as unknown as Response);
  return { res, headers, status: res.status.mock.calls[0]?.[0] as number, body: res.json.mock.calls[0]?.[0] };
}

describe("MSG1 CP4 history route modes", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    service.read.mockReset().mockResolvedValue({ messages: [], nextAfter: 0 });
    service.history.mockReset().mockResolvedValue({ messages: [], hasOlder: false, nextBefore: null, newestSequence: 0 });
    vi.spyOn(authority, "resolveParticipantAuthority").mockResolvedValue({ ok: true } as never);
  });

  it("keeps absent direction on the forward path with unchanged defaults and response", async () => {
    const result = await call({});
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ messages: [], nextAfter: 0 });
    expect(service.read).toHaveBeenCalledWith("credential", REQUEST, { conversationId: CONVERSATION }, 0, 100);
    expect(service.history).not.toHaveBeenCalled();
    await call({ after: "7", limit: "100" });
    expect(service.read).toHaveBeenLastCalledWith("credential", REQUEST, { conversationId: CONVERSATION }, 7, 100);
  });

  it("serves backward mode with service defaults and an explicit bound", async () => {
    const result = await call({ direction: "backward" });
    expect(result.status).toBe(200);
    expect(Object.keys(result.body).sort()).toEqual(["hasOlder", "messages", "newestSequence", "nextBefore"]);
    expect(service.history).toHaveBeenCalledWith("credential", REQUEST, { conversationId: CONVERSATION }, undefined, undefined);
    await call({ direction: "backward", before: "12", limit: "100" });
    expect(service.history).toHaveBeenLastCalledWith("credential", REQUEST, { conversationId: CONVERSATION }, 12, 100);
    expect(service.read).not.toHaveBeenCalled();
  });

  it.each<[string, Record<string, unknown>]>([
    ["after with backward", { direction: "backward", after: "1" }],
    ["before without direction", { before: "5" }],
    ["unknown direction", { direction: "forward" }],
    ["empty direction", { direction: "" }],
    ["uppercase direction", { direction: "BACKWARD" }],
    ["before zero", { direction: "backward", before: "0" }],
    ["leading zero before", { direction: "backward", before: "01" }],
    ["negative before", { direction: "backward", before: "-1" }],
    ["hex before", { direction: "backward", before: "0x10" }],
    ["whitespace before", { direction: "backward", before: " 5" }],
    ["decimal before", { direction: "backward", before: "1.5" }],
    ["limit zero", { direction: "backward", limit: "0" }],
    ["non-numeric limit", { direction: "backward", limit: "ten" }],
    ["duplicate direction", { direction: ["backward", "backward"] }],
    ["duplicate before", { direction: "backward", before: ["1", "2"] }],
    ["duplicate limit", { direction: "backward", limit: ["1", "2"] }],
    ["nested before", { direction: "backward", before: { $gt: "1" } }],
    ["unknown key", { direction: "backward", cursor: "abc" }],
  ])("rejects %s as a content-free 400", async (_name, query) => {
    const result = await call(query);
    expect(result.status).toBe(400);
    expect(result.body).toEqual({ error: expect.objectContaining({ code: "INVALID_MESSAGE" }) });
    expect(JSON.stringify(result.body)).not.toMatch(/before|after|direction|cursor/i);
    expect(service.history).not.toHaveBeenCalled();
    expect(service.read).not.toHaveBeenCalled();
  });

  it("maps a service-side invalid bound (unsafe integer) to the same content-free 400", async () => {
    service.history.mockRejectedValueOnce(new MessagingError("invalid"));
    const result = await call({ direction: "backward", before: String(2 ** 53) });
    expect(result.status).toBe(400);
    expect(service.history).toHaveBeenCalledWith("credential", REQUEST, { conversationId: CONVERSATION }, 2 ** 53, undefined);
  });

  it("maps unavailable and failure outcomes without echoing the bound", async () => {
    service.history.mockRejectedValueOnce(new MessagingError("unavailable"));
    const denied = await call({ direction: "backward", before: "4" });
    expect(denied.status).toBe(404);
    expect(denied.body).toEqual({ error: expect.objectContaining({ code: "CONVERSATION_UNAVAILABLE" }) });
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    service.history.mockRejectedValueOnce(new Error("PRIVATE text 4"));
    const failed = await call({ direction: "backward", before: "4" });
    expect(failed.status).toBe(503);
    expect(error.mock.calls.flat().join(" ")).not.toMatch(/PRIVATE|4/);
  });

  it("sets private headers on history responses and resolves authority first", async () => {
    const result = await call({ direction: "backward" });
    expect(result.headers.get("Cache-Control")).toBe("private, no-store");
    expect(result.headers.get("Vary")).toBe("x-commonplate-participant");
    vi.spyOn(authority, "resolveParticipantAuthority").mockResolvedValue({ ok: false, refusal: "missing" });
    service.history.mockClear();
    const refused = await call({ direction: "backward", before: "bad" });
    expect(refused.status).toBe(401);
    expect(service.history).not.toHaveBeenCalled();
  });
});

describe("MSG1 CP4 history service validation (no database)", () => {
  const real = createMessagingService(undefined);
  const call = (before?: number, limit?: number) =>
    real.history("credential", REQUEST, { conversationId: CONVERSATION }, before, limit);

  it.each<[number | undefined, number | undefined]>([
    [0, undefined], [-1, undefined], [1.5, undefined], [2 ** 53, undefined], [NaN, undefined], [Infinity, undefined],
    [undefined, 0], [undefined, 101], [undefined, 1.5], [undefined, NaN],
  ])("refuses before=%s limit=%s as invalid", async (before, limit) => {
    await expect(call(before, limit)).rejects.toThrow(new MessagingError("invalid"));
  });

  it("defaults to 50 and otherwise denies without a policy", async () => {
    expect(MESSAGE_HISTORY_DEFAULT_LIMIT).toBe(50);
    await expect(call(5, 100)).rejects.toThrow(new MessagingError("unavailable"));
    await expect(call(undefined, 1)).rejects.toThrow(new MessagingError("unavailable"));
  });
});

describe("MSG1 CP4 dormancy and forward DTO shape", () => {
  it("is not imported, mounted or scheduled by app.ts or the model registry", () => {
    const app = readFileSync(new URL("../app.ts", import.meta.url), "utf8");
    const db = readFileSync(new URL("../models/db.ts", import.meta.url), "utf8");
    expect(app).not.toMatch(/messaging|MessageConversation|ConversationMessage|history/i);
    expect(db).not.toMatch(/messaging|MessageConversation|ConversationMessage/);
  });

  it("leaves the forward response keys that CP3 decodes unchanged", () => {
    const source = readFileSync(new URL("./messaging.ts", import.meta.url), "utf8");
    expect(source).toMatch(/return \{ messages: messages\.map\(message => view\(message, actor\)\),\s+nextAfter: messages\.at\(-1\)\?\.sequence \?\? after \};/);
  });
});
