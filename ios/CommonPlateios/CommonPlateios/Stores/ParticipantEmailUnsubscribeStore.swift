//
//  ParticipantEmailUnsubscribeStore.swift
//  CommonPlateios
//
// The one state owner for the participant-authorized "Turn off email
// alerts" action (W3-N2). Entirely separate from `AlertSubscriptionStore`:
// signup presentation history and this action share no state, and this store
// never reads or writes it.
//
// `emailAlertsOff` becomes `true` only after the backend confirms the
// declarative Off result. It is session-only — never persisted — so a
// relaunch never presents Off as a durable Subscriber-status cache; nothing
// here ever claims Email On, and nothing here reads or writes push state.
import Combine
import Foundation

enum ParticipantEmailUnsubscribeFailure: Equatable {
    /// This installation holds no participant credential. The caller's next
    /// step is verification, not a retry.
    case verificationRequired
    /// The held credential is stale, revoked, or otherwise unusable. The
    /// caller's next step is re-verification.
    case authorityInvalid
    case paused
    case rateLimited
    /// Uncertain or unreachable. Safe to retry: this operation is idempotent
    /// and declarative in one direction, so a retry can never assert the
    /// wrong desired state.
    case unavailable
}

@MainActor
final class ParticipantEmailUnsubscribeStore: ObservableObject {
    @Published private(set) var isUnsubscribing = false
    @Published private(set) var emailAlertsOff = false
    @Published private(set) var failure: ParticipantEmailUnsubscribeFailure?

    private let service: ParticipantEmailUnsubscribeService
    /// Bumped by `reset()`. An in-flight attempt captures the generation it
    /// started under and checks it again before applying its outcome, so a
    /// result that arrives after the screen has already moved on to a
    /// different signup (`reset()`) cannot reapply Off — or a stale failure
    /// — for a lifecycle this action never touched.
    private var generation = 0

    init(service: ParticipantEmailUnsubscribeService) {
        self.service = service
    }

    /// `authority` is read by the caller from `ParticipantIdentityStore` at
    /// the moment of the tap — this store holds no identity itself. Refuses
    /// outright with `.verificationRequired` when there is none, so the
    /// screen can route to verification instead of attempting a call that
    /// would only be refused server-side too.
    func turnOffEmailAlerts(authority: String?) async {
        guard !isUnsubscribing, !emailAlertsOff else { return }
        guard let authority else {
            failure = .verificationRequired
            return
        }

        let attemptGeneration = generation
        isUnsubscribing = true
        failure = nil
        // Generation-gated like the outcome handling below: a stale attempt
        // finishing after `reset()` must not clear `isUnsubscribing` out from
        // under a newer attempt that reset() itself allowed to start.
        defer {
            if attemptGeneration == generation {
                isUnsubscribing = false
            }
        }

        do {
            try await service.unsubscribe(authority: authority)
            guard attemptGeneration == generation else { return }
            emailAlertsOff = true
        } catch let error as ParticipantEmailUnsubscribeError {
            guard attemptGeneration == generation else { return }
            apply(error)
        } catch {
            guard attemptGeneration == generation else { return }
            failure = .unavailable
        }
    }

    /// Returns this action to its pre-unsubscribe presentation state. Called
    /// when the screen moves on to a different signup (`AlertSignupView`'s
    /// `Use a different email`), so a stale in-session Off — or a stale
    /// failure message — from a previous address is never shown for a
    /// lifecycle this action never touched. Session-only, exactly like
    /// `emailAlertsOff` itself: nothing is read from or written to any
    /// Subscriber, and no cross-store state is created.
    func reset() {
        generation += 1
        isUnsubscribing = false
        emailAlertsOff = false
        failure = nil
    }

    private func apply(_ error: ParticipantEmailUnsubscribeError) {
        switch error {
        case .verificationRequired:
            failure = .verificationRequired
        case .authorityInvalid:
            failure = .authorityInvalid
        case .publicActionsPaused:
            failure = .paused
        case .rateLimited:
            failure = .rateLimited
        case .unavailable:
            failure = .unavailable
        }
    }
}
