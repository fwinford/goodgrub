//
//  CommonPlateSupportAction.swift
//  CommonPlateios
//
// Configured, student-controlled CommonPlate Support email action (W4-U1.2).
//
import SwiftUI
import UIKit

struct CommonPlateSupportContact: Equatable {
    static let infoDictionaryKey = "BrandSupportEmail"
    static let unavailableEmailAppTitle = "Couldn't open your email app"
    static let unavailableEmailAppMessage =
        "You can copy our email address and contact us from another email app."
    static let copyAddressTitle = "Copy email address"
    static let cancelTitle = "Cancel"

    let address: String?

    init(address: String?) {
        let candidate = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate, Self.isUsableAddress(candidate) {
            self.address = candidate
        } else {
            self.address = nil
        }
    }

    init(bundle: Bundle = .main) {
        self.init(address: bundle.object(forInfoDictionaryKey: Self.infoDictionaryKey) as? String)
    }

    var isConfigured: Bool { address != nil }

    var mailtoURL: URL? {
        guard let address else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        return components.url
    }

    func open(using openURL: OpenURLAction, onUnavailable: @escaping () -> Void) {
        guard let mailtoURL else { return }
        openURL(mailtoURL) { didOpen in
            if !didOpen {
                onUnavailable()
            }
        }
    }

    private static func isUsableAddress(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !value.contains(","), !value.contains(";"),
              !value.contains("?"), !value.contains("#"), !value.contains("/") else {
            return false
        }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }
}

struct CommonPlateSupportAction: View {
    let title: String
    var contact = CommonPlateSupportContact(bundle: .main)

    @Environment(\.openURL) private var openURL
    @State private var isShowingFallback = false

    var body: some View {
        Button {
            contact.open(using: openURL) {
                isShowingFallback = true
            }
        } label: {
            // A 44pt minimum hit target that still hugs the leading edge.
            Text(title)
                .multilineTextAlignment(.leading)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityHint(contact.isConfigured ? "Opens your email app." : "")
        .disabled(!contact.isConfigured)
        .alert(
            CommonPlateSupportContact.unavailableEmailAppTitle,
            isPresented: $isShowingFallback
        ) {
            Button(CommonPlateSupportContact.copyAddressTitle) {
                guard let address = contact.address else { return }
                UIPasteboard.general.string = address
            }
            Button(CommonPlateSupportContact.cancelTitle, role: .cancel) {}
        } message: {
            Text(CommonPlateSupportContact.unavailableEmailAppMessage)
        }
    }
}
