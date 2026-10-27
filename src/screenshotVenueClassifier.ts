import type { SupportedVendor } from "./supportedVendors.js";
import { SUPPORTED_VENDORS } from "./supportedVendors.js";
import { groundedVendorMatches } from "./screenshotProposalValidation.js";

/**
 * R4.2's selection-local venue anchor. This is deliberately separate from
 * proposal validation: it has no route effect and never widens the accepted
 * catalog matcher. It is shared with the Swift port through synthetic vectors.
 */
export type ScreenshotVenueDisposition =
  | { kind: "supported"; vendor: SupportedVendor }
  | { kind: "unresolved" }
  | { kind: "unsupported"; key: string }
  | { kind: "conflicting" };

/**
 * The disposition plus the one evidence fact the application gate needs:
 * whether any eligible image carried a V1 identity line at all. When false,
 * the accepted catalog-derived recognition is the only venue evidence.
 */
export interface ScreenshotVenueClassification {
  disposition: ScreenshotVenueDisposition;
  hasV1Observation: boolean;
}

type Observation =
  | { kind: "supported"; vendor: SupportedVendor; key: string }
  | { kind: "unsupported"; key: string }
  | { kind: "indeterminate" }
  | { kind: "none" };

function normalize(text: string): string {
  return text.toLowerCase().replace(/\s+/g, " ").trim();
}

function normalizedLines(text: string): string[] {
  return text
    .split(/\r\n|\r|\n/)
    .map(normalize)
    .filter((line) => line.length > 0);
}

/** ASCII-only keying is intentional: it is the accepted near-miss boundary. */
export function venueKey(text: string): string {
  return Array.from(text)
    .filter((character) => /[A-Za-z0-9]/.test(character))
    .join("")
    .toLowerCase();
}

function levenshtein(left: string, right: string): number {
  const previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let row = 1; row <= left.length; row += 1) {
    let diagonal = previous[0]!;
    previous[0] = row;
    for (let column = 1; column <= right.length; column += 1) {
      const above = previous[column]!;
      previous[column] = Math.min(
        previous[column]! + 1,
        previous[column - 1]! + 1,
        diagonal + (left[row - 1] === right[column - 1] ? 0 : 1)
      );
      diagonal = above;
    }
  }
  return previous[right.length]!;
}

/** Downgrade-only similarity: it never names or selects a catalog entry. */
export function venueKeysAreNear(left: string, right: string): boolean {
  if (left === right) return true;
  const shorter = Math.min(left.length, right.length);
  if (shorter >= 4 && (left.includes(right) || right.includes(left))) return true;
  return shorter >= 6 && levenshtein(left, right) <= 2;
}

function isNearCatalog(prefixKey: string): boolean {
  return SUPPORTED_VENDORS.some((vendor) => {
    const full = venueKey(vendor.name);
    const base = venueKey(vendor.name.split(" - ")[0] ?? vendor.name);
    return venueKeysAreNear(prefixKey, full) || venueKeysAreNear(prefixKey, base);
  });
}

function v1Prefixes(text: string): string[] {
  const lines = normalizedLines(text);
  const prefixes: string[] = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]!;
    const oneLine = /^(.*) - meal exchange$/.exec(line);
    if (oneLine) {
      if (oneLine[1]!.length > 0) prefixes.push(oneLine[1]!);
      continue;
    }
    if (line.endsWith(" - meal") && lines[index + 1] === "exchange") {
      const prefix = line.slice(0, -" - meal".length);
      if (prefix.length > 0) prefixes.push(prefix);
    }
  }
  return prefixes;
}

function asciiLetterCount(text: string): number {
  return Array.from(text).filter((character) => /[A-Za-z]/.test(character)).length;
}

function observeImage(text: string): Observation {
  const prefixes = v1Prefixes(text);
  if (prefixes.length === 0) return { kind: "none" };
  const keys = prefixes.map(venueKey);
  if (keys.some((key) => key.length === 0) || prefixes.some((prefix) => asciiLetterCount(prefix) < 3 || /(?:\.\.\.|…)$/.test(prefix))) {
    return { kind: "indeterminate" };
  }
  if (new Set(keys).size !== 1) return { kind: "indeterminate" };

  // The existing matcher sees the whole identity line, exactly as its current
  // supported-location authority does. Near matching never runs in reverse.
  const matches = prefixes.flatMap((prefix) =>
    groundedVendorMatches(`${prefix} - meal exchange`)
  );
  const names = new Set(matches.map((vendor) => vendor.name));
  if (names.size === 1) return { kind: "supported", vendor: matches[0]!, key: keys[0]! };
  if (names.size > 1 || isNearCatalog(keys[0]!)) return { kind: "indeterminate" };
  return { kind: "unsupported", key: keys[0]! };
}

/**
 * Classifies only V1 Meal Exchange identity evidence from already eligible
 * images. Cart position, catalog mentions, and every non-V1 structure remain
 * unknown by design.
 */
export function classifyScreenshotVenue(imageEvidenceTexts: readonly string[]): ScreenshotVenueClassification {
  const observations = imageEvidenceTexts.map(observeImage);
  const hasV1Observation = observations.some((observation) => observation.kind !== "none");
  const result = (disposition: ScreenshotVenueDisposition): ScreenshotVenueClassification => ({ disposition, hasV1Observation });
  const reliable = observations.filter((observation) => observation.kind === "supported" || observation.kind === "unsupported");
  for (let left = 0; left < reliable.length; left += 1) {
    for (let right = left + 1; right < reliable.length; right += 1) {
      const a = reliable[left]!;
      const b = reliable[right]!;
      if (a.kind !== b.kind) return result({ kind: "conflicting" });
      if (a.kind === "supported" && b.kind === "supported" && a.vendor.name !== b.vendor.name) return result({ kind: "conflicting" });
      if (a.kind === "unsupported" && b.kind === "unsupported" && !venueKeysAreNear(a.key, b.key)) return result({ kind: "conflicting" });
    }
  }

  const supported = observations.filter((observation): observation is Extract<Observation, { kind: "supported" }> => observation.kind === "supported");
  const unsupported = observations.filter((observation): observation is Extract<Observation, { kind: "unsupported" }> => observation.kind === "unsupported");
  const hasIndeterminate = observations.some((observation) => observation.kind === "indeterminate");
  if (unsupported.length > 0 && supported.length === 0 && !hasIndeterminate) {
    const joinedMatches = groundedVendorMatches(imageEvidenceTexts.join("\n"));
    if (joinedMatches.length === 0) return result({ kind: "unsupported", key: unsupported[0]!.key });
  }
  // Reliable V1 support stands only when no image's V1 evidence is
  // indeterminate; otherwise the selection is unresolved (A).
  if (supported.length > 0 && !hasIndeterminate) return result({ kind: "supported", vendor: supported[0]!.vendor });
  return result({ kind: "unresolved" });
}
