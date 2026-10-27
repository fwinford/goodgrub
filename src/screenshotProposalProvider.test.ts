import { describe, expect, it, vi } from "vitest";
import { callScreenshotProvider } from "./screenshotProposalProvider.js";

function jsonResponse(content: unknown, init: { ok?: boolean; status?: number } = {}) {
  return {
    ok: init.ok ?? true,
    status: init.status ?? 200,
    json: async () => ({ choices: [{ message: { content: JSON.stringify(content) } }] }),
  } as Response;
}

describe("callScreenshotProvider", () => {
  it("parses a well-formed structured response", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      jsonResponse({
        visibleVenueText: "Palladium",
        foodItems: [],
        mealSwipes: null,
      })
    );
    const result = await callScreenshotProvider({
      images: [{ imageBase64: "aGVsbG8=", mimeType: "image/png" }],
      apiKey: "test-key",
      timeoutMs: 5000,
      fetchImpl,
    });
    expect(result.ok).toBe(true);
    expect(result.rawJson).toEqual({
      visibleVenueText: "Palladium",
      foodItems: [],
      mealSwipes: null,
    });
    // The image never travels anywhere but the one request body this test
    // inspects; the API key never leaves the Authorization header.
    const [, init] = fetchImpl.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer test-key"
    );
  });

  it("classifies a 401/403 as auth", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      jsonResponse({}, { ok: false, status: 401 })
    );
    const result = await callScreenshotProvider({
      images: [{ imageBase64: "aGVsbG8=", mimeType: "image/png" }],
      apiKey: "bad-key",
      timeoutMs: 5000,
      fetchImpl,
    });
    expect(result).toEqual({ ok: false, httpStatus: 401, errorKind: "auth" });
  });

  it("classifies a 429 as rate_limit", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      jsonResponse({}, { ok: false, status: 429 })
    );
    const result = await callScreenshotProvider({
      images: [{ imageBase64: "aGVsbG8=", mimeType: "image/png" }],
      apiKey: "test-key",
      timeoutMs: 5000,
      fetchImpl,
    });
    expect(result).toEqual({ ok: false, httpStatus: 429, errorKind: "rate_limit" });
  });

  it("classifies a 500 as server", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      jsonResponse({}, { ok: false, status: 500 })
    );
    const result = await callScreenshotProvider({
      images: [{ imageBase64: "aGVsbG8=", mimeType: "image/png" }],
      apiKey: "test-key",
      timeoutMs: 5000,
      fetchImpl,
    });
    expect(result).toEqual({ ok: false, httpStatus: 500, errorKind: "server" });
  });

  it("classifies malformed JSON content as a parse failure", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ choices: [{ message: { content: "not json" } }] }),
    } as Response);
    const result = await callScreenshotProvider({
      images: [{ imageBase64: "aGVsbG8=", mimeType: "image/png" }],
      apiKey: "test-key",
      timeoutMs: 5000,
      fetchImpl,
    });
    expect(result).toEqual({ ok: false, errorKind: "parse" });
  });

  it("classifies an abort past the finite timeout as timeout", async () => {
    const fetchImpl = vi.fn().mockImplementation((_url: string, init: RequestInit) => {
      return new Promise((_resolve, reject) => {
        init.signal?.addEventListener("abort", () => {
          const error = new Error("aborted");
          error.name = "AbortError";
          reject(error);
        });
      });
    });
    const result = await callScreenshotProvider({
      images: [{ imageBase64: "aGVsbG8=", mimeType: "image/png" }],
      apiKey: "test-key",
      timeoutMs: 10,
      fetchImpl,
    });
    expect(result).toEqual({ ok: false, errorKind: "timeout" });
  });

  it("classifies an unexpected transport rejection as unknown", async () => {
    const fetchImpl = vi.fn().mockRejectedValue(new Error("network down"));
    const result = await callScreenshotProvider({
      images: [{ imageBase64: "aGVsbG8=", mimeType: "image/png" }],
      apiKey: "test-key",
      timeoutMs: 5000,
      fetchImpl,
    });
    expect(result).toEqual({ ok: false, errorKind: "unknown" });
  });
});
