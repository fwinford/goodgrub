# CommonPlate system contract

## 1. Scope and release boundary

CommonPlate currently supports one journey: **create → list → claim → fulfill → placed**. The iOS client and backend are for internal simulator/testing use; they are not ready for student distribution or TestFlight.

Current scope excludes authentication, chat, maps, payments, cancellation, pickup confirmation, and any no-show lifecycle. The legacy web fulfillment page remains disabled and cannot place an order.

Chat remains unavailable to users. Accepted W4-MSG1 CP1 and CP2 provide only
the dormant backend HTTP and WebSocket foundations (sections 18-19), and
accepted CP3 a dormant, unmounted iOS client foundation (section 20); they do
not extend the live journey or establish deployment readiness. Accepted CP4
adds dormant backend latest-first/backward history pagination (section 21);
accepted CP5 consumes it in the dormant iOS client (section 23). No shipping
navigation or request-linked entry point exposes messaging.

### 1.1 Accepted visual foundation (W4-F1)

CommonPlate's shared iOS presentation is native-first **Subtle Warmth**: a
restrained warm-neutral page canvas, bounded warm surfaces only where grouping
is genuinely useful, selective CommonPlate purple, and character primarily
through typography, spacing, hierarchy, and restrained color. Standard
shadows/elevation, card-per-fact, pill-everything, and purple-everywhere are
not part of the shared language. Home and participant verification use one
coherent page-level canvas rather than distinct full-page treatments.

Quiet Fraunces is reserved for CommonPlate brand and rare human-facing display
moments, with graceful system fallback; SF/system type remains for functional
and operational UI and all typography remains compatible with Dynamic Type.
Shared actions distinguish strong filled-purple primary actions, soft-purple
secondary actions, plain-purple-text tertiary actions, restrained red
destructive actions, and clearly inactive neutral disabled actions. Controls
remain moderately rounded rectangles that can grow or wrap without clipping.

Verified identity remains a simple native section with the masked address, one
clear verification indication, Change Email, and a visibly destructive Remove
Email action; final Home composition and placement remain requester-slice
owned. Participant verification is a more visibly branded but direct,
scrollable flow with standard Cancel, field-to-primary-action hierarchy, and
quiet inline code-lifetime help, not stacked form/section cards or decorative
containers. These presentation rules do not change identity or verification
runtime semantics.

### 1.2 Accepted first-use, Home, and requester presentation (W4-R1, W4-O1)

