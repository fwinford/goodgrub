import Foundation

/// An installation-local presentation epoch, never account provenance or
/// deletion authority. Ownerless old presentation stays unavailable in place;
/// later explicit actions write fresh state without adopting or erasing it.
struct ParticipantLocalPresentationStorage {
    static let generationKey = "com.commonplate.participant.local-presentation-generation.v1"
    let defaults: UserDefaults
    let generation: String?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        generation = defaults.string(forKey: Self.generationKey)
    }

    var isCurrent: Bool { defaults.string(forKey: Self.generationKey) == generation }

    func key(_ base: String) -> String {
        generation.map { base + ".presentation." + $0 } ?? base
    }

    static func retire(defaults: UserDefaults, generation: String) throws {
        guard UUID(uuidString: generation) != nil else { throw ParticipantDeletionError.storageUnavailable }
        defaults.set(generation, forKey: generationKey)
        guard defaults.string(forKey: generationKey) == generation else {
            throw ParticipantDeletionError.storageUnavailable
        }
    }
}
