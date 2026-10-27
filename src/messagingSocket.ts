import { randomUUID } from "node:crypto";
import type { IncomingMessage, Server } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocket, WebSocketServer } from "ws";
import { PARTICIPANT_AUTHORITY_HEADER, resolveParticipantAuthority } from "./participantAuthorityGate.js";
import type { MessagingObserver } from "./messaging.js";

export const MESSAGING_SOCKET_PATH = "/api/messaging/socket";
export const SOCKET_LIMITS = Object.freeze({
  connections: 250,
  authorizations: 32,
  participantConnections: 8,
  conversationConnections: 16,
  validations: 8,
  participantValidations: 2,
  retryMs: 25,
  relationshipIntervalMs: 100,
  queueMs: 5000,
  refusalMs: 1000,
  upgradeAttempts: 30,
  addressBuckets: 512,
  headerBytes: 16 * 1024,
  frameBytes: 1024,
  bufferedBytes: 16 * 1024,
  pendingHints: 1000,
  controlFrames: 10,
  windowMs: 60_000,
  authorizationMs: 5000,
  subscriptionMs: 5000,
  intervalMs: 30_000,
  lifetimeMs: 60 * 60_000,
  shutdownMs: 5000,
});

export interface SocketAuthority {
  authorizeSubscription(credential: string, requestId: string, conversationId: string, signal?: AbortSignal): Promise<void>;
}

interface Subscription {
  requestId: string;
  conversationId: string;
  reference: string;
}

interface Connection {
  socket: WebSocket;
  credential: string;
  participantId: string;
  generation: number;
  subscription?: Subscription;
  subscribed: boolean;
  dirty: boolean;
  validating: boolean;
  pong: boolean;
  controls: number[];
  timers: Set<ReturnType<typeof setTimeout>>;
  queuedAt?: number;
  batch?: { members: Set<Connection>; abort: AbortController };
}

let processAttachment: symbol | undefined;

