import SwiftUI

/// Shown when the Release build has no valid production backend configuration.
/// It owns no state and starts no work, so nothing can reach a network.
struct ConfigurationUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: CommonPlateStyle.Spacing.m) {
            Text("\(AppBrand.name) is unavailable")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(CommonPlateStyle.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("configuration-unavailable")
    }
}
