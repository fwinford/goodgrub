import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const iosRoot = new URL("../ios/CommonPlateios/", import.meta.url);
const read = (path: string) => readFileSync(new URL(path, iosRoot), "utf8");

function topLevelKeys(plist: string): string[] {
  const dict = plist.slice(plist.indexOf("<dict>") + 6, plist.lastIndexOf("</dict>"));
  const keys: string[] = [];
  let depth = 0;
  for (const token of dict.match(/<\/?(?:dict|array)>|<key>[^<]*<\/key>/g) ?? []) {
    if (token === "<dict>" || token === "<array>") depth++;
    else if (token === "</dict>" || token === "</array>") depth--;
    else if (depth === 0) keys.push(token.replace(/<\/?key>/g, ""));
  }
  return keys.sort();
}

describe("iPhone Release configuration (source configuration only)", () => {
  const debugPlist = read("CommonPlateios/Info.plist");
  const releasePlist = read("Configuration/Release-Info.plist");
  const project = read("CommonPlateios.xcodeproj/project.pbxproj");

  it("keeps Release Info.plist identical to Debug except ATS and the production origin", () => {
    const expected = topLevelKeys(debugPlist)
      .filter((key) => key !== "NSAppTransportSecurity")
      .concat("CommonPlateProductionAPIBaseURL")
      .sort();
    expect(topLevelKeys(releasePlist)).toEqual(expected);
  });

  it("carries no ATS or local-network allowance in the Release Info.plist", () => {
    expect(releasePlist).not.toMatch(/NSAllowsArbitraryLoads|NSAllowsLocalNetworking|NSAppTransportSecurity/);
  });

  it("is iPhone-only with no Mac, Catalyst, or visionOS compatibility destinations", () => {
    // Only the non-shipping unit-test bundle keeps the Xcode default family.
    const iPadFamilyBlocks = project
      .split("buildSettings = {")
      .filter((block) => /TARGETED_DEVICE_FAMILY = "1,2"/.test(block.split("};")[0]));
    expect(iPadFamilyBlocks).toHaveLength(2);
    for (const block of iPadFamilyBlocks) {
      expect(block.split("};")[0]).toContain("PRODUCT_BUNDLE_IDENTIFIER = com.fwinford.CommonPlateiosTests;");
    }
    expect(project).not.toMatch(/UISupportedInterfaceOrientations_iPad/);
    expect(project.match(/TARGETED_DEVICE_FAMILY = 1;/g)).toHaveLength(2);
    expect(project.match(/SUPPORTS_MACCATALYST = NO;/g)).toHaveLength(2);
  });

  it("uses the separate Release plist only for the Release app configuration and never hardcodes a host", () => {
    expect(project.match(/INFOPLIST_FILE = "Configuration\/Release-Info\.plist";/g)).toHaveLength(1);
    expect(project.match(/NSLocalNetworkUsageDescription/g)).toHaveLength(1);
    expect(project).not.toMatch(/COMMONPLATE_PRODUCTION_API_BASE_URL\s*=/);
  });
});
