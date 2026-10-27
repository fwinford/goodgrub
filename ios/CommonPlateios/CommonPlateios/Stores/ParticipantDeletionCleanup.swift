import Foundation

struct ParticipantDeletionCleanupResult: Equatable {
    var removedCreates = 0
    var removedUpdates = 0
    var retainedUnavailable = false
}

/// Runs synchronously on the stores' actor; never reconciles or replays held
/// operations. Surviving create bytes and update JSON values stay intact.
@MainActor
struct ParticipantDeletionCleanup {
    static let createUnavailableKey = "com.commonplate.deletion.create-unavailable.v1"
    static let updateUnavailableKey = "com.commonplate.deletion.update-unavailable.v1"
    static let pickupUnavailableKey = "com.commonplate.deletion.pickup-unavailable.v1"
    static let reportUnavailableKey = "com.commonplate.deletion.report-unavailable.v1"
    let defaults: UserDefaults

    func recordedLedgers() -> Set<String> {
        var values = Set<String>()
        for entry in UserDefaultsPendingRequestOperationStorage(defaults: defaults).restoreAll() {
            if case .restored(let record) = entry,
               let authority = record.identity.operationAuthority, authority.isUsable {
                values.insert(authority.ledger)
            }
        }
        if case .records(let records) = UserDefaultsPendingRequestUpdateStorage(defaults: defaults).load() {
            for record in records {
                if let ledger = record.operationLedger,
                   RequestOperationAuthorityIdentity.isValidLedger(ledger) { values.insert(ledger) }
            }
        }
        if case .record(let record) = UserDefaultsPendingReportOperationStorage(defaults: defaults).load(),
           record.isUsable { values.insert(record.authorityLedger) }
        return values
    }

