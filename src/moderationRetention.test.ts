import { describe, expect, it } from "vitest";
import {
  DAY_MS,
  HOLD_REVIEW_INTERVAL_MAX_MS,
  REPORT_CAP_WINDOW_MS,
  REPORT_EVIDENCE_RETENTION_MS,
  REPORT_LEDGER_RETENTION_MS,
  REPORT_LEDGER_RETENTION_SECONDS,
  REPORT_MINT_SKEW_TOLERANCE_MS,
  REPORT_OUTCOMES,
  REPORT_REASONS,
  REPORT_SUBMISSION_WINDOW_MS,
  RETENTION_SWEEP_GRACE_MS,
  RETENTION_SWEEP_STALE_MS,
} from "./moderationConstants.js";
import {
  HELD,
  addYearsUtc,
  computeRetentionClocks,
  evidenceDeadline,
  historyDeadline,
  isPastDeleteAt,
  notPastDeleteAt,
  retentionAnchor,
} from "./moderationRetention.js";

const at = (iso: string) => new Date(iso);

describe("approved constants", () => {
  it("fixes the approved deadlines and counts", () => {
    expect(REPORT_EVIDENCE_RETENTION_MS).toBe(90 * DAY_MS);
    expect(REPORT_REASONS).toEqual([
      "Harassment or hateful behavior",
      "Sexual or inappropriate content",
      "Threats or unsafe behavior",
      "Spam or misuse of CommonPlate",
      "Other concern",
    ]);
    expect(REPORT_OUTCOMES).toHaveLength(4);
    expect(HOLD_REVIEW_INTERVAL_MAX_MS).toBe(90 * DAY_MS);
    expect(RETENTION_SWEEP_GRACE_MS).toBe(60 * 60 * 1000);
    expect(RETENTION_SWEEP_STALE_MS).toBe(3 * 60 * 60 * 1000);
  });

  it("keeps W plus the skew bound strictly under R with a margin far above TTL lag", () => {
    expect(REPORT_SUBMISSION_WINDOW_MS).toBe(24 * 60 * 60 * 1000);
    expect(REPORT_LEDGER_RETENTION_MS).toBe(48 * 60 * 60 * 1000);
    expect(REPORT_LEDGER_RETENTION_SECONDS).toBe(172_800);
    const margin =
      REPORT_LEDGER_RETENTION_MS - REPORT_SUBMISSION_WINDOW_MS - REPORT_MINT_SKEW_TOLERANCE_MS;
    expect(margin).toBeGreaterThan(0);
    // The TTL monitor runs about every 60 seconds; the margin dwarfs that lag.
    expect(margin).toBeGreaterThan(23 * 60 * 60 * 1000);
    expect(REPORT_CAP_WINDOW_MS).toBeLessThan(REPORT_LEDGER_RETENTION_MS);
  });
});

describe("retention anchor", () => {
  it("is closedAt for a closed case with no suspension", () => {
    expect(retentionAnchor({ closedAt: at("2026-01-10T00:00:00Z") })).toEqual(
      at("2026-01-10T00:00:00Z")
    );
  });

  it("is liftedAt for a manual suspension", () => {
    expect(retentionAnchor({ liftedAt: at("2026-02-01T00:00:00Z") })).toEqual(
      at("2026-02-01T00:00:00Z")
    );
  });

  it("is the later of closedAt and liftedAt for a report-linked suspension", () => {
    const closedAt = at("2026-01-10T00:00:00Z");
    const liftedAt = at("2026-03-01T00:00:00Z");
    expect(retentionAnchor({ closedAt, liftedAt })).toEqual(liftedAt);
    expect(retentionAnchor({ closedAt: liftedAt, liftedAt: closedAt })).toEqual(liftedAt);
  });

  it("is absent until an end exists", () => {
    expect(retentionAnchor({})).toBeNull();
  });
});

