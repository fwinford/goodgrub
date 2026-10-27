import type { Types } from "mongoose";
import type { IReportRequestSnapshot } from "../models/moderation.js";

/**
 * The Decision 7 request-evidence allowlist.
 *
 * Only reported request content and the minimum interaction context survive:
 * what was asked for, where, the requester-stated window, and the role of the
 * reported party. Everything else on a Request is dropped by construction,
 * because this builds a new object from named fields rather than copying one:
 * emails (requester and fulfiller), participant IDs, order numbers, ETAs,
 * claim tokens and digests, installation IDs, screenshots, contact data, the
 * moderation markers, and any helper Message (which is never persisted at all).
 */
export interface ReportableRequestFields {
  _id: Types.ObjectId | string;
  status: "open" | "claimed" | "placed";
  vendor?: unknown;
  food?: unknown;
  pickupWindowText?: unknown;
  menuPath?: unknown;
  mealSwipes?: unknown;
  mealItems?: unknown;
  orderDetails?: unknown;
  estimatedDiningDollarsCents?: unknown;
  [other: string]: unknown;
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value !== "" ? value : undefined;
}

function integer(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) ? value : undefined;
}

export function buildReportRequestSnapshot(
  request: ReportableRequestFields,
  reportedRole: "requester" | "helper"
): IReportRequestSnapshot {
  const mealItems = Array.isArray(request.mealItems)
    ? request.mealItems
        .map((item: unknown) => {
          const entry = item as { name?: unknown; details?: unknown } | null;
          const name = text(entry?.name);
          if (!name) return null;
          const details = text(entry?.details);
          return details ? { name, details } : { name };
        })
        .filter((item): item is { name: string; details?: string } => item !== null)
    : undefined;

  return {
    requestId: request._id as Types.ObjectId,
    reportedRole,
    requestStatus: request.status,
    vendor: text(request.vendor),
    food: text(request.food),
    pickupWindowText: text(request.pickupWindowText),
    menuPath: text(request.menuPath),
    mealSwipes: integer(request.mealSwipes),
    mealItems: mealItems && mealItems.length > 0 ? mealItems : undefined,
    orderDetails: text(request.orderDetails),
    estimatedDiningDollarsCents: integer(request.estimatedDiningDollarsCents),
  };
}
