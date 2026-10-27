/**
 * The single public base-URL setting for links this service emails.
 *
 * Emailed links carry credentials, so their origin comes from trusted
 * configuration and never from a request `Host`, `X-Forwarded-Host`, or
 * forwarded protocol. Every emailed link resolves the origin here, so a
 * second competing origin setting cannot drift into existence alongside it.
 */
export const PUBLIC_BASE_URL_ENV = "BASE_URL";
export const DEFAULT_PUBLIC_BASE_URL = "https://commonplatenyu.org";

export function publicBaseUrl(
  environment: NodeJS.ProcessEnv = process.env
): string {
  return environment[PUBLIC_BASE_URL_ENV] || DEFAULT_PUBLIC_BASE_URL;
}

/**
 * The configured origin with trailing slashes removed, so it composes with an
 * absolute path without producing a doubled separator.
 */
export function publicBaseOrigin(
  environment: NodeJS.ProcessEnv = process.env
): string {
  return publicBaseUrl(environment).replace(/\/+$/, "");
}
