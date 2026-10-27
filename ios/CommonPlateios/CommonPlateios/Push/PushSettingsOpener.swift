//
//  PushSettingsOpener.swift
//  CommonPlateios
//
// The one place `PushSubscriptionStore` can reach iPhone Settings. Narrow on
// purpose: the accepted contract requires Settings to open only from an
// explicit `Open Settings` tap, never automatically, and this seam is what
// lets a test prove that without launching the real Settings app.
import UIKit

protocol PushSettingsOpener {
    func openSettings()
}

struct UIApplicationPushSettingsOpener: PushSettingsOpener {
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { @MainActor in
            UIApplication.shared.open(url)
        }
    }
}
