//
//  APNsEnvironment.swift
//  CommonPlateios
//
// The one place the app reads its build configuration to decide which APNs
// environment it synchronizes as, per the Week 3 Day 6 Slice 6A contract.
// Nothing else in the push feature checks `#if DEBUG`; every call site reads
// `APNsEnvironment.current` instead, so a future need to change the mapping
// changes in exactly one place. The user never chooses this value.
import Foundation

/// Matches the backend's accepted `environment` values exactly
/// (`src/installationPushRoute.ts`).
enum APNsEnvironment: String {
    case development
    case production

    /// `DEBUG` is defined only for the Debug build configuration
    /// (`SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"` on the
    /// Debug configuration only — see `project.pbxproj`), which is what a
    /// Debug physical-device build runs under. Every other configuration,
    /// including Release and therefore any archive, TestFlight, or App Store
    /// build, does not define it and synchronizes as `production`.
    static var current: APNsEnvironment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }
}
