//
//  OnboardingPresentationStorage.swift
//  CommonPlateios
//
// The onboarding and discovery records are deliberately only local
// presentation preferences. They are not participant identity, a role, or
// backend authority, and they are never synchronized or sent anywhere.

import Combine
import Foundation
import SwiftUI

/// W4-O1 helping-discovery record. `nil` (no record) combined with completed
/// onboarding means a grandfathered installation, which is treated as
/// discovery-complete and never pending.
enum HelpingDiscoveryRecord: String, Equatable {
    case pending
    case complete
}

protocol OnboardingPresentationStoring: AnyObject {
    var hasCompletedOnboarding: Bool { get set }
    var helpingDiscoveryRecord: HelpingDiscoveryRecord? { get set }
}

final class UserDefaultsOnboardingPresentationStorage: OnboardingPresentationStoring {
    private let defaults: UserDefaults
    private let key = "commonplate.onboarding.completed"
    private let discoveryKey = "commonplate.onboarding.helpingDiscovery"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }

    var helpingDiscoveryRecord: HelpingDiscoveryRecord? {
        get {
            defaults.string(forKey: discoveryKey).flatMap(HelpingDiscoveryRecord.init(rawValue:))
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: discoveryKey)
            } else {
                defaults.removeObject(forKey: discoveryKey)
            }
        }
    }
}

@MainActor
final class OnboardingPresentationStore: ObservableObject {
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var helpingDiscoveryRecord: HelpingDiscoveryRecord?

    private let storage: OnboardingPresentationStoring

    init(storage: OnboardingPresentationStoring) {
        self.storage = storage
        hasCompletedOnboarding = storage.hasCompletedOnboarding
        helpingDiscoveryRecord = storage.helpingDiscoveryRecord
    }

    /// Discovery is pending only for a fresh-install completion that wrote its
    /// record. Completed onboarding with no record is grandfathered.
    var isHelpingDiscoveryPending: Bool {
        hasCompletedOnboarding && helpingDiscoveryRecord == .pending
    }

    /// Welcome completion. The discovery record is written *before* the
    /// completion flag so no interruption can produce completed-without-record.
    func completeOnboarding() {
        guard !hasCompletedOnboarding else { return }
        storage.helpingDiscoveryRecord = .pending
        helpingDiscoveryRecord = .pending
        storage.hasCompletedOnboarding = true
        hasCompletedOnboarding = true
    }

    /// pending → complete only; a grandfathered or already-complete install is
    /// left untouched.
    func completeHelpingDiscovery() {
        guard isHelpingDiscoveryPending else { return }
        storage.helpingDiscoveryRecord = .complete
        helpingDiscoveryRecord = .complete
    }

    /// The narrow local seam W4-P2 invokes after authoritative deletion
    /// success. Completion is cleared first, so an interrupted reset can never
    /// leave completed-without-record (which would read as grandfathered).
    /// Nothing in O1 calls this.
    func resetFirstUsePresentation() {
        storage.hasCompletedOnboarding = false
        guard !storage.hasCompletedOnboarding else { return }
        hasCompletedOnboarding = false
        storage.helpingDiscoveryRecord = nil
        helpingDiscoveryRecord = nil
    }

    func resetFirstUsePresentationChecked() throws {
        resetFirstUsePresentation()
        guard !storage.hasCompletedOnboarding, storage.helpingDiscoveryRecord == nil else {
            throw ParticipantDeletionError.storageUnavailable
        }
    }
}

/// Owns only the presentation-only latch for the Welcome → Home completion
/// transition. Completion truth is recorded synchronously by the store.
@MainActor
final class OnboardingFlowCoordinator: ObservableObject {
    @Published private(set) var isCompletingOnboarding = false

    private let presentationStore: OnboardingPresentationStore

    init(presentationStore: OnboardingPresentationStore) {
        self.presentationStore = presentationStore
    }

    func continueFromWelcome() {
        isCompletingOnboarding = true
        presentationStore.completeOnboarding()
    }

    func finishCompletionPresentation() {
        isCompletingOnboarding = false
    }
}
