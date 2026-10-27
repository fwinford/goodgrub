import { createServer, type Server } from "node:http";
import { request as httpRequest } from "node:http";
import { once } from "node:events";
import { readFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import { WebSocket } from "ws";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as gate from "./participantAuthorityGate.js";
import { attachMessagingSocket, MESSAGING_SOCKET_PATH, SOCKET_LIMITS } from "./messagingSocket.js";

const requestId = "a".repeat(24);
const conversationId = "b".repeat(24);
const credential = "test-header-only-credential";
const subscribe = { type: "subscribe", requestId, conversationId };
const turn = () => new Promise<void>(resolve => setImmediate(resolve));

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}

describe("dormant local WebSocket signaling", () => {
  let server: Server;
  let url: string;
  let transport: ReturnType<typeof attachMessagingSocket>;
  let clients: WebSocket[];
  let frames: Map<WebSocket, Record<string, unknown>[]>;
  let releases: (() => void)[];
  let authorization: ReturnType<typeof vi.fn<(
    credential: string, requestId: string, conversationId: string, signal?: AbortSignal
  ) => Promise<void>>>;

  async function connect(options: { path?: string; headers?: Record<string, string | string[]>; autoPong?: boolean } = {}) {
    const client = new WebSocket(`${url}${options.path ?? MESSAGING_SOCKET_PATH}`, {
      headers: options.headers ?? { "x-commonplate-participant": credential },
      autoPong: options.autoPong ?? true,
    });
    clients.push(client);
    frames.set(client, []);
    client.on("message", data => frames.get(client)!.push(JSON.parse(data.toString())));
    // Errors are asserted by the connection promise or close assertions.
    client.on("error", () => {});
    await once(client, "open");
    return client;
  }
  async function waitFor(check: () => boolean) {
    for (let count = 0; count < 100 && !check(); count++) await delay(2);
    expect(check()).toBe(true);
  }
  async function subscribed(token = credential, frame = subscribe) {
    const client = await connect({ headers: { "x-commonplate-participant": token } });
    client.send(JSON.stringify(frame));
    await waitFor(() => frames.get(client)!.length > 0);
    expect(frames.get(client)![0]).toEqual({ type: "subscribed", subscription: expect.any(String) });
    return client;
  }
  async function refusedUpgrade(headers: Record<string, string | string[]>, path = MESSAGING_SOCKET_PATH) {
    return new Promise<{ status: number; body: string }>((resolve, reject) => {
      const req = httpRequest(`${url.replace("ws:", "http:")}${path}`, {
        headers: {
          Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Version": "13",
          "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==", ...headers,
        },
      }, response => {
        let body = "";
        response.on("data", data => { body += data; });
        response.on("end", () => resolve({ status: response.statusCode!, body }));
      });
      req.on("error", reject);
      req.end();
    });
  }

  beforeEach(async () => {
    vi.spyOn(gate, "resolveParticipantAuthority").mockResolvedValue({
      ok: true, participant: { participantId: "internal", principal: "private@nyu.edu", authorityVersion: 1 },
    });
    authorization = vi.fn(async () => {});
    clients = [];
    frames = new Map();
    releases = [];
    server = createServer({ maxHeaderSize: SOCKET_LIMITS.headerBytes, headersTimeout: 5000 });
    transport = attachMessagingSocket(server, { authorizeSubscription: authorization });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Missing server");
    url = `ws://127.0.0.1:${address.port}`;
  });
  afterEach(async () => {
    for (const release of releases) release();
    vi.useRealTimers();
    const closed = clients.map(client => client.readyState === WebSocket.CLOSED ? Promise.resolve()
      : new Promise<void>(resolve => { client.once("close", () => resolve()); client.terminate(); }));
    await Promise.all(closed);
    await transport.dispose();
    await transport.drainAuthorizations();
    expect(transport.stats().authorizations).toBe(0);
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    vi.restoreAllMocks();
  });

  it("authenticates upgrades separately and authorizes before any subscription disclosure", async () => {
    const gate = deferred<void>();
    releases.push(() => gate.resolve());
    authorization.mockImplementation(() => gate.promise);
    const client = await connect();
    client.send(JSON.stringify(subscribe));
    await waitFor(() => authorization.mock.calls.length === 1);
    expect(frames.get(client)).toEqual([]);
    expect(authorization.mock.calls[0].slice(0, 3)).toEqual([credential, requestId, conversationId]);
    gate.resolve();
    await waitFor(() => frames.get(client)!.length === 1);
    expect(frames.get(client)![0].type).toBe("subscribed");
  });

  it.each<Record<string, string | string[]>>([
    {}, { "x-commonplate-participant": "" },
    { "x-commonplate-participant": ["first", "second"] },
    { "x-commonplate-participant": credential, "Sec-WebSocket-Protocol": "secret" },
  ])("refuses missing, empty, duplicated or subprotocol credentials generically: %j", async headers => {
    const result = await refusedUpgrade(headers);
    expect(result).toEqual({ status: 503, body: "Unavailable" });
    expect(authorization).not.toHaveBeenCalled();
  });
  it("refuses query-string credentials even alongside a valid header", async () => {
    expect(await refusedUpgrade({ "x-commonplate-participant": credential },
      `${MESSAGING_SOCKET_PATH}?credential=private`)).toEqual({ status: 503, body: "Unavailable" });
  });
  it("uses a generic response for malformed WebSocket handshakes", async () => {
    const malformed: Record<string, string>[] = [
      { "Sec-WebSocket-Key": "not-a-key" }, { "Sec-WebSocket-Version": "12" },
    ];
    for (const headers of malformed) {
      expect(await refusedUpgrade({ "x-commonplate-participant": credential, ...headers }))
        .toEqual({ status: 503, body: "Unavailable" });
    }
    expect(gate.resolveParticipantAuthority).not.toHaveBeenCalled();
  });
  it.each(["invalid", "missing", "unavailable"] as const)("conceals %s credential refusal", async refusal => {
    vi.mocked(gate.resolveParticipantAuthority).mockResolvedValue({ ok: false, refusal });
    expect(await refusedUpgrade({ "x-commonplate-participant": credential }))
      .toEqual({ status: 503, body: "Unavailable" });
  });

  it("rejects unallowlisted upgrade paths without leaving an untracked socket", async () => {
    expect(await refusedUpgrade({ "x-commonplate-participant": credential }, "/not-messaging"))
      .toEqual({ status: 503, body: "Unavailable" });
    expect(gate.resolveParticipantAuthority).not.toHaveBeenCalled();
    expect(transport.stats().connections).toBe(0);
    expect(transport.stats().upgrades).toBe(0);
  });

  it("registers before acknowledgement and preserves changes during authorization", async () => {
    const gate = deferred<void>();
    releases.push(() => gate.resolve());
    authorization.mockImplementationOnce(() => gate.promise);
    const client = await connect();
    client.send(JSON.stringify(subscribe));
    await waitFor(() => authorization.mock.calls.length > 0);
    transport.observer.committed(conversationId);
    await turn();
    gate.resolve();
    await waitFor(() => frames.get(client)!.length === 2);
    expect(frames.get(client)!.map(frame => frame.type)).toEqual(["subscribed", "changed"]);
    expect(authorization).toHaveBeenCalledTimes(2);
  });

  it("coalesces publications and emits only connection-local content-free references", async () => {
    const client = await subscribed();
    for (let i = 0; i < 100; i++) transport.observer.committed(conversationId);
    await waitFor(() => frames.get(client)!.length === 2);
    const [ack, hint] = frames.get(client)!;
    expect(hint).toEqual({ type: "changed", subscription: ack.subscription });
    expect(JSON.stringify(frames.get(client))).not.toMatch(new RegExp(`${requestId}|${conversationId}|${credential}|private@nyu.edu|internal`));
    expect(transport.stats().pendingHints).toBe(0);
  });

  it("denies stale async authorization after disposal and uses a new reference after reconnect", async () => {
    const first = await subscribed();
    const reference = frames.get(first)![0].subscription;
    first.terminate();
    await once(first, "close");
    const second = await subscribed();
    expect(frames.get(second)![0].subscription).not.toBe(reference);
    const gate = deferred<void>();
    releases.push(() => gate.resolve());
    authorization.mockImplementation(() => gate.promise);
    transport.observer.committed(conversationId);
    await waitFor(() => transport.stats().authorizations === 1);
    const disposing = transport.dispose();
    gate.resolve();
    expect(await disposing).toEqual({ pendingAuthorizations: 0 });
    expect(frames.get(second)!.map(frame => frame.type)).toEqual(["subscribed"]);
    expect(server.listenerCount("upgrade")).toBe(0);
  });

  it("revokes multiple sockets before delivery without disclosing policy reasons", async () => {
    const a = await subscribed();
    const b = await subscribed();
    authorization.mockRejectedValue(new Error("PRIVATE POLICY DETAIL"));
    transport.observer.committed(conversationId);
    await waitFor(() => a.readyState === WebSocket.CLOSED && b.readyState === WebSocket.CLOSED);
    expect(frames.get(a)!.filter(frame => frame.type === "changed")).toHaveLength(0);
    expect(JSON.stringify([...frames.values()])).not.toContain("PRIVATE");
    expect(transport.stats().connections).toBe(0);
    expect(frames.get(a)!.at(-1)).toEqual({ type: "unavailable" });
    expect(frames.get(b)!.at(-1)).toEqual({ type: "unavailable" });
  });

  it.each(["not-json", "null", "[]", '{"type":"send","text":"PRIVATE"}', JSON.stringify({ ...subscribe, credential }),
    JSON.stringify({ ...subscribe, conversationId: "bad" })])("closes malformed or unsupported application frame %s", async payload => {
    const client = await connect();
    client.send(payload);
    await waitFor(() => client.readyState === WebSocket.CLOSED);
    expect(authorization).not.toHaveBeenCalled();
    expect(frames.get(client)).toEqual([{ type: "unavailable" }]);
  });
  it("rejects a second subscription and binary data", async () => {
    const client = await subscribed();
    client.send(JSON.stringify(subscribe));
    await waitFor(() => client.readyState === WebSocket.CLOSED);
    const binary = await connect();
    binary.send(Buffer.from("private"));
    await waitFor(() => binary.readyState === WebSocket.CLOSED);
    expect(authorization).toHaveBeenCalledTimes(1);
  });
  it("bounds oversized and fragmented message payloads at 1024 bytes", async () => {
    const client = await connect();
    const closed = new Promise<number>(resolve => client.once("close", code => resolve(code)));
    client.send("x".repeat(1025));
    await waitFor(() => client.readyState === WebSocket.CLOSED);
    expect(await closed).toBe(1009);
    expect(frames.get(client)).toEqual([]);
    expect(authorization).not.toHaveBeenCalled();
    const fragmented = await connect();
    fragmented.send("x".repeat(600), { fin: false });
    fragmented.send("x".repeat(600));
    await waitFor(() => fragmented.readyState === WebSocket.CLOSED);
  });

  it("bounds the hint queue and safely drops excess publications", async () => {
    for (let i = 0; i < 1100; i++) transport.observer.committed(String(i));
    expect(transport.stats().pendingHints).toBe(1000);
    await turn();
    expect(transport.stats().pendingHints).toBe(0);
  });
  it("enforces 30 upgrade attempts in a rolling minute, including refused credentials", async () => {
    for (let i = 0; i < 30; i++) expect((await refusedUpgrade({})).status).toBe(503);
    expect((await refusedUpgrade({ "x-commonplate-participant": credential })).status).toBe(503);
    expect(gate.resolveParticipantAuthority).not.toHaveBeenCalled();
    expect(transport.stats().addressBuckets).toBe(1);
    const future = Date.now() + 60_001;
    vi.spyOn(Date, "now").mockReturnValue(future);
    const client = await connect();
    expect(client.readyState).toBe(WebSocket.OPEN);
  });
  it("bounds concurrent authentication and retains slots for unsettled work after timeout", async () => {
    let address = 0;
    server.on("connection", socket => Object.defineProperty(socket, "remoteAddress", { value: `test-${address++}` }));
    const gate = deferred<gate.ParticipantAuthorityResolution>();
    releases.push(() => gate.resolve({ ok: false, refusal: "unavailable" }));
    vi.mocked(gateModule()).mockImplementation(() => gate.promise);
    vi.useFakeTimers();
    const attempts = Array.from({ length: 33 }, () => refusedUpgrade({ "x-commonplate-participant": credential }));
    await waitFor(() => transport.stats().authorizations === 32);
    await vi.advanceTimersByTimeAsync(5001);
    vi.useRealTimers();
    expect((await Promise.all(attempts)).every(result => result.status === 503)).toBe(true);
    expect(transport.stats().authorizations).toBe(32);
    gate.resolve({ ok: false, refusal: "unavailable" });
    await waitFor(() => transport.stats().authorizations === 0);
  });
  function gateModule() { return gate.resolveParticipantAuthority; }

  function separateParticipants() {
    vi.mocked(gate.resolveParticipantAuthority).mockImplementation(async request => ({
      ok: true, participant: {
        participantId: String(request.headers["x-commonplate-participant"]), principal: "private@nyu.edu",
        authorityVersion: 1,
      },
    }));
  }

  it("atomically caps simultaneous admissions at eight sockets per verified participant", async () => {
    const results = await Promise.allSettled(Array.from({ length: 10 }, () => connect()));
    expect(results.filter(result => result.status === "fulfilled")).toHaveLength(8);
    expect(results.filter(result => result.status === "rejected")).toHaveLength(2);
    expect(transport.stats().connections).toBe(SOCKET_LIMITS.participantConnections);
    const client = clients.find(client => client.readyState === WebSocket.OPEN)!;
    client.terminate();
    await once(client, "close");
    await waitFor(() => transport.stats().connections === 7);
    expect((await connect()).readyState).toBe(WebSocket.OPEN);
  });

  it("atomically caps provisional conversation admissions at sixteen, including pending authority", async () => {
    separateParticipants();
    vi.useFakeTimers();
    const barrier = deferred<void>();
    releases.push(() => barrier.resolve());
    authorization.mockImplementation(() => barrier.promise);
    const sockets = await Promise.all(Array.from({ length: 18 }, (_, index) =>
      connect({ headers: { "x-commonplate-participant": `actor-${index % 3}` } })));
    for (const socket of sockets) socket.send(JSON.stringify(subscribe));
    await waitFor(() => sockets.filter(socket => socket.readyState === WebSocket.CLOSED).length === 2);
    expect(transport.stats().connections).toBe(SOCKET_LIMITS.conversationConnections);
    expect(transport.stats().validations).toBe(1);
    barrier.resolve();
    await vi.advanceTimersByTimeAsync(1000);
    vi.useRealTimers();
    await waitFor(() => sockets.filter(socket => frames.get(socket)!.some(frame => frame.type === "subscribed")).length === 16);
  });

  it("coalesces exact-credential hints, isolates a busy relationship and preserves its counterparty", async () => {
    separateParticipants();
    const noisy = await Promise.all(Array.from({ length: 8 }, () => subscribed()));
    const counterparty = await subscribed("helper");
    const otherFrame = { ...subscribe, requestId: "c".repeat(24), conversationId: "d".repeat(24) };
    const unrelated = await subscribed("unrelated", otherFrame);
    const barrier = deferred<void>();
    releases.push(() => barrier.resolve());
    authorization.mockClear();
    authorization.mockImplementation(async (token, _request, conversation) => {
      if (token === credential && conversation === conversationId) await barrier.promise;
    });
    for (let i = 0; i < 100; i++) transport.observer.committed(conversationId);
    await waitFor(() => authorization.mock.calls.length === 1);
    expect(transport.stats().validations).toBe(1);
    expect(transport.stats().queuedValidations).toBe(1);
    transport.observer.committed(otherFrame.conversationId);
    await waitFor(() => frames.get(unrelated)!.length === 2);
    expect(counterparty.readyState).toBe(WebSocket.OPEN);
    expect(frames.get(counterparty)).toHaveLength(1);
    for (const socket of noisy) expect(frames.get(socket)).toHaveLength(1);
    barrier.resolve();
    await waitFor(() => frames.get(counterparty)!.length === 2);
    for (const socket of noisy) expect(frames.get(socket)!.map(frame => frame.type)).toEqual(["subscribed", "changed"]);
    expect(authorization.mock.calls.filter(call => call[2] === conversationId)).toHaveLength(2);
    expect(transport.stats().queuedValidations).toBe(0);
  });

  it("defers capacity shortages fairly and periodically revalidates after congestion", async () => {
    separateParticipants();
    vi.useFakeTimers();
    const entries: { frame: typeof subscribe; socket: WebSocket }[] = [];
    for (let i = 0; i < 10; i++) {
      const frame = { ...subscribe, requestId: i.toString(16).padStart(24, "0"), conversationId: (i + 20).toString(16).padStart(24, "0") };
      entries.push({ frame, socket: await subscribed(`actor-${i}`, frame) });
    }
    const barrier = deferred<void>();
    releases.push(() => barrier.resolve());
    authorization.mockClear();
    authorization.mockImplementation(() => barrier.promise);
    await vi.advanceTimersByTimeAsync(100);
    for (const { frame } of entries) transport.observer.committed(frame.conversationId);
    await vi.advanceTimersByTimeAsync(0);
    await waitFor(() => transport.stats().validations === 8);
    expect(authorization).toHaveBeenCalledTimes(8);
    expect(transport.stats().queuedValidations).toBe(2);
    for (const { frame } of entries) {
      for (let i = 0; i < 100; i++) transport.observer.committed(frame.conversationId);
    }
    await vi.advanceTimersByTimeAsync(0);
    expect(transport.stats().queuedValidations).toBe(2);
    expect(entries.map(({ socket }) => socket.readyState)).toEqual(Array(10).fill(WebSocket.OPEN));
    expect(entries.every(({ socket }) => frames.get(socket)!.length === 1)).toBe(true);
    barrier.resolve();
    await waitFor(() => entries.every(({ socket }) => frames.get(socket)!.length >= 2));
    await vi.advanceTimersByTimeAsync(200);
    await waitFor(() => transport.stats().validations === 0 && transport.stats().queuedValidations === 0);
    const previous = authorization.mock.calls.length;
    await vi.advanceTimersByTimeAsync(30_000);
    await vi.advanceTimersByTimeAsync(200);
    vi.useRealTimers();
    await waitFor(() => authorization.mock.calls.length === previous + 10);
    expect(entries.every(({ socket }) => socket.readyState === WebSocket.OPEN)).toBe(true);
  });

  it("limits one participant to two active checks across relationships while admitting unrelated work", async () => {
    separateParticipants();
    const entries: { frame: typeof subscribe; socket: WebSocket }[] = [];
    for (let i = 0; i < 7; i++) {
      const frame = { ...subscribe, conversationId: i.toString(16).padStart(24, "0") };
      entries.push({ frame, socket: await subscribed(credential, frame) });
    }
    const unrelatedFrame = { ...subscribe, conversationId: "f".repeat(24) };
    const unrelated = await subscribed("unrelated", unrelatedFrame);
    const barrier = deferred<void>();
    releases.push(() => barrier.resolve());
    authorization.mockClear();
    authorization.mockImplementation(async token => {
      if (token === credential) await barrier.promise;
    });
    for (const { frame } of entries) transport.observer.committed(frame.conversationId);
    await waitFor(() => transport.stats().validations === 2);
    expect(authorization).toHaveBeenCalledTimes(2);
    expect(transport.stats().queuedValidations).toBe(5);
    transport.observer.committed(unrelatedFrame.conversationId);
    await waitFor(() => frames.get(unrelated)!.length === 2);
    expect(transport.stats().validations).toBe(2);
    barrier.resolve();
    await waitFor(() => entries.every(({ socket }) => frames.get(socket)!.length === 2));
    await waitFor(() => transport.stats().validations === 0 && transport.stats().queuedValidations === 0);
  });

  it("keeps a shared check valid for remaining members without resurrecting its disconnected first member", async () => {
    const first = await subscribed();
    const second = await subscribed();
    const barrier = deferred<void>();
    releases.push(() => barrier.resolve());
    authorization.mockClear();
    authorization.mockImplementation(() => barrier.promise);
    transport.observer.committed(conversationId);
    await waitFor(() => authorization.mock.calls.length === 1);
    first.terminate();
    await once(first, "close");
    barrier.resolve();
    await waitFor(() => frames.get(second)!.length === 2);
    expect(frames.get(first)!.map(frame => frame.type)).toEqual(["subscribed"]);
    expect(authorization).toHaveBeenCalledTimes(1);
    expect(authorization.mock.calls[0][0]).toBe(credential);
    await waitFor(() => transport.stats().authorizations === 0 && transport.stats().validations === 0);
  });

  it("does not share decisions across credentials or with sockets arriving after authorization began", async () => {
    separateParticipants();
    const barrier = deferred<void>();
    releases.push(() => barrier.resolve());
    authorization.mockImplementationOnce(() => barrier.promise).mockRejectedValue(new Error("revoked"));
    const first = await connect();
    first.send(JSON.stringify(subscribe));
    await waitFor(() => authorization.mock.calls.length === 1);
    const late = await connect();
    const newerCredential = await connect({ headers: { "x-commonplate-participant": "new-authority-version" } });
    late.send(JSON.stringify(subscribe));
    newerCredential.send(JSON.stringify(subscribe));
    await turn();
    expect(frames.get(late)).toEqual([]);
    expect(frames.get(newerCredential)).toEqual([]);
    first.terminate();
    await once(first, "close");
    barrier.resolve();
    await waitFor(() => late.readyState === WebSocket.CLOSED && newerCredential.readyState === WebSocket.CLOSED);
    expect(frames.get(first)).toEqual([]);
    expect(frames.get(late)).toEqual([{ type: "unavailable" }]);
    expect(frames.get(newerCredential)).toEqual([{ type: "unavailable" }]);
    expect(authorization.mock.calls.map(call => call[0])).toEqual([credential, credential, "new-authority-version"]);
  });

  it("bounds sustained pending work and retains actual slots until disconnected work settles", async () => {
    separateParticipants();
    vi.useFakeTimers();
    const barrier = deferred<void>();
    releases.push(() => barrier.resolve());
    authorization.mockImplementation(() => barrier.promise);
    const sockets: WebSocket[] = [];
    for (let i = 0; i < 9; i++) {
      const socket = await connect({ headers: { "x-commonplate-participant": `actor-${i}` } });
      sockets.push(socket);
      socket.send(JSON.stringify({ ...subscribe, conversationId: i.toString(16).padStart(24, "0") }));
    }
    await waitFor(() => transport.stats().validations === 8 && transport.stats().queuedValidations === 1);
    await vi.advanceTimersByTimeAsync(5100);
    vi.useRealTimers();
    await waitFor(() => sockets.every(socket => socket.readyState === WebSocket.CLOSED));
    expect(transport.stats().queuedValidations).toBe(0);
    expect(transport.stats().validations).toBe(8);
    expect(authorization).toHaveBeenCalledTimes(8);
    for (const socket of sockets) expect(frames.get(socket)).toEqual([{ type: "unavailable" }]);
    barrier.resolve();
    await waitFor(() => transport.stats().validations === 0 && transport.stats().authorizations === 0);
  });

  it("enforces the subscription timeout", async () => {
    vi.useFakeTimers();
    const client = await connect();
    await vi.advanceTimersByTimeAsync(5001);
    vi.useRealTimers();
    await waitFor(() => client.readyState === WebSocket.CLOSED);
  });
  it("sends pings, requires pong by the next interval and revalidates authority", async () => {
    vi.useFakeTimers();
    const client = await connect({ autoPong: false });
    client.send(JSON.stringify(subscribe));
    await waitFor(() => frames.get(client)!.length > 0);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(authorization).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(30_000);
    vi.useRealTimers();
    await waitFor(() => client.readyState === WebSocket.CLOSED);
  });
  it("requires reconnect at the one-hour lifetime even with valid pongs", async () => {
    let peer: import("node:net").Socket | undefined;
    server.on("upgrade", request => { peer = request.socket; });
    vi.useFakeTimers();
    const client = await subscribed();
    for (let i = 0; i < 119; i++) {
      const previous = authorization.mock.calls.length;
      const previousBytes = peer!.bytesRead;
      await vi.advanceTimersByTimeAsync(30_000);
      await waitFor(() => authorization.mock.calls.length > previous);
      await waitFor(() => peer!.bytesRead > previousBytes);
    }
    expect(client.readyState).toBe(WebSocket.OPEN);
    await vi.advanceTimersByTimeAsync(30_000);
    vi.useRealTimers();
    await waitFor(() => client.readyState === WebSocket.CLOSED);
  });
  it("bounds accepted connections at 250 and rate-limit buckets at 512", async () => {
    let participant = 0;
    vi.mocked(gate.resolveParticipantAuthority).mockImplementation(async () => ({
      ok: true, participant: { participantId: `participant-${participant++}`, principal: "private@nyu.edu", authorityVersion: 1 },
    }));
    let address = 0;
    server.on("connection", socket => Object.defineProperty(socket, "remoteAddress", { value: `test-${address++}` }));
    for (let i = 0; i < 250; i++) await connect();
    expect(transport.stats().connections).toBe(250);
    expect((await refusedUpgrade({ "x-commonplate-participant": credential })).status).toBe(503);
    for (let i = 251; i < 513; i++) await refusedUpgrade({});
    expect(transport.stats().addressBuckets).toBe(512);
    expect(transport.stats().connections).toBe(250);
  });
  it("limits inbound control frames to ten per minute", async () => {
    const client = await subscribed();
    for (let i = 0; i < 11; i++) client.ping();
    await waitFor(() => client.readyState === WebSocket.CLOSED);
  });
  it("expires unavailable subscription authority and never sends a late success", async () => {
    const gate = deferred<void>();
    releases.push(() => gate.resolve());
    authorization.mockImplementation(() => gate.promise);
    vi.useFakeTimers();
    const client = await connect();
    client.send(JSON.stringify(subscribe));
    await waitFor(() => authorization.mock.calls.length === 1);
    await vi.advanceTimersByTimeAsync(5001);
    vi.useRealTimers();
    await waitFor(() => client.readyState === WebSocket.CLOSED);
    gate.resolve();
    await waitFor(() => transport.stats().authorizations === 0);
    expect(frames.get(client)).toEqual([{ type: "unavailable" }]);
  });
  it("checks authority periodically even without publications", async () => {
    vi.useFakeTimers();
    const client = await subscribed();
    authorization.mockRejectedValue(new Error("unavailable"));
    await vi.advanceTimersByTimeAsync(30_000);
    vi.useRealTimers();
    await waitFor(() => client.readyState === WebSocket.CLOSED);
    expect(authorization).toHaveBeenCalledTimes(2);
    expect(frames.get(client)!.some(frame => frame.type === "changed")).toBe(false);
  });
  it("bounds shutdown at five seconds for a peer that never acknowledges close", async () => {
    const raw = await new Promise<import("node:stream").Duplex>((resolve, reject) => {
      const req = httpRequest(`${url.replace("ws:", "http:")}${MESSAGING_SOCKET_PATH}`, {
        headers: {
          Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Version": "13",
          "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==", "x-commonplate-participant": credential,
        },
      });
      req.once("upgrade", (_response, socket) => { socket.resume(); resolve(socket); });
      req.once("error", reject);
      req.end();
    });
    try {
      vi.useFakeTimers();
      let settled = false;
      const draining = transport.dispose().then(result => { settled = true; return result; });
      await vi.advanceTimersByTimeAsync(4999);
      expect(settled).toBe(false);
      await vi.advanceTimersByTimeAsync(1);
      expect(await draining).toEqual({ pendingAuthorizations: 0 });
    } finally {
      raw.destroy();
      vi.useRealTimers();
    }
  });
  it("flushes generic refusal and terminates a peer that never acknowledges its close within one second", async () => {
    const raw = await new Promise<import("node:stream").Duplex>((resolve, reject) => {
      const req = httpRequest(`${url.replace("ws:", "http:")}${MESSAGING_SOCKET_PATH}`, {
        headers: {
          Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Version": "13",
          "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==", "x-commonplate-participant": credential,
        },
      });
      req.once("upgrade", (_response, socket) => resolve(socket));
      req.once("error", reject);
      req.end();
    });
    try {
      const chunks: Buffer[] = [];
      raw.on("data", chunk => chunks.push(Buffer.from(chunk)));
      const closed = new Promise<void>(resolve => raw.once("close", () => resolve()));
      vi.useFakeTimers();
      // A masked invalid JSON frame. The raw peer reads but never answers close.
      raw.write(Buffer.from([0x81, 0x83, 0, 0, 0, 0, 98, 97, 100]));
      await waitFor(() => Buffer.concat(chunks).includes(Buffer.from('{"type":"unavailable"}')));
      expect(transport.stats().connections).toBe(0);
      await vi.advanceTimersByTimeAsync(999);
      expect(raw.destroyed).toBe(false);
      await vi.advanceTimersByTimeAsync(1);
      vi.useRealTimers();
      await closed;
      expect(raw.destroyed).toBe(true);
      expect(authorization).not.toHaveBeenCalled();
    } finally {
      raw.destroy();
      vi.useRealTimers();
    }
  });
  it("reports unsettled authorization on bounded disposal and exposes an explicit drain", async () => {
    const gate = deferred<void>();
    releases.push(() => gate.resolve());
    authorization.mockImplementation(() => gate.promise);
    vi.useFakeTimers();
    const client = await connect();
    client.send(JSON.stringify(subscribe));
    await waitFor(() => authorization.mock.calls.length > 0);
    const disposing = transport.dispose();
    await vi.advanceTimersByTimeAsync(5000);
    expect(await disposing).toEqual({ pendingAuthorizations: 1 });
    expect(() => attachMessagingSocket(server, { authorizeSubscription: authorization })).toThrow("dispose and drain");
    expect(transport.stats().connections).toBe(0);
    gate.resolve();
    await transport.drainAuthorizations();
    expect(transport.stats().authorizations).toBe(0);
    expect(frames.get(client)!.some(frame => frame.type === "subscribed")).toBe(false);
  });
  it("refuses oversized credentials and headers without echoing them", async () => {
    expect(await refusedUpgrade({ "x-commonplate-participant": "secret".repeat(200) }))
      .toEqual({ status: 503, body: "Unavailable" });
    // The injected HTTP server bounds headers before they reach upgrade auth.
    const result = await refusedUpgrade({ "x-commonplate-participant": credential, "x-padding": "x".repeat(17 * 1024) });
    expect(result.status).toBe(431);
    expect(result.body).not.toContain(credential);
    expect(gate.resolveParticipantAuthority).not.toHaveBeenCalled();
  });
  it("closes simulated slow consumers above 16 KiB after authorization but before output", async () => {
    const client = await subscribed();
    // This simulates buffered output, not kernel saturation, production memory
    // capacity, or Lightsail/Nginx buffering behavior.
    const original = Object.getOwnPropertyDescriptor(WebSocket.prototype, "bufferedAmount")!;
    Object.defineProperty(WebSocket.prototype, "bufferedAmount", { configurable: true, get: () => 16385 });
    try {
      transport.observer.committed(conversationId);
      await waitFor(() => client.readyState === WebSocket.CLOSED);
      expect(authorization).toHaveBeenCalledTimes(2);
      expect(frames.get(client)!.filter(frame => frame.type === "changed")).toHaveLength(0);
    } finally {
      Object.defineProperty(WebSocket.prototype, "bufferedAmount", original);
    }
  });
  it("disposes idempotently, clears queued hints and stays unmounted in production", async () => {
    expect(() => attachMessagingSocket(server, { authorizeSubscription: authorization })).toThrow("already attached");
    await subscribed();
    transport.observer.committed(conversationId);
    const first = transport.dispose();
    expect(transport.dispose()).toBe(first);
    expect(await first).toEqual({ pendingAuthorizations: 0 });
    expect(transport.stats()).toEqual({
      connections: 0, upgrades: 0, authorizations: 0, addressBuckets: 0, pendingHints: 0,
      queuedValidations: 0, validations: 0,
    });
    const source = readFileSync(new URL("../app.ts", import.meta.url), "utf8");
    expect(source).not.toMatch(/messagingSocket|attachMessagingSocket|WebSocketServer/);
  });
});
