//
//  PushInstallationStorageTests.swift
//  CommonPlateiosTests
//
// Focused coverage for Week 3 Day 6 Slice 6A.2 installation identity and
// last-confirmed push state. Every case here uses a fresh `UserDefaults`
// suite removed in `tearDown`, matching `AlertSignupPresentationTests`:
// nothing in this file can read or write the developer's real preferences.
import Foundation
import XCTest
@testable import CommonPlateios

final class PushInstallationStorageTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "PushInstallationStorageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Credential format

    func testGeneratesA32ByteCredentialEncodedAsCanonicalUnpaddedBase64URL() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        let credential = storage.installationCredential()

        XCTAssertEqual(credential.count, 43)
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(credential.allSatisfy { alphabet.contains($0) })

        let standardBase64 = credential
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standardBase64 + String(
            repeating: "=",
            count: (4 - standardBase64.count % 4) % 4
        )
        let decoded = Data(base64Encoded: padded)
        XCTAssertEqual(decoded?.count, 32)
    }

    func testTwoGeneratedCredentialsDiffer() {
        let first = UserDefaultsPushInstallationStorage(defaults: defaults).installationCredential()
        defaults.removeObject(forKey: "com.commonplate.push.installationCredential")
        let second = UserDefaultsPushInstallationStorage(defaults: defaults).installationCredential()
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Stability within one installation lifecycle

    func testTheCredentialIsStableAcrossRepeatedReadsAndAcrossStorageInstances() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        let first = storage.installationCredential()
        let second = storage.installationCredential()
        XCTAssertEqual(first, second)

        // A fresh storage instance over the same `UserDefaults` — the shape
        // of what happens on the next app launch — must see the identical
        // value: stability is a property of the storage location, not of one
        // in-memory object.
        let reopened = UserDefaultsPushInstallationStorage(defaults: defaults)
        XCTAssertEqual(reopened.installationCredential(), first)
    }

    /// Two different `UserDefaults` suites stand in for two different app
    /// installations. Reinstalling must produce a new installation, so each
    /// gets its own credential.
    func testDifferentInstallationsGetDifferentCredentials() {
        let otherSuiteName = "\(suiteName).other"
        let other = UserDefaults(suiteName: otherSuiteName)!
        defer { other.removePersistentDomain(forName: otherSuiteName) }

        let a = UserDefaultsPushInstallationStorage(defaults: defaults).installationCredential()
        let b = UserDefaultsPushInstallationStorage(defaults: other).installationCredential()
        XCTAssertNotEqual(a, b)
    }

    /// Not a substitute for code review, but the strongest claim a unit test
    /// can make about "not the Keychain": the credential is readable straight
    /// back out of the exact `UserDefaults` suite this storage was given,
    /// through the plain `UserDefaults` API, under the one documented key —
    /// with no Keychain call anywhere in the path that produced it.
    func testTheCredentialLivesInPlainUserDefaultsUnderItsDocumentedKey() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        let credential = storage.installationCredential()
        XCTAssertEqual(
            defaults.string(forKey: "com.commonplate.push.installationCredential"),
            credential
        )
    }

    // MARK: - Last-confirmed push state

    func testLastConfirmedPushEnabledIsNilUntilRecorded() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        XCTAssertNil(storage.lastConfirmedPushEnabled)
    }

    func testRecordingReplacesTheConfirmedValue() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)

        storage.recordConfirmedPushEnabled(true)
        XCTAssertEqual(storage.lastConfirmedPushEnabled, true)

        storage.recordConfirmedPushEnabled(false)
        XCTAssertEqual(storage.lastConfirmedPushEnabled, false)
    }

    /// `nil` (never synchronized) and `false` (confirmed off) must not
    /// collapse into the same stored representation.
    func testNeverConfirmedIsDistinctFromConfirmedOff() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        XCTAssertNil(storage.lastConfirmedPushEnabled)

        storage.recordConfirmedPushEnabled(false)
        XCTAssertEqual(storage.lastConfirmedPushEnabled, false)
        XCTAssertNotNil(storage.lastConfirmedPushEnabled)
    }

    // MARK: - Settings-recovery intent timestamp

    func testSettingsRecoveryIntentStartedAtIsNilUntilRecorded() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        XCTAssertNil(storage.settingsRecoveryIntentStartedAt)
    }

    func testSettingsRecoveryIntentStartedAtRoundTripsThroughStorage() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        storage.setSettingsRecoveryIntentStartedAt(date)

        XCTAssertEqual(storage.settingsRecoveryIntentStartedAt, date)
    }

    func testSettingClearsThePersistedRecoveryIntentTimestamp() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        storage.setSettingsRecoveryIntentStartedAt(Date(timeIntervalSince1970: 1_700_000_000))

        storage.setSettingsRecoveryIntentStartedAt(nil)

        XCTAssertNil(storage.settingsRecoveryIntentStartedAt)
    }

    /// The malformed half of "missing or malformed timestamp is treated as
    /// stale": a value stored under this key that is not a `Date` at all —
    /// unreachable through this type's own API, but a defensive check
    /// against any future or external write to the same `UserDefaults`
    /// suite — must read back as `nil`, exactly like an absent key, so
    /// `PushSubscriptionStore` treats it as stale rather than crashing or
    /// misreading it as some other type.
    func testMalformedStoredValueUnderTheRecoveryIntentKeyReadsAsNil() {
        defaults.set("not-a-date", forKey: "com.commonplate.push.settingsRecoveryIntentStartedAt")
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)

        XCTAssertNil(storage.settingsRecoveryIntentStartedAt)
    }

    // MARK: - Pending ambiguous desired state

    func testPendingAmbiguousDesiredEnabledIsNilUntilRecorded() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        XCTAssertNil(storage.pendingAmbiguousDesiredEnabled)
    }

    func testPendingAmbiguousDesiredEnabledRoundTripsThroughStorage() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)

        storage.setPendingAmbiguousDesiredEnabled(true)
        XCTAssertEqual(storage.pendingAmbiguousDesiredEnabled, true)

        storage.setPendingAmbiguousDesiredEnabled(false)
        XCTAssertEqual(storage.pendingAmbiguousDesiredEnabled, false)
    }

    /// `nil` (nothing unresolved) and `false` (an unresolved disable) must
    /// not collapse into the same stored representation — the same
    /// distinction `lastConfirmedPushEnabled` already draws.
    func testNoPendingAmbiguityIsDistinctFromAPendingDisable() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        XCTAssertNil(storage.pendingAmbiguousDesiredEnabled)

        storage.setPendingAmbiguousDesiredEnabled(false)
        XCTAssertNotNil(storage.pendingAmbiguousDesiredEnabled)
        XCTAssertEqual(storage.pendingAmbiguousDesiredEnabled, false)
    }

    func testClearingRemovesThePersistedPendingAmbiguity() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        storage.setPendingAmbiguousDesiredEnabled(true)

        storage.setPendingAmbiguousDesiredEnabled(nil)

        XCTAssertNil(storage.pendingAmbiguousDesiredEnabled)
    }

    /// Persists across a fresh storage instance over the same suite, the
    /// shape of an app relaunch — the whole reason this value exists.
    func testPendingAmbiguousDesiredEnabledSurvivesAFreshStorageInstance() {
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        storage.setPendingAmbiguousDesiredEnabled(true)

        let reopened = UserDefaultsPushInstallationStorage(defaults: defaults)
        XCTAssertEqual(reopened.pendingAmbiguousDesiredEnabled, true)
    }
}
