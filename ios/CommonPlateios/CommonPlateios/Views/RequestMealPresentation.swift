import SwiftUI

/// W4-N1 meal presentation rule (Faith): every surface shows a request meal as
/// the requester entered it — `Meal item` first, optional freeform `Details`
/// beneath it, never parsed, reworded or folded into parentheses.
///
/// - `compact` (Home card): item, then details in smaller secondary text.
/// - `detail` (Your request, public request detail): `MEAL N` eyebrow, item,
///   details.
/// - `execution` (Helping): `MEAL N` eyebrow, item, then a `DETAILS` label and
///   the details beside a subtle leading accent line (no filled container).
enum RequestMealDensity {
    case compact
    case detail
    case execution
}

struct RequestMealEntry: Equatable {
    let label: String
    let name: String
    let details: String?

    static let detailsLabel = "Details"

    /// Meal Exchange meals, one entry per meal. A single meal keeps the
    /// `Meal request` label; Dining Dollars requests have no meal entries.
    static func entries(for request: FoodRequest) -> [RequestMealEntry] {
        guard request.resource.menuPath == .mealExchange else { return [] }
        let meals = request.resource.mealItems
        return meals.enumerated().map { index, item in
            RequestMealEntry(
                label: meals.count > 1 ? "Meal \(index + 1)" : "Meal request",
                name: item.name,
                details: item.details.flatMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                }
            )
        }
    }
}

struct RequestMealView: View {
    let entry: RequestMealEntry
    let density: RequestMealDensity

    var body: some View {
        VStack(alignment: .leading, spacing: density == .compact ? 1 : 5) {
            if density != .compact {
                eyebrow(entry.label)
            }
            Text(entry.name)
                .font(density == .compact ? .body : .callout)
                .foregroundStyle(Color.primary)
                .lineLimit(density == .compact ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
            if let details = entry.details {
                detailsView(details)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func detailsView(_ details: String) -> some View {
        switch density {
        case .compact, .detail:
            Text(details)
                .font(density == .compact ? .subheadline : .footnote)
                .foregroundStyle(.secondary)
                .lineLimit(density == .compact ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
        case .execution:
            // Compact instruction treatment: a subtle leading accent line,
            // no filled container, details kept with their meal.
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color(uiColor: .tertiaryLabel))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    eyebrow(RequestMealEntry.detailsLabel)
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .accessibilityIdentifier("request-meal-details-inset")
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}