// No production caller. The injected HTTP server must itself bound pre-upgrade
// header parsing (maxHeaderSize / headersTimeout); this module bounds upgrades.
export function attachMessagingSocket(server: Server, authority: SocketAuthority) {
  if (processAttachment) throw new Error("Messaging transport already attached; dispose and drain first");
  const attachment = Symbol();
  const limits = SOCKET_LIMITS;
  const wss = new WebSocketServer({
    noServer: true, maxPayload: limits.frameBytes, perMessageDeflate: false,
    autoPong: false,
  });
  const connections = new Set<Connection>();
  const peers = new Set<WebSocket>();
  const refusals = new Map<WebSocket, ReturnType<typeof setTimeout>>();
  const participants = new Map<string, number>();
  const conversations = new Map<string, number>();
  const queued = new Set<Connection>();
  const relationships = new Map<string, number>();
  const validatingParticipants = new Map<string, number>();
  const upgrades = new Map<Duplex, AbortController>();
  const addresses = new Map<string, number[]>();
  const hints = new Set<string>();
  const pending = new Set<Promise<unknown>>();
  let authCount = 0;
  let validationCount = 0;
  let scheduler: ReturnType<typeof setTimeout> | undefined;
  let pumpQueued = false;
  let stopped = false;
  let flush: ReturnType<typeof setImmediate> | undefined;
  let disposePromise: Promise<{ pendingAuthorizations: number }> | undefined;

  function later(connection: Connection, callback: () => void, ms: number) {
    const timer = setTimeout(() => {
      connection.timers.delete(timer);
      callback();
    }, ms);
    connection.timers.add(timer);
    return timer;
  }

  function clean(connection: Connection) {
    if (!connections.delete(connection)) return;
    connection.generation++;
    queued.delete(connection);
    const batch = connection.batch;
    if (batch) {
      batch.members.delete(connection);
      if (!batch.members.size) batch.abort.abort();
    }
    const count = participants.get(connection.participantId)! - 1;
    if (count) participants.set(connection.participantId, count); else participants.delete(connection.participantId);
    if (connection.subscription) {
      const key = connection.subscription.conversationId;
      const count = conversations.get(key)! - 1;
      if (count) conversations.set(key, count); else conversations.delete(key);
    }
    connection.dirty = false;
    connection.subscription = undefined;
    connection.credential = "";
    for (const timer of connection.timers) clearTimeout(timer);
    connection.timers.clear();
  }

  function send(connection: Connection, value: object): boolean {
    if (stopped || !connections.has(connection) || connection.socket.readyState !== WebSocket.OPEN) return false;
    const frame = JSON.stringify(value);
    if (connection.socket.bufferedAmount + Buffer.byteLength(frame) > limits.bufferedBytes) {
      refuse(connection);
      return false;
    }
    connection.socket.send(frame, error => {
      if (error) {
        clean(connection);
        connection.socket.terminate();
      }
    });
    return true;
  }

  function refuse(connection: Connection) {
    if (!connections.has(connection)) return;
    // Invalidate before sending the non-conversation-dependent refusal.
    clean(connection);
    const socket = connection.socket;
    const frame = '{"type":"unavailable"}';
    if (socket.readyState !== WebSocket.OPEN ||
      socket.bufferedAmount + Buffer.byteLength(frame) > limits.bufferedBytes) return socket.terminate();
    // Enforcement happened in clean(). Delivery is best-effort, with a finite
    // close deadline even when the peer never reads or acknowledges close.
    refusals.set(socket, setTimeout(() => socket.terminate(), limits.refusalMs));
    socket.send(frame, error => {
      if (error) socket.terminate(); else if (socket.readyState === WebSocket.OPEN) socket.close(1008);
    });
  }

  async function authorized<T>(
    work: (signal: AbortSignal) => Promise<T>, parent: AbortSignal, released?: () => void
  ): Promise<T> {
    if (stopped || parent.aborted || authCount >= limits.authorizations) throw new Error("unavailable");
    authCount++;
    const abort = new AbortController();
    const cancel = () => abort.abort();
    parent.addEventListener("abort", cancel, { once: true });
    let rejectDeadline!: (reason: Error) => void;
    const deadline = new Promise<never>((_, reject) => { rejectDeadline = reject; });
    const cancelled = () => rejectDeadline(new Error("unavailable"));
    abort.signal.addEventListener("abort", cancelled, { once: true });
    const timer = setTimeout(() => abort.abort(), limits.authorizationMs);
    const operation = Promise.resolve().then(() => {
      abort.signal.throwIfAborted();
      return work(abort.signal);
    });
    // Slots belong to actual work, not the timeout race. A stuck database can
    // exhaust 32 slots but cannot start an unbounded tail of replacement work.
    const settled = operation.then(() => undefined, () => undefined).finally(() => {
      authCount--;
      pending.delete(settled);
      released?.();
    });
    pending.add(settled);
    try {
      return await Promise.race([operation, deadline]);
    } finally {
      clearTimeout(timer);
      parent.removeEventListener("abort", cancel);
      abort.signal.removeEventListener("abort", cancelled);
    }
  }

  function schedule() {
    if (!stopped && queued.size && !scheduler) scheduler = setTimeout(pump, limits.retryMs);
  }

  function kick() {
    if (stopped || pumpQueued) return;
    pumpQueued = true;
    void Promise.resolve().then(() => {
      pumpQueued = false;
      if (!stopped) pump();
    });
  }

  function validate(connection: Connection) {
    if (connection.validating || queued.has(connection) || !connections.has(connection)) return;
    connection.queuedAt = Date.now();
    queued.add(connection);
    kick();
  }

  function pump() {
    if (scheduler) clearTimeout(scheduler);
    scheduler = undefined;
    const now = Date.now();
    for (const [key, readyAt] of relationships) {
      if (readyAt <= now) relationships.delete(key);
    }
    for (const connection of queued) {
      if (now - connection.queuedAt! >= limits.queueMs) refuse(connection);
    }
    // Insertion order is FIFO. Busy relationships are skipped, not allowed to
    // block unrelated work. At most one pending bit exists per live connection.
    for (const first of queued) {
      if (validationCount >= limits.validations || authCount >= limits.authorizations) break;
      const subscription = first.subscription!;
      const credential = first.credential;
      const relationship = `${subscription.requestId}:${subscription.conversationId}`;
      const participantId = first.participantId;
      if (relationships.has(relationship) ||
        (validatingParticipants.get(participantId) ?? 0) >= limits.participantValidations) continue;
      const members = [...queued].filter(connection =>
        connection.credential === first.credential &&
        connection.subscription?.requestId === subscription.requestId &&
        connection.subscription.conversationId === subscription.conversationId);
      const batch = { members: new Set(members), abort: new AbortController() };
      const snapshots = members.map(connection => {
        queued.delete(connection);
        connection.validating = true;
        connection.batch = batch;
        const snapshot = { connection, generation: connection.generation, changed: connection.dirty };
        connection.dirty = false;
        return snapshot;
      });
      relationships.set(relationship, Infinity);
      validatingParticipants.set(participantId, (validatingParticipants.get(participantId) ?? 0) + 1);
      validationCount++;
      // Snapshot membership before beginning the transaction: later arrivals
      // never inherit a decision. Exact credentials include authority version.
      void authorized(signal => authority.authorizeSubscription(
        credential, subscription.requestId, subscription.conversationId, signal
      ), batch.abort.signal, () => {
        validationCount--;
        const count = validatingParticipants.get(participantId)! - 1;
        if (count) validatingParticipants.set(participantId, count); else validatingParticipants.delete(participantId);
        if (stopped) relationships.delete(relationship);
        else relationships.set(relationship, Date.now() + limits.relationshipIntervalMs);
        kick();
      }).then(() => {
        for (const { connection, generation, changed } of snapshots) {
          if (stopped || !connections.has(connection) || generation !== connection.generation) continue;
          if (!connection.subscribed) {
            connection.subscribed = true;
            if (!send(connection, { type: "subscribed", subscription: connection.subscription!.reference })) continue;
          }
          if (changed) send(connection, { type: "changed", subscription: connection.subscription!.reference });
        }
      }, () => {
        for (const { connection } of snapshots) refuse(connection);
      }).finally(() => {
        for (const { connection } of snapshots) {
          connection.validating = false;
          connection.batch = undefined;
          if (connection.dirty && connections.has(connection)) validate(connection);
        }
      });
    }
    // Cooldown keys only outlive their operation by 100ms; the connection bound
    // also bounds this map. No authorization decision is cached.
    if (!queued.size && relationships.size && !scheduler && !stopped) {
      scheduler = setTimeout(pump, limits.relationshipIntervalMs);
    }
    schedule();
  }

  function pulse(connection: Connection) {
    if (!connections.has(connection)) return;
    if (!connection.pong || connection.socket.bufferedAmount > limits.bufferedBytes) {
      refuse(connection);
      return;
    }
    connection.pong = false;
    connection.socket.ping();
    if (connection.subscribed) validate(connection);
    later(connection, () => pulse(connection), limits.intervalMs);
  }

  function control(connection: Connection): boolean {
    const now = Date.now();
    connection.controls = connection.controls.filter(time => now - time < limits.windowMs);
    if (connection.controls.length >= limits.controlFrames) {
      refuse(connection);
      return false;
    }
    connection.controls.push(now);
    return true;
  }

  function accept(socket: WebSocket, credential: string, participantId: string) {
    const connection: Connection = {
      socket, credential, participantId, generation: 0, subscribed: false, dirty: false,
      validating: false, pong: true, controls: [], timers: new Set(),
    };
    connections.add(connection);
    peers.add(socket);
    participants.set(participantId, (participants.get(participantId) ?? 0) + 1);
    const subscriptionTimer = later(connection, () => refuse(connection), limits.subscriptionMs);
    later(connection, () => refuse(connection), limits.lifetimeMs);
    later(connection, () => pulse(connection), limits.intervalMs);
    socket.on("error", () => { clean(connection); socket.terminate(); });
    socket.on("close", () => {
      clean(connection);
      peers.delete(socket);
      clearTimeout(refusals.get(socket));
      refusals.delete(socket);
    });
    socket.on("ping", data => { if (control(connection)) socket.pong(data); });
    socket.on("pong", () => { if (control(connection)) connection.pong = true; });
    socket.on("message", (data, binary) => {
      if (binary || connection.subscription || !connections.has(connection)) return refuse(connection);
      let frame: unknown;
      try { frame = JSON.parse(data.toString()); } catch { return refuse(connection); }
      if (!frame || typeof frame !== "object" || Array.isArray(frame)) return refuse(connection);
      const fields = frame as Record<string, unknown>;
      if (Object.keys(fields).sort().join(",") !== "conversationId,requestId,type" ||
        fields.type !== "subscribe" || typeof fields.requestId !== "string" ||
        typeof fields.conversationId !== "string" ||
        !/^[0-9a-f]{24}$/.test(fields.requestId) || !/^[0-9a-f]{24}$/.test(fields.conversationId)) {
        return refuse(connection);
      }
      clearTimeout(subscriptionTimer);
      connection.timers.delete(subscriptionTimer);
      if ((conversations.get(fields.conversationId) ?? 0) >= limits.conversationConnections) return refuse(connection);
      // Register provisionally before asynchronous authorization. No information
      // is disclosed until it succeeds; concurrent commits set the dirty bit.
      connection.subscription = {
        requestId: fields.requestId, conversationId: fields.conversationId, reference: randomUUID(),
      };
      conversations.set(fields.conversationId, (conversations.get(fields.conversationId) ?? 0) + 1);
      validate(connection);
    });
  }

  function rateAllowed(address: string) {
    const now = Date.now();
    for (const [key, attempts] of addresses) {
      const live = attempts.filter(time => now - time < limits.windowMs);
      if (live.length) addresses.set(key, live); else addresses.delete(key);
    }
    const attempts = addresses.get(address);
    if (!attempts && addresses.size >= limits.addressBuckets) return false;
    if (attempts && attempts.length >= limits.upgradeAttempts) return false;
    addresses.set(address, [...(attempts ?? []), now]);
    return true;
  }

  function reject(socket: Duplex) {
    if (!socket.destroyed) socket.end(
      "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Length: 11\r\n\r\nUnavailable"
    );
    socket.destroy();
  }

  function upgrade(request: IncomingMessage, socket: Duplex, head: Buffer) {
    const credential = request.headers[PARTICIPANT_AUTHORITY_HEADER];
    const count = request.rawHeaders.filter((_, index) =>
      index % 2 === 0 && request.rawHeaders[index].toLowerCase() === PARTICIPANT_AUTHORITY_HEADER).length;
    const headerBytes = request.rawHeaders.reduce((bytes, value) => bytes + Buffer.byteLength(value) + 4, 0);
    const key = request.headers["sec-websocket-key"];
    if (!rateAllowed(request.socket.remoteAddress ?? "") || stopped ||
      peers.size + upgrades.size >= limits.connections ||
      authCount >= limits.authorizations ||
      request.url !== MESSAGING_SOCKET_PATH || request.headers["sec-websocket-protocol"] !== undefined ||
      request.method !== "GET" || request.headers.upgrade?.toLowerCase() !== "websocket" ||
      request.headers["sec-websocket-version"] !== "13" ||
      typeof key !== "string" || !/^[+/0-9A-Za-z]{22}==$/.test(key) ||
      headerBytes > limits.headerBytes || head.length > limits.frameBytes ||
      count !== 1 || typeof credential !== "string" || credential.length > limits.frameBytes ||
      credential.trim() !== credential || !credential) {
      reject(socket);
      return;
    }
    const abort = new AbortController();
    upgrades.set(socket, abort);
    const closed = () => abort.abort();
    socket.once("close", closed);
    socket.on("error", closed);
    const work = (async () => {
      try {
        const result = await authorized(() => resolveParticipantAuthority(request), abort.signal);
        if (!result.ok || stopped || abort.signal.aborted || socket.destroyed) return reject(socket);
        const participantId = result.participant.participantId;
        // Check and reserve synchronously after authentication. Concurrent
        // upgrades cannot pass the cap using the same pre-authentication count.
        if ((participants.get(participantId) ?? 0) >= limits.participantConnections) return reject(socket);
        wss.handleUpgrade(request, socket, head, ws => accept(ws, credential, participantId));
      } catch {
        reject(socket);
      } finally {
        upgrades.delete(socket);
        socket.removeListener("close", closed);
        socket.removeListener("error", closed);
      }
    })();
    // All failure paths above settle locally, including synchronous ws errors.
    void work;
  }

  server.on("upgrade", upgrade);
  processAttachment = attachment;
  const observer: MessagingObserver = {
    committed(key) {
      if (stopped || hints.size >= limits.pendingHints) return;
      hints.add(key);
      flush ??= setImmediate(() => {
        flush = undefined;
        const changed = new Set(hints);
        hints.clear();
        for (const connection of connections) {
          if (connection.subscription && changed.has(connection.subscription.conversationId)) {
            connection.dirty = true;
            if (connection.subscribed) validate(connection);
          }
        }
      });
    },
  };

  return {
    observer,
    stats: () => ({
      connections: connections.size, upgrades: upgrades.size, authorizations: authCount,
      addressBuckets: addresses.size, pendingHints: hints.size,
      queuedValidations: queued.size, validations: validationCount,
    }),
    async drainAuthorizations(): Promise<void> {
      if (!stopped) throw new Error("Dispose before draining");
      while (pending.size) await Promise.all([...pending]);
      await disposePromise;
      if (processAttachment === attachment) processAttachment = undefined;
    },
    dispose(): Promise<{ pendingAuthorizations: number }> {
      disposePromise ??= (async () => {
        stopped = true;
        server.removeListener("upgrade", upgrade);
        if (flush) clearImmediate(flush);
        if (scheduler) clearTimeout(scheduler);
        queued.clear();
        relationships.clear();
        for (const timer of refusals.values()) clearTimeout(timer);
        refusals.clear();
        hints.clear();
        addresses.clear();
        for (const [socket, abort] of upgrades) { abort.abort(); socket.destroy(); }
        upgrades.clear();
        const sockets = [...peers];
        for (const connection of [...connections]) {
          clean(connection);
          connection.socket.close(1001);
        }
        let timeout: ReturnType<typeof setTimeout> | undefined;
        const closed = Promise.all(sockets.map(socket => socket.readyState === WebSocket.CLOSED
          ? Promise.resolve() : new Promise<void>(resolve => socket.once("close", resolve))));
        await Promise.race([
          Promise.all([closed, ...pending]),
          new Promise<void>(resolve => { timeout = setTimeout(resolve, limits.shutdownMs); }),
        ]);
        if (timeout) clearTimeout(timeout);
        for (const socket of sockets) if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
        wss.close();
        // Driver cancellation is cooperative, not promised. Outstanding work
        // retains its concurrency slot and can never send after disposal.
        if (authCount === 0 && processAttachment === attachment) processAttachment = undefined;
        return { pendingAuthorizations: authCount };
      })();
      return disposePromise;
    },
  };
}
