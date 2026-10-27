//
//  PendingRequestUpdateStorage.swift
//  CommonPlateios
//
//  W4-R5 durable record of an Edit or Withdraw whose outcome is unknown.
//

import Foundation

/// Which mutation a pending update is.
enum RequestUpdateKind: String, Codable, Equatable {
    case edit
    case withdraw
}

/// One Edit or Withdraw that was sent and whose outcome the app does not know.
///
/// Held durably *before* the POST is sent, so a relaunch can neither forget an
/// operation that may have committed nor invent a fresh one for the same intent:
/// recovery replays this exact `operationId` (and, for an edit, this exact
/// payload), which the backend answers exactly once. It is bound to the
/// participant that started it; another participant never sees, replays or
/// adopts it. It carries no credential, no claim token and no request content
/// beyond the edit payload the student already submitted.
struct PendingRequestUpdate: Codable, Equatable {
    let operationId: String
    let kind: RequestUpdateKind
    let requestID: String
    /// The participant that started this operation (the canonical identifier
    /// inside their credential). A record is acted on only for this participant.
    let participantIdentifier: String
    /// The ledger authority the operation was recorded against; sent back so a
    /// reset or replaced ledger can neither answer for it nor reuse its identity.
    let operationLedger: String?
    /// Present exactly for an edit: the exact submitted content.
    let editPayload: EditRequestPayload?
}

/// Durable storage for unresolved updates, keyed by operation identity. A record
/// belongs to the participant that started it; saving one never replaces or
/// reads another participant's.
protocol PendingRequestUpdateStorage: AnyObject {
    /// A held value that cannot be read is `.unreadable`, never "none": it could
    /// be anyone's operation.
    func load() -> PendingRequestUpdateLoad
    @discardableResult
    func save(_ update: PendingRequestUpdate) -> Bool
    func clear(operationId: String)
}

enum PendingRequestUpdateLoad: Equatable {
    case records([PendingRequestUpdate])
    case unreadable

    var records: [PendingRequestUpdate] {
        if case .records(let records) = self { return records }
        return []
    }
}

final class InMemoryPendingRequestUpdateStorage: PendingRequestUpdateStorage {
    private var held: [PendingRequestUpdate] = []

    func load() -> PendingRequestUpdateLoad { .records(held) }

    @discardableResult
    func save(_ update: PendingRequestUpdate) -> Bool {
        held.removeAll { $0.operationId == update.operationId }
        held.append(update)
        return true
    }

    func clear(operationId: String) {
        held.removeAll { $0.operationId == operationId }
    }
}

final class UserDefaultsPendingRequestUpdateStorage: PendingRequestUpdateStorage {
    static let key = "com.commonplate.request.pending-update-operations.v1"

    private let defaults: UserDefaults
    private let localPresentation: ParticipantLocalPresentationStorage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        localPresentation = ParticipantLocalPresentationStorage(defaults: defaults)
    }

    func load() -> PendingRequestUpdateLoad {
        if defaults.bool(forKey: ParticipantDeletionCleanup.updateUnavailableKey) { return .unreadable }
        guard let stored = defaults.object(forKey: Self.key) else { return .records([]) }
        guard let data = stored as? Data,
              let records = try? JSONDecoder().decode([PendingRequestUpdate].self, from: data) else {
            return .unreadable
        }
        return .records(records)
    }

    @discardableResult
    func save(_ update: PendingRequestUpdate) -> Bool {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return false }
        guard case .records(var records) = load() else { return false }
        records.removeAll { $0.operationId == update.operationId }
        records.append(update)
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: Self.key)
        // Read back: a write that did not land is a failed save, never a record
        // the caller believes it has.
        return load().records.contains(update)
    }

    func clear(operationId: String) {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        guard case .records(var records) = load() else { return }
        records.removeAll { $0.operationId == operationId }
        if records.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
