//
//  ScreenshotProposalPreferencesStorage.swift
//  CommonPlateios
//
// W4-S3 consent-authority revision (2026-10-01 HQ sync): Screenshot
// Assistance's one app-level toggle IS the external-transfer consent record —
// there is no separate "enabled" preference distinct from consent. On exists
// only while a valid consent record for the CURRENT contract (purpose,
// provider, transferred-data class) is present; Off clears it. A later
// material change to purpose/provider/data class must not silently inherit an
// old record — `ScreenshotAssistanceConsentContract.current` is what "valid"
// is checked against.
//
// Pre-TestFlight development-state reset (Faith-approved, 2026-10-01): this
// is a fresh contract, not a migration of the old one. An installation
// without a valid record under THIS contract is Off, full stop:
// - the old W4-S1/S3 `isAIAssistanceEnabled` key (which defaulted to `true`)
//   is never read by this type;
// - the pre-S3 `commonplate.screenshotProposal.thirdPartyConsentRecorded` key
//   is never read by this type;
// - presence of either legacy key never creates a valid consent record.
// No migration screen, notice, or legacy-compatibility path exists.
//
// `hasCompletedScreenshotHelp` (W4-R2 2026-09-01 sync) is the independent
// first-use Screenshot Help education-completion flag: it tracks only whether
// the requester has completed Screenshot Help through `Got it` and is never
// inferred from consent/enabled state.
import Foundation

/// The exact purpose/provider/data-class binding a consent record is valid
/// for. A stored record is honored only while it equals
/// `ScreenshotAssistanceConsentContract.current`: a later material change to
/// any one of these three fields invalidates every previously granted record
/// rather than silently inheriting it (W4-S3 revision item 5).
struct ScreenshotAssistanceConsentContract: Codable, Equatable {
    let purpose: String
    let provider: String
    let transferredDataClass: String

    /// Screenshot Assistance, OpenAI, selected-screenshot-image-bytes only
    /// (`docs/week-4-ios-testflight-spec.md` W4-S3 "Payload verification":
    /// the on-device OCR `localEvidenceText` travels only to CommonPlate's
    /// own backend and is never part of this transferred-data class). Do not
    /// change these values without a truthful new disclosure (item 5).
    static let current = ScreenshotAssistanceConsentContract(
        purpose: "screenshotAssistance",
        provider: "openAI",
        transferredDataClass: "selectedScreenshotImages"
    )
}

protocol ScreenshotProposalPreferencesStoring: AnyObject {
    /// `true` exactly while a consent record matching
    /// `ScreenshotAssistanceConsentContract.current` is present. This is also
    /// the sole Screenshot Assistance On/Off authority — there is no separate
    /// stored "enabled" bit.
    var hasValidScreenshotAssistanceConsent: Bool { get }
    var hasCompletedScreenshotHelp: Bool { get set }

    /// Records a fresh `Turn On` decision: the only action that may create a
    /// valid consent record under the current contract.
    func grantScreenshotAssistanceConsent()
    /// `Not Now`, or Off: clears any consent record. Idempotent, and safe to
    /// call when none exists.
    func revokeScreenshotAssistanceConsent()
}

final class UserDefaultsScreenshotProposalPreferencesStorage: ScreenshotProposalPreferencesStoring {
    private let defaults: UserDefaults
    private let consentContractKey = "commonplate.screenshotProposal.consentContract.v1"
    private let helpCompletedKey = "commonplate.screenshotProposal.helpCompleted"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Absent (never set), unreadable (corrupt/foreign data), or recorded
    /// under a different purpose/provider/data-class contract all resolve to
    /// `false` — fail closed, never fail open.
    var hasValidScreenshotAssistanceConsent: Bool {
        guard let data = defaults.data(forKey: consentContractKey),
              let stored = try? JSONDecoder().decode(ScreenshotAssistanceConsentContract.self, from: data) else {
            return false
        }
        return stored == .current
    }

    func grantScreenshotAssistanceConsent() {
        guard let data = try? JSONEncoder().encode(ScreenshotAssistanceConsentContract.current) else { return }
        defaults.set(data, forKey: consentContractKey)
    }

    func revokeScreenshotAssistanceConsent() {
        defaults.removeObject(forKey: consentContractKey)
    }

    /// Defaults to `false` when never set: education is shown until the
    /// requester actually completes it once.
    var hasCompletedScreenshotHelp: Bool {
        get { defaults.bool(forKey: helpCompletedKey) }
        set { defaults.set(newValue, forKey: helpCompletedKey) }
    }
}
