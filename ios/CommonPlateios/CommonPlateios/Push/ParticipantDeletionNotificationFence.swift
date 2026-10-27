import Foundation

@MainActor
struct ParticipantDeletionNotificationFence {
    static let key = "com.commonplate.deletion.notification-cutoff.v1"
    let defaults: UserDefaults

    func recordCompletion(at date: Date) throws {
        let persistedDate = max(defaults.object(forKey: Self.key) as? Date ?? .distantPast, date)
        defaults.set(persistedDate, forKey: Self.key)
        guard defaults.object(forKey: Self.key) as? Date == persistedDate else {
            throw ParticipantDeletionError.storageUnavailable
        }
    }

    func rejects(deliveredAt date: Date) -> Bool {
        guard let stored = defaults.object(forKey: Self.key) else { return false }
        guard let cutoff = stored as? Date else { return true }
        return date <= cutoff
    }
}
