import type { Types } from "mongoose";
import { Installation } from "../models/db.js";
import { digestInstallationCredential } from "./installationCredential.js";

/**
 * Request-to-installation association (Week 3 Day 6 Slice 6E).
 *
 * iOS sends its existing installation credential with request creation. This
 * resolves/establishes that installation's identity using the same
 * credential-digest mechanism Slice 6A's synchronization endpoint uses, and
 * returns only the internal `Installation._id` to associate with the
 * request. The raw credential is never persisted here or by the caller.
 *
 * This is notification-routing identity only — not authentication, not
 * person identity. A valid credential resolves identity even when push is
 * currently off, or has never been turned on, for that installation: an
 * upsert with `$setOnInsert` creates a bare, disabled installation record
 * without ever touching `pushEnabled` on one that already exists, so this
 * path can never flip an installation's push state.
 */
export async function resolveRequestInstallationAssociation(
  rawCredential: string | undefined
): Promise<Types.ObjectId | undefined> {
  if (rawCredential === undefined) {
    // Web-created requests, and any caller that supplies none, remain valid
    // without an association.
    return undefined;
  }

  const installationCredentialDigest = digestInstallationCredential(rawCredential);
  const installation = await Installation.findOneAndUpdate(
    { installationCredentialDigest },
    { $setOnInsert: { pushEnabled: false } },
    { upsert: true, new: true }
  )
    .select("_id")
    .lean()
    .exec();

  return installation?._id as Types.ObjectId | undefined;
}