describe("the one formula", () => {
  const anchor = at("2026-01-10T12:00:00Z");

  it("puts evidence at anchor + 90 days and history at anchor + one calendar year", () => {
    expect(evidenceDeadline(anchor, null)).toEqual(at("2026-04-10T12:00:00Z"));
    expect(historyDeadline(anchor, null)).toEqual(at("2027-01-10T12:00:00Z"));
  });

  it("measures one year as a calendar year across a leap day, not as 365 days", () => {
    expect(addYearsUtc(at("2027-03-01T00:00:00Z"), 1)).toEqual(at("2028-03-01T00:00:00Z"));
    expect(historyDeadline(at("2027-02-28T00:00:00Z"), null)).toEqual(
      at("2028-02-28T00:00:00Z")
    );
    // 365 days from 2027-03-01 would be 2028-02-29: the calendar rule is 03-01.
    expect(at("2027-03-01T00:00:00Z").getTime() + 365 * DAY_MS).not.toBe(
      addYearsUtc(at("2027-03-01T00:00:00Z"), 1).getTime()
    );
  });

  describe("February 29 anchors (Week HQ F7 rule: clamp to February 28, never March 1)", () => {
    it("clamps to February 28 at the same UTC clock time in a non-leap year", () => {
      expect(addYearsUtc(at("2028-02-29T12:00:00Z"), 1)).toEqual(at("2029-02-28T12:00:00Z"));
      expect(historyDeadline(at("2028-02-29T12:00:00Z"), null)).toEqual(at("2029-02-28T12:00:00Z"));
    });

    it("preserves the full UTC time of day, including seconds and milliseconds", () => {
      expect(addYearsUtc(at("2024-02-29T23:59:59.999Z"), 1)).toEqual(at("2025-02-28T23:59:59.999Z"));
      expect(addYearsUtc(at("2096-02-29T00:00:00.000Z"), 1)).toEqual(at("2097-02-28T00:00:00.000Z"));
    });

    it("is never March 1", () => {
      for (const year of [2024, 2028, 2032, 2096]) {
        const result = addYearsUtc(new Date(Date.UTC(year, 1, 29, 7, 30)), 1);
        expect([result.getUTCMonth(), result.getUTCDate()]).toEqual([1, 28]);
      }
    });

    it("maps a February 29 anchor to February 29 when the target year is also a leap year", () => {
      expect(addYearsUtc(at("2024-02-29T12:00:00Z"), 4)).toEqual(at("2028-02-29T12:00:00Z"));
      // 2100 is not a leap year (century rule): the clamp applies.
      expect(addYearsUtc(at("2096-02-29T12:00:00Z"), 4)).toEqual(at("2100-02-28T12:00:00Z"));
    });

    it("leaves ordinary anniversaries and neighbouring dates unchanged", () => {
      expect(addYearsUtc(at("2028-02-28T12:00:00Z"), 1)).toEqual(at("2029-02-28T12:00:00Z"));
      expect(addYearsUtc(at("2028-03-01T12:00:00Z"), 1)).toEqual(at("2029-03-01T12:00:00Z"));
      expect(addYearsUtc(at("2027-02-28T12:00:00Z"), 1)).toEqual(at("2028-02-28T12:00:00Z"));
      expect(addYearsUtc(at("2026-10-18T14:05:09.123Z"), 1)).toEqual(at("2027-10-18T14:05:09.123Z"));
      expect(addYearsUtc(at("2026-12-31T23:59:59Z"), 1)).toEqual(at("2027-12-31T23:59:59Z"));
      expect(addYearsUtc(at("2026-01-31T00:00:00Z"), 1)).toEqual(at("2027-01-31T00:00:00Z"));
    });

    it("keeps the 90-day evidence deadline fixed-duration, separate from the calendar rule", () => {
      const anchor = at("2028-02-29T12:00:00Z");
      expect(evidenceDeadline(anchor, null)).toEqual(new Date(anchor.getTime() + 90 * DAY_MS));
      expect(evidenceDeadline(anchor, null)).toEqual(at("2028-05-29T12:00:00Z"));
      expect(historyDeadline(anchor, null)).toEqual(at("2029-02-28T12:00:00Z"));
    });

    it("applies hold-end maxima unchanged to a clamped history deadline", () => {
      const anchor = at("2028-02-29T12:00:00Z");
      const laterHold = at("2029-06-01T00:00:00Z");
      const earlierHold = at("2028-09-01T00:00:00Z");
      expect(historyDeadline(anchor, laterHold)).toEqual(laterHold);
      expect(historyDeadline(anchor, earlierHold)).toEqual(at("2029-02-28T12:00:00Z"));
      // A hold ending exactly on the clamped date changes nothing.
      expect(historyDeadline(anchor, at("2029-02-28T12:00:00Z"))).toEqual(at("2029-02-28T12:00:00Z"));
      // And a hold end past the 90-day evidence deadline still extends only evidence.
      expect(evidenceDeadline(anchor, at("2028-08-01T00:00:00Z"))).toEqual(at("2028-08-01T00:00:00Z"));
    });

    it("yields no deadline for a February 29 anchor while an active suspension holds it", () => {
      const closedAt = at("2028-02-29T12:00:00Z");
      expect(computeRetentionClocks({ ended: true, heldByLiveState: true, closedAt })).toEqual(HELD);
      expect(computeRetentionClocks({ ended: true, heldByLiveState: false, closedAt })).toEqual({
        evidenceDeleteAt: at("2028-05-29T12:00:00Z"),
        historyDeleteAt: at("2029-02-28T12:00:00Z"),
      });
    });

    it("uses the later of closure and reinstatement as the anchor before clamping", () => {
      expect(
        computeRetentionClocks({
          ended: true,
          heldByLiveState: false,
          closedAt: at("2027-06-01T00:00:00Z"),
          liftedAt: at("2028-02-29T00:00:00Z"),
        }).historyDeleteAt
      ).toEqual(at("2029-02-28T00:00:00Z"));
    });
  });

  it("makes deletion due at a later hold end, not a fresh period", () => {
    const holdEnd = at("2026-06-01T00:00:00Z");
    expect(evidenceDeadline(anchor, holdEnd)).toEqual(holdEnd);
    expect(historyDeadline(anchor, holdEnd)).toEqual(at("2027-01-10T12:00:00Z"));
  });

  it("ignores a hold that ended before the base deadline", () => {
    const holdEnd = at("2026-02-01T00:00:00Z");
    expect(evidenceDeadline(anchor, holdEnd)).toEqual(at("2026-04-10T12:00:00Z"));
  });

  it("is due immediately when a hold is released long after the base deadline", () => {
    const holdEnd = at("2028-01-01T00:00:00Z");
    expect(evidenceDeadline(anchor, holdEnd)).toEqual(holdEnd);
    expect(historyDeadline(anchor, holdEnd)).toEqual(holdEnd);
  });
});

