import { describe, expect, it, vi, beforeEach } from "vitest";
import type { Request, Response } from "express";
import * as authority from "./participantAuthorityGate.js";

const service = vi.hoisted(() => ({
  open: vi.fn(),
  acknowledgeDisplayed: vi.fn(),
  unreadCounts: vi.fn(),
}));
vi.mock("./messaging.js", async importOriginal => ({
  ...(await importOriginal<typeof import("./messaging.js")>()),
  createMessagingService: () => service,
}));

const {
  createMessagingHandlers,
  CONVERSATION_ROUTE_PATH,
  MESSAGE_READ_ACK_ROUTE_PATH,
  MESSAGE_UNREAD_COUNT_ROUTE_PATH,
} = await import("./messagingRoutes.js");
const { MessagingError } = await vi.importActual<typeof import("./messaging.js")>("./messaging.js");

const REQUEST = "a".repeat(24);
const CONVERSATION = "b".repeat(24);
const CREDENTIAL = "participant-credential";

async function call(
  handlerName: "open" | "acknowledgeDisplayed" | "unreadCounts",
  body?: unknown
) {
  const headers = new Map<string, string>();
  const res = {
    setHeader: vi.fn((key: string, value: string) => headers.set(key, value)),
    status: vi.fn().mockReturnThis(),
    json: vi.fn().mockReturnThis(),
  };
  const req = {
    headers: { "x-commonplate-participant": CREDENTIAL },
    params: { id: REQUEST, conversationId: CONVERSATION },
    body,
  } as unknown as Request;
  const handlers = createMessagingHandlers();
  await handlers[handlerName](req, res as unknown as Response);
  return {
    headers,
    status: res.status.mock.calls[0]?.[0] as number,
    body: res.json.mock.calls[0]?.[0],
  };
}

describe("MSG1 CP7-A unread wire contract", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    service.open.mockReset().mockResolvedValue({
      conversationId: CONVERSATION,
      openingSnapshotSequence: 7,
    });
    service.acknowledgeDisplayed.mockReset().mockResolvedValue({
      conversationId: CONVERSATION,
      acknowledgedCount: 1,
    });
    service.unreadCounts.mockReset().mockResolvedValue({
      unreadCount: 2,
      conversations: [{ requestId: REQUEST, conversationId: CONVERSATION, unreadCount: 2 }],
    });
    vi.spyOn(authority, "resolveParticipantAuthority").mockResolvedValue({ ok: true } as never);
  });

  it("keeps the open route and adds only the authoritative opening snapshot", async () => {
    expect(CONVERSATION_ROUTE_PATH).toBe("/api/request/:id/conversation");
    const response = await call("open");
    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      conversationId: CONVERSATION,
      openingSnapshotSequence: 7,
    });
    expect(service.open).toHaveBeenCalledWith(CREDENTIAL, REQUEST);
    expect(JSON.stringify(response.body)).not.toMatch(/readAt|seen|receipt/i);
  });

  it("requires a strict bounded list for displayed-message acknowledgement", async () => {
    expect(MESSAGE_READ_ACK_ROUTE_PATH).toBe(
      "/api/request/:id/conversation/:conversationId/read"
    );
    const response = await call("acknowledgeDisplayed", { displayedSequences: [3, 7] });
    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      conversationId: CONVERSATION,
      acknowledgedCount: 1,
    });
    expect(service.acknowledgeDisplayed).toHaveBeenCalledWith(
      CREDENTIAL,
      REQUEST,
      { conversationId: CONVERSATION },
      [3, 7]
    );
  });

  it.each([
    ["missing sequence list", {}],
    ["string sequence", { displayedSequences: ["1"] }],
    ["unsafe sequence", { displayedSequences: [Number.MAX_SAFE_INTEGER + 1] }],
    ["unknown field", { displayedSequences: [1], through: 1 }],
    ["oversized sequence list", { displayedSequences: Array.from({ length: 101 }, (_, i) => i + 1) }],
  ])("refuses %s without echoing acknowledgement input", async (_name, body) => {
    const response = await call("acknowledgeDisplayed", body);
    expect(response.status).toBe(400);
    expect(response.body).toEqual({ error: expect.objectContaining({ code: "INVALID_MESSAGE" }) });
    expect(JSON.stringify(response.body)).not.toMatch(/displayedSequences|sequence/i);
    expect(service.acknowledgeDisplayed).not.toHaveBeenCalled();
  });

  it("accepts duplicate sequences and maps invalid references to the content-free invalid response", async () => {
    const duplicate = await call("acknowledgeDisplayed", { displayedSequences: [2, 2] });
    expect(duplicate.status).toBe(200);
    expect(service.acknowledgeDisplayed).toHaveBeenCalledWith(
      CREDENTIAL, REQUEST, { conversationId: CONVERSATION }, [2, 2]
    );
    service.acknowledgeDisplayed.mockRejectedValueOnce(new MessagingError("invalid"));
    const response = await call("acknowledgeDisplayed", { displayedSequences: [2, 99] });
    expect(response.status).toBe(400);
    expect(response.body).toEqual({ error: expect.objectContaining({ code: "INVALID_MESSAGE" }) });
  });

  it("returns only private, content-free eligible unread counts", async () => {
    expect(MESSAGE_UNREAD_COUNT_ROUTE_PATH).toBe("/api/participant/messaging/unread-count");
    const response = await call("unreadCounts");
    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      unreadCount: 2,
      conversations: [{ requestId: REQUEST, conversationId: CONVERSATION, unreadCount: 2 }],
    });
    expect(JSON.stringify(response.body)).not.toMatch(/text|sender|readAt|seen/i);
    expect(service.unreadCounts).toHaveBeenCalledWith(CREDENTIAL);
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(response.headers.get("Vary")).toBe("x-commonplate-participant");
  });

  it("resolves participant authority before reading the unread projection", async () => {
    vi.spyOn(authority, "resolveParticipantAuthority").mockResolvedValue({
      ok: false,
      refusal: "missing",
    });
    const response = await call("unreadCounts");
    expect(response.status).toBe(401);
    expect(service.unreadCounts).not.toHaveBeenCalled();
  });
});
