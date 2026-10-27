/**
 * Exact-domain allowlist for CommonPlate email addresses.
 *
 * The comparison is on the whole normalized domain after the final `@`.
 * Substring or suffix matching would accept `fake-nyu.edu`, `nyu.edu.example`,
 * and every unlisted subdomain, none of which are the school's addresses, so
 * neither is used here.
 *
 * Alert signup enforces this today. Request creation is scheduled to reuse the
 * same helper, which is why this lives beside neither route.
 */
export const ALLOWED_EMAIL_DOMAINS: readonly string[] = Object.freeze([
  "nyu.edu",
  "stern.nyu.edu",
]);

export const NYU_EMAIL_REQUIRED_MESSAGE =
  "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu.";

/** Trims surrounding whitespace and lowercases, for comparison and storage. */
export function normalizeEmail(value: string): string {
  return value.trim().toLowerCase();
}

/**
 * The exact normalized domain, or `null` when the value has no usable one.
 * A leading `@` has no local part, so it is rejected rather than treated as a
 * bare domain.
 */
export function emailDomain(value: string): string | null {
  const normalized = normalizeEmail(value);
  const separator = normalized.lastIndexOf("@");
  if (separator <= 0) return null;
  const domain = normalized.slice(separator + 1);
  return domain.length > 0 ? domain : null;
}

export function hasAllowedEmailDomain(value: string): boolean {
  const domain = emailDomain(value);
  return domain !== null && ALLOWED_EMAIL_DOMAINS.includes(domain);
}
