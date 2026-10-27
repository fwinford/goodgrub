import { describe, expect, it } from "vitest";
import {
  describeLegacyRequestData,
  isExpiresAtTtlIndex,
} from "./migrate-request-ttl-index.js";

describe("request TTL index migration targeting", () => {
  it("targets only a single-field expiresAt TTL index", () => {
    expect(
      isExpiresAtTtlIndex({
        name: "expiresAt_1",
        key: { expiresAt: 1 },
        expireAfterSeconds: 0,
      })
    ).toBe(true);
  });

  it.each<{
    name?: string;
    key?: Record<string, number>;
    expireAfterSeconds?: number;
  }>([
    { name: "_id_", key: { _id: 1 } },
    { name: "expiresAt_1", key: { expiresAt: 1 } },
    {
      name: "compound",
      key: { expiresAt: 1, status: 1 },
      expireAfterSeconds: 0,
    },
    {
      name: "deleteAt",
      key: { deleteAt: 1 },
      expireAfterSeconds: 0,
    },
  ])("does not target unrelated index $name", (index) => {
    expect(isExpiresAtTtlIndex(index)).toBe(false);
  });
});

describe("legacy request data refusal", () => {
  it("permits the migration only when both legacy counts are zero", () => {
    expect(describeLegacyRequestData(0, 0)).toBeNull();
  });

  it.each([
    { legacyStatusCount: 1, missingDeleteAtCount: 0 },
    { legacyStatusCount: 0, missingDeleteAtCount: 1 },
    { legacyStatusCount: 3, missingDeleteAtCount: 2 },
  ])(
    "refuses for $legacyStatusCount requested and $missingDeleteAtCount missing deleteAt",
    ({ legacyStatusCount, missingDeleteAtCount }) => {
      const refusal = describeLegacyRequestData(
        legacyStatusCount,
        missingDeleteAtCount
      );

      expect(refusal).toContain(`"requested": ${legacyStatusCount}`);
      expect(refusal).toContain(`deleteAt:        ${missingDeleteAtCount}`);
      // The operator must be told to clear rather than to backfill.
      expect(refusal).toMatch(/Clear them/);
      expect(refusal).toMatch(/not backfilled/);
      expect(refusal).toMatch(/No index was changed/);
    }
  );
});

