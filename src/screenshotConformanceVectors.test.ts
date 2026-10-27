import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  corroboratedMealSwipeCount,
  currentOrderTotalCents,
  evaluateEligibility,
  resolveMenuPath,
  type TotalGeometryEvidence,
} from "./screenshotEligibility.js";
import { validateProviderOutput } from "./screenshotProposalValidation.js";

/**
 * W4-S3 drift guard. `shared/screenshot-conformance-vectors.json` holds
 * synthetic cases that this backend implementation and the iOS on-device
 * validator (`ScreenshotConformanceVectorTests.swift`) must both satisfy
 * exactly, so the accepted fail-closed eligibility/validation rules cannot
 * silently diverge between the two. A vector changes only by deliberate edit
 * reviewed against both suites — never by regenerating expectations from one
 * side alone.
 */
interface Vectors {
  version: number;
  totalGeometry: Array<{
    id: string;
    evidenceTexts: string[];
    geometryEvidence: Array<TotalGeometryEvidence | null>;
    expected: { totalCents: number | null; menuPath: string | null; conflict: boolean };
  }>;
  eligibility: Array<{
    id: string;
    evidenceText: string;
    expected: { eligible: boolean; category: string | null };
  }>;
  mealSwipeCorroboration: Array<{
    id: string;
    evidenceText: string;
    expected: number | null;
  }>;
  menuPath: Array<{
    id: string;
    evidenceTexts: string[];
    expected: { menuPath: string | null; conflict: boolean };
  }>;
  providerOutput: Array<{
    id: string;
    raw: unknown;
    evidenceText: string;
    evidenceImageCount: number;
    /** W4-R4.1: each eligible screenshot's own evidence. Optional; when
     * absent the single `evidenceText` is one screenshot. */
    evidenceTexts?: string[];
    expected: unknown;
  }>;
}

const vectors = JSON.parse(
  readFileSync(
    new URL("../shared/screenshot-conformance-vectors.json", import.meta.url),
    "utf8"
  )
) as Vectors;

describe("screenshot conformance vectors (backend side)", () => {
  it("declares a known vector version", () => {
    expect(vectors.version).toBe(1);
    expect(vectors.totalGeometry.length).toBeGreaterThanOrEqual(6);
    expect(vectors.providerOutput.length).toBeGreaterThanOrEqual(113);
  });

  it.each(vectors.totalGeometry)("Total geometry: $id", (vector) => {
    const geometry = vector.geometryEvidence.map((item) => item ?? undefined);
    expect(currentOrderTotalCents(vector.evidenceTexts, true, geometry)).toBe(
      vector.expected.totalCents
    );
    expect(resolveMenuPath(vector.evidenceTexts, geometry)).toEqual({
      menuPath: vector.expected.menuPath,
      conflict: vector.expected.conflict,
    });
  });

  it.each(vectors.eligibility)("eligibility: $id", (vector) => {
    expect(evaluateEligibility(vector.evidenceText)).toEqual(vector.expected);
  });

  it.each(vectors.mealSwipeCorroboration)(
    "meal-swipe corroboration: $id",
    (vector) => {
      expect(corroboratedMealSwipeCount(vector.evidenceText)).toBe(
        vector.expected
      );
    }
  );

  it.each(vectors.menuPath)("menu path: $id", (vector) => {
    expect(resolveMenuPath(vector.evidenceTexts)).toEqual(vector.expected);
  });

  it.each(vectors.providerOutput)("provider output: $id", (vector) => {
    if (vector.evidenceTexts) {
      // The combined text is always exactly the per-screenshot texts joined
      // the way the route and the on-device workflow join them.
      expect(vector.evidenceText).toBe(vector.evidenceTexts.join("\n"));
    }
    expect(
      validateProviderOutput(
        vector.raw,
        vector.evidenceText,
        vector.evidenceImageCount,
        vector.evidenceTexts
      )
    ).toEqual(vector.expected);
  });
});
