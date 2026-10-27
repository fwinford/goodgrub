/// All requester assistance consumers must use this same policy. It does not
/// govern H1a placed-order evidence. Phase 2 wires the shared consumers.
struct RequesterScreenshotAssistanceAvailability: Equatable, Sendable {
    let isAvailable: Bool

    static let shipping = Self(isAvailable: false)

    private init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    static func enabledForTesting() -> Self {
        Self(isAvailable: true)
    }
}
