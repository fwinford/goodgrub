# A request whose helper affirmed an external order is retired in place and never reopened

**Status.** Accepted (established during W4-U1.3, 2026-10-15).

**Context.** A helper who holds a reservation may Block the requester and answer
that the real Grubhub order is already placed. CommonPlate cannot see or undo
that external order. Two existing behaviors would then put a second real order at
risk: an ordinary release returns the request to `open`, and passive reservation
expiry makes a `claimed` request claimable again. A helper who is allowed to
leave must therefore be able to do so without either happening, and CommonPlate
must not fabricate placement, claim the external order cancelled, or invent a
requester-facing state.

**Decision.** A successful `Yes` Block writes a private, content-free,
request-scoped `externalOrderAffirmed` marker in the same transaction as the
Block, pinned to the exact reservation the answer was given for. While it
exists the request is unavailable everywhere: the shared effective-availability
predicate and the claim filter both carry `externalOrderAffirmed: { $ne: true }`
at the top level, so it fails closed even for a marked row that reads `open`. A
Stop of such a request goes through the same release mutation but retires the
reservation in place — the deadline, token digest, helper binding, and one-use
marker are removed and the helper's lock is cleared — while `status` stays
`claimed` and never becomes `open`. Expiry, Stop, and Unblock cannot reopen it;
only the Request's own TTL ends the marker.

Rejected alternatives: ordinary release (reopens, so a second helper could place
a duplicate order); letting the reservation lapse (expiry reopens it, so an
explicit Stop would protect nothing); making fulfillment the only exit (forces
the blocker to enter order details to leave); a new request status (needs a
requester surface and copy no accepted contract authorizes, and every status
consumer would need to learn it); and client-only dismissal (the reservation and
the helper's one-active-reservation lock persist until expiry).

**Consequence for future work.**

- Anything that decides whether a request may be offered, claimed, alerted, or
  digested must use the shared availability predicate or filter. A new consumer
  that re-derives availability from `status` and `claimExpiresAt` alone will
  reopen a post-Yes request.
- Failure classifiers must answer a stale Stop, extension, or fulfillment for a
  retired request exactly as they answer one for an ordinarily released request
  (`isStoppedAfterAffirmedOrder`), so the marker is never revealed.
- The marker, the Block owner, and the Block direction are never projected. A
  requester who understands normal reservation timing can still infer an
  exceptional lifecycle from the request staying `claimed` past an ordinary
  reservation's duration; that inference is an accepted limitation
  (`docs/system-contract.md` section 5.3), and removing it needs a generic
  requester lifecycle presentation under its own product authority, not a change
  to this mechanism.
- Extension is intentionally not pair-fenced: a Block fences new interaction, and
  extending a reservation the holder already legitimately has begins none.
- Unblock is prospective and must never clear the marker or reopen the request.

**Related, not covered by this decision.** The write-skew serialization between
a Block and a concurrent claim (`blockFenceEpoch`) is documented where it is
implemented, in `src/participantBlocks.ts`.
