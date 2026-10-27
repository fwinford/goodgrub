import {
  deps,
  ownerFilter,
  readSecureOperation,
  withDeletionOwnerFence,
  type DeletionOwner,
  type ParticipantDeletionDependencies,
} from "./participantDeletionOperations.js";
import { deletionNamespaceBinding, isDeletionNamespaceBinding, DeletionNamespaceUnavailable } from "./participantDeletionNamespace.js";
import { isValidOperationAuthorityId } from "./requestOperationAuthority.js";

// Attests comparison provenance only. Cleanup still requires authoritative
// completion for this exact operation/owner/namespace, not this response alone.
export async function compareDeletionRecordedLedger(
  owner: DeletionOwner,
  recordedLedger: string,
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Promise<boolean> {
  if (!isDeletionNamespaceBinding(owner.namespaceBinding) ||
      !isValidOperationAuthorityId(recordedLedger)) {
    throw new DeletionNamespaceUnavailable();
  }
  return withDeletionOwnerFence(owner, deps(overrides), async (session, secret) => {
    const row = await readSecureOperation(ownerFilter(owner, secret), session);
    if (!row || !isDeletionNamespaceBinding(row.namespaceBinding) ||
        row.namespaceBinding !== owner.namespaceBinding ||
        row.phase === "completed" || row.phase === "canceled") {
      throw new DeletionNamespaceUnavailable();
    }
    return deletionNamespaceBinding(recordedLedger) === row.namespaceBinding;
  });
}
