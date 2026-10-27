import { describe, expect, it } from "vitest";
import {
  REPORT_MINT_SKEW_TOLERANCE_MS,
  REPORT_SUBMISSION_WINDOW_MS,
} from "./moderationConstants.js";
import {
  classifyOperationWindow,
  parseReportOperationId,
} from "./reportSubmissionLedger.js";

const mint = (ms: number, entropy = "A".repeat(22)) => `rp1.${String(ms).padStart(13, "0")}.${entropy}`;
const now = new Date("2026-10-18T12:00:00Z");

describe("report operation identity", () => {
  it("embeds the client mint time", () => {
    const parsed = parseReportOperationId(mint(now.getTime()));
    expect(parsed?.mintedAt).toEqual(now);
  });

  it.each([
    undefined,
    null,
    42,
    "",
    "rp2.1760000000000." + "A".repeat(22),
    "rp1.176000000000." + "A".repeat(22),
    "rp1.17600000000000." + "A".repeat(22),
    "rp1.1760000000000.short",
    "rp1.1760000000000." + "A".repeat(65),
    "rp1.1760000000000.has space in entropy....",
    "x" + mint(now.getTime()),
    mint(now.getTime()) + "\n",
  ])("rejects %j", (value) => {
    expect(parseReportOperationId(value)).toBeNull();
  });
});

describe("submission window", () => {
  const minted = (offsetMs: number) => new Date(now.getTime() + offsetMs);

  it("is within W for a fresh mint", () => {
    expect(classifyOperationWindow(minted(0), now)).toBe("within");
    expect(classifyOperationWindow(minted(-(REPORT_SUBMISSION_WINDOW_MS - 1)), now)).toBe("within");
  });

  it("expires at W exactly", () => {
    expect(classifyOperationWindow(minted(-REPORT_SUBMISSION_WINDOW_MS), now)).toBe("expired");
    expect(classifyOperationWindow(minted(-REPORT_SUBMISSION_WINDOW_MS - 1), now)).toBe("expired");
  });

  it("tolerates small clock skew and refuses a mint further in the future", () => {
    expect(classifyOperationWindow(minted(REPORT_MINT_SKEW_TOLERANCE_MS), now)).toBe("within");
    expect(classifyOperationWindow(minted(REPORT_MINT_SKEW_TOLERANCE_MS + 1), now)).toBe("future");
  });
});
