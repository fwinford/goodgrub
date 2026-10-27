import http from "node:http";
import { connect } from "node:net";
import { networkInterfaces } from "node:os";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { startLocalMailSink, type LocalMailSink } from "./local-mail-sink.js";

function request(
  sink: LocalMailSink,
  options: { method?: string; path: string; headers?: Record<string, string>; body?: string }
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const outgoing = http.request(
      {
        host: "127.0.0.1",
        port: sink.port,
        method: options.method ?? "GET",
        path: options.path,
        headers: options.headers,
      },
      (response) => {
        let body = "";
        response.on("data", (chunk) => (body += chunk));
        response.on("end", () => resolve({ status: response.statusCode ?? 0, body }));
      }
    );
    outgoing.on("error", reject);
    outgoing.end(options.body);
  });
}

// `http.request` refuses to emit some request targets, so malformed ones are
// written to the socket directly.
function rawRequest(sink: LocalMailSink, text: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const socket = connect({ host: "127.0.0.1", port: sink.port });
    let received = "";
    socket.on("data", (chunk) => (received += chunk));
    socket.on("error", reject);
    socket.on("close", () => {
      const status = Number(/^HTTP\/1\.1 (\d{3})/.exec(received)?.[1] ?? 0);
      // The reply may be chunk-framed; the sink only ever answers one JSON object.
      resolve({ status, body: received.slice(received.indexOf("{"), received.lastIndexOf("}") + 1) });
    });
    socket.write(text);
  });
}

const postEmail = (sink: LocalMailSink, payload: unknown) =>
  request(sink, {
    method: "POST",
    path: "/emails",
    headers: { "Content-Type": "application/json", Authorization: "Bearer re_local_qa_fake" },
    body: JSON.stringify(payload),
  });

const latestCode = (sink: LocalMailSink, to: string) =>
  request(sink, { path: `/latest-code?to=${encodeURIComponent(to)}` });

const latestDeletionCode = (sink: LocalMailSink, to: string) =>
  request(sink, { path: `/latest-deletion-code?to=${encodeURIComponent(to)}` });

