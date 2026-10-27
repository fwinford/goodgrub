//
//  PendingPlacedPickupStorage.swift
//  CommonPlateios
//
// W4-R3's minimal durable pickup reconciliation record.
//
import Foundation

/// The only state retained for a pickup whose outcome is unknown. The
/// principal is a normalized participant identity, never the authority token.
struct PendingPlacedPickup: Codable, Equatable {
    let requestID: String
    let participantPrincipal: String
}

enum PendingPlacedPickupLoad: Equatable {
    case records([PendingPlacedPickup])
    case unreadable
}

protocol PendingPlacedPickupStorage: AnyObject {
    func load() -> PendingPlacedPickupLoad
    @discardableResult func save(_ record: PendingPlacedPickup) -> Bool
    @discardableResult func clear(_ record: PendingPlacedPickup) -> Bool
    @discardableResult func clear(participantPrincipal: String) -> Bool
}

final class InMemoryPendingPlacedPickupStorage: PendingPlacedPickupStorage {
    private var records: [PendingPlacedPickup] = []

    func load() -> PendingPlacedPickupLoad { .records(records) }

    func save(_ record: PendingPlacedPickup) -> Bool {
        records.removeAll { $0 == record }
        records.append(record)
        return records.contains(record)
    }

    func clear(_ record: PendingPlacedPickup) -> Bool {
        records.removeAll { $0 == record }
        return !records.contains(record)
    }

    func clear(participantPrincipal: String) -> Bool {
        records.removeAll { $0.participantPrincipal == participantPrincipal }
        return !records.contains { $0.participantPrincipal == participantPrincipal }
    }
}

final class UserDefaultsPendingPlacedPickupStorage: PendingPlacedPickupStorage {
    static let key = "com.commonplate.request.pending-placed-pickups.v1"

    private let defaults: UserDefaults
    private let localPresentation: ParticipantLocalPresentationStorage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        localPresentation = ParticipantLocalPresentationStorage(defaults: defaults)
    }

    func load() -> PendingPlacedPickupLoad {
        if defaults.bool(forKey: ParticipantDeletionCleanup.pickupUnavailableKey) { return .unreadable }
        guard let stored = defaults.object(forKey: Self.key) else {
            return .records([])
        }
        guard let data = stored as? Data,
              let records = try? JSONDecoder().decode([PendingPlacedPickup].self, from: data) else {
            return .unreadable
        }
        return .records(records)
    }

    func save(_ record: PendingPlacedPickup) -> Bool {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return false }
        guard case .records(var records) = load() else { return false }
        records.removeAll { $0 == record }
        records.append(record)
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: Self.key)
        guard case .records(let stored) = load() else { return false }
        return stored.contains(record)
    }

    func clear(_ record: PendingPlacedPickup) -> Bool {
        update { $0.removeAll { $0 == record } } &&
            !loadedRecords().contains(record)
    }

    func clear(participantPrincipal: String) -> Bool {
        update { $0.removeAll { $0.participantPrincipal == participantPrincipal } } &&
            !loadedRecords().contains { $0.participantPrincipal == participantPrincipal }
    }

    private func update(_ mutate: (inout [PendingPlacedPickup]) -> Void) -> Bool {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return false }
        guard case .records(var records) = load() else { return false }
        mutate(&records)
        if records.isEmpty {
            defaults.removeObject(forKey: Self.key)
            return defaults.object(forKey: Self.key) == nil
        }
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: Self.key)
        return loadedRecords() == records
    }

    private func loadedRecords() -> [PendingPlacedPickup] {
        guard case .records(let records) = load() else { return [] }
        return records
    }
}
