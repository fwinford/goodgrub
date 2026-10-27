//
//  AlertSubscriptionStore.swift
//  CommonPlateios
//
// The one state owner for email alert signup. Coordinates
// AlertSubscriptionService and updates local state only after a confirmed
// backend response, per docs/system-contract.md. Owns no SwiftUI screen.
//
// Deliberately not part of RequestStore: alert signup is not a request
// operation, shares none of its collection, claim, or placement state, and
// must never inherit request-shaped error recovery. There is exactly one owner
// here — no separate view model sits beside it.
//
// One thing here outlives the process: the `Check your email` presentation, so
// reopening the app does not silently forget that a signup was submitted. What
// is written is presentation history — the address submitted and when the
// generic accepted response arrived — and never subscription truth. See
// AlertSignupPresentationStorage.swift. Everything else, including the draft
// field and every failure state, is session-only.
import Combine
import Foundation

/// Where the signup screen is in the flow. `checkEmail` is the presentation of
/// the backend's generic accepted response and asserts nothing about
/// subscription status.
enum AlertSignupPhase: Equatable {
    case editing
    case submitting
    case checkEmail
}

/// A failure that belongs beside the email field, because the address itself is
/// what has to change.
enum AlertSignupFieldError: Equatable {
    case invalidNYUEmail
}

/// A failure that belongs to the screen rather than to the address. Each case
/// exists because its honest next step differs from the others'.
enum AlertSignupFailure: Equatable {
    /// Signup is closed on the backend. Not an address problem.
    case paused
    /// Too many attempts from here. Waiting is the only next step.
    case rateLimited
    /// Receipt is uncertain. Never retried automatically, and never described
    /// as either success or failure.
    case ambiguousOutcome
    /// Bounded generic failure. Definitive, with nothing specific to offer.
    case unknown
}

@MainActor
final class AlertSubscriptionStore: ObservableObject {
    @Published private(set) var phase: AlertSignupPhase = .editing
    @Published private(set) var fieldError: AlertSignupFieldError?
    @Published private(set) var failure: AlertSignupFailure?
    /// The address as typed. Owned here rather than by the screen so that
    /// changing addresses is one state transition instead of two that can
    /// drift apart. It is draft text only, is never persisted, and asserts
    /// nothing about any subscription. A restored launch starts it empty:
    /// nothing has been typed this launch, and the field is not on screen.
    @Published private(set) var email: String = ""
    /// The normalized address this installation last submitted and received the
    /// generic accepted response for, restored across launches.
    ///
    /// It is what was shown, not what is true: it proves only that the response
    /// came back, never that a subscriber exists, is pending, is confirmed, is
    /// still subscribed, or that any email was sent.
    @Published private(set) var rememberedEmail: String?

    private let service: AlertSubscriptionService
    private let presentationStorage: AlertSignupPresentationStorage
    private var generation = UUID()

    func retireForCompletedDeletion() {
        generation = UUID()
        email = ""
        rememberedEmail = nil
        phase = .editing
        fieldError = nil
        failure = nil
    }

    /// Storage is injected with no default so no caller — and no test — can
    /// reach process-wide preferences by omitting it.
    ///
    /// Restoration happens here, synchronously and without a network request.
    /// The record is local presentation history; the backend has no endpoint
    /// that would confirm it and asking for one would be a subscription-status
    /// lookup, which does not exist.
    init(service: AlertSubscriptionService, presentationStorage: AlertSignupPresentationStorage) {
        self.service = service
        self.presentationStorage = presentationStorage

        // An unreadable or no-longer-eligible record yields nil and is
        // discarded by the storage, so a corrupt value falls back to the
        // editable form instead of failing the launch.
        if let restored = presentationStorage.loadValidPresentation() {
            rememberedEmail = restored.email
            phase = .checkEmail
        }
    }

    var isSubmitting: Bool {
        phase == .submitting
    }

    /// Records what the person has typed. Presentation state is deliberately
    /// left alone: when an error is cleared is existing accepted behavior and
    /// is not what this slice changes.
    func updateEmail(_ value: String) {
        email = value
    }

    /// `POST /api/subscribe`, at most once at a time and never retried
    /// automatically.
    ///
    /// A locally unusable address is refused here, before any request is
    /// started. The accepted phase is entered only on the backend's confirmed
    /// generic acceptance, and even then records nothing about the subscriber's
    /// actual status, because that response cannot report one.
    ///
    /// The generic accepted response is also the only thing that writes to
    /// local storage. Every failure below — local refusal, backend refusal,
    /// paused, throttled, provider-unavailable, ambiguous, and unknown — leaves
    /// any existing record exactly as it was: it neither replaces one nor
    /// destroys one, because none of them learned anything about the address
    /// that an earlier accepted response did not already establish.
    func submit(email: String) async {
        // A repeated tap while a signup is in flight, or after one has been
        // accepted, must not start a second POST: signup is a mutation, and
        // the backend's generic response gives the client nothing with which to
        // reconcile a duplicate.
        guard phase == .editing else { return }

        // The submitted address is the field's value. The screen already passes
        // what it holds, so this only keeps the owner authoritative for callers
        // that submit an address directly.
        self.email = email

        guard AlertSignupEmailValidator.isAllowedNYUEmail(email) else {
            fieldError = .invalidNYUEmail
            failure = nil
            return
        }

        phase = .submitting
        fieldError = nil
        failure = nil

        let normalized = AlertSignupEmailValidator.normalize(email)
        let expectedGeneration = generation

        do {
            try await service.subscribe(email: normalized)
            guard generation == expectedGeneration else { return }
            // Exactly the address that was sent is what gets remembered, so the
            // restored screen can never name an address the backend never saw.
            rememberedEmail = normalized
            presentationStorage.save(
                AlertSignupPresentationRecord(email: normalized, acceptedResponseAt: Date())
            )
            phase = .checkEmail
        } catch {
            guard generation == expectedGeneration else { return }
            phase = .editing
            apply(error)
        }
    }

    /// Returns to the editable form with an empty field, and forgets the
    /// remembered address on this device.
    ///
    /// It clears presentation only. What is discarded is this installation's
    /// memory of having seen the accepted response — not subscription truth,
    /// which was never recorded. The previous address is not unsubscribed,
    /// cancelled, or altered on the backend: nothing is sent, and whatever the
    /// backend already did with it stands.
    ///
    /// The field is emptied because entering a different address is the whole
    /// point of the action; leaving the previous one in place invites
    /// resubmitting the address the person just chose to move on from.
    ///
    /// This is the only deliberate way to remove the local record. It is also
    /// what makes a later failing attempt safe: submitting is refused outside
    /// `editing`, so no failure can reach a store that still holds a record.
    func useDifferentEmail() {
        guard phase == .checkEmail else { return }
        phase = .editing
        email = ""
        rememberedEmail = nil
        presentationStorage.clear()
        fieldError = nil
        failure = nil
    }

    private func apply(_ error: Error) {
        guard let subscriptionError = error as? AlertSubscriptionError else {
            failure = .unknown
            return
        }

        switch subscriptionError {
        case .invalidEmail:
            // The backend is authoritative on the allowlist, so its refusal is
            // shown against the field exactly as a local one is.
            fieldError = .invalidNYUEmail
        case .publicActionsPaused:
            failure = .paused
        case .rateLimited:
            failure = .rateLimited
        case .ambiguousSignupOutcome:
            failure = .ambiguousOutcome
        case .unknownFailure:
            failure = .unknown
        }
    }
}