describe("W4-QA1 local verification mail sink", () => {
  let sink: LocalMailSink;
  let log: ReturnType<typeof vi.spyOn>;
  let clock = 1_000_000;

  beforeEach(async () => {
    clock = 1_000_000;
    log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    sink = await startLocalMailSink({ now: () => clock });
  });

  afterEach(async () => {
    await sink.close();
    log.mockRestore();
    vi.unstubAllEnvs();
  });

  it("binds only the loopback interface", async () => {
    expect(sink.host).toBe("127.0.0.1");
    // Where the machine has a non-loopback address, nothing answers there.
    const external = Object.values(networkInterfaces())
      .flat()
      .find((entry) => entry && entry.family === "IPv4" && !entry.internal);
    if (!external) return;
    const refused = await new Promise<boolean>((resolve) => {
      const socket = connect({ host: external.address, port: sink.port });
      socket.once("connect", () => {
        socket.destroy();
        resolve(false);
      });
      socket.once("error", () => resolve(true));
    });
    expect(refused).toBe(true);
  });

  it("round-trips real verification and deletion sends through the Resend SDK", async () => {
    vi.stubEnv("RESEND_BASE_URL", `http://127.0.0.1:${sink.port}`);
    vi.stubEnv("RESEND_API_KEY", "re_local_qa_fake");
    vi.resetModules();
    const {
      sendParticipantVerificationEmail,
      sendParticipantDeletionChallengeEmail,
    } = await import("../src/emailHelpers.js");

    await sendParticipantVerificationEmail("Student@NYU.edu", "428193", 10);

    const result = await latestCode(sink, "student@nyu.edu");
    expect(result.status).toBe(200);
    // Exactly the recipient and the code, nothing else from the message.
    expect(JSON.parse(result.body)).toEqual({ to: "student@nyu.edu", code: "428193" });
    expect(result.body).not.toContain("expires");
    expect(result.body).not.toContain("CommonPlate verification code");

    await sendParticipantDeletionChallengeEmail("Student@NYU.edu", "731604", 10);

    const deletionResult = await latestDeletionCode(sink, "student@nyu.edu");
    expect(deletionResult.status).toBe(200);
    expect(JSON.parse(deletionResult.body)).toEqual({ to: "student@nyu.edu", code: "731604" });
    expect(deletionResult.body).not.toContain("expires");
    expect(deletionResult.body).not.toContain("account deletion code");
    expect(JSON.parse((await latestCode(sink, "student@nyu.edu")).body)).toEqual({
      to: "student@nyu.edu",
      code: "428193",
    });
  });

  it("keeps verification and deletion codes in separate purpose stores", async () => {
    await postEmail(sink, {
      to: "a@nyu.edu",
      subject: "123456 is your CommonPlate verification code",
    });
    await postEmail(sink, {
      to: "a@nyu.edu",
      subject: "654321 is your CommonPlate account deletion code",
    });

    expect(JSON.parse((await latestCode(sink, "a@nyu.edu")).body).code).toBe("123456");
    expect(JSON.parse((await latestDeletionCode(sink, "a@nyu.edu")).body).code).toBe("654321");
  });

  it("does not log deletion codes or expose them through unsupported mail", async () => {
    await postEmail(sink, {
      to: "a@nyu.edu",
      subject: "654321 is your CommonPlate account deletion code",
      text: "654321",
    });
    await postEmail(sink, {
      to: "a@nyu.edu",
      subject: "Other message",
      text: "secret-body-731604",
    });

    const logged = log.mock.calls.map((call: unknown[]) => call.join(" ")).join("\n");
    expect(logged).not.toContain("654321");
    expect(logged).not.toContain("731604");
    expect(logged).not.toContain("a@nyu.edu");
  });

  it("accepts the Resend-shaped request and answers with an id", async () => {
    const result = await postEmail(sink, {
      from: "CommonPlate <onboarding@resend.dev>",
      to: ["Name <a@nyu.edu>"],
      subject: "123456 is your CommonPlate verification code",
      html: "<p>x</p>",
      text: "x",
    });
    expect(result.status).toBe(200);
    expect(JSON.parse(result.body)).toEqual({ id: "local-mail-sink" });
    expect(JSON.parse((await latestCode(sink, "a@nyu.edu")).body).code).toBe("123456");
  });

  it("keeps only the newest code for an address", async () => {
    for (const code of ["111111", "222222"]) {
      await postEmail(sink, { to: "a@nyu.edu", subject: `${code} is your CommonPlate verification code` });
    }
    expect(JSON.parse((await latestCode(sink, "a@nyu.edu")).body).code).toBe("222222");
  });

  it("acknowledges but never stores, logs, or exposes any other message", async () => {
    const result = await postEmail(sink, {
      to: "a@nyu.edu",
      subject: "Confirm your CommonPlate subscription",
      html: "<a href='https://x/confirm?token=SECRET-TOKEN'>confirm</a>",
      text: "https://x/confirm?token=SECRET-TOKEN",
    });
    expect(result.status).toBe(200);
    expect((await latestCode(sink, "a@nyu.edu")).status).toBe(404);
    const logged = log.mock.calls.map((call: unknown[]) => call.join(" ")).join("\n");
    expect(logged).not.toContain("SECRET-TOKEN");
    expect(logged).not.toContain("a@nyu.edu");
  });

  it("does not treat a code-shaped subject with extra text as a verification message", async () => {
    await postEmail(sink, { to: "a@nyu.edu", subject: "123456 is your CommonPlate verification code, plus more" });
    await postEmail(sink, { to: "a@nyu.edu", subject: "Re: 123456 is your CommonPlate verification code" });
    await postEmail(sink, { to: "a@nyu.edu", subject: "123456 is your CommonPlate account deletion code, plus more" });
    await postEmail(sink, { to: "a@nyu.edu", subject: "Re: 123456 is your CommonPlate account deletion code" });
    expect((await latestCode(sink, "a@nyu.edu")).status).toBe(404);
    expect((await latestDeletionCode(sink, "a@nyu.edu")).status).toBe(404);
  });

  it("does not reveal one address's code through another", async () => {
    await postEmail(sink, { to: "a@nyu.edu", subject: "123456 is your CommonPlate verification code" });
    expect((await latestCode(sink, "b@nyu.edu")).status).toBe(404);
    expect((await request(sink, { path: "/latest-code" })).status).toBe(404);
    await postEmail(sink, { to: "a@nyu.edu", subject: "123456 is your CommonPlate account deletion code" });
    expect((await latestDeletionCode(sink, "b@nyu.edu")).status).toBe(404);
    expect((await request(sink, { path: "/latest-deletion-code" })).status).toBe(404);
  });

  it("forgets a code after its lifetime", async () => {
    await postEmail(sink, { to: "a@nyu.edu", subject: "123456 is your CommonPlate verification code" });
    clock += 10 * 60 * 1000 + 1;
    expect((await latestCode(sink, "a@nyu.edu")).status).toBe(404);
  });

  it("forgets deletion codes after their lifetime", async () => {
    await postEmail(sink, {
      to: "a@nyu.edu",
      subject: "123456 is your CommonPlate account deletion code",
    });
    clock += 10 * 60 * 1000 + 1;
    expect((await latestDeletionCode(sink, "a@nyu.edu")).status).toBe(404);
  });

  it("remembers a bounded number of addresses", async () => {
    for (let index = 0; index < 25; index++) {
      await postEmail(sink, { to: `user${index}@nyu.edu`, subject: "123456 is your CommonPlate verification code" });
    }
    expect((await latestCode(sink, "user0@nyu.edu")).status).toBe(404);
    expect((await latestCode(sink, "user24@nyu.edu")).status).toBe(200);
  });

  it("refuses a request addressed to a non-loopback host name", async () => {
    await postEmail(sink, { to: "a@nyu.edu", subject: "123456 is your CommonPlate verification code" });
    const result = await request(sink, {
      path: "/latest-code?to=a%40nyu.edu",
      headers: { Host: "attacker.example" },
    });
    expect(result.status).toBe(403);
    expect(result.body).not.toContain("123456");

    await postEmail(sink, {
      to: "a@nyu.edu",
      subject: "654321 is your CommonPlate account deletion code",
    });
    const deletionResult = await request(sink, {
      path: `/latest-deletion-code?to=${encodeURIComponent("a@nyu.edu")}`,
      headers: { Host: "attacker.example" },
    });
    expect(deletionResult.status).toBe(403);
    expect(deletionResult.body).not.toContain("654321");
  });

  it("exposes no other route and no way to list or authenticate", async () => {
    for (const [method, path] of [
      ["GET", "/emails"],
      ["POST", "/latest-code"],
      ["GET", "/"],
      ["GET", "/codes"],
      ["POST", "/api/participant/verify"],
      ["DELETE", "/emails"],
    ] as const) {
      expect((await request(sink, { method, path })).status).toBe(404);
    }
  });

  it("rejects malformed or oversized bodies without storing anything", async () => {
    expect(
      (await request(sink, { method: "POST", path: "/emails", body: "not json" })).status
    ).toBe(422);
    const oversized = await request(sink, {
      method: "POST",
      path: "/emails",
      body: JSON.stringify({ to: "a@nyu.edu", subject: "x", html: "y".repeat(80 * 1024) }),
    }).catch(() => ({ status: 413, body: "" }));
    expect(oversized.status).toBe(413);
    expect((await latestCode(sink, "a@nyu.edu")).status).toBe(404);
  });

  describe("containment of invalid requests", () => {
    const verification = { to: "a@nyu.edu", subject: "654321 is your CommonPlate verification code" };

    const expectStillServing = async () => {
      expect((await postEmail(sink, verification)).status).toBe(200);
      expect(JSON.parse((await latestCode(sink, "a@nyu.edu")).body)).toEqual({
        to: "a@nyu.edu",
        code: "654321",
      });
    };

    it.each([
      ["null", "null"],
      ["a number", "42"],
      ["a string", '"subject"'],
      ["a boolean", "true"],
      ["an array", '[{"to":"a@nyu.edu","subject":"654321 is your CommonPlate verification code"}]'],
    ])("answers a sanitized 422 for valid JSON that is %s, and stays up", async (_label, body) => {
      const result = await request(sink, {
        method: "POST",
        path: "/emails",
        headers: { "Content-Type": "application/json" },
        body,
      });
      expect(result.status).toBe(422);
      expect(JSON.parse(result.body)).toEqual({ name: "validation_error", message: "invalid payload" });
      // Nothing was remembered from a rejected payload, even an array that wraps a code.
      expect((await latestCode(sink, "a@nyu.edu")).status).toBe(404);
      await expectStillServing();
    });

    // Each of these makes `new URL(target, base)` throw (an empty or invalid authority).
    it.each(["//", "//:80", "//[", "//?to=a@nyu.edu"])(
      "answers a sanitized 400 for the malformed request target %s, and stays up",
      async (target) => {
        for (const method of ["GET", "POST"]) {
          const result = await rawRequest(
            sink,
            `${method} ${target} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`
          );
          expect(result.status).toBe(400);
          expect(JSON.parse(result.body)).toEqual({ error: "invalid request target" });
        }
        await expectStillServing();
      }
    );

    it("keeps serving a valid verification request after a run of malformed input", async () => {
      await request(sink, { method: "POST", path: "/emails", body: "null" });
      await rawRequest(sink, "GET // HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
      await request(sink, { method: "POST", path: "/emails", body: "not json" });
      await expectStillServing();
    });

    it("contains an unexpected handler failure as a fixed 500 without leaking detail", async () => {
      // JSON cannot produce a throwing accessor, so inject one: the handler's
      // next JSON.parse returns an object whose `subject` getter throws.
      const parse = vi.spyOn(JSON, "parse").mockImplementationOnce(() => ({
        get subject(): string {
          throw new Error("secret-detail-654321");
        },
      }));
      const result = await request(sink, { method: "POST", path: "/emails", body: "{}" });
      parse.mockRestore();
      expect(result.status).toBe(500);
      expect(result.body).toBe(JSON.stringify({ error: "internal error" }));
      expect(result.body).not.toContain("secret-detail");
      await expectStillServing();
    });
  });
});
