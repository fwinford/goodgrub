import Foundation

@MainActor
final class ParticipantDeletionNetworkFence {
    private(set) var generation = 0
    private(set) var isFrozen: Bool

    init(isFrozen: Bool = false) {
        self.isFrozen = isFrozen
    }

    func setFrozen(_ value: Bool) {
        generation += 1
        isFrozen = value
    }

    func check(path: String, generation expected: Int) throws {
        if path.hasPrefix("/api/participant/deletion") { return }
        guard !isFrozen, expected == generation else {
            throw CancellationError()
        }
    }
}
