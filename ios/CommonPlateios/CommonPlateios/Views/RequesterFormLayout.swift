//
//  RequesterFormLayout.swift
//  CommonPlateios
//
// W4-R4 (2026-09-26 requester fidelity/layout contract): the requester form is
// a stable `ScrollView`/`VStack` skeleton. The only adaptive behavior left is
// where `Post request` sits, and that is decided from three measurements —
// never by redistributing spare height between form sections.
import SwiftUI

/// Where `Post request` lives for the current form height.
///
/// - Short form (the form plus the action fit the usable viewport): the action
///   occupies the bottom safe-area action position, like Home's `Request a
///   Meal`. The form above it is not stretched or rebalanced; the unused space
///   is simply the empty part of the viewport.
/// - Tall form: the action is the last ordinary child of the scroll content,
///   so it follows the form, is reached by scrolling, never overlays a field,
///   and is not sticky.
///
/// The decision depends only on measurements that do not change with the
/// placement itself (the form's own height, the action's own height, and the
/// whole region's height), so it cannot oscillate.
struct RequesterFormLayoutMetrics: Equatable {
    /// Height of the region the form is laid out in, inside the safe area.
    var viewportHeight: CGFloat = 0
    /// Height of every form section, excluding `Post request`.
    var formContentHeight: CGFloat = 0
    /// Height of the `Post request` section (button plus any pointer line).
    var postRequestHeight: CGFloat = 0

    static let contentTopPadding = CommonPlateStyle.Spacing.l
    static let contentBottomPadding = CommonPlateStyle.Spacing.xs
    static let formToActionSpacing = CommonPlateStyle.Spacing.m

    /// Nothing is decided until all three measurements exist, so the first
    /// frame never briefly shows the action in the wrong place.
    var isMeasured: Bool {
        viewportHeight > 0 && formContentHeight > 0 && postRequestHeight > 0
    }

    /// The height the whole form needs when `Post request` is ordinary
    /// scroll content.
    var flowedContentHeight: CGFloat {
        Self.contentTopPadding
            + formContentHeight
            + Self.formToActionSpacing
            + postRequestHeight
            + Self.contentBottomPadding
    }

    var anchorsPostRequestToBottom: Bool {
        isMeasured && flowedContentHeight <= viewportHeight
    }
}

/// Holds the raw measurements outside SwiftUI's invalidation graph. Recording
/// a height never re-evaluates the form; only a change in the placement
/// *decision* is published (see `RequestFoodView.recordLayoutMeasurement`).
/// Publishing every raw height re-ran the whole form body once or twice per
/// meal expansion for no visible change.
final class RequesterFormMeasurementBox {
    var metrics = RequesterFormLayoutMetrics()

    /// `nil` until everything is measured, then whether the action anchors.
    var placementDecision: Bool? {
        metrics.isMeasured ? metrics.anchorsPostRequestToBottom : nil
    }
}

struct RequesterViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RequesterFormContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RequesterPostRequestHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Publishes this view's laid-out height without affecting its layout.
    func requesterMeasuringHeight<Key: PreferenceKey>(_ key: Key.Type) -> some View
    where Key.Value == CGFloat {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: key, value: proxy.size.height)
            }
        )
    }
}

extension View {
    /// Keeps a Meal card presentation mounted for the card's lifetime while
    /// only the active one takes part in the interface: the inactive one has
    /// zero layout height (so it never reaches the measured form height),
    /// draws nothing, receives no hits, and is absent from accessibility.
    /// Deliberately not `.disabled`, which would change the subtree's
    /// environment each time it is revealed.
    func mealPresentation(isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .frame(height: isActive ? nil : 0, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}
