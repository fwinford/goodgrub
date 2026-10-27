//
//  CommonPlateDisclosureIndicator.swift
//  CommonPlateios
//
// W4-H2 reusable "Navigation / Disclosure" fidelity (approved Figma node
// 163:282): a 44×44 alignment frame around a lightweight accent-colored
// chevron, for Settings/utility rows that navigate to another destination.
// Home request cards remain whole-card tappable and never receive this
// affordance.
import SwiftUI

struct CommonPlateDisclosureIndicator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(CommonPlateStyle.Color.brandText)
            .frame(width: 44, height: 44)
    }
}
