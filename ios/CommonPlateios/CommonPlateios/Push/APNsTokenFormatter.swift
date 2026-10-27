//
//  APNsTokenFormatter.swift
//  CommonPlateios
//
// Normalizes the `Data` APNs hands back in
// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` into the
// deterministic lowercase-hex representation the backend expects
// (`isNormalizedApnsToken` in `src/installationPushRoute.ts`). Neither side
// assumes Apple's current 32-byte token size, so a future change to it needs
// no coordinated update.
import Foundation

enum APNsTokenFormatterError: Error {
    case emptyToken
}

enum APNsTokenFormatter {
    /// One lowercase two-character hex pair per byte, in order, with no
    /// separators, wrapping characters, or `Data` description text. Leading
    /// zero bytes are preserved because `%02x` always emits two digits.
    static func normalize(_ deviceToken: Data) throws -> String {
        guard !deviceToken.isEmpty else {
            throw APNsTokenFormatterError.emptyToken
        }
        return deviceToken.map { String(format: "%02x", $0) }.joined()
    }
}