CommonPlate has one shared, role-free first-use experience (W4-O1). On a
fresh installation, iOS presents a single scrolling Welcome / How CommonPlate
Works story with no requester/helper chooser, role, account, or authority;
requesting and helping are actions, not permanent roles. The story teaches, in
order: someone posts a meal request; other students can find it on Home (and
can get notified when a new request is posted); someone chooses to help; the
helper places the order using their extra swipes (a text-only `Grubhub`
badge, no logo or brand asset); pickup details come back through CommonPlate,
which notifies the requester; and the requester then picks it up. The
helper-provided pickup timing is described only as approximate ("about
when") and is never represented as provider-confirmed readiness. The story
names no notification channel, claims no guarantee, prompts for no permission,
links to no alert setup, and teaches no in-app helper-message flow or
Screenshot Assistance. `Continue to Home` synchronously records local
completion and enters canonical Home; correctness never waits on a
presentation animation. The earlier slogan, ticket → arrow → bowl motif,
`I need a meal` / `I have extra meal swipes` chooser, and four-step
walkthroughs no longer exist.

Installations that had already completed the prior onboarding are
grandfathered: they are shown neither the new Welcome nor the discovery
treatment below. First-use completion and the helping-discovery record are
local, presentation-only state: neither is identity, a role, or backend
authority, neither is synchronized across devices, sent to the backend, or
required for any action, and no analytics authority is created. Completing
the Welcome records discovery as pending before or together with completion;
completed onboarding with no discovery record means grandfathered (discovery
complete), never pending. iOS exposes one local reset operation that clears
first-use completion first and then the discovery record, so the next first
use shows the Welcome again and an interrupted reset cannot produce
completed-without-record. Nothing in the app invokes it today; it is reserved
for a deletion slice (W4-P2) to invoke after its own accepted deletion
behavior, and onboarding neither detects nor owns deletion.

**First eligible request discovery.** After the Welcome is completed and while
discovery is pending, Home waits for a real eligible request and never
fabricates, reorders, or inserts one. Eligible means an ordinary open card in
the `Needs help` board; the student's own requests, the actively held
`Continue Helping` request, placed-order continuations, and any non-populated
board state (loading, unavailable, empty) are not eligible. The first
eligible request under the existing authoritative Home ordering is selected
(moving to the next eligible request if it disappears), and the treatment is
suppressed while the student holds an active helping reservation, returning
afterward if still pending. The treatment is temporary and presentation-only:
the real card gets lavender emphasis and an overlapping `View request` cue and
floats gently; the whole request card remains the single interaction surface,
no hit target or layout is added, and its accessibility label and trait are
unchanged. With Reduce Motion the same emphasized state is shown statically.
Discovery completes, and is persisted locally, when the student opens any
eligible request card from Home's `Needs help` board while the treatment is
active (touch or accessibility activation); deep-link or notification
navigation does not itself complete it. After completion the treatment does
not recur in ordinary use.

**Settings → How CommonPlate Works.** The existing Settings row opens a
two-destination reference hub rather than replaying onboarding: `Requesting a
meal` and `Helping someone`, each a concise reference path ending in `Return to
Home`, which returns to the canonical Home root. The hub is reachable
regardless of onboarding state, neither reads nor changes completion or
discovery state, and includes no Screenshot Assistance education.

Recurring Home presents `Request a meal`, `Find a request`, and the secondary
`Request alerts` action, followed by the utility/identity group. When a usable
verified participant identity exists, Home shows one masked verified address,
Change email, and Remove email; when it does not, Home does not fabricate an
address or require a standing verification explainer. Actions requiring
participant authority continue to present the existing verification flow on
entry. Request Food remains the existing requester flow: an unverified entry
uses the native participant-verification presentation before the form, and a
successful verification continues directly into the form without a second
participant-email field. The requester form's accepted timing, meal-swipe,
pickup-name, submission, refusal, and ambiguity semantics are unchanged.

Back controls retain stable native-looking chevron geometry and accessible
Back behavior across supported text sizes. Change email remains a quiet inline
action with an at-least-44-point touch target. Home and the Welcome and
reference screens retain their accepted responsive, scrolling, Dynamic Type,
and Reduce Motion fallbacks; functional titles use system typography, while
Quiet Fraunces remains limited to accepted brand/display moments. Dark-appearance
design for the first-use surfaces is not yet design-accepted (see the W4-O1
card in the weekly spec).

Routine/passive states default to native or inline treatment; important
non-failure states may use restrained inline emphasis; success is lightweight
by default; and no universal banner/card state system is implied. Outcome
uncertainty remains distinct from failure, using a calm blue-gray semantic
family, and every state remains distinguishable by more than color alone.
Actionable-state action choice and layout remain with the owning flow. User
facing role nouns are `student` and `helper`; motion and haptics are restrained,
meaningful, non-gamified, and Reduce Motion aware.

### 1.3 Accepted Home and navigation architecture (W4-H2)

CommonPlate has one primary product root: Home. There are no permanent Request, Help, Activity, or Settings tabs. Returning students enter the live open-request board directly rather than a recurring static launcher. Home is board-first, not role-first: CommonPlate does not create permanent requester/helper roles, and `Request a Meal` remains a prominent first-class creation action from Home. When the current student holds an active helper reservation, `Continue Helping` is a temporary priority state above the board; an ordinary open request the student posted does not itself create a separate personal Home status. Settings is a secondary shared utility route reachable from Home, not a permanent root.

#### Shared board and caller-relative ownership

A student's own open request remains visible on the shared board. Ownership is derived server-side: when `GET /api/requests` serves a verified participant (the list is verified-only since W4-R5, section 16), the response includes opaque caller-relative ownership metadata per request, computed by comparing the resolving verified participant to the request's persisted `requesterParticipantId`. The owner receives an affirmative ownership signal for their own request only; another verified participant receives no affirmative ownership signal for that request; an anonymous or unresolved caller is refused and receives no list (section 16). The response exposes no requester participant ID, requester email, credential, or another requester's identity; the existing public request privacy projection (section 3) is otherwise unchanged.

iOS represents this as own / notOwn / unresolved and must use only this authoritative signal — never an installation-local request-ID heuristic — to render the approved YOUR REQUEST presentation and to withhold the helper/reserve action from the owner. Unresolved ownership fails closed for helper actionability: the help/reserve action is not exposed or executable unless ownership resolves to notOwn. Participant-relative ownership is invalidated/reconciled across identity replacement (Change Email), consistent with the existing stale-response/current-participant fencing pattern used elsewhere (sections 3.1, 9.10).

The backend claim mutation authoritatively refuses a verified participant attempting to claim a request whose `requesterParticipantId` resolves to that same participant. This guard sits inside the existing atomic conditional claim mutation (section 4) as final mutation authority; the iOS action restriction is defense-in-depth, not the authority. A rejected self-claim creates no reservation/helper-binding/participation side effect, preserves existing claim status/visibility/expiry and one-active-reservation behavior, and reveals no requester identity.

#### Board continuity

An active claimed request is excluded from the shared board while `Continue Helping` represents it to that helper. Board ordering (ASAP first, then scheduled earliest to latest, otherwise canonical/source order; section 2.1) remains authoritative and unchanged by H2. Low Activity uses the real current board contents rather than fabricated/placeholder content. Empty Exchange and Exchange Unavailable are distinct, truthful states: Empty Exchange means zero currently eligible open requests; Exchange Unavailable means current request-list truth could not be established. W4-D2 (section 6.4) narrowly excepts this for one exact, ownership-resolved, authoritatively created request: that one card may render in `Your request(s)` during a `.loading`/`.unavailable` broader board without the board itself being treated as populated; no other stale requester/helper/discovery data is exempted.

#### Functional refresh

Native SwiftUI `.refreshable` is the sole refresh trigger/activation authority; H2 introduces no competing gesture, arming threshold, or second refresh/reload mechanism. All refresh interactions reuse the existing authoritative request reload (`fetchRequests()`); no second source of request truth exists. Initial unresolved Home loading may remain in the Loading presentation for at most 5 seconds before falling back to Exchange Unavailable if authoritative truth has not resolved; a user-initiated refresh may remain in the Refreshing presentation for at most 5 seconds, never a minimum — a result that resolves before the ceiling completes immediately. Timeout or cancellation never fabricates success, and a stale/cancelled fetch generation can never overwrite a newer generation's result (the existing stale-response/generation boundary). The success acknowledgment and the authored refresh presentation are governed by section 1.5 (W4-H3), which supersedes the earlier H2 recovery-only checkmark: a truthful successful refresh — healthy → healthy as well as each Unavailable → healthy destination — is acknowledged there, and a failure, timeout, cancellation, stale result, or unresolved unavailable is never acknowledged as success. Baseline Reduce Motion correctness (state, meaning, and operability preserved without relying on animation) remains accepted runtime behavior.

#### Settings, identity, and Request Alerts

Home reaches app-level utilities through one shared Settings route rather than permanent competing tabs. From Settings, `Change Email` actually presents the existing replacement verification flow (section 3.1); identity replacement (a successful Change Email) invalidates participant-relative state, including caller-relative ownership and cached Email Request Alert truth (section 9.10). An unverified participant's Request Alerts entry is an explicit `Verify NYU email` action rather than passive explanatory text or a bare disclosure chevron. The Request Alerts overlay's `Done` closes only its own overlay rather than performing ambient navigation. N0 Email Request Alert state (section 9.10) remains the sole authoritative Email On/Off source; a result or rejection resolved under authority a later Change Email has replaced cannot be silently applied to, or retire, the replacement identity. Email and Push remain independent channels (sections 8.6, 9.10); neither H2 nor Settings presentation infers or fabricates one channel's state from the other. Block management is reached at `Settings → Privacy & Safety → Blocked Students` for a verified participant (section 5.3); the Home Settings gear's interactive region is its full 44-point control.

### 1.4 Accepted Home continuous scroll composition (W4-H4)

Home is one coherent vertical scroll. The established header and priority area, `Continue Helping` when applicable, the caller-owned request preview when applicable, and `Needs help` all live inside that same scroll, in that order. `Continue Helping` retains its accepted priority (section 1.3) and the ownership preview follows it; `Needs help` follows ownership. There is no nested `Needs help` vertical scroll and no horizontal `Needs help` carousel. Exactly one native `.refreshable` is attached to that unified scroll.

#### Home ownership preview

Home presents the current participant's currently-open owned requests as a bounded, count-sensitive preview: zero owned requests render no ownership section; one renders `Your request` with one card and no `See all`; two render `Your requests` with both cards and no `See all`; three or more render the first two under the authoritative owned-request ordering plus a `See all` action; its visible label shows no count, and its accessibility label carries the full authoritative count of currently-open owned requests (for example `See all 4 requests`).

The two-card Home cap is presentation-only. Ownership authority and board ordering are unchanged from section 1.3: ownership remains the server-derived caller-relative signal, never an installation-local heuristic. An owned open request never appears under `Needs help`, including an owned request that the two-card preview does not itself display.

Within this dedicated owned-request zone (the Home preview and its `See all` destination), `RequestCardView`'s `YOUR REQUEST` eyebrow is suppressed, because the zone itself already establishes ownership. The eyebrow is preserved wherever a request card renders outside that zone (W4-R2).

#### See all

For three or more owned open requests, `See all` opens an ordinary subordinate destination containing the full currently-open owned-request set in the same authoritative ordering. It is not request history, not completed requests, not Edit/Remove, not requester management itself (the list offers no management control; since W4-R5 each card opens the requester-owned detail, section 16), and not a new root or tab.

#### Persistent Request a Meal

`Request a Meal` remains persistently available at the bottom of Home, outside the scrolling content, through a `ScrollView`-level `.safeAreaInset(edge: .bottom)`. That inset is the authoritative structural bottom accommodation: the final Home scroll content can be scrolled fully clear of the action rather than resting beneath it. The action carries a soft transparent-to-canvas transition above it instead of a hard opaque cutoff; that gradient is presentation only and supplies no scroll clearance of its own. There is no authored footer animation.

The action shares the same Home content column as request cards. One shared horizontal content-column inset of 24 points governs ownership cards, `Needs help` cards, and the persistent action together; they are not sized independently of each other. Authored bottom padding on the action is zero, so the remaining clearance is the device-provided home-indicator safe area, which remains native and is never overlapped or negatively adjusted.

#### Home freshness

Home resolves authoritative request data through the one existing reload path (`fetchRequests()`; section 1.3) when Home appears, and native pull-to-refresh provides manual freshness on demand. A student never has to force-quit and relaunch CommonPlate to see currently available requests.

A pull-to-refresh must actually apply the authoritative result it resolves. The lifetime of the authoritative fetch is independent of SwiftUI's own cancellation of the pull interaction: SwiftUI cancels a `.refreshable` action task as soon as the view owning the modifier is invalidated, and a refresh necessarily invalidates Home the moment it publishes its own in-flight state, so an authoritative fetch owned by that action task's lifetime would be cancelled on every pull and silently apply nothing. Transient cancellation of the refresh *caller* therefore never cancels the authoritative fetch operation.

This changes none of section 1.3's refresh authority. Native `.refreshable` remains the sole refresh trigger; there is no second refresh path, no reload authority beyond `fetchRequests()`, and no visible retry action. The initial-load and manual-refresh 5-second ceilings, the cancellation of whichever side loses the manual-refresh deadline, and the stale-response generation/collection-revision fencing that decides which result may be applied all remain exactly as recorded there; the success acknowledgment is superseded by section 1.5. Timeout or cancellation still never fabricates success.

H4 accepts refresh correctness only; the authored refresh presentation and success acknowledgment are accepted separately in section 1.5 (W4-H3).

### 1.5 Accepted Home refresh experience (W4-H3)

Home pull-to-refresh presentation and success acknowledgment. This section completes the refresh presentation that sections 1.3 and 1.4 deferred, supersedes the H2-era recovery-only checkmark, and supersedes the visible board copy `Needs help right now` and the visible `See all N` label recorded in section 1.4. It changes no refresh authority.

#### Authority is unchanged

Native `.refreshable` remains the sole refresh trigger, spinner, and loading authority. `fetchRequests()`, the 5-second deadlines, cancellation, generation/collection-revision fencing, and concurrency semantics, and `RequestStore` truth, are exactly as recorded in sections 1.3 and 1.4. There is no custom drag gesture, release threshold, or `Release to refresh` state. The authored settle and the acknowledgment are presentation only: they never trigger a refresh, decide whether one succeeded, delay or suppress refreshed data, or alter the deadline. The refreshed hierarchy is never delayed for the acknowledgment.

#### Header and rest layout

The CommonPlate header stays visually stationary during pull, active refresh, and settle, and scrolls away normally during ordinary upward scrolling of a legitimately long Home; it is not permanently sticky. Ownership between the pull-band header and the in-scroll header is derived from scroll position only, never from refresh state or timers, and exactly one header and one Settings affordance are perceived and accessibility-exposed at a time. The permanent Home rest layout, the short-content scroll range, and the fixed bottom `Request a Meal` composition (section 1.4) are unchanged.

#### Truthful success acknowledgment

A truthful successful refresh — a user-initiated native refresh whose authoritative result resolved before the deadline, was applied under the generation fence, and resolves to a healthy Home — is acknowledged by a bare 18×18 purple check and a VoiceOver-only `Updated` announcement, exactly once per eligible refresh. This applies to healthy → healthy (whether or not visible content changed) and to every Unavailable → healthy destination: the ordinary board, Continue Helping, Your request(s), and the combined Continue Helping + Your request(s) state.

The check is opacity-only: no circle or badge, no text, no scale or bounce, no haptic, and no success dwell. No visible `Updated` text appears anywhere on Home. The announcement does not move accessibility focus, and the check is neither focusable nor a persistent accessibility element.

A failure, timeout, cancellation, stale or superseded result, failed fetch (a failed refresh of a previously healthy Home preserves the existing stale-healthy behavior), or an Unavailable refresh that remains Unavailable receives neither the check nor the announcement, and no failure copy, motion, or haptic is added.

#### Authored post-refresh settle

After a truthful successful refresh and once the native spinner is visually gone, the dynamic Home content is held in a 36 pt transient lane rather than snapping to rest, and the check sits fixed and horizontally centered 18 pt below the header band — below CommonPlate, above `Needs help`, clear of `at NYU`, not in the permanent rest gap, and not travelling with the content.

- **Standard Motion:** the lane holds still for about 0.35 s; the check holds 200 ms and fades during one about 0.4 s ease-in-out return of the content to rest; the whole authored treatment is about 0.75 s. There is no overshoot, bounce, or oscillation, and the spinner and check never appear together.
- **Reduce Motion:** the same lane and fixed check geometry; a 0.5 s static hold, the same 200 ms check hold, then one about 0.2 s ease-out return. No alternate success state or directional or celebratory motion exists, and the spinner remains native.

#### Context-bound lifetime and stale retirement

The acknowledgment is presented only if, at the moment it would begin, Home is still the presented destination and the scroll position is still within the top/header-owned refresh context. Otherwise both the check and the announcement are suppressed together; a suppressed acknowledgment is never queued, deferred, or replayed, and suppression never cancels the refresh or discards its data. A new refresh or repeated pull retires any older pending or visible acknowledgment, so an older check never stacks with a new spinner and at most one `Updated` is announced per eligible refresh.

#### Successful-recovery fallback

For a successful Unavailable → healthy recovery whose native reading is already at or within 6 pt of rest, with no transient lane in which to present the acknowledgment, neither the check nor `Updated` is emitted. The recovered data applies normally, no overlay is placed over ordinary Home content, and the recovered Home remains accessibly represented. The runtime cannot independently observe a visually open lane in every case; that accepted residual is recorded in the weekly spec and is not a guarantee that this fallback is never taken while a lane is visually open.

#### Board copy and ownership overflow

The Home board heading is `Needs help` in every state. For three or more owned open requests the heading remains `Your requests` and the trailing action is `See all` with no visible count; its accessibility label retains the full open-request count (for example `See all 4 requests`), it keeps a minimum 44 pt target, and at large Dynamic Type it may move below the heading. There is no `See all` for zero, one, or two owned requests. The destination, its full carried request set and order, and ownership semantics are unchanged.

#### Verification boundary

The rendered pull feel, VoiceOver announcement and focus behavior, accessibility frames, and hit-testing while the authored offset is active were verified manually on a physical iPhone by Faith, using a Debug build with a temporary LAN endpoint against a synthetic stub backend; they are not established by the automated suite. Release, Archive, and TestFlight behavior is not established (section 11).

### 1.6 Accepted first-download through first-Home corrections (W4-UI1 CP1)

Faith accepted CP1 on 2026-10-24 after her physical UX walkthrough,
independent correctness review, four quality-review perspectives and bounded
corrections. This is local acceptance, not deployment or release qualification.

The Welcome headline is `Meals move through the community.` Its
`See how it works` label stays stationary; only the chevron below it moves
downward from rest, never above the label (motion refined in section 1.7). Reduce Motion disables that
motion. Story cards reveal once when visible without changing layout;
Reduce Motion and VoiceOver show them immediately. Existing navigation,
local onboarding completion, role-free behavior and Dynamic Type remain.
The timeline makes the handoff explicit: the requester finds a meal on
Grubhub and copies its details into GoodGrub; a helper orders through Grubhub,
then shares the order details in GoodGrub; GoodGrub notifies the requester
when pickup details are ready, and the requester uses those details to
collect the meal. This does not claim provider-confirmed meal readiness,
delivery, reading or pickup, nor change notification-channel ownership.

Verification uses a neutral GoodGrub wordmark and campus-purple `at NYU`,
matching Home, and concise `Code sent to <email>.` copy. Malformed addresses
remain editable with inline `Enter a valid email address.` feedback;
well-formed non-NYU addresses receive `Enter a valid NYU email address.`
Neither issues a code. Eligibility remains exactly `nyu.edu` and
`stern.nyu.edu`; the explicit `Not at NYU?` action still opens the unsupported
school screen. Backend rejection of a stored identity still retires its
authority, but the verification screen shows no revocation notice.

A resend/cooldown response on the current flow's first send attempt stays on
email entry and never fabricates a successful send. Only an address with an
already confirmed send in that same flow may return to code entry after a
cooldown response; replacement-recovery handling remains guarded. Confirmed
send state is private, in-memory and cleared when the flow starts or ends.
The backend alone establishes code validity and verified authority.

Real-provider email delivery and Release qualification remain unverified;
accepted automated, isolated API and physical evidence is in `docs/testing.md`.

### 1.7 Accepted Home, first-request guidance and verification corrections (W4-UI1 CP2)

Faith accepted CP2 on 2026-10-26 after an interactive Simulator walkthrough
against an isolated local backend, the independent ledger/deletion review and
four quality-review perspectives. She waived the targeted physical-iPhone
check for CP2 only. This is local acceptance, not deployment or release
qualification. Request, reservation, status meaning, authoritative ordering,
navigation and backend behavior are unchanged.

**Home.** Continue helping cards have no trailing chevron; the whole card
stays tappable with pressed feedback. The empty Needs help state keeps
`No open requests right now` and the existing Request Alerts action, with only
a subtle accent, no promotional copy and no fabricated activity. The fixed
Request a Meal CTA and existing Home scrolling remain. In the unavailable
state the `Pull down to refresh` text stays still; only its arrow makes two
small downward movements when the state appears, then stops. Reduce Motion
disables that movement and native `.refreshable` is preserved. Status accents
use semantic roles: Available to helpers is neutral; Being helped and a
helping timer above five minutes share amber; Confirm pickup and a helping
timer at five minutes or less share an urgent red, in both appearances. The
urgent timer keeps its clock icon; the non-urgent timer keeps its dot. Confirm
pickup uses a less saturated warm dark surface; an urgent helping card uses a
subtle red-tinted surface and border. A wrapped mixed Meal Swipes + Dining
Dollars title uses a more compact line rhythm without fixed card heights.
ASAP/Later stays off Needs help cards.

**First-request Success guidance.** A verified Participant's first
successfully created request on a device shows `Request posted!` and
`We'll let you know when a student places your order.` for 3.5 seconds
(3,000 ms settle + 500 ms landing), announced together. Later posts show
`Request posted!` only, with the existing ~1.6-second dwell and title-only
announcement. Landing, the single success haptic and Reduce Motion parity are
unchanged. The copy assumes notifications are enabled; provider acceptance is
not verified delivery or reading. The signal is device-local presentation
memory, not request history: `FirstRequestGuidanceLedger` stores in
`UserDefaults` only a SHA-256 digest of the Participant identifier parsed from
the current canonical authority, never the identifier, authority or any
credential. It is read when Success appears and recorded only when the
presentation finishes, so copy and dwell stay stable during it. It records only
while P2's installation presentation generation is current, the exact posting
authority is still the verified current authority and no deletion record or
freeze is active. A non-canonical or non-current authority shows no guidance.
Reinstall or a new device shows it again. No backend lifetime-history endpoint
exists or is implied. The first-time Home empty-state caption remains deferred.

**Verification.** Code entry keeps Verify as the only filled primary action.
`Send a new code` uses the shared outlined secondary action with its error
directly below; `Use a different email` is a quiet footnote-weight link with a
44 pt target. While the backend's `resendAvailableAt` is in the future, the
secondary action reads `Send a new code in M:SS`, is disabled and updates each
second; at that instant it enables. A successful resend adopts the newly
returned timestamp. The client invents, persists and changes no cooldown
policy. Submitting an eligible email never fails silently: the visible
`Sending…` state remains, a refused or unreachable request renders an inline
error, and verification errors are announced to accessibility on both the
email and code steps. If the form is shown without an active verification
flow, Continue reports a temporarily-unavailable error, sends nothing and
never claims a code was sent or retries automatically.

**Other corrections.** The Welcome chevron (section 1.6) performs a repeating
2.0 s cycle: an 8 pt downward hop then a 4 pt hop within the first 18%, then
rest; it never rises above its resting position, `See how it works` stays
still, and Reduce Motion turns it off completely. When no scheduled start is
left today, Request Food reads `Scheduling is closed for today. ASAP only.`
and a late Later selection is refused with
`Scheduling is closed for today. Choose ASAP to post this request now.`; timing
authority is unchanged. The requester `View menu on Grubhub` link (section 14)
and the unsupported-school screen (section 24) changes are recorded there.

Accepted automated, hosted and Simulator evidence and the verification
limitations are in `docs/testing.md`.

## 2. Request lifecycle and availability

| Persisted state | Meaning | Effective availability |
| --- | --- | --- |
| `open` | Awaiting a helper | Available only before `expiresAt` and with at least five full minutes remaining to claim. |
| `claimed` | Reserved for one helper | Not publicly available while its active claim has not expired; it may become claimable again after claim expiry if the request itself remains eligible. A claimed request carrying the post-Yes external-order-risk authority (section 5.3) is never claimable or advertised again. |
| `placed` | Placement was recorded | Never available. |

Backend time is authoritative for availability, the five-minute claim threshold, and claim deadlines. Public list membership is effective availability, not simply the stored `status`; listed records are projected as `open`. `expiresAt` ends availability. `deleteAt` controls TTL retention: it initially matches `expiresAt`, while placement retains the request for seven days from `placedAt` by moving `deleteAt` without changing `expiresAt`.

### 2.1 NYU campus time and request availability windows

`America/New_York` is the canonical request timezone, named by IANA identifier so every conversion is DST-correct on its own. Backend time is authoritative for all request timing and availability; iOS presents and submits Later timing in NYU campus time even when the device is set to a different timezone (verified on a physical device configured to non-Eastern Phoenix time, with no source-text-only reliance).

Two backend-owned absolute instants define a request's window: `visibleFrom` (when helpers begin seeing it) and `expiresAt` (`visibleFrom` plus a three-hour duration). An ASAP request becomes visible from the backend creation instant; a Later request becomes visible from its accepted scheduled start. Both instants are written explicitly at creation and are never accepted from a client.

A Later start earlier than the creation instant is refused (`400 INVALID_REQUEST`) ahead of the daily-limit read, the write, the requester confirmation email, and helper notification, so a refused create has no side effect; the requester's Later selection is never silently converted to ASAP.

A future Later request is not publicly visible before its `visibleFrom`: the public list, helper-alert selection, and the claim mutation all apply the same visibility rule, and direct public detail (`GET /api/request/:id`) reveals no request content and answers `409 REQUEST_NOT_YET_AVAILABLE` (`"This request is not available to help with yet."`) rather than `404`, so "come back later" stays distinct from "no such request." Claiming before `visibleFrom` answers the same `409 REQUEST_NOT_YET_AVAILABLE`. Legacy rows persisted before `visibleFrom` existed carry no value for it and are treated as visible from creation, so they remain unaffected.

Presentation: the three-hour availability rule is explained once, where the requester chooses timing; downstream request/helper surfaces (lists, detail, requester and helper email, digest email, push) do not repeat it. The shared backend timing label for an ASAP request is `ASAP`; Later surfaces use the concrete backend-derived start/end window text instead of restating the rule.

## 3. Public and private data boundaries

The public request projection is allowlisted: `id`, vendor, food, pickup-window text and bounds, persisted/projection status, `createdAt`, and `expiresAt`. It is used for list and detail responses.

| Private data | Boundary |
| --- | --- |
| Requester email and pickup name | Never public. Pickup name is returned only in the successful claimant's claim response. |
| Claim token, token digest, claim deadline, claim timestamps | Never public. The raw token is claimant authorization; the backend persists only its digest. |
| Confirmation token, its digest, expiry, and send-ownership fields | Never public. The raw confirmation token exists only in the emailed link; the backend persists only its SHA-256 digest. |
| Used-confirmation-token receipt (`lastConfirmedTokenDigest`, `lastConfirmedTokenExpiresAt`) | Never public. |
| Unsubscribe signing secret (`UNSUBSCRIBE_SIGNING_SECRET`) | Never public and never emailed. It is the only thing that makes an unsubscribe link authentic; nothing derived from it is stored. |
| Participant verification codes, participant authority credentials, and participant identifiers | Never public. A raw code is emailed only to the address being verified; the backend stores no raw code, and a stored device authority credential is private to that installation. |
| `deleteAt`, requester-notification state, fulfillment/contact fields, and other internal fields | Never public. |
| Participant Block records, the post-Yes `externalOrderAffirmed` request marker, the `contactMessageWithheld` marker, and `blockFenceEpoch` | Never public and never projected on any list, detail, requester, placement, or error response (section 5.3). A caller sees only its own Blocks as interaction context, and only affirmative-only restriction signals on its own reservation. |
| Placed-order evidence (`PlacementEvidence` row, its image bytes, MIME type, and `byteLength`) | Never public and never projected on any list, detail, helper-facing, or error response. It is absent from the fulfillment email, from every notification, and from every log (section 5.4). |
| Helper email | May be sent to the requester in the committed-placement email for coordination. |

### 3.1 Verified participant identity

The NYU allowlist (`nyu.edu` and `stern.nyu.edu`) establishes only that an address is eligible to become a participant; it does not establish mailbox ownership, enrollment, a human identity, or equivalence between aliases, vanity addresses, or `+tag` variants. Mailbox control is established only when that exact normalized allowed address successfully completes the participant email-code verification flow. That resulting normalized address is the participant principal.

Participant identity is distinct from Subscriber identity, Push Installation identity, claim-token authorization, and unsubscribe credentials. A Participant is backend authority for an acting requester or helper; an Installation is only device-local notification-routing metadata, and a Subscriber is only the email-alert lifecycle. Neither substitutes for participant authority.

Participant actions require usable backend-verifiable participant authority. Request creation derives the requester principal from that authority and binds it to the Request; a caller-supplied legacy `email` field, when present, must match the verified principal and is never the source of the persisted requester identity. The atomic claim grant likewise binds the verified helper principal. These bindings remain private.

Fulfillment uses the helper principal bound to the claim, never a caller-entered helper email. A valid unexpired claim created before this binding existed remains narrowly fulfillable through its existing claim-token authorization only when `helperParticipantId` is physically absent; this compatibility path does not authorize a post-identity claim without participant binding.

After successful verification, an installation is designed to retain its private authority across ordinary launches while it remains usable; backend rejection, revocation, missing, or malformed stored authority requires verification again. A reinstall or new device has no automatic recovery and requires verification again. Change Email leaves the existing authority active until the replacement address has successfully verified, then applies the replacement only to future actions; existing request and claim bindings remain unchanged. These device-lifecycle properties are accepted runtime behavior, with physical Keychain/device proof still recorded as an environmental limitation in `docs/testing.md`.

On iOS, selecting Request Food requires usable verified participant identity before the request form is initially exposed. If no usable identity exists, iOS presents the existing participant-verification flow first; successful verification continues directly into Request Food, and an already-verified or restored identity enters Request Food directly, in both cases without another editable participant-email field. Request submission remains bound to this verified participant authority. If that authority is lost after the form was already legitimately admitted, the form and its in-progress draft are preserved rather than discarded, and recovery uses the same in-form reverification continuation Request Food already provides at submission; authority loss alone does not return the requester to the pre-form verification screen. Change Email continues to require reverification, per the device-lifecycle properties above.

Remove Email is a distinct app-level action from Change Email and requires explicit confirmation. Safe removal forgets only the current installation's verified participant identity and immediately returns that installation to unverified; Request Food and Help require verification again. It performs no backend Participant deletion and rewrites no historical Request, reservation, fulfillment, or RequestParticipation ownership. W3-H2 participation remains bound to the original verified principal: removing and reverifying as the same principal does not bypass prior participation, while a genuinely different verified principal does not inherit the former principal's history. Subscriber/email-alert state and Push Installation/preferences remain independent.

Remove Email is refuse-only while participant-bound work or recovery makes forgetting unsafe, and remains unavailable until the app has established removal safety for the current process. An active H1 reservation or participant-authorized fulfillment state, including unresolved ambiguous-fulfillment recovery, blocks removal. An unresolved W3-D1/W4-D2 request-create recovery also blocks removal, in both the stable-unresolved and identity-unavailable states (section 6.4). Unknown or inconclusive H1 reconciliation fails closed rather than allowing removal. I4 performs no assisted release, fulfillment mutation, D1 mutation, or backend identity deletion.

While removal safety has not yet been established, Settings shows a loading presentation only for as long as a relaunch-reconciliation read is actually in flight; once that read has failed or otherwise remains unresolved and is no longer actively running, Settings instead shows `Remove Email is temporarily unavailable.` with no spinner (W4-R2). This is presentation only: it changes no removal-eligibility semantics, and Remove Email remains blocked in both cases exactly as this section already requires.

Verified participant identity is app-level CommonPlate identity, not Request Food content. Home presents the currently verified participant identity when one exists and provides the accepted app-level identity controls; this is the sole identity-presentation source. When no usable verified participant identity exists, Home need not present a standing verification explainer; actions that require verified participant authority present the existing verification flow on entry. Change Email preserves the current verified authority until the replacement address successfully verifies, consistent with the device-lifecycle properties above.

Participant verification and Change Email present their existing lifecycle
action-first, with the field and its action leading and supporting
eligibility/purpose/replacement explanation visually secondary beneath.
CP1's accepted entry, cooldown and silent stale-identity presentation rules
are recorded in section 1.6; backend code validity, expiry, credentials,
participant principals, persistence and authorization remain unchanged.

Request Food contains no Contact section and no verified-participant-email row: it does not display the verified participant email and does not ask the requester to enter or reconfirm a participant email. It still submits using the accepted verified participant authority established before the form was reached (section 3.1 above). The requester email remains private participant identity and is not presented as information shared with helpers.

The legacy website has no participant-verification UX. Until the separate Week 6 work exists, website request creation is deliberately non-actionable and cannot bypass participant authority. This does not define later website verification behavior.

## 4. Claim contract

Claiming requires usable participant authority and is an atomic conditional mutation, so one eligible attempt wins and binds that verified helper principal. A verified participant may hold at most one active reservation across requests, app processes, devices, and installations; different verified participants may reserve independently. The winning response returns the raw token once; iOS keeps it only in private in-memory store state, while the backend keeps an HMAC digest. Subscriber and Push Installation identities are neither participant identity nor reservation authority.

An active reservation lasts at most 15 minutes and is capped by `expiresAt`. Leaving, backgrounding, or terminating CommonPlate does not release it. Relaunch resolves the active reservation from verified participant authority; it never persists or reconstructs the raw claim token. Continuation establishes an active reservation only from a current reservation whose embedded request is `claimed`; explicit absence establishes none, while transport, server, decoding, authority, or contradictory-response failures remain unknown and do not fabricate lifecycle state or clear warning state. A restored reservation captures the exact participant authority that established that reservation lifecycle, so a later Change Email affects future actions but does not rewrite authority for the restored reservation. A backend rejection retires a presented participant credential only when it is still the app's current credential; a stale rejection cannot retire a newer replacement.

Reservation actions require the reservation's exact authority. The raw token remains the preferred in-process path; verified participant authority is the additive continuation path when that token no longer exists. Explicit release atomically invalidates a currently authorized reservation and immediately returns the request to availability when otherwise eligible; a request carrying the post-Yes external-order-risk authority is instead retired in place and never returns to availability (section 5.3). Local reservation state clears only after `released: true` is confirmed. A release cannot reopen a placed request or another participant's reservation, and released authority cannot later extend, release, or fulfill. Release, extension, and fulfillment use conditional lifecycle mutations, so concurrent operations have one coherent winner; iOS also mutually excludes their local in-flight and ambiguous-fulfillment states.

Its holder may receive exactly one five-minute extension only when the full extension fits before request expiry; a participant Block does not withhold it (section 5.3). iOS offers extension only while that remains true; backend timing and mutation results remain authoritative. A readable `INTERNAL_FAILURE` from claim is ambiguous: iOS does not automatically retry it and never permits ordering without a confirmed active claim and its raw token or reservation-scoped continuation authority.

## 5. Fulfillment contract

Fulfillment requires a valid, unexpired active reservation authorized by its raw claim token or, after continuation, its exact reservation-scoped participant authority. The raw-token path remains preferred whenever a token is still held. Fulfillment reuses the verified helper principal atomically bound at claim grant, rather than trusting any helper email supplied by the caller. Every new fulfillment also requires one valid placed-order screenshot (section 5.4). In one MongoDB transaction, the backend conditionally transitions the request from `claimed` to `placed`, creates its Fulfillment ledger record, and creates its private `PlacementEvidence` row; the three commit or abort together. A unique Fulfillment `requestId` index independently protects one fulfillment per request. The sole compatibility exception is an active pre-W3-I1 claim whose helper binding field is absent, as defined in section 3.1.

`orderNumber` is a digits-only string, not a number; leading zeroes are preserved. The requester email is submitted only after placement commits. Email failure does not undo placement, and failure to clean up the database session cannot replace the committed placement result.

Fulfillment `INTERNAL_FAILURE` is ambiguous. iOS performs one read-only request-status check, then permits at most one exact-payload CommonPlate-only resend using the retained in-memory submission (including the identical screenshot, section 5.4) and its exact original authorization (raw token or reservation-scoped participant authority). It never instructs the helper to place another external order.

After a confirmed placement, iOS ends the client helper lifecycle at once: the active reservation and its claim authorization are cleared. The success presentation is presentation only, has no lifecycle authority, and retires itself when it returns the helper to Home (section 5.2); it neither gates nor authorizes a new claim. There is no Got It, Done, or other acknowledgement control.

Fulfillment remains request/claim-bound: the requester placement email is addressed to the requester's own submitted address, tied to this specific request and its committed placement, never to a general participant contact channel. For a verified-helper placement, that email's `Reply-To` may carry the claim-bound helper's own verified email address, so the requester can coordinate directly with the helper about that order, except when the pair is fenced by a Block, in which case no helper address is sent (section 5.3). Where the accepted implementation cannot establish a verified helper address for the placement (the pre-W3-I1 compatibility path in section 3.1), no `Reply-To` address is fabricated or substituted; the email is sent without one. V1 therefore does not guarantee that participants' real email addresses remain mutually hidden from one another. Private, request-scoped email relay and mutual participant-address privacy (W3-M1) are deferred to V2/post-pilot; product and privacy-facing copy must describe this V1 direct-coordination behavior truthfully rather than promising hidden addresses.

### 5.1 Helper participation continuity (W3-H2)

Once a verified W3-I1 participant principal has successfully acquired reservation authority over request R — the atomic claim-grant conditional mutation actually committing for that principal — that same principal can never successfully acquire R again. This is durable: release and passive claim expiry do not erase it, and it survives across devices, reinstalls, and newly issued authority for the same principal. A failed or raced attempt that never wins authority consumes no participation. Other eligible verified participants remain able to acquire R independently. This invariant is separate from and does not alter section 4's one-active-reservation-across-requests invariant; both apply to the same claim attempt without conflict.

The invariant is bound to the exact normalized verified W3-I1 participant principal, never to device, installation, or push identity. Reverification of the same principal preserves enforcement. A successful Change Email to a genuinely different verified email establishes a different participant principal for future actions; the historical participation record remains bound to the original principal and does not constrain the new principal. This does not create a hidden cross-email human identity.

Participation history is durable, append-only backend state: the `RequestParticipation` collection records one row per successful `(requestId, participantId)` acquisition, written once inside the same transaction that grants the claim, and never updated or cleared by release, expiry, or a later reacquisition attempt. `Request.helperParticipantId` remains current-holder state only (overwritten on reclaim, `$unset` on release) and is not the source of historical truth. A unique `(requestId, participantId)` index is the sole concurrency primitive behind "at most one successful acquisition per participant per request"; `claimRequest` consults this collection before its own conditional grant filter, and a race that slips past the pre-check still loses the transaction on that index. This index is explicitly established during application startup (`RequestParticipation.createIndexes()`, before the process listens), so claim traffic is never accepted against a database that has not established the guarantee. Backend claim rejection remains authoritative for stale or racing clients regardless of what a client believes.

A request a verified participant has previously successfully held is excluded from that participant's own eligible request-list results; every other eligible participant's list is unaffected, because the exclusion is scoped to exactly the resolving caller's own participant id. Participant-aware request-detail responses may expose only the resolving caller's own already-participated boolean for that request, alongside the existing public request projection and privacy boundary (section 3); since W4-R5 a caller with no usable verified participant identity is refused with the shared structured participant-authority refusal and no request content (section 16), not answered as though anonymous. Caller-specific detail responses use the existing cache-isolation boundary that prevents one participant's resolved result from leaking into another's rendered state. iOS does not expose or execute Reserve unless authoritative eligibility for the current request and the caller's current participant key resolves to eligible; a stale or mismatched resolution — including one resolved for a since-changed participant identity — is never treated as eligible.

If a placement has durably committed but the client lost usable completion state, an authoritative backend read of participant-scoped placed-request truth (`Request.status === "placed"` plus its retained `helperParticipantId` binding) reports it on relaunch or reconstruction. Confirmed placement completes the helper relationship, so iOS reconciles that report to the ordinary helper-available state and reconstructs no success presentation, haptic, or acknowledgement gate. It never recreates reservation authority or a raw claim token, and never exposes a second Place Order or other second-external-order affordance for that request. The read is bounded by the request's existing retained lifetime (`deleteAt`/`PLACED_RETENTION_MS`, section 2): a request at or past its retention horizon is not reported as placed merely because TTL deletion is asynchronous. Fulfillment already releases the participant's reservation lock server-side on placement (section 4).

### 5.2 Helper Message suppression (W4-U1.1)

The helper's optional fulfillment Message remains fulfillment/email-only and is filtered authoritatively at the fulfillment mutation by the same deterministic, provider-free filter that governs requester text (section 6). A matching Message never blocks legitimate placement: the transaction in section 5 still commits exactly once, the Message is not persisted, and it is not included in the requester placement email, which is still sent without it. No participant text is sent to any external moderation provider.

The only durable suppression truth is a content-free `contactMessageSuppressed` marker (`select: false` on the Request model), written in the same atomic placement update. The Request schema carries no `contactMessage` field. Neither the marker nor any response names the matched term, category, or field. Pre-filter placed rows that still carry a persisted Message are not migrated and expire with the existing placed retention (section 2).

Suppression status is distinct from provider email status (`notificationStatus`, section 8.2): provider acceptance is not delivery, and suppression is never inferred from email status or from Message absence. The fulfillment response and the participant-scoped placed read (`GET /api/participant/active-reservation`) carry an affirmative-only `messageSuppressed: true` to the placing helper; it is absent otherwise, never an explicit `false`, and the public request list/detail projection is untouched (section 3).

Fixed Pickup ETA: fulfillment accepts exactly `ASAP`, `15 minutes`, `30 minutes`, `45 minutes`, or `60 minutes` (after trimming); any other value, including free text, is refused before fulfillment work. ETA is therefore not moderated text.

**Ambiguity recovery.** The Section 5 recovery contract is unchanged. After the single read-only status check proves placement, iOS may make one additional participant-scoped placed read solely to establish suppression, and only when the submission carried a non-blank Message. An inconclusive result leaves suppression unestablished: confirmed placement is applied with or without it and suppression is never fabricated. Relaunch does not reconstruct transient suppression UI. If the one manual repeat of an exact resend receives `REQUEST_ALREADY_PLACED`, the existing already-recorded notice is shown without a suppression statement.

**Success presentation.** When authoritative fulfillment truth establishes both placement and suppression, the helper success state is the ordinary success presentation with headline `Thanks for helping someone out.` and a subordinate `Message not sent` card (`Your message didn’t meet CommonPlate’s guidelines.`); it does not claim failure, shows neither email-result line, and introduces no retry, edit, acknowledgement, or second-order control. Ordinary non-suppressed success variants are unchanged. Automatic return to Home occurs exactly once. When VoiceOver is not running at resolve, Home follows an approximately 2-second readable dwell. When VoiceOver is running at resolve (read once per confirmation), Home occurs at the later of that dwell and successful completion of the complete success announcement, with at most one repost on interruption, no second haptic, and a bounded active-time fallback so the screen cannot remain indefinitely (9 seconds in the accepted implementation, never more than 10). The announcement carries the same strings as the visible state.

### 5.3 Participant blocking and interaction fencing (W4-U1.3)

**Block authority.** A Block is a durable, owner-scoped `ParticipantBlock` record in its own collection, unique per ordered `(blocker, blocked)` pair and with no TTL, so it outlives the Request that supplied its context (`deleteAt`). It carries the two private participant references (`select: false`, never projected) and only an interaction-context snapshot: the blocked party's role (`requester` or `helper`), the request's dining location, and the request's creation time. No name, NYU email, participant identifier, or order content is stored for or projected from it, and the snapshot is deleted with the row on Unblock.

Block is contextual only. `POST /api/request/:id/block` names a request and nothing else; the backend resolves the counterpart from the request's private participant authority. There is no student directory, global person lookup or search, arbitrary-email Block, or participant-ID Block. A helper may Block the requester of a request the helper could legitimately have opened (visible now); a requester may Block only the recorded helper of the requester's own placed, still-retained request; every other target, a request not yet visible, and a self-target are refused as `404 REQUEST_NOT_FOUND`. Repeating a Block for the same ordered pair is an idempotent no-op that keeps the original snapshot. The iOS client offers the helper-side entry on Request Detail and, once W4-R3 is accepted, on the helper Waiting detail (section 22); the requester → helper creation authority is backend-only.

**Pair fence.** A pair is fenced while a Block exists in either direction. The two directions are separately owned records: a fence persists after one is removed if the other remains, and no response exposes the owner or direction of any Block as a field. Unblock (`DELETE /api/participant/blocks/:blockId`) removes only the caller's own record, prospectively: it never resurrects an expired request or an old reservation, and never alters `RequestParticipation`, placement, fulfillment, or pickup truth. A record that is missing and a record owned by someone else are the same `404 BLOCK_NOT_FOUND`. `GET /api/participant/blocks` returns only the caller's own records, as interaction context.

**Where the fence is enforced (server-authoritative, never UI-only).**

- *Board discovery:* a caller's list excludes requests authored by any participant fenced from them, applied in the query ahead of the fixed list limit. The list is served only to a verified participant (section 16), so every served list is fenced for its caller.
- *Request Detail:* a fenced counterpart's request is answered exactly as a request that does not exist (`404`), ahead of the not-yet-available refusal, so a request ID does not bypass the fence. Exempt, because it is not new interaction: the request's own requester, and the participant currently holding the request as helper (its placement, or its live unexpired reservation).
- *Claim:* inside the claim transaction, in the same snapshot as the grant and ahead of the participation check, answered as an ordinary `404 REQUEST_NOT_FOUND`. Every Block write also writes both participants' private `blockFenceEpoch`, and every claim writes the claimant's own Participant document, so a concurrent Block and claim conflict and one is retried against a snapshot that contains the other: no reservation is granted across a committed Block.
- *Not fenced:* Add 5 minutes (extension), release, and placement. A Block fences new interaction; it never strips a reservation or placement the participant already legitimately holds.

**Block while helping.** While the caller holds a live reservation on the request, the Block body must carry `externalOrderPlaced`; without it the request is refused `400 BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED`.

- *`No` (`externalOrderPlaced: false`):* Block and the ordinary release commit in one transaction through the one accepted release mutation, so the request returns to ordinary availability for other eligible helpers. While `PUBLIC_ACTIONS_PAUSED` governs release, neither commits (`503 PUBLIC_ACTIONS_PAUSED`), and a reservation that moved after the attempt began (an extension) commits neither (`409 RESERVATION_STATE_CHANGED`).
- *`Yes` (`externalOrderPlaced: true`):* the Block commits with the reservation left untouched, and, in the same transaction, a private, content-free, `select: false` request marker `externalOrderAffirmed` is written, pinned to the exact reservation the answer was given for (same helper binding and deadline). A `Yes` is accepted at the expiry boundary only while the request is still `claimed`, still bound to the same helper, not released or re-claimed, and the request itself unexpired.
- *Refused `Yes`:* if the caller no longer owns the reservation (it was released, re-claimed by another helper, placed, retired, or the request expired), the operation answers `409 RESERVATION_STATE_CHANGED` and writes no Block, no fence bump, and no marker, and touches nothing of another helper's reservation. It never reports Block success while failing the post-Yes transition.
- Block and Unblock are safety controls and are not behind `PUBLIC_ACTIONS_PAUSED`; the `No` branch is gated only because it includes release.

**Post-Yes request.** While `externalOrderAffirmed` exists the request is never claimable and never advertised: the shared effective-availability predicate, the claim filter, the board, detail, helper alerts, digests, and push eligibility all exclude it, whatever its stored status or deadline says. This holds after the helper's Stop, after passive reservation expiry, and after Unblock, and it ends only with the Request itself (ordinary `deleteAt` retention). The marker is never projected on any list, detail, requester, placement, or error response.

- *Add 5 minutes* remains available under the ordinary one-use and fit-before-expiry rules and never answers differently because a Block exists, in either direction.
- *Stop helping* remains available, is an ordinary release-class mutation for pause, rate limiting, authorization, version-pinning, and in-flight/ambiguous-fulfillment exclusion, and for a marked request retires the reservation in place: the deadline, claim-token digest, helper binding, and one-use marker are removed and the helper's active-reservation lock is cleared, while the request stays `claimed` and never becomes `open`. No placement is fabricated, the external order is never claimed cancelled, the request is not offered to another helper, and the Block remains effective. A Stop without the marker is the existing release unchanged. The retired authority can no longer extend, release, or fulfill, and answers like an ordinarily released reservation; the stopped helper cannot resume it, may help another eligible request, and cannot re-claim this one (section 5.1).
- *Concurrency:* Stop, extension, fulfillment, and expiry resolve through the existing conditional, version-pinned mutations to one coherent winner. A fulfillment that wins is authoritative `placed` truth; a later Stop cannot undo it.
- *Finish helping* keeps ordinary authoritative fulfillment, ambiguity, and success.

**Active-reservation read.** `GET /api/participant/active-reservation` adds two affirmative-only fields to a live reservation, each absent rather than `false` when not established: `directContactRestricted: true` when a pair fence exists in either direction (it states that optional direct contact is unavailable, never who blocked whom), and `stopReturnsHome: true` when the marker exists and no pair restriction remains (so a requester-blocked helper's read is the same with or without the marker). They carry no Block owner, direction, or marker.

**Placed-order continuity and direct contact.** A Block never refuses, alters, or undoes placement, and never reverses a placed order. For a fenced pair the placement transaction still commits exactly once; the optional helper Message is not persisted or emailed (the content-free `contactMessageSuppressed` marker plus a second content-free `contactMessageWithheld` marker, written in the same atomic update); and the requester email carries the order facts without the helper `Reply-To` (section 5), re-checked after commit and withheld when the answer cannot be read. A Message withheld by the fence is reported only to the placing helper (`messageSuppressed` with `messageWithheld`, never a filter verdict), and iOS shows the ordinary success with no `Message not sent` card for it. Direct participant-to-participant contact stays unavailable for a fenced pair after placement; any support destination belongs to W4-T1 and is not fabricated here.

**iOS presentation (runtime truth, not layout).**

- *Entry.* Before helping, Request Detail's contextual `•••` → `Block this student` → a centered confirmation (`Block this student?`, `Block student`, `Cancel`) → Home. While the reservation is held, the canonical Helping screen's contextual `•••` → `Have you already placed the Grubhub order?` with neutral `Yes, already placed` / `No, not yet` / `Cancel` and no explanation below; `Your message won’t be shared.` appears once before the choices only when a Message draft exists, read from the live draft (no draft is persisted for Block). `No, not yet` → Home. A failed Block shows the alert title `Couldn’t block` with the existing truthful mapped message and is never presented as success. An outcome iOS cannot confirm is never retried, never presented as a success or release, and points the helper to Blocked Students. Block is mutually excluded with an in-flight release, extension, or fulfillment.
- *Restricted Helping (after `Yes` and on reconstruction).* Retains reservation context, Add 5 minutes (or its ordinary replacement states), Stop helping, `Open Grubhub`, `After you order`, `Order number`, `Pickup ETA`, and `Finish helping`; suppresses the Message, direct contact, and the Helping safety menu once a Block is active. Control composition is identical for the caller-owned and reconstructed states and reveals no ownership.
- *Immediate caller-owned `Yes`.* A compact accent `BLOCK ACTIVE` status with the muted line `You can continue or stop helping.` appears directly beneath the `After you order` heading, and the Helping view may orient to the After-you-order region once. The orientation does not focus a field, open Pickup ETA, or change lifecycle authority; Cancel, `No, not yet`, and failure never show it, and a restricted state merely loaded after relaunch does not scroll.
- *Reconstructed unknown-direction.* Shows the neutral `Direct contact is unavailable. You can still finish this order.` The client never infers who owns the Block from the direction-agnostic restriction.
- *After Unblock.* Only the ephemeral caller-owned marker is cleared. The direction-agnostic restriction is re-established through the authoritative active-reservation read; if that read fails or is superseded the conservative restriction stays, never cleared by assumption.
- *Stop and Back destination.* A confirmed Stop ends at Home, never Active Requests, while a restriction exists or `stopReturnsHome` is reported (so after the helper's own Unblock and after relaunch too). Restricted Helping reached through Block → `Yes` resolves Back to Home, including from a legacy Active-Requests-rooted stack. W4-R5 later retired Active Requests entirely (section 16); every non-success end of the helper flow returns Home.
- *Block management.* `Settings → Privacy & Safety → Blocked Students`, offered only with a verified participant: anonymous context rows (muted `Requester`/`Helper`, semibold dining location, regular timestamp, never truncated), a stable trailing `Unblock` lane, direct Unblock with no confirmation and no permanent footer, an empty state, and a fresh read that does not keep a stale Unblock failure. Available while operationally paused.
- *Home Settings gear.* The gear's interactive region is the full 44-point control (visual ring unchanged).

**Accepted limitations.**

- *Requester timing/state inference.* V1 never exposes a Block owner or direction, but a post-Yes stopped request keeps its existing claimed-like projection past an ordinary reservation's duration, so a requester who understands normal timing can infer an exceptional safety lifecycle and may suspect they were blocked. U1.3 does not claim resistance to this inference and adds no requester copy or state; removing it needs a generic requester lifecycle presentation owned by a later slice.
- *Deleted request.* A late `Yes` against a physically absent (TTL-deleted) request may answer `404 REQUEST_NOT_FOUND`; it writes nothing and reports no success.
- *Lost authority.* A Block + `Yes` that loses reservation authority before commit fails with `409 RESERVATION_STATE_CHANGED` rather than creating the Block; there is no mixed Block-succeeded/protection-failed state.
- *Unrecorded order.* A helper who affirms an external order and then Stops leaves CommonPlate with no fulfillment details for the requester, who is given no explanation, and consumed daily request quota is not restored.
- *No later requester Block.* After `I picked it up` removes the continuation from active Home, V1 offers no requester → helper Block entry for that helper; existing Blocks remain manageable.
- Block continuity across completed account deletion and same-email recreation is not provided here (W4-P2); different verified NYU email principals remain distinct (section 3.1).

### 5.4 Required placed-order evidence and manual fulfillment (W4-H1a)

**Requirement.** Every new successful helper fulfillment requires exactly one placed-order screenshot, in both authorization shapes (raw claim token and participant continuation) and in the section 5.3 `Yes, already placed` blocked-pair state, which adds no exception. The backend never commits a new fulfillment without a valid image; there is no compatibility path and no screenshot-less placement for older clients. Placements committed before this requirement remain historical data with no evidence row. The screenshot is required regardless of the Screenshot Assistance setting, and the only hard requirements are an attached, supported-type, structurally valid, bounded image. It is evidence the helper supplied, not proof that the order is genuine: nothing recognizes text, checks for Grubhub content, or judges authenticity, OCR is never a gate, and selecting or submitting it starts no analysis and transfers nothing to any AI provider.

**Transport and refusal.** The image travels as `fulfillment.placedOrderScreenshot: { mimeType, imageBase64 }` inside the existing fulfillment body. The fulfillment route owns a bounded `express.json({ limit: "3mb" })` parser, registered (`registerFulfillmentRoute`) ahead of the unchanged 100 KB global parser and behind the route's rate limiter; the shared parser limit is unchanged for every other route. Accepted types are `image/jpeg` and `image/png`; the value must be strict base64 and a structurally valid image of that type, with a decoded size of at most `1_500_000` bytes. Validation order is participant authority, then the ordinary payload, then the screenshot, then the section 5.2 Message filter, then the transaction. A missing, malformed, oversized, or wrong-type screenshot is a definitive `400 INVALID_PLACED_ORDER_SCREENSHOT` (`The order screenshot is missing or can’t be used.`), distinct from `INVALID_FULFILLMENT_PAYLOAD`, returned before any mutation and without saying which check failed. A request body over the parser ceiling answers the same code; any other unreadable body answers `INVALID_FULFILLMENT_PAYLOAD`. The route's parser-error boundary logs nothing, because a parser error can carry a slice of the raw body; an error that did not come from the parser is passed on unchanged and is never reported as a definitive 400, since it can follow a committed placement.

**Private persistence.** `PlacementEvidence` holds one row per Request: `requestId`, `image` (a Buffer, `select: false`), `mimeType`, `byteLength`, `deleteAt`, and timestamps. A unique `requestId` index (`placement_evidence_request_unique`) is the database-level guard that a resend or race can never produce a second row, and a `deleteAt` TTL index (`placement_evidence_deleteAt_ttl`, `expireAfterSeconds: 0`) removes it. Both are established at startup before the process listens (`PlacementEvidence.createIndexes()`). The schema also rejects an empty or over-cap image and an out-of-range `byteLength`. The row is created with the placement session immediately after the Fulfillment ledger row, so Request `placed`, Fulfillment, and PlacementEvidence commit or abort together: a failure inserting the row, including a uniqueness violation, aborts the whole placement, and a placed Request never exists without its evidence. Its `deleteAt` is the same `placedAt + PLACED_RETENTION_MS` value, computed once, that the placed Request carries (seven days, section 2). There is no object storage, signed URL, filesystem path, upload lifecycle, or general attachment system, and the QA reset deletes the row with its Request. Requester pickup confirmation does not delete it.

**Privacy.** The evidence never appears in the public Request DTO, list or detail projections, the fulfillment response, the participant-scoped placed read, the requester fulfillment email, any notification, or any log. No route in this slice returns the bytes; the requester-private, participant-authorized read was added by W4-R3 (section 22). The helper cannot replace the screenshot after placement commits. Request and account-deletion classification of `PlacementEvidence` belongs to W4-P2/R5; until they classify it, evidence outlives an early-deleted Request until its own TTL.

**Manual fulfillment fields.** Order number (digits-only, section 5), fixed Pickup ETA (section 5.2), and the optional Message (filtered, fenced, and suppressed as in sections 5.2 and 5.3) are entered manually. Screenshot Assistance disabled, unavailable, or never used changes nothing about this path.

**iOS selection and gating.** The Helping page's After you order section lists, in order: Order screenshot (right-aligned `Required`), Order number, Pickup ETA, the optional Message when not suppressed, the direct-coordination disclosure, and the pinned `Finish helping`, which stays disabled until a valid screenshot is attached and every other required field is valid and the store permits a submission. A missing screenshot is an incomplete state, not an error: it produces no red message and no tap-to-validate behavior. Before selection the control reads `Choose Grubhub screenshot` with no accompanying privacy or explanatory line; after a valid attachment it reads `Screenshot attached` with a `Change` action (VoiceOver `Change order screenshot`) that replaces the one image through the same picker. The selection lives only in the owning store's private in-memory state; it is neither published nor persisted, and the view never holds the bytes. Before it is sent, the image is read and normalized on the device off the main thread: only the latest selection applies, JPEG and PNG are accepted, other source formats (for example HEIC) are re-encoded to JPEG, the longest edge is at most 2000 px and is never upscaled, JPEG quality is `0.7` with exactly one fallback re-encode at `0.5`, and the result must be within `1_500_000` bytes. A failure at any step, or a definitive backend refusal before commit, fails closed to an unattached chooser and sends nothing: `This image can’t be used. Choose another screenshot to continue.` Network, claim, placement, and other unrelated failures keep their existing classifications and copy and are never mapped to that message.

**Ambiguity and relaunch.** The retained submission snapshot carries the exact screenshot bytes. The section 5 bounded recovery (one read-only status check, at most one exact-payload CommonPlate-only resend with the original authorization) resends the identical image. A selection, Change, or clear arriving after a submission was issued never alters that snapshot. A resend that finds `REQUEST_ALREADY_PLACED` uses the existing path; ambiguity is never turned into screenshot reselection, release, cancellation, or a second-order affordance. The screenshot is never persisted, so after a relaunch that restores a still-claimed, unfulfilled reservation the helper re-enters fulfillment data and selects the screenshot again, with `The order screenshot needs to be added again before you continue.` shown at the chooser. A relaunch after placement reconstructs no success presentation, haptic, or second-order affordance (section 5.1).

**Success and return.** Success begins only on authoritative placed truth (the fulfillment response or the bounded status check) and ends the helper lifecycle as section 5 states. It plays one semantic haptic and one VoiceOver announcement, then returns to Home exactly once, per section 5.2; there is no Got It, Done, or acknowledgement control. When placement succeeds but requester-email provider submission fails, the ending is unchanged: `Thanks for helping.` with the secondary line `We couldn't email the requester.`, then the same automatic return to Home. There is no email retry, placement retry, second-order action, alternative notification, or failure screen, and email failure never undoes placement. The section 5.2 Message-suppressed presentation and the section 5.3 blocking behavior are unchanged.

**Request Detail.** The pre-fulfillment note about verifying an NYU email before helping is removed with no replacement. `Start helping` remains offered to an otherwise eligible unverified participant and still begins the existing verification flow; no claim precedes successful verification, and verification and claim authority are unchanged.

## 6. Request-creation contract

Creation requires usable participant authority as well as strict backend validation for canonical and legacy request shapes, vendor, email when supplied, required text, scheduling bounds, and a still-usable scheduled end time. The backend derives and persists the requester identity from that authority. Where iOS can know an error locally, it validates before submission (including required fields, email, and scheduling/form constraints).

CommonPlate has one canonical supported-vendor catalog, `shared/vendors.json`, currently the accepted 11 dining locations. Backend request creation is authoritative over it. Both supported create payload shapes require `vendor` to match a catalog entry exactly, after the same trimming already applied to that field; case variants and other near-matches are refused rather than silently canonicalized. Structural shape validation still runs first, and vendor validation runs immediately after it, before the email allowlist below. A vendor that is present and non-blank but not in the catalog returns HTTP 400 with code `INVALID_VENDOR` and message `Choose a supported CommonPlate dining location.` Enforcement applies only to new request creation: existing persisted requests are neither migrated nor rejected on read. iOS consumes the same shared catalog for its vendor picker; the website form remains free-text, with backend enforcement still applying to it.

The requester principal must be an allowed NYU address. Both alert signup and food-request creation use the same `src/allowedEmailDomains.ts` helper with the same exact allowlist, normalization, and refusal of lookalikes and unlisted subdomains described in section 9.1. The allowlist establishes eligibility only; participant email-code verification is what proves control of the mailbox. Existing requests created on other domains are unaffected — the allowlist gates creation only.

The participant gate runs before payload validation, so an unverified caller neither creates a request nor learns whether its payload would otherwise be accepted. The legacy `email` field is optional because the backend already has the verified requester principal; if supplied, it must exactly equal that normalized principal or the request is refused with `403 PARTICIPANT_PRINCIPAL_MISMATCH`. A missing `email` is valid, while a blank or wrongly typed supplied `email` remains a structural `400 INVALID_REQUEST` failure alongside other malformed fields. `POST /api/request` keeps its two-key `{error: {code, message}}` envelope.

Refusal precedes the daily abuse-control count, the write, the requester confirmation email, and helper-alert notification. The iOS Request Food form carries no editable email field and supplies no legacy `email` at all; it relies entirely on the verified participant authority established before the form is reached (section 3.1). A backend `INVALID_EMAIL` on this path would indicate a stale or mismatched authority rather than free-form input the form itself validates. The legacy website is instead temporarily non-actionable because it cannot establish participant authority (section 3.1); its email input placeholder remains `abc123@nyu.edu`.

Request creation now has an exact logical operation identity and durable ambiguity recovery (section 6.3). A caller that presents no operation identity still receives the pre-D1 non-idempotent behavior described above.

#### Requester text filtering (W4-U1.1)

Requester-authored text another participant can read is filtered authoritatively at `POST /api/request` by a deterministic, provider-free filter (`src/participantTextFilter.ts`); no participant text is sent to any external moderation provider, and Screenshot Assistance is not a moderation mechanism. The filtered values are exactly each active Meal item's `name` and `details` and `orderDetails`. Derived `food` is not independently filtered, and `vendor` is allowlisted rather than free text. The filter is a bounded, high-precision list, not a guarantee that all objectionable text is refused: phonetic respellings, reversed text, adjacent-word concatenation, masked ordinary profanity, and non-English lexicons are deliberately not covered.

Filtering applies only to a genuinely new create attempt: it runs after participant authority, exact-operation reconciliation (an exact replay is answered by reconciliation and is never re-filtered, section 6.3), and canonical validation, and strictly before the daily-limit read and every creation effect. A match returns `422 REQUEST_TEXT_NOT_ALLOWED` in the shared structured error envelope with the neutral message `Keep request details respectful and food-related.` The refusal is definitive and pre-mutation: no Request, no operation-ledger row, no quota use, no confirmation email, and no helper push or email. It never names the matched term, category, or field, and nothing about the match is logged.

iOS treats the refusal as a definitive non-create for a fresh transmission, and as a post-lookup refusal — never recovery proof — for an already-issued operation identity. The requester sees the same neutral copy as a section-level notice beneath the heading `What would you like?` above the Meal fields, shown only after a refusal, with the draft and Screenshot Assistance state preserved and no modal, sheet, or new retry control. The notice retires when any submitted authored value, or the participant authority it was answered under, changes.

### 6.1 Request → installation association

An iOS request-creation payload may carry the installation's existing `installationCredential`. A structurally malformed supplied credential is a structural failure: HTTP 400 `INVALID_REQUEST`, the same envelope as any other malformed payload. A structurally valid credential is used to establish or resolve installation identity through the existing installation-credential mechanism; only an opaque internal association is persisted on the Request, never the raw credential. This association is notification-routing metadata only — it is not authentication, not NYU participant identity, and not proof of a person. Reinstall creates a new installation and does not relink requests created by a prior installation; no email, APNs token, or other heuristic re-links them either. Request creation never depends on Apple notification permission or push-enabled state.

Association is best-effort against unexpected backend persistence failure: if establishing or persisting the association unexpectedly fails, request creation still proceeds and the request persists without an installation association. `installationId` is therefore optional persisted metadata; a downstream flow may not assume every iOS-created Request carries one, and its presence or absence carries no authentication or identity meaning.

### 6.2 Meal-swipe quantity requirement

V1 supports meal swipes only — no Dining Dollars, no other payment source. Every request shape `POST /api/request` accepts requires an integer meal-swipe quantity, minimum 1 and maximum 5; this applies identically to the canonical/iOS shape and to `legacyWebSchema`, and the backend does not create a helper-visible request from either shape without one. The backend is authoritative for this validation on every accepted shape; invalid, missing, fractional, or out-of-range values cannot create a request. On iOS, the requester selects the quantity from a bounded picker offering exactly 1, 2, 3, 4, or 5.

The quantity is persisted once as Request-owned truth and included in the privacy-safe helper request projection, which remains allowlisted. Helpers see it on the Home request card (formerly the Active Requests list/card, retired by W4-R5) before opening Request Detail, in `RequestDetailView` before the Reserve action, in active-reservation presentation, and in `FulfillRequestView` order context after reservation — the same authoritative value throughout, sourced from the active claim's request rather than a stale pre-claim copy. The existing new-request helper email (text and HTML) and push alert carry the same authoritative quantity concisely (e.g. `Meal swipes: 2`), via the existing `sendNewRequestAlert()` and `buildHelperNewRequestPayload()` composition paths reused by both immediate creation and the W3-N3 eligibility sweep; W3-N3's eligibility, timing, deduplication, and tap-routing behavior is unchanged.

Because current database contents are disposable test data, no backward-compatibility, migration, fallback, default, or optional representation exists for pre-C1 Request documents, and no backend exception, default, or fallback quantity is introduced for any accepted request shape to avoid this requirement. Legacy website UI parity is deferred: the current legacy website form cannot supply the required quantity, so its submissions are rejected by the same backend validation as any other missing-field submission until later parity work supplies it; this is an accepted consequence, not a defect. CommonPlate does not process payments, reimburse participants, connect Grubhub accounts, or place the external order.

The `Meal swipes: N` presentation is technically correct but its user-facing meaning and visual hierarchy are a Week 4 deferral; Week 4 must not reopen this section's data semantics, backend behavior, validation rules, or notification content.

### 6.3 Durable request-create recovery (W3-D1)

One intentional request submission mints one exact logical create-operation identity, carried in the `x-commonplate-operation-id` header. Replay or reconciliation of that logical operation uses the same identity; payload similarity, timestamps, recency, and request-list matching are never identity. A genuinely new intentional submission mints a new identity even when its payload is identical, and remains subject to normal quota rules. A caller that presents no identity receives the ordinary non-idempotent behavior of section 6 above, unchanged.

**Backend idempotency.** The backend binds the operation to the requester participant. A minimal durable ledger (`RequestOperation`) — not a field on the Request document — records the operation identity, the owning participant, and a pointer to the created Request; the Request and its ledger row are created in one transaction, so the two writes can never diverge. A unique index on the operation identity is what makes "at most one Request per logical operation" true under real concurrency: a racing create for the same identity loses with a duplicate-key error and reconciles to the winner's already-decided outcome instead of writing a second Request. Sequential and concurrent replay of an already-created operation converge on the same authoritative Request and consume no additional daily quota. Cross-participant replay is refused generically (`403 OPERATION_UNAUTHORIZED`) with no detail about the other participant's request.

**Bounded recovery.** While the Request an operation created remains active/actionable under the accepted request lifecycle, the same operation identity reconciles to that Request. The ledger row survives the Request's own TTL cleanup, so once the Request is gone the operation resolves as terminal expired/unrecoverable (`410 OPERATION_EXPIRED`) rather than falling through to a fresh create — cleanup of the original Request can never make an expired operation identity reusable. An expired operation can never resurrect or create another Request; a later intentional request uses a fresh operation identity.

**iOS durable recovery.** Once transmission of a request-create operation may have begun, iOS durably persists the exact unresolved operation — participant-bound, and including the exact submitted request fields needed for replay — so it survives app/process termination. No raw participant credential is persisted in that record. While a write-uncertain operation remains unresolved, iOS blocks another logical create until authoritative reconciliation resolves it. Launch reconciliation reuses the exact persisted operation identity and payload.

**Authoritative outcomes.** First successful create answers `201`; replay/reconciliation of an already-created operation answers `200` with the same authoritative Request; a terminal expired/unrecoverable operation answers `410 OPERATION_EXPIRED`; a successfully received `400 INVALID_OPERATION_ID` is a definitive non-create; `403 OPERATION_UNAUTHORIZED` is a hard authorization outcome; every other pre-write rejection (`INVALID_VENDOR`, `PARTICIPANT_PRINCIPAL_MISMATCH`, `INVALID_REQUEST`, `REQUEST_LIMIT_REACHED`, rate limiting) is also definitive and retires the operation. `REQUEST_CREATION_FAILED` remains write-uncertain — it can follow a write attempt — and keeps the operation open/blocking rather than retiring it, as does transport loss, timeout, or an unreadable response.

**Architecture rationale.** The ledger is a separate, permanently retained collection rather than a field on the Request document because Request documents are TTL-deleted (`deleteAt`, section 2) once a request stops being active/actionable; storing the durable identity only there would silently free it for reuse the moment cleanup ran, which is the exact "cleanup makes an expired operation fresh again" defect this design forbids. Operation identity must remain non-reusable even after the Request it created is cleaned up. The ledger stores identity, owning participant, and a pointer to the created Request only — never request content — because this is a minimal recovery/idempotency primitive, not a request-history product, and must not be repurposed as one. The Request and its ledger row are created in one transaction, and the ledger's unique operation-identity index is the sole primitive behind "at most one Request per logical operation" under real concurrency. Ledger rows are retained permanently rather than on their own TTL: each row is a handful of bytes, and freeing them after some duration would eventually let the same resurrection defect resurface, only delayed. This permanent minimal-tombstone retention is the accepted V1 tradeoff; cleanup cannot be introduced for this ledger later unless another mechanism independently preserves the non-reusability of retired operation identities.

### 6.4 Exact request-create terminal reconciliation and Success→Home continuity (W4-D2)

D2 extends W3-D1's bounded recovery (section 6.3) so one issued request-create operation can always converge on at most one authoritative terminal outcome whenever its stable recovery identity remains readable, even when the detailed persisted request payload cannot be decoded. No heuristic, content matching, timestamp, recent-request lookup, or local clearing may establish that outcome.

**Stable recovery identity.** The durable pending-operation record carries a recovery identity — the exact operation ID, the non-secret participant-identifier segment, an explicit recovery-envelope version, and a stable backend/environment authority identity — that is independently decodable from the evolving detailed request payload. A payload decode failure can never prevent identity recovery. Pre-D2 records (pre-R4 legacy and R4 current shapes) remain recoverable to at least operation ID and participant identifier; they carry no recorded authority identity.

**Exact-operation terminal authority.** Backend authority, bound to one exact operation ID and resolved only after participant authority, atomically does exactly one of: returns the existing created outcome; preserves terminal expired/non-resurrection (`410 OPERATION_EXPIRED`); refuses unauthorized cross-participant access generically; or durably establishes terminal **NO-CREATE** for that exact operation when no create has won. An absent ledger row is never terminal authority by itself. Terminal no-create occupies the same unique operation-identity authority as a created operation, so a racing or later-arriving original create for that identity cannot commit a Request once terminalization has won. A terminalized operation is permanent: every later replay, reconciliation, or terminalization of that identity returns the same terminal no-create outcome and can never create. Terminalization consumes no daily quota, sends no notification, creates no Request, and never reads, stores, or requires request content. The endpoint is side-effect free except for the terminal no-create write, and every outcome carries `Cache-Control: private, no-store` and `Vary: x-commonplate-participant`.

**Recovery classification.** During recovery, a response produced before exact ledger reconciliation is not proof the operation can no longer create: `RATE_LIMITED`, `PUBLIC_ACTIONS_PAUSED`, participant-authority refusals, route-level `404`, and post-`not-found` validation/quota codes (`INVALID_VENDOR`, `PARTICIPANT_PRINCIPAL_MISMATCH`, `INVALID_REQUEST`, `REQUEST_TEXT_NOT_ALLOWED`, `REQUEST_LIMIT_REACHED`) all keep the operation pending rather than retiring it. `INVALID_OPERATION_ID` and `OPERATION_UNAUTHORIZED` remain definitive. `OPERATION_EXPIRED` remains terminal. `REQUEST_CREATION_FAILED`, transport loss, timeout, and an unreadable response remain write-uncertain. Ordinary fresh-submission semantics (a single transmission of a freshly minted operation ID) are unchanged by any of this: a pre-write rejection still proves that attempt created nothing and still retires that record without arming the block. `REQUEST_TEXT_NOT_ALLOWED` (W4-U1.1, section 6, Requester text filtering) follows this same split: a definitive pre-write non-create for a single transmission of a freshly minted operation ID, and a post-lookup refusal that is never recovery proof for an already-issued identity. A recorded backend/environment authority that does not match the currently reachable authority, or a pre-D2 record with no recorded authority, is never sufficient to treat a `not-found`/`404`/no-create answer as terminal; unresolved state is preserved unless the recorded authority can be reconciled.

**User-visible recovery states.** `Posting request…` is the only initial in-progress presentation; there is no separate `Checking your request` screen. The **stable unresolved state** (reconciliation has finished at least once, or authority is mismatched, without reaching a terminal outcome, and none is actively in flight) shows `Your request may have posted` / `CommonPlate couldn't confirm whether your request posted.`, primary action `Check again` (exact-operation reconciliation only; never resubmits, never mints a new operation ID; while in flight the action label becomes `Checking…` and the requester stays on the same screen), secondary action `Go to Home` (navigation only, no mutation). **Exact recovery identity unavailable** shows `We can't safely confirm what happened to this request.` / `To prevent a duplicate, CommonPlate won't submit another request.` with no check/retry/clear action; normal navigation away remains possible. **Authoritative terminal NO-CREATE** always shows `Your request wasn't posted`: **Path A** (the frozen `CreateRequestPayload` is actually readable) adds `Your request details are still here. Return to your request to review them before submitting again.` and primary action `Return to request`, which restores the preserved information into the existing Request Food form without submitting, reconciling, or reusing the old operation ID — the next intentional Submit mints a fresh operation ID; **Path B** (the payload is genuinely unreadable — confirmed reachable when a stable identity is readable but its payload is not) adds `You'll need to enter the request details again.` and primary action `Start a new request`, which opens the ordinary empty form with no reconstruction, guessing, or content-matching. Both paths carry secondary action `Go to Home` and neither is offered before authoritative NO-CREATE. **Authoritative CREATED** preserves the existing successful posted flow. Neither unresolved state nor the NO-CREATE state receives a success/failure haptic. Remove Email stays blocked in both unresolved states, presenting `CommonPlate can't remove your email while a request tied to it is unresolved. This helps prevent a duplicate request.`

**Success→Home continuity.** After authoritative CREATED, the newly created requester-owned request card rises in on `Posting request…`, settles, shows `Request posted` (Success), and — during Home reveal — the same card visually continues into its first slot under `Your request(s)` rather than a Success card disappearing and a separately materialized Home card reappearing. Final Home-card layout width is fixed from first appearance and text does not reflow/resize/wrap differently during the transition. This holds for both zero-existing-request and multi-existing-request landings. Requester-owned Home ordering is newest-created-first; ASAP vs. Later does not reorder requester-owned requests; helper/discovery ordering is unchanged. Reduce Motion uses substantially reduced displacement/crossfade for this sequence; the existing single success haptic, concise VoiceOver announcement, and accepted timing/dwell (~1.6 seconds total) are preserved, except that a verified Participant's first post on a device uses the 3.5-second guidance presentation in section 1.7. This narrowly supersedes W4-R2's Success presentation and W4-H2/W4-H4's requester-owned ordering only; it does not reopen either slice's broader navigation, Timing, draft-lifetime, D1-ambiguity, Home information-architecture, continuous-scroll, refresh, or CTA-position contracts.

When a valid, fully visible real Home first-slot target is available, standard motion lands the continuity card into that measured slot (no guessed offsets, no duplicate-card/empty-slot artifact); Reduce Motion applies its existing bounded movement + crossfade to that same valid target. When no safe, usable real Home landing target can be captured (including an off-screen target), the continuity card does not travel toward a guessed position and Home is not force-scrolled: the continuity card stays spatially fixed and fades out while Home's real card for the exact created request fades in at its actual slot, as one coordinated crossfade during the existing landing window, with no hard retirement swap. This fallback applies regardless of motion preference and preserves the same final Home destination and the same Success dwell (section 1.7).

**Exact-created-request Home continuity.** After authoritative request creation, if the ownership-resolved exact created request is already trusted in local/continuity/store state, that exact request may render in `Your request(s)` even while the broader Home request-list fetch remains `.loading` or `.unavailable`. This exception is scoped only to that one exact, ownership-resolved, authoritatively created request: it never fabricates, reuses, or exposes stale broader Home/requester/helper/discovery data, and the overall loading/unavailable board is never treated as populated merely because this one card is visible. It guarantees the Success→Home fallback above always has a real Home card to hand off to. When the broader authoritative Home fetch later resolves, normal reconciliation and requester ordering resume without duplicate cards or stale local-only persistence. This is a narrow local-authority continuity exception scoped to this one D2 flow, not a general Home cache policy, and does not reopen W4-H2's board-first architecture, ownership-partition mechanism, `Continue Helping` priority, or helper/discovery semantics.

**Engineering-owned** (provided the contract above holds): exact endpoint path/method, DTO names, status/code vocabulary for terminal no-create, ledger schema change, recovery-envelope layout/versioning, authority-identity derivation, and row-6 retry scheduling.

## 7. Daily request abuse control

CommonPlate attempts to limit each email to three requests per NYU/New York calendar day (`startOfCampusDay`, not the requesting process's local timezone). The backend counts before creating, serially in the handler; this is best-effort abuse control, not an atomic quota transaction. A failed count read fails closed. Concurrent create requests can exceed the limit. Atomic enforcement is deferred to Week 5 if usage requires it.

Ordinary Request Food presentation does not continuously advertise this limit. Only an actual `REQUEST_LIMIT_REACHED` refusal tells the requester to try again after midnight Eastern/New York time.

### 7.1 Participant-authorized request-creation eligibility read (W4-Q1)

`GET /api/participant/request-eligibility` lets the currently verified participant authoritatively read whether they are presently eligible to attempt another request under the daily abuse-control quota above. The principal is derived only from `resolveParticipantAuthority`, never from a caller-supplied email, participant ID, installation ID, Subscriber identity, or request-list identity; authority resolution happens before any count, exactly as it does for `POST /api/request`.

The read shares its substantive quota authority with `POST /api/request` (`src/requestDailyQuota.ts`): the same exact-principal `Request.countDocuments` basis, the same `startOfCampusDay`/`America/New_York` campus-day boundary, and the same three-request threshold. Neither the read nor its extraction changes create's existing principal, count filter, threshold, serial best-effort behavior, count-failure handling, D1 replay ordering, or write path; the quota remains the best-effort, non-atomic abuse control described above, and concurrent creates can still exceed it.

The successful response exposes only the accepted binary product state — `{ "eligibility": "eligible" }` or `{ "eligibility": "exhausted" }` — with no count used, count remaining, reset timestamp, quota-dashboard data, email, participant ID, credential, or request content. A count/database failure answers unavailable/error and never fabricates either successful result.

The result is advisory and current only as of that read. It is not a reservation of quota and does not guarantee that a later `POST /api/request` will pass validation, pause/configuration, rate-limiting, D1, database, or then-current quota checks; another request or race may change state after an `eligible` answer. `POST /api/request` remains the sole authoritative create-time quota enforcement.

The read is side-effect free — it performs no Request, RequestOperation, participant, notification, subscription, or installation mutation — and uses its own read-sized rate-limit bucket rather than consuming `POST /api/request`'s create allowance. The response carries `Cache-Control: private, no-store` and `Vary: x-commonplate-participant` on every outcome, including a mounted rate-limited refusal, so one participant's answer can never be cached or reused for another or for an unverified caller.

On iOS, `RequestService` owns the participant-authorized read and strict DTO decoding; `RequestStore.resolveRequestCreationEligibility()` owns the current authority-scoped load and its stale-response fence, mirroring `resolveStaleParticipationEligibility`. Missing authority, transport/server/decoding failure, cancellation, a stale/superseded-identity result, or an unmapped server refusal all resolve to unknown and are never coerced to eligible; a current `PARTICIPANT_AUTHORITY_INVALID` refusal feeds the same participant-authority-retirement lifecycle every other participant-gated store method already uses. No Q1 result is persisted or reused as durable quota truth.

## 8. Email and notification truth

Provider acceptance means only that CommonPlate submitted an email to the provider. It does not prove delivery, reading, or pickup; no email result is described as verified delivery.

| Record/state | Owner and meaning |
| --- | --- |
| `Request.notificationStatus` (`pending`, `sent`, `failed`) | Requester placement-email submission state only, recorded after committed placement. |
| `SendLog` (`sent`, `fail`) | Helper-alert and digest send ledger / duplicate-send guard. It is not requester placement-email state. |

### 8.1 Real-time helper-alert selection and dispatch

W4-N1 Increment A (section 28) makes Request Alert Email delivery inactive in V1; this subsection describes the preserved, dormant email behavior. Helper Push recipients are selected by the shared Push eligibility predicate in section 28.

When composed, request-alert and digest email retain their useful request
summary but do not link to the configured origin's root: GoodGrub V1 has no
website destination. Request-alert unsubscribe links remain signed and
subscriber-specific. Subscription-confirmation links continue to use the
configured trusted origin and the existing confirmation endpoint.

For each new eligible request, every `confirmed`, non-bounced Subscriber is considered for a real-time email alert — not a bounded or round-robin-selected subset. There is no 1-hour per-subscriber cooldown, no per-subscriber daily send cap, and no ordinary round-robin selection gating which confirmed subscribers receive an alert. A subscriber enrolled in both email and push may receive both for the same request; the two channels are independent.

`SendLog`'s unique `(requestId, subscriberId)` claim-before-send index still provides per-pair duplicate-send prevention, and one subscriber's provider failure does not stop the remaining eligible subscribers from being attempted. A successful real-time send still sets `lastSentAt` and increments `dailyCount` on the Subscriber, because the hourly digest still reads both fields for its own eligibility; digest behavior is unchanged by real-time selection. Provider acceptance for a real-time alert carries the same meaning as elsewhere in this section: submission only, never delivery, reading, or pickup.

CommonPlate has no internal provider-wide send-volume ceiling. A provider quota or rate-limit refusal surfaces through the existing per-subscriber `SendLog` `fail` outcome and per-subscriber failure isolation above; it is not pre-empted by silently skipping subscribers. Introducing an application-level ceiling is deferred until Week 5 production email configuration, and only if actual provider rate or quota evidence requires one.

`POST /api/request` never waits on real-time helper-alert fan-out. The `201` response is built and sent from the persisted document first; helper-alert dispatch is started only afterward, detached, through a total entry point that cannot throw and cannot leave an unhandled promise rejection. A slow, large, or failing fan-out cannot delay the requester's response, cannot turn a successful creation into `REQUEST_CREATION_FAILED`, and cannot produce a second response on a request whose headers are already sent. The requester confirmation email remains awaited before the response, unchanged.

### 8.2 Requester-fulfillment push

W4-N1 Increment A (section 28) additionally requires the originating installation to pass the shared Push eligibility predicate bound to the request's requester; the copy and Home tap below are unchanged until Increment B.

After a request's placement has durably committed, CommonPlate may best-effort submit a requester-fulfillment push to the originating associated installation only (the Request's stored association from section 6.1). If that installation is missing, disabled, invalidated, or lacks a usable APNs registration, no push is sent; there is no fallback or heuristic recipient. Requester-fulfillment push is independent of placement success and of the existing fulfillment email — neither affects the other. At most one requester-fulfillment provider submission is claimed for the same request + installation, matching the existing dedup discipline used for helper push. Provider acceptance means submission only, never delivery, display, opening, or reading.

Notification title: `"Your order was placed"`. Body: `"A helper placed the order for your request."` The payload carries only privacy-safe routing data; it never carries pickup name, requester or helper email, order number, claim token or claim state, the installation credential, or any other private fulfillment field. The requester-fulfillment notification intent and the helper new-request notification intent remain distinct; a requester notification tap opens Home and presents a one-time "Your order was placed." notice.

A physical device has received a real requester-fulfillment push while running, tapped it to open Home, and seen the one-time notice. That device result covers submission-to-tap-to-notice on the observed device; it does not extend provider acceptance beyond submission (see the section header) and does not establish Release/Archive/TestFlight signing or environment behavior, which remains a separate gate (section 11).

### 8.3 Helper new-request push tap routing

A helper new-request notification tap carries a request id as routing context only. Only current backend truth from `GET /api/request/:id`, read at the moment of the tap, decides where the tap goes — the payload itself never establishes availability.

- If the backend confirms the request is currently open, the tap opens that request's detail flow.
- If the backend confirms the request is no longer available (a non-open status, or an authoritative not-found), the tap shows a "no longer available" notice and returns to Home (Active Requests was retired by W4-R5; a verified withdrawn or expired request earns its own Home notice, section 16).
- If current backend truth cannot be established (a transport failure, timeout, unexpected server response, or a malformed response), the tap shows a distinct "temporarily unavailable" notice rather than claiming the request is gone, and also returns to Home. Neither notice discloses an internal error code or any requester-private detail.

Each valid tap is routed exactly once, in the order it was made. A routing attempt that does not reach one of the outcomes above — including one interrupted by app startup ordering, such as a cold launch from a terminated state — does not consume the tap: the tap remains available to a later attempt rather than being silently lost. When more than one attempt is in flight for the same tap, at most one of them may apply a navigation or recovery outcome, and an older tap can never overwrite or retire a newer one.

A physical device has received a real helper new-request push while CommonPlate was terminated, tapped it to launch the app, and been routed to that request's detail flow rather than to Home — including the cold-launch case described above. Background-state tap routing to the specific request has also been physically observed. These device results do not establish Release/Archive/TestFlight signing or environment behavior, which remains a separate gate (section 11).

### 8.4 Reservation warning

At five minutes remaining before an active reservation's backend-authoritative `claimExpiresAt`, CommonPlate warns once. While the app scene is active and visible, the in-app reservation warning owns presentation and the request-keyed local notification is canceled, so there is no duplicate system warning. While inactive or backgrounded, the local notification owns presentation. If an already-visible in-app warning loses active-scene ownership, CommonPlate retires that in-app warning and restores the local-notification path immediately; active re-entry reconciles back to truthful in-app ownership.

The local notification title is `"5 minutes remain"`. Its stable identity is derived from the request id, so scheduling, extension rescheduling, cancellation, and relaunch reconciliation affect the same reservation warning without touching other notification kinds. Warnings are rescheduled after a successful extension and canceled when the reservation ends through release, fulfillment, expiry, or authoritative continuation absence.

A reservation-warning tap is routing context, not authority. It routes only after current continuation truth confirms the matching active reservation. A stale warning for reservation A cannot route to newer reservation B. A terminated-app tap can cold-launch CommonPlate, restore the matching reservation through participant authority, and route to it; unknown continuation truth produces temporary-unavailability recovery rather than fabricating absence or a reservation.

### 8.5 Later eligibility notification dispatch

Helper notification initiation follows the event a request becomes helper-eligible, not the event it was created. For an ASAP request, creation and helper eligibility are the same event, so ASAP creation-time behavior is unchanged. For a future Later request, no helper email or helper push initiation occurs before its authoritative `visibleFrom`; when `visibleFrom` arrives and the request becomes effectively helper-eligible, it enters the existing helper-notification lifecycle on the next eligibility sweep.

Notification discovery is not bounded by `createdAt`: an older request is not permanently omitted merely because its creation predates an ordinary lookback, and a still-eligible request remains recoverable after a missed or interrupted sweep. Email and push remain independent, and existing per-recipient (`SendLog`) and per-installation (`PushDelivery`) deduplication remain the sole duplicate-send guards. Existing pause, effective-availability, recipient-eligibility, provider classification/no-retry behavior, payload contracts, and helper push tap routing are unchanged by eligibility-time dispatch.

A pre-existing future Later request created before this behavior existed, once identifiable as having eligibility after creation, is transition-compatible with the eligibility sweep rather than permanently unreachable.

Provider acceptance for eligibility-time dispatch carries the same meaning as elsewhere in this section: submission only, never delivery, reading, or pickup. A real future Later request has been observed end to end: no helper email or push initiation before `visibleFrom`, and eligibility-time initiation — confirmed email submission and physical APNs delivery to an intended installation — after it. That observation establishes correct no-early-dispatch and first-eligible-sweep timing on the observed request; it does not by itself establish that an old-`createdAt` request survives the former lookback omission, which is separately established by real-Mongo integration coverage (`docs/testing.md`).

### 8.6 Push enable/disable management truth (W3-N2)

W4-N1 Increment A (section 28) binds Push enable to verified participant authority and moves Request Alerts management inline into Settings and the Home promotion; the On/Off/ambiguous truth below is unchanged.

Email and push remain independent channels: changing one never automatically creates, confirms, enables, disables, or rewrites the other, and participant verification never creates or confirms a Subscriber or changes push state (section 3.1).

Stable Push **On** requires all three of: Apple notification authorization permitting delivery, a current APNs token, and authoritative backend Installation synchronization confirming `enabled: true`. iOS does not present On before that complete sequence completes.

Stable Push **Off** requires the same authoritative backend-confirmed `enabled: false`; iOS never optimistically flips to Off before that confirmation.

For a synchronization request whose backend result is ambiguous, iOS presents neither stable On nor stable Off. The unresolved desired enable/disable state is persisted and survives relaunch. Authorization refresh and relaunch do not automatically retry the ambiguous mutation, so relaunch cannot silently reverse the unresolved user choice. An explicit retry reasserts only the same declarative desired state through the existing synchronization contract; it cannot make relaunch or backend reconciliation choose the opposite state.

Apple permission truth remains distinct from CommonPlate backend Installation state: denied or revoked Apple permission may be presented as Needs Permission, while a backend reconciliation failure is never mislabeled as an Apple permission failure.

## 9. Subscriber lifecycle

W4-N1 Increment A (section 28) makes Request Alert Email enrollment, confirmation and delivery inactive in V1 through one hard-coded boundary; this section describes the preserved, dormant lifecycle. Unsubscribe and the N0 state read remain dormant and unchanged.

The lifecycle is `signup → pending → confirmed → unsubscribed`. Only `confirmed` subscribers are eligible for real-time helper alerts and the hourly digest; `pending` and `unsubscribed` subscribers are excluded by both the alert query and the recent-request path. Signing up again never silently reactivates alerts.

Signup is implemented. Confirmation is implemented as an internal backend primitive (section 9.4) reached by a public browser flow (section 9.5). Unsubscribe credentials and their emailed links are implemented (section 9.6), and so is unsubscribe redemption (section 9.7). Rows already marked `confirmed` by the removed auto-confirm handler stay `confirmed` and alert-eligible; no slice migrated or modified legacy confirmed rows. Signup, confirmation, and alert delivery all remain paused (section 10).

The accepted end-to-end runtime path, proven end to end against real MongoDB through the production handlers and the real emails, is:

```text
signup → pending Subscriber → confirmation email → safe confirmation GET
→ explicit confirmation POST → confirmed and alert-eligible
→ alert or digest email carrying a valid unsubscribe link
→ safe unsubscribe GET → explicit unsubscribe POST → unsubscribed and ineligible
```

Signing up again after unsubscribing rotates a fresh pending confirmation credential onto the same document — preserving `_id`, `unsubscribeCredentialVersion`, `dailyCount`, `lastSentAt`, `bounced`, `unsubscribedAt`, and SendLog history — and reconfirming restores eligibility. The unsubscribe link emailed before any of that still opens the page and still unsubscribes afterwards. Neither half of either emailed link mutates anything on a GET.

Every Subscriber holds a revocable unsubscribe credential by construction: it is signed on demand from `_id` and `unsubscribeCredentialVersion` (section 9.6) rather than stored, so no confirmed-row credential invariant is needed and no unsubscribe credential is persisted in any form. The legacy raw `unsubToken` field is retained on existing rows but excluded from ordinary projections (`select: false`); nothing issues, requires, or explicitly selects one, and confirmation still clears it when it transitions a row that carries one.

### 9.1 `POST /api/subscribe`

The handler validates a strict body: the sole field is `email`, unexpected fields are rejected, and the address is trimmed and lowercased before any database work. Invalid input returns the shared structured error envelope with HTTP 400 and `INVALID_EMAIL`.

Alert signup additionally accepts only NYU addresses. The exact allowlist is `nyu.edu` and `stern.nyu.edu`, compared against the whole normalized domain after the final `@` — never by suffix or substring, so `fake-nyu.edu`, `nyu.edu.example.com`, and unlisted subdomains such as `law.nyu.edu` are all refused. Plus-addressing on an allowed domain is accepted. A non-allowlisted address is part of the same strict schema and so is refused with the identical HTTP 400 `INVALID_EMAIL` envelope, before any Subscriber lookup or mutation; its message is `Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu.` The allowlist gates signup only: it never affects confirmation or unsubscribe, and existing Subscriber rows on other domains keep their lifecycle. `src/allowedEmailDomains.ts` is the single implementation, shared with food-request creation (section 6).

Every valid attempt — brand-new, unexpired pending, expired pending, unsubscribed, and already-confirmed — returns the identical generic response, so the response cannot be used to enumerate subscription status:

```http
HTTP 202
{ "message": "If confirmation is needed, check your email for the next step." }
```

**Confirmation-email provider-submission failure (W3-N2).** A confirmation-email provider-submission failure is operational/internal truth, not public Subscriber-lifecycle truth. The public response is the same generic accepted `202` above rather than a distinct status or code; it makes no claim that a confirmation email was submitted, delivered, or received. Existing lifecycle cleanup/rollback (section 9.3), send-lease handling, and sanitized internal logging remain unchanged and still run before the response is sent. `CONFIRMATION_EMAIL_UNAVAILABLE` is retired as public runtime behavior; invalid NYU email, malformed input, rate limiting, and public-action pause retain their existing distinct error behavior because none of those reveal Subscriber lifecycle state. A user who does not receive a confirmation email may explicitly retry signup.

**Accepted V1 response-timing limitation.** An already-confirmed address requires no confirmation-email provider submission, while a pending address may wait on that provider during signup, so response timing may differ between these cases even though response content and status do not. Faith has explicitly accepted this timing side channel as a known V1 limitation. Timing equalization — artificial delays, unnecessary provider calls for confirmed addresses, or asynchronous architecture solely for timing parity — is not current behavior and is not required for V1 acceptance.

An already-confirmed address performs no mutation and submits no email. Signup never auto-confirms, never creates unsubscribe credentials, never resets delivery history, and never dispatches recent-request alerts. Re-signup preserves `bounced`, `dailyCount`, `lastSentAt`, unsubscribe-token state, unsubscribe timestamp, and existing delivery history.

iOS remembers one thing about signup across app launches, in `UserDefaults` under a single key: the normalized address it last submitted and the device time at which the generic accepted response arrived. That record is presentation history — this installation submitted this address and saw the generic response — and never subscription truth. Because the 202 is identical for a new, pending, confirmed, and unsubscribed address, the record does not establish that a Subscriber exists, that the address is pending, confirmed, or still subscribed, that a confirmation email was submitted or delivered, that alerts are active, or that the person still controls the address; nothing in the app is named or read as subscription status, and no client may treat local state as any. Restoring it only re-presents the existing `Check your email` copy, which claims none of those things. It is written only by a generic accepted response, replaced only by a later one, and removed only by `Use a different email` — which sends nothing and unsubscribes nothing — or by the record itself being unreadable, carrying no valid timestamp, or holding an address the NYU allowlist no longer accepts, each of which is discarded in favor of the editable form. No failure writes or deletes it. Restoring performs no network request: no endpoint reports subscription status, and none is consulted. No confirmation credential, unsubscribe credential, Subscriber ID, or backend status is persisted on the device in any form.

### 9.2 Confirmation tokens and pending state

The raw confirmation token is a cryptographically random 32-byte base64url value that exists only for the emailed link. Only its SHA-256 digest is persisted, in the private `confirmationTokenDigest`. `confirmationExpiresAt` is backend time plus exactly 24 hours. `confirmationTokenDigest`, `confirmationExpiresAt`, `confirmationSendAttemptId`, and `confirmationSendAttemptAt` are private (`select: false`) and never public.

The confirmation link is built from trusted configured `BASE_URL`, never from a request `Host`, `X-Forwarded-Host`, or request protocol, because the link carries a bearer token.

A brand-new address creates one Subscriber. Unexpired pending, expired pending, and unsubscribed addresses rotate the existing document, preserving its `_id`. Rotation issues a new token, digest, and expiry, so any previous confirmation link becomes invalid.

### 9.3 Concurrency, send ownership, and compensation

Creation relies on the unique normalized-email index; a duplicate-key loss re-reads state and returns the same 202. Existing-lifecycle rotation is one exact conditional mutation that matches every prior lifecycle field, including field presence. A losing concurrent attempt re-reads state and never submits a token whose digest is not the persisted one.

One attempt owns provider submission through `confirmationSendAttemptId` under a two-minute lease. Ownership with no timestamp, or a timestamp at or before the lease cutoff, is stale and takeover-eligible, so a process that dies mid-flight cannot make an address permanently unconfirmable. The confirmation provider request carries a real 30-second abort deadline — strictly shorter than the lease — so an unanswered provider releases its lifecycle within the lease.

Successful submission leaves the Subscriber `pending` and clears the owner conditionally on `_id`, digest, and attempt ID. Submission failure conditionally deletes only the record created by that attempt, or restores the exact previous field values and field-presence semantics of the record it rotated; both compensations match `_id`, digest, and attempt ID, so stale cleanup cannot damage a newer lifecycle.

If an owner-clear, deletion, or rollback operation itself rejects, its database outcome is unknown rather than known-failed, and is logged as unverified with only the subscriber ID, attempt ID, and a sanitized reason — never a raw token or confirmation URL. API behavior is unchanged by that ambiguity: 202 after provider success even when the owner clear is unacknowledged, and the exact 503 after provider failure even when compensation is unacknowledged. The bounded lease is what makes an unresolved owner recoverable by a later signup.

### 9.4 Confirmation redemption primitive

An internal primitive redeems a raw confirmation token against backend time:

```text
valid pending confirmation token
→ one conditional atomic mutation
→ confirmed Subscriber
```

Eligibility requires all three of `status: "pending"`, a matching SHA-256 `confirmationTokenDigest`, and `confirmationExpiresAt` strictly after backend now. The transition is one conditional atomic Mongo mutation, not read-check-save, so two concurrent redemptions cannot both observe `pending` and both write.

Confirmation issues no unsubscribe credential and never touches `unsubscribeCredentialVersion`: raising that version would invalidate every unsubscribe link the address has already been sent.

A successful transition sets `status` to `confirmed`; clears the active `confirmationTokenDigest` and `confirmationExpiresAt`; clears the confirmation send-attempt ownership and lease fields; clears the legacy raw `confirmToken` and `unsubToken`; sets `bounced` to `false`, `dailyCount` to `0`, and `lastSentAt` to `null`; clears any prior `unsubscribedAt`; and retains a bounded receipt of the used confirmation-token digest until that token's original expiry.

Reopening the same valid confirmation link before its original expiry mutates nothing and yields the internal `alreadyConfirmed` result. After the original expiry the used token no longer needs to be recognised, and an unsubscribe clears the receipt outright (section 9.7): the link is then simply `invalid`, because the address it would have vouched for is no longer confirmed.

The primitive distinguishes four internal outcomes — `confirmed`, `alreadyConfirmed`, `expired`, and `invalid`. Expired and invalid tokens mutate no state. These remain internal results rather than a response shape; section 9.5 defines the only surface that currently maps them, and how much of each outcome a browser is allowed to learn.

Malformed tokens are rejected on shape alone, before any hashing or database work.

Concurrency and interaction with signup send ownership:

- Simultaneous confirmation attempts produce exactly one lifecycle mutation; the losing valid attempt receives `alreadyConfirmed` rather than an invalid-token answer.
- Confirmation may succeed while a signup send lease is live or orphaned. Success clears that ownership, because the lifecycle the lease guarded no longer exists.
- A late signup deletion, rollback, timeout, compensation, or owner-clear filter cannot undo a confirmed Subscriber: every such filter still requires the confirmation digest and attempt ID that confirmation cleared.

Confirmation-token generation, shape validation, and SHA-256 digest calculation are shared with signup through `src/subscriptionTokens.ts`; signup behaviour is otherwise unchanged.

### 9.5 Browser confirmation routes

The emailed link is redeemed through two public routes in `src/confirmSubscriptionRoute.ts`:

```text
GET  /api/subscribe/confirm?token=...
POST /api/subscribe/confirm
```

Every response from both routes is HTML, including every refusal. A person reading email is the only intended caller, so the shared structured JSON error envelope is deliberately not used here.

#### GET: safe by construction

Opening the link never confirms anything. Inbox scanners, link previewers, and prefetchers fetch links without a person acting, so the mutation belongs to the explicit button press instead.

The public-action pause is checked before any token work. A paused GET returns an HTML `503` page carrying no form. A missing or malformed token returns HTML `400`. A well-formed token returns HTML `200` with a no-JavaScript confirmation form.

GET performs token-shape validation only. It does not hash the token, query Subscriber, call the confirmation primitive, or mutate anything. Because it answers from shape alone, the page cannot be used to probe whether a token belongs to a real Subscriber.

GET is not rate-limited.

#### POST: middleware and handler order

```text
confirmation security headers
→ HTML public-action pause guard
→ POST-only confirmation limiter
→ route-local URL-encoded parser
→ confirmation handler
→ sanitized route-local parser-error boundary
```

Both routes are registered in `app.ts` **before** the global JSON and URL-encoded parsers. A global parser runs ahead of route middleware, so a body it rejected would be answered by the global JSON error handler — outside this route's security headers, outside its HTML contract, and logging a parser error that can quote the raw token. Route-local parsing keeps every malformed-body outcome inside the confirmation route.

POST accepts the confirmation token through `application/x-www-form-urlencoded`, the only encoding the accepted form submits. JSON bodies are not parsed for this route; an unparsed body reaches the handler with no usable token and produces the invalid-link HTML response. Malformed or oversized URL-encoded input is handled by the route-local parser-error boundary and never reaches the global JSON error handler.

The public-action pause runs before rate-limit capacity consumption, route-local parsing, validation, hashing, lookup, and mutation, so a paused confirmation performs no lifecycle work and spends no throttle capacity. The confirmation limiter is IP-based, POST-only, and allows 5 requests per 60 seconds in its own bucket, so confirming cannot spend the signup allowance.

#### POST outcome mapping

| Condition | Browser response |
| --- | --- |
| `confirmed` | HTML `200` |
| `alreadyConfirmed` | HTML `200` |
| `expired` | HTML `410` |
| `invalid` | HTML `400` |
| Rate-limited | HTML `429` |
| Public actions paused | HTML `503` |
| Unexpected internal failure | Sanitized HTML `500` |

The primitive returns no credential for the route to discard. Its `subscriberId` is internal detail and is never rendered, logged, or exposed in any form.

#### Browser security and privacy

Every confirmation HTML response — including the pause, invalid, expired, rate-limit, and error pages — carries route-owned headers:

- `Cache-Control: no-store`
- `Referrer-Policy: no-referrer`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- a route Content-Security-Policy enforcing at least `default-src 'none'`, `script-src 'none'`, `style-src 'self' 'unsafe-inline'`, `form-action 'self'`, `base-uri 'none'`, and `frame-ancestors 'none'`.

The pages load no JavaScript and no third-party resources. The form submits to the same origin, and the hidden token is HTML-escaped. Result pages never repeat the token, and no page displays the subscriber email or internal lifecycle detail.

Caught request, parser, and database details are never logged, because each can carry the body and therefore the raw token. The only permitted unexpected-failure log is a fixed sanitized event.

#### Accepted browser behavior

- The initial page states explicitly that opening the link alone does not confirm alerts; the user must select `Confirm alerts`.
- Success and already-confirmed pages state that no further action is needed.
- Expired and invalid pages offer the same privacy-preserving link back to `/` to sign up again, so neither page can be read as evidence about a Subscriber.
- Paused and unexpected-error pages read identically and tell the user to reopen the link later; the distinction survives only in the status code.
- The rate-limit page tells the user to wait about a minute and reopen the confirmation link.
- Page titles identify CommonPlate.

#### Activation boundary

Signup, confirmation activation, and alert delivery all remain publicly paused. The existence of these routes does not mean the alert flow is activated: `pauseConfirmationPage` refuses both halves while `PUBLIC_ACTIONS_PAUSED` holds.

No iOS, APNs, or push behavior was added with these routes.

The page shell these routes render — document skeleton, styles, title convention, `text/html` send helper, and the header middleware above — lives in `src/publicPage.ts` and is shared with the unsubscribe routes (section 9.7), so both emailed-link surfaces answer with the same structure and the same headers. Its title convention (`… — CommonPlate`) and `no-store` header are unchanged by section 16.

### 9.6 Unsubscribe credentials and emailed links

An unsubscribe credential is signed on demand and never stored:

```text
<subscriberId>.<credentialVersion>.<signature>
```

The signature is HMAC-SHA-256 over the canonical, domain-separated input `commonplate:unsubscribe:v1:<subscriberId>:<credentialVersion>`, encoded base64url. The key is the dedicated `UNSUBSCRIBE_SIGNING_SECRET`, at least 32 UTF-8 bytes; no confirmation digest, claim-token secret, or other credential's raw value is reused, so one credential's compromise cannot forge another.

Because the credential is derived from identity the document already carries, an authentic link does not expire and stays valid across unsubscribe, re-signup, and reconfirmation. `unsubscribeCredentialVersion` is the sole revocation lever: it is a bounded positive integer (1 to 1,000,000) defaulting to `1`, and raising it invalidates every credential signed at the previous version. Signup, re-signup, and confirmation all leave it untouched, and a document that *physically lacks* the field — one written before it existed — is treated as version `1`. That absence is the only legacy case: a persisted `null` is malformed state no schema path produces, and it is rejected rather than resolved to `1`. No migration rewrites existing documents.

Verification parses strictly — three segments, a 24-character lowercase hexadecimal subscriber id, a bounded version with no leading zeros or sign, and a canonical 43-character base64url signature — and compares signatures with a constant-time comparison. Malformed input yields no result rather than an exception. Neither signing nor verification performs any database work; comparing a verified version against the stored one belongs to the unsubscribe redemption route (section 9.7).

Real-time helper alerts and hourly digests build the link while composing the message, with no database read or write:

```text
<BASE_URL>/unsubscribe?credential=<URL-encoded credential>
```

`BASE_URL` is the single public base-URL setting, resolved in one place (`src/publicBaseUrl.ts`) and never taken from a request `Host`, `X-Forwarded-Host`, or forwarded protocol. Both send paths remain behind `PUBLIC_ACTIONS_PAUSED`, so no such link has been delivered.

#### Activation prerequisite

`UNSUBSCRIBE_SIGNING_SECRET` is validated at startup, from the same `app.ts` environment-validation block as `CLAIM_TOKEN_HMAC_SECRET` and through one reader (`src/unsubscribeCredential.ts`). The check runs before the Express app is constructed, before any route is registered, before the MongoDB connection, and before the process listens, so an unpaused process cannot expose a public-action surface, accept a signup or confirmation, send an alert, deliver a digest, or serve an unsubscribe link without being able to sign one.

The requirement is conditional on the pause, which is what makes those surfaces reachable at all:

| Public actions | `UNSUBSCRIBE_SIGNING_SECRET` | Startup |
| --- | --- | --- |
| Paused | Absent | Starts; paused routes and delivery stay unavailable |
| Paused | Valid | Starts; functionality stays paused |
| Unpaused | Absent | Refused |
| Unpaused | Empty | Refused |
| Unpaused | Fewer than 32 UTF-8 bytes | Refused |
| Unpaused | 32 UTF-8 bytes or more | Starts |

While paused the variable is not read at all, so a paused local or deployed process is never asked for a secret no paused path can use. A refusal logs a message naming only the variable — never its value — and exits non-zero. No other secret is substituted for a missing one, and the validated secret is discarded rather than returned or cached: every signing and verification path still reads it where it is needed.

### 9.7 Unsubscribe redemption routes

`GET /unsubscribe?credential=<credential>` and `POST /unsubscribe` are the browser surface for the emailed link. Both answer in HTML behind the shared emailed-link security headers (section 9.5) and an HTML pause guard.

#### Safe by construction

Opening the link never unsubscribes anyone. Mail scanners, previewers, and prefetchers fetch inbox links with nobody acting, so the GET only renders a form and performs no mutation on any path, including a repeated open. The mutation belongs to the explicit POST.

Unlike the confirmation GET, this one does read a Subscriber, because an unsubscribe credential is unforgeable: a `200` is returned only when the credential verifies against an existing Subscriber whose stored version matches. What the page never discloses is the state it found. Pending, confirmed, and already-unsubscribed subscribers receive the identical page, and the redemption primitive reports only whether the link is usable, so no page can carry a status it was never told.

Malformed, tampered, unknown-Subscriber, and version-mismatched links all receive one generic `400` page carrying no form. A `503` pause page and a `500` unexpected-error page — including the case where `UNSUBSCRIBE_SIGNING_SECRET` is missing — read identically to each other and carry no form either.

#### Middleware and handler order

The pause guard runs before the rate limiter, credential parsing, the signing-secret read, the Subscriber lookup, and any mutation, so a paused request performs no lifecycle work, touches no configuration secret, and consumes no throttle capacity. The POST then runs its own 5-per-60-second limiter, route-local URL-encoded body parsing, the handler, and a parser-error boundary that answers a rejected body with the invalid-link page. Both verbs are registered ahead of the global body parsers for the same reason the confirmation POST is. The GET is not rate limited: mail clients prefetch, and it mutates nothing.

#### The unsubscribe mutation

A valid POST performs one conditional atomic update:

- the transition is accepted from `pending`, `confirmed`, and `unsubscribed` alike, so a repeated submission is a no-op and every prior status yields the same generic `200` page;
- `_id`, `email`, `unsubscribeCredentialVersion`, `dailyCount`, `lastSentAt`, `bounced`, and SendLog history are preserved — unsubscribing is a status change, not a deletion, a reset, or a revocation, and the link just used must keep working;
- every confirmation credential the row holds is cleared in the same update — the active `confirmationTokenDigest` and `confirmationExpiresAt`, the confirmation send-attempt ownership and lease fields, the legacy raw `confirmToken` and `unsubToken`, and the bounded confirmation receipt `lastConfirmedTokenDigest` and `lastConfirmedTokenExpiresAt`. A pending row's outstanding link cannot later activate an address that asked to stop, and a confirmed row's original link can no longer be answered `alreadyConfirmed`, which stopped being true the moment the update ran; it becomes `invalid` like any unrecognised token, and cannot return the row to `confirmed`. The cleared set is derived from the confirmation clear list and the receipt definition rather than restated, minus `unsubscribedAt`;
- `unsubscribedAt` is written with `$ifNull`, so the first unsubscribe of the current lifecycle stands. Confirmation clears the field, so a reconfirmed address that unsubscribes again records the new lifecycle's time;
- no email is sent, and no credential is rotated or issued.

The resulting `unsubscribed` status is what makes the subscriber ineligible: both the real-time alert query and the hourly digest query select on `status: "confirmed"`, and neither selection rule was changed.

Clearing the confirmation credentials ends the current lifecycle only. Signing up again rotates a fresh pending confirmation credential onto the same document, `_id`, and `unsubscribeCredentialVersion`, and reconfirming it works normally; the unsubscribe credential emailed before any of that still opens the page and still unsubscribes afterwards.

#### Version comparison and the rotation race

After cryptographic verification, the persisted version is normalized through `resolveUnsubscribeCredentialVersion` before it is compared, so a document that physically lacks the field is version 1 and accepts a version-1 credential; a direct comparison would reject every legacy row. A stored version of 2 rejects a version-1 credential and accepts a version-2 one.

Physical absence is the only fallback. A persisted `null` is not a legacy row — nothing in the schema, its default, or any write path produces one — so it is treated like any other value outside the accepted range: the link is unusable at both verbs, the row is not mutated, and the malformed value is left exactly as found rather than repaired by a redemption request.

The update filter repeats the exact persisted version state that was validated: `$exists: false` when the row physically lacked the field, and the exact stored integer otherwise. It is never `{unsubscribeCredentialVersion: null}`, which would match a physical null and an absent field alike and so could state neither condition. A rotation that lands between the read and the update therefore loses the update, and that miss — like a row that disappeared — is reported as the same generic invalid result, disclosing neither.

#### Privacy and page security

No page renders a subscriber's address, status, counters, history, or internal id. The credential exists only in the incoming link and the hidden form field, is escaped where it is rendered, and is never logged; neither is the raw query, the body, nor a parser or provider error. No page loads an external script, stylesheet, image, font, or tracking resource, and no page carries JavaScript, a CAPTCHA, a cookie, or a redirect. Credentials have no expiry.

Redemption existing is not activation: `pauseUnsubscribePage` refuses both verbs while `PUBLIC_ACTIONS_PAUSED` holds, and signup, confirmation, real-time alerts, and the digest all remain paused.

### 9.8 Participant-authorized email unsubscribe (W3-N2)

`POST /api/participant/email-alerts/unsubscribe` authorizes one explicit in-app "Turn off email alerts" operation, gated by the same participant-authority mechanism as request creation and claim (section 3.1). The route accepts no body: it never takes a caller-supplied email or Subscriber ID, and the only address ever acted on is the exact normalized address `resolveParticipantAuthority` resolves the caller's credential to.

Participant identity, Subscriber identity, and Push Installation identity remain distinct (section 3.1). This route does not create, read, or otherwise touch Subscriber state beyond the one declarative mutation below, and no Participant ID is ever persisted onto a Subscriber.

The operation is one unconditional atomic update matched by the resolved email, not a read-then-branch, so absent, pending, confirmed, and already-unsubscribed Subscriber cases are indistinguishable to the caller: all converge externally to the same result, `{ "email": { "unsubscribed": true } }`. An absent Subscriber performs the update against zero matching documents and still reports the same result, because there is nothing to turn off and the declarative result is already true.

The mutation sets `status: "unsubscribed"`, writes `unsubscribedAt` only if not already set (`$ifNull`), and clears the same confirmation-credential fields the existing emailed-link unsubscribe clears (section 9.7) — the active `confirmationTokenDigest`/`confirmationExpiresAt`, confirmation send-attempt ownership/lease fields, the legacy raw `confirmToken`/`unsubToken`, and the bounded confirmation receipt. It does not touch `unsubscribeCredentialVersion`: unsubscribing is not credential revocation, and an already-emailed unsubscribe link must keep working afterward.

This is declarative and idempotent, matching `PUT /api/installations/push`: a repeated call, a retry after a dropped response, or concurrent calls from two devices holding the same participant credential all converge on the same result with no special-casing. It is rate-limited in its own bucket, matching the installation-push and claim mutation buckets, so it cannot spend, or be spent by, another public action's allowance, and it is registered ahead of the global body parsers and behind `PUBLIC_ACTIONS_PAUSED` like the other participant-gated routes.

Existing signed emailed unsubscribe credentials and browser GET/POST unsubscribe behavior (section 9.7) remain fully supported and unchanged; this route is an additional path for the browser-only, no-current-credential, reinstall, and already-delivered-link cases participant authority can reach that an emailed link cannot.

### 9.9 iOS email-alert state truth (W3-N2)

iOS may present Email Alerts Off only after the backend confirms the declarative result of section 9.8. That local Off presentation is not a durable Subscriber-status cache and cannot itself establish a future On state: iOS still cannot infer Email Alerts On from a generic signup `202`, signup presentation history, participant credential possession, or prior confirmation (section 9.1). A later signup or reconfirmation attempt returns to the existing `Check your email` presentation rather than continuing to show a stale Off.

### 9.10 Participant-authorized Email Request Alert state read (W4-N0)

`GET /api/participant/email-alerts/state` lets a verified participant authoritatively read whether their CURRENT verified NYU email presently has active Email Request Alerts. Gated by the same participant-authority mechanism as section 9.8: the principal is derived only from `resolveParticipantAuthority`, never from a caller-supplied email, query parameter, or body field, so no arbitrary-address lookup is possible.

The response is minimal privacy-safe truth only — `{ "email": { "active": boolean } }` — with no Subscriber id, credential, or other lifecycle field. `active` is `true` exactly when the resolved principal has a Subscriber row with `status: "confirmed"` (section 9); absent, `pending`, and `unsubscribed` all read `false`. This is deliberately narrower than real-time alert/digest send eligibility (section 8.1), which additionally requires `bounced: false`: N0 reports Subscriber lifecycle On/Off only and does not represent bounce or other provider-delivery state. A read that cannot establish current truth — an unauthorized, unavailable, or failed lookup — never reports `false` as a substitute for unknown; the caller must treat it as unresolved rather than as confirmed Off.

The read is side-effect free: it performs no signup, confirmation, unsubscribe, or other Subscriber mutation, and changes no Push, provider, or delivery behavior. The response carries `Cache-Control: private, no-store` and `Vary: x-commonplate-participant`, matching the existing caller-specific isolation on `GET /api/requests`, so a result for one participant credential is never cached or reused for another or for no credential at all. A result or an authority-invalid rejection resolved under a participant authority that a later Change Email has since replaced cannot become truth for, or retire, the replacement credential — only the still-current credential's own outcome is applied, mirroring the existing W3-I1 stale-response fence.

Existing signup, confirmation, unsubscribe (sections 9.1–9.8), Push (section 8.6), and local `Check your email` presentation-history semantics (section 9.9) are unchanged by this read; the local presentation history remains non-authoritative and is never treated as N0 truth.

## 10. Public-actions pause and scheduled jobs

`PUBLIC_ACTIONS_PAUSED` fails closed unless explicitly set to `false` or `0`. It blocks public request creation, subscription signup, both halves of the browser confirmation flow (section 9.5), both halves of the unsubscribe flow (section 9.7), claim, claim-extension, and release mutations, real-time helper alerts, and hourly subscriber digests. The API mutations answer a paused request in JSON through `pausePublicAction`; the confirmation and unsubscribe routes answer in HTML through `pauseConfirmationPage` and `pauseUnsubscribePage`. It does not block fulfillment: a valid active claim token or reservation-scoped continuation authority is already authorization to record an order, and blocking that path could strand a helper who has already placed one. It also does not block participant Block, Unblock, or Blocked Students management, which are safety controls (section 5.3); the one pause-governed part is the reservation release inside a helper's `No, not yet` Block, which commits neither the Block nor the release while paused.

The same variable is the activation switch for the unsubscribe signing secret: unpausing is what makes that secret a startup requirement (section 9.6). It also makes `PARTICIPATION_HMAC_KEYRING`, `BLOCK_SAFETY_HMAC_KEYRING`, and `PARTICIPANT_DELETION_SIGNING_SECRET` startup requirements; existing keyring/secret validators fail startup before route registration, database connection, or listening when any is missing or invalid. Paused production startup does not require them. The isolated review runtime remains paused and rejects production participant credentials.

Production uses `BASE_URL=https://api.goodgrubapp.com` as its configured HTTPS
origin and requires `FROM_EMAIL=GoodGrub <noreply@goodgrubapp.com>`; production
cannot select the development sender fallback. These settings do not establish
DNS, TLS, link reachability, or email delivery. The production API returns 404
for the deprecated CommonPlate homepage, request form, and fulfillment pages,
while preserving API routes and supported confirmation and signed-unsubscribe
flows. Development behavior for those legacy pages is unchanged.

`CRON_ENABLED=true` controls only the hourly expired-request cleanup backup to TTL deletion. The hourly digest, daily confirmed-subscriber `dailyCount` reset, and ten-minute SendLog failure monitor are registered independently of `CRON_ENABLED`; the digest additionally exits when public actions are paused.

Notification-management correctness (W3-N2, sections 8.6 and 9.8–9.9) does not itself change this pause boundary or authorize production/TestFlight unpause. Deployed secrets/provider configuration, signed build environment, and provider proof remain separate release gates (section 11).

## 11. Durable deferrals that constrain current behavior

- An application-level provider-wide send-volume ceiling for real-time helper-alert email. None exists today; a provider quota or rate-limit refusal is handled through the existing per-subscriber `SendLog` failure path rather than by pre-emptively skipping subscribers. Revisit during Week 5 production email configuration, and only if actual provider rate or quota evidence requires one.
- Cleanup of expired pending Subscribers; they stay notification-ineligible, so the current consequence is storage growth.
- Physical cleanup of expired confirmation receipts (`lastConfirmedTokenDigest`, `lastConfirmedTokenExpiresAt`) on rows that stay confirmed. Unsubscribing now clears the receipt outright, and the expiry comparison already prevents recognition after the original window, so the remaining consequence is stored data, not behaviour.
- Provider timeouts outside the confirmation email, and durable email-outcome persistence. Only `sendSubscriptionConfirmationEmail` currently carries an abort deadline.
- Browser rendering of the shared structured error envelope on the signup form, which must land before signup is unpaused.
- Paid-but-unrecorded recovery beyond the in-memory, one-resend fulfillment safeguard.
- Physical-device and release backend configuration.
- Full privacy and accessibility review.
- Release/Archive/TestFlight `aps-environment` signing and build-configuration alignment. Debug and simulator alignment is proven; a signed Release/Archive/TestFlight build has not been verified. This, along with release backend/APNs reachability and configuration and the remaining activation/unpausing decisions in section 10, gates distribution — see section 1. Physical-device push proof for helper new-request routing (section 8.3) and requester-fulfillment push (section 8.2) has passed on a development device, but that is not evidence about a signed Release build.
- W4-S3 (section 15) ships with ZERO qualified local providers. Apple local-provider evaluation, qualification, and production enablement, multi-screenshot accuracy/consistency, and the mixed manual/AI meal and post-edit provenance presentation questions are not settled and are owned by W4-S2 (weekly spec). Checkout/review input is accepted Requester behavior as of W4-R4.1 (section 14.8) and is no longer an S2-owned deferral. The S3 physical-iPhone smoke used a temporary development LAN backend configuration; it does not establish Release/TestFlight endpoint behavior or local-model quality.
- W4-R4.2 (section 14.9) recognition is deliberately narrow and its proof is bounded. Unsupported-venue (B) and different-venue (C) recognition fires only on the Meal Exchange identity line; every other structure resolves to A. Real confirmed unsupported-venue accuracy is unmeasured (B/C proof is synthetic). The local attempt still runs for B/C and there is no server-side short-circuit. The post-R4.2 versioned selection-level evaluation (a named S2.1 follow-on) is required before the Week 4 pilot release gate while Screenshot Assistance is enabled and is not satisfied by R4.2 acceptance. Physical VoiceOver, State A's final visual, the menu-path-conflict-after-recovery interaction, and Off-while-pending stale retirement were not fully covered on a physical device (`docs/testing.md`); broader VoiceOver/focus acceptance remains W4-A1's.
- Participant-blocking surfaces owned elsewhere (section 5.3): the requester → helper Block entry (placed-order continuation presentation is accepted in W4-R3, section 22), requester-facing resolution of a post-Yes stopped request (R3 or a later slice with explicit product authority), Report and its follow-up with Block (W4-U1.2, not carded), Block continuity across completed account deletion and same-email recreation (W4-P2), final trust/privacy/support presentation and any order-support destination (W4-T1), and retirement of the legacy Active Requests destination and its foreground-warning routing (W4-R5). U1.3 verification limits are in `docs/testing.md`.
- W3-D1 (section 6.3) integrated physical-iPhone runtime scenarios — commit/terminate/relaunch/reconcile, terminal-expiry non-resurrection, and a fresh operation after expiry — were not executed before acceptance. Faith explicitly accepted W3-D1 with this remaining limitation (`docs/testing.md`). Automated/simulator/backend evidence for D1 does not establish real physical-device process termination, relaunch sequencing, or network-interruption convergence at the post-commit boundary.

## 12. AI screenshot proposal (W4-S1)

**V1.0 availability: excluded (W5-IOS1, section 26).** The behavior below is preserved implementation, not public V1.0 behavior; the route refuses and no iOS entry point exists.

Screenshot assistance is an optional, non-authoritative aid to the existing Request Food form. Manual entry remains fully usable whether or not AI is used, is On, or produces useful output. `POST /api/request/screenshot-proposal` is a distinct route, DTO, and response vocabulary from request creation: it can never call `createRequest`, mint or consume an `x-commonplate-operation-id`, create or update a `RequestOperation`/`Request`, consume daily request quota, send a requester/helper notification, or enter D1 ambiguity recovery. Only the requester's later, existing, explicit Submit action can construct `CreateRequestPayload` and enter `RequestStore.createRequest(...)`; AI has zero Request/D1/submission authority. iOS admits at most one active `PhotosPicker` screenshot selection at a time.

**Eligibility is accident prevention, not authenticity verification.** The deterministic gate (`evaluateEligibility` in `src/screenshotEligibility.ts`) only guarantees that the selected image sufficiently resembles a supported category for CommonPlate to attempt optional extraction; it never claims or implies that Grubhub genuinely produced the image or that OCR proves origin. The Requester eligible categories are exactly three (the third added by W4-R4.1, section 14.8): a Grubhub cart/bag screenshot; a detailed historical/past Grubhub order screenshot satisfying strict H5 — legible image, exact `View order` title, `Order information` heading, and a quantity-prefixed item line; and a Grubhub checkout/review screenshot as defined in section 14.8. Orders list/index, confirmation/tracking, receipt/payment-only, item-detail, menu/browse, and other Grubhub screens remain unsupported independent inputs; a receipt/payment sheet by itself remains unsupported. The cart/bag rule excludes checkout-context phrasing (`review your delivery order`, `place your delivery order`, `place your pickup order`, and their pickup equivalents) so a checkout screen is classified as checkout/review (section 14.8) rather than satisfying the cart rule merely by containing a cart phrase as a substring. H5's quantity-prefix requirement is not relaxed to improve OCR recall: a genuinely supported historical-order screenshot may be rejected when on-device OCR fails to recognize H5-required evidence. This is an accepted V1 limitation, not an implementation defect, because manual entry remains available.

A compound screenshot (unsupported foreground UI — a modal, popup, receipt, or payment surface — visible alongside a supported category) may be eligible when the visible supported evidence independently satisfies its own deterministic category rule; unsupported foreground UI neither automatically disqualifies nor independently qualifies a screenshot. Eligibility, and the independent meal-swipe corroboration signal, are evaluated only against `localEvidenceText` — on-device Apple Vision OCR text produced and sent by iOS before the provider is ever called — never against anything the OpenAI provider itself returns; validating a provider's claim against evidence the same provider produced is not independent corroboration.

**Proposal allowlist and partial proposals.** Eligibility does not require a complete proposal. AI may propose only location, literal food, and meal swipes; timing, preferred pickup time, and pickup name remain manual in all cases regardless of what the `RequestFoodFormDraft` seams could technically hold. Zero safely proposed fields is "no useful extraction," not successful prefill. Location is proposed only when independent OCR evidence resolves unambiguously to exactly one current `shared/vendors.json` entry; older/generic or historical venue text that cannot be resolved to exactly one current entry (e.g. against the two current distinct Upstein entries) omits the location proposal rather than guessing. Resolving a location does not by itself authorize applying anything: application of a screenshot-derived field is gated by the requester venue disposition in section 14.9 (W4-R4.2). A proposed `mealSwipes` value survives only when it is an integer `1`–`5` and the literal `1M`-style marker count in the independent OCR evidence matches it exactly; a mismatch drops the value rather than coercing it. A bare, unlabeled yes/no modifier value is sanitized/discarded; a genuinely labeled value (e.g. "No Side," "No Bag," "Yes Bag") is unaffected. Sections 14 and 14.8 extend this allowlist (structured Meal items, the deterministic Dining Dollars estimate, and the deterministic menu path) and narrowly supersede the literal-marker-only rule for `mealSwipes` with the bounded top-level-meal inference in section 14.8; provider output remains unable to supply the menu path or any money value.

**Adversarial and schema safety.** Raw provider output is never proposal authority by itself. Presence of any forbidden field (`pickupName`, `timing`, `preferredPickupTime`, `action`, `submit`, `reasoning`, `explanation`) refuses the output before schema parsing even runs, independent of whether the rest of the shape is otherwise valid. All remaining output passes a `.strict()` schema before any of it can populate a `RequestFoodFormDraft` seam. Prompt-injection or schema-escape attempts embedded in image text cannot reach the final proposal, the UI, logs, or any persisted state.

**Manual precedence and generations.** Manual requester edits always outrank an AI-proposed value for the same field. Replacing the selected image clears only fields still holding a still-AI-proposed value from the prior generation; a manually-edited field is never reverted or overwritten by a new generation. A stale, replaced, or disabled analysis can never mutate the current draft state.

**Data handling.** CommonPlate deliberately persists no raw screenshot, no OCR output, and no provider request/response content; only content-free operational analytics (success/failure/latency classification, never extracted values or image data) may be recorded, and any in-memory/temporary artifact used during a single proposal request does not survive past that request's completion or failure. Provider direction is the OpenAI API; standard OpenAI API retention is the accepted V1 boundary — CommonPlate does not claim Zero Data Retention or Modified Abuse Monitoring. **W4-S3 consent authority (section 15):** the single app-level Screenshot Assistance control is the sole authority for both local and external Screenshot Assistance processing. A screenshot may be transferred to the provider only while valid Screenshot Assistance consent exists, established by an explicit `Turn On` on the Off → On disclosure and bound to the Screenshot Assistance purpose, OpenAI, and the selected screenshot images. There is no first-use third-party disclosure before screenshot selection and no per-attempt external-AI prompt. Off revokes the consent, prevents any local or external processing and any new provider transfer, and retires pending attempts.

## 13. Requester journey integration (W4-R2)

R2 delivers the authoritative requester loop: Home → `Request a Meal` → existing verification when needed → pushed `Request Food` → manual or optional Screenshot Assistance draft/review → explicit Post → Posting → authoritative Success, definitive failure, or D1 ambiguity → authoritative Home re-entry.

**Navigation.** Request Food is a pushed subordinate destination on `ContentView`'s existing root `NavigationStack` (analogous to Settings), not a sheet and not a nested local `NavigationStack`. It uses ordinary stack Back navigation. Entry-verification sequencing, mounted-draft preservation, `RequestStore`/D1 authority, and authoritative successful re-entry to Home (section 3.1, section 6.3) are unchanged.

**Early request-creation eligibility boundary.** R2 consumes W4-Q1's authoritative read (section 7.1) only after verified participant authority exists. For an already-verified identity, `Request a Meal` performs an authoritative Q1 read before the form is exposed; eligible continues to Request Food, exhausted surfaces the limit before form investment. For an identity not yet verified, verification precedes the Q1 read; cancellation or unsuccessful verification never queries Q1. Missing authority, error, cancellation, or unknown/stale Q1 state is never treated as eligible. An eligibility read that cannot resolve presents a retryable state — title `Requesting is temporarily unavailable`, body `Try again in a moment.`, and a `Try Again` action that performs a fresh Q1 read — distinct from the unchanged, non-retryable exhausted state (`Daily request limit reached. Try again after midnight Eastern Time.`). Final `POST /api/request` quota enforcement (section 7) remains the sole authoritative create-time check; R2 owns only this early boundary/presentation.

**Draft lifetime.** An unfinished Request Food draft survives ordinary departure from the pushed route and background/foreground transitions for the current app process/session — a bounded in-memory lifetime, not durable cross-launch persistence. Returning Home and reopening `Request a Meal` restores the same draft: dining location, order details, meal swipes, pickup name, ASAP/Later state, chosen Later time, valid AI-proposed values, and manual edits made after those proposals. Manual values continue to outrank AI; stale or replaced analysis can never overwrite the restored draft; AI retains zero Request/D1/submission authority (section 12). Successful authoritative request creation clears the completed draft.

**Timing.** ASAP/Later selection preserves all existing timing authority (section 2.1). With ASAP selected, no secondary time selector is shown. A discreet `Timing information` control opens `How timing works`; there is no permanent explanatory subtitle. Its accepted body (W4-UI1 CP3, 2026-10-24) puts each sentence on its own line:

```text
ASAP is shown to helpers now.
Later is shown at your chosen time.
Requests stay open for up to 3 hours.
```

With Later selected, a row of nearby valid quick-time choices plus `Choose time` is shown; `Choose time` opens the native iOS time-selection control, and an exact chosen time becomes the active Later value, replacing the `Choose time` label in place. `America/New_York`, existing Later bounds/validation, and backend-derived three-hour availability (section 2.1) are unchanged.

**Screenshot Assistance completion acknowledgement.** After every successfully completed Screenshot Assistance analysis, a compact inline `✓ Screenshot checked` acknowledgement appears beneath the Screenshot Assistance area, alongside a `Change` action that reopens the picker to select and analyze another screenshot. No dynamic explanatory second line is shown, and no screenshot count is shown. This presentation is inline, compact, never modal or a toast, uses no success haptic, and the newest result replaces the previous acknowledgement in place. It communicates only that analysis completed, independent of whether any field changed, and does not alter manual precedence, S1's proposal-only authority, or the absence of AI auto-submit.

**Screenshot Assistance entry and the Off-state re-entry path (W4-S3 supersedes R2's first-use consent).** The pre-S3 first-use disclosure (`Use Screenshot Assistance?` / `Continue` / `Not now`) and its Decline-turns-Off behavior no longer exist; the only disclosure is the Off → On disclosure defined in section 15. While Screenshot Assistance is On, choosing a screenshot proceeds through Screenshot Help (if not yet completed on this installation) and the photo picker, then on-device routing, with no further disclosure or consent prompt; selecting and locally analyzing screenshots sends nothing off-device. When Screenshot Assistance is Off, Request Food shows a discoverable `Screenshot Assistance` / `Off` / `Turn on Screenshot Assistance` row; tapping it presents the section 15 disclosure, and only `Turn On` enables Screenshot Assistance and continues into the same Help/picker step. `Not Now` leaves it Off and establishes nothing. Toggling Off/On does not reset previously recorded Screenshot Help completion; enabled state and Help-completion state remain independent. The remote-transfer authority is the standing consent established by that disclosure (section 15).

**Screenshot Help.** `What should I screenshot?` opens a temporary local overlay over Request Food — never a permanent subpage or root destination — presented as a centered modal popup with Request Food dimmed behind it, sharing the disclosure's outer modal geometry, and showing cart and past-order examples. An enlarged example detail exposes a local Back only when it actually returns to the overview. `Got it` is the overall dismissal, returning to the exact same Request Food task and unfinished draft. Only approved production-design assets are used; no real screenshots, research fixtures, or other unapproved imagery may enter production assets or Git history.

**Submission, Posting, and outcomes.** Duplicate-submit protection, D1 ambiguity, and definitive-failure/draft-preservation behavior (sections 5, 6.3) are unchanged. Posting shows one native indeterminate `ProgressView` tinted CommonPlate purple. On authoritative creation, Success replaces it immediately with no delay, firing exactly one success haptic at that boundary, holding Success for approximately 1.6 seconds (3.5 seconds for a first post with guidance, section 1.7), then dismissing natively to authoritative Home re-entry. D1's unresolved-ambiguity state remains distinct from definitive failure and receives no success/failure haptic while unresolved.

**Home ownership presentation.** R2 forces no insertion, reordering, pulse, highlight, fade, or auto-scroll into Home; the returning requester relies entirely on H4's authoritative fetch and ownership presentation (section 1.4) to reflect a newly created request. Within the dedicated owned-request zone, `RequestCardView`'s `YOUR REQUEST` eyebrow is suppressed and preserved everywhere else (recorded in section 1.4). This is narrowly superseded by W4-D2's Success→Home continuity (section 6.4): a fresh create now inserts the exact created request immediately, ownership-resolved, as part of the accepted card-continuity handoff. R2's other Posting/Success/D1-ambiguity presentation, navigation, Timing, and draft-lifetime contract is otherwise unchanged.

## 14. Structured meal requests and multi-screenshot evidence (W4-R4)

R4 replaces the pre-R4 flat `food` + `pickupName` + meal-swipes-only request representation with a structured requester representation, and extends Screenshot Assistance (section 12) to jointly analyze up to five screenshots of one logical Grubhub order. Faith accepted W4-R4 on 2026-09-29 (weekly spec section 7).

### 14.1 Structured requester representation

Every accepted `POST /api/request` shape (the canonical/iOS shape and `legacyWebSchema` alike) now carries one of exactly two mutually exclusive menu paths, `menuPath`: `meal-exchange` or `dining-dollars` (wire values; `MEAL_EXCHANGE_PATH` / `DINING_DOLLARS_PATH` in `src/structuredRequest.ts`).

- `mealSwipes` remains the shared bounded integer field, now spanning 0–5: Meal Exchange requires 1–5 active meal swipes; Dining-Dollars-only requires exactly 0.
- `mealItems[]` carries exactly one active Meal item per active Meal Exchange swipe (never more, never fewer); each item's canonical fields are `name` (required, non-blank) and `details` (optional, non-blank when present). Dining-Dollars-only requests carry no meal items.
- `estimatedDiningDollarsCents` is an exact positive integer count of cents, never a float. On Meal Exchange it is an optional top-up estimate bounded at `$25.00` (2,500 cents); on Dining-Dollars-only it is a required whole-order estimate bounded at `$50.00` (5,000 cents).
- `orderDetails` is required, non-blank free text on Dining-Dollars-only requests and forbidden on Meal Exchange requests.
- `pickupName` is removed from the R4 structured requester contract. A payload that still carries `pickupName` is refused with the same generic structural failure as any other malformed payload (`src/createRequestRoute.test.ts`).
- The persisted single-line `food` field is retained only as a backend-derived compatibility summary (`deriveFoodSummary`), deterministically composed once at creation from the structured fields above. It is never client-authoritative, never an inference or default, and exists so already-accepted downstream projections, emails, push payloads, and digest lines (section 8) can keep rendering it without an R4-caused redesign; the structured fields themselves are projected alongside it for a later, separately routed H1 consumption sync.

An invalid combination for the chosen path (e.g. a Dining-Dollars-only request carrying meal entries, a Meal Exchange request with fewer meal entries than swipes, or an out-of-range estimate for the path chosen) is refused as a generic structural failure; nothing is defaulted, repaired, or coerced into the other path. Unrelated legacy compatibility behavior not actually changed by this contract (daily abuse control, installation association, W3-D1/W4-D2 recovery) is unchanged.

### 14.2 Requester UI behavior

Request Food lets the requester choose between Meal Exchange and Dining Dollars; a Dining-Dollars-only request is a fully supported request shape, not a degraded path. Required fields left empty remain visually neutral — no red/invalid treatment on an untouched or focus→blur-empty required field — while the incomplete state keeps `Post request` disabled; a non-empty invalid value (e.g. an out-of-range Dining Dollars amount) may show field-specific validation feedback after blur. W4-UI1 CP3's narrow create-only exception: nonblank Details with a blank/whitespace-only meal name shows `Enter a meal item to go with these details.` below the expanded or collapsed meal, in its error styling and meal-name accessibility hint. Supplying the name or clearing Details removes the prompt; entirely blank meals remain neutral. This does not change backend validation, posting eligibility or Edit's validation policy.

Switching between Meal Exchange and Dining Dollars clears branch-specific visible validation while preserving appropriate already-entered values; it does not otherwise reset the form. The Dining-Dollars ordering field is labeled `What are you ordering?` with example treatment `e.g. Chicken Wings`. A populated Meal summary is content-driven, and stored `Details` wraps fully without an ellipsis. The existing meal editor/add-item interaction is retained, not replaced with repeating cards. The expanded editor keeps `Optional` right-aligned beside Details and a compact bottom-right `Done` with a minimum 44pt tap target, comfortable padding and natural multiline growth. On Request Food, that Done dismisses editing and collapses the meal locally without a server save or content mutation.

`Post request` uses the accepted adaptive placement: bottom-anchored for a short form, flowing with content once the form grows past the viewport (e.g. Later expanded). It is completely hidden while the software keyboard is visible and restored on dismissal. There is no floating keyboard Done or keyboard-toolbar action. Outside-input taps and interactive downward scrolling dismiss the keyboard, native input switching and focus visibility are preserved, and keyboard dismissal does not clear the draft.

**Dining location and deferred external shortcut (W4-UI1 CP3, accepted 2026-10-24).** Request Food omits visible street-address text while preserving the selected venue identity and underlying ordering/validation data. The requester Grubhub shortcut is deferred to a follow-up slice and is **not delivered by CP3**. Release exposes no requester links. An existing explicitly opted-in local Debug QA action, `View menu on Grubhub`, remains directly below Dining location, requires a validated local API override, and reuses N1's strict selected-venue/menu `GrubhubRestaurantDestination.url(...)` lookup, never its generic fallback. No mappings or helper shortcut behavior are changed. A follow-up must establish actual restaurant/menu content for every offered destination and populated-draft preservation after real external return before release enablement; loading shells, HTTP success and helper-only handoff tests are not that proof. Nothing implies shared carts, item-specific deep links or GoodGrub placing external orders.

**Requester Grubhub shortcut (W4-UI1 CP2, accepted 2026-10-26; supersedes the CP3 deferral above).** `View menu on Grubhub` appears directly below Dining location in Debug and Release, with no local-QA or Debug gate. It resolves the selected venue and menu path only through N1's strict `GrubhubRestaurantDestination.url(restaurantID:menuPath:)`; there is no generic fallback, duplicated mapping or new configuration, and an unmapped or missing venue shows no link. Helper shortcuts, mappings, Request Food layout and draft lifecycle are unchanged. Faith manually verified that all 20 mapped destinations open the correct restaurant and menu and that returning preserves the populated draft (`docs/testing.md`).

### 14.3 Screenshot Assistance (multi-screenshot evidence)

Screenshot Assistance remains optional and manual-first (section 12); R4 extends it to accept up to five screenshots representing one logical Grubhub order, jointly analyzed as evidence for that one order rather than as independent per-image proposals. Overlapping evidence across screenshots must not duplicate logical order content (e.g. the same item counted twice because it appears in two screenshots). A screenshot that is unsupported or ineligible under the existing deterministic gate (section 12) remains fail-closed independent of how many other screenshots in the same selection are eligible. Screenshot Assistance still never auto-submits, and requester-entered values remain authoritative over any screenshot-derived value. A requester-selected dining location is never overwritten by a screenshot-derived venue except through the explicit confirmation in section 14.9.

**Manual authority and provenance.** Meal item (`name`) and Details are independent authority/provenance units, tracked per field rather than per Meal. A current non-empty manual value in either field is preserved on a later eligible rerun; clearing a field removes that field's manual protection, and a later valid reproposal may then fill it again. An untouched, still-screenshot-derived value remains eligible to be updated by a later eligible rerun. The requester-facing screenshot provenance label is `Suggested` (it replaced `Filled from screenshot` in W4-R4.1); it reflects only current screenshot provenance, never a permanent historical "was once suggested" marker, and `Manually selected` marks an explicit requester-owned value or path. The collapsed and expanded Meal UI both present exactly one Meal-level provenance badge, using OR semantics: the badge shows if the Meal item OR the Details field is still screenshot-derived. The badge means "Some content in this meal came from Screenshot Assistance," not that every field in that Meal is screenshot-derived; the underlying field-level provenance model is not collapsed by this single badge.

### 14.4 Rerun qualification and feedback

Only a successfully completed, eligible Screenshot Assistance analysis establishes completed-run state; an unsupported, ineligible, failed, cancelled, or nil outcome does not. The first eligible success on a given draft never shows rerun-only preserved-entry feedback. A later eligible success that preserves one or more requester-owned manual values may show exactly `Screenshot checked. Your existing entries were kept.` — and only that later-success case. This feedback is temporary, inline, non-blocking, and non-layout-reserving; it retires cleanly on view disappearance and on Screenshot Assistance disablement, and stale cleanup cannot clear newer feedback or leave the UI in a stranded feedback state. Section 14.9 (W4-R4.2) records how a completed analysis whose outcome is withheld pending venue recovery establishes completed-run state, and the narrow conditions under which this feedback may follow a confirmed recovery.

### 14.5 Current-cart Dining Dollars proposal authority

Screenshot Assistance's Dining Dollars estimate is never provider (OpenAI) authority — it is populated only by a deterministic, independent OCR rule evaluated against on-device `localEvidenceText` (section 12), the same evidence-independence boundary S1 already established. Strong, explicit current-cart/order-level evidence (e.g. a literal `3M + $2.00` marker) may support a proposal of 3 meal swipes plus an estimated `$2.00`. An arbitrary item- or modifier-level `+$2.00` (e.g. a paid modifier) does not by itself establish a Dining Dollars proposal. Ambiguous evidence fails closed — no proposal — rather than guessing. Section 14.8 extends this authority to one deterministic order-level `Total` for the Dining-Dollars-only whole-order estimate on a current cart/review. A historical/past-order money proposal remains a deferral, not an accepted V1 behavior, if still current per the deferral ledger (section 11).

### 14.6 D2 boundary

W4-D2 (section 6.4) remains the sole request-create recovery/terminal authority. R4 introduces no competing terminal, recovery, or pending-operation semantics; R4's pending-operation compatibility work consumes D2's terminal-recovery authority rather than defining its own.

### 14.7 Deferrals

Hardware-keyboard Tab traversal into the mounted hidden Meal editor is deferred to W4-A1 and is not an R4 acceptance blocker (weekly spec section 7). A read-only latency diagnosis found that `RequestFoodDraftSession` ownership may cause requester draft mutations to invalidate `ContentView`/`HomeExchangeView` behind the pushed requester form; this was not established as an R4 cause and was not fixed in R4 — it is routed to W4-A1's existing cross-screen tint/content-column stabilization work, not absorbed into R4. Release/Archive/TestFlight signing and any provider environment beyond the observed Screenshot Assistance run remain outside R4's boundary and are owned elsewhere.

### 14.8 Screenshot-assisted menu path, checkout/review input, and path-conflict assistance (W4-R4.1)

R4.1 extends Requester Screenshot Assistance so independent on-device evidence can propose the menu path (`MEAL_EXCHANGE` or `DINING_DOLLARS`) and switch the form's selector. Faith accepted W4-R4.1 on 2026-10-07 (weekly spec). It narrowly supersedes: the two-category eligibility and the checkout/review exclusion in section 12; R4's requester-only `menuPath` and single shared Dining Dollars draft amount; the literal-`M`-only swipe-count rule; and section 14.5's top-up-only money authority. It retains S1's provider forbidden-field and independent-evidence rules, R2's draft/consent journey, R4's structured wire and other manual/provenance rules, and S3's shared runtime, consent, and qualification contract (section 15). Screenshot Assistance remains optional, proposal-only, and manual-first; it never auto-submits, and explicit `Post request` remains authoritative. W4-R4.2 (section 14.9) later narrowed when this section's path, location, and order-detail application may occur: nothing in this section is written to the draft until the requester venue disposition permits it, and a venue recovery always precedes the path-conflict and meal-swipe-mismatch assistance below.

**Provider authority.** `menuPath` and `diningDollarsOrderTotalCents` stay in the forbidden provider-field list; a provider that returns either is refused before schema parsing. The proposed path and Total are CommonPlate-validated proposals derived only from independent on-device evidence, evaluated identically by the backend (`src/screenshotEligibility.ts`, `src/screenshotProposalValidation.ts`) and on device (`RequesterOrderDeterministicEvidence`, `RequesterOrderOutputValidator`), pinned by `shared/screenshot-conformance-vectors.json`. The proposal response carries an optional `menuPath` and `diningDollarsOrderTotalCents`; the iOS decoder treats an absent or unrecognized value as no proposal.

**Checkout/review eligibility.** The third category is a Grubhub checkout/review screenshot with the explicit heading `Review your pickup order` or `Review your delivery order` (the complete supported set; generic `Review your order` is not supported) plus order-specific content: either a `Your order` section containing a quantity-prefixed item line, or a `Your payment` section containing a `Payment method` summary row. The existing legibility minimum and strict H5 are unchanged. `Place your ... order` call-to-action text, generic checkout words, item count, prices, totals, or a cropped summary do not qualify on their own. A quantity-prefixed item counts only inside `Your order`; that scan stops at the first later `Your payment` heading whether it is valid, duplicated, or malformed, and a duplicate heading never reopens it. Payment attribution ends when structure leaves the bounded `Your payment` section (`Order confirmation`, `Receipt`, another top-level section); a valid later `Payment method` row uniquely inside that same section remains attributable, no numeric line-distance cutoff is used, and ambiguous or duplicate/conflicting payment structure fails closed. Intermediate controls such as `Apply a promo code` do not by themselves end the section. In a multi-image selection only individually eligible images contribute pixels and evidence. Eligibility remains accident prevention, not proof of authenticity.

**Deterministic path evidence.** The path is resolved only from independent evidence of eligible screenshots, never provider output or plausibility.
- *Meal Exchange:* explicit `Meal Exchange` wording in a provider venue/menu identity (such as `Crave NYU - Meal Exchange`); bounded literal `1M`–`5M` order-level subtotal/total notation that resolves without conflict; or a canonical selected meal-based payment such as `Use 1 Meal + Dining Dollars`, whose embedded `Dining Dollars` words never open a Dining Dollars path and which supplies no swipe count or amount. `3M + $2.00` is Meal Exchange with a possible top-up only when the existing top-up corroboration succeeds. Meal Exchange wording alone supplies no count or amount.
- *Dining Dollars, review:* a supported review whose single `Payment method` row inside bounded `Your payment` is uniquely associated with canonical `Dining Dollars`. The association is valid when the tender is immediate or inline, or when at most one non-authoritative observation intervenes between the row and the tender (that observation supplies zero authority) with no structural departure, no second `Payment method` row, and no duplicate or conflicting recognized tender. Two or more intervening observations, fuzzy or substring matching, restaurant or logo recognition, and incidental or alternative `Dining Dollars` text grant nothing. A payment-method signal establishes path only, never an amount.
- *Dining Dollars, current cart:* a supported current cart with no Meal Exchange identity, no order-level `M` notation, no conflicting Meal Exchange evidence, and one unambiguous dollar-denominated order-level `Total`. All conditions are required; dollar signs, item prices, or venue-name guesses alone establish nothing.
- *No evidence or conflict:* a selected Dining Dollars method together with Meal Exchange evidence, conflicting evidence across the logical selection, or no accepted signal omits the path proposal and preserves the requester's selection; branch-dependent values whose meaning needs the disputed path are omitted. Unresolved or out-of-range `M` notation alone establishes no path or count. Real Grubhub screenshots are structural exemplars only; restaurant identity is never authority.

**Order-level Total and bounded device-derived geometry.** One clearly labeled, unambiguous dollar `Total` on a supported current cart/review may populate the requester-editable Dining-Dollars-only whole-order estimate within the existing 1–5,000-cent bounds; an out-of-bounds Total is omitted, never clamped. Item prices, a subtotal alongside a distinct Total, tax, fees, discounts, promos, crossed-out prices, arbitrary amounts, and unrelated tender values are never Total authority, and a Total is never chosen because it is largest, last, arithmetically compatible, nearest by index, or within N lines. Conflicting final amounts, split-payment ambiguity, an unidentifiable Total, or Meal Exchange/Dining Dollars conflict omit the path and/or amount. Existing text-only Total association remains authoritative where it succeeds; otherwise Swift may derive a minimal same-image relation from transient Vision geometry: the Total is authoritative only when exactly one authoritative exact `Total` label exists, exactly one amount-only candidate is on the same row (at least 50% vertical overlap of the shorter box) and to the right of it, geometry is valid, there is no competing association, and classification, cents, and observation ownership are consistent. Raw Vision boxes stay transient on device and are never transmitted, persisted, logged, or fixtured. Only privacy-safe derived relation evidence (`localTotalGeometry`: per-image observation IDs, `total-label`/`amount` classification, parsed cents, geometry-valid flag, and same-row/right-of relation facts) accompanies `localEvidenceText`; cross-image edges are forbidden. The backend validates it against the same image's text evidence and fails closed on missing, malformed, duplicate, contradictory, or cross-image claims. It cannot re-derive raw geometry, and this narrow trust supplies no authority outside Screenshot Assistance proposal generation. A path-only result on a checkout/review is a useful proposal without a fabricated amount or food.

**Path authority and application.** A valid deterministic path is applied before branch-dependent fields, then only the active branch's field rules run. The untouched initial/default path is not requester authority: default Meal Exchange plus deterministic Dining Dollars evidence auto-switches to Dining Dollars, and a same-value re-select of the default stays non-manual. Manual path authority begins only when the requester actually changes the selected path; the first actual change makes the new path requester-owned (`Manually selected`) and a later actual change moves that authority. A provider or store write never creates manual authority.

**Path-conflict assistance.** When a requester-owned path conflicts with the opposite deterministic path for the current analyzed result, the path is preserved and neutral assistance appears between the field label/provenance and the current selector: `We found Dining Dollars` or `We found Meal Exchange`, with a compact filled `Switch` action and a distinct `×` dismiss control (44×44 hit target). The current path keeps `Manually selected` while the conflict is pending.
- `Switch` is explicit requester acceptance of only the proposed path: switch to it, remove the row, clear the superseded manual-path provenance, and apply valid path-specific screenshot values, shown as `Suggested`. It never auto-submits.
- `×` preserves the requester-owned path and its provenance, removes the row, and rejects the opposite-path recommendation for this analyzed result only; the same result never later silently switches the path, while a genuinely fresh or reanalyzed result may propose it again.
- Dismissal rejects the path recommendation, not all assistance: independently valid path-independent evidence (such as dining location or general order details) may remain. Rejected path-specific evidence is never reinterpreted for the retained path: a Dining Dollars Total never becomes Meal Exchange evidence, Dining-Dollars-only evidence never invents a swipe count or Meal 1 structure, and Meal-Exchange-only evidence never becomes a Dining Dollars amount.
- The row is neutral assistance (not warning, error, or destructive), uses existing semantic tokens, reflows with Dynamic Type, and adds no modal, toast, lock, or other copy. Stale or cancelled results never resurface a row.

**Branch state and amounts.** The draft keeps two in-memory amount values — the optional Meal Exchange top-up (1–2,500 cents) and the required Dining-Dollars-only whole-order amount (1–5,000 cents) — and the wire field `estimatedDiningDollarsCents` is derived only from the active branch. Switching, by requester or Screenshot Assistance, preserves the inactive amount and never copies, reinterprets, truncates, validates, or submits it. A current-cart top-up proposal fills only the Meal Exchange value; a labeled Total fills only the Dining-Dollars-only value. Shared dining location and timing stay shared; Meal Exchange keeps its bounded swipes and per-swipe Meal entries; Dining-Dollars-only keeps its own order-details text with zero submitted swipes and no Meal items; switching never clears inactive branch data, clears branch-specific visible validation and stale focus, and a newly active branch must satisfy its own validation before Post enables. Frozen D2 payload restoration reconstructs only the submitted branch.

**Meal-swipe count.** Literal `M` notation remains authoritative, and a returned count survives only when on-device evidence establishes it. When literal `M` notation is absent, the path resolves to Meal Exchange without conflict, and the validated top-level item list is not withheld by the overlap rule, a count `N` (2 ≤ N ≤ 5; `N = 1` is not proposed) is inferred only if every counted entry has quantity exactly 1, is independently grounded as a top-level OCR line in at least one eligible screenshot (modifier and bullet lines never ground an entry; one ungrounded entry disengages the whole inference), and no two counted entries share a normalized top-level name across multiple screenshots. Modifiers, add-ons, and extras never inflate the count, a count is never inferred from an arbitrary item count or from provider output alone, present-but-unresolved notation is never repaired, and the inference never feeds path resolution or unlocks a top-up estimate.

**Requester-owned meal-swipe mismatch.** When the requester owns `mealSwipes = M` and a successful eligible analysis deterministically establishes valid `N > M`, M is preserved and assistance appears above the swipe control (hierarchy: `Number of meal swipes` label with `Manually selected`, then the row, then the control): `We found N meals`, a filled `Use N swipes` action, and a distinct `×` (44×44). It is not shown for `N == M` or `N < M`. `Use N swipes` adopts N and the result's screenshot-derived higher-index Meal content, removes the row and `Manually selected`, shows `Suggested`, and never auto-submits. `×` keeps M and `Manually selected`, removes the row, and rejects only this result's surplus screenshot-derived Meal content above M; a later manual increase does not resurrect it, requester-owned content is never erased, and a genuinely new analysis may propose again. When assistance was previously accepted at a larger count and the requester later decreases the count, the lower count wins, the higher-index accepted content stays preserved in the draft and may be restored by increasing the count, inactive meals stay excluded from submission, and no warning is shown.

**Provenance.** Affected requester runtime surfaces use `Suggested` for an editable value proposed by Screenshot Assistance and `Manually selected` for an explicit requester-owned value or path; a later requester edit restores requester authority and removes screenshot provenance under the existing per-field rules. This terminology does not change any Helper surface.

**Privacy and trust.** Raw OCR, raw geometry, screenshots, and screenshot-derived diagnostics are never logged, persisted, or fixtured. Synthetic structural vectors stand in for real screenshots, and provider/model evaluation is not R4.1 proof.

### 14.9 Requester venue anchoring and recovery (W4-R4.2)

Faith accepted W4-R4.2 on 2026-10-18. R4.2 adds a deterministic, on-device venue disposition and one application gate around the existing Requester Screenshot Assistance flow. It adds no wire field, route, validator output, provider field, OCR pass, network call, telemetry, or persisted state, and changes no existing conformance vector. It narrowly supersedes section 12's resolve-one-or-omit behavior (a resolved or omitted location with every other field still applied) and section 14.8's unconditional application of path, items, swipes, and amounts. It retains S1's allowlist and independence rules, R4's manual authority and provenance, R4.1's path and mismatch assistance, and S3's runtime, consent, and qualification. Screenshot Assistance remains optional, proposal-only, and manual-first; nothing auto-submits.

**Disposition.** Each selection has exactly one venue disposition: `supported(venue)` (E, or D when it conflicts with a requester-owned location), `unresolved` (A), `unsupported` (B), or `conflicting` (C). It is requester-local presentation and application state: not a wire field, not persisted, never logged, and derived only from the on-device OCR text of the eligible images. Provider output, including `visibleVenueText`, never gains venue authority.

**Evidence and classification.** The only venue observation is a Meal Exchange identity line (`<venue> - Meal Exchange`, or a line ending ` - meal` followed by the exact line `exchange`) in an eligible image; a bare `Meal Exchange` line supplies no venue. Cart venue lines, headings, truncated text, brand or banner lines, and catalog-name mentions are not observations, so an image without such a line is unknown and an unsupported cart without one is A, never B. An image whose lines name more than one distinct venue key, or whose venue text is truncated (`...`/`…`), has fewer than three ASCII letters, or yields an empty key, is indeterminate. A single observation is classified with the unchanged catalog matcher (`matchesVendorText`/`groundedVendorMatches`): exactly one catalog entry is supported; two or more (for example the shared `Upstein` base) is indeterminate; zero entries applies a downgrade-only near-miss rule over ASCII letters and digits (equal keys, containment with the shorter key at least four characters, or Levenshtein distance at most two with the shorter key at least six, against the entry's full-name or base-label key): near is indeterminate, otherwise unsupported. The near-miss rule can only turn a potential B into A; it never populates a location or selects a catalog entry. A near-miss supported venue (for example OCR spacing such as `Dunkin'at U-Hall`) therefore stays unresolved (A), exactly as it was unresolved before R4.2.

**Selection classification.** C when two or more reliable (supported or unsupported) observations denote different venues: two supported entries with different names, one supported and one unsupported, or two unsupported whose keys are not mutually near. B when not C, at least one observation is unsupported, all unsupported observations are mutually near, the selection has no supported and no indeterminate observation, and the catalog matcher over the joined evidence text names no catalog entry. C takes precedence over B, and B/C over every other disposition even when the catalog matcher resolved one name from the joined text. Otherwise the disposition is E, D, or A: with no Meal Exchange identity observation in any eligible image, supported catalog recognition stands (E, or D against a differing requester-owned location, including Dining Dollars with no Meal Exchange header); with such an observation and any indeterminate observation the disposition is A whatever `selectedDiningSpot` holds and whether or not a manual location exists; with reliably supported identity evidence E/D is anchored on that venue and `selectedDiningSpot` must name the same entry, otherwise the result is A.

**Single application gate.** After a validated outcome exists (local or external, validated on device as before):
- **B or C:** the entire proposal is withheld; the draft, manual entries, and protected input are untouched; the B/C recovery is presented.
- **E:** unchanged accepted behavior, including R4.1 path, Total, swipes, items, provenance, and mismatch rows.
- **D:** a supported venue conflicts with a requester-owned location. The entire proposal is withheld, the manual location and all protected input are preserved, and recovery D is presented.
- **A:** no `selectedDiningSpot` but the proposal has an order-detail field (non-empty `mealItems`, `mealSwipes`, `estimatedDiningDollarsCents`, or `diningDollarsOrderTotalCents`). The entire proposal is withheld, the manual location is preserved, and recovery A is presented.
- **Unanchored empty or path-only result:** nothing is applied and the existing `noUsefulExtraction` treatment applies, with no new copy; the existing `✓ Screenshot checked` / `Change` row is shown and no notice is rendered. Faith accepted this existing presentation.
- **Ineligible:** the existing `unsupportedScreenshot` treatment, unchanged.

No screenshot-derived field is written to the draft except through E, an explicit D `Use … & autofill`, or an explicit A `Autofill order details`; a confirmed withheld outcome is applied through the existing `apply` rules unchanged (field-level manual precedence, R4.1 path rules, path-conflict and swipe-mismatch rows, `Suggested` provenance). Venue recovery is presented first; path-conflict and meal-swipe-mismatch assistance appears only after a confirmed application, never alongside or before a venue recovery.

**Pre-transfer stop.** The classification is computed once from the evaluation's derived evidence in the Requester adapter and consuming store. At the external-fallback decision, after the unchanged local attempt and before participant authority is read or any transfer permission is minted, a B or C classification returns the recovery result and never calls `authorizeExternalTransfer` or `runExternal`; no external request is made. The stop only withholds an otherwise permitted transfer: S3 consent, single-use permission minting and binding, qualification, the empty production registry, attempt fencing, the local-attempt deadline, and fail-closed behavior are unchanged, and the local attempt is neither skipped nor altered. Whatever the local attempt returns is subject to the same gate, so a B/C selection never applies fields. A, D, and E never stop a transfer; uncertainty is never treated as confirmed unsupported evidence.

**Recovery presentation.** The callout reuses the Screenshot Assistance entry and status component; R4.2 adds no status variant and no status copy. Approved copy (Figma `1110:7268`):
- **A:** `We found order details, but couldn't identify the dining location.` The callout hosts the existing Dining location picker (`Choose dining location`); primary `Autofill order details` (disabled until a location is selected, enabled immediately when a manual location already exists); secondary `Continue manually`. A's heading appears only when a usable order-detail field exists.
- **B:** `Restaurant not found on CommonPlate`; primary `Try other screenshots`; secondary `Continue manually`.
- **C:** `Screenshots show different restaurants`; the same two actions.
- **D:** `Which dining location should we use?` / `Your screenshots show <screenshot venue>, but you selected <manual venue>.`; primary `Use <screenshot venue> & autofill`; secondary `Keep <manual venue> & enter manually`.

Layout (Faith-approved final Figma-aligned styling, 2026-10-18; supersedes an interim side-by-side ordinary-size treatment): the two actions are stacked full-width in order at every text size, at least 46 pt tall (wrapping on word boundaries for long venue names and large Dynamic Type), 14 pt rounded rectangles with an 8 pt gap (10 pt above A's actions); the primary is filled with the accent color (grey with muted text when disabled) and the secondary is canvas-filled with a 1 pt border and accent text; the heading is 15 pt semibold and D's body is 13 pt secondary text. The callout uses existing semantic tokens with no modal, toast, lock, or new motion, and long venue names wrap. Selecting a venue in A's picker is a real requester interaction and never autofills by itself. `Continue manually` and `Keep … & enter manually` dismiss the callout, apply nothing, and leave every manual entry and the location unchanged. `Use … & autofill` replaces the requester-owned location by explicit choice: the location becomes screenshot-derived (`Suggested`) and its manual flag clears. `Manually selected` appears on the dining location only while a venue recovery for the current result is pending or has been resolved by `Keep … & enter manually`.

**Status truthfulness.** A completed A or D analysis (a validated eligible outcome held pending the requester's decision) shows the existing `✓ Screenshot checked` / `Change` row and establishes completed-run state at completion, as for any eligible outcome; no afterglow occurs until fields are written. The withheld result records at completion whether it was a genuine rerun. On explicit confirmation, `Screenshot checked. Your existing entries were kept.` appears only if that recorded flag is true and the confirmed application actually preserved requester-owned content; the confirmation is never a second completed run. Dismissal shows no feedback and leaves the checked row and completed-run state as they are. B/C is not a successful assistance outcome: no analysis completed on the stop path, so it sets no checked row, completed-run state, feedback, afterglow, or `unavailable` notice, and the non-checked entry row is shown. Classification is path-independent: B/C behaves identically whether or not a local provider returned fields.

**Retry, cancellation, and fencing.** `Try other screenshots` opens the existing Photos picker directly (no Screenshot Help, no disclosure) only while Screenshot Assistance is On and no analysis is in flight. Cancelling the picker is an empty selection and starts nothing: the callout, draft, and manual entries are unchanged. A non-empty new selection follows the existing selection-begin path: it mints a new token, clears only still-screenshot-owned fields, and retires the pending recovery and any withheld outcome. Recovery state is result-scoped to its analysis token, in memory only, and retired on a new selection, view disappearance, Screenshot Assistance turned Off, and terminal-recovery reset; a stale token never surfaces, confirms, or applies a withheld outcome.

**Parity, vectors, and fingerprint.** The pure classifier exists twice: Swift in `Services/ScreenshotAssistance/Requester/RequesterVenueClassifier.swift` and TypeScript in `src/screenshotVenueClassifier.ts`. The TypeScript twin has no route runtime effect; it exists for conformance and so the S2.1 follow-on harness binds to a production primitive. `matchesVendorText` and `groundedVendorMatches` are exported from `src/screenshotProposalValidation.ts` with no behavior change. Synthetic versioned vectors live in `shared/screenshot-venue-vectors.json` (`version: 1`), consumed by both suites; `shared/screenshot-conformance-vectors.json` is unchanged and its `version` assertions stay `1`, so validator output is unchanged. The build-derived qualification fingerprint changed by design, because the classifier lives under the hashed directory: `3e8e351fb2fbee625a67bed9864030e34c15f004d5076c8d803b0137ca4fcb4e`, derived identically for the Debug simulator, Release simulator, Release device, and Debug device builds and the test build. The production registry has zero entries, so no production qualification was invalidated; S2.1's recorded development fingerprints are historical evidence about the pre-R4.2 build and are not rewritten.

**Privacy and verification boundary.** Raw OCR, venue text, screenshots, and classifications are never logged, persisted, fixtured from real captures, or sent to analytics. B/C proof uses synthetic evidence only. R4.2 acceptance is not evidence of provider or model quality, real unsupported-venue accuracy, Release/TestFlight signing or endpoint behavior, or the post-R4.2 selection-level evaluation; the physical, Simulator, and accessibility coverage and its gaps are recorded in `docs/testing.md`.

## 15. Shared Screenshot Assistance runtime and local-first routing (W4-S3)

The requester workflow is excluded from the V1.0 public build (W5-IOS1, section 26); this runtime is preserved and exercised in tests with the gate injected enabled.

S3 replaces the requester-shaped Screenshot Assistance implementation with one shared, schema-neutral runtime plus workflow-specific adapters. Requester behavior in sections 12–14 is Requester workflow policy; it is not generalized to any future workflow, and S3 settles no Helper Screenshot Assistance policy (W4-H1 owns that).

**Shared runtime and adapters.** `ScreenshotAssistanceRuntime<Workflow: ScreenshotWorkflow>` owns provider routing, local capability/qualification enforcement, the attempt fence, the local-attempt deadline, and enforcement that no external transfer begins without a current, exactly bound, single-use runtime transfer permission, which exists only while valid Screenshot Assistance consent and the current attempt both hold (below). Its one input is the complete ORDERED screenshot selection (`ScreenshotSelection`, pixels); that ordered selection, not per-image calls, is the logical input. Preprocessing, Vision OCR, and other evidence derivation are private to the workflow/provider adapters and are not part of the shared contract. Eligibility, derived evidence, raw output shapes, validation, what an outcome may change, user-visible copy, and when an external attempt is offered belong to the workflow adapter and its consuming store. The Requester adapter (`RequesterOrderWorkflow`) and its providers live under `Services/ScreenshotAssistance/Requester/`. A test-only, non-shipping second-schema workflow proves the runtime is not requester-shaped; it creates no production qualification and is not reachable in production. `shared/screenshot-conformance-vectors.json` is a drift guard that the backend (`src/screenshotConformanceVectors.test.ts`) and the on-device validator (`ScreenshotConformanceVectorTests`) must both satisfy, so the fail-closed eligibility and validation rules cannot diverge; a vector changes only by deliberate edit reviewed against both suites.

**Local providers are qualification-gated and fail closed.** A local provider may run only for an exact qualification entry binding workflow (schema id, schema version, validator version), provider (id, prompt/model/provider-strategy version, shipping distribution), evidence/input strategy (`ocrFlattenedText`, `ocrLayoutAware`, `directImageMultimodal`), an explicit OS major.minor band, device model set, and a build-derived implementation fingerprint. Unknown or later OS bands, unknown devices, a changed fingerprint, and any unqualified combination behave as local-not-qualified. The production registry (`ScreenshotQualificationRegistry.production`, `Services/ScreenshotQualificationProduction.swift`) currently contains ZERO entries. Device/model availability, including Apple Intelligence or Foundation Models being available, never authorizes invocation: qualification is decided before a provider is asked anything, so an unqualified provider is not even asked for availability, and Foundation Models is not invoked without a matching entry. The Apple OCR→flattened-text Requester candidate remains NOT QUALIFIED; evaluation, qualification, and production enablement are W4-S2's. A non-shipping provider can be admitted only by an injected test registry, and nothing in the app target may construct one.

**Local failure never authorizes transfer; bounded local attempts.** Local unavailability, non-qualification, failure, timeout, or invalid output never authorizes external transfer by itself and leaves manual entry available. One local attempt has a finite deadline (20 seconds, engineering-owned, not derived from physical-device measurement; no production combination reaches it today). The orchestration returns control at the deadline, on provider completion, or on cancellation — whichever settles first, exactly once — without waiting for a non-cooperative provider; a late completion is stale and has no state effect. The abandoned provider computation is not terminated, and a provider that synchronously blocks the main actor cannot be pre-empted.

**Screenshot Assistance consent authority (Requester).** Screenshot Assistance has one app-level On/Off authority, surfaced in the H2 `SettingsView` route and in the Request Food Off-state row. There is no separate Requester/Helper toggle and no separate stored "enabled" state apart from consent: On exists only while a valid consent record exists, and Off holds none.

- **Off** means no local Screenshot Assistance AI processing, no external Screenshot Assistance AI processing, and no new external screenshot transfer. Manual Request Food flows remain fully available. `analyzeScreenshot` refuses while Off.
- **Off → On requires the disclosure first.** Attempting to turn Screenshot Assistance On — from Settings or from the Request Food Off-state row — presents a centered modal before enablement: title `Turn on Screenshot Assistance?`; body `Screenshot Assistance can help fill in details from screenshots you add to CommonPlate. Some screenshots may be sent to OpenAI to generate these suggestions.`; recovery line `You can turn Screenshot Assistance off anytime in Settings.`; actions `Turn On` and `Not Now`. The copy carries no on-device, model-routing, qualification, or fallback-architecture language, and mentions no OCR text, because the actual external transfer is the selected screenshot images only (on-device OCR evidence goes only to CommonPlate's own backend, section 12).
- **`Turn On`** enables Screenshot Assistance and establishes the valid external-transfer consent. From the Request Food row it then continues into the Help/picker step; from Settings it only enables. **`Not Now`** leaves Screenshot Assistance Off, establishes no consent, and persists nothing.
- **Standing consent.** While valid consent remains active, no per-attempt external-AI permission popup or other repeated prompt appears; qualified local processing (when one exists) and the accepted OpenAI fallback may both proceed under the standing consent.
- **On → Off** revokes the consent, blocks all future local and external Screenshot Assistance processing and any future external transfer, retires the current selection generation and fences any in-flight local or external attempt (a transfer already in flight cannot be recalled, but its result is never applied), and prevents stale results from applying. Turning Screenshot Assistance On again never revives a prior generation or inherits the revoked consent: it requires the disclosure and a fresh `Turn On`.
- **Consent binding.** The consent record is bound to exactly the Screenshot Assistance purpose, OpenAI as provider, and the selected screenshot images as the transferred data class. It is honored only while it equals the current binding; a materially different provider, purpose, or materially broader transferred-data contract cannot silently inherit it and requires a truthful new disclosure first.
- **Fail closed.** An absent, unreadable/corrupt, or mismatched consent record is Off. Legacy or default preference state — the pre-revision `isAIAssistanceEnabled` value, whether explicitly set or defaulted On, and the pre-S3 `thirdPartyConsentRecorded` value — is never read as consent and never creates it. No migration screen, notice, or legacy-compatibility path exists.

**External fallback under standing consent (Requester).** When an attempt is otherwise eligible, no qualified local provider produced the outcome (the production registry is empty today), and current participant authority exists, the store runs the one terminal external attempt automatically under the standing consent: no popup, no tap, and nothing but the selected screenshot images (plus the existing S1 local-evidence payload to CommonPlate's own route, section 12) is sent. Local unavailability, non-qualification, or failure alone never authorizes transfer; without standing consent no transfer occurs. The runtime still requires a current, exactly bound, single-use transfer permission minted for the exact attempt token and exact evaluation of that attempt, carried by a shared single-use flag (copies cannot mint a second transfer), consumed at the first validity check, and failing closed on any mismatch (another attempt, fence, runtime, or retired generation). That permission is an internal fencing guard, not a user decision; it is minted only while the attempt is current and Screenshot Assistance is On. A new or replaced selection, Screenshot Assistance turned Off, view departure or retirement, cancellation, loss of participant authority, a stale or superseded attempt, or an already consumed permission retires the pending attempt, and no later unauthorized transfer or result application can occur. Current participant authority is evaluated at the fallback decision and re-read inside the runtime synchronously immediately before the provider is invoked; if it is gone, there is no provider call and the permission is spent, and the ordinary local-outcome treatment is presented. If authority is lost while an admitted form remains mounted, local Screenshot Assistance may still run under normal qualification, external AI is not attempted, no Screenshot Assistance-owned verification prompt appears, and manual entry remains available. Defense-in-depth backend participant authorization on `POST /api/request/screenshot-proposal` is unchanged (section 12). The consent-authority revision made no backend route or contract change.

**Local privacy boundary and evidence.** Content-bearing artifacts used for local analysis — screenshots, normalized images, OCR text, prompts, proposal fields, and local-model inputs/outputs — do not leave the device by any route, are not persisted, and are never emitted to any analytics or observability service. Only an authorized external attempt sends the selected screenshots (and the existing S1 local-evidence payload, section 12) to the existing provider route. Optional evidence/provenance (`ScreenshotEvidenceSet`: per field key, one or more entries of screenshot index, exact source text, optional normalized region) is in-memory and attempt-scoped, returned beside a validated outcome, released with the attempt, not `Codable`, and unused by the Requester store and view; S3 introduces no user-visible evidence presentation.

**No shipping observability dependency.** The iOS app has no Datadog or other third-party observability package, SDK initialization, or Screenshot Assistance telemetry. The external-transfer boundary (no request after cancellation, retirement, a stale or replayed permission, or loss of participant authority; exactly one request for a valid authorized attempt) is enforced by the runtime and the networking layer themselves and is proved by transport request counts and store state. The W4-OBS1 observability slice was retired and is not part of the accepted runtime.

**Unchanged by S3.** Requester eligibility semantics, multi-screenshot/overlap behavior, manual precedence, deterministic validation, no auto-submit, stale-result fencing, and failure behavior are as in sections 12–14 except for the S3 consent/ordering/Settings supersession recorded above. W4-R4.2 (section 14.9) adds a Requester-store pre-transfer stop at the external-fallback decision for a reliably unsupported or different-venue selection; it does not alter S3 consent, routing, qualification, fencing, the deadline, or transfer-permission behavior. The consent-authority revision also leaves unchanged local-first routing, empty-registry/qualification fail-closed behavior, the local-attempt deadline, the qualification fingerprint, requester manual authority, and the absence of auto-submit.

**Verification limits.** Faith's physical-iPhone walkthrough of the revised consent flow confirmed: the disclosure appears before enablement on an Off → enable attempt; `Not Now` leaves Screenshot Assistance Off; `Turn On` enables it; On → Off disables and revokes; and a later enable attempt shows the disclosure again. Manual Request Food remained available while Off. Source and unit tests prove consent, authority, fencing, and wiring but do not themselves prove SwiftUI presentation. A brief perceptible delay between tapping the enable control and the disclosure appearing was observed on device; consent sequencing was correct and nothing became enabled before the disclosure, so it is a presentation-responsiveness item routed to the weekly spec's Candidate Stabilization deferral, not an accepted-behavior defect. The earlier S3 physical-iPhone smoke (iPhone 16 Pro, iOS 26.3.1, Apple Intelligence On, Debug build against a temporary development LAN backend) observed the real `PhotosPicker` and preprocessing path, the empty-registry fallback path, and retirement without late application under the pre-revision consent model; it is retained only as evidence of the picker, preprocessing, and retirement boundaries, not of the consent behavior. Neither walkthrough establishes Apple local-model quality or qualification, Release/TestFlight signing or endpoint behavior, or production provider reachability (`docs/testing.md`; section 11).

## 16. GoodGrub public information pages (W4-T1)

`GET /guidelines` and `GET /support` are implemented in `src/publicInfoPages.ts` and registered from `app.ts` with one import and one `registerPublicInfoRoutes(app)` call. They are the GoodGrub Community Guidelines and GoodGrub Support pages, and they are local accepted behavior only: this section does not claim that they are deployed or publicly reachable.

**Static and read-only.** Each page is fixed HTML rendered once at module load. It needs no authentication, no database access, no cookies, no client-side JavaScript, and no request-specific data: no query, header, or body value reaches the page. It is not coupled to `PUBLIC_ACTIONS_PAUSED` or to a rate limiter. Only `GET` (and the `HEAD` Express derives from it) is served; other methods are not handled by these routes.

**Content.** The wording is the Faith-approved copy, unchanged, in the approved section order. Page titles are `Community Guidelines — GoodGrub` and `Support — GoodGrub`. The only contact is `goodgrubsupport@gmail.com`, a `mailto:goodgrubsupport@gmail.com` link. Links are relative only (`/guidelines`, `/support`, the in-page skip link, and the mailto); the pages embed no hostname and link to no Privacy Policy. The pages carry the terracotta `#AD563D` web accent with light and dark schemes, a skip link, a labelled navigation with `aria-current`, one `h1`, `<main>`, and a visible keyboard focus style.

**Headers.** Both routes reuse `publicPageSecurityHeaders` from `src/publicPage.ts` (`Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and the shared Content-Security-Policy with `default-src 'none'` and `script-src 'none'`), then a route-specific step replaces its `Cache-Control: no-store` with `Cache-Control: public, max-age=300`. The override is local to these two routes: the shared helper is unmodified, and every emailed-link response (sections 9.5 and 9.7) keeps `no-store` and its `— CommonPlate` title convention. All other routes, including the legacy website and API, are unchanged.

**Not implemented here.** No `/privacy` route, file, or link exists. The pages assert nothing beyond the approved copy about moderation, reporting, account deletion, or retention; whether that copy matches final accepted behavior is a release dependency, not something this section establishes. Hostname, canonical URL, hosting, and publication are undecided and out of scope. Verification evidence and limits are in `docs/testing.md`.

## 17. Requester request management: owner reads, Edit, Withdraw, and Active Requests retirement (W4-R5)

Faith accepted W4-R5 on 2026-10-19, with the verification limitations recorded in `docs/testing.md`. R5 lets a verified requester read, Edit, and Withdraw their own ongoing requests, makes the two ordinary request reads verified-only, adds a notification-generation fence to every helper new-request dispatcher, and retires the legacy Active Requests destination. It narrowly supersedes the statements in sections 1.3, 5.1, 5.3, 6.2, and 8.3 that described anonymous request reads, `.activeRequests` callers, or a return to the active-requests list; those sections carry pointers here. Edit and Withdraw are not on the `PUBLIC_ACTIONS_PAUSED` list (section 10) and have no feature flag; the alert delivery an explicit rescheduling can eventually cause stays governed by the dispatchers' own pause guards. Neither mutation consumes or refunds a daily slot, touches D2's `RequestOperation` ledger, or sends a requester or helper email or push.

**Verified-only ordinary reads.** `GET /api/requests` and `GET /api/request/:id` resolve participant authority through the shared gate before id validation, any database lookup, the pair fence, and the visibility check; there is no anonymous or unresolved fallback. A missing, malformed, independently revoked, or unverifiable credential is refused with the shared structured participant-authority error and no request content, identically whether or not the id exists, is fenced, or is not yet visible. `Cache-Control: private, no-store` and `Vary` on the participant-authority header are set inside the gate ahead of any response. One resolution serves the W4-U1.3 pair fence, the W3-H2 participation filter, and caller-relative `isOwnRequest`. A credential that is merely the original credential of an installation whose Change Email completed is not rejected for that reason (`R5-IR-2`). Release sequencing of this gate with W4-B1 is owned by planning, not by this contract. The iOS service boundary sends neither read without participant authority (`participantAuthorityRequired`, nothing sent).

**Owner reads.** `GET /api/participant/requests` returns `{ requests }`, the verified participant's ongoing requests oldest first, bounded at 25; an empty list is an authoritative empty answer. `GET /api/participant/request/:id` returns `{ request }` for one. Both are resolved from the persisted `requesterParticipantId`, never an installation, push token, raw email, or cached id, are `private, no-store` with `Vary` set ahead of the per-IP limiter (30), and return a narrow allowlisted DTO: the public request fields plus `timing` (`asap` or `scheduled`), `phase` (`scheduled`, `available`, or `reserved`, derived from stored state and the backend clock and never written back), `contentRevision` (null only for a legacy row), `canEdit`, `canWithdraw`, and `latestScheduledStart`. A request is ongoing only while `open` or `claimed`, unexpired; `reserved` covers a live reservation and the post-Yes external-order authority and reveals nothing about who. The DTO carries no helper identity, claim material, moderation state, or other participant data. A nonexistent id, a malformed id, and another participant's request are one indistinguishable `404 REQUEST_NOT_FOUND`. For the owner's own request that is no longer ongoing, the detail read answers its terminal state: `410 REQUEST_WITHDRAWN`, `409 REQUEST_ALREADY_PLACED`, or `410 REQUEST_EXPIRED`. `canEdit` and `canWithdraw` are the backend's reading at read time and are false while reserved; `canEdit` is also false for a legacy row with no revision. The mutation re-checks atomically, so a stale `true` can only earn a definitive refusal. Owner reads are not paused by `PUBLIC_ACTIONS_PAUSED`, apply no pair fence (they are keyed on the caller's own binding), and return no placed-order continuation (served by the separate W4-R3 routes, section 22).

**Public detail and claim after withdrawal or expiry.** `GET /api/request/:id` answers a withdrawn request with a contentless `410 REQUEST_WITHDRAWN` (`"This request is no longer available."`), ordered after the pair fence and before the not-yet-available gate so a rescheduled-then-withdrawn request is never told to come back later. It answers an `open` or lapsed-claim request whose window has ended with `410 REQUEST_EXPIRED` and the same sentence, so a notification tap reads current truth; a live reservation and a placement keep their prior answers. Previously these were `200` with a status. The claim route answers a withdrawn request with `410 REQUEST_WITHDRAWN` (same sentence). Only the detail read projects `contentRevision` (so a tapped notification can say the request changed since it was sent); the list, create response, and claim response keep their accepted shapes.

**Edit.** `POST /api/request/:id/edit` is an owner-authorized atomic conditional update, together with its ledger row, in one transaction. The strict payload carries `vendor`, the same structured fields as create (`menuPath`, `mealSwipes`, `mealItems`, `orderDetails`, `estimatedDiningDollarsCents`) validated by the shared structured refinement, `timing` (`unchanged`, `asap`, or `scheduled`), `windowStart` (only with `scheduled`), and `expectedContentRevision`; it refuses `email`, credentials, a flat `food`, and any window end. `food` is re-derived from the structured fields; user text is stored literally (a leading `$` is text); an optional field the payload no longer carries is removed. The update matches only an owned request that is unexpired, not placed or withdrawn, not holding a live reservation or post-Yes authority (a lapsed reservation is eligible, as in effective availability), and still at `expectedContentRevision`; `contentRevision` advances by one. A stale revision is `409 REQUEST_REVISION_CONFLICT`; a legacy row with no revision is `409 REQUEST_NOT_EDITABLE` and is never given a guessed revision. Refusals are classified from current state in the order placed (`409 REQUEST_ALREADY_PLACED`), withdrawn (`410 REQUEST_WITHDRAWN`), expired (`410 REQUEST_EXPIRED`), reserved (`409 REQUEST_RESERVED`), then revision, so a claim, placement, withdrawal, expiry, or second edit racing an Edit has exactly one backend-authoritative winner and an edit that loses to a reservation writes nothing. Validation follows the owner lookup, so payload validity probes nothing about another participant's request. The vendor must be in the supported catalog only if it changed (`400 INVALID_VENDOR`); an unchanged vendor is preserved even if it has since left the catalog. Requester-authored text passes the same U1.1 filter as create before any write (`422 REQUEST_TEXT_NOT_ALLOWED`, nothing written). The response is `{ outcome: "edited", resultingRevision, request }`, with `request` null if the request is no longer ongoing.

**Timing and the original-creation-day horizon.** `unchanged` leaves the availability window exactly as stored and is never held to the horizon, so ordinary meal-detail edits never reset the window. `asap` and `scheduled` are explicit changes that recalculate the three-hour window (ASAP from the backend's now; Later from the chosen start; `pickupWindowText`, `visibleFrom`, `expiresAt`, and `deleteAt` follow, and `windowStart`/`windowEnd` are set for Later and cleared for ASAP). A scheduled start already in the past is `400 INVALID_REQUEST`. Every explicit timing change, including one to ASAP (D-R5-3), must begin by 11:30 PM `America/New_York` on the campus day the request was originally created (`latestEditableScheduledStart`, derived from the immutable `createdAt`, so editing never rolls it forward and a 23- or 25-hour DST day still lands on 11:30 PM wall clock); a later start is `422 REQUEST_HORIZON_EXCEEDED`, so ASAP after the creation day keeps being refused while unchanged timing stays valid. An explicit rescheduling also sets `helperNotification` to `awaiting-eligibility` and advances `notificationGeneration`.

**Withdraw.** `POST /api/request/:id/withdraw` is an owner-authorized atomic conditional update under the same eligibility clause (without the revision check): status becomes `withdrawn`, `withdrawnAt` is set, `notificationGeneration` advances, and `deleteAt` is raised (`$max`) to the end of the original creation campus day, in one transaction with the ledger row. Withdraw is terminal for the request and does not refund quota: the row still counts toward that day's limit (section 7). It loses to a live reservation (`409 REQUEST_RESERVED`) and to placement, and a Withdraw does not need a revision, so a legacy row can be withdrawn. The response is `{ outcome: "withdrawn", requestId }`. A withdrawn request is gone from the public list, claim, and detail.

**Operation ledger and exact replay.** Edit and Withdraw each require a valid operation identity header and pass the existing operation-authority check (`400 INVALID_OPERATION_ID`; mismatched or unavailable authority refuses before any lookup). `RequestUpdateOperation` is its own collection and identity space, unique on `operationId`, holding the owner, request, kind, resulting revision, and (Edit) a SHA-256 digest of the canonical submitted edit; it holds no request content and is kept indefinitely. The row is written in the same transaction as the mutation, so "committed" and "recorded" cannot disagree. An exact replay by the same participant answers the decided outcome with no second effect (and is not re-evaluated for eligibility); another participant's identity is `403 OPERATION_UNAUTHORIZED`; an identity reused for a different request, a different kind, or different edit content is `409 OPERATION_CONFLICT`, never the earlier result; a replay whose request has since been removed is `410 OPERATION_EXPIRED`. Concurrent duplicates of one identity produce one effect (the loser's transaction rolls back on the duplicate key and answers the winner's decision). Any failure this module cannot classify is a plain `500 REQUEST_UPDATE_FAILED`, which a client must treat as ambiguous.

**Notification generation and the dispatcher fence.** Two counters are never conflated. `contentRevision` (written as 1 at creation, advanced by one per committed edit) is the edit compare-and-swap and the basis for a truthful updated-since-notification notice. `notificationGeneration` (written as 1 at creation, advanced only by an explicit rescheduling and by withdrawal) fences rescheduling-eligibility work and is never part of any delivery-deduplication key. Legacy rows carry neither; notification paths read an absent generation as the initial one. Every helper new-request dispatcher (the real-time email alert, the push dispatcher, and the eligibility sweep that starts them) is started for one generation and re-reads the request through one read-only guard at three points: before a delivery claim is written, after it is written, and immediately before provider handoff. The guard requires current effective availability and the same generation; the document it returns is the content sent, so an ordinary edit mid-dispatch is sent with its new text (the push payload is rebuilt when the revision changed). When it fails, nothing is handed to a provider: the just-written claim is released (for email only the placeholder no real send attempt touched), the dispatch stops with initiation left retryable, and the sweep records initiation conditionally on the generation, so a rescheduled request stays awaiting for the new generation. Delivery-dedupe identities do not change, so nobody already notified is alerted again, and an ordinary edit initiates no alert. A handoff already begun to a provider cannot be recalled. The helper push payload carries `contentRevision` when the request has one; it is opaque to the device, which compares it with the detail read's current revision on a tap.

**Unknown Edit/Withdraw outcome (D-R5-1).** Recovery is user-initiated replay of the same operation only; an unknown Edit or Withdraw is never retried automatically. Anything that leaves the outcome unknown (transport loss after the body may have been sent, a timeout, an undecodable answer, an unclassified 5xx, `REQUEST_UPDATE_FAILED`, `INTERNAL_FAILURE`, a cancellation after dispatch) is `ambiguousUpdateOutcome` and is never presented as edited, withdrawn, or unchanged; the UI states plainly that the outcome is unconfirmed. The operation identity, kind, request, and (Edit) exact payload are persisted durably before the POST is sent and survive relaunch, bound to the participant who started it; another participant never sees, replays, or adopts it, and an unreadable held value blocks new updates rather than reading as none. While a record is unresolved no new Edit or Withdraw starts and nothing is sent (`unresolvedUpdate`). `retryUnresolvedUpdate(matching:)` must name the original operation (identity, kind, request); a different action is refused without sending. On a replay only a ledger-decided refusal (or the request's own terminal code, or `OPERATION_EXPIRED`) settles the record; the rate limiter, the participant or operation-authority gate, or an unavailable verification keep it unresolved. Verified evidence that the request is no longer ongoing (an authoritative owner list without it, or a decoded withdrawn, expired, or placed answer) retires that request's record so nothing stays blocked with no screen left to resolve it; a failed owner list never does.

**Identity retirement (D-R5-2).** When participant identity A is retired, with or without a replacement, A's protected request data is removed from the visible UI: the board, the owner list, request-detail and own-requests navigation snapshots (`.requestDetail`, `.ownRequests`, `.ownerRequest`, `.editRequest`), and any one-time requester notice. If participant B later verifies, A's private request details and snapshots never reappear. Durable D2/H1a recovery, claims, reservations, pending create operations, and original participant bindings are untouched. A pending, cancelled, or failed Change Email and ordinary same-identity refresh failures change nothing (same-identity stale-healthy), and reverifying the same principal yields the same credential and is not a replacement. The board is retired in the same turn a different participant becomes current (`R5-IR-1`, which narrowly supersedes W4-H2's board preservation for that one case); the replacement then loads its own board, or the existing Exchange Unavailable state, never a fabricated Empty Exchange.

**iOS architecture boundary.** `APIClient → RequestService → RequestStore → SwiftUI` is preserved. `RequestStore` owns the owner collection (`ownerRequests`), bound to the participant authority it was read for exactly like the public board: a different participant becoming current retires it, and a read issued for a previous participant installs nothing. `ownerRequests` is authoritative-empty only once `hasLoadedOwnerRequests`; a failed read is unknown, never an empty list, and a previously loaded list stays after a same-participant refresh failure. A decided result mutates in-memory collections only if the participant who started the operation is still current. The durable unresolved-update record (`PendingRequestUpdateStorage`) is participant-bound and carries no credential or claim token. Read failures classify as authority required, authority invalid (the backend definitively rejected the credential), or unknown (a `503`, transport failure, timeout, or undecodable answer, which is never a revocation, withdrawal, or absence).

**Home, navigation, and Active Requests retirement.** `ActiveRequestsView` and `AppRoute.activeRequests` are deleted, replaced by `.ownerRequest` and `.editRequest` (carried by value; the owner detail re-reads current owner truth on appearance and never treats the snapshot as authority, and a provisional snapshot carries no revision and offers no Edit or Withdraw). Home is the only helper-request and requester-request surface: `Your request`/`Your requests` is built from the owner list once loaded (including scheduled and reserved requests the board does not carry; a just-created request fills a gap without duplicating), each card opens the owner detail, and `See all` cards do the same. Owner truth that cannot be established makes an otherwise resolved board Exchange Unavailable, never Empty Exchange. Every non-success end of the helper flow, every notification-tap outcome that is not a destination, and the reservation-warning tap return to Home; the foreground reservation-warning path now enters Helping in place above a Home-rooted stack, so Back returns Home and never exposes a legacy list (this closes the 2026-10-15 deferred defect). Claim-unavailable notices are delivered on Home in the store's FIFO order: safety reasons (claim expired, reservation ran out or no longer valid, already placed, request not found, already claimed) remain alerts and calm reasons (no longer available, not yet available, temporarily unavailable, withdrawn, expired) are banners. A verified own withdrawal or expiry earns a one-time Home notice (`Request withdrawn`; `Your <vendor> request expired`), and a tap on a helper notification whose request the backend verifies as withdrawn or expired earns the same kind of notice; an available request whose current revision is newer than the one the notification carried opens with a small verified-update notice. None of these is produced from a payload or the device clock alone. The owner detail offers Edit and a stacked-confirmation Withdraw (`Withdraw this request?`, stating the request still counts toward today's limit), `Changes saved` once after a committed edit, a calm `Being helped` state with Edit and Withdraw withheld, and `Your request expired` for a verified expiry. Edit opens only on a confirmed owner snapshot, discards behind a `Discard changes?` confirmation, and each failure maps to exactly one approved sentence (conflict, reserved, text not allowed, past the horizon, definitive failure, and the unconfirmed outcome worded as neither success nor failure).

**Edit presentation and create parity.** Edit reuses the Request a Meal form rather than a parallel copy: the shared `RequesterMealSwipesMenu` (bounded 1–5 menu), the collapsed, expandable `RequesterMealEntryControl` with its bordered editor and `Done`, and the shared `RequesterTimingHeader` with its info glyph whose text is `RequestFoodView.timingInfoBody`, which now states the 11:30 PM same-day rule for both create and Edit. On Meal Exchange the optional Dining Dollars field sits above the meal-swipe count in both forms (a Dining Dollars-only form is unchanged). The Edit form is seeded only from the confirmed saved fields; screenshots and provenance are never restored. The past-horizon message is `It’s past 11:30 PM, so the time can’t be changed. Requests can’t run past the day they’re made.` (and `Start by 11:30 PM tonight. Requests can’t run past the day they’re made.` while the creation day is still today). A saved request carries only a vendor name, so `EditRequestPresentation.canonicalSpot` maps it to the catalog spot of the same name (an unlisted vendor is preserved as saved), which keeps same-venue comparison honest and avoids a false venue conflict.

**Screenshot Assistance on Edit (D-R5-4).** The optional Screenshot Assistance entry point appears in the Edit form and reuses the R4.2/S3 shared domain layer unchanged (`ScreenshotProposalStore`, venue recovery classification, manual-precedence application, the shared result-state structs, and the venue recovery callout), adding only Edit-form glue. Every non-empty value the form was prefilled with is requester-owned, so a screenshot fills only what is empty and a differing venue, menu path, or swipe count is offered through the same explicit recovery or suggestion affordances instead of replacing saved data. Screenshots and provenance are not persisted, and nothing is sent to CommonPlate's request routes by the assistance itself: saved content changes only through `Save Changes`. Sections 12–15 (consent, routing, transfer, fencing) apply unchanged.

**Dining Dollars presentation.** A Dining Dollars request with a cents value shows its amount (`$2.00 Dining Dollars`) instead of `0 meal swipes` on Home cards, the owner, helper, and fulfill detail headers, and the Home expired notice; otherwise the meal-swipe text is used. The Home card drops the backend's trailing `($X Dining Dollars)` from the body when its header already shows the amount, and the owner detail hides the duplicate Dining Dollars fact row for such a request. These are display-only: the backend `food` string is unchanged. The Home card header stacks its two labels when they do not fit on one row (large Dynamic Type) rather than truncating.

**Known limits and deferrals.** The hourly digest is not generation-fenced (recorded by the slice as a deferral). A per-IP limiter (30 for owner reads, 10 for each mutation) matches the other participant routes. A handoff already begun to a provider cannot be recalled, and provider acceptance is not delivery. Withdrawn rows are retained through the original creation campus day and then removed by the existing `deleteAt` TTL; there is no request history (V1). Screenshot network transfer on Edit, VoiceOver, and the helper-side and second-participant device scenarios were not verified on a device (`docs/testing.md`).

## 18. Accepted dormant messaging foundation (W4-MSG1 CP1)

Faith accepted CP1 on 2026-10-19 as a **dormant backend foundation**, not
public messaging or completion of MSG1. At closeout it is uncommitted on
`w4-msg1-cp1-foundation`, based on `1b31f185714370105217af1c6545f0f591c0f3a0`.
Its five-file source/test fingerprint is
`3406606fc4365b39a594b7db94271c7dda3b5f5f07aa5ab72d5e92d4e00566ae`.
These facts describe that accepted candidate, not code integrated into main
or deployed. Verification qualifications are in `docs/testing.md`.

**Implementation boundary.** `models/messaging.ts` defines
`MessageConversation`, `ConversationMessage` and content-free `MessageReceipt`
models with explicit index initialization. `src/messaging.ts` supplies the
service, transactional closure hook and bounded cleanup primitive.
`src/messagingRoutes.ts` implements authenticated HTTP open, send, ascending
cursor read and exact-message reconciliation handlers. They are not imported
or mounted by `app.ts`; no messaging models are imported by `models/db.ts`,
and no cleanup scheduler is registered. CP1 creates no live messaging endpoint,
iOS chat, inbox, WebSocket, push or other public messaging functionality.

**Authority and persistence.** Conversation identity is
`(requestId, helperParticipantId)`, relying on the permanent
`RequestParticipation` prohibition on helper reacquisition. Every protected
operation rechecks credential version, both participant identities, current
request/helper binding, participation, pair-block fence and lifecycle; table
membership is insufficient. A required session-bound policy must supply
authoritative pickup/moderation/deletion facts; absence denies access.
Protected operations take genuine Participant and Request write-conflict
anchors inside MongoDB transactions. Passive lapse and the placed-request
retention horizon are enforced without relying on TTL deletion. HTTP uses
opaque conversation IDs, never a client-visible helper ID, so stale operations
cannot migrate to a replacement relationship. Revocation errors conceal the
private reason; responses are private/no-store and message content is not logged.

**Ordering and operation identity.** A successful send commits message,
per-conversation monotonic sequence and receipt atomically. Unique sequence
and sender/client-UUID indexes prevent duplicates. Exact text is SHA-256
digest-bound and passes U1.1 filtering. Identical manual Retry returns the
original message; different content or conversation under the same identity
conflicts. Reads are sequence-ordered and bounded to 100 messages; exact
reconciliation creates nothing. A missing result does not prove an in-flight
send cannot commit. No reconnect or automatic resend behavior is implemented.

**Revocation and ordinary-content cleanup.** Authorization loss denies access
independently of retained content or TTL lag. Closed conversations cannot
reopen. `closeMessagingRelationship` requires the owning authoritative
transaction, including closure before first open; CP1 does not wire other
lanes' writers. Cleanup handles at most 100 conversations and 100 messages per
conversation per pass, retains durable progress, retries on later passes and
reports content-free failures/overdue counts. Minimal content-free receipts
and closure records have no TTL, preventing identity reuse after content
deletion. Independently authorized safety evidence is not deleted by this
primitive. The 24-hour ordinary-deletion objective and intended one-minute
invocation are **not an operational guarantee**: no scheduler, capacity
qualification or production failure drill is established by CP1.

**Activation remains gated.** U1.3 owns early Block and transactional
Block/Unblock-safe conversation closure; R3 owns authoritative pickup and
send/read race integration; U1.2 owns moderation and bounded authorized report
evidence; P2 owns deletion, retained-safety and receipt-retention integration.
MSG1/operations owns cleanup scheduling, capacity, retry and the 24-hour
objective. N1 owns recipient-to-installation authority before message push.
MSG1/iOS, coordinating B1/R3, owns chat, manual Retry and navigation.
Deployment/production configuration and operational qualification remain
W5-INF1/W5-RC1 release gates. None is completed by dormant acceptance, and
CP2's separate dormant acceptance is recorded below; it does not satisfy
these activation gates.

## 19. Accepted dormant WebSocket foundation (W4-MSG1 CP2)

Faith accepted CP2 on 2026-10-20 following independent HIGH-risk review
**PASS WITH DEFERRALS**. The accepted single-process backend foundation is
uncommitted on `w4-msg1-cp2-realtime-902e41a8`, directly based on accepted CP1
commit `43c3ce6c002a892b2d25a721a73744674ba9e154`. Its eight-file fingerprint is
`9cfcbaac44fc65e0473f7678ceab1459559e4544461c836fac694e95e88ba7d1`
(paths, algorithm and verification in `docs/testing.md`). Acceptance is not
integration, deployment, production registration or public messaging.

**Transport and authority.** `attachMessagingSocket(server, authority)` in
`src/messagingSocket.ts` explicitly attaches `WebSocketServer({ noServer: true })`
to an injected HTTP server. There is no production caller. Only
`/api/messaging/socket` upgrades are allowlisted; header-only participant
credentials are independently verified, never trusted through Express.
Missing, malformed, duplicate, query-string and subprotocol credentials are
refused generically. One strict subscription frame binds a connection to one
request/conversation; no socket write-message operation exists.

CP1's content-free `authorizeSubscription` retains its transactional credential,
participation, relationship, block-fence and lifecycle checks. Initial,
outbound and periodic checks use that authority, not a persistent cache.
Dispatch snapshots coalesce only identical credentials, request and conversation;
different versions and later arrivals require fresh checks. Live membership
and generation guards invalidate removed subscriptions and late results.
Denied, unavailable or timed-out authority fails closed; already-transmitted
bytes cannot be recalled.

**Hints and recovery.** The optional CP1 observer runs after successful
transaction/session completion, outside retryable callbacks. Aborts and failed
commits publish nothing; identical HTTP Retry does not republish. Publication
failure cannot turn a committed HTTP send into a false failure. Wire outputs
are `subscribed`/`changed` with an ephemeral connection-local subscription
reference, or generic `unavailable`: no content, identity, stable conversation
identifier, sequence or cursor. HTTP/MongoDB remain the sole durable write,
read, ordering and idempotency authority.

Provisional registration preserves dirty hints during establishment.
Acknowledgement does not mean HTTP catch-up is complete. Later clients must
fetch and paginate using applied HTTP cursors, retain dirty indications during
fetch, periodically reconcile even on live sockets, and reconcile after
reconnect/restart. Hints never advance a cursor or automatically resend an
ambiguous HTTP mutation. Manual Retry retains the original operation identity,
payload and conversation. Client networking/UI is not implemented by CP2.

**Resource and shutdown bounds.** Per process: 250 connections including
in-progress upgrades/closing peers; eight live connections per verified
participant; sixteen provisional/live subscriptions per conversation; 32 actual
outstanding authority operations, of which at most eight are subscription
validations, two per participant and one per request/conversation relationship.
FIFO pending work skips busy keys; each live connection has at most one queued
validation and one dirty bit. Capacity pressure defers work without granting
authority or immediately evicting healthy peers. Retry cadence is 25 ms;
relationship cooldown is 100 ms after actual settlement. Queue wait and
dispatched authorization each have a five-second deadline; periodic checks
and pings run every 30 seconds. Unsettled operations retain their slots.

Other bounds: 30 upgrade attempts/address/rolling minute, at most 512 address
buckets; 16 KiB upgrade headers; 1,024-byte aggregate frame payload; one
subscription application frame; ten inbound control frames/minute; 1,000
coalesced routing hints with excess dropped; projected buffered output at most
16 KiB; five-second subscription deadline; missing-pong termination at the next
pulse; one-hour lifetime. Generic refusal invalidates authority before flushing
its frame and policy close, with a one-second termination fallback. Broken,
oversized or over-buffered peers need not receive an application refusal.

One attachment is allowed per process. Idempotent disposal removes the upgrade
listener, invalidates subscriptions, clears queues/timers, aborts cooperative
work and bounds socket shutdown to five seconds before termination. It reports
residual authority work; explicit draining awaits actual settlement before
replacement attachment/fixture reuse. Driver cancellation or bounded completion
of an uncooperative adapter is not promised. The HTTP server/proxy must protect
pre-upgrade parsing independently.

**Deferred activation owners.** U1.3 transactional Block closure, R3 pickup
authority, U1.2 moderation/evidence, P2 deletion, MSG1 iOS networking/chat,
INF1 dependency reconciliation/proxy/process/shutdown integration and RC1
deployed/release verification remain required. Section 18's cleanup obligations
remain unchanged. N1 recipient authority is required before enabling messaging
push notifications. Multi-process propagation is conditional on adopting that
topology, not a requirement of this accepted single-process foundation. No
production endpoint, scheduler, iOS chat or messaging push is activated.

## 20. Accepted dormant iOS messaging foundation (W4-MSG1 CP3)

Faith accepted CP3 on 2026-10-20 as a **dormant iOS client foundation**, with
the complete-suite qualification recorded in `docs/testing.md`. It is
uncommitted on `w4-msg1-cp3-ios` (base `e826ea6`) and is not integrated,
pushed or activated. Nothing here makes messaging available in the shipping
app: no `AppRoute`, `ContentView`, tab, entry row or production URL composes
it. CP1/CP2 (sections 18-19) are the accepted backend foundation; this section
adds only CP3's client rules.

**Boundary.** New files under `ios/CommonPlateios/CommonPlateios/Messaging/`
(wire DTOs, HTTP client, WebSocket adapter, pure transcript reducer,
`@MainActor` `ConversationCoordinator`, and SwiftUI components driven by
injected closures). Existing app, store, service, design-token and project
files are unchanged.

**Authority and isolation.** A coordinator is bound to one credential, request
and conversation (resolved once from the authenticated open call) and never
re-points; a replacement helper needs a fresh coordinator and an empty
transcript. Every asynchronous completion is dropped unless identity,
conversation and, for the socket, connection generations still match. HTTP is
the only message authority; socket frames are content-free hints and never
insert messages or move the cursor, which advances only after an applied HTTP
page. Catch-up is serialized with a dirty bit and also runs periodically while
foregrounded. `404 CONVERSATION_UNAVAILABLE` purges transcript, cursor,
pending/failed payloads and draft, cancels the socket and is terminal; `503`,
transport errors and socket failures prove neither closure nor credential
invalidity. Only an HTTP `PARTICIPANT_AUTHORITY_INVALID` reaches the existing
rejection closure. Nothing is written to disk, logs or analytics.

**Sending.** Text is 1-2,000 UTF-16 code units (as CP1), at most 8,000 UTF-8
bytes and non-blank; the server stays authoritative. Each send has an
in-memory UUIDv4. An ambiguous result is reconciled read-only by exact
`clientMessageId`; absent becomes failed, never an automatic resend. "Try
again" is manual and reuses the identical UUID, text and conversation. After a
definitive refusal (`MESSAGE_TEXT_NOT_ALLOWED`, `INVALID_MESSAGE`,
`MESSAGE_IDENTITY_CONFLICT`) identical content is never retried; only Cancel is
offered. At most 10 outstanding local messages (in-flight, ambiguous and
failed) are held; at the cap sending is disabled, the draft is preserved and
nothing is discarded. Releasing a coordinator cancels its owned tasks and
socket; in-flight sends are not cancelled and never resent.

**Presentation.** Text-only components with the approved outgoing/incoming and
failed styles, failure sheet, empty/unavailable states and an ellipsis menu
that lists only host-injected actions. Closed-state, offline, capacity and
entry-row copy is provisional. Hosted simulator tests cover real sheet detents,
44-pt targets and action activation; physical-device VoiceOver is not verified.

**History and memory (CP3 baseline; CP5 supersedes opening in section 23).**
Authorized history is never truncated: the CP3 client pages
forward from cursor 0 without a page cap and retains the transcript in memory
only. Bounded memory and latest-first opening are **not** provided. They need
the separately accepted CP4 backend pagination in section 21 and CP5 in
section 23; CP3 alone does not consume that API. CP5 retains session-only
O(loaded history) memory, not bounded total transcript memory.

**Later integration and activation.** Route and entry-row integration, identity
store and scene-phase composition, Block/Report closures, and every CP1/CP2
activation gate in sections 18-19 remain outstanding, as do device, APNs,
deployed WSS and real cross-lane evidence.

## 21. Accepted dormant backend history pagination (W4-MSG1 CP4)

Faith accepted CP4 on 2026-10-21 as a **dormant backend capability**, following
independent HIGH-risk review PASS WITH DEFERRALS and resolution of its F1
verification gap. It does not mount routes, attach WebSockets, schedule
cleanup, change schemas/indexes, or make messaging available to users.
CP1 authority, sends, exact-operation reconciliation, terminal closure and
cleanup (section 18) and CP2 content-free hints (section 19) are unchanged.

**API and validation.** The unmounted
`GET /api/request/:id/conversation/:conversationId/messages` handler accepts
`direction=backward`, optional `before` (positive safe integer, exclusive),
and optional `limit` (1..100, default 50). Omit `before` for the latest page.
Unknown directions/keys, duplicate or nested parameters, noncanonical numeric
strings (including zero/leading zeros for `before`), unsafe integers, and
out-of-range limits are rejected with content-free `400 INVALID_MESSAGE`.
`after` with backward mode and `before` without backward mode are invalid.
Absent `direction` preserves CP1's ascending forward mode, default/cap 100,
exclusive `after` and exact response keys `{messages, nextAfter}`; accepted
CP3 forward decoding remains compatible.

**Page shape and ordering.** Backward mode returns exactly
`{messages, hasOlder, nextBefore, newestSequence}`. Each message retains only
`clientMessageId`, `sequence`, `sender`, `text`, and `createdAt`. Retrieval
uses the existing `message_sequence_unique` compound index
`{conversationId:1, sequence:1}` in reverse, with `sequence < before` when
bounded and `limit+1` rows; the returned page is reversed to ascending
sequence. `createdAt` is never an ordering key. `hasOlder` comes from the
extra row, not contiguity/counting; `nextBefore` is the smallest returned
sequence, or `null` when empty. A nonempty last page can have a non-null
`nextBefore` and `hasOlder=false`; stop on `hasOlder=false`. No total-history
or page-count cap truncates available authorized messages. Subsequent pages
use the previous `nextBefore` exclusively; concurrent larger sequences do
not shift older page boundaries.

**Snapshot and forward reconciliation.** `newestSequence` is the conversation
head read in the same transaction snapshot as the messages (0 for an empty
conversation),
not necessarily the maximum of an older page. Seed a client's forward
`after` only from the opening latest page's `newestSequence`; never advance
the forward cursor from an older page. Existing forward HTTP catch-up then
recovers later commits without a seam gap. History/send conflicts retry
under the existing CP1 transaction fences. Each page has its own transaction;
there is no multi-page snapshot or server-held cursor.

**Authority and privacy.** Numeric bounds are not credentials. Every page
runs the complete unchanged `protectedOperation`, rechecking current
participant/version, request/helper relationship, participation, pair fence,
lifecycle, policy and `closedAt`. A bound from another conversation cannot
change the path's authorized conversation. Generic `404
CONVERSATION_UNAVAILABLE` conceals denial/closure reasons; existing
participant-authority refusals and content-free `503 MESSAGING_UNAVAILABLE`
remain unchanged. Responses remain `private, no-store` and vary on
`x-commonplate-participant`; no message, credential or cursor is logged.
Closed conversations cannot be read, recreated or resurrected by pagination,
including after cleanup or Unblock. A page may linearize before revocation;
delivered bytes are not retracted, and no later authorized page is promised.

**Resource and integration limits.** At most 101 message rows are requested
per page. Explain/profiler verification covers bounded message-index work,
not every authorization operation or production latency: every page still
performs CP1's transaction, Participant/Request fence writes and conversation
write. No rate-limit/capacity or production-load claim is established.
CP5 adds dormant iOS latest-first consumption, separate cursors and scroll
anchoring (section 23), retaining O(loaded history) session memory rather than
window eviction. Live navigation is separately owned.
Real R3 pickup, U1.2 moderation/evidence, U1.3 transactional Block closure,
P2 deletion, N1 before push, and INF1/RC1 deployment/operational qualification
remain deferred as in sections 18-20. Local synthetic-authority proof is not
those integrations, physical-device or deployed HTTPS/WSS proof.

## 22. Requester placed-order continuation and pickup (W4-R3)

Faith accepted W4-R3 on 2026-10-21, with the verification limitations recorded
in `docs/testing.md`. After a helper places the real order, the exchange stays
visible to both participants until the requester confirms pickup. Placement does
not end it. The requester's `I picked it up` is the only terminal event, and it
never claims provider-verified pickup.

**Lifecycle.** Helper places the order, sees the accepted success presentation
and returns Home. The same request stays under `Continue helping` as a calm,
non-urgent `Waiting for pickup`. The requester sees `Your meal was ordered` in
`Your Requests`, which becomes `Confirm pickup` (attention only; the request
stays `placed`) once backend `estimatedReadyAt` has passed. The requester then
taps `I picked it up`, and `requesterPickupConfirmedAt` becomes authoritative.
The requester card retires and the helper card retires on the next
authoritative read or relaunch. The helper's `Waiting for pickup` state survives
relaunch because it is derived from backend truth.

**Visibility cutoffs (presentation only).** Persistence is unchanged: the
request stays `placed`, and the request and `PlacementEvidence` keep the
seven-day `deleteAt` retention. A helper sees a placement until the earliest of
requester-confirmed pickup or `estimatedReadyAt` + 1 hour. A requester sees it
until the earliest of confirmed pickup or the end of the `America/New_York`
campus day containing `estimatedReadyAt`. `estimatedReadyAt` is derived from
`placedAt` and the helper-authored `etaText` (never parsed on the device) and is
compared with backend time, never the device clock. A placed row without a valid
ETA violates the H1a invariant: it is excluded from active Home, a content-free
diagnostic is emitted, and nothing is fabricated. Expiry writes nothing and never
implies pickup. `hasUnfinishedPlacedPickupObligation` (the B1 Change Email
gate) is `placed` and unconfirmed and `deleteAt > now` and backend now < the
requester cutoff. An invalid ETA rejects (fail closed), so it is never `false`.

**Requester routes.** All are verified-participant routes, `private, no-store`,
with every refusal an indistinguishable `404 PLACED_ORDER_NOT_FOUND` (or
`503 PLACED_ORDERS_UNAVAILABLE` for an unreadable store).
`GET /api/participant/placed-orders` lists the requester's unconfirmed placed
orders. `GET /api/participant/placed-orders/:requestId` returns the detail: order
number, estimated-ready time, dining hall, address, request context, pickup
state and `contactHelperEmail`. `GET …/:requestId/evidence` returns the helper's
Grubhub order-confirmation screenshot as raw bytes, requester-authorized, never
cacheable, memory-only on the device, with no Save or Share. A missing evidence
row is an invariant violation that fails closed (`503
PLACED_ORDER_EVIDENCE_UNAVAILABLE`). `POST …/:requestId/pickup-confirmation`
atomically and idempotently sets only `requesterPickupConfirmedAt` (safe replay,
one persisted timestamp), and the client never retries it automatically. The
helper Message (`contactMessage`) is never requester-visible.

**Helper continuation.** The helper reads their own placements from the
participant active-reservation read: `placements[]` carry the request,
`orderNumber`, `etaText`, `estimatedReadyAt`, `helperVisibleUntil` and notification
state. They carry no requester identity or pickup timestamp, and the public
Request DTO gains none of these fields. Tapping a Waiting card opens the
helper-owned `AppRoute.helperWaiting` detail for that exact request. It never
uses the public request-availability path (which would answer "no longer
available"). The detail shows order number, estimated-ready time, dining hall,
address, `What was requested`, `Contact requester` and the existing `•••` →
`Block this student`. It offers no pickup or completion action and no in-app
messaging. The detail has no dedicated Figma frame. It mirrors the requester
detail by Faith's decision and its layout is PROVISIONAL pending B1.

**Helper contact.** `GET /api/participant/helper-placements/:requestId/contact`
returns `{ contactRequesterEmail }` only to the placing helper, only while the
request is `placed`, unconfirmed, retained and inside the helper's visibility
window (`estimatedReadyAt` + 1 hour), the pair is not fenced and neither
participant is suspended. Every other case is the same uniform `404`. This is the
single authorized helper-side disclosure of the requester's address (the V1
email fallback), and it is rate-limited like the other placed reads. It does not
extend to the seven-day retention.

**Blocking.** A helper may Block the requester from the Waiting detail through the
existing contextual Block (section 5.3). The requester may Block the helper from
the placed-order detail (the requester → helper creation authority belongs to
R3's client surface). A Block fences the pair, so both contact reads then refuse.

**Home presentation.** Placed orders live inside `Your Requests` on the shared
R5 card (no parallel section; 0/1/2/3+ and `See all` are R5's). Confirm pickup
orders by urgency above lower-priority requests. A placed card shows a green dot
and `Your meal was ordered`, or the rose circled exclamation and `Confirm pickup`
with a rose card tint (the tint is not in Figma and was added at Faith's
direction). A helper `Waiting for pickup` card is compact (status, quantity, dining
spot, meals one per line) and does not repeat the order number or estimate.
Multiple waiting cards are all preserved, in placement order newest first, below
any active claimed or unplaced request, using the shared two-card preview and `See
all`. The one-time `Pickup confirmed. Enjoy your meal!` notice renders at the top
of Home. The helper `Choose Grubhub screenshot` control and the requester control
share one chrome and keep stable height once a screenshot is attached.

**Maps.** The address is always visible. Only venues with a reliably resolvable
destination get the `↗` and the Apple/Google Maps chooser (`R3MapsDestination`:
the six verified catalog venues, plus real street addresses for Crave NYU and
Cafe 181 (181 Mercer St), Jasper Kane Cafe and Flavor Lab (327 Jay St, Brooklyn)
and Dunkin' at U-Hall (110 E 14th St)). `shared/vendors.json` is unchanged: it
still holds descriptive text for some of these venues and remains the
screenshot-qualification catalog. Correcting it is a cross-lane change.

**Deferred and not established.** B1 owns the Home `Continue helping` redesign,
the confusing requester `ASAP` / `Available until` wording and a better
post-placement helper experience. N1 owns the helper notification when pickup is
confirmed. MSG1 (v2) owns in-app messaging and Contact on claim for both
participants. R3 acceptance is not provider-verified pickup, N1 delivery or P2
deletion of placed-order data, and it does not establish Release, signing or
TestFlight behavior (section 11).

## 23. Accepted dormant iOS history loading (W4-MSG1 CP5)

Faith accepted CP5 on 2026-10-21 with the failed-suite qualification and
explicit keyboard/device deferrals in `docs/testing.md`. This extends CP3
using CP4; it does not expose chat in shipping navigation, mount backend
routes or WebSockets, change request authority, or activate messaging.

**Opening and history.** Opening requests the latest authorized page with
`direction=backward&limit=50`, without `before` or `after`, and displays it
chronologically at the newest messages, including empty/short conversations.
It does not drain earlier pages before presenting. Only the opening page's
`newestSequence` seeds forward HTTP reconciliation. Older pages never advance
that cursor. Reaching the loaded top requests the exclusive `before=nextBefore`
boundary, one history request at a time and no automatic page draining.
`hasOlder=false` terminates loading even with a non-null `nextBefore`.
History failures offer explicit Retry without consuming the applied boundary.
There is no total-history cap; 5-50 messages is an expected volume, not a limit.

**Reconciliation and privacy.** Forward catch-up and older history have
independent cursors and tasks. Chronological union deduplicates matching
sequence/message identities and rejects contradictory mappings atomically.
Concurrent incoming messages cannot be lost at the opening/history seam.
Identity/conversation generations and history epochs fence obsolete results,
including noncooperative late completions after cancellation. Backgrounding
cancels obsolete history work; foreground reconciliation preserves applied
boundaries. Authoritative unavailability is terminal and purges messages,
cursors, pending/failed sends, draft and related viewport state. Replacement
helpers require a fresh coordinator; a closed conversation never reopens.
CP3's exact UUID/payload/conversation manual Retry and no automatic resend
remain unchanged. Credentials and transcript contents remain private and
session-only, never persisted or logged.

**Reading position.** Existing lazy SwiftUI rendering uses stable message
identities and hosted viewport geometry. Prepending preserves a visible
message's viewport-relative position, including partially visible tall
messages, consecutive pages, Dynamic Type and concurrent appends; settled
prepend drift must remain at most 2 points. Appended messages follow the bottom
only when already bottom-pinned, rather than moving a reader of older history.
This does not establish correct bottom pinning during viewport/keyboard resize:
the artificial-inset concern remains unresolved, and real-system-keyboard
show/hide and bottom-pinned qualification belong to integrated MSG1 CP6,
mandatory before messaging activation.

**Resources and remaining gates.** All fetched history stays in session
memory: O(loaded history), not bounded total transcript memory. Lazy rendering
is not eviction, disk caching or long-conversation resource qualification.
Request-linked navigation and identity/scene composition, R3/safety/deletion
integration, device/VoiceOver, deployed HTTPS/WSS, notifications, operational
and activation gates remain separate. R3's local-main integration does not
by itself establish any MSG1 cross-slice behavior or authorize CP6.

## 24. GoodGrub branding, unsupported-school entry and Change Email (W4-B1)

Faith accepted W4-B1 on 2026-10-22 after a physical-device walkthrough (iPhone 16 Pro, local QA backend). Local accepted behavior only; this section does not claim a deployed, Release, signed or TestFlight build, and acceptance is not public-release approval.

**iOS presentation.** The product name is GoodGrub (`AppBrand`, `BrandSupportEmail` in `Info.plist`). Home, owned-request, helper Waiting and order-confirmation cards share one `commonPlateCard` surface. A Meal Exchange card shows the meal-swipe count with any Dining Dollars top-up as "+ $X" on the title's second line; "Available to helpers" stays top-right, stacking only at accessibility Dynamic Type sizes. "Manually selected" appears only when Screenshot Assistance has established or conflicted the menu path. Timing labels come from `RequestTimingLabels`. An unsupported school sees `UnsupportedSchoolView`; it has no close control, so `I have an NYU email` is the only way back and Contact GoodGrub is unchanged (W4-UI1 CP2). A reached daily limit shows "Today's request limit reached" with a Find food support entry to Settings food resources (Figma `1212:7875` / `1300:8131`). The requester pickup card collapses on a confirmed pickup; pickup is never inferred from a card disappearing, expiring or being withdrawn.

**Change Email.** `src/emailReplacementGate.ts` gates identity replacement; a stale or superseded authority cannot complete it, and an unfinished placed pickup obligation (section 22) blocks it. CP1 supersedes the unconditional cooldown-to-code presentation: only a confirmed send to that address in the current flow permits the shortcut (section 1.6).

**Helper pickup acknowledgement.** The active-reservation read adds `pickupConfirmations: [{ requestId }]` for the calling helper's placed orders whose requester has confirmed pickup and which are still inside helper visibility (`src/reservationRoute.ts`). It is additive and read-only. The iOS Home banner and haptic are bound to the participant authority and principal and de-duplicated client-locally only.

**Not established.** Push delivery of the helper notification is N1's, and de-duplication between push and the in-app banner is N1's. In-app contact is MSG1's. Stale `shared/vendors.json` addresses are for the planning owner. Large Text, Reduce Motion and VoiceOver were accepted without physical-device proof. A transient Home flicker (back button and large "Your requests" title) was observed once and has no repro; the `AppRoute.ownRequests` snapshot is an unproven hypothesis. `testLongCollapsedDetailsWrapsFullyAndGrowsCardHeightNaturally` and the Home refresh motion tests are load-sensitive iOS tests that fail on the accepted candidate.

## 25. Moderator dashboard, removed-request notices and report-flow fixes (W4-U1.2 CP5)

Faith accepted W4-U1.2 CP5 on 2026-10-23 for local integration only, with the verification exceptions recorded in `docs/testing.md` section 13. This section does not claim a deployed, Release, signed or TestFlight state, and CP5 is not production-release qualified.

**Moderator dashboard.** Reports closed by a moderator open in a read-only view. Navigation is consistent across pages, dates render server-side in `America/New_York`, and styling is same-origin only; the Content-Security-Policy forbids script, so no page relies on client-side validation. Closing a report with an outcome that suspends the participant requires private notes that carry no email address. When they are missing or invalid, the server answers `400` with an in-dashboard alert and a link back to the report, and the report stays open.

**Owner removal answers.** Only a live `open` or `claimed` request carrying the Remove-request or requester-suspension marker (`moderationUnavailable`) is a removal. For its owner, `GET /api/participant/requests` omits it and returns the owner-only boolean `removedNotice: true`, and the detail read answers `410 REQUEST_REMOVED` ("This request is no longer available."). A withdrawn, expired or placed request keeps its ordinary terminal answer even when held (`410 REQUEST_WITHDRAWN`, `410 REQUEST_EXPIRED`, or the placed `409`), so a hold is not inferable from the status. A live request held only by a helper suspension (`reservationLapseHold`) is not ongoing and stays the uniform `404`. A helper suspension never notifies the requester. Edit and Withdraw on a removed request still answer the earlier `404`; that is an open deferral.

**Email replacement.** The Change Email gate also reads `moderationUnavailable` and `reservationLapseHold` when listing blockers, so a removed request is not treated as open.

**iOS.** A neutral removal notice (Faith-approved copy, no request, reporter, reason or rule named) appears on Home and Request Detail for the requester only. The Home flag is in-memory in `RequestStore`; a dismissal stays dismissed until `removedNotice` goes false and then true. The reporter never sees it, and nothing carries across an account switch. Contact support sits on its own line below the banner text. Navigation-crash fixes cover verification, wrong-email back navigation and sign-out with a pushed screen. A `403 PARTICIPANT_SUSPENDED` is not yet mapped on iOS.

**Not established.** Official parallel `npm run test:mongo`, final physical-device re-checks, VoiceOver, large Dynamic Type, lost-response recovery, the remaining moderator outcomes and report reasons, and independent review of the 410 correction, the two UI fixes and the final `RequestStore` changes. Push and deployment are not performed.

**MSG1 CP6 bounded Report-evidence and removal closure (Faith accepted; integrated locally 2026-10-26).** When U1.2 independently authorizes a Report, unavailable message evidence does not itself deny the Report. Capture is recorded as `complete` (including a successful empty capture) or `incomplete` with a bounded reason; only safely available messages from the exact authorized conversation are retained, capped at ten recent committed messages. Invalid Report authority, an expired window, and an invalid counterpart-bound post-Block handoff still deny. An unexpected capture-query error aborts its transaction; a fresh transaction rechecks Report authority and the applicable window before recording `capture-failed`. The moderator view exposes capture status and limitation. In the moderation-removal path, when the MSG1 lifecycle is installed, its request-scoped closure hook runs in the removal transaction; hook failure rolls back removal, and reinstatement does not reopen closed conversations. The lifecycle remains uninstalled in shipping composition, so this does not activate messaging or change the dormant shipping boundary.

Source commit `9036ea5` and prepared candidate `6799e55` are integrated into local `main` by merge `cccf365` (parents `eb0eb1a`, `6799e55`). All twelve accepted implementation/test files are byte-identical to the candidate. CP4's unaccepted UI changes were relocated to its own worktree before integration and are not included. No deployment or activation is established. Physical-iPhone keyboard/VoiceOver proof remains unperformed, and full MSG1 CP6 remains blocked by that proof and the separate INF1/REV1 gates.

## 26. iPhone Release configuration and V1.0 requester Screenshot Assistance exclusion (W5-IOS1)

Faith accepted W5-IOS1 on 2026-10-23. Local accepted behavior only: this section does not claim a deployed endpoint, a signed immutable candidate, a physical-device pass or App Store readiness (those belong to W5-RC1).

**Requester Screenshot Assistance is excluded from V1.0.** The implementation is preserved and testable but unreachable in every shipping configuration; sections 12 and 14–15 describe the preserved behavior, not V1.0 availability.
- **Backend (authoritative).** `src/screenshotProposalRoute.ts` refuses `POST /api/request/screenshot-proposal` with `503 SCREENSHOT_ASSISTANCE_UNAVAILABLE` (shared structured error contract) before the pause middleware, rate limiter, body parsing, participant lookup, image handling and any provider call. No environment variable, header, body field or client value controls it, and `PUBLIC_ACTIONS_PAUSED` is unchanged and independent. Production registration (`registerScreenshotProposalRoute(app)` in `app.ts`) passes no option; only an injected `enableForTests` parameter, never passed in production, enables the route in tests.
- **iOS.** `RequesterScreenshotAssistanceAvailability` is the single gate: `.shipping` is excluded and `.enabledForTesting()` exists only for tests. `ContentView` constructs the store and service with `.shipping`. The Request Food and Edit Request entry points are not rendered, with no disabled or "Coming Soon" placeholder. Settings has no Screenshot Assistance option and onboarding/help makes no availability claim. The store and service refuse before any local, external or network work, so saved consent, stale drafts and restored state cannot activate it. Saved preferences are neither granted nor revoked while excluded, and manual draft state is untouched. `Services/ScreenshotAssistance/*` is preserved.
- **Unchanged.** Manual Request Food/Edit, H1a mandatory placed-order screenshot evidence (section 5.4) and unrelated uploads.

**iPhone-only.** The app target sets `TARGETED_DEVICE_FAMILY = 1`, with Catalyst, Mac-designed-for-iPad and visionOS support off. The deployment target is 17.6.

**Production API routing.** Debug keeps the validated loopback/private override and the `127.0.0.1:3000` default (`localSimulator` and `forLaunch()` are `#if DEBUG`). Release uses `Configuration/Release-Info.plist` and reads `CommonPlateProductionAPIBaseURL`, expanded from the build setting `COMMONPLATE_PRODUCTION_API_BASE_URL`, which the project leaves undefined. The value must be a bare `https://` DNS host: no credentials, port, path, query or fragment, no IP literal, no single-label or special-use TLD (`localhost`, `local`, `internal`, `invalid`, `test`, `example`, `home`, `arpa`). A missing or invalid value makes `CommonPlateiosApp` show the static `ConfigurationUnavailableView`: no client or store is built, no request is made and nothing falls back to another backend. Tests and Debug never default to production.

**Release ATS and entitlements.** The effective built Release `Info.plist` has no `NSAppTransportSecurity`, `NSAllowsArbitraryLoads`, `NSAllowsLocalNetworking` or local-network usage description. Debug keeps `Info.plist` with local-development access. The Release plist carries the same keys as Debug (including B1's `BrandSupportEmail`, `LSApplicationQueriesSchemes` and `UIAppFonts`) plus the production key; `src/iosReleaseConfiguration.test.ts` guards drift, so any later `Info.plist` key must be mirrored in `Release-Info.plist`. The source entitlement `aps-environment` stays `development`: a local `app-store-connect` export of a Release archive re-signed it as `production` with `get-task-allow` false.

**Not established.** A deployed production origin or APNs topic (W5-INF1); a signed immutable candidate, a physical-device pass, and deployed-endpoint, provider and APNs behavior (W5-RC1). The local archive/export used a placeholder host and is not a candidate. A Release build of the test target fails on `@testable import` (testability is off in Release); tests run in Debug.

## 27. Approved app icon and Home Screen display name (W5-ICO1)

Faith accepted W5-ICO1 on 2026-10-23. Local accepted behavior only: this section does not claim a signed/distribution build, a physical-device pass or App Store Connect listing icon proof (those belong to W5-RC1 and W5-ASC1).

**App icon.** `AppIcon.appiconset`'s universal (1024×1024) slot references `AppIcon-1024.png`, exported from the approved Figma source (file `o5VXC3QZWs4w9tQ8drVRC4`, node `1665:7262`): terracotta background `#A24F38`, cream meal symbol `#FBF9F6`, full-bleed opaque square, no pre-rounded corners, no baked shadows/effects, the source's terracotta knockout shapes between overlapping meal elements preserved. The shipped file is flattened to 8-bit RGB with no alpha channel (the Figma export carried an alpha channel but every pixel was fully opaque; flattening removes an unnecessary channel without changing appearance). Dark- and tinted-appearance slots remain unpopulated; no new artwork was created for them, and nothing in Apple's current asset-catalog validation required them.

**Display name.** `CFBundleDisplayName` is `GoodGrub` in both `ios/CommonPlateios/CommonPlateios/Info.plist` (Debug) and `ios/CommonPlateios/Configuration/Release-Info.plist` (Release, per the dual-plist pattern `src/iosReleaseConfiguration.test.ts` guards per section 26). Before this slice neither plist set `CFBundleDisplayName`, so the Home Screen label defaulted to the target name `CommonPlateios`.

**Not established.** The literal rendered Home Screen tile was not visually captured (the installed icon landed on simulator Home Screen page 2, not the page screenshotted; reaching it needed simulator touch/swipe navigation that was not performed). Physical-device rendering, a signed/Archive/TestFlight build, and App Store Connect icon/listing proof remain open (W5-RC1, W5-ASC1).

## 28. Request Alerts foundation: participant-bound Push, eligibility and Email shutdown (W4-N1 Increment A)

Faith accepted W4-N1 Increment A on 2026-10-23 after a physical-device walkthrough (iPhone, local QA backend, development APNs). This section records that foundation; section 29 records accepted Increment B and supersedes its discovery copy, Settings presentation and remaining tap/push deferrals. Acceptance does not establish deployment or distribution/TestFlight behavior.

**Installation participant binding (the shared identity seam).** `Installation` (`models/db.ts`) carries private (`select: false`) `participantId` and `participantAuthorityVersion`, with one index `{ participantId: 1 }` that also serves the future P2 deletion adapter. This is the only definition; P2 consumes it and does not redefine it. Installation identity remains device-routing metadata and never becomes participant authority (section 3.1).
- `PUT /api/installations/push` **enable** resolves participant authority (`resolveParticipantAuthority`) before any mutation and writes `participantId`, the Participant's current `authorityVersion`, `pushEnabled` and the token in one conditional update. Missing or invalid authority returns the existing participant refusal and mutates nothing. **Disable** stays installation-credential-only, so a user can always turn Push Off.
- The same route accepts a declarative association body (`association: "replace" | "clear"`). `replace` requires participant authority and rebinds the installation to it (the Change Email A → B handoff); `clear` is credential-only, unsets the binding and sets `pushEnabled: false` (Remove Email). Every mutation carries a monotonic `mutationVersion`; an older mutation cannot overwrite a newer one and is refused `409 INSTALLATION_UPDATE_SUPERSEDED`.
- iOS completes Change Email locally only after a confirmed `replace`, and Remove Email (now presented as Sign out) only after a confirmed `clear`. A definite failure keeps the current identity; an ambiguous result keeps it too, presents Push as neither stably On nor Off, and is never retried automatically. An interrupted handoff may be retried explicitly through the existing Change Email verification with a fresh code; no bearer credential is persisted.

**Shared Push eligibility.** `selectEligiblePushInstallations` (`src/pushEligibility.ts`) is the single recipient predicate: `pushEnabled`, a usable token, not invalidated, a bound `participantId` whose Participant exists, is not suspended (U1.2 `isParticipantSuspended`) and whose current `authorityVersion` equals the recorded one, and not pair-fenced in either direction (U1.3 `findFencedCounterpartIds`) from the request's counterpart. Unbound legacy rows, version mismatches and deleted Participants are ineligible with no migration. Helper new-request fan-out (`src/helperNewRequestPush.ts`, reached from request creation and the eligibility sweep, section 8.5) excludes the request's own requester for that request only. Requester-fulfillment Push (section 8.2) targets the originating installation only when it is bound to the request's requester and not fenced from its helper, and rechecks eligibility before sending.

**Helper new-request copy.** Title `New request at {Dining Location}`. Body `ASAP · {N} meal swipe(s)` or `{stored pickupWindowText} · {N} meal swipe(s)`; a Dining-Dollars-only request (`menuPath` `dining-dollars`) uses `$X.XX Dining Dollars` from `estimatedDiningDollarsCents`; a Meal Exchange request with a top-up shows the swipe count only. The payload carries no food, order, pickup name, token or contact detail; tap routing is unchanged (section 8.3).

**Request Alert Email is inactive in V1.** `isRequestAlertEmailDeliveryActive()` (`src/requestAlertEmailDelivery.ts`) is hard-coded `false`, with no environment or runtime switch. `POST /api/subscribe` refuses `410 REQUEST_ALERT_EMAIL_UNAVAILABLE` before any Subscriber write or email. Confirmation GET/POST render a neutral `410` page and never confirm. Real-time alerts, recent-request alerts and the hourly digest return before any `SendLog` claim. NYU verification, requester placement email and operator/monitor email are unchanged, and `PUBLIC_ACTIONS_PAUSED` semantics are untouched.

**Helper reservation contact.** `GET /api/participant/active-reservation/:requestId/contact` returns `{ contactRequesterEmail }` only to the verified helper holding that live, unexpired reservation, and only when the pair is not fenced, neither participant is moderation-disabled and the request is not moderation-removed. Every refusal is the same `404 RESERVATION_CONTACT_NOT_FOUND`, and responses use the placed-order cache isolation and read limiter. iOS shows `Contact requester` on the active helping screen.

**iOS presentation.** Request Alerts are Push-only and managed inline in Settings with a quiet switch, a spinner while updating, `Notifications are off` recovery for denied permission, and `Something went wrong while updating Request Alerts.` with `Try Again` for every other problem; `PushSubscriptionStore` stays the single state owner and section 8.6 truth is unchanged. The Home promotion starts the same Push action directly, without a popup. The accepted Home card, meal presentation, timing copy, reservation-warning copy and `GrubhubRestaurantDestination` restaurant links are recorded in the W4-N1 contract. V1.0 Screenshot Assistance exclusion remains owned by section 26.

**Not established.** Cold-launch tap proof and signed Release/TestFlight push behavior remain with W5-IOS1/INF1 and W5-RC1. Provider acceptance is submission only, never delivery or reading. Mixed-resource notification copy, request-specific requester tap routing, pickup-confirmation Push and further reminders are Increment B.

## 29. Accepted notification completion (W4-N1 Increment B)

**Acceptance (2026-10-24, restored by Faith):** closing-soon alerts separate
quantity title, `Closing in 15 min` native subtitle and location body; Faith
accepted the mixed-resource presentation on device. Discovery tap, background
requester placed-order tap, and helper pickup-confirmed receipt/Home tap were
also physically confirmed. Foreground duplicate acknowledgement and terminal
old-alert fallback remain physically unverified and explicitly accepted as
gaps, not passes. The Debug launch-only API override limitation is accepted
without an N1 fix; production-configured cold-launch proof remains RC1-owned.
See `docs/testing.md` for proof and limitations.

Faith accepted the implemented Increment B scope with those limitations.
Increment B is committed as `a227536` and fast-forward integrated into local
`main`, following already integrated Increment A (`4aa2741`, accepted-truth
sync `9360be1`). Local integration is not deployment or release qualification.
This section supersedes conflicting
notification copy/presentation and deferral statements in sections 27-28.

**Installation authority.** Enabled iOS Push synchronization reads the current
Participant authority directly from `ParticipantIdentityStore` and fences
identity changes across asynchronous APNs registration. It consumes the one
shared Installation association/version/index; no parallel P2 identity is
introduced. Disable and ambiguous-mutation safeguards remain unchanged.

**Helper discovery.** Initial titles contain authoritative value only:
`1 meal swipe`, `2 meal swipes`, `$12.00 DD`, or
`2 meal swipes + $8.00 DD`. The body is the authoritative dining location.
Swipe singular/plural and two-decimal cents formatting are preserved.
Neither ASAP nor requester Later timing appears; requester-facing timing,
existing scheduled-dispatch eligibility and lifecycle semantics are unchanged.
`DD` is notification-title-only, not an in-app rename.

**Closing soon.** In addition to initial discovery, one closing-soon Push uses
the same value-first title, a separate `Closing in 15 min` native subtitle,
and location body, avoiding the long combined title. iOS controls native
layout; the payload does not guarantee line wrapping or subtitle visibility.
The minute sweep selects effectively available requests within fifteen minutes
of authoritative expiration, with a separate persisted initiation latch and
PushDelivery purpose. Request availability, generation and recipient authority
are rechecked before provider submission; claimed, withdrawn, expired or
otherwise ineligible requests/recipients fail closed. This is not a recurring
reminder, aggregation or an exact-second scheduling guarantee.

**Requester placement tap.** Copy remains `Your order was placed` /
`A helper placed the order for your request.` Tap resolves
`AppRoute.placedOrder(requestID:)` through current R3 backend truth, preserving
shared tap ordering and cancellation fences. Inaccessible or confirmed orders
return Home without private data; backend unavailability is temporary failure,
not fabricated lifecycle truth.

**Helper pickup confirmation.** After the authoritative requester pickup
confirmation commits, only the recorded helper's eligible installations receive
`Pickup confirmed` / `The requester confirmed pickup. Thanks for helping make a meal possible!`.
It reuses shared authority, suspension/block fencing and PushDelivery dedup.
Tap opens Home. Foreground suppression is limited to the matching acknowledgement
actually presented on Home, avoiding duplication of B1's local acknowledgement
without suppressing unrelated events or non-Home presentation.

**Settings.** Settings presents a native `Push notifications` toggle without
permanent On/Off labels, explanatory cards or Open Settings button. First enable
requests system permission; previously denied permission uses a brief alert with
an explicit Open Settings action. Authorized enable changes the app preference;
disable leaves system permission unchanged. Returning from system Settings
refreshes permission and reconciles effective state. Failures/ambiguity remain
explicit and never silently retry mutations. The Home promotion and Email
behavior are unchanged. Change Email is removed from Settings; safe Sign out
and internal identity-replacement/recovery machinery remain.

**Icon packaging.** `GoodGrubAppIcon.appiconset` is primary in Debug/Release.
Its universal iOS 1024px runtime master and explicit iPhone sizes use the
unchanged ICO1 artwork (`AppIcon-1024.png`, SHA-256
`0880c28a8887cb9c82d12e002fc279384c16e7c0bcc44efdd73415d6a9aeacf9`).
The runtime master preserves actual image data under normal device thinning;
no global thinning override or restaurant-specific notification icon exists.
Faith reports the final physical notification icon passed.

**Boundaries retained.** One-minute, new-claim, post-pickup-window and recurring
reminders, aggregation, MSG1, transactional fulfillment-email retirement and
Reply-To replacement remain deferred. U1 owns claim-expiration changes; the
existing iOS T-5 warning consumes backend `claimExpiresAt`, with no N1 formula.
P2 consumes shared Installation unlinking downstream. User-reported physical
background tap checks do not establish persistent-endpoint readiness
(IOS1/INF1), signed distribution/TestFlight Push (RC1), or deployment.
Provider acceptance is never proof of delivery, reading or pickup.

## 30. Participant account deletion (W4-P2)

Faith accepted the irreversible-deletion backend, completion recovery and
public backend surface on 2026-10-24, and Checkpoint 9 and the complete W4-P2
slice on 2026-10-26 (9/9 checkpoints accepted). This section includes accepted
iOS activation; acceptance does not establish release, device, deployment or
provider proof.

**Lifecycle and public surface.** An authenticated Participant may inspect
eligibility and create, read, cancel, challenge, redeem, complete or recover a
deletion operation through the `/api/participant/deletion...` routes. The
server derives the operation owner from live Participant authority; submitted
Participant IDs/emails are not authority. Challenge delivery is attempted
after durable challenge state is written; a delivery failure is compensated
against that exact state and reported without exposing the code. Recovery uses
the operation ID and the exact opaque capability issued at authorization.

**Authorization and irreversible transaction.** Completion requires the exact
recovery capability, an unexpired authorization and matching readiness
generation. The whole-operation readiness evaluator runs before completion,
then requester and helper blockers are rechecked inside the final snapshot
transaction. A late blocker aborts all deletion writes and readiness is
demoted; no partial deletion is committed. A referenced U1.2 safety identity
is confirmed with `confirmSafetyIdentity` inside that same transaction.
Permanent RequestParticipation and Request/RequestUpdateOperation tombstones,
deletion-operation receipt transition, and Participant removal commit
atomically with the remaining deletion treatments below. There is no global
backend mutation freeze while deletion is pending: other installations may
still attempt mutations, and authoritative readiness reconciliation and the
in-transaction recheck determine whether deletion can proceed.

**Installation.** P2 consumes N1's private `participantId`,
`participantAuthorityVersion` and association ordering. Successful deletion
clears only those association fields on Installations belonging to the
deleting Participant, in the final transaction. It preserves Installation
credentials, APNs token, preferences and other device state. N1 eligibility
fails closed after unlink; provider-handed-off notifications cannot be
recalled, and provider acceptance is not verified delivery.

**Request and fulfillment records.** Once interaction blockers are
authoritatively clear, deletion immediately removes every requester-owned
ordinary Request document and its linked ordinary PlacementEvidence,
independent of their normal TTL. Separately retained moderation/safety
evidence follows its own accepted hold and retention rules. On another
Participant's Request, deletion unsets only the deleting helper's direct
Participant/email bindings; the other requester's Request and evidence remain.
Fulfillment remains the permanent operational/counting ledger and is not
cascade-deleted with its Request. For deleted requester-owned Requests, its
optional legacy free-text `note` is removed. Fulfillment may additionally
retain only the per-Request helper participation pseudonym and authoritative
requester pickup-confirmation timestamp needed for the narrow helper terminal
proof; it retains no raw helper Participant ID for that proof.

For a physically absent or expired Request, TTL or absence is never deletion
authority. A helper obligation clears only when permanent RequestParticipation
identity matches the Fulfillment's request-scoped helper pseudonym and the
Fulfillment has a valid authoritative pickup-confirmation timestamp. Missing,
malformed, mismatched or unconfirmed proof remains unknown and blocks deletion.
Request and PlacementEvidence TTLs are not extended.

**Email subscription history.** In the same final transaction, deletion
removes the Subscriber row matching the deleting Participant's canonical
email, invalidating its unsubscribe capability. A later signup at that address
creates fresh subscription state, not the old status, counters or history.
Deletion also removes all SendLogs for that Subscriber and all SendLogs for
requester-owned Requests deleted by the transaction, including free-text
errors. Unrelated Subscribers and SendLogs are unchanged; no post-deletion
retention horizon is introduced.

**Safety and permanent identity records.** Accepted pseudonymous safety
evidence and permanent operation ledgers follow their existing transformation,
hold and retention rules; ordinary account deletion does not erase or reset
those records. Same-email recreation does not restore the deleted Participant,
Subscriber or their live bindings. No safety/moderation state is exposed by
deletion responses.

**Completion recovery.** The completed operation retains only its permanent
unique operation ID plus the minimal recovery receipt and capability digest
for at most seven days from completion. Expiry scrubs receipt fields, not the
operation-ID tombstone. A scheduled, non-overlapping 15-minute sweep performs
that scrub and logs its result count or a content-free failure class. Whole-row
TTL deletion is not used.

**Verification boundary.** Backend typecheck, full non-Mongo tests and the
full replica-set Mongo suite, iOS proof, independent review and accepted
verification limitations are recorded in `docs/testing.md`. Automated proof
does not establish physical-device behavior, environmental erasure, deployment
or provider delivery.

### 30.1 iOS activation, reconciliation and local retirement (Checkpoint 9)

**Namespace and provenance.** Deletion operations bind to a server-derived,
non-credential projection of the existing request-operation ledger namespace.
Subsequent operation requests, final completion and capability recovery must
match that binding. Transactional namespace fencing rejects replacement behind
the same API origin; malformed or missing bindings fail closed. An authenticated
comparison can attest an already-recorded ledger against the exact live
deletion operation. This is comparison provenance, not completion or erasure
authority; a URL, email, Participant ID, operation ID or standalone ledger fetch
is insufficient to authorize local cleanup.

**Entry and readiness.** Delete Account is activated in Settings / Privacy &
Safety. The initial confirmation precedes backend work. Authoritative
eligibility identifying an active requester/helper obligation presents
`Finish your request first`; Go to Request only navigates to the existing
request flow, and Keep My Account preserves the account. Such entry blockers
do not start a deletion operation. Immediately eligible confirmation explicitly
requests the deletion challenge; the ready surface is for operations that had
to wait. Nonterminal status reads run the existing whole-operation readiness
evaluator before returning state, using the observed readiness generation.
Clear inputs may promote waiting to ready; blockers retain waiting and
unknown/incomplete inputs remain fail-closed. Existing demotion/generation
fences and the final transactional recheck remain authoritative.

**Truthful waiting.** A stored `waiting` phase is not evidence of an active
request. The public status result supplies no blocker reason, so its centered
modal says `Account deletion is on hold` / `Your account isn’t ready to delete
yet. We’ll let you know when you can continue.` Got It dismisses only;
Cancel Account Deletion uses authoritative cancellation. There is no close X.
The persistent row reads `Account Deletion` / `On hold`. Ready reconciliation
shows ready, not on hold; blocker clearance never automatically issues a code
or deletes the account.

**Verification and explicit deletion.** Waiting/ready permit ordinary app use.
The durable installation-local freeze/startup barrier begins immediately before
the first challenge request; identity replacement/removal is excluded while
any deletion record exists. Verification uses the deletion-specific six-digit
emailed challenge and backend expiry, cooldown and attempt authority, not
ordinary signup-verification assumptions. The code screen shows the full
recipient email; resend is a secondary button with an explicit backend-deadline
countdown independent of six-digit input validity. An initial send failure
shows `Code couldn’t be sent`, not a sent-code/input claim. Redeeming a code
does not delete: the separate final confirmation says `Delete your account?`
/ `Your identity is verified. Deleting your account can’t be undone.`, with
explicit destructive Delete Account and Cancel actions. Leaving or relaunching
unfinished verification authoritatively cancels it; failed cancellation keeps
the freeze. This never cancels unresolved completion or pending cleanup.

**Completion and recovery.** Before final transmission, protected storage binds
the opaque recovery capability to the exact operation, initiating Participant,
trusted namespace and installation. Lost final responses retain it only while
the outcome is unresolved and reconcile through backend recovery, never an
automatic final-mutation retry or inferred completion. Unavailable/expired
recovery stays fail-closed. On authoritative completion, fence the deleted
principal immediately and atomically replace the bearer record with the minimal
`completedCleanupPending` journal. It contains only operation/owner,
origin/ledger/namespace and installation binding, not email, credential, payload,
code or capability digest. If replacement fails, attempt checked bearer removal
and keep the independent freeze with an explicit cleanup error. A known-completed
journal resumes local cleanup without network, including after receipt expiry.

**Checked cleanup and isolation.** Cleanup requires both exact Participant
identity and trusted provenance. Checked serialized removal covers proven
deleted-owner pending create/update/report records, credential/Keychain and
verified marker/presentation, drafts, cached private request/helper/claim state,
continuations, account-linked alert presentation and deletion context. Preserve
foreign survivors, unknown fields, order and multiplicity. Foreign, legacy,
opaque, email-only or otherwise unprovable recovery bytes are not guessed,
replayed or erased; retain unprovable state unavailable, with gates surviving
O1/relaunch/reverification. This is not an all-local-bytes-erased promise.
Storage failure blocks completion/handoff. Retire stale generations, callbacks,
private presentation and queued notification intents rather than relying on
cancellation or eventual identity observation alone. Completed-deletion cleanup
removes only the exact journal Participant's first-request guidance digest
(section 1.7), preserving other Participants' digests; an unreadable ledger
fails cleanup closed without erasure. P2's generation retirement and the
ledger's current-authority check prevent a stale Success callback from
recreating it. If a different Participant
is encountered defensively, retire only the deleted context: preserve the other
credential, onboarding and navigation, with no root reset or deleted-account
completion shown as that Participant's result.

**Notifications, installation and O1.** Persist a checked, monotonic local
notification navigation cutoff during completed cleanup and independently fence
captured/queued notification intents, including the foreign-Participant path.
Deliveries at or before the cutoff cannot navigate; later deliveries remain
routable. Do not indiscriminately remove delivered OS notifications whose owner
cannot be proven. Preserve installation credentials, APNs token/environment,
OS authorization, API configuration and generic device preferences. For the
deleted account's ordinary completion path, verify capability absence and
required cleanup, perform the existing checked O1 reset (first-use completion
false, discovery cleared), remove the matching pre-send freeze and remove the
cleanup journal last. Only then show `Account deleted` / `Thanks for being part
of CommonPlate. Your account and history have been deleted.` with Done and no
Share Feedback action. Done publishes the existing O1 Welcome / How CommonPlate
Works handoff. No cleanup occurs merely because deletion was requested or
authorized.

## 31. Accepted dormant recipient-owned unread backend (W4-MSG1 CP7-A)

Faith accepted CP7-A on 2026-10-27 as a **dormant backend capability**
(implementation commit `fdb0a7f`). It is not shipping behavior: the CP7-A route
paths and handlers are not imported or mounted by `app.ts`, shipping iOS
messaging is not activated, and live two-account messaging has not been
qualified. Mounting and lifecycle ownership remain INF1/later-checkpoint work.
CP1–CP6 guarantees (authorization, conversation isolation, lifecycle, moderation
and deletion access) are unchanged; later CP7-B–F behavior is not accepted
runtime truth.

**Source surfaces.** `src/messaging.ts`: `open`, `acknowledgeDisplayed`,
`unreadCounts` and `MAX_UNREAD_CONVERSATIONS` (100). `src/messagingRoutes.ts`:
path constants `MESSAGE_READ_ACK_ROUTE_PATH`
(`/api/request/:id/conversation/:conversationId/read`) and
`MESSAGE_UNREAD_COUNT_ROUTE_PATH` (`/api/participant/messaging/unread-count`),
and the `acknowledgeDisplayed` / `unreadCounts` handlers from
`createMessagingHandlers`, whose acknowledgement body is a strict
`{ displayedSequences: positive safe integers, at most 100 }`. No HTTP method or
production registration is defined or accepted yet.

**Read state.** Read state belongs to the authenticated recipient and is
independent of installation. It is stored per message as a hidden `readAt`
(`select: false` in `models/messaging.ts`), is never selected into responses, and
no Seen/read receipt or any sender-visible read information exists. Unread
supporting indexes: `{conversationId, senderParticipantId, readAt}`,
`{requesterParticipantId, closedAt}`, `{helperParticipantId, closedAt}`.

**Opening.** `open` (through the existing protected operation) returns
`openingSnapshotSequence` (the conversation's sequence at that transaction) and
marks only the recipient's incoming messages with sequence at or below it as
read. Later messages are not read by opening.

**Explicit acknowledgement.** `acknowledgeDisplayed` takes the displayed incoming
sequences for one exact conversation, de-duplicates them, and runs inside the
existing `protectedOperation` fences (revocation, Block, replacement, pickup,
suspension and deletion are honored). Every distinct sequence must be an existing
incoming message of that conversation at or below its current sequence; any
unknown, foreign-conversation, own-message or not-yet-existing reference rejects
the whole batch as `invalid` with nothing marked read. Replaying an accepted
acknowledgement is idempotent (`acknowledgedCount` counts only newly marked
messages). Duplicates within a valid batch are harmless; an empty batch marks
nothing. Gaps and undisplayed newer messages are never marked read.

**Unread counts.** `unreadCounts` is a read-only point-in-time projection: one
snapshot transaction with no write of block fences, request versions, leases or
closures. It verifies the signed participant authority and the Participant's
current authority version, then reads the actor's open (`closedAt: null`)
conversations. If more than `MAX_UNREAD_CONVERSATIONS` (100) are open it fails
closed as `unavailable` rather than returning a partial total. Each conversation
with unread messages is re-checked against its Request (same requester, current
placed helper, `relationshipAllowed` policy at that instant); closed,
inaccessible, ineligible, replaced-helper or stale conversations contribute
nothing, and no conversation's count leaks into another. The result
`{ unreadCount, conversations: [{ requestId, conversationId, unreadCount }] }` is
a snapshot that can change immediately; it is not a delivery or notification
signal and does not close ineligible conversations (lifecycle writers do).

Message Notifications preferences remain a later, device-specific CP7-D/E
decision; CP7-A adds no notification, preference, push or navigation behavior.
Verification qualifications are in `docs/testing.md`.

## 32. Accepted dormant iOS read/unread experience (W4-MSG1 CP7-B)

Faith accepted CP7-B on 2026-10-27 as a **dormant iOS capability** (implementation
commit `0429a81`). Shipping messaging remains disabled (`.dormant`
composition, nothing mounted by `ContentView`/shipping composition), live HTTP
routes are not activated, the existing `mailto:` contact actions remain, and live
two-account communication has not been demonstrated. Behavior is exercised only by
injected/scripted composition and the Debug preview.

**Wire.** `ConversationOpenDTO` requires exactly `conversationId` (object id) and
`openingSnapshotSequence` (integer 0...`MessagingWire.maxSequence`); missing,
extra, malformed, fractional, negative, oversize or non-numeric fields are
rejected. `ConversationReadAckDTO` (`conversationId`, `acknowledgedCount` 0...100)
and `MessagingUnreadSummaryDTO` (at most 100 entries, no duplicate conversation,
positive per-entry counts, `unreadCount` equal to the sum) are equally strict. The
client's `acknowledge` requires 1...100 distinct positive sequences, binds the
response to the exact conversation, and treats a count above the batch size as
unknown. In `unreadSummary`, `unavailable` (which the server also returns for its
fail-closed cap) is a failure, never a closure.

**Read acknowledgement.** Opening a conversation relies on the server marking
messages at or below `openingSnapshotSequence` read; the client does not
re-acknowledge them. `ConversationCoordinator.messagesDidDisplay` submits only
server-confirmed incoming messages above the snapshot that the screen reports as
displayed (a row at least half visible after a dwell, in an active scene, not
while the viewport is settling), never own, local, prefetched or offscreen
messages. Batches hold at most 100 and one is in flight at a time. A failed or
ambiguous acknowledgement is not treated as read and is never retried on a timer;
a later genuine display event may resubmit. Valid duplicates are harmless.
Closure, rejection or lost authority end the coordinator as before. There are no
Seen labels or sender-visible read receipts.

**Unread state.** `MessagingUnreadStore` is MSG1-owned, in-memory only and holds no
message content. Counts are keyed by exact (request, conversation) and refreshed
only on authorized events (entry appearance, scene active, acknowledgement,
leaving a conversation); there is no polling. Unknown is never fabricated as zero;
absence means zero only in a current (non-stale) snapshot. More than one entry for
one request is unknown. After a refresh failure the last count is retained marked
stale only while its authority remains valid. Responses are fenced by generation,
credential fingerprint (never the raw credential), fetch serial and a per-request
invalidation clock, so delayed responses cannot repopulate cleared or invalidated
state. A different or missing credential is remembered (A→B→A does not restore A's
counts); closure, Block, authority rejection or required authority invalidate or
clear it; opening and acknowledging invalidate the request until the next
authoritative fetch. `RequestUnreadLookup` is a read-only request-to-count
lookup (unknown or known(count, isStale)) reserved for a later UI1 Home handoff.

**Chat entry.** In `RequestConversationEntryRow` a trailing capsule shows the
count 1...99 or `99+`, is hidden for zero or unknown, and the button's
accessibility label reads "…, N unread message(s)" ("More than 99 unread
messages" above the cap). It does not clip at the largest accessibility size, and
eligibility, role and navigation are unchanged. A suppressed relationship renders
nothing and fetches nothing.

**Not part of CP7-B.** Home-card unread indicators (UI1-HOME-UNREAD), app-icon
badges, message notifications, Settings, and deletion minimization are not
implemented. Remaining obligations: INF1 must explicitly call `unread.clearAll()`
at sign-out and identity replacement, compose the live messaging composition,
install routes and lifecycle, verify the conversation-opening HTTP method, and
prove live identity/revocation behavior. Reviewer hardening notes (non-blocking):
re-check the generation after credential validation in `MessagingUnreadStore`'s
`finish`, and consider invalidating a request's unread state when
`isSuppressed` becomes true. Verification limits are in `docs/testing.md`.
