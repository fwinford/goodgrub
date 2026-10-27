//
//  ScreenshotQualificationProduction.swift
//  CommonPlateios
//
// W4-S3: the production qualification registry. It lives OUTSIDE
// `Services/ScreenshotAssistance/` on purpose: that directory is hashed into
// `ScreenshotQualificationFingerprint`, and a registry entry pins that very
// fingerprint. If the registry were inside the hashed directory, adding an entry
// would change the fingerprint the entry pins, so no entry could ever match.
import Foundation

extension ScreenshotQualificationRegistry {
    /// Production qualification is closed. An entry may be added here only
    /// after the S3 contract's qualification evidence exists for that exact
    /// combination — held-out safety/authority/usefulness/OCR-misread proof per
    /// evidence strategy and physical-device proof (weekly spec, W4-S3
    /// "Required proof") — and it pins the implementation fingerprint that
    /// evidence was gathered against. Tests inject their own registry;
    /// production is never made reachable by fiat.
    static let production = ScreenshotQualificationRegistry(shippingEntries: [])
}
