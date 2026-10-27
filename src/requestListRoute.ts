import type { NextFunction, Request, Response } from "express";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";
import { buildParticipantFenceFilter } from "./participantBlocks.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  buildPublicRequestListResponse,
  type RequestListDocument,
} from "./requestListResponse.js";
import {
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS,
  ParticipantIdentityConfigurationError,
} from "./participantIdentityKeys.js";
import {
  filterRequestListForParticipant,
  ParticipantParticipationReadCancelled,
  requireVerifiedCallerForRead,
} from "./requestParticipation.js";

const PARTICIPATION_SCAN_PAGE_SIZE = 200;
const PARTICIPATION_SCAN_MAX_PAGES = 10;
const PARTICIPATION_RESPONSE_LIMIT = 20;

class ParticipationListUnavailable extends Error {}

interface ListScanKey {
  group: number;
  sortAt: Date;
  id: mongoose.Types.ObjectId;
}

async function scanParticipationAwareRequests(input: {
  now: Date;
  participant: NonNullable<
    Awaited<ReturnType<typeof requireVerifiedCallerForRead>>
  >["participant"];
  fenceFilter: Record<string, unknown>;
  isCanceled: () => boolean;
}): Promise<RequestListDocument[]> {
  const { now, participant, fenceFilter, isCanceled } = input;
  const hourLater = new Date(now.getTime() + 60 * 60 * 1000);
  const isAsap = {
    $or: [
      { $eq: [{ $type: "$windowStart" }, "missing"] },
      { $lte: ["$windowStart", hourLater] },
    ],
  };
  let after: ListScanKey | undefined;
  let exhausted = false;
  let candidatesExamined = 0;
  const visible: RequestListDocument[] = [];

  for (let page = 0; page < PARTICIPATION_SCAN_MAX_PAGES; page += 1) {
    if (isCanceled()) throw new ParticipationListUnavailable();
    const pipeline: mongoose.PipelineStage[] = [
      {
        $match: {
          ...buildEffectiveAvailabilityFilter(now),
          ...fenceFilter,
        },
      },
      {
        $addFields: {
          __participationListGroup: { $cond: [isAsap, 0, 1] },
          __participationListSortAt: {
            $cond: [isAsap, "$createdAt", "$windowStart"],
          },
        },
      },
    ];
    if (after) {
      pipeline.push({
        $match: {
          $or: [
            { __participationListGroup: { $gt: after.group } },
            {
              __participationListGroup: after.group,
              __participationListSortAt: { $gt: after.sortAt },
            },
            {
              __participationListGroup: after.group,
              __participationListSortAt: after.sortAt,
              _id: { $gt: after.id },
            },
          ],
        },
      });
    }
    pipeline.push(
      { $sort: { __participationListGroup: 1, __participationListSortAt: 1, _id: 1 } },
      { $limit: PARTICIPATION_SCAN_PAGE_SIZE },
      {
        $project: {
          _id: 1,
          vendor: 1,
          food: 1,
          pickupWindowText: 1,
          mealSwipes: 1,
          menuPath: 1,
          mealItems: 1,
          orderDetails: 1,
          estimatedDiningDollarsCents: 1,
          windowStart: 1,
          windowEnd: 1,
          status: 1,
          createdAt: 1,
          expiresAt: 1,
          visibleFrom: 1,
          claimExpiresAt: 1,
          requesterParticipantId: 1,
          __participationListGroup: 1,
          __participationListSortAt: 1,
        },
      }
    );
    const pageRows = await MealRequest.aggregate(pipeline)
      .option({ maxTimeMS: PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS })
      .exec();
    if (isCanceled()) throw new ParticipationListUnavailable();
    candidatesExamined += pageRows.length;
    if (pageRows.length === 0) {
      exhausted = true;
      break;
    }
    const last = pageRows[pageRows.length - 1] as {
      _id: mongoose.Types.ObjectId;
      __participationListGroup: number;
      __participationListSortAt: Date;
    };
    after = {
      group: last.__participationListGroup,
      sortAt: new Date(last.__participationListSortAt),
      id: last._id,
    };
    const candidates = pageRows.map(({ __participationListGroup: _group,
      __participationListSortAt: _sortAt, ...row }) => row);
    const filtered = await filterRequestListForParticipant(
      candidates as RequestListDocument[],
      participant,
      undefined,
      isCanceled
    );
    if (isCanceled()) throw new ParticipationListUnavailable();
    visible.push(...filtered);
    if (visible.length >= PARTICIPATION_RESPONSE_LIMIT) break;
    if (pageRows.length < PARTICIPATION_SCAN_PAGE_SIZE) {
      exhausted = true;
      break;
    }
  }

  if (
    visible.length < PARTICIPATION_RESPONSE_LIMIT &&
    !exhausted &&
    candidatesExamined >=
      PARTICIPATION_SCAN_PAGE_SIZE * PARTICIPATION_SCAN_MAX_PAGES
  ) {
    throw new ParticipationListUnavailable();
  }
  return visible.slice(0, PARTICIPATION_RESPONSE_LIMIT);
}

