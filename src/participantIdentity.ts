import { z } from "zod";
import { hasAllowedEmailDomain } from "./allowedEmailDomains.js";

/**
 * The participant principal: the exact normalized allowed NYU address that has
 * completed participant verification.
 *
 * "Exact" is load-bearing. `a.b+cs101@nyu.edu` and `ab@nyu.edu` are two
 * principals, not two spellings of one human — nothing here strips `+tags`,
 * removes dots, or resolves vanity addresses, because CommonPlate has no way to
 * know that any two NYU addresses belong to the same person and inventing that
 * equivalence would silently merge two people's requests and reservations.
 *
 * Domain eligibility is not ownership. `hasAllowedEmailDomain` only decides
 * whether an address is *allowed* to become a participant; only successful
 * backend verification of an emailed code makes one.
 */

/**
 * The RFC 5321 maximum. Bounded here so a hostile value cannot reach an index,
 * an HMAC input, or an email envelope at unbounded length.
 */
export const PARTICIPANT_PRINCIPAL_MAX_LENGTH = 254;

/**
 * Same trimming, lowercasing, syntax check, and exact-domain allowlist that
 * `POST /api/subscribe` and `POST /api/request` already apply, in that order,
 * so participant eligibility cannot drift into a second idea of an NYU address.
 */
const eligibleParticipantEmail = z
  .string()
  .trim()
  .toLowerCase()
  .max(PARTICIPANT_PRINCIPAL_MAX_LENGTH)
  .email()
  .refine(hasAllowedEmailDomain);

/**
 * The normalized principal, or `null` when the value is not an address that may
 * become one. Returning `null` rather than throwing keeps every caller — route
 * validation, stored-row revalidation, credential resolution — answering from
 * shape alone before touching the database.
 */
export function normalizeParticipantPrincipal(value: unknown): string | null {
  const result = eligibleParticipantEmail.safeParse(value);
  return result.success ? result.data : null;
}

export function isParticipantPrincipal(value: unknown): value is string {
  return normalizeParticipantPrincipal(value) !== null;
}
