//
//  CommonPlateiosApp.swift
//  CommonPlateios
//
//  Created by faith on 7/5/26.
//

import SwiftUI

@main
struct CommonPlateiosApp: App {
    // The narrowest UIKit bridge SwiftUI's app lifecycle needs for APNs
    // device-token callbacks (Week 3 Day 6 Slice 6A.2). See
    // `PushAppDelegate.swift`.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate

    /// Resolved once per launch. A failure renders a static unavailable state
    /// and constructs no client, store, or request.
    private let launchConfiguration = APIConfiguration.resolvedForLaunch()
    @State private var accountPresentationID = UUID()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if MessagingPreviewLaunch.isRequested() {
                MessagingPreviewRootView()
            } else {
                appContent
            }
            #else
            appContent
            #endif
        }
    }

    @ViewBuilder private var appContent: some View {
        switch launchConfiguration {
        case .success(let configuration):
            ContentView(
                configuration: configuration,
                remoteNotificationRegistrar: appDelegate.remoteNotificationRegistrar,
                notificationRouter: appDelegate.notificationRouter,
                onAccountDeletionHandoff: { accountPresentationID = UUID() }
            )
            .id(accountPresentationID)
        case .failure(let error):
            ConfigurationUnavailableView(message: error.message)
        }
    }
}
