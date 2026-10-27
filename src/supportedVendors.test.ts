import { realpathSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { SUPPORTED_VENDORS, isSupportedVendor } from "./supportedVendors.js";

describe("supportedVendors", () => {
  it("preserves the exact accepted 10-spot catalog and its order", () => {
    expect(SUPPORTED_VENDORS.map((vendor) => vendor.name)).toEqual([
      "Crave NYU",
      "Dunkin' at U-Hall",
      "Jasper Kane Cafe",
      "Peet's Coffee at Kimmel",
      "Cafe 370",
      "Flavor Lab by NYU Eats",
      "Cafe 181",
      "Upstein - Vedge Craft & Smoothie Lab",
      "Upstein - Shareables, Cluckstein, Slidestein & Taqueria",
      "True Burger at UHall",
    ]);
  });

  it("accepts every catalog vendor and rejects anything else", () => {
    for (const vendor of SUPPORTED_VENDORS) {
      expect(isSupportedVendor(vendor.name)).toBe(true);
    }
    expect(isSupportedVendor("Off-Campus Diner")).toBe(false);
    expect(isSupportedVendor("palladium")).toBe(false);
    // Faith (N1): Palladium is not a supported dining location.
    expect(isSupportedVendor("Palladium")).toBe(false);
    expect(isSupportedVendor("")).toBe(false);
  });

  it("is the same physical file the iOS bundle resource symlinks to", () => {
    // Not two lists kept in sync by hand: the iOS resource is a symlink to
    // this same `shared/vendors.json`.
    const sharedPath = realpathSync(
      new URL("../shared/vendors.json", import.meta.url)
    );
    const iosResourcePath = realpathSync(
      new URL(
        "../ios/CommonPlateios/CommonPlateios/Resources/SupportedVendors.json",
        import.meta.url
      )
    );
    expect(iosResourcePath).toBe(sharedPath);
  });
});
