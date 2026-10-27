import { createHash } from "node:crypto";
import type { ClientSession } from "mongoose";
import { RequestOperationAuthority } from "../models/db.js";
import { isValidOperationAuthorityId } from "./requestOperationAuthority.js";

export const DELETION_NAMESPACE_HEADER = "x-commonplate-deletion-namespace";
const AUTHORITY_ROW_ID = "request-operation-ledger";

export class DeletionNamespaceUnavailable extends Error {
  constructor() {
    super("Participant deletion namespace is unavailable");
  }
}

export function isDeletionNamespaceBinding(value: unknown): value is string {
  return typeof value === "string" && /^dn1_[0-9a-f]{64}$/.test(value);
}

// A non-credential projection: clients can compare existing recorded ledger
// provenance without the deletion API disclosing the internal ledger UUID.
export function deletionNamespaceBinding(ledger: string): string {
  if (!isValidOperationAuthorityId(ledger)) throw new DeletionNamespaceUnavailable();
  return `dn1_${createHash("sha256")
    .update("commonplate:participant-deletion-namespace:v1\0", "utf8")
    .update(ledger, "utf8")
    .digest("hex")}`;
}

export async function readDeletionNamespace(
  session: ClientSession
): Promise<{ authorityId: string; binding: string }> {
  const row = await RequestOperationAuthority.findById(AUTHORITY_ROW_ID)
    .session(session)
    .lean()
    .exec();
  if (!row || !isValidOperationAuthorityId(row.authorityId)) {
    throw new DeletionNamespaceUnavailable();
  }
  return { authorityId: row.authorityId, binding: deletionNamespaceBinding(row.authorityId) };
}

export async function fenceDeletionNamespace(
  session: ClientSession,
  expected?: string
): Promise<string> {
  const current = await readDeletionNamespace(session);
  if (expected !== undefined &&
      (!isDeletionNamespaceBinding(expected) || expected !== current.binding)) {
    throw new DeletionNamespaceUnavailable();
  }
  // A real write, not a read/check: replacement of this authority row conflicts
  // with the transaction, which must retry against the replacement namespace.
  const result = await RequestOperationAuthority.updateOne(
    { _id: AUTHORITY_ROW_ID, authorityId: current.authorityId },
    { $inc: { deletionFenceEpoch: 1 } },
    { session }
  ).exec();
  if (result.modifiedCount !== 1) throw new DeletionNamespaceUnavailable();
  return current.binding;
}