    func run(journal: ParticipantDeletionRecord, retireUnboundPresentation: Bool = true) throws -> ParticipantDeletionCleanupResult {
        guard journal.stage == .completedCleanupPending, journal.isValid else {
            throw ParticipantDeletionError.storageUnavailable
        }
        try ParticipantDeletionNotificationFence(defaults: defaults).recordCompletion(at: Date())
        let context = journal.context
        var result = ParticipantDeletionCleanupResult()
        for key in [
            UserDefaultsPendingRequestOperationStorage.singleRecordKey,
            UserDefaultsPendingRequestOperationStorage.collectionKey,
        ] {
            guard let stored = defaults.object(forKey: key) else { continue }
            if key == UserDefaultsPendingRequestOperationStorage.singleRecordKey {
                switch createDisposition(stored, context: context) {
                case .remove:
                    defaults.removeObject(forKey: key)
                    guard defaults.object(forKey: key) == nil else {
                        throw ParticipantDeletionError.storageUnavailable
                    }
                    result.removedCreates += 1
                case .unavailable:
                    try quarantine(Self.createUnavailableKey)
                    result.retainedUnavailable = true
                case .foreign:
                    break
                }
            } else if let entries = stored as? [Any] {
                var survivors: [Any] = []
                for entry in entries {
                    switch createDisposition(entry, context: context) {
                    case .remove: result.removedCreates += 1
                    case .foreign: survivors.append(entry)
                    case .unavailable:
                        survivors.append(entry)
                        try quarantine(Self.createUnavailableKey)
                        result.retainedUnavailable = true
                    }
                }
                if survivors.count != entries.count {
                    if survivors.isEmpty { defaults.removeObject(forKey: key) }
                    else { defaults.set(survivors, forKey: key) }
                    if survivors.isEmpty {
                        guard defaults.object(forKey: key) == nil else {
                            throw ParticipantDeletionError.storageUnavailable
                        }
                    } else {
                        guard let actual = defaults.array(forKey: key) as NSArray?,
                              actual.isEqual(to: survivors) else {
                            throw ParticipantDeletionError.storageUnavailable
                        }
                    }
                }
            } else {
                try quarantine(Self.createUnavailableKey)
                result.retainedUnavailable = true
            }
        }
        let updateKey = UserDefaultsPendingRequestUpdateStorage.key
        if let original = defaults.object(forKey: updateKey) {
            if let data = original as? Data,
               let decoded = try? JSONDecoder().decode([PendingRequestUpdate].self, from: data),
               let elements = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               elements.count == decoded.count {
                var survivors: [[String: Any]] = []
                for (record, element) in zip(decoded, elements) {
                    let canonical = ParticipantAuthorityShape.isCanonicalParticipantIdentifier(record.participantIdentifier)
                    let ledger = record.operationLedger
                    let validLedger = ledger.map(RequestOperationAuthorityIdentity.isValidLedger) ?? false
                    if canonical, validLedger, record.participantIdentifier == context.participantID,
                       let attested = context.attestedLedger, ledger == attested {
                        result.removedUpdates += 1
                    } else {
                        survivors.append(element)
                        if !canonical || !validLedger ||
                            (record.participantIdentifier == context.participantID && ledger != context.attestedLedger) {
                            try quarantine(Self.updateUnavailableKey)
                            result.retainedUnavailable = true
                        }
                    }
                }
                if survivors.count != elements.count {
                    if survivors.isEmpty { defaults.removeObject(forKey: updateKey) }
                    else { defaults.set(try JSONSerialization.data(withJSONObject: survivors), forKey: updateKey) }
                    if survivors.isEmpty {
                        guard defaults.object(forKey: updateKey) == nil else {
                            throw ParticipantDeletionError.storageUnavailable
                        }
                    } else {
                        guard let persisted = defaults.data(forKey: updateKey),
                              let actual = try JSONSerialization.jsonObject(with: persisted) as? NSArray,
                              actual.isEqual(to: survivors) else {
                            throw ParticipantDeletionError.storageUnavailable
                        }
                    }
                }
            } else {
                try quarantine(Self.updateUnavailableKey)
                result.retainedUnavailable = true
            }
        }
        let reportKey = UserDefaultsPendingReportOperationStorage.key
        if let original = defaults.object(forKey: reportKey) {
            if let data = original as? Data,
               let record = try? JSONDecoder().decode(PendingReportOperationRecord.self, from: data),
               record.isUsable, record.participantIdentifier == context.participantID,
               record.authorityOrigin == context.origin,
               record.authorityLedger == context.attestedLedger {
                defaults.removeObject(forKey: reportKey)
                guard defaults.object(forKey: reportKey) == nil else {
                    throw ParticipantDeletionError.storageUnavailable
                }
            } else {
                switch UserDefaultsPendingReportOperationStorage(defaults: defaults).load() {
                case .record(let record) where record.isUsable && record.participantIdentifier != context.participantID:
                    break
                default:
                    try quarantine(Self.reportUnavailableKey)
                    result.retainedUnavailable = true
                }
            }
        }
        // Pickup records have email-only ownership. They cannot be erased or
        // adopted by a later same-email identity.
        if defaults.object(forKey: UserDefaultsPendingPlacedPickupStorage.key) != nil {
            try quarantine(Self.pickupUnavailableKey)
            result.retainedUnavailable = true
        }
        try FirstRequestGuidanceLedger.remove(
            forParticipantIdentifier: context.participantID,
            defaults: defaults
        )
        if retireUnboundPresentation {
            try ParticipantLocalPresentationStorage.retire(defaults: defaults, generation: context.freezeID)
        }
        return result
    }

    private enum Disposition { case remove, foreign, unavailable }

    private func createDisposition(_ stored: Any, context: ParticipantDeletionContext) -> Disposition {
        guard case .restored(let record) = UserDefaultsPendingRequestOperationStorage.restoreEntry(stored),
              let authority = record.identity.operationAuthority, authority.isUsable else {
            return .unavailable
        }
        guard record.identity.participantIdentifier == context.participantID else { return .foreign }
        guard authority.origin == context.origin, authority.ledger == context.attestedLedger else {
            return .unavailable
        }
        return .remove
    }

    private func quarantine(_ key: String) throws {
        defaults.set(true, forKey: key)
        guard defaults.object(forKey: key) as? Bool == true else {
            throw ParticipantDeletionError.storageUnavailable
        }
    }
}
