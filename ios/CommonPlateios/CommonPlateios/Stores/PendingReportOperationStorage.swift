//
//  PendingReportOperationStorage.swift
//  CommonPlateios
//
// Identity-only local recovery for one unresolved W4-U1.2 report operation.
//
import Foundation

struct PendingReportOperationRecord: Codable, Equatable {
    static let currentVersion = 1

    let recoveryVersion: Int
    let operationId: String
    let participantIdentifier: String
    let requestID: String
    let authorityOrigin: String
    let authorityLedger: String

    init(
        operationId: String,
        participantIdentifier: String,
        requestID: String,
        authority: RequestOperationAuthorityIdentity
    ) {
        recoveryVersion = Self.currentVersion
        self.operationId = operationId
        self.participantIdentifier = participantIdentifier
        self.requestID = requestID
        authorityOrigin = authority.origin
        authorityLedger = authority.ledger
    }

    var authority: RequestOperationAuthorityIdentity {
        RequestOperationAuthorityIdentity(origin: authorityOrigin, ledger: authorityLedger)
    }

    var isUsable: Bool {
        recoveryVersion == Self.currentVersion
            && Self.isValidOperationId(operationId)
            && ParticipantAuthorityShape.isCanonicalParticipantIdentifier(participantIdentifier)
            && Self.isValidRequestID(requestID)
            && authority.isUsable
    }

    static func isValidOperationId(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "rp1",
              parts[1].count == 13,
              parts[1].unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789").contains
              ),
              (22...64).contains(parts[2].count) else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        return parts[2].unicodeScalars.allSatisfy(allowed.contains)
    }

    static func isValidRequestID(_ value: String) -> Bool {
        value.count == 24
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }
    }
}

enum PendingReportOperationLoad: Equatable {
    case absent
    case record(PendingReportOperationRecord)
    case identityUnavailable
}

protocol PendingReportOperationStorage: AnyObject {
    func load() -> PendingReportOperationLoad
    @discardableResult
    func save(_ record: PendingReportOperationRecord) -> Bool
    func clear(operationId: String)
}

final class InMemoryPendingReportOperationStorage: PendingReportOperationStorage {
    private var record: PendingReportOperationRecord?

    func load() -> PendingReportOperationLoad {
        guard let record else { return .absent }
        return record.isUsable ? .record(record) : .identityUnavailable
    }

    @discardableResult
    func save(_ record: PendingReportOperationRecord) -> Bool {
        guard record.isUsable else { return false }
        switch load() {
        case .absent:
            self.record = record
        case .record(let existing) where existing.operationId == record.operationId:
            self.record = record
        case .record, .identityUnavailable:
            return false
        }
        return true
    }

    func clear(operationId: String) {
        guard record?.operationId == operationId else { return }
        record = nil
    }
}

final class UserDefaultsPendingReportOperationStorage: PendingReportOperationStorage {
    static let key = "com.commonplate.participant.pending-report-operation.v1"

    private let defaults: UserDefaults
    private let localPresentation: ParticipantLocalPresentationStorage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        localPresentation = ParticipantLocalPresentationStorage(defaults: defaults)
    }

    func load() -> PendingReportOperationLoad {
        if defaults.bool(forKey: ParticipantDeletionCleanup.reportUnavailableKey) { return .identityUnavailable }
        guard let stored = defaults.object(forKey: Self.key) else { return .absent }
        guard let data = stored as? Data,
              let record = try? JSONDecoder().decode(PendingReportOperationRecord.self, from: data),
              record.isUsable else {
            return .identityUnavailable
        }
        return .record(record)
    }

    @discardableResult
    func save(_ record: PendingReportOperationRecord) -> Bool {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return false }
        guard record.isUsable else { return false }
        switch load() {
        case .absent:
            break
        case .record(let existing) where existing.operationId == record.operationId:
            break
        case .record, .identityUnavailable:
            return false
        }
        guard let data = try? JSONEncoder().encode(record) else { return false }
        defaults.set(data, forKey: Self.key)
        return load() == .record(record)
    }

    func clear(operationId: String) {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        guard case .record(let record) = load(),
              record.operationId == operationId else {
            return
        }
        defaults.removeObject(forKey: Self.key)
    }
}
