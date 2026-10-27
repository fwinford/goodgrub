/**
 * Whether a helper-notification channel actually finished initiating a request,
 * as opposed to resolving without having done so (W3-N3).
 *
 * This is deliberately a distinction at the **initiation** layer, not at the
 * provider layer. It introduces no retry of any provider submission and changes
 * no delivery semantics: an accepted APNs submission, a token rejection, a
 * transient submission failure, an abandoned dispatch, and a failed email send
 * are all exactly as terminal as they have always been, and none of them is
 * ever attempted twice.
 *
 * The one question it answers is the one the eligibility sweep has to ask
 * before it consumes a request's single `awaiting-eligibility` state:
 *
 * - `"processed"` — this channel reached its existing terminal outcome for this
 *   request. Every recipient it was going to consider has been considered, and
 *   running it again would produce nothing but duplicate-claim skips. Having no
 *   eligible recipients at all is one of these: the accepted lifecycle notifies
 *   whoever is eligible when a request becomes eligible, and does not hold a
 *   request open waiting for someone to subscribe later.
 *
 * - `"retryable"` — this channel did no initiation work and reached no terminal
 *   outcome, so nothing about this request has been decided. Public actions
 *   were paused, the request was not effectively available at the moment the
 *   channel looked, or a delivery-ledger claim could not be written for a
 *   reason that was not "another dispatch already owns this recipient". None of
 *   these is a delivery outcome, and treating any of them as one would spend
 *   the request's only initiation on work that never happened — a request that
 *   becomes eligible again would then be permanently undiscoverable.
 *
 * A request leaves `awaiting-eligibility` only when **both** channels report
 * `"processed"`. Channel independence is preserved: one processed channel plus
 * one retryable channel leaves the request awaiting, a later sweep revisits
 * both, and the already-processed channel is a per-recipient no-op through the
 * existing unique `SendLog` and `PushDelivery` claims.
 */
export type HelperNotificationInitiation = "processed" | "retryable";

/** Both channels, or neither. */
export function isInitiationProcessed(
  ...channels: HelperNotificationInitiation[]
): boolean {
  return channels.every((channel) => channel === "processed");
}