/**
 * `GET /api/requests`: the ordinary request list, served only to a usable,
 * backend-verified participant (W4-R5).
 *
 * Extracted from `app.ts` unchanged except for the verified-only gate, so the
 * gate and the caller-specific behavior behind it have direct executable
 * coverage rather than only source inspection.
 */
export async function getPublicRequestList(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> {
  try {
    const now = new Date();
    // W4-R5 verified-only gate, ahead of every database lookup and all
    // request-dependent work: a missing, malformed, independently revoked or
    // otherwise unusable credential (never one that is merely the original
    // credential of an installation whose Change Email completed, `R5-IR-2`)
    // is refused with the shared structured error and
    // no request content (it also sets the no-store headers before any
    // response). One resolution serves the W4-U1.3 participant-pair fence, the
    // W3-H2 participation filter, and the W4-H2 caller-relative ownership
    // context.
    const caller = await requireVerifiedCallerForRead(req, res);
    if (!caller) return;
    const { participant, ownershipContext } = caller;
    const isCanceled = () => req.aborted === true || res.destroyed === true;

    // W4-U1.3: a fenced pair does not see each other's otherwise-eligible
    // requests. Applied in the query, ahead of the fixed `limit`, so excluded
    // requests can never occupy slots a visible one would have filled.
    if (isCanceled()) throw new ParticipationListUnavailable();
    const fenceFilter = await buildParticipantFenceFilter(
      participant.participantId,
      { maxTimeMS: PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS }
    );
    if (isCanceled()) throw new ParticipationListUnavailable();

    // `+requesterParticipantId` (W4-H2): the field is `select: false` on the
    // schema like every other private field; explicitly selecting it here is
    // required to derive the caller-relative ownership signal below.
    // `mapPublicRequestFields` never reads or copies it, so it never reaches
    // the public wire response.
    const visibleDocs = await scanParticipationAwareRequests({
      now,
      participant,
      fenceFilter,
      isCanceled,
    });

    // This response is caller-specific (W4-H2: `isOwnRequest` can differ per
    // caller for the identical request); `requireVerifiedCallerForRead`
    // already set `Cache-Control: private, no-store` and `Vary` on it.
    res.json(
      buildPublicRequestListResponse(visibleDocs, now, ownershipContext)
    );
  } catch (err) {
    if (
      err instanceof ParticipantIdentityConfigurationError ||
      err instanceof ParticipantParticipationReadCancelled ||
      err instanceof ParticipationListUnavailable ||
      (typeof err === "object" &&
        err !== null &&
        "code" in err &&
        (err as { code?: unknown }).code === 50)
    ) {
      if (!res.destroyed) {
        sendDay4Error(
          res,
          503,
          PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
          PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
        );
      }
      return;
    }
    next(err);
  }
}
