//
//  AlertSignupPresentationStorage.swift
//  CommonPlateios
//
// Local continuity for the alert-signup `Check your email` screen across app
// launches. This is presentation history and nothing else.
//
// What a saved record means is exactly: this installation previously submitted
// this address and received CommonPlate's generic accepted response. It does
// not prove that a Subscriber exists, that the address is pending, that a
// confirmation email was submitted or delivered, that the address was
// confirmed, that alerts are active, that the address is still subscribed, or
// that the person still controls it. The generic 202 is identical for a new,
// pending, confirmed, and unsubscribed address (docs/system-contract.md section
// 9.1), so no local record derived from it may be read as subscription status —
// which is why nothing here is named for one.
//
// The address is presentation data, not a credential, and is deliberately not
// in the Keychain: the app keeps no comparable preference there, and a stored
// email is not a secret.
import Foundation

/// The one thing this installation remembers about alert signup: which address
/// it last submitted, and when the generic accepted response came back.
///
/// `acceptedResponseAt` is device time and is not displayed today. It is kept
/// because "we showed this once" without "when" is not something a later slice
/// can reason about — an expiry rule, for instance, has nothing to measure.
struct AlertSignupPresentationRecord: Codable, Equatable {
    let email: String
    let acceptedResponseAt: Date
}

/// The narrow persistence seam the signup store owns. Two operations, because
/// there are exactly two things that happen to the record: a generic accepted
/// response writes one, and `Use a different email` or an unusable stored value
/// removes one.
protocol AlertSignupPresentationStorage {
    /// The saved record, or `nil` when there is none and when what is saved
    /// cannot be trusted. Rejecting a record also removes it.
    func loadValidPresentation() -> AlertSignupPresentationRecord?
    func save(_ record: AlertSignupPresentationRecord)
    func clear()
}

/// `UserDefaults`-backed storage. `UserDefaults` because the app has no
/// established preference mechanism to reuse and this is a single small
/// non-secret value; deliberately not Core Data, SwiftData, a database, or any
/// app-wide persistence layer, none of which one key would justify.
struct UserDefaultsAlertSignupPresentationStorage: AlertSignupPresentationStorage {
    /// One key. A second one would let the address and its timestamp be written
    /// or removed independently, and a half-record is exactly what the load
    /// path exists to refuse.
    static let key = "com.commonplate.alertSignup.checkEmailPresentation"
    private let localPresentation: ParticipantLocalPresentationStorage
    private var activeKey: String { localPresentation.key(Self.key) }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        localPresentation = ParticipantLocalPresentationStorage(defaults: defaults)
    }

    /// ISO-8601 rather than the `Date` default's seconds-since-reference-date
    /// double, so a stored record is readable and a malformed timestamp is
    /// unambiguously malformed instead of being some other instant.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Restores only a record that is still usable, and throws nothing: this
    /// runs during store initialization, so corrupt local state must fall back
    /// to the editable form rather than take the launch down with it.
    ///
    /// Reads no network. A local record cannot be checked against the backend,
    /// and asking would be a subscription-status lookup, which does not exist.
    func loadValidPresentation() -> AlertSignupPresentationRecord? {
        guard localPresentation.isCurrent else { return nil }
        guard defaults.object(forKey: activeKey) != nil else {
            return nil
        }

        // Anything stored under this key that is not a decodable record with a
        // valid timestamp and a still-eligible address is removed rather than
        // left to be re-rejected on every launch. A value of the wrong type
        // entirely fails the `data` read and is removed here too.
        guard let data = defaults.data(forKey: activeKey),
              let decoded = try? Self.decoder.decode(AlertSignupPresentationRecord.self, from: data),
              AlertSignupEmailValidator.isAllowedNYUEmail(decoded.email) else {
            clear()
            return nil
        }

        // Normalized on the way out as well as in. The rule that decides
        // eligibility and the value that is remembered must be the same string.
        return AlertSignupPresentationRecord(
            email: AlertSignupEmailValidator.normalize(decoded.email),
            acceptedResponseAt: decoded.acceptedResponseAt
        )
    }

    /// Replaces whatever was there. Exactly one address is remembered, because
    /// the screen presents exactly one.
    func save(_ record: AlertSignupPresentationRecord) {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        guard let data = try? Self.encoder.encode(record) else {
            // Two `Codable` fields cannot realistically fail to encode. If it
            // ever did, the honest outcome is no memory of this response rather
            // than a stale record left standing for a different address.
            clear()
            return
        }
        defaults.set(data, forKey: activeKey)
    }

    func clear() {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        defaults.removeObject(forKey: activeKey)
    }
}
