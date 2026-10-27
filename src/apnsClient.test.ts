import http2 from "node:http2";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import {
  APNS_TIMEOUT_OUTCOME,
  classifyApnsError,
  classifyApnsResponse,
  openApnsConnection,
  sanitizedApnsId,
} from "./apnsClient.js";

/**
 * The classification table is the safety boundary of this slice: only the two
 * reasons Apple defines as "this token is dead" may retire an installation.
 * Everything below asserts that table directly, and then over a real local
 * HTTP/2 server — never Apple's service and never with real credentials.
 */
describe("APNs response classification", () => {
  it("treats 200 as an accepted submission and nothing more", () => {
    const outcome = classifyApnsResponse(200, "", "3ce8-4b25");

    expect(outcome.classification).toBe("accepted");
    expect(outcome.apnsId).toBe("3ce8-4b25");
    // "accepted" is the whole claim: no delivery, display, opening, or read.
    expect(JSON.stringify(outcome)).not.toMatch(
      /delivered|displayed|opened|read|received/i
    );
  });

  it.each([
    [410, '{"reason":"Unregistered"}', "Unregistered"],
    [400, '{"reason":"BadDeviceToken"}', "BadDeviceToken"],
  ])("treats %i %s as a terminal token rejection", (status, body, reason) => {
    const outcome = classifyApnsResponse(status, body);

    expect(outcome.classification).toBe("token-rejected");
    expect(outcome.reason).toBe(reason);
  });

  it("treats a 410 with an unreadable body as Unregistered", () => {
    expect(classifyApnsResponse(410, "not json").classification).toBe(
      "token-rejected"
    );
    expect(classifyApnsResponse(410, "not json").reason).toBe("Unregistered");
  });

  it.each([
    [400, '{"reason":"BadTopic"}'],
    [400, '{"reason":"DeviceTokenNotForTopic"}'],
    [400, '{"reason":"TopicDisallowed"}'],
    [400, '{"reason":"PayloadTooLarge"}'],
    [400, "{}"],
    [404, '{"reason":"BadPath"}'],
    [405, '{"reason":"MethodNotAllowed"}'],
    [413, '{"reason":"PayloadTooLarge"}'],
  ])("treats %i %s as a configuration failure that retires nothing", (status, body) => {
    // A topic or environment misconfiguration would otherwise retire every
    // installation's token in a single dispatch.
    expect(classifyApnsResponse(status, body).classification).toBe(
      "configuration"
    );
  });

  it.each([
    [401, '{"reason":"InvalidProviderToken"}'],
    [403, '{"reason":"ExpiredProviderToken"}'],
  ])("treats %i %s as a provider auth failure", (status, body) => {
    expect(classifyApnsResponse(status, body).classification).toBe(
      "provider-auth"
    );
  });

  it.each([
    [429, '{"reason":"TooManyRequests"}'],
    [500, '{"reason":"InternalServerError"}'],
    [503, '{"reason":"ServiceUnavailable"}'],
    [418, "{}"],
  ])("treats %i %s as transient", (status, body) => {
    expect(classifyApnsResponse(status, body).classification).toBe("transient");
  });

  it("never echoes an unbounded reason from a hostile body", () => {
    const hostile = JSON.stringify({
      reason: `bearer eyJ.${"A".repeat(4000)}`,
    });

    const outcome = classifyApnsResponse(400, hostile);

    expect(outcome.reason).toBe("Unknown");
    expect(outcome.classification).toBe("configuration");
  });

  it("ignores a malformed apns-id", () => {
    expect(sanitizedApnsId("8A2B-4C5D")).toBe("8A2B-4C5D");
    expect(sanitizedApnsId("has space")).toBeUndefined();
    expect(sanitizedApnsId("x".repeat(65))).toBeUndefined();
    expect(sanitizedApnsId(undefined)).toBeUndefined();
    expect(sanitizedApnsId(12)).toBeUndefined();
  });

  it("classifies a network failure by code alone", () => {
    expect(classifyApnsError({ code: "ECONNREFUSED" })).toEqual({
      classification: "transient",
      reason: "ECONNREFUSED",
    });
    // Nothing derived from the error object itself may reach an outcome: a
    // provider error can carry headers, tokens, URLs, and request bodies.
    const chatty = Object.assign(new Error("bearer eyJhbGciOi.secret"), {
      code: "not a code",
    });
    expect(classifyApnsError(chatty)).toEqual({
      classification: "transient",
      reason: "NetworkError",
    });
    expect(classifyApnsError(null).reason).toBe("NetworkError");
  });

  it("classifies a timeout as transient", () => {
    expect(APNS_TIMEOUT_OUTCOME).toEqual({
      classification: "transient",
      reason: "Timeout",
    });
  });
});

interface FakeApns {
  origin: string;
  requests: { path: string; headers: http2.IncomingHttpHeaders; body: string }[];
  close(): Promise<void>;
}

