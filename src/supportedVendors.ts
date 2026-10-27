import { readFileSync } from "fs";
import path from "path";

/**
 * Backend and iOS both read `shared/vendors.json` — the iOS copy is a
 * symlink to this same file, not a second copy — so the accepted 10-spot
 * catalog has exactly one physical source. Read with `process.cwd()`, the
 * same repo-root-relative convention `app.ts` already uses for `public/`,
 * so this resolves the same way in dev (`tsx watch app.ts`) and in
 * production (`node dist/app.js`, both run from the repo root).
 */
export interface SupportedVendor {
  name: string;
  address: string;
}

const catalogPath = path.join(process.cwd(), "shared", "vendors.json");
const catalogJson = readFileSync(catalogPath, "utf-8");

export const SUPPORTED_VENDORS: readonly SupportedVendor[] =
  Object.freeze(JSON.parse(catalogJson));

const SUPPORTED_VENDOR_NAMES: ReadonlySet<string> = new Set(
  SUPPORTED_VENDORS.map((vendor) => vendor.name)
);

/**
 * Exact match only, against the already-trimmed value. A near-match like
 * trailing punctuation or a different case is a different string, not the
 * same vendor, so it is rejected rather than silently canonicalized.
 */
export function isSupportedVendor(vendor: string): boolean {
  return SUPPORTED_VENDOR_NAMES.has(vendor);
}

export const UNSUPPORTED_VENDOR_MESSAGE =
  "Choose a supported CommonPlate dining location.";
