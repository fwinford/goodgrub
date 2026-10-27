import { Request as MealRequest, type IRequest } from "../models/db.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";
import { buildNotificationGenerationFilter } from "./requestRevision.js";

/**
 * W4-R5 notification-generation guard shared by every helper new-request
 * dispatcher.
 *
 * A dispatch is started for one request at one notification generation. Between
 * that start and any individual provider handoff the requester can edit,
 * reschedule or withdraw. This returns the request as it is *now* — current
 * content, current effective availability, and still the generation the
 * dispatch was started for — or `null` when it is no longer the request this
 * dispatch was started to advertise.
 *
 * Callers use it at the three points the contract names: before a delivery
 * claim is written, after it is written, and immediately before provider
 * handoff. An ordinary edit advances only `contentRevision`, so this keeps
 * returning the request with its new content (and the caller sends *that*,
 * never a stale copy). An explicit rescheduling or a withdrawal changes the
 * generation or the availability, so this returns `null` and the dispatch
 * stops before handing anything to a provider.
 *
 * Read only; it claims nothing and writes nothing. `$and`, because the
 * availability filter carries a top-level `$or` and so does the generation
 * clause for the initial generation.
 */
export type DispatchRequest = IRequest & {
  contentRevision?: number | null;
  notificationGeneration?: number | null;
};

export async function readCurrentForDispatch(
  requestId: unknown,
  expectedGeneration: number,
  now: Date
): Promise<DispatchRequest | null> {
  const current = await MealRequest.findOne(
    {
      $and: [
        { _id: requestId },
        buildEffectiveAvailabilityFilter(now),
        buildNotificationGenerationFilter(expectedGeneration),
      ],
    },
    "+notificationGeneration +contentRevision +requesterParticipantId",
    { lean: true }
  );
  return (current ?? null) as unknown as DispatchRequest | null;
}