type Responder = (
  stream: http2.ServerHttp2Stream,
  headers: http2.IncomingHttpHeaders,
  body: string
) => void;

/**
 * A plaintext local HTTP/2 server standing in for APNs. No automated test may
 * require live APNs credentials or contact Apple's service.
 */
async function startFakeApns(respond: Responder): Promise<FakeApns> {
  const requests: FakeApns["requests"] = [];
  const server = http2.createServer();

  server.on("stream", (stream, headers) => {
    let body = "";
    stream.setEncoding("utf8");
    stream.on("data", (chunk: string) => {
      body += chunk;
    });
    stream.on("error", () => {
      // A cancelled stream is one of the cases under test.
    });
    stream.on("end", () => {
      requests.push({ path: String(headers[":path"]), headers, body });
      respond(stream, headers, body);
    });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;

  return {
    origin: `http://127.0.0.1:${port}`,
    requests,
    close() {
      return new Promise<void>((resolve) => {
        server.close(() => resolve());
      });
    },
  };
}

const submission = {
  deviceToken: "a".repeat(64),
  headers: {
    "apns-push-type": "alert",
    "apns-topic": "org.commonplatenyu.CommonPlateios",
    authorization: "bearer provider-token",
  },
  payload: JSON.stringify({ aps: { alert: { title: "t", body: "b" } } }),
};

describe("APNs submission over HTTP/2", () => {
  let apns: FakeApns | null = null;

  afterEach(async () => {
    await apns?.close();
    apns = null;
  });

  it("posts to the device path and reports an accepted submission", async () => {
    apns = await startFakeApns((stream) => {
      stream.respond({ ":status": 200, "apns-id": "1234-abcd" });
      stream.end();
    });
    const connection = openApnsConnection(apns.origin);

    const outcome = await connection.submit(submission, 5_000);
    connection.close();

    expect(outcome.classification).toBe("accepted");
    expect(outcome.apnsId).toBe("1234-abcd");
    expect(apns.requests[0].path).toBe(`/3/device/${submission.deviceToken}`);
    expect(apns.requests[0].headers["apns-topic"]).toBe(
      "org.commonplatenyu.CommonPlateios"
    );
    expect(apns.requests[0].body).toBe(submission.payload);
  });

  it.each([
    [410, '{"reason":"Unregistered"}', "token-rejected"],
    [400, '{"reason":"BadDeviceToken"}', "token-rejected"],
    [400, '{"reason":"BadTopic"}', "configuration"],
    [403, '{"reason":"ExpiredProviderToken"}', "provider-auth"],
    [429, '{"reason":"TooManyRequests"}', "transient"],
    [503, '{"reason":"ServiceUnavailable"}', "transient"],
  ] as const)("classifies a real %i response as %s", async (status, body, classification) => {
    apns = await startFakeApns((stream) => {
      stream.respond({ ":status": status });
      stream.end(body);
    });
    const connection = openApnsConnection(apns.origin);

    const outcome = await connection.submit(submission, 5_000);
    connection.close();

    expect(outcome.classification).toBe(classification);
    expect(outcome.status).toBe(status);
  });

  it("reports a timeout without rejecting", async () => {
    apns = await startFakeApns(() => {
      // Deliberately never answered.
    });
    const connection = openApnsConnection(apns.origin);

    const outcome = await connection.submit(submission, 150);
    connection.close();

    expect(outcome).toEqual(APNS_TIMEOUT_OUTCOME);
  });

  it("reports a connection failure without rejecting", async () => {
    // A closed port: the session errors before any stream can be answered.
    const connection = openApnsConnection("http://127.0.0.1:1");

    const outcome = await connection.submit(submission, 2_000);
    connection.close();

    expect(outcome.classification).toBe("transient");
    expect(outcome.reason).not.toContain(submission.headers.authorization);
  });

  it("reports a stream refused before any response without rejecting", async () => {
    apns = await startFakeApns((stream) => {
      stream.close(http2.constants.NGHTTP2_INTERNAL_ERROR);
    });
    const connection = openApnsConnection(apns.origin);

    const outcome = await connection.submit(submission, 5_000);
    connection.close();

    expect(outcome.classification).toBe("transient");
  });

  it("carries no token, key, or authorization value into an outcome", async () => {
    apns = await startFakeApns((stream) => {
      stream.respond({ ":status": 400 });
      stream.end('{"reason":"BadDeviceToken"}');
    });
    const connection = openApnsConnection(apns.origin);

    const outcome = await connection.submit(submission, 5_000);
    connection.close();

    const serialized = JSON.stringify(outcome);
    expect(serialized).not.toContain(submission.deviceToken);
    expect(serialized).not.toContain("bearer");
    expect(serialized).not.toContain("provider-token");
  });
});
