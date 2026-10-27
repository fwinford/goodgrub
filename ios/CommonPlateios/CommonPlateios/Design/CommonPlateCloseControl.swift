//
//  CommonPlateCloseControl.swift
//  CommonPlateios
//
// W4-H2 reusable "Control / Close" fidelity (approved Figma node 163:279): a
// quiet 44×44 dismiss control for sheets and focused overlays — a 38pt ghost
// circle with a native xmark glyph, inset to the full 44×44 interaction
// target. Use for dismissal only; this is never a substitute for Back
// navigation.
import SwiftUI

struct CommonPlateCloseControl: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(CommonPlateStyle.Color.baseCanvas, in: Circle())
                .overlay(Circle().strokeBorder(.secondary.opacity(0.3)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
