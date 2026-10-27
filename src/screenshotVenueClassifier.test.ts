import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { classifyScreenshotVenue } from "./screenshotVenueClassifier.js";

interface VenueVector {
  id: string;
  evidenceTexts: string[];
  expected: { kind: string; vendor?: string; key?: string; hasV1Observation: boolean };
}

const vectors = JSON.parse(readFileSync(
  new URL("../shared/screenshot-venue-vectors.json", import.meta.url), "utf8"
)) as { version: number; vectors: VenueVector[] };

describe("screenshot venue vectors (backend twin)", () => {
  it("pins its own versioned synthetic contract", () => {
    expect(vectors.version).toBe(1);
    expect(vectors.vectors.length).toBeGreaterThanOrEqual(20);
  });

  it.each(vectors.vectors)("$id", (vector) => {
    const { disposition: actual, hasV1Observation } = classifyScreenshotVenue(vector.evidenceTexts);
    expect(actual.kind).toBe(vector.expected.kind);
    expect(hasV1Observation).toBe(vector.expected.hasV1Observation);
    if (vector.expected.vendor) {
      expect(actual.kind === "supported" ? actual.vendor.name : undefined).toBe(vector.expected.vendor);
    }
    if (vector.expected.key) {
      expect(actual.kind === "unsupported" ? actual.key : undefined).toBe(vector.expected.key);
    }
  });
});