describe("computeRetentionClocks", () => {
  const closedAt = at("2026-01-10T00:00:00Z");

  it("holds everything while the record's own lifecycle is live", () => {
    expect(computeRetentionClocks({ ended: false, heldByLiveState: false, closedAt })).toEqual(
      HELD
    );
  });

  it("holds everything while another live reason applies", () => {
    expect(computeRetentionClocks({ ended: true, heldByLiveState: true, closedAt })).toEqual(HELD);
  });

  it("holds when ended but no anchor exists", () => {
    expect(computeRetentionClocks({ ended: true, heldByLiveState: false })).toEqual(HELD);
  });

  it("yields both deadlines once ended and unheld", () => {
    expect(computeRetentionClocks({ ended: true, heldByLiveState: false, closedAt })).toEqual({
      evidenceDeleteAt: at("2026-04-10T00:00:00Z"),
      historyDeleteAt: at("2027-01-10T00:00:00Z"),
    });
  });
});

describe("reads treat a past deleteAt as absent", () => {
  const now = at("2026-05-01T00:00:00Z");

  it("builds a filter that excludes only records past their deadline", () => {
    expect(notPastDeleteAt(now)).toEqual({
      $or: [{ deleteAt: { $exists: false } }, { deleteAt: { $gt: now } }],
    });
  });

  it("classifies a record in memory the same way", () => {
    expect(isPastDeleteAt({ deleteAt: at("2026-04-30T00:00:00Z") }, now)).toBe(true);
    expect(isPastDeleteAt({ deleteAt: now }, now)).toBe(true);
    expect(isPastDeleteAt({ deleteAt: at("2026-05-02T00:00:00Z") }, now)).toBe(false);
    expect(isPastDeleteAt({}, now)).toBe(false);
  });
});
