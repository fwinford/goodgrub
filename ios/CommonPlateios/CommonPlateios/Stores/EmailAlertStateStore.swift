//
//  EmailAlertStateStore.swift
//  CommonPlateios
//
// The one state owner for the W4-N0 authoritative Email Request Alert state
// read. Entirely separate from `AlertSubscriptionStore` (signup presentation
// history) and `ParticipantEmailUnsubscribeStore` (the participant-authorized
// Off mutation): neither of those is Subscriber truth, and this store never
// reads or writes either one's state. `AlertSubscriptionStore`'s local
// `Check your email` presentation history is never treated as this store's
// truth (docs/system-contract.md section 9.9).
//
// `state` becomes `.active`/`.inactive` only after the backend answers under
// the participant authority that is still current *at the moment `state` is
// read*; `.unknown` covers "not yet read", "read failed", "credential
// unusable", and "resolved under a since-replaced identity" alike, so a
// caller can never mistake an unresolved or superseded read for a confirmed
// On or Off. Session-only, like the stores it sits beside: nothing here is
// persisted across launches.
import Combine
import Foundation

enum EmailAlertState: Equatable {
    /// Not yet read, unreadable, or resolved under a participant authority
    /// that is no longer current. Never presented as On or Off.
    case unknown
    case active
    case inactive
}

@MainActor
final class EmailAlertStateStore: ObservableObject {
    /// Backend-confirmed truth, tagged with the exact authority it was
    /// resolved under. Never read directly outside this file — `state` below
    /// is the only externally observable truth, and it re-checks the tag
    /// against the current participant authority on every access so a
    /// Change Email that happens without a further `refresh()` call cannot
    /// leave a previous principal's truth observable.
    private struct ResolvedState {
        let authority: String
        let value: EmailAlertState
    }

    @Published private var resolved: ResolvedState?
    /// Authorities with a refresh currently in flight. A set, not a single
    /// flag: a refresh for a newly current participant must be able to start
    /// and complete while a still-settling refresh for the participant it
    /// replaced is in flight, so only a *repeated* call for the same
    /// already-in-flight authority is deduplicated.
    @Published private var inFlightAuthorities: Set<String> = []
    /// Review triage (finding 5): a `refresh()` call that arrives while a
    /// same-authority read is already in flight must not be silently
    /// dropped — a caller reconciling truth after a meaningful boundary
    /// (Email Off/unsubscribe, Request Alerts overlay dismissal) may be
    /// calling precisely because the in-flight read started *before* that
    /// boundary and cannot be trusted to reflect it. Recorded here instead,
    /// and honored with exactly one more read once the in-flight one
    /// finishes — see `performRefresh(authority:)`.
    private var pendingReconciliation: Set<String> = []

    private let service: EmailAlertStateService
    /// Read at the start and end of every refresh, and again on every
    /// external `state` access — never cached — so a changed identity always
    /// gets a fresh answer, matching
    /// `RequestStore.resolveStaleParticipationEligibility`'s own provider use.
    private let participantAuthorityProvider: () -> String?
    /// Invoked only when the backend refuses the exact credential a request
    /// under this store actually presented, and only while that credential is
    /// still the current one — mirrors `RequestStore.applyParticipantVerdict`.
    /// The identity store owns discarding it; this store never reaches into
    /// that lifecycle directly.
    private let participantAuthorityRejected: () -> Void

    /// Current authoritative Email Request Alert state for whichever
    /// participant is current right now. Computed, not stored: a resolved
    /// value tagged with a superseded authority reads back as `.unknown`
    /// without needing another `refresh()` to notice the identity changed.
    var state: EmailAlertState {
        guard let resolved,
              let authority = participantAuthorityProvider(),
              resolved.authority == authority else {
            return .unknown
        }
        return resolved.value
    }

    /// Whether a refresh for the *current* participant is in flight. A
    /// still-settling refresh for a participant Change Email has already
    /// replaced is not reported here — it no longer describes anything the
    /// current screen is waiting on.
    var isRefreshing: Bool {
        guard let authority = participantAuthorityProvider() else { return false }
        return inFlightAuthorities.contains(authority)
    }

    func retireForCompletedDeletion() {
        resolved = nil
        pendingReconciliation = []
    }

    init(
        service: EmailAlertStateService,
        participantAuthorityProvider: @escaping () -> String?,
        participantAuthorityRejected: @escaping () -> Void
    ) {
        self.service = service
        self.participantAuthorityProvider = participantAuthorityProvider
        self.participantAuthorityRejected = participantAuthorityRejected
    }

    /// Reads current authoritative Email Request Alert state for the
    /// participant currently authorized on this installation.
    ///
    /// No credential held clears any previously resolved state and issues no
    /// network call — there is no principal to ask about, and `state` would
    /// already read `.unknown` for a `nil` authority regardless.
    ///
    /// Stale-response guard: the participant authority in effect *before*
    /// this read is captured and compared against the authority in effect
    /// *after* it completes, on every outcome. If they differ — a Change
    /// Email completed while this read was in flight — the outcome belongs to
    /// a principal that is no longer authoritative: it is neither written
    /// into `resolved` nor allowed to retire the credential that replaced it,
    /// so it can never overwrite whatever truth the new principal's own
    /// refresh has already established.
    func refresh() async {
        guard let authority = participantAuthorityProvider() else {
            resolved = nil
            return
        }
        guard !inFlightAuthorities.contains(authority) else {
            pendingReconciliation.insert(authority)
            return
        }
        await performRefresh(authority: authority)
    }

    /// The one place that actually issues a read. `refresh()` above either
    /// starts this directly or, while a same-authority read is already in
    /// flight, records the need for one — honored below once that read
    /// finishes. The follow-up read only ever starts after the one before
    /// it has fully returned, so results for the same authority are always
    /// applied in the order they were issued; no additional generation
    /// fence is needed beyond the existing per-authority tag on `resolved`.
    private func performRefresh(authority: String) async {
        inFlightAuthorities.insert(authority)
        defer { inFlightAuthorities.remove(authority) }

        do {
            let active = try await service.fetchEmailAlertState(authority: authority)
            if participantAuthorityProvider() == authority {
                resolved = ResolvedState(authority: authority, value: active ? .active : .inactive)
            }
        } catch is CancellationError {
            // No state change; a pending reconciliation for this authority,
            // if any, is still honored below.
        } catch let error as EmailAlertStateError {
            if participantAuthorityProvider() == authority {
                if case .authorityInvalid = error {
                    participantAuthorityRejected()
                }
                resolved = nil
            }
        } catch {
            if participantAuthorityProvider() == authority {
                resolved = nil
            }
        }

        if pendingReconciliation.remove(authority) != nil,
           participantAuthorityProvider() == authority {
            await performRefresh(authority: authority)
        }
    }
}
