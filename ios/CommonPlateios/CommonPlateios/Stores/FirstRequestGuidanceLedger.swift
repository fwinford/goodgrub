import CryptoKit
import Foundation

@MainActor
struct FirstRequestGuidanceLedger {
    static let defaultsKey = "commonplate.firstRequestGuidanceShown"

    let defaults: UserDefaults
    private let presentationStorage: ParticipantLocalPresentationStorage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        presentationStorage = ParticipantLocalPresentationStorage(defaults: defaults)
    }

    func showsGuidance(
        forAuthority authority: String,
        currentAuthority: String?,
        deletionFrozen: Bool
    ) -> Bool {
        guard mayRecord(
            forAuthority: authority,
            currentAuthority: currentAuthority,
            deletionFrozen: deletionFrozen
        ), let entry = Self.entry(forAuthority: authority),
           let recordedEntries else {
            return false
        }
        return !recordedEntries.contains(entry)
    }

    @discardableResult
    func recordGuidanceShown(
        forAuthority authority: String,
        currentAuthority: String?,
        deletionFrozen: Bool
    ) -> Bool {
        guard mayRecord(
            forAuthority: authority,
            currentAuthority: currentAuthority,
            deletionFrozen: deletionFrozen
        ), let entry = Self.entry(forAuthority: authority),
           var entries = recordedEntries else {
            return false
        }
        guard !entries.contains(entry) else { return true }
        entries.append(entry)
        defaults.set(entries, forKey: Self.defaultsKey)
        return defaults.stringArray(forKey: Self.defaultsKey) == entries
    }

    static func remove(forParticipantIdentifier participantID: String, defaults: UserDefaults) throws {
        guard ParticipantAuthorityShape.isCanonicalParticipantIdentifier(participantID),
              let entry = entry(forParticipantIdentifier: participantID) else {
            throw ParticipantDeletionError.storageUnavailable
        }
        guard let stored = defaults.object(forKey: Self.defaultsKey) else { return }
        guard let entries = stored as? [String], entries.allSatisfy(Self.isValidEntry) else {
            throw ParticipantDeletionError.storageUnavailable
        }
        let survivors = entries.filter { $0 != entry }
        guard survivors.count != entries.count else { return }
        if survivors.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            guard defaults.object(forKey: Self.defaultsKey) == nil else {
                throw ParticipantDeletionError.storageUnavailable
            }
        } else {
            defaults.set(survivors, forKey: Self.defaultsKey)
            guard defaults.stringArray(forKey: Self.defaultsKey) == survivors else {
                throw ParticipantDeletionError.storageUnavailable
            }
        }
    }

    static func entry(forAuthority authority: String) -> String? {
        guard let participantID = ParticipantAuthorityShape.participantIdentifier(ofAuthority: authority) else {
            return nil
        }
        return entry(forParticipantIdentifier: participantID)
    }

    static func entry(forParticipantIdentifier participantID: String) -> String? {
        guard ParticipantAuthorityShape.isCanonicalParticipantIdentifier(participantID) else { return nil }
        return SHA256.hash(data: Data(participantID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var recordedEntries: [String]? {
        guard let stored = defaults.object(forKey: Self.defaultsKey) else { return [] }
        guard let entries = stored as? [String], entries.allSatisfy(Self.isValidEntry) else { return nil }
        return entries
    }

    private static func isValidEntry(_ entry: String) -> Bool {
        let bytes = entry.utf8
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func mayRecord(
        forAuthority authority: String,
        currentAuthority: String?,
        deletionFrozen: Bool
    ) -> Bool {
        !deletionFrozen &&
            presentationStorage.isCurrent &&
            currentAuthority == authority &&
            Self.entry(forAuthority: authority) != nil
    }
}
