//
//  CommonPlateScreenCloseControl.swift
//  CommonPlateios
//
// W4-B1 one close control for B1's full-screen and modal dismissals (the
// approved unsupported-school design): a 44×44 warm-surface circle with a
// 17pt semibold xmark. The fixed circle owns the glyph's geometry, so Dynamic
// Type cannot resize it. A hairline keeps its bounds visible in dark, where
// the warm surface equals the canvas. Placement and the accessible label stay
// with each screen; this owns only the look and the 44pt hit target.
import SwiftUI

struct CommonPlateScreenCloseControl: View {
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(CommonPlateStyle.Color.warmSurface, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(CommonPlateScreenCloseButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct CommonPlateScreenCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
