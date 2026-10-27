# GoodGrub verification guide

> **Reading note for contributors.** This guide is both the verification
> reference and a record of accepted baselines. Labels such as `CP1`, `CP7-B`,
> `W4-MSG1`, `P2`, `N1` and `UI1` are internal checkpoint/slice names from the
> project's development history; they identify an accepted increment and are not
> needed to run any command. "The project owner" is the maintainer who accepts
> work. Evidence paths for earlier runs were local, ephemeral artifacts that are
> not retained and are not prerequisites; to reproduce a result, run the command
> in the relevant section. Commands, prerequisites, resource preflights and the
> stated limitations apply unchanged.

## Accepted W4-UI1 CP1 onboarding and verification baseline (2026-10-24)

The project owner explicitly accepted CP1 after approving the physical UX and completing
the independent correctness and four-perspective quality reviews. The exact
verified candidate is committed as `b8a677e`, based on `cb494c5`; runtime truth
is in `docs/system-contract.md` section 1.6. Bounded quality corrections
improved source-guard resilience, shared hosted captures, teardown, semantic
motion checks and comment/proof accuracy without changing approved runtime UX.

**Automated:** final focused eight-class CP1/identity/branding/copy/hierarchy
bundle: **108 passed, 0 failed, 0 skipped**. Complete `CommonPlateiosTests`:
**3,010 passed, 0 failed, 2 configuration-skipped**, serial simulator runs.
Results were local `.xcresult` bundles (not retained). Hosted Light/Dark captures
are labeled XCTest attachments, not full-app navigation or live-mail proof.
The capture harness uses bounded render settling and fractional scroll
positions; those positions do not prove a particular card is visible.

The unchanged `src/createRequestRoute.test.ts` passed **241/241 twice** after
an environmental dependency-read stall was resolved. Node worker sampling
and an independent filesystem read both stalled in the candidate's Mongoose
files; restoring the identical installed Mongoose 8.19.3 package resolved it.
No assertion, manifest, lockfile or backend implementation changed. The exact
filesystem cause remains unproven; the stalled package was preserved.

**Isolated API:** disposable local QA passed issuance (202), same-address
cooldown (429), retry (202), local mail-sink retrieval and redemption (200).
No production database or real provider was used. **Physical:** The project owner
reported the revised installed signed Debug iPhone walkthrough passed.
Hosted/stubbed store reconstruction does not establish persistent Keychain
relaunch or real email delivery. **Unverified:** real-provider delivery and
Release/Archive/distribution qualification remain explicit limitations.

Local integration onto `c6b2299` preserves all twelve accepted CP1 source/test
files byte-for-byte and the newer N1, CP3, CP3 retrospective and P2 backend
changes. No overlapping file or behavior was resolved by editing; the
acceptance proof is retained rather than rerun, as the project owner authorized.
No complete backend/Mongo suite was required for CP1's iOS-only changes.
This is not a new combined-main full-regression or release qualification.

## Accepted W4-UI1 CP3 requester baseline (2026-10-24)

CP3's accepted candidate is based on local `main` `2e354cb` plus its requester
changes; the project owner authorized committing it directly on local `main`. The integration
changes no accepted source/test bytes and requires no new regression run.
The project owner's physical requester UX approval and the completed fresh
independent technical-debt/UI-abstraction review stand. The review found no
required production correction or material CP3-introduced maintainability
risk; broad view decomposition/speculative abstraction is deferred. No
production/test source changed during final gate reconciliation. Accepted
runtime truth is in `docs/system-contract.md` sections 13 and 14.2.

**Final automated proof.** Focused and affected-neighbor iOS: **180 passed,
0 failures** (`RequesterIncompleteVsInvalidHostedTests`,
`RequestIncompleteVsInvalidValidationTests`,
`RequesterMealPresentationHostedTests`, `RequestCreationViewTests`,
`RequesterWalkthroughCorrectionTests`). Complete `CommonPlateiosTests`:
**2,996 reported, 2,994 passed, 2 configuration-skipped, 0 failures,
TEST SUCCEEDED**. The skips are optional owner review exporters requiring
`R5_SNAPSHOT_DIR`, not skipped behavior being counted as passes. Result:
a maintainer-local `.xcresult` bundle (not distributed with the repository);
command was the section 9 full-target command on simulator
`8E810D50-5729-4F0A-955D-2C1531EAFA41`, with parallel testing disabled.
This result remains valid: the new evidence exporter exists only in an
isolated snapshot, not in the accepted production/test candidate.

`npm run typecheck` passed. Focused
`npm test -- src/createRequestRoute.test.ts scripts/local-mail-sink.test.ts`
passed **264/264**, including all 241 requester route/production-copy tests.
Final official **`npm test`**, unchanged and without exclusions, passed
**3,776 tests, 1,150 configuration-skipped, 0 failures** (121 passing files,
58 skipped files) in the isolated source-equivalent candidate described
below. No persistence change was made; Mongo was not rerun, and the skips do
not establish persistence proof.

**Isolated official backend procedure and diagnosis.** Default Vitest
discovery in the main working directory also found ignored
`dist/models/db.test.js` (July 30), an obsolete compiled three-status schema
assertion, alongside newer compiled model output containing `withdrawn`.
The unfiltered main-directory run failed that stale assertion and one
mail-sink timeout; the mail case and production-copy scan passed unchanged
on focused rerun. Two serialized attempts stalled before results and were
stopped. An earlier source-excluding diagnostic was not treated as the gate.

For the final official run, copied all currently tracked working files
(**not just HEAD**) and CP3's new untracked test into a session-local
candidate, with the installed `node_modules` symlinked read-only by convention;
no install or dependency changes occurred. The snapshot contained no old
ignored `dist/`, `.env` or repository Git metadata. All **793 tracked files**
were SHA-256 byte-compared with the live candidate, with zero mismatches;
the new untracked CP3 test also matched. Ran the exact **`npm test`** there,
without filters, timeout changes or assertions changed. The main `dist/`
directory and all unrelated work remained untouched. This is a clean-source
official suite pass, not a claim the contaminated main-directory command now
passes. General build-output hygiene remains outside CP3.

Snapshot: a maintainer-local isolated copy (not distributed with the
repository). Official output: a temporary local log file, not retained.

**Mandatory missing error evidence — now captured.** The real production
`RequestFoodView` was mounted on an iOS simulator with shipping Screenshot
Assistance availability and in-memory identity/draft/operation stores.
URLProtocol intercepted every request; no live failure, email, Push,
provider order or production mutation was induced. After a valid draft's
explicit Post, fixture responses drove production submission/catch/recovery
paths, not a static reconstruction of the screen. Assertions established
exactly one create attempt, no unresolved ambiguity, unchanged draft, and
Review draft returning to the form without another create. Expired authority
was discarded; temporary verification unavailability retained identity.

Every stem below has matching `light/<stem>.png` and `dark/<stem>.png`:

| Mandatory state / trigger | Screenshot stem |
| --- | --- |
| Availability read returns `paused: true`; no fields/Post | `posting-paused-entry` |
| Availability read returns 503; retryable unknown, not revoked identity | `availability-check-unavailable-retry` |
| Explicit Post receives 429 `RATE_LIMITED`; saved-draft summary | `posting-rate-limited-saved-draft` |
| Explicit Post receives 400 `INVALID_REQUEST`; saved-draft summary | `posting-invalid-request-saved-draft` |
| Explicit Post receives 503 `PUBLIC_ACTIONS_PAUSED`; saved-draft summary | `posting-paused-saved-draft` |
| Explicit Post receives 422 `REQUEST_TEXT_NOT_ALLOWED`; editable form notice | `moderation-refusal-editable-draft` |
| Explicit Post receives 401 `PARTICIPANT_VERIFICATION_REQUIRED` | `posting-verification-required` |
| Explicit Post receives 403 `PARTICIPANT_AUTHORITY_INVALID` | `posting-authority-expired` |
| Explicit Post receives 503 `PARTICIPANT_VERIFICATION_UNAVAILABLE` | `posting-verification-check-unavailable` |
| Nonblank Details, empty meal name; final correction prompt/Post disabled | `meal-details-without-item-name` |

All **20 PNGs** (10 per appearance, 1206×2622) and the ZIP contents/CRC were
checked. Hosted capture is real rendered-view evidence, not a full-app
navigation/system-chrome screenshot, physical VoiceOver qualification or live
backend proof. The isolated exporter
`CP3AcceptanceEvidenceTests.testCaptureMandatoryLightAndDarkStatesThroughProductionForm`
passed with zero failures; result `CP3AcceptanceEvidence.xcresult` in the
same session's local files (not retained) with a local log.
Its test source is retained in the snapshot for reproducibility; it is not
added to the repository target.

Evidence directory: maintainer-local, not distributed with the repository.
ZIP: maintainer-local, not distributed
(only `light/` and `dark/`; SHA-256
`ad6bd20cb7f79b4a862330cbd4b22affcd01ac2cd4587f05c511156fb7ba72e0`).
Historical discovery and the 46-image corrections-v2 package are preserved,
not replaced. That older ZIP predates the final details-only prompt; the new
package supplies current proof for it.

**Optional/not-applicable coverage, not waived mandatory evidence.** A
principal-mismatch duplicate is optional because it renders the same
expired-verification message and recovery controls (copy equivalence also
asserted). Duplicate transport causes/error codes with identical UI and live
service failure induction are optional audit coverage. Screenshot Assistance
errors are unreachable in the shipping requester configuration; no fabricated
screens are required. Actual software-keyboard Light/Dark full-app captures
and the project owner's physical walkthrough remain the keyboard proof; hosted captures
do not replace them. Physical VoiceOver/largest Dynamic Type and separately
instrumented outside-tap/swipe observations were not added by this closeout.

**Grubhub is deferred, not delivered.** The project owner moved the requester shortcut to
a follow-up slice. All Release requester links remain hidden; the existing
explicit local Debug QA gate and strict N1 mappings are unchanged. Only
historical Dunkin' Meal Exchange content proof exists; the other 19 mappings
and populated-draft preservation after real external return are follow-up
release-enablement dependencies, not CP3 acceptance gates. HTTP loading shells
and the existing helper-only unit test do not establish that proof.

## Accepted W4-UI1 CP2 Home, first-request guidance and verification baseline (2026-10-26)

The project owner explicitly accepted CP2 after its four quality-review perspectives, a
fresh independent risk review of the first-request ledger/P2 deletion
integration (no findings), and her interactive Simulator walkthrough. The
candidate was selectively reconciled onto P2-integrated local main
(`5f87b7a`, containing P2 `f5ee910`) on branch `w4-ui1-cp2-p2-reconciled`.
Runtime truth is in `docs/system-contract.md` sections 1.7, 6.4, 13, 14, 24
and 30.1. The requester Grubhub item in CP3's record above is superseded.

**Automated.** Complete `CommonPlateiosTests` on the final candidate:
**3,137 reported, 3,135 passed, 2 configuration-skipped, 0 failures, TEST
SUCCEEDED** (Xcode 26.6, iPhone 17 / iOS 26.5 Simulator; local
`.xcresult` bundle, not retained). The skips are the
optional snapshot writers requiring `R5_SNAPSHOT_DIR`. Focused classes include
`CP2FirstRequestGuidanceTests` (once per Participant, digest-only storage,
persistence across a reconstructed ledger over the same defaults rather than a
real app relaunch, non-canonical authority, malformed ledger, stale-generation
fence, record-on-finish) and `ParticipantDeletionCleanupTests` (exact-owner
marker removal, foreign-marker preservation with deleted-callback rejection,
unreadable/malformed ledger blocking cleanup without erasure), plus
`CP2VerificationResendCountdownTests`,
`CP2VerificationActionHierarchyHostedTests`, `ParticipantIdentityTests`,
`ParticipantVerificationHierarchyTests`, `UI1WelcomeMotionTests` and
`UI1WelcomeScrollCueHostedTests`. The final resend/error/identity bundle passed
**41/41**; the post-review ledger/deletion bundle passed **21/21**. The
unchanged `src/createRequestRoute.test.ts` copy guard passed **241/241** after
a lockfile-exact isolated `npm ci` restored Mongoose 8.19.3; no manifest,
lockfile or assertion changed. `git diff --check` passed. CP2 changes no
backend source, so no `npm test`/Mongo rerun was required.

**Known test fragility, not a CP2 defect.** One earlier full-target run failed
`HomeRefreshSettleHostedMotionTests` on timing; its first sampled frame depends
on the host app's Welcome animation. It passed independently and in the final
complete run. The W4-H3 owner should harden it; assertions were not weakened.

**Hosted and Simulator evidence.** Labeled Light/Dark hosted captures (stubbed
fixtures, not live-backend proof) of first and later Success, code-entry
countdown and the unavailable-error state are in the ignored local package
a maintainer-local ZIP
(not committed). The project owner walked through the Debug build on a dedicated iPhone 17
Simulator against an isolated W4-QA1 backend and local mail sink: live code
issuance and redemption, the resend countdown, Home with the `helper-board`
preset, and first then later posts. She approved it.

**Manual.** The project owner verified on their own that all 20 requester Grubhub
destinations open the correct restaurant/menu and that returning preserves the
populated draft. No agent-observed device evidence exists for this.

**Accepted limitations.** The project owner waived the targeted physical-iPhone check for
CP2 only: physical scrolling, touch, motion, Home-arrow animation on device and
real email delivery are unverified. Hosted Home-arrow motion is Simulator
XCTest evidence. Only the late-night clock state of the 704 pt
`RequesterMealPresentationHostedTests` viewport executed. Release, Archive and
TestFlight behavior is not established. The waiver does not apply to A1 or RC1.

## Accepted W4-P2 Checkpoint 8 baseline (2026-10-24)

The project owner accepted Checkpoint 8 (irreversible deletion backend, completion
recovery and public backend surface) on 2026-10-24. This acceptance covers the
backend scope only; it does not establish Checkpoint 9, iOS activation,
physical-device/environmental erasure, provider delivery, deployment or full
W4-P2 acceptance.

**Final automated proof on the accepted candidate:** `npm run typecheck`
passed; focused recovery and receipt-sweep tests passed **6/6**; complete
serialized **`npm test -- --no-file-parallelism`** passed **3,941**, with
**1,314 Mongo/configuration-gated skips** and no failures. The full
real-replica-set command **`VITEST_MAX_WORKERS=1 npm run test:mongo`** passed
**1,303**, with **11 activation-gated skips** and no failures. `git diff
--check` passed. The one-worker Mongo invocation avoids host-load timeouts
observed with parallel workers; this accepted run completed without relaxing
test timeouts or selecting subsets.

The Mongo suite requires the configured local replica-set harness and runs
the complete Mongo-gated suite; it is not replaced by the non-Mongo skips.
These automated backend results do not prove iOS presentation, physical-device
behavior, environmental erasure, provider delivery, deployment or release
qualification. No Checkpoint-9 or simulator/device proof is claimed here.
Fresh independent HIGH-risk review was **CLEAN** with no high-confidence
findings.

## Accepted W4-P2 Checkpoint 9 and full-slice baseline (2026-10-26)

The project owner explicitly accepted CP9 and completed W4-P2: **9/9 checkpoints
accepted**, committed as `e9809fe`. This extends the historical CP8 backend-only
baseline above; runtime truth is in `docs/system-contract.md` section 30.
Evidence is for the accepted candidate on `w4-p2-cp8-n1-reconciled`, based on
`e6d0060`, not a combined-current-main or release qualification.

**Final qualifying automated evidence:** `npm run typecheck` passed.
Complete serialized `npm test -- --no-file-parallelism`: **3,975 passed,
1,348 Mongo/configuration-gated skips, 0 failed**. Complete official
`npm run test:mongo`, using its own disposable real replica set:
**1,337 passed, 11 configuration-gated skips, 0 failed**. Complete final
post-review-fix `CommonPlateiosTests`: **3,078 passed, 0 failed, 2 optional
snapshot-exporter skips** (`testWriteDarkReviewSnapshotsWhenRequested` and
`testWriteReviewSnapshotsWhenRequested`). These skips are not passed behavior.
Focused deletion lifecycle/companion/cleanup/storage-failure proof after the
review fixes: **88 passed, 0 skipped**. Earlier unchanged backend attempts had
nine non-Mongo timing/scheduler failures and three Mongo startup timeouts;
complete unchanged reruns passed without relaxing assertions or timeouts.
Backend source remained hash-identical through the final iOS fixes.

**Independent HIGH-risk review:** final candidate **CLEAN** after two
foreign-account preservation findings were fixed and independently re-reviewed:
always fence captured notification intents even when another identity is
present; never reset that other identity's root navigation during deleted-owner
cleanup. Automated coverage uses the real isolated notification router and a
checked-cleanup failure/retry case.

**Manual evidence and accepted limitations:** The project owner reported simulator normal
deletion, post-deletion chooser, rejoining, and active-request entry blocker
Keep My Account / Go to Request passes. These are user-observed simulator
results, not physical-device or independently inspected erasure evidence.
The project owner explicitly waived the remaining physical-device/manual scenarios as
CP9/full-P2 acceptance gates. They remain **NOT VERIFIED**, retained for release
qualification: physical Keychain/locked-storage, notification/deep-link
delivery, installation-state preservation, relaunch/recovery, cleanup/isolation
and same-email recreation; and unfinished simulator persisted-waiting/Got It/
cancellation/blocker-clearance and lost-final-response walkthroughs. Stubbed/
automated recovery is not an end-to-end lost-response pass. Local challenge
capture is not real-provider delivery. The waiver does not close other slices'
or release/environment gates.

**Lint baseline limitation:** `npm run lint` reports **3 errors and 12
warnings**. All three error-bearing files are byte-identical to CP8 HEAD:
`src/messagingHistory.mongo.test.ts:299` (`no-constant-condition`),
`src/moderatorAuth.ts:34` (`no-namespace`) and
`src/participantVerificationRoute.test.ts:99` (`prefer-const`). These are
unchanged CP8-baseline errors, not CP9 regressions; lint is not recorded as
passed. Cleanup belongs to the testing/owning lanes.

Local evidence (typecheck, serial backend, Mongo rerun, focused and full iOS
results, lint) was kept as local logs and `.xcresult` bundles that are not
retained and are not prerequisites for a fresh clone. This documentation-only acceptance sync does not invalidate
the qualified runtime/test bytes or require another complete regression.

### Isolated P2 integration qualification (2026-10-26)

Candidate: `w4-p2-main-integration-496f81b`, committed main `496f81b` plus
the uncommitted no-fast-forward merge of `e9809fe` and
`ParticipantDeletionVerificationIntegrationTests.swift`. The sole source
conflict retains both CP1 confirmed-send tracking and P2 deletion guards.
Four new regressions cover the cooldown shortcut, deletion-hold identity
preservation, freeze/reset and late send/redemption responses. All 59
P2-only paths and 20 newer-main-only paths retain their respective parent
bytes. Dirty main UI1/first-request-guidance and moderation work is excluded.

**Final automated evidence:** typecheck passed; focused backend route,
namespace, mail-sink and create-request/copy guards **323 passed**; complete
serialized non-Mongo **3,975 passed, 1,363 configuration skips**. Complete
official disposable-replica-set Mongo **1,352 passed, 11 configuration
skips**, including all 15 newer-main messaging/deletion-access cases.
Complete serial `CommonPlateiosTests` on a dedicated iPhone 17 / iOS 26.5
simulator: **3,111 passed, 2 optional snapshot-exporter skips, 0 failed,
TEST SUCCEEDED**. All 49 extant focused deletion/identity/verification/
onboarding/block/report/push/navigation classes passed **593 tests** in that
final full run. Separate requester neighbors passed **511 RequesterCore,
80 HostedRequesterUI and 7 CP3 correction tests**, no skips or failures.
The stale `TapAuthorityFenceTests` routing-manifest name is not an executed
class or claimed evidence.

**Earlier attempts, not passes:** the first focused iOS run had one hosted
accessibility-frame lookup failure; the unchanged case passed alone and in
the complete target. One requester build stopped on an entitlement-input
modification error; its source was verified byte-identical to main, and
the unchanged retry passed without bypassing entitlement checks. The first
Mongo attempt had two test timeouts, a startup deadline failure and a
worker-start timeout during prolonged filesystem reads. The second reached
every suite but failed the unchanged Atlas probe CLI-interruption cleanup
assertion. An instrumented unchanged CLI reproduction removed its server and
directory within 1.58 seconds; the intermittent cause remains unproven.
The final complete Mongo run passed without changing source, assertions,
timeouts, selectors or the official runner. These earlier failures are not
reclassified as passed evidence.

`git diff --check` and staged whitespace checks passed. This is isolated
combined-tree qualification, not merge-back, deployment, physical-device
proof or qualification of dirty UI1/moderation work. The accepted P2
physical/manual waivers and unchanged CP8 lint limitation above remain.

**Independent integration review:** **CLEAN**. The bounded read-only review
inspected both-parent preservation, identity reconciliation and regressions,
root/navigation, stale callbacks, cleanup/provenance, notification fences,
MSG1 access, documentation and exclusions. It inspected the qualifying logs
and per-class evidence without rerunning suites or changing the candidate.
No integration defect or additional product decision was identified.

## Accepted W4-N1 Increment B baseline (2026-10-24)

**Local integration closeout:** N1B is committed as `a227536` and
fast-forwarded from `e039d60` into local `main`, without runtime/test changes,
conflicts or a stash. Post-integration `npm run typecheck` passed; the nine-file
N1 notification/placed-order/Installation-authority neighbor run passed all
251 tests, with no skips. An initial run had one Installation pause-test
timeout amid blocked filesystem/import reads; the identical rerun passed
without code, timeout or selector changes. `git diff --check` passed.
Earlier complete backend, replica-set and iOS evidence below is retained:
the fast-forward changed no accepted candidate bytes, so those suites and
physical gaps were not rerun. Unrelated, concurrently edited requester UI
files remained dirty on main and were excluded from N1 commits; this is not
qualification of that UI work. Full W4-N1 is COMMITTED locally; no push or
deployment occurred.

**Physical-proof correction and restored acceptance:** The project owner accepted the
candidate again on 2026-10-24 after the subtitle fix and follow-up. The earlier
blanket physical pass is superseded by these actual observations: mixed-resource
closing-subtitle presentation, discovery tap, background requester order tap,
and helper pickup-confirmed receipt/Home tap passed on the iPhone. Backend
inspection after T-15 found the claimed request still claimed with no closing
delivery; the earlier closing alert belonged to the older open fixture.
Foreground duplicate acknowledgement and terminal old-alert fallback were
not physically verified; the project owner explicitly accepts those gaps. Helper pickup
replay was not rerun in this physical follow-up; automated coverage is retained.
Force-quit notification launch lost the Debug launch-environment local API
override and could not reach QA: not a cold-launch pass. The project owner accepts that
Debug-only limitation without an N1 fix. Release uses bundled HTTPS configuration;
production-configured cold-launch device proof remains RC1-owned.

**Closing-subtitle follow-up proof:** focused payload/dispatcher/sweep neighbors
133 passed; `npm run typecheck` passed; full serialized
`npm test -- --no-file-parallelism` 3776 passed, 1150 skipped; final full
`npm run test:mongo` 1139 passed, 11 skipped. Earlier runs encountered
filesystem/import timeouts (including two Mongo startup failures); the
unchanged final reruns passed without relaxing timeouts or test selection.
Independent narrow review found no significant issues; `git diff --check`
passed. No iOS source/build change was needed. The owned local QA backend
was restarted and readiness checked. Physical results and accepted gaps are
recorded above. Acceptance alone did not authorize commit or integration;
The project owner separately authorized local Git closeout. Release remains unauthorized.

The project owner accepted the uncommitted `w4-n1-increment-b` candidate based on `e039d60`;
runtime truth is in `docs/system-contract.md` section 29. Final icon-catalog
and packaging-test candidate: complete `CommonPlateiosTests` **2946 passed,
2 skipped, 0 failed**, including **2/2** `AppIconPackagingTests`
(`N1B-runtime-master-clean-final.xcresult`, local session artifact). The
earlier timing-sensitive MSG1 long-history failure passed on the final complete
run without changes to messaging. Focused and affected-neighbor notification,
authority, Settings and routing evidence was followed by the complete target.

Unchanged backend proof: `npm run typecheck` passed; `npm test` **3776 passed,
1150 Mongo-gated skipped, 0 failed**; separate full replica-set
`npm run test:mongo` **1139 passed, 11 skipped, 0 failed**. Mongo-gated skips
in `npm test` are not persistence proof. Backend proof was preserved across
subsequent icon-only changes. Final `git diff --check` passed and independent
HIGH-risk review, including narrow final icon follow-ups, found no remaining
significant issues.

Build/package inspection: signed development Debug and unsigned generic
Release retain the unchanged approved 1024px runtime icon payload under normal
packaging. This is not signed distribution, Archive, App Store or TestFlight
qualification. No new verification commands or dependencies were introduced.

Physical evidence is limited to the corrected observations and accepted gaps
above, plus the previously accepted final notification icon. The withdrawn
blanket pass does not establish terminated routing, terminal fallback or
foreground duplicate suppression. Device observations are **user-reported
physical proof**, not agent-instrumented observation.
Direct APNs diagnostics establish presentation/transport only; separate
production discovery dispatch/replay evidence establishes provider acceptance
and dedup, not device delivery. Persistent-endpoint readiness and release
qualification remain IOS1/INF1/RC1 gates. Local Git closeout does not push,
deploy, activate MSG1, or retire transactional email.

## Accepted W4-MSG1 CP7-A baseline (2026-10-27)

Dormant backend (`docs/system-contract.md` section 31). Candidate based on
`b96ffcd` (source diff sha1 `71eb16ac36fa057754036e0e7a0623b4d5f72f2b`, new
`src/messagingUnread.test.ts` sha1 `5e1166b7d9e81be33a778be513d8e7e1b3c91ea2`),
committed unchanged as `fdb0a7f`. Observed passing evidence: focused messaging
**116/116**; typecheck, changed-file ESLint and `git diff --check` passed;
complete `npm test -- --no-file-parallelism` **4,025 passed, 1,388 Mongo-gated
skips, 0 failed**; complete serialized `VITEST_MAX_WORKERS=1 npm run test:mongo`
**1,377 passed, 11 configuration skips (`reviewRuntimeIntegration`), 0 failed**,
including the two former `requestOperationStartup` credential failures. An
independent HIGH-risk review reported no blocking findings.

**Host-compliance limitation:** both complete runs were performed below the
~1 GiB swap-headroom prerequisite (896 MiB at preflight, 790 MiB during the
Mongo run) under the project owner's explicit one-time exception. A later compliant-host
attempt was NOT RUN (swap 798-940 MiB). Compliant-host qualification remains
outstanding; this is observed passing evidence with a host-compliance
limitation, not an unconditional compliant baseline, and the threshold is
unchanged. Later main commit `1dc5c69` touches no messaging file (source
inspection only; not rerun). This is real-Mongo and injected evidence only: no
simulator, physical-device, live two-account or provider evidence exists.

**Pagination lint correction (separate, not CP7-A evidence).** The
`src/messagingHistory.mongo.test.ts` loop (previously `while (true)`, cited above
at line 299) is `while (page.hasOlder)` in `b96ffcd` with the same page walk and
assertions. On `d09dd52` plus that patch: complete serialized Mongo **1,359
passed, 11 skipped, 0 failed**; messaging history **55/55**;
`requestOperationStartup` **15/15**; typecheck, focused ESLint and diff check
passed. That run also used swap headroom of 1,028 MiB at start (792 MiB after).
The CP9 lint-baseline note above is a historical snapshot; this error no longer
exists in source.

## Accepted W4-MSG1 CP7-B baseline (2026-10-27)

Dormant iOS read/unread (`docs/system-contract.md` section 32), committed as
`0429a81` on `29b7e47` (main changes since the tested `b6c741c` were backend and
review-maintenance only; no iOS file, so iOS evidence was not rerun). Observed
passing evidence on the final source: `MessagingWireTests` +
`MessagingHTTPClientTests` **22/22**; new `MessagingUnreadStoreTests` **15**,
`MessagingReadAcknowledgementTests` **16**,
`RequestConversationEntryUnreadHostedTests` **4**; complete `CommonPlateiosTests`
**3,172 executed, 2 skipped, 0 failed**; `git diff --check` passed. An earlier
full run (before the identity fix) failed only the timing-sensitive
`HomeRefreshSettleHostedMotionTests` hold test, which passed in isolation
(8/8) and in the final full run. An independent HIGH-risk review found one
blocking issue (A→B→A identity switch restoring cached counts); it was fixed with
a regression test and a targeted rereview found no blocking findings.

Evidence is scripted/injected simulator only. It does not prove physical-device
scroll visibility or acknowledgement, production route mounting, APNs/provider
delivery, or live two-account messaging. The CP7-A compliant-host qualification
caveat above remains separate and unchanged.

## 1. Verification overview

| Type | Command | Purpose | Important limitation |
| --- | --- | --- | --- |
| TypeScript checking | `npm run typecheck` | Checks the TypeScript source and tests without emitting files. | It does not exercise runtime behavior. |
| Backend unit/source-wiring tests | `npm test` | Runs Vitest unit, browser-behavior, and source-wiring tests. | Mongo suites are skipped without their integration environment. |
| Mongo integration tests | `npm run test:mongo` | Runs the real-Mongo replica-set suites. | Requires local `mongod` and `mongosh`. |
| Local database qualification probe | `npm run probe:atlas-local` | Starts a throwaway authenticated loopback replica set and checks transaction commit/abort, the application's own `Model.createIndexes()` results (keys, uniqueness, names, TTL, partial filters) for production, dormant-messaging and review models, the `deploy/atlas/` runtime roles (allowed actions and expected denials) and pool configuration. Refuses any target that is not the harness it started. | Local proof only. It is not Atlas compatibility proof; the Atlas-only items it prints as NOT VERIFIED must run on the real cluster. Its pool check is a non-deterministic burst. |
| Browser bundle generation | `npm run build:client` | Rebuilds tracked browser bundles from client TypeScript. | A successful build does not decide whether bundle diffs are intended. |
| iOS tests | See [section 9](#9-complete-terminal-ios-test-command). | Builds and runs `CommonPlateiosTests` on a simulator. | Compilation alone is not a passing test run. |
| Diff validation | `git diff --check` | Detects whitespace errors in unstaged changes. | It does not establish behavioral correctness. |

### Verification tiers and post-fix invalidation

This subsection owns *how much* verification a change needs; sections 3–9 own the commands, section 11 owns the per-change-class matrix, and the routing manifests at the end of section 9 own the named test groups. It was introduced by W4-VP1 and is subject to the prospective transition rule at the end of this subsection.

**Tiers.**

| Tier | Name | What it is |
| --- | --- | --- |
| 1 | Focused | Tests and compile/typecheck that directly exercise the implementation change. |
| 2 | Affected-neighbor | Tests for the immediate producer/consumer, state, navigation, persistence, or accessibility neighbors the change can affect. |
| 3 | Change-type acceptance | The acceptance bundle section 11 requires for the actual change class, executed on the acceptance candidate. |
| 4 | Full regression/integration | The complete target(s), required by change class (triggers below), by an explicit slice contract, by broad blast radius, by cross-slice integration, or by a release checkpoint. |
| 5 | Post-fix | After a fix: rerun the direct and neighbor proof the fix invalidated, plus any still-mandatory final gate. Earlier full-run evidence for areas the fix did not touch is preserved, not mechanically rerun. |

Tiers 1–3 apply to every change that seeks acceptance. Tier 4 applies only when a trigger below, a section 11 tier-3 bundle, an explicit slice contract, or a release checkpoint requires it. Tier 5 applies whenever a change is made after any earlier tier's evidence exists. A tier-3 bundle that section 11 defines as the complete target is also tier 4.

**Full-regression triggers: complete iOS `CommonPlateiosTests`.** Required for:

- slices whose contract explicitly requires it;
- app root and global navigation/routing;
- app lifecycle and notification handoff;
- the shared `APIClient → RequestService → RequestStore` boundary (any edit to `APIClient`, `RequestService`, or `RequestStore` source, or to shared model types);
- identity, persistence, cache semantics, and shared models;
- project, scheme, dependency, and build-configuration changes;
- cross-stack contract changes as defined in section 11;
- cross-slice integration and release checkpoints;
- other broad or materially uncertain blast-radius changes.

**Full-regression triggers: complete backend `npm test`, plus `npm run test:mongo` when applicable.** Required for:

- `app.ts` startup/registration behavior;
- shared authentication, error (`src/day4Errors.ts`), and public-projection boundaries;
- Mongo persistence of any kind: schemas, indexes, migrations, transactions, uniqueness, lifecycle transitions, concurrency, and any change to a query, update, aggregation, or other code path exercised by a `*.mongo.test.ts` suite (these also require `npm run test:mongo`);
- credential, token, privacy-by-omission, and ambiguous-mutation boundaries recorded in `docs/system-contract.md`;
- shared cross-route contracts;
- notification/delivery infrastructure;
- dependency and runtime configuration;
- cross-stack changes and release checkpoints.

**Localized changes.** Localized SwiftUI layout, accessibility, copy, leaf presentation state (view-local `@State` or view models, never store state), isolated route validation/copy that does not touch persistence, credentials or tokens, response projection/allowlists, lifecycle transitions, or ambiguous-mutation handling, and test-only corrections confined to one test class or file (not a shared helper, fixture, or mock) may use tier 1–3 proof (focused plus affected-neighbor) *unless another trigger above or an explicit slice contract applies*. A trigger always wins over this exception. When it is genuinely unclear whether a change is localized, the blast radius is "materially uncertain" and tier 4 applies; do not resolve the doubt toward less testing. When no named group covers the affected area, tier 2 names the neighbor classes or files explicitly in the report; if no defensible neighbor set can be named, the blast radius is materially uncertain and tier 4 applies.

**Acceptance candidate.** Tier 3 and tier 4 evidence must be produced on the acceptance candidate: the exact tree proposed for acceptance, identified by commit or by a recorded `git status`/`git diff` state. The evidence must name the candidate it ran on, and a tree containing other uncommitted work must say what was mixed in. A later change to the candidate does not invalidate the evidence wholesale; it invalidates exactly what the post-fix rule below says it does. A slice that is required to pass a complete-target gate on its acceptance candidate must pass it on the *final* candidate, after its last change.

**Post-fix invalidation.** After any fix, including a review fix:

1. Identify the files and behavior the fix changed.
2. Rerun tier 1 for the fix.
3. Rerun the tier 2 neighbors and the tier 3 bundle components the fix could invalidate.
4. Rerun tier 4 when the fix itself meets a full-regression trigger, is not localized, or when a tier 4 gate is still mandatory for the final candidate (explicit slice contract, or a trigger that applied to the slice).
5. Otherwise preserve earlier tier 3 and tier 4 evidence for the unchanged areas, and say in the report which earlier run it was, what it covered, and what the fix touched.

Evidence is never carried across a change that could alter what it established. Skipping a rerun is a recorded decision with a reason, not a default.

**Evidence rules that do not change.**

- `-skip-testing` filters are never acceptance evidence. Only complete-target runs and explicit repeated `-only-testing:` runs count.
- Selective Mongo verification is not defined: `npm run test:mongo` runs the entire Mongo-gated suite (section 5) and is the only valid Mongo gate.
- Compilation alone is not a passing iOS result; reports distinguish tests executed, tests skipped by configuration, source inspection only, manual/physical verification, and behavior not yet verified (`AGENTS.md`).
- A focused run counts only if its output shows each named class or file executed with a non-zero test count; a filter naming a class that no longer exists can still report success. Report the executed count per group.
- Green results are never obtained by weakening, narrowing, or skipping required proof.

**Prospective transition (W4-VP1).** This policy is effective from the commit that lands it on `main` in canonical repository truth (record that commit hash in the W4-VP1 weekly-spec entry when it exists). It applies only to slices whose weekly-spec card records a *first READY transition* after that commit. Successor or split slices of a grandfathered slice inherit its grandfathered status unless Week HQ states otherwise. A slice that was already READY, ACTIVE, in VERIFY, or acceptance-pending when this policy landed keeps its original acceptance-proof obligations, including for every subsequent fix: the rule in force before this policy, which is the complete grandfathered table at the end of section 11 (including "iOS production or test change" and "Backend TypeScript only"), plus whatever its own weekly-spec card states. In particular, W4-H3 and W4-U1.1 still require their explicitly contracted complete `CommonPlateiosTests` acceptance gate; nothing here reduces it, and neither slice may use tier 5 to avoid rerunning that gate on its final candidate. Work with no weekly-spec card recording a first READY transition after that commit is treated as grandfathered. When it is unclear whether a slice is grandfathered, it is: the stricter rule applies until Week HQ states otherwise.

## 2. Node and dependency setup

Use Node.js **24.13.0** and npm **11.6.2** for the INF1 reproducible
installation baseline. Those exact versions have been exercised locally;
Linux host qualification remains separate from local macOS verification.
The repository does not enforce tool versions through `package.json`.

Install the locked dependencies in a clean checkout with:

```bash
npm ci --no-audit --no-fund
```

Use `npm install --package-lock-only --ignore-scripts --no-audit --no-fund`
only when intentionally repairing/updating the lockfile, then inspect its
diff and repeat `npm ci`. Do not use `--legacy-peer-deps`, omit optional
packages, or borrow another worktree's `node_modules` to bypass a failed
clean install.

For an immutable production artifact, run `scripts/build-release-artifact.sh
[commit]` (requires Docker). It builds from `git archive` of one committed
revision (never the working tree; uncommitted changes are excluded and a dirty
tree produces a warning) inside the `node:24.22.0-bookworm` linux/amd64 image
pinned by index digest, with npm 11.6.2 installed at build time, runs `npm ci`, `npm run typecheck`, `tsc`,
and a committed-client-bundle drift check, stages `dist/`, `public/` (no source
maps), `shared/vendors.json`, `package.json`, `package-lock.json`, `RELEASE.json`
and the two deployment health-check scripts under `scripts/`, then runs
`npm ci --omit=dev --no-audit --no-fund` there with lifecycle scripts enabled
and the lockfile checksum unchanged. The archive is deterministic (sorted,
root-owned, commit-time mtimes, `gzip -n`), which removes known sources of
nondeterminism. Repeat-build equivalence has been observed (two builds of
commit `e5b2f11293e3` gave the same SHA-256 `5a0bb82e...047c`, byte-identical;
same machine) but is not guaranteed: the image digest pins
only the base image, while the npm registry, the npm self-install and
dependency lifecycle scripts remain external inputs. Compare digests across
rebuilds rather than assuming them. The script prints the full source commit,
and the local branches containing it; provenance records the image digest and
image ID, toolchain versions and source ref. Before success it verifies required entries; absence of `.env`,
keys, tests, source maps, planning/docs/iOS content and development dependencies;
that every bare and relative import in shipped JS resolves from a fresh
extraction; and the fail-closed startup refusal against an unreachable database
with dummy credentials. That refusal smoke test does not establish production
Atlas connectivity, readiness, or a successful deployment. Output (`release-artifacts/`, ignored): `.tgz`, `.sha256`, and
`.provenance.json`. The script verifies the artifact only; it does not run the
test suites. Run the required tests on the same commit first. Deployment-host
verification (digest check on the host, extraction, readiness before switching
releases) remains a separate step. The host never runs `npm install` against
an active release or builds under the service account. Do not ship macOS
`node_modules`.

Configure local runtime values by copying `.env.example` to an untracked `.env` and replacing placeholders with local development values. Never copy secrets, real URIs, or personal values into tracked files.

For app startup, the configured MongoDB deployment must support transactions; a local single-member replica set is sufficient. The test runner itself does not require app startup.

## 3. TypeScript checking

Run:

```bash
npm run typecheck
```

This runs `tsc -p tsconfig.typecheck.json`. That configuration checks the application, `src`, browser-client source, scripts, and TypeScript test files with no emitted output. The production `tsconfig.json` intentionally excludes `**/*.test.ts`, so `npm run build` does not emit tests or require Vitest types in a production install.

Typechecking validates static TypeScript compatibility; it does not validate routes, MongoDB transactions, email-provider behavior, browser execution, or iOS behavior.

## 4. Backend unit and source-wiring tests

Run:

```bash
npm test
```

The current accepted baseline is **990 passed, 172 Mongo-gated skipped**. Skipped Mongo suites are not failures. This command does not execute the real-Mongo transactional suite; run `npm run test:mongo` separately.

Representative coverage includes validation, route logic, error envelopes, browser behavior, copy guards, and source-wiring assertions. Some tests read source text instead of importing `app.ts`, because `app.ts` connects to MongoDB and starts listening at module scope. These assertions are not end-to-end route tests.

Consequences:

- Broad `app.ts` formatting or route-registration changes can break source-text assertions.
- README and web-copy changes can be pinned by tests.
- INF1 review containment is covered by `src/reviewRuntime.test.ts` and
  `src/reviewProviderContainment.test.ts`, with lifecycle/startup neighbors in
  `createRequestRoute`, `fulfillmentRoute`, `requestOperationTerminalRoute`,
  `scheduledJobs`, `credentialLauncher`, `productionRuntimeConfig` and
  `infrastructureConfig` tests. These use local HTTP and recording providers,
  not real reviewer authentication or Atlas. Nginx rendering and shell syntax
  are local checks; Linux nftables/systemd, TLS, Atlas permission denial and
  the REV1-owned reset transaction require separate environmental proof.
- A repository-wide production-source guard rejects the superseded ASAP phrasings `within the next hour` and `within the next 5 hours`, and rejects any production sentence that names an expiration in hours other than three. It scans `src`, `public`, and `ios/CommonPlateios/CommonPlateios`, skipping test files and sourcemaps, so a stale generated bundle fails it until `npm run build:client` is rerun.
- Vitest sets `process.env.BASE_URL` to `/`. A test that asserts an absolute emailed link must stub `BASE_URL` itself rather than relying on the production default.

### Confirmation coverage

The confirmation flow adds, relative to the previous baseline:

- 53 focused unit/HTTP cases in `src/confirmSubscriptionRoute.test.ts`;
- 2 real-Mongo HTTP cases in `src/confirmSubscriptionRoute.mongo.test.ts`;
- 6 additional public-route wiring/order assertions.

Slice 3A (`src/confirmSubscription*.test.ts`) proves the atomic pending-to-confirmed transition, concurrency and idempotent loser behavior, field cleanup, the bounded used-token receipt, send-lease interactions, and outcome classification. Since Day 4 Slice 4A it also proves confirmation issues no unsubscribe credential and never touches `unsubscribeCredentialVersion`.

Slice 3B (`src/confirmSubscriptionRoute*.test.ts`) proves the safe non-mutating GET, the explicit form POST, actual URL-encoded body handling, that the pause runs before parsing and limiter work, that malformed JSON cannot bypass the route, sanitized parser-error behavior, the POST-only 5-per-60-second limiter, the required HTML security headers, the absence of internal-detail leakage, the browser outcome mapping, real HTTP-to-Mongo confirmation, and that a repeated HTTP POST mutates the document no further.

### Unsubscribe credential coverage

Day 4 Slice 4A adds, relative to the confirmation baseline:

- 73 focused cases in `src/unsubscribeCredential.test.ts` — 53 at this slice, the rest added by the Slice 4B review fixes below: signing-secret configuration, credential format and canonical signed input, stability, per-subscriber and per-version distinctness, strict parsing, constant-time verification, wrong-secret and tampering rejection, malformed input that fails without throwing, absence of any database work, and the emitted URL shape;
- unsubscribe-link cases in `src/emailHelpers.test.ts` and `src/sendDigestEmail.test.ts` proving both send paths emit a correctly formed link whose extracted credential verifies, need no stored raw token, and do not rotate between sends;
- re-signup preservation cases in `src/subscribeRoute.test.ts` and `src/subscribeRoute.mongo.test.ts` proving signup names none of `unsubscribeCredentialVersion`, the delivery counters, or the unsubscribe history;
- `models/db.test.ts` cases for the bounded version field, its default, the removal of the stored-digest invariant, and the legacy raw `unsubToken` being excluded from ordinary projections, with `models/db.mongo.test.ts` proving that exclusion against real MongoDB while leaving the stored value in place;
- `src/publicActionsRoutes.test.ts` guards that no `/unsubscribe` route is registered and that signup and delivery stay paused.

Both send paths take an optional injected signing secret so these tests configure signing directly instead of mutating the process environment.

### Unsubscribe redemption coverage

Day 4 Slice 4B adds, relative to the credential baseline:

- 33 focused cases in `src/unsubscribeSubscriber.test.ts`: which links the primitive accepts, that an unusable one never reaches Mongo, the legacy/rotated stored-version comparison through `resolveUnsubscribeCredentialVersion`, the exact conditional filter (`$exists: false` versus the exact stored value), the single-update pipeline it writes, the exact cleared set — the active confirmation and send-attempt fields plus the bounded confirmation receipt, asserted against the shared definitions rather than a restated list — the fields it refuses to touch, and a conditional-update miss reported as the generic invalid result;
- 39 focused HTTP cases in `src/unsubscribeRoute.test.ts`: the non-mutating GET, the explicit form POST, the one page rendered for every subscriber status, one generic invalid page for every unusable link, the pause running ahead of verification, lookup, mutation, and the limiter, the POST-only 5-per-60-second limiter, the required security headers, sanitized parser-error behaviour, the fixed log lines, and the copy and page-structure guards;
- 36 real-Mongo cases in `src/unsubscribeRoute.mongo.test.ts`: the GET writing nothing for pending, confirmed, and unsubscribed rows, the atomic transition from each of those statuses, the pending row's confirmation link becoming unusable afterwards, idempotent repeats compared over the whole document, preserved identity/version/counters/send history, legacy and rotated versions, a version rotation landing between validation and update, and an unsubscribed row leaving the confirmed delivery pool;
- within those, a confirmation-lifecycle group added by the confirmation-receipt correction: a confirmed row holding a live receipt unsubscribing and losing it, the reopened confirmation link no longer able to claim the address is confirmed, the old credential posting back the existing invalid result without writing, a re-signup issuing a fresh pending credential on the same row and version, and the original emailed unsubscribe credential still working after re-signup and reconfirmation;
- `src/publicActionsRoutes.test.ts` guards for the two new registrations, their middleware order, registration ahead of the global parsers, and signup and delivery still being paused.

The independent-review fixes add, within those files:

- stored-version resolution cases in `src/unsubscribeCredential.test.ts` proving `undefined` resolves to version 1 while `null` is rejected alongside every other malformed value, and that valid versions — including the schema default of 1 — pass through unchanged;
- primitive cases in `src/unsubscribeSubscriber.test.ts` proving a persisted `null` produces the generic invalid result on both the check and the mutation without reaching `updateOne`, and that no stored state ever produces a `{unsubscribeCredentialVersion: null}` filter;
- real-Mongo cases proving a physically null row is refused generically on GET and POST at every credential version, keeps its status, and retains its physical `null`; and that a legacy row's atomic filter is captured as `{$exists: false}` while the real update still runs;
- a `tamperCredentialSignature` fixture helper, defined per test file like the other small fixture helpers and regression-tested once in `src/unsubscribeCredential.test.ts`, that swaps between two canonical trailing base64url characters so a tampered credential always differs from the authentic one. Every tampering fixture asserts both that difference and a failed `verifyUnsubscribeCredential` before submitting, and the Mongo suite covers both an authentic signature ending in `A` and one that does not, using deterministically searched subscriber ids rather than sampled ones.

### Activation validation coverage

Day 4 Slice 4C adds startup validation of `UNSUBSCRIBE_SIGNING_SECRET` and its coverage:

- 15 focused cases in `src/unsubscribeCredential.test.ts` for the activation rule itself — the paused rows, the unpaused rows for an absent, empty, short, exactly-32-byte, and longer secret, that a paused check never reads the variable, that the byte count is UTF-8 bytes rather than JavaScript characters in both directions, that no other configured secret is substituted, and that the reported failure names the variable but never its value. These cases describe environments as plain objects rather than stubbed process variables, so none of them can leak configuration into another;
- 13 cases in `src/startupValidation.test.ts`. Six read `app.ts` as text and pin where the check sits: inside the existing environment-validation block, exactly once, before the Express app, every route registration, `mongoose.connect`, `Fulfillment.createIndexes`, `app.listen`, and the first module-level `await`; that the catch logs only the reported message; and that `src/unsubscribeCredential.ts` is the only production module able to read the variable. The remaining seven run the real `app.ts` in a child process and observe the whole table end to end.

Those child processes are given an explicitly constructed environment rather than an inherited one, and `DOTENV_CONFIG_PATH` names a file that does not exist, so a developer's local `.env` can neither supply a secret a case means to withhold nor withhold one it means to supply. `MONGO_URI` points at a closed local port with a short server-selection timeout: a refused startup never reaches it, and a permitted startup fails there quickly, which is the signal that it passed validation. No real database is contacted.

### Lifecycle acceptance coverage

`src/subscriptionLifecycle.mongo.test.ts` (Slice 4C) is 20 real-Mongo acceptance cases for the complete backend email lifecycle, driven through the production route registrations, handlers, helpers, and emails: signup writing one pending Subscriber and rotating rather than duplicating on a repeat; the confirmation email carrying the token whose digest that row holds; the confirmation GET mutating nothing however often it is opened; the explicit POST transitioning pending to confirmed without moving the credential version; eligibility appearing only after that POST, proved through the real alert path rather than a query; a real-time alert and a digest each carrying a credential that verifies for exactly that subscriber and opens the real unsubscribe route; the unsubscribe GET mutating nothing; the explicit POST transitioning the row and clearing the active confirmation fields and the bounded receipt; idempotent repeats compared over the whole document; the address leaving later alert and digest selection; re-signup preserving `_id`, credential version, counters, send history, and unsubscribe history while issuing a fresh credential that retires the previous one; reconfirmation restoring eligibility with the original emailed link still working; no raw credential or signature persisted in any collection; and paused signup, confirmation, unsubscribe, alert, and digest paths all refusing before their protected work.

Only the email provider is replaced, at the existing `resend` boundary, so `emailHelpers.ts` composes the real messages and links. The one selection the suite reproduces rather than calls is the hourly digest query, which lives in the `app.ts` cron and cannot be imported; `src/publicActionsRoutes.test.ts` pins that query's `status: "confirmed"` against the real source.

### NYU alert-signup allowlist coverage

Week 3 Day 5 Slice 5A adds, relative to the lifecycle-acceptance baseline:

- 29 cases in `src/allowedEmailDomains.test.ts` for the exact-domain helper — the allowlist's exact contents, trimming and lowercasing, reading the domain after the final `@`, values with no usable domain, plus-addressing on an allowed domain, and the lookalike, unlisted-subdomain, and suffix/substring addresses a `hasSuffix("nyu.edu")` or `includes` check would wrongly accept;
- 9 cases in `src/subscribeRoute.test.ts` for the route. Six prove a non-allowlisted address is refused with the shared `INVALID_EMAIL` envelope **before any database work**, asserting that `Subscriber.findOne`, `Subscriber.create`, `Subscriber.findOneAndUpdate`, the token generator, and the confirmation sender are each never called. Three prove an allowed address is still normalized before its lookup;
- 26 cases in `ios/CommonPlateios/CommonPlateiosTests/AlertSignupTests.swift`. The original 21 cover the iOS allowlist, the single normalized POST through the existing `APIClient`, duplicate-submit refusal while a signup is in flight and after acceptance, the generic accepted state, and the distinct mapping of local invalid email, backend `INVALID_EMAIL`, paused signup, HTTP 429, `CONFIRMATION_EMAIL_UNAVAILABLE`, transport and undecodable-body ambiguity, and bounded unknown failure — plus copy guards proving no accepted or failure message claims a subscription, confirmation, active alerts, or a sent email. Five review-response cases were added: three pin the cancellation split described below, and two pin that `Use a different email` empties the field, sends nothing, and is ignored outside the accepted state.

No existing lifecycle assertion changed for this slice. Eight fixture addresses in `src/subscribeRoute.test.ts`, `src/subscribeRoute.mongo.test.ts`, `src/subscriptionLifecycle.mongo.test.ts`, and `src/unsubscribeRoute.mongo.test.ts` moved from `@example.edu` to `@nyu.edu` because those cases drive the real subscribe handler, which now refuses the former. The Mongo suites gained and lost no cases, so `npm run test:mongo` is unchanged at 127.

Cancellation is two outcomes, and `AlertSignupTests.swift` pins both. Cancellation observed before transmission is definitive — nothing was encoded or handed to the transport — and `AlertSubscriptionService` translates it into its own definitive failure rather than letting a raw `CancellationError` escape to be classified by whoever catches it; the service-level case fails if that translation is removed. Cancellation from transmission onward stays conservatively ambiguous, and its case cancels only after the stub has recorded the request, so the body is provably on the wire first. Known limit: `APIClient` reports cancellation from three points — before `URLSession` is called, from a cancelled transport, and after a response was already received. The first is pinned directly and the other two are pinned as a pair; separating them would require suspending the stub mid-response and reaching into `APIClient` internals, and both are ambiguous by design, so that distinction is documented rather than tested.

The Slice 4B mongo suite drives the production handlers, so it stubs both `PUBLIC_ACTIONS_PAUSED` and `UNSUBSCRIBE_SIGNING_SECRET` per case rather than injecting a secret. Fixtures that describe malformed persisted state — a physically absent version field, or a physical `null` — are written through the driver, because the schema default, its bounds, and its integer validator would otherwise replace or reject them before they reached the collection. Its lifecycle cases also mount the confirmation routes and call the signup handler directly, so that file replaces `emailHelpers.js` — whose module scope constructs a Resend client that refuses to build without an API key — and injects its own send function. Pause middleware is unaffected: signup, confirmation, and unsubscribe all remain paused in production registration.

### NYU food-request allowlist coverage

Week 3 Day 5 Slice 5B applies the same allowlist to `POST /api/request` and the iOS Request Food form, adding, relative to the alert-signup baseline:

- 23 cases in `src/createRequestRoute.test.ts`. They prove acceptance and normalization of both exact domains including uppercase, surrounding whitespace, and plus-addressing — asserted on the persisted document, the daily-limit count, and the requester email, so all three use the normalized address; refusal of malformed, non-NYU, lookalike, and unlisted-subdomain addresses with the `INVALID_EMAIL` envelope; the same rule on the canonical scheduled and legacy web shapes; and that a refused address reaches no side effect, asserted as `Request.countDocuments`, `Request.create`, the Resend send, and `notifySubscribersForRequest` each never being called. Two further cases pin precedence: a missing or blank `email` keeps the generic `INVALID_REQUEST` payload message, and so does a bad address accompanied by a blank field, a bad `timing`, an unexpected key, or an ended window;
- 21 cases in `ios/CommonPlateios/CommonPlateiosTests/RequestEmailAllowlistTests.swift`. They prove both exact domains, uppercase and whitespace normalization, plus-addressing, and the malformed, non-NYU, lookalike, and unlisted-subdomain refusals; that the empty field keeps its own distinct message; that a refused address blocks submission, focuses the email field, and — driven through the real store, service, `APIClient`, and `URLSession` — issues no HTTP request and never arms the process-lifetime create block, while an allowed address still posts once and creates; that every other entered value and the timing selection survive an email rejection with only the email field marked presented; that a backend `INVALID_EMAIL` maps to the same sentence without showing the backend's own wording, and that every other create code and the ambiguous and in-progress outcomes map exactly as before; and that submit enabling, the duplicate-submit refusal, and the ambiguity guard are unchanged. Six of those cases cover the pre-entry eligibility notice: its exact sentence, that every `@`-prefixed token in it is an allowed domain and every allowed domain appears in it — so the copy and `NYUEmailPolicy.allowedDomains` cannot drift apart — that it is distinct from the validation message, the empty-field message, and the purpose notice, that the validator never emits it for any input and a rejected address still produces its own error, and that it promises no email delivery.

Those six cases are copy and validator tests: they cover the sentence and its relationship to the validation errors, not where or how it is drawn. There is no UI-test target, so four properties of the pre-entry notice were **verified by code inspection of `RequestFoodView.swift` only, not by automated UI verification**:

- that it is rendered before submission — the `Text` is unconditional, with no dependence on `validationPresentation`, `errors`, or `submissionError`;
- that it remains visible during editing — the same absence of any focus or edit-state condition;
- that it uses scalable `.footnote` typography with vertical expansion — `.font(.footnote)` plus `.fixedSize(horizontal: false, vertical: true)`;
- that it appears in the intended accessibility reading order — placed between the email `TextField` and `fieldErrorText`, carrying `request-email-eligibility`, and adding nothing to the field's `accessibilityHint`, which the error still owns.

A future UI-test target would be what actually pins those four. Until then, changes to that section's layout, styling, or ordering will not be caught by `CommonPlateiosTests`.

**Superseded by W3-I3.** The pre-entry eligibility notice and its six cases, and the code-inspection properties above, describe Request Food's former Contact section, which W3-I3 removed entirely (see the W3-I3 coverage subsection below). They are preserved here as the historical record of Slice 5B; they are no longer present in `RequestEmailAllowlistTests.swift` or `RequestFoodView.swift`.

`src/allowedEmailDomains.test.ts` already proves the helper matrix, so it gained no cases. The route suite's requester fixtures moved from `@example.edu` to `@nyu.edu` for the same reason the signup fixtures did in Slice 5A: they drive the real handler, which now refuses the former. One existing iOS assertion changed — `testEmptyAndMalformedEmailHaveDistinctCopy` now expects the NYU sentence for a malformed address, and additionally asserts that the empty and malformed messages still differ.

No Mongo suite drives `POST /api/request`, so no Mongo fixture changed and `npm run test:mongo` is unchanged at 127. No browser-client source changed; `src/client/new-request.ts` already decodes `error` as a string or `{code, message}` and renders the message, which `src/client/new-request.test.ts` already proves, so the new envelope cannot render as `[object Object]`.

### Cross-launch check-email presentation coverage

Week 3 Day 5 Slice 5C makes the iOS `Check your email` screen survive relaunch. It changes no backend file, so no backend or Mongo suite was rerun and both remain at their Slice 5B totals. It adds **21 cases in `ios/CommonPlateios/CommonPlateiosTests/AlertSignupPresentationTests.swift`**, and `AlertSignupTests.swift` is unchanged at 26 cases with every assertion preserved — only its store factory now passes an in-memory presentation storage.

The new cases prove that a generic 202 persists the normalized submitted address and the response time; that a store rebuilt over the same stored value — which is what launch does — restores the `checkEmail` phase, the remembered address, an empty draft, and no error state; that the restored screen is the existing accepted copy and that no observable property, record field, or storage key is named `subscriptionStatus`, `isSubscribed`, `isConfirmed`, `activeSubscriber`, or `pendingSubscriber`; that `Use a different email` removes the stored value, empties the draft, forgets the remembered address, and sends nothing; that a store rebuilt after clearing returns to editing; that a later accepted address replaces the earlier record with exactly one record remaining; and that `Done` — which dismisses the screen and calls nothing on the store — leaves the record for the next launch.

Seven cases cover the failure boundary. A locally rejected address, a backend `INVALID_EMAIL`, the paused bare 503, HTTP 429, `CONFIRMATION_EMAIL_UNAVAILABLE`, a transport-loss ambiguity, and a definitive unknown failure each perform **zero writes and zero deletes**, asserted as counts on an in-memory storage double rather than by inspecting the record — a preserved record and a destroyed-then-rewritten one are otherwise indistinguishable. One further case proves a failing attempt cannot destroy an existing accepted record at all: submission is refused outside `editing`, so a store holding a restored record sends nothing and writes nothing, and only the explicit `Use a different email` removes it.

Four cases cover unusable stored data, driven through a real `UserDefaults` suite: unparseable JSON, an incomplete record, an array in place of the record, and a value of the wrong type entirely; a stored address that no longer satisfies the NYU rule; and a missing, empty, unparseable, `null`, or numeric timestamp. Each is removed rather than left to be re-rejected, each leaves the editable form, and none crashes initialization. Restoring and rejecting are both proved to issue no HTTP request, since no endpoint reports subscription status.

Every store in the new file is given isolated persistence — either the in-memory double or a `UserDefaults` suite named per test and removed in `tearDown` — and one case asserts directly that the run leaves nothing in `UserDefaults.standard`. `AlertSubscriptionStore`'s storage argument has no default value, so a test cannot reach real preferences by omitting it.

"Relaunch" here means reconstructing `AlertSubscriptionStore` over the same persisted value, exactly as `ContentView` builds one at launch — no manual kill-and-relaunch walkthrough on a simulator or device was performed for this slice. The repository has no UI-test target, so these cases do not exercise the real `NavigationStack` → `AlertSignupView` rendering path; they prove store state only, not on-screen layout, navigation, or accessibility presentation.

### Supported-vendor integrity coverage

Week 3 Day 7 Slice 7A adds, relative to the cross-launch check-email presentation baseline:

- 3 cases in `src/supportedVendors.test.ts` for the catalog helper: exact-match acceptance of every entry in `shared/vendors.json`, and rejection of a near-match (different case or punctuation);
- 23 cases in `src/createRequestRoute.test.ts`, in a dedicated `POST /api/request supported-vendor allowlist` describe block: acceptance of each of the 11 catalog vendors by name, refusal of unsupported, case-variant, and near-match vendors with the `INVALID_VENDOR` envelope and no side effect (`Request.create`, the Resend send, and `notifySubscribersForRequest` each never called), a blank vendor keeping the generic `INVALID_REQUEST` structural message rather than `INVALID_VENDOR`, the same catalog applied to both the canonical scheduled and legacy web create shapes, vendor precedence over the email allowlist so an unsupported vendor is reported even when the email is also invalid, an earlier structural error still reported ahead of `INVALID_VENDOR`, and a source-inspection case proving `RequestFoodView.swift` reads `SupportedVendorCatalog.diningSpots` rather than a second hand-maintained vendor list;
- 2 cases in `ios/CommonPlateios/CommonPlateiosTests/SupportedVendorCatalogTests.swift` proving the iOS Picker's data source decodes the exact accepted 11 entries, in order, from the bundled shared catalog, and that every entry carries a non-empty address.

No Mongo suite reads or writes vendor state, so `npm run test:mongo` was not rerun for this slice and stands at its Slice 5B baseline below.

### Real-time helper-alert selection and response-isolation coverage

Week 3 Day 7 Slices 7B and 7C add, relative to the supported-vendor integrity baseline:

- In `src/notifySubscribers.test.ts`: the real-time eligibility query is asserted exact — `{ status: "confirmed" }` and `{ bounced: false }` only, no cooldown or daily-cap clause; every eligible subscriber in a multi-subscriber set is notified, not a bounded subset; a subscriber with a fresh `lastSentAt` and a subscriber already at the old daily cap are each still attempted; one subscriber's provider failure does not block the remaining eligible subscribers; `SendLog`'s claim-before-send dedup still skips a subscriber another process already claimed; a successful send still updates `dailyCount` and `lastSentAt`; and the real-time path never reads or writes the now-removed `notify_cursor` `System` document.
- In `src/createRequestRoute.test.ts`: the side-effect-ordering case now proves requester email is still awaited before the `201`, while helper-alert fan-out starts only after it. A dedicated `POST /api/request helper email isolation (Slice 7C)` describe block mirrors the existing helper-push isolation suite: `201` returns while a deliberately never-settling helper-alert dispatch is still outstanding; a rejecting dispatch does not alter the `201` result and produces no unhandled rejection (asserted against the process's rejection handling); and a synchronously throwing dispatch start does not reach the outer `catch` to attempt a second response.

No Mongo suite reads or writes `Subscriber`, `SendLog`, or `System` selection logic differently under these slices — the change is a query-shape and dispatch-timing change, not new persistence, transaction, or index behavior — so `npm run test:mongo` was not rerun and stands at its Slice 5B baseline below.

### Request correctness (W3-R1) coverage

W3-R1 is ACCEPTED: NYU/`America/New_York` campus-time request timing, the ASAP/Later `visibleFrom`/`expiresAt` availability window, elapsed-Later refusal, pre-`visibleFrom` withholding on public detail and claim (`REQUEST_NOT_YET_AVAILABLE`), and the daily-quota calendar-day boundary are covered in `src/createRequestRoute.test.ts`, `src/requestTiming.test.ts`, `src/requestAvailability.test.ts`, and the corresponding iOS suites (`RequestCreationViewTests.swift`, `RequestFetchingTests.swift`, `ClaimFlowTests.swift`). These behaviors are unchanged from the checkpoint commit and are now promoted as accepted runtime truth in `docs/system-contract.md` section 2.1.

The project owner's revised presentation contract — removing the standing daily-quota notice from ordinary Request Food presentation, explaining the three-hour availability rule once at the timing choice instead of repeatedly downstream, and shortening the shared backend `ASAP` timing label — added and updated cases in `src/createRequestRoute.test.ts` (the shared `ASAP_WINDOW_TEXT` label and its propagation to `pickupWindowText`), `ios/CommonPlateios/CommonPlateiosTests/RequestPostingLimitCopyTests.swift` (the standing notice is gone from the ordinary form; the actual limit-reached recovery sentence is unchanged), and `ios/CommonPlateios/CommonPlateiosTests/RequestCreationViewTests.swift` (the timing-choice form states the three-hour rule exactly once per timing; the post-submit success screen states only the confirmation, with a scoped test reading the `successView` declaration's own source to guard against any reintroduction of timing/expiration policy there, under any name).

No persistence, schema, query, or notification-routing behavior changed, so `npm run test:mongo` was not rerun for the presentation correction itself and stands at its own baseline below. The non-Eastern `DatePicker` physical-device timezone proof (Phoenix time) predates and is unaffected by the presentation correction, which does not touch timezone rendering or submission code; see the environmental-proof note in section 9.

### Verified participant identity (W3-I1) coverage

W3-I1 is accepted. Backend unit and HTTP tests cover participant challenge issuance and redemption, exact normalized NYU principals, rate/error envelopes, authority signing and revocation, route-local parsing, and startup configuration. The Mongo suites cover challenge expiry, resend supersession, bounded incorrect attempts, concurrent redemption, one participant per verified address, no raw verification-code persistence, and durable requester/helper bindings. Request, claim, fulfillment, notification, and browser tests cover the participant gate, requester identity derived from authority, atomic helper binding, fulfillment reuse of that bound helper, the intentionally narrow pre-I1 active-claim compatibility path, and the legacy website's non-actionable form.

The focused iOS participant identity, gate, and continuation suites contain 52 passing tests (including 15 continuation cases after the final test-proof correction). They cover code-verification flow, authority storage and rejection, Change Email staging, draft preservation through verification, requester/helper gates, and same-install continuation logic. The complete `CommonPlateiosTests` target passed with 550 tests and 0 failures.

These automated, source, and simulator results do **not** prove real NYU verification-email receipt or real-code redemption; uninstall/reinstall or new-device reverification; the remaining physical Keychain lifecycle behavior; backup/device-migration exclusion; or a real-address Change Email flow. Same-install authority retention through terminate/relaunch continuation was subsequently observed in the accepted W3-H1 physical flow below. The remaining items are accepted, explicitly unperformed environmental checks, not passed evidence.

### Requester verification entry (W3-I2) coverage

W3-I2 is accepted. It changes only requester-entry sequencing (verification before the Request Food form, rather than a gate at first Submit) and consumes W3-I1's identity, credential, storage, and lifetime semantics unchanged; the W3-I1 coverage above still governs those.

Focused `ios/CommonPlateios/CommonPlateiosTests/RequestFoodEntryTests.swift` coverage exists for: clean/no-identity entry routing to verification rather than the form; a usable verification-start/email-entry action; successful verification continuing directly into the form; failed/cancelled verification not doing so; already-verified and restored identity entering the form directly; no second editable participant-email field; submission carrying the authority entry verification established; sticky form-admission surviving a later mid-form authority loss without losing the draft; a repeat appearance after admission not opening a second entry-owned verification flow; and the real SwiftUI sheet-dismissal handshake (successful verification's own dismissal) not being mistaken for a user cancellation and popping the Request Food navigation destination.

That last case matters specifically because simulator/unit tests cannot, by themselves, establish the real physical-device sheet-presentation/dismissal transition — an initial round of this coverage passed in simulator while a real iPhone still required a second "I Need Food" entry after successful verification, because nothing in the automated suite drives an actual `.sheet` presentation/dismissal handshake. That physical defect was found, fixed, and its regression proof added at the same pure-predicate boundary the fix itself uses; simulator/unit results remain a proxy for, not a substitute for, physical confirmation of this exact transition.

Physical confirmation was subsequently performed and passed on a real iPhone: unverified Request Food opened participant verification before the form; real NYU verification succeeded; successful verification proceeded immediately into Request Food without a second Request Food entry; Request Food had no second editable participant-email field; a valid request submitted using the verified participant identity with no further email/verification step; leaving and reopening Request Food entered the form directly using restored verified identity; and Change Email required reverification. The project owner accepted W3-I2 on this basis.

The complete `CommonPlateiosTests` target has passed alongside this coverage. The combined-tree result is recorded as current execution evidence below; it is not a historical clean-commit baseline for W3-I2 alone.

### Verification UX and app-level identity presentation (W3-I3) coverage

W3-I3 is accepted. It changes only presentation: the participant-verification and Change Email visual hierarchy, and removal of Request Food's Contact section / verified-email row. It changes no verification-code, resend, expiry, credential, participant-principal, persistence, or authorization behavior; the W3-I1 and W3-I2 coverage above still governs those. Home-level verified-identity presentation and the Change Email entry point already existed from prior accepted work and required no change for this slice.

New focused `ios/CommonPlateios/CommonPlateiosTests/ParticipantVerificationHierarchyTests.swift` coverage (2 cases) proves, by reading `ParticipantVerificationView.swift`'s own tracked source scoped to each section's declaration: the email section orders the email field, then Send code, ahead of the standing eligibility/purpose/replacement/revoked explanation; and the code section orders the code field, Verify, then resend. `ParticipantGateTests.swift` and `RequestCreationViewTests.swift` lost cases that pinned copy/behavior removed by this slice (the Request Food Contact section's standing verification notice and email-purpose-notice text). `RequestEmailAllowlistTests.swift` replaced its pre-entry email-eligibility-copy cases with a source-inspection case (`testRequestFoodHasNoContactSection`) proving `RequestFoodView.swift` contains no `Section("Contact")`, no `"Posting as"` row, and none of `emailEligibilityNotice`, `emailPurposeNotice`, or `verificationRequiredNotice` — so a reintroduction under a different property or section name still fails it.

These are structural source-text assertions, matching the existing source-inspection pattern used elsewhere in this target (e.g. the Slice 5B pre-entry-notice cases they replace). They do not by themselves prove real rendered hierarchy, visual density, or discoverability on screen — the repository has no UI-test target. Physical-device presentation is the evidence that established those rendered/discoverability properties: on a real iPhone, entering the NYU email was immediately understandable, Send code read clearly as the verification screen's primary action, Verify read clearly as the code-entry screen's primary action, Change Email presentation looked good, Home-level verified identity and Change Email were discoverable, and Request Food showed no Contact/participant-email presentation and felt limited to request-specific information. The project owner accepted W3-I3 on this basis.

A final focused run after the physical-presentation fix (the `.buttonStyle(.borderedProminent)`/`.controlSize(.large)` correction to Send code and Verify) passed 60 tests, 0 failures. The complete `CommonPlateiosTests` target also passed with **649 tests, 0 failed, TEST SUCCEEDED** alongside this coverage. That later composite result is retained as the newest recorded complete-target execution evidence below.

### Later Eligibility Notification Dispatch (W3-N3) coverage

W3-N3 is accepted. Notification-focused suites passed 117/117 at the accepted checkpoint. Backend automated coverage includes: no email/push initiation before `visibleFrom`; eligibility-time processing at the next sweep; discovery of a `createdAt` well outside the former lookback; delayed/catch-up execution after a missed or interrupted sweep; temporary-availability recovery; deduplication under concurrent/repeated sweep processing; per-recipient email fan-out (`SendLog`); per-installation push deduplication (`PushDelivery`); retryable pre-initiation outcomes (pause, not-yet-effectively-available, non-duplicate claim-write failure) remaining recoverable rather than consuming the request's only initiation; terminal provider outcomes remaining terminal and non-repeating; compatibility of pre-N3 W3-R1 Later rows with the eligibility sweep; and an ASAP regression proving no N3-created duplicate notification.

At acceptance: `npm run typecheck` passed; `npm test` passed 1,055 tests with 209 Mongo-gated skips; `npm run test:mongo` passed 209 tests across 14 files; `npm run ci-check` passed; `git diff --check` was clean. An initial independent HIGH-risk review returned 3 MUST FIX findings, all corrected; a fresh narrow independent rereview of the corrections was CLEAN.

**Physical/environmental acceptance evidence.** One real future Later request was observed against live Mongo, email, and APNs. Before its `visibleFrom` (`2026-08-10T08:29:00.000Z`), the request existed with `helperNotification` awaiting eligibility, zero `SendLog` rows, and zero helper-new-request `PushDelivery` rows — no email or APNs initiation had occurred. At the first eligible sweep, `helperNotification` transitioned `awaiting-eligibility → initiated` at `2026-08-10T08:29:00.544Z`. Email: exactly one real-time `SendLog` row for the confirmed subscriber, `status: sent`, `sentAt: 2026-08-10T08:29:00.537Z`; the project owner confirmed the email arrived in the intended inbox. Push: three helper-new-request `PushDelivery` rows, one per eligible installation, with no duplicate rows; two were accepted by APNs and one was rejected under existing provider/token classification (not an N3 timing defect — initiation occurred at the correct time and another intended installation was accepted); the project owner physically observed the notification on the intended physical iPhone. Every recorded initiation timestamp was at or after `visibleFrom`.

This physical request's `createdAt` was approximately 10 minutes before its `visibleFrom`, so the physical test alone does not reproduce the former long-lookback omission; that stronger old-`createdAt` property is established by the real-Mongo integration coverage above using requests many hours old, not by this physical observation. Provider acceptance proves provider submission/acceptance only; inbox arrival and physical notification presentation were observed as supporting environmental evidence, and neither proves reading or pickup.

A separate finding from this same physical session — that helper new-request emails for ASAP requests currently show a concrete time range where the project owner prefers an "ASAP" label, while Later alerts correctly retain concrete scheduled timing — is not an N3 eligibility-time defect and is not part of this acceptance. It is recorded as a forward-routed product/email-presentation finding in the current weekly spec's deferral register.

### Reservation Lifecycle (W3-H1) coverage

W3-H1 is accepted. Backend automated coverage includes one-active-reservation enforcement across principals and requests; atomic release and continuation authorization; exact release CAS handling for absent, `null`, and date representations; release/extension one-winner races on real MongoDB; fulfillment/release safety; and deterministic transaction-callback retry regression proof. The H1 closeout typecheck, focused claim/reservation/fulfillment suites, complete non-Mongo suite, and complete Mongo-gated suite passed.

iOS coverage exercises continuation truth (`active` only for a claimed embedded request, `none` only for authoritative absence, and `unknown` for transport/server/decode/contradictory responses); reservation-scoped authority and stale-credential rejection; release/extend/fulfill exclusion and recovery; bounded ambiguous-fulfillment resend; requestID-stable warning scheduling; active/inactive warning ownership transfer; scheduler callback fencing; and warning tap routing, including cold launch and stale-warning isolation. The H1 closeout complete `CommonPlateiosTests` run passed **633 tests, 0 failed** on an iPhone 17 Pro simulator running iOS 26.5; final focused rereview suites and both diff checks also passed.

The project owner's physical iPhone acceptance established the device-only behaviors not proven by simulator/unit tests: terminate/relaunch continuation; foreground in-app T−5 warning without a duplicate system warning; backgrounded and terminated local warning delivery; terminated-app warning-tap cold launch to the matching reservation; release; and fulfillment after restored continuation. These observations establish H1 behavior on the observed device only. They do not establish APNs provider behavior, Release/Archive/TestFlight signing, or release-environment configuration, which remain separate gates.

### Meal-Plan / Payment Requirement (W3-C1) coverage

W3-C1 is accepted. Backend coverage in `src/createRequestRoute.test.ts` proves the required integer 1–5 `mealSwipes` quantity is enforced identically on the canonical/iOS and `legacyWebSchema` request shapes: values 1–5 are accepted and round-trip unchanged; missing, invalid, fractional, and out-of-range values are rejected on both shapes, including a `legacyWebSchema` submission omitting the quantity. `src/requestListResponse.test.ts` and `src/requestDetailRoute.test.ts` prove the helper projection exposes the quantity without newly exposing any private field. `src/emailHelpers.test.ts` and `src/helperPushPayload.test.ts` prove the helper new-request email (text and HTML) and push payload carry the same authoritative quantity through the existing `sendNewRequestAlert()` and `buildHelperNewRequestPayload()` composition paths, unchanged for both immediate-creation and W3-N3 eligibility-sweep dispatch. `src/participantBinding.mongo.test.ts` and `models/db.ts` cover Request-owned persistence of the field.

iOS coverage proves the bounded 1–5 picker, payload behavior, and pre-Reserve visibility in Active Requests and `RequestDetailView`, continuity through active-reservation presentation and `FulfillRequestView`, and that fulfillment navigation reads the quantity from the active claim's authoritative request rather than a stale pre-claim copy — across `RequestCreationViewTests.swift`, `RequestFetchingTests.swift`, `RequestFoodEntryTests.swift`, `ClaimFlowTests.swift`, `ReservationContinuationTests.swift`, `ReservationFulfillmentContinuationTests.swift`, `ReservationReleaseTests.swift`, `ReservationWarningTests.swift`, `ReservationWarningRoutingTests.swift`, `ParticipantContinuationTests.swift`, `ParticipantGateTests.swift`, `RequestCreationInstallationCredentialTests.swift`, `RequestEmailAllowlistTests.swift`, `RequestTimingContractTests.swift`, `HelperNotificationRoutingTests.swift`, and `HelperNotificationTerminatedLaunchRoutingTests.swift`.

At acceptance: `npm run typecheck` passed; `npm test` passed 1,317 tests with 275 Mongo-gated skips; `npm run test:mongo` passed 275 tests across 17 files; `npm run ci-check` passed; `npm run build:client` produced no tracked bundle diff. The final focused Active Requests visibility test, the ClaimFlow focused proof after continuity fixes, and the complete `CommonPlateiosTests` target (662 passed, 0 failed, TEST SUCCEEDED) all passed. An independent engineering review resolved backend validation/persistence/privacy/notification findings and one iOS stale-request fulfillment continuity MUST FIX, with no remaining engineering finding afterward.

**Physical acceptance evidence.** The project owner verified the meal-swipe quantity is visibly acceptable in Active Requests on a physical device. An earlier walkthrough verified the same distinctive quantity (`4`) in Request Detail, active-reservation presentation, and fulfillment/order context, and the helper new-request notification and email presentation were also physically reviewed and accepted. These observations establish on-device presentation on the observed device only; they do not establish Release/Archive/TestFlight signing or environment behavior, which remains a separate gate (`docs/system-contract.md` section 11).

**Week 4 deferral.** `Meal swipes: N` is technically correct but its user-facing meaning and visual hierarchy are deferred to Week 4; that resolution must not reopen C1 data semantics, backend behavior, validation rules, or notification content, except that the project owner has explicitly authorized W4-N1 (not W4-R2, and only once N1 reaches its own READY contract) to change the new-request push notification's title/body composition specifically; this narrow carve-out does not reopen any other notification content, channel, delivery, tap-routing, or dedup behavior recorded in this document or in `docs/system-contract.md`.

### Notification Management / Activation Truth (W3-N2) coverage

W3-N2 is accepted. Backend coverage adds focused participant-authorized email-unsubscribe route/primitive tests proving: exact participant-email authorization with no caller-supplied email or Subscriber ID accepted; rejection of forged, revoked, deleted, and stale participant authority; absent/pending/confirmed/already-unsubscribed Subscriber convergence to the identical `{ "email": { "unsubscribed": true } }` result with no lifecycle or identifier leakage; atomicity and idempotency under repeat and concurrent calls; the exact cleared confirmation-credential field set, matching the existing emailed-unsubscribe clear list; that `unsubscribeCredentialVersion` is untouched; pause and rate-limit behavior; and that existing emailed unsubscribe credentials and browser GET/POST behavior are unaffected. Backend coverage also adds focused signup-privacy tests proving the same generic accepted `202` response across Subscriber lifecycle states and confirmation-email provider outcomes that previously exposed `CONFIRMATION_EMAIL_UNAVAILABLE`, that internal cleanup/rollback and sanitized logging still run on provider failure, and that the response makes no provider-submission or delivery claim.

At acceptance: `npm run typecheck` passed; complete `npm test` passed after the signup-privacy correction; `npm run test:mongo` passed **283 tests across 18 files**; `npm run ci-check` passed; `git diff --check` passed.

**Verification-environment limitation.** Sandboxed backend test execution could not bind `127.0.0.1` and produced unrelated EPERM/timeout failures unconnected to this slice's behavior. The complete backend suite passed when run with the necessary local-loopback permission. This is recorded as a verification-environment limitation, not a product defect.

iOS coverage adds focused suites for: ambiguous push enable/disable persistence surviving relaunch and requiring an explicit retry, with no automatic ambiguous reconciliation across relaunch or authorization refresh; participant-authorized email unsubscribe through `ParticipantEmailUnsubscribeService`/`ParticipantEmailUnsubscribeStore`, including forged/stale-credential rejection and convergence to the same Off result regardless of prior Subscriber state; a stale Email Alerts Off presentation being reset by a later signup, both to the same address and to a different one, returning to `Check your email` rather than a stale Off; in-flight unsubscribe generation/reset races; and removal of retired `CONFIRMATION_EMAIL_UNAVAILABLE` client-side handling from `AlertSubscriptionService` and `AlertSubscriptionStore`.

Final complete iOS evidence: **CommonPlateiosTests — 689 passed / 0 failed / TEST SUCCEEDED**. This supersedes the W3-C1 iOS baseline (662 passed) as the current accepted baseline below.

**Physical acceptance.** The project owner completed the W3-N2 physical acceptance walkthrough on a physical iPhone and reported the behavior worked as expected. The walkthrough covered: physical Apple notification-permission behavior; push enable reaching authoritative On; push disable reaching authoritative Off; relaunch preserving accepted push-management truth; ambiguous push recovery/retry behavior as exercised in the walkthrough; participant-authorized in-app email unsubscribe; later signup returning to Check Your Email rather than stale Off; and email/push channel independence. This walkthrough does not establish verified email delivery or reading, a production APNs delivery environment, TestFlight signing/configuration, or production backend reachability — those remain separate provider/release gates (`docs/system-contract.md` section 11).

### Durable Request-Creation Recovery (W3-D1) coverage

W3-D1 is accepted. Backend coverage proves exact-operation idempotency and reconciliation for `POST /api/request`: sequential and concurrent replay of one operation identity converge on the same authoritative Request and create no duplicate; a backend commit followed by a lost/unreadable response reconciles to the already-created Request; a definitively rejected operation (`400 INVALID_OPERATION_ID`, `403 OPERATION_UNAUTHORIZED`, and the ordinary pre-write validation/quota/rate-limit refusals) creates no Request and permits a later intentional submission with a fresh identity; replay of an already-created operation consumes no additional daily quota while a genuinely distinct create still does; cross-participant reconciliation is refused generically with no private detail disclosed; the operation tombstone (`RequestOperation`) survives Request removal; presenting an identity whose Request has passed its recovery horizon resolves as terminal `410 OPERATION_EXPIRED` and creates zero Requests; and a fresh intentional operation after expiry creates normally under existing validation and quota rules. `src/createRequestRoute.test.ts` and `src/createRequestRoute.mongo.test.ts` cover this; `models/db.ts` adds the `RequestOperation` ledger and its unique operation-identity index.

iOS coverage (`RequestCreateDurableOperationTests.swift`, `PendingRequestOperationStorage.swift`) proves: a fresh operation identity is minted and its durable recovery record — participant-bound, carrying the exact submitted request fields, and never a raw participant credential — is persisted before transmission begins; the process-lifetime create block is armed only by an ambiguous outcome or a write-uncertain decoded response (`REQUEST_CREATION_FAILED`), never by a definitive non-create; a definitive non-create (including `OPERATION_EXPIRED`, `INVALID_OPERATION_ID`, `OPERATION_UNAUTHORIZED`, and the ordinary pre-write rejection codes) retires the durable record so a later intentional submission mints its own identity; a proven pre-transmission cancellation retires the record it just wrote; and launch reconciliation restores and reuses the exact persisted operation identity and payload rather than reconstructing it heuristically.

At acceptance:

* TypeScript/backend typecheck: passed.
* Complete non-Mongo backend suite: passed at the current recorded D1 run.
* Real-Mongo D1 suite (`src/createRequestRoute.mongo.test.ts`): passed, covering exact-operation replay, concurrency, participant isolation, quota non-double-consumption, the operation tombstone surviving Request removal, terminal expiry/non-resurrection, and a fresh operation after expiry.
* `npm run ci-check` and `git diff --check`: passed.
* `RequestCreateDurableOperationTests`: **21 passed, 0 failed**.
* Complete `CommonPlateiosTests`: **710 passed, 0 failed, 0 skipped**, with a valid inspectable `.xcresult`.
* An independent HIGH-risk review completed with all MUST-FIX findings corrected; a final narrow independent rereview was CLEAN.

**Accepted verification limitation.** The integrated physical-iPhone D1 runtime scenarios were **not executed before acceptance**. The project owner explicitly accepted W3-D1 with this remaining physical-runtime limitation. The automated, simulator, and backend evidence above must **not** be described as proving: actual physical-device process termination at the post-commit/pre-retirement boundary; real physical-device relaunch sequencing; real physical-device network interruption behavior; or visible physical-device convergence after that termination boundary. The remaining unperformed scenarios are:

1. backend commits operation X to Request A → physical app terminates before retiring X → relaunch → the same X reconciles to the same A without creating a duplicate;
2. the physical client handles a terminal expired operation X without resurrecting a Request;
3. a fresh intentional operation Y, submitted after X has become terminal, creates normally.

A separate attempt at a simulator-integrated (non-physical) proof was made and was **blocked by environment/tooling**, not by a D1 correctness defect: the preserved physical-test `APIConfiguration.swift` LAN value was unreachable from the development machine's then-current subnet, and the repository-connected verification agent lacked GUI-input/interactive-LLDB capability needed to drive Simulator UI and hold a deterministic post-commit/pre-retirement breakpoint. That blocked attempt is neither PASS nor FAIL and did not discover a D1 correctness defect. The project owner has accepted this limitation for W3-D1 V1 closeout; see `docs/system-contract.md` section 11.

### Helper Participation Continuity (W3-H2) coverage

W3-H2 is accepted. Backend coverage in `src/claimRouteParticipation.test.ts` and `src/claimRouteParticipation.mongo.test.ts` proves: a participant who releases or passively expires out of a claim cannot successfully reacquire the same request while another eligible participant still can; a failed or raced acquisition attempt that never wins authority consumes no participation; the same verified participant presenting newly issued authority from another installation/device cannot bypass the invariant; concurrent reacquisition attempts preserve one-winner behavior and correctly refuse the prior holder; and H1's one-active-reservation-across-requests invariant remains intact and unaffected. `src/requestParticipation.test.ts` and `src/requestParticipation.mongo.test.ts` prove the marketplace-list exclusion is scoped to exactly the resolving caller's own participant id, leaving every other eligible participant's list unaffected, and that anonymous/unverified browsing is never refused. `src/requestDetailRoute.test.ts` and `src/requestDetailRoute.mongo.test.ts` prove participant-aware detail exposes only the resolving caller's own already-participated boolean alongside the existing public projection and privacy boundary. `src/reservationRoute.test.ts` and `src/reservationRoute.mongo.test.ts` prove the participant-scoped placed-request re-entry read: restoring already-placed/Got It truth only within the request's retained `deleteAt`/`PLACED_RETENTION_MS` horizon, an active `claimed` reservation taking priority over any placement field, and no reservation authority or raw claim token being recreated by re-entry. `models/db.ts`/`app.ts` add the `RequestParticipation` collection and its unique `(requestId, participantId)` index, explicitly established via `RequestParticipation.createIndexes()` before the process accepts claim traffic, with real-Mongo coverage proving the index enforces one successful acquisition per participant per request under concurrency.

iOS coverage adds three focused files: `ActiveRequestsParticipantAuthorityTests.swift` proves the active-requests fetch forwards the caller's verified participant authority header when present and sends none when absent, at both the service and store layers. `RequestDetailStaleParticipationTests.swift` proves the already-participated read decodes correctly (including treating an absent field as `false`), resolves eligible/already-participated from backend truth, resolves unresolved (never fabricated-eligible) on a failed read, discards a result resolved for a participant identity that changed while the read was in flight, and gates both the rendered claim-section state and the `startClaim` action boundary on current-key-aware eligibility truth — a stale or cross-identity result can never enable Reserve. `PlacementReentryContinuationTests.swift` proves the reconstructed Got It/already-placed presentation across settled-sent, settled-failed, and unknown notification outcomes, that no reservation and no placement restores nothing, that a restored confirmation blocks starting a new claim until acknowledged, that a second continuation call never overwrites an already-restored confirmation, and that an active reservation takes priority over any placement field. The complete `CommonPlateiosTests` target passed **744 tests, 0 failed, TEST SUCCEEDED**.

*Superseded presentation (W4-H1 / W4-H1a).* The restored "Got It" confirmation and its "blocks starting a new claim until acknowledged" rule recorded above were W3-H2 acceptance behavior. They no longer describe the app: confirmed placement ends the helper lifecycle and returns to Home automatically, an already-placed relaunch reconstructs no success presentation, and no acknowledgement gate exists (`docs/system-contract.md` sections 5 and 5.1). The durable participation, concurrency, ambiguity, and retention-bound invariants this section proves are unchanged.

At acceptance: `npm run typecheck` passed; `npm test` passed 1,378 tests with 321 Mongo-gated skips; `npm run test:mongo` passed 321 tests across 22 files; complete `CommonPlateiosTests` passed 744 tests, 0 failed, TEST SUCCEEDED; `git diff --check` passed. An independent HIGH-risk review identified a contract conflict (Change Email / principal-scoped participation, resolved by the project owner as principal-scoped per `docs/system-contract.md` section 5.1) and four correctness-critical findings (stale marketplace/detail Reserve affordance, unverified startup index establishment, unbounded placed re-entry recovery, and insufficient production-boundary proof beyond source inspection); all four were addressed during implementation and a focused rereview found no remaining engineering finding.

**Accepted verification limitation.** The repository has no iOS UI-test target, so the literal SwiftUI stale-detail render/tap scheduling sequence — a visible Reserve affordance disabling itself on screen, and an actual tap being gated in real `RequestDetailView` rendering — was not driven end-to-end through UI automation or physical-device interaction. The accepted evidence instead covers: current-key-aware production eligibility/action logic directly (`RequestDetailStaleParticipationTests.swift`); production `startClaim` action-boundary wiring; backend authoritative reacquisition refusal; real-Mongo persistence/concurrency proof for the participation ledger and its unique index; participant-scoped list/detail behavior and privacy isolation; the complete `CommonPlateiosTests` target; and independent HIGH-risk review plus focused rereviews ending CLEAN. This is an accepted verification limitation, not a failed or pending correctness check, and must not be described as UI-test or physical-device proof.

### Remove Verified Identity (W3-I4) coverage

W3-I4 is accepted. Focused `RemoveEmailTests` reached 19/19 and the complete `CommonPlateiosTests` target reached 763/763 with 0 failures before the final literal-only copy correction; that correction was verified by source/diff inspection and `git diff --check` passed. An independent rereview established that the H1/D1 cold-launch race identified against the removal-safety gating was closed, that unknown/inconclusive removal-safety states fail closed rather than allowing removal, and that the ambiguous-fulfillment-recovery blocking case is a meaningful blocker rather than a redundant one.

**Accepted verification limitation.** The final focused `RemoveEmailTests` rerun against the literal-only copy correction was attempted twice but could not execute because CoreSimulator became unavailable (`CoreSimulatorService connection became invalid`; `Unable to find a device matching the provided destination specifier`). This final focused test state is not claimed as passed; it is an accepted environmental verification limitation, consistent with the pattern already used for W3-I1/W3-H1/W3-D1/W3-H2. Physical-device Keychain-deletion proof was likewise not established and is accepted as unperformed on the same basis.

### Email Request Alert State Authority (W4-N0) coverage

W4-N0 is accepted. Backend coverage (`src/emailAlertState.test.ts`, `src/emailAlertState.mongo.test.ts`, `src/emailAlertStateRoute.test.ts`) proves: the read derives its principal only from `resolveParticipantAuthority`, refusing missing/invalid authority before any Subscriber lookup; no caller-supplied query, body, or header field can select a different address; another participant's Subscriber state cannot affect or be exposed to the caller; absent, pending, and unsubscribed Subscriber rows all read `active: false` and only `status: "confirmed"` reads `active: true`; the read performs no mutation on any path; a database failure answers `503` rather than a false `active: false`; the response carries only `{ "email": { "active": boolean } }` with no Subscriber id, credential, or lifecycle field; and `Cache-Control: private, no-store` / `Vary: x-commonplate-participant` are present on success, authority-refusal, and lookup-failure responses alike. `src/emailAlertState.mongo.test.ts` proves the absent/pending/confirmed/unsubscribed lifecycle mapping and read-only behavior against real MongoDB, in its own `commonplate_email_alert_state_test` database, following the same per-suite-database `Subscriber` isolation convention documented in section 5 below.

iOS coverage (`EmailAlertStateStoreTests.swift`) proves: no credential issues no network call and leaves state `.unknown`; authoritative backend On/Off map exactly to `.active`/`.inactive`; authorization, transport, and decoding failures all leave state `.unknown` rather than a fabricated Off; a response or an authority-invalid rejection resolved under a participant authority that a later Change Email has since replaced is discarded rather than applied to, or retiring, the replacement identity — including when the newer participant's own refresh has already completed, and when the newer participant's refresh is still in flight concurrently with the superseded one; repeated refreshes for the same still-current participant remain coherent; and only `PARTICIPANT_AUTHORITY_INVALID` for the still-current credential invokes the existing participant-authority rejection path, matching `RequestStore.applyParticipantVerdict`.

At acceptance: `npm run typecheck` passed; focused backend N0 suites passed **18/18**; complete `npm test` passed **1,406 passed, 328 Mongo-gated skipped**; `npm run test:mongo` passed **328 tests across 23 files** (against the N0 query/persistence implementation, which a later comment-only correction left unchanged); focused `EmailAlertStateStoreTests` passed **18/18**; complete `CommonPlateiosTests` passed **857 passed, 0 failed, 0 skipped, TEST SUCCEEDED**; `git diff --check` passed. An initial independent HIGH-risk review returned three MUST FIX findings (participant-specific cache isolation, iOS state remaining bound to the current participant across a Change Email race, and current-only authority-rejection retirement) and one SHOULD FIX (a misleading backend comment conflating N0's confirmed-only state with send/delivery eligibility); all four were corrected, and a fresh focused rereview was CLEAN.

A `ReservationWarningTests.testReleaseSucceedsBeforeTheWarningEverFires` timing flake surfaced twice during the fix-round complete-target runs. It was investigated: the test passed standalone in both the pre-fix and post-fix trees, passed as part of its full suite against the unmodified pre-fix tree, and passed again in its full suite and in the complete target against the post-fix tree with no further code change. It does not touch `EmailAlertStateStore`, `EmailAlertStateService`, or any other N0 file. This is recorded as pre-existing `Task.sleep`/`waitUntil` polling flakiness in that unrelated suite, not an N0 defect, and is not a new accepted verification limitation for N0.

No N0-specific physical-device or environmental proof is required or outstanding.

### AI Screenshot Proposal Foundation (W4-S1) coverage

W4-S1 is accepted for the bounded contract-aware fix recorded in the current weekly spec: extending the existing cart-rule checkout-context exclusion to `place your delivery order` and `place your pickup order`. Focused backend coverage lives in `src/screenshotEligibility.test.ts` (the deterministic `evaluateEligibility`/`countMealSwipeMarkers` rule, including the checkout-context exclusion and strict H5), `src/screenshotProposalValidation.test.ts` (forbidden-field refusal, `.strict()` schema validation, bare yes/no sanitization, vendor resolution/ambiguity, and meal-swipe corroboration), `src/screenshotProposalProvider.test.ts` (the stateless single-attempt OpenAI adapter and its error-kind classification), and `src/screenshotProposalRoute.test.ts` (participant-authority-first ordering, the route's own bounded image transport and structural PNG/JPEG validation, fail-closed missing-provider-configuration behavior, and that no path reaches `createRequest`/`RequestOperation`/quota/notifications). Focused iOS coverage lives in `ScreenshotProposalStoreTests.swift`. These files are ordinary `*.test.ts`/`XCTest` suites and are collected automatically by `npm test` and the complete `CommonPlateiosTests` target; this documentation sync did not rerun those runtime suites, so exact pass counts are not restated here — they are the implementing/reviewing session's record, not invented for this sync.

**Apple Vision eligibility-corpus verification (local-only research artifact; not committed).** A 71-image eligibility corpus, a companion Apple Vision OCR harness, and an OpenAI provider-qualification harness were used during W4-S1 to verify the deterministic eligibility rule end to end. None of that evaluation workspace — corpus images, harness code, run scripts, or result artifacts — is committed to this repository or reproducible from a fresh clone. It is kept local-only because the evaluation workspace mixes real personal order screenshots, real extracted OCR/provider-response text, and third-party campus-dining/Grubhub material with no cleared redistribution status, and no boundary short of excluding the whole workspace reliably kept that content out of Git history. This is a distribution/retention decision, not a statement that the verification didn't happen or isn't trustworthy.

The verification itself re-ran the actual production `evaluateEligibility`/`countMealSwipeMarkers` implementations (`src/screenshotEligibility.ts`) against production-equivalent Apple Vision OCR output for all 71 corpus images, so it exercised real production logic rather than a reimplementation of the rule. The accepted post-fix result is 71/71 processed, 0 load failures, 0 OCR failures, and an all-71 confusion matrix of 12 TP / 55 TN / 2 FP / 2 FN. This establishes: the bounded checkout-context fix rejects the intended false positive; a compound screenshot with a visible receipt/payment sheet is judged on whether its exposed supported evidence independently qualifies, not disqualified merely because a receipt is visible; and strict H5 is unchanged. One historical-detail fixture may remain an accepted false negative when Apple Vision fails to recognize the required quantity-prefix digit — a documented V1 limitation (manual entry remains available), not a defect. Two deliberate synthetic vocabulary/chrome-mimicking fixtures are accepted false positives outside the V1 authenticity guarantee (`docs/system-contract.md` section 12). This result contributed to W4-S1 acceptance; it is not evidence about a signed Release build, production provider credentials/reachability, or a physical device — those remain Week 5 gates (`docs/system-contract.md` section 11).

Because the corpus and harnesses are not distributed, a fresh clone cannot reproduce this historical 71-image run from committed artifacts alone. Rerunning it in the future requires rebuilding an equivalent local corpus/harness against the production eligibility functions; the result above stands as the accepted historical evidence until such a rerun happens.

### Home & Navigation Architecture (W4-H2) coverage

W4-H2 is accepted. Backend coverage proves the expanded ownership/self-claim contract: participant-scoped request-list ownership projection (verified owner receives an affirmative ownership signal for their own eligible open request only; another verified participant and anonymous/unresolved callers receive no participant-specific ownership truth for it; own requests are not filtered out of the list; `requesterParticipantId`, requester email, and other private identity never enter the response; existing public-list privacy projection and participant-aware filtering remain intact) and the authoritative backend self-claim guard inside the existing atomic conditional claim mutation (direct self-claim is refused using the existing conflict-style error envelope, creates no reservation/helper-binding/participation side effect, and leaves another eligible participant's claim, existing one-active-reservation behavior, and claim visibility/expiry/atomicity unaffected). iOS coverage proves `FoodRequest` ownership truth (own/notOwn/unresolved) driven only by authoritative backend signal rather than an installation-local heuristic, the approved YOUR REQUEST presentation, owner-side withholding of the Help/Reserve action, and unresolved ownership failing closed for actionability; Home root/navigation, live-board entry and ASAP-then-scheduled ordering, `Continue Helping` continuation, Low Activity/Empty/Unavailable presentation, Settings navigation and identity presentation, verified/unverified Request Alerts entry and verification-return continuation, and the native-`.refreshable`-only functional refresh contract (initial-load and manual-refresh 5-second deadlines, recovery-only checkmark, stale-response/generation safety, and baseline Reduce Motion correctness) recorded in `docs/system-contract.md` section 1.3.

At the final ownership rereview: `npm run typecheck` passed; focused backend ownership/detail/privacy/self-claim suites passed **90 passed, 23 Mongo-gated skipped in that focused run**; complete `npm test` passed **1,424 passed, 328 Mongo-gated skipped**; `npm run test:mongo` passed **328 passed across 23 files**. Focused iOS ownership suites passed **40 passed**: `RequestOwnershipLifecycleTests` — 15, `RequestOwnershipAuthorityContextTests` — 16, `RequestOwnershipReconciliationTests` — 5, `RequestOwnershipTests` — 4. The latest complete iOS run after the ownership implementation, `CommonPlateiosTests`, passed **914 passed, 0 failed, TEST SUCCEEDED**.

**Final rereview scope.** The final independent rereviewer did not independently rerun the complete 914-test `CommonPlateiosTests` target; it inspected the prior current-tree complete result above and reran the focused ownership evidence (the 90 backend and 40 iOS totals above) fresh. Do not describe the complete 914-test run as having been independently rerun at the final rereview; it is the most recent complete-target result on the accepted tree, not evidence reproduced by that final review pass.

**Known, accepted limitations.** The repository has no iOS UI-test target: the unresolved-ownership UI branch (help/reserve withheld while ownership resolves) is proven through production ownership-resolution predicate/action-boundary logic and the complete iOS target rather than through UI automation or physical-device interaction. Backend detail ownership is proven through production handler/builder behavior with mocked persistence for the unit layer, plus real-Mongo coverage for the list/claim mutation, rather than a fully mounted HTTP+Mongo detail request end to end. The current authored refresh visual/motion polish (pull-cue choreography, easing, arrow-to-symbol transform quality, spinner/symbol treatment) is not acceptance proof of anything beyond H2's functional refresh contract; it is a known, accepted visual/experience limitation deferred to W4-H3 (`docs/system-contract.md` section 1.3), not a defect; W4-H3 has since been accepted (`docs/system-contract.md` section 1.5; see the W4-H3 subsection in section 9). A Simulator-only defect (native `.refreshable` not activating under Simulator's indirect-pointer/trackpad input path; see the current weekly spec's W4-H2 section) was investigated but could not be resolved further without a physical device; the repository/session contains no record of a physical-iPhone reproduction-or-rule-out walkthrough for this specific defect, and this is not claimed as performed.

### Request Creation Eligibility Authority (W4-Q1) coverage

W4-Q1 is accepted. Backend coverage (`src/requestDailyQuota.test.ts`, `src/requestEligibility.test.ts`, `src/requestEligibilityRoute.test.ts`, `src/requestEligibility.mongo.test.ts`) proves: the read derives its principal only from `resolveParticipantAuthority`, refusing missing/invalid authority before any count; no caller-supplied query, body, or header field can select a different principal; distinct exact normalized principals retain distinct current allowances; `eligible` below three and `exhausted` at three and above, with no count/remaining/reset/identity/credential/request data in the response; the NY campus-day rollover at `America/New_York` midnight; the read and `POST /api/request` call the same extracted `src/requestDailyQuota.ts` count/threshold authority (create's own daily-limit suites in `src/createRequestRoute.test.ts` pass unchanged against the shared extraction); a count/database failure fails closed as unavailable rather than eligible or exhausted; `Cache-Control: private, no-store` and `Vary: x-commonplate-participant` cover success and every refusal/failure path, including a mounted rate-limited `429` proven through a real Express/HTTP server rather than a direct handler call; and the read performs no Request/RequestOperation/participant/notification/subscription/installation mutation. `src/requestEligibility.mongo.test.ts` additionally proves the current-as-of-read boundary against real MongoDB: an eligible Q1 read followed by racing writes that reach the threshold, then a real `createRequest` invocation for the same participant carrying a fresh valid `x-commonplate-operation-id`, independently refuses with `429 REQUEST_LIMIT_REACHED`, creates no additional `Request`, writes no `RequestOperation` ledger row for the presented identity, and starts no requester-confirmation email, helper-alert, or helper-push side effect.

iOS coverage (`RequestEligibilityTests.swift`) proves: `RequestService.fetchRequestCreationEligibility` decodes `eligible`/`exhausted` and sends the participant header, and fails decoding on an unrecognized wire value rather than guessing; `RequestStore.resolveRequestCreationEligibility()` resolves `.eligible`/`.exhausted` only from a successfully decoded backend result for the still-current authority; no participant identity issues no network call and leaves `.unknown`; transport failure, decoding failure, and an unrelated server refusal all leave `.unknown`; a result resolved for an authority a later Change Email has since replaced is discarded as `.unknown` rather than applied to the replacement identity, while the unchanged-identity path still resolves normally; genuine mid-flight cancellation (a `Task` cancelled while a gated in-flight stub is provably still waiting, not merely a call that never reaches the network) resolves `.unknown` without retiring identity; and a current `PARTICIPANT_AUTHORITY_INVALID` refusal invokes the same `applyParticipantVerdict`/authority-retirement path every other participant-gated `RequestStore` method already uses, while a stale rejection for a since-replaced authority cannot retire the replacement.

At acceptance: `npm run typecheck` passed; `npm test` passed **1,537 passed, 335 Mongo-gated skipped**; `npm run test:mongo` passed **335 tests across 24 files**; complete `CommonPlateiosTests` passed **1,001 passed, 0 failed, TEST SUCCEEDED**; `git diff --check` passed. Independent HIGH-risk review of this evidence ended CLEAN.

No Q1-specific physical-device or environmental proof is required or outstanding.

### W4-R2 Requester Journey Integration acceptance

W4-R2 is accepted. It is an iOS-only slice: per section 11, its minimum verification is focused suites plus the complete `CommonPlateiosTests` target. No backend, Mongo, or browser-bundle check was required or rerun for R2, and none is claimed here.

Automated coverage proves: the pushed (not sheeted) Request Food navigation and its preserved entry-verification/draft/re-entry behavior; the Q1-consuming early eligibility boundary, including the distinct retryable unknown/error presentation versus the unchanged non-retryable exhausted presentation, and that `Try Again` performs a fresh eligibility read rather than reusing a cached result; the in-memory draft-session lifetime across ordinary departure and background/foreground transitions, including manual-outranks-AI and no-mutation-by-stale-analysis; Timing's ASAP/Later presentation, quick-time choices, and native `Choose time` replacing its own label; the Screenshot Assistance completion acknowledgement's three distinct outcome states; the first-use consent/disclosure gate, its Off-state discoverable re-entry path (`Turn on Screenshot Assistance`), and the independence of consent/enabled state from Screenshot Help completion state; Screenshot Help's centered-overlay presentation and `Got it` dismissal back to the same draft; Posting/Success timing (the tinted native `ProgressView`, the single success haptic, and the ~1.6-second Success dwell) and D1 unresolved-ambiguity's continued haptic-free distinctness from definitive failure; that R2 performs no Home insertion/reorder/highlight and instead relies on H4's authoritative fetch (section 1.4); and the `YOUR REQUEST` eyebrow suppression scoped to the dedicated owned-request zone only. Focused coverage lives in `RequestFoodEntryTests.swift`, `RequestFoodDraftSessionTests.swift`, `RequestCreationViewTests.swift`, `RequestTimingContractTests.swift`, `ScreenshotProposalStoreTests.swift`, `ScreenshotProposalDisclosurePresentationTests.swift`, `ScreenshotHelpPresentationTests.swift`, `RemoveEmailTests.swift`, `RemoveEmailStatusKindTests.swift`, `RequestOwnershipLifecycleTests.swift`, and `RequestCreateDurableOperationTests.swift`, alongside updates to `MealSwipeQuantityTests.swift`, `OnboardingPresentationTests.swift`, `RequestEligibilityTests.swift`, `RequestFetchingTests.swift`, and `SettingsRequestAlertsToggleTests.swift`.

At acceptance: a final independent rereview passed; the Q1 production-transition proof (the early-boundary consuming the real Q1 read rather than a stub) passed; the Remove Email overlapping-read presentation-state proof (an in-flight check versus a settled-unresolved check resolving to distinct presentations without racing) passed; a focused final rereview passed **63 passed, 0 failed**; the complete `CommonPlateiosTests` target passed **1,104 passed, 0 failed**; `git diff --check` and `git diff --cached --check` were both clean, with nothing staged at the final rereview. The project owner completed the required physical-device walkthroughs — covering Request Food navigation, Q1 eligibility presentation, draft continuity, Timing, Screenshot Assistance consent/Off-state/Help, Posting/Success motion and haptics, and Remove Email presentation — and explicitly accepted W4-R2 on 2026-09-07.

**Known, accepted limitations.** The repository still has no iOS UI-test target: rendered layout, gesture, and accessibility-traversal properties for the items above are the same class of accepted limitation recorded for W4-H2/H4 and are established by physical-device walkthrough rather than automated UI verification. W4-R2 acceptance does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (`docs/system-contract.md` section 11). The new-request push notification's title/body composition remains W4-N1's future work, not R2's (see the W3-C1 coverage subsection's carve-out above); R2's own acceptance evidence does not touch that payload.

### Cross-Participant Text Filtering (W4-U1.1) acceptance

W4-U1.1 is accepted (the project owner, 2026-10-13). It is a cross-stack slice (backend authority plus iOS presentation) and is grandfathered under the pre-VP1 complete-target rule (see the prospective transition in the verification-tier policy): its contracted gate was the complete `CommonPlateiosTests` target plus the complete backend gates on its final candidate, and those were satisfied. Acceptance is not a commit; the evidence below is attached to the uncommitted final integrated candidate (`w4-u1.1-integration` on `82274ff`, 30 dirty paths, nothing staged), not to a landed commit. The pre-integration acceptance candidate (`w4-u1.1-filtering` on `56c0a17`) is the historical origin of the accepted behavior; results measured on it are labeled as such below.

**Focused verification (rerun after a change in this area).**

```bash
npm run typecheck
npm test -- src/participantTextFilter.test.ts src/requestTextFilteringRoute.test.ts \
  src/fulfillmentMessageFilteringRoute.test.ts src/fulfillmentRoute.test.ts \
  src/reservationRoute.test.ts src/createRequestRoute.test.ts models/db.test.ts
npm run test:mongo   # createRequestRoute.mongo.test.ts, fulfillmentRoute.mongo.test.ts; entire suite, no selective form (section 5)
```

iOS classes added by U1.1: `RequestTextModerationTests`, `HelperMessageSuppressionTests`, `HelperSuccessVoiceOverTimingTests`, `HelperSuccessAnnouncementFocusTests`. Modified neighbors: `HelperHeldRequestNavigationTests`, `HelperSuccessForegroundProgressionTests` (run with the command in section 9 using one `-only-testing:CommonPlateiosTests/<Class>` filter per class, plus affected-neighbor classes per the change-type matrix in section 11). `APIConfigurationDebugOverrideTests` belongs to the Debug endpoint override, not to U1.1 behavior, and is not part of the U1.1 focused set. These classes, and the three new backend test files (`src/participantTextFilter.test.ts`, `src/requestTextFilteringRoute.test.ts`, `src/fulfillmentMessageFilteringRoute.test.ts`), are members of the routing manifests in section 9 as of the final integrated candidate.

**Automated evidence.** On the pre-integration acceptance candidate (`w4-u1.1-filtering` on `56c0a17`; historical, its base predates W4-QA1, W4-VP1, and W4-H3): focused iOS 126 executed, 0 failed; complete `CommonPlateiosTests` 1,944 executed, 0 failed, 0 skipped, TEST SUCCEEDED; `npm run typecheck` passed; `npm test` 2,678 passed; `npm run test:mongo` 380 of 380 passed (real replica set); `git diff --check` clean. A final independent whole-slice review returned clean with non-blocking findings. On the final integrated candidate (`w4-u1.1-integration` on `82274ff`, the U1.1 acceptance/commit baseline): `npm run typecheck` passed; `npm test` 2,873 passed, 409 Mongo-gated skipped, 0 failed (70 files passed, 29 skipped); `npm run test:mongo` 409 of 409 passed across 29 files (real isolated replica set); focused iOS groups `HelperSuccess` 128, `HelperFulfillmentCore` 255, `RequesterCore` 479, `HostedRequesterUI` 67, `HomeRefresh` 223, `IdentityAndNavigation` 218, the `AccessibilitySensitive` overlay 539, and `APIConfigurationDebugOverrideTests` 11 executed, 0 failed, 0 skipped; complete `CommonPlateiosTests` 2,085 executed, 0 failed, 0 skipped, TEST SUCCEEDED; `git diff --check` clean. Integration changed no accepted U1.1 behavior, so the independent review and physical-device rows above were not repeated. These totals are a point-in-time record, not a required count: the totals for a later change come from rerunning the commands above on that change.

**What the automation establishes.** The deterministic filter's accepted and refused classes, including the contextual and masked-letter rules; `REQUEST_TEXT_NOT_ALLOWED` ordering (after authority, exact-operation reconciliation, and canonical validation; before the quota read and every creation side effect) and its no-Request, no-ledger-row, no-quota, no-notification refusal on real Mongo; fulfillment placement exactly-once with a suppressed Message neither persisted nor emailed and the content-free `contactMessageSuppressed` marker written in the same atomic update; affirmative-only `messageSuppressed` on the fulfillment response and participant-scoped placed read, absent from every public projection; the fixed Pickup ETA set; iOS refusal classification, draft preservation and notice retirement; same-flow suppression recovery without fabrication; and the success state's content, completion-aware VoiceOver gate, single repost, and bounded fallback.

**Physical-device proof (non-automatable; the project owner-observed on a physical iPhone).** The remaining rows passed: suppressed success with headline, `Message not sent`, and the guideline explanation each heard completely, then automatic Home; ordinary success for each email-result variant; slower speech rate; Reduce Motion; large Dynamic Type; interruption (at most one re-announcement, no second haptic, one Home return); VoiceOver off (approximately 2-second dwell, unchanged); and the project owner's visual-readability judgement of the suppression copy inside that dwell. These rows are manual device observation, not part of any test suite, and any change to the success timing, announcement, or copy requires them again.

**Known, accepted limitation (not an ideal-behavior claim).** With VoiceOver enabled during helper success, focus migration from the removed `Finish helping` control can occasionally interrupt the initial explicit success announcement and trigger the single allowed repost, so the beginning may be heard twice (approximately `Thanks for… thanks for…`) before the complete truthful message is spoken. The project owner accepted this for TestFlight as non-blocking; it is deferred to W4-A1, which must reevaluate it in integrated VoiceOver/focus proof. No automated check or simulator observation establishes real VoiceOver focus or speech behavior. The filter's uncovered classes (section 6 of `docs/system-contract.md`) are an accepted bounded-precision limitation, not unverified behavior.

### Participant Blocking & Interaction Fencing (W4-U1.3) acceptance

W4-U1.3 is accepted (the project owner, 2026-10-15). It is a cross-stack slice (backend authority plus iOS presentation) and is grandfathered under the pre-VP1 complete-target rule (see the prospective transition in the verification-tier policy): its contracted gates were `npm run typecheck`, complete `npm test`, `npm run test:mongo`, and the complete `CommonPlateiosTests` target on its final candidate. The evidence below was produced against the accepted candidate bytes, based on `main` at `eeed898`, identified by a 40-path set whose SHA-256 manifest (`shasum -a 256` per path, then `shasum -a 256` over that listing, in the closeout path-list order) is `78f540eedc7560fd5054f75d2b14dbf67392709a12e6603070466e033a45d4dd`. Unrelated S2.1 screenshot-evaluation work (its evaluation sources, golden data, and the `/eval/` ignore line) was excluded from the U1.3 candidate and is not part of U1.3's accepted set. Separately, test-hygiene cleanup to `HelperHeldRequestNavigationTests` and comment-only cleanup in `FulfillRequestView.swift`, and the Settings-gear hit-target polish in `HomeExchangeView.swift`, accompany the U1.3 closeout; they are not participant-block behavior. The totals below were reported to the closeout by the implementing and verification sessions; the documentation sync did not re-execute them. They are a point-in-time record, not a required count.

**Focused verification (rerun after a change in this area).**

```bash
npm run typecheck
npm test -- src/claimRoute.test.ts src/claimRouteParticipation.test.ts \
  src/requestAvailability.test.ts src/requestDetailOwnership.test.ts \
  src/reservationRoute.test.ts src/participantBlockWiring.test.ts
npm run test:mongo   # includes participantBlock.mongo.test.ts and participantBlockPostYes.mongo.test.ts; entire suite, no selective form (section 5)
```

iOS classes added by U1.3: `ParticipantBlockTests`, `ParticipantBlockEntryTests`, `ParticipantBlockManagementTests`, `ParticipantBlockReconstructionTests`, `ParticipantBlockPostYesAutonomyTests`, `ParticipantBlockPostYesStopHomeTests`, `ParticipantBlockYesNavigationTests`, `ParticipantBlockActivePillScrollTests`. Modified neighbor: `HelperJourneyFulfillmentTests` (its no-paragraph assertion stays strict after excluding exactly the permitted restricted-state notice span). Run them with the section 9 command and one `-only-testing:CommonPlateiosTests/<Class>` filter per class plus the neighbors named by the `ParticipantBlocking` group in the routing manifests. `HelperHeldRequestNavigationTests` is a neighbor but carries pre-existing H1 churn that U1.3 neither made nor owns.

**Automated evidence (as reported).** Backend final behavioral candidate: `npm run typecheck` passed; `npm test` 3,040 passed, 0 failed, with the Mongo-gated suites skipped by configuration there as expected; `npm run test:mongo` 504 of 504 passed across 31 files on a real replica set, including the focused C1 refusal and C3 stop-destination proof and the block-vs-claim, Yes-vs-release/re-claim/expiry, and extend/Stop/fulfill concurrency proof. iOS final presentation candidate (the `BLOCK ACTIVE` pill, supporting copy, and orientation scroll): the focused final pill/scroll affected suites 132 tests, 0 failures; complete `CommonPlateiosTests` 2,190 executed, 0 failures, 2 skipped by configuration (gated tests; the closeout report did not itemize them), TEST SUCCEEDED. Earlier complete-target counts from before the C1–C3 and presentation changes are superseded and are not the accepted baseline. `git diff --check` clean; nothing staged.

**What the automation establishes.** Contextual-only Block creation and refusal of every non-contextual target; no participant identifier in any projection, error, or label; board exclusion in both directions including double-Block; Request Detail fencing without disclosing the Block as the reason and its requester/bound-helper exemption; claim refusal inside the claim transaction and write-skew serialization against a concurrent Block; `No` as atomic Block plus ordinary release, including the paused outcome that commits neither; `Yes` writing the post-Yes marker atomically and pinned to the exact reservation, and a late or lost-authority `Yes` answering `409 RESERVATION_STATE_CHANGED` with no Block row, fence bump, marker, or change to another helper's reservation; the expiry-boundary `Yes` still accepted for the same bound helper; Add 5 minutes with no Block-specific refusal in either direction; post-Yes Stop never reopening the request, passive expiry never reopening it, Unblock never reopening it, the stopped helper unable to extend, release, fulfill, or re-claim, Stop without the marker unchanged, and fulfillment winning a race; the marker, owner, and direction never projected; placement never refused or altered, the withheld Message and `Reply-To`, and the affirmative-only `messageWithheld`; Unblock ownership, prospective-only behavior, and indistinguishable missing/not-owned answers; Block durability past Request TTL; the iOS Block / Yes / No / Unblock store flows, ambiguity never retried, no fabricated release or restriction after an ambiguous response, stale-response guards, the caller-owned versus reconstructed notices, post-Unblock authoritative reconciliation staying conservative on failure, Stop and Back destinations, the Blocked Students route and rows, the Settings gear's explicit hit region, and the exact pill and supporting copy with its tint usage and scroll trigger and non-trigger paths. Several iOS presentation assertions are source-structure checks, because the repository has no iOS UI-test target.

**Simulator evidence (the project owner-observed and session-observed on the Simulator; not physical-device proof).** Block → `Yes` retains Add 5 minutes and Stop helping; direct contact (Message) is suppressed; Yes → Unblock → Stop → Home; the same sequence after relaunch/reconstruction; the C1 refusal fixture (a `Yes` after reservation authority was lost is refused with no Block); Finish helping still succeeds on a valid `Yes` path; and the final pill and scroll presentation only where it was actually observed. These runs used a local backend and harness (section 5, Local QA harness), so they do not prove real email delivery, APNs, or signed-build behavior.

**Physical-device proof (non-automatable; the project owner-observed on a physical iPhone).** The Settings gear responds on the first tap; the Helping `•••` opens; Block → `Yes`; Add 5 minutes and Stop helping visible and Finish helping not forced; Message suppressed; Yes → Unblock restores normal Helping; Stop → Home with no Active Requests destination and no Continue Helping card; a read-only backend inspection confirmed the stopped request non-claimable and the helper's reservation lock released. The project owner also gave final visual approval of the accent `BLOCK ACTIVE` pill, its supporting copy, and the auto-scroll. These rows are manual device observation, not part of any suite, and any change to the Helping restricted-state presentation, the safety menus, or the Blocked Students layout requires them again.

**Known, accepted limits and what is not established.** The requester-side timing/state inference for a post-Yes stopped request, the deleted-request `404` outcome, the fail-rather-than-Block outcome for a lost-authority `Yes`, and the absence of a requester → helper Block entry after pickup are accepted product limitations recorded in `docs/system-contract.md` section 5.3, not unverified behavior. Not established by any evidence here: APNs or other provider behavior, Release/Archive/TestFlight signing or environment behavior (still open, section 11 of the system contract), a broader device or OS matrix, VoiceOver and Dynamic Type behavior of the new surfaces (W4-A1), and the foreground reservation-warning navigation rewrite (a W4-R5-owned defect, not exercised as U1.3 behavior).

### Placed-Order Evidence & Manual Fulfillment (W4-H1a) acceptance

W4-H1a is accepted (the project owner, 2026-10-16), with the verification limitations and deferrals recorded below. It is a cross-stack slice (backend authority plus iOS presentation) and is grandfathered under the pre-VP1 complete-target rule (see the prospective transition in the verification-tier policy): its contracted gates were `npm run typecheck`, complete `npm test`, `npm run test:mongo`, and the complete `CommonPlateiosTests` target on its final candidate. The candidate is based on `main` at `b37972f`, so its totals are not additive to the later-baseline figures in section 13. The evidence below was reported by the H1a slice and review sessions; the acceptance closeout and documentation sync did not rerun it, and changed no production or test code.

**Focused verification (rerun after a change in this area).**

```bash
npm run typecheck
npm test -- src/fulfillmentEvidenceRoute.test.ts src/fulfillmentRoute.test.ts \
  src/fulfillmentMessageFilteringRoute.test.ts src/publicActionsRoutes.test.ts \
  scripts/qa-environment.test.ts
npm run test:mongo   # includes fulfillmentRoute.mongo.test.ts, participantBlock*.mongo.test.ts and qa-environment.mongo.test.ts; entire suite, no selective form (section 5)
```

iOS classes added by H1a: `PlacedOrderEvidenceFlowTests` and `PlacedOrderScreenshotNormalizerTests`, with the shared fixtures in `PlacedOrderScreenshotFixtures.swift`. Modified neighbors include `ClaimFlowTests`, `HelperJourneyFulfillmentTests`, `HelperCompletionLifecycleTests`, `HelperHeldRequestNavigationTests`, `HelperMessageSuppressionTests`, `ParticipantGateTests`, `RemoveEmailTests`, the `Reservation*` classes, and the `ParticipantBlock*` classes (fixtures adopt the required screenshot). Run them with the section 9 command and one `-only-testing:CommonPlateiosTests/<Class>` filter per class.

**Automated evidence (as reported).** Backend: `npm run typecheck` passed; `npm test` 2,958 passed, 519 skipped by Mongo configuration, 0 failed; `npm run test:mongo` 519 passed across 31 files, 0 failed, on a real replica set. iOS final F-P1 candidate: focused `PlacedOrderEvidenceFlowTests` 27 of 27; complete `CommonPlateiosTests` **2,228 executed, 0 failed, 0 skipped**, TEST SUCCEEDED, exit 0, on the final tree. The first attempt at that final run failed before any test executed on a codesign/resource-fork problem with derived data under `~/Desktop`; the rerun used a derived-data path outside it and passed with no code change, so the failure is environmental, not a product result. Earlier complete runs on this slice failed only a load-dependent hosted-geometry/motion test (a different set each time, all passing in isolation); the accepted run was on a quiet host. The F-P1 change (removal of the helper-facing privacy line) touched only `FulfillRequestView.swift` and `PlacedOrderEvidenceFlowTests.swift`; no backend file changed after the backend gates ran, so they were not rerun. `git diff --check` passed.

**What the automation establishes.** Backend (`fulfillmentEvidenceRoute.test.ts` and the `W4-H1a required placed-order evidence` block in `fulfillmentRoute.mongo.test.ts`): a missing, invalid, corrupt, truncated, oversized, or wrong-type screenshot is refused with the dedicated content-free code before any mutation, in both authorization shapes, with the exact 1,500,000-byte cap accepted and one byte more refused; refusal precedes the Message filter and ordinary payload refusal keeps its own code; the route-owned 3 MB parser holds a body the 100 KB global parser refuses, is registered after the rate limiter, answers an over-limit or malformed body content-free, and never converts a post-parse handler failure into a definitive 400; the evidence row joins the placement transaction (an evidence insert failure aborts the whole placement with no placed Request, ledger row, evidence, lock change, or email; an inserted row rolls back with a later abort); a wrong token or participant writes no evidence; a resend cannot replace or duplicate it and the original bytes remain; concurrent attempts with different images leave exactly one winner's evidence; the unique `requestId` and TTL indexes exist with the contracted names, and `deleteAt` equals the placed Request's; the image is `select: false` and absent from every response, projection, the fulfillment email, the Request update, and every log line; a suppressed Message and a post-commit email failure each leave placement and evidence in place; and the QA reset classifies and removes `PlacementEvidence`. iOS: the on-device normalization bounds (2000 px edge, never upscaled, EXIF orientation, PNG/APNG/transparent and HEIC sources to JPEG, one `0.5` fallback then refusal, the 1.5 MB cap, truncated or non-image bytes refused); the wire payload; selection held privately by the store for the active reservation and ended by confirmed placement; Finish helping unavailable and the store unreachable without a selection; Change replaces the selection; a late selection never alters an issued ambiguous submission; both authorization shapes and the ambiguous resend carry the identical image; only the screenshot refusal maps to the screenshot message while network loss stays ambiguity and server failure keeps its own classification; a relaunch-restored reservation asks for the screenshot again while an already-placed reconciliation asks for none; requester-email failure remains the accepted success; and, by source inspection of the view, the F-P1 structure (no helper-facing disclosure, the label and `Required`, the chooser, the attached branch, the notice branch). Source-structure assertions are source inspection, not rendered UI.

**Independent review.** A fresh independent HIGH-risk review of the full H1a candidate returned CLEAN, and a final bounded review of the F-P1 correction returned CLEAN.

**Physical-device evidence (the project owner-observed on a physical iPhone, 2026-10-16).** Debug build against a throwaway local QA backend through the Debug base-URL override; manual/environmental verification, not part of any suite. Passed: initial Required state; real PhotosPicker selection; attached state; Change/reselect with manual fields preserved; dark mode; largest Dynamic Type; Reduce Motion; VoiceOver including `Change order screenshot`; real upload through Finish helping with persisted-evidence inspection through QA tooling (a JPEG of 920 by 2000 px, `byteLength` at most 1.5 MB and equal to the stored bytes, evidence `deleteAt` equal to the Request's `deleteAt`, one fulfillment row); stored-image fidelity; ordinary success returning to Home exactly once with one haptic; the failed-requester-email presentation; the U1.1 Message-suppressed path (marker persisted, the profane Message stored nowhere); relaunch while claimed followed by reselection; and Assistance Off and On both non-AI. After the F-P1 change, the project owner re-observed on the final candidate the pre-selection state (`Order screenshot`, right-aligned `Required`, `Choose Grubhub screenshot`, no privacy line, no replacement sentence, no red missing-evidence error, Finish helping disabled) plus a dark-mode glance and a largest-Dynamic-Type glance, all passing; the other physical rows above were produced before F-P1 and carry forward because F-P1 removed only that line. The Grubhub open-failure notice appeared and return/restoration and no-mutation passed on the failing handoff (see P15 below).

**Accepted verification limitations (the project owner, 2026-10-16). These are not passes.**

- *P5 — definitive invalid/refused screenshot presentation was not physically observed.* No safe controlled physical fault-injection mechanism exists and none was built. The refusal, mapping, no-mutation, and chooser-recovery behavior rests on automated and independent-review evidence.
- *P17 — an ambiguous fulfillment response was not physically observed.* The same applies; the snapshot-carries-identical-bytes, one-resend, no-reselection, no-second-order, and relaunch-reconciliation behavior rests on automated and independent-review evidence.
- *HEIC source container.* The original source format of the camera photo chosen through PhotosPicker was not independently proven. The real PhotosPicker and image path and the normalized persisted JPEG were physically exercised; the HEIC-to-JPEG conversion itself is proven by the automated normalizer test.

**Not established, and routed elsewhere.** P15 — Open Grubhub failed on a physical iPhone with Grubhub installed — is an inherited parent-W4-H1 integration issue that predates H1a and is outside its diff. It does not block H1a acceptance, H1a changed no handoff behavior, and this entry is not evidence that the Grubhub handoff works; it must be resolved before parent-H1 acceptance and the integrated walkthrough. The attached-row width preference (F-P3), the future email/messaging/Home questions (F-P13), and the chooser/button presentation (width, fill or background treatment, and centered text, deferred to the final integrated W4-H1 walkthrough and W4-A1 visual reconciliation, with no H1a-specific treatment) are deferred as recorded in the weekly spec. Stored-image fidelity was verified through QA tooling rather than an app screen, because H1a has no evidence viewer (W4-R3 owns it). Not established by any evidence here: requester viewing of the evidence, Helper Screenshot Assistance (W4-H1b), request/account-deletion classification of `PlacementEvidence` (W4-P2/R5), provider email delivery, APNs behavior, and Release/Archive/TestFlight signing or environment behavior (still open, section 11 of the system contract). Simulator and unit results above are not device proof.

### Requester Venue Anchoring & Recovery (W4-R4.2) acceptance

W4-R4.2 is accepted (the project owner, 2026-10-18), with the verification limitations recorded below. It is a cross-stack contract change (a new shared vector file consumed by a backend suite and an iOS suite, plus iOS runtime), and its first READY transition follows W4-VP1, so the verification-tier policy applies: its explicit slice contract required `npm run typecheck`, complete `npm test`, the complete `CommonPlateiosTests` target, Release builds, fingerprint equality, one HIGH-risk independent review, and a physical-iPhone pass, on the final candidate after its last change. `npm run test:mongo` was not run: R4.2 changes no persistence, transaction, uniqueness, concurrency, or index behavior. The candidate is based on `main` at `38edd30` (W4-H1a) and was uncommitted at acceptance (20 paths: 10 modified, 10 untracked; content digest `bccfa31dfb27a60ba5ff8557c54a4c72550e4fd5`, the SHA-1 over `git diff` followed by the SHA-1 of each untracked file in C-locale order; tracked-patch SHA-256 `7b3efe061e34ceaf8e77fa2ac78054d422333a1b5efe3c7ff8573774d5d7d76b`, which the Figma-alignment edit did not change because the callout view and its hosted test are untracked files). The final-candidate gates below were run by the physical-QA session after its last change; the acceptance closeout and documentation sync did not rerun them and changed no production or test code.

**Focused verification (rerun after a change in this area).**

```bash
npm run typecheck
npm test -- src/screenshotVenueClassifier.test.ts src/screenshotConformanceVectors.test.ts \
  src/screenshotEligibility.test.ts src/screenshotProposalValidation.test.ts \
  src/screenshotProposalRoute.test.ts src/createRequestRoute.test.ts
```

iOS classes added by R4.2: `ScreenshotVenueClassifierTests` (classifier and vector parity, near-miss matrix), `ScreenshotVenueRecoveryTests` (disposition by proposal shape and manual state, pre-transfer stop, recovery state machine, status truthfulness, fencing), `ScreenshotVenueAuthorityReconciliationTests` (catalog-recognition versus venue-evidence authority through the production `analyzeScreenshot` → `apply` path), and `RequesterVenueRecoveryCalloutLayoutHostedTests` (stacked full-width Figma layout, 46 pt single-line actions, complete wrapped labels and at least 44 pt targets at the largest accessibility sizes, disabled and activation behavior), with the test-support file `SwiftSourceFunctionSupport.swift`. Modified neighbors: `ScreenshotProposalStoreTests`, `ScreenshotMenuPathApplicationTests`, `ScreenshotMealSwipeMismatchTests`, `ScreenshotAssistanceDisclosurePresentationTests`, `RequestCreationViewTests`, and `RequestFoodMenuPathHostedTests`. Run them with the section 9 command and one `-only-testing:CommonPlateiosTests/<Class>` filter per class, plus the `RequesterCore`, `HostedRequesterUI`, and `AccessibilitySensitive` groups and these affected neighbors: `ScreenshotLocalFirstRoutingTests`, `ScreenshotExternalRequestSeamTests`, `ScreenshotExternalPermissionBindingTests`, `ScreenshotPreservedEntryFeedbackLifecycleTests`, `ScreenshotSharedRuntimeConformanceTests`, `ScreenshotConformanceVectorTests`, `ScreenshotQualificationFingerprintTests`, `ScreenshotFingerprintBuildScriptTests`, and `RequestFoodDraftSessionTests`.

**Automated evidence (as run on the final candidate).** `npm run typecheck` passed. `npm test`: **2,979 passed, 519 skipped by Mongo configuration, 0 failed**. Complete `CommonPlateiosTests`: **2,293 executed, 0 failed, 0 skipped**, TEST SUCCEEDED, on an iPhone 17 simulator (iOS 26.5). The focused callout-layout and disclosure-presentation run measured 27 tests, 0 failures after the final Figma-alignment edit. Debug simulator, Release generic simulator, Release unsigned generic device (`CODE_SIGNING_ALLOWED=NO`), and signed Debug device builds all succeeded. The derived qualification fingerprint was `3e8e351fb2fbee625a67bed9864030e34c15f004d5076c8d803b0137ca4fcb4e` in all five derived-data trees (the four builds and the test build), unchanged by the Figma-alignment edit because the callout view is outside the hashed inputs. `git diff --check` was clean. The new test file for the shared vectors, `src/screenshotVenueClassifier.test.ts`, and the unmodified `src/screenshotConformanceVectors.test.ts` both pass, which is the proof that validator output and the existing vectors are unchanged.

**What the automation establishes.** The disposition matrix (E, D, A, B, C, no-useful, ineligible) by proposal shape and manual state; that the draft is byte-unchanged until an explicit confirmation and that `apply` is reachable only through E, an explicit `Use … & autofill`, or an explicit `Autofill order details`; the near-miss downgrade (a near-miss supported venue is A, never B, never E); that non-Meal-Exchange venue lines (including cart-shaped lines) classify A; the pre-transfer stop (for B/C no permission is minted, participant authority is not read, and no external provider is invoked, while A/D/E transfer exactly as before and the local attempt is unchanged); the recovery state machine (confirm, dismiss, retry, picker cancel, new selection, disappearance, Off, terminal reset, stale token); status truthfulness; the recovery-before-path-conflict-and-mismatch precedence; and the callout geometry, labels, and targets. It does not establish OCR or Vision behavior on real captures, real unsupported-venue accuracy, or provider quality.

**Independent review.** A fresh HIGH-risk independent review of the R4.2 candidate was closed before physical QA (reported by the implementation session). The Figma-alignment restyle of the A–D callout view and its hosted layout test were made after that review; they are presentation-only and were not independently re-reviewed.

**Simulator evidence (staged, as reported before physical QA).** A–E, the no-V1 Dining Dollars E case, the empty/path-only A result, B/C with zero external screenshot-proposal requests and E as the positive control, D `Use`/`Keep`, retry, picker cancel, replacement, genuine-rerun feedback (and its negative cases), the menu-path conflict after a confirmed recovery, stale-after-leave, and Off-mid-analysis behavior were exercised on a simulator against a controlled stack. The largest-Dynamic-Type callout defect found there was fixed with hosted red/green verification; the layout was later superseded by the Figma-aligned styling above, and the layout was re-proved only by the hosted tests and the physical rows below, not by a new Simulator pass.

**Physical-device evidence (the project owner-observed on a physical iPhone, 2026-10-18).** An iPhone 16 Pro (iOS 26.3.1, Developer Mode on), a signed automatic-signing Debug build, a throwaway local replica-set backend reached through the Debug base-URL override over the LAN, and a synthetic provider; manual/environmental verification, not part of any suite. The project owner reported PASS for: the consent disclosure and State E (one provider request, checked row, `Suggested` location and meal); B (zero screenshot-proposal requests and zero provider calls, callout copy and actions, no checked row, fields untouched, `Choose Grubhub screenshot` entry row retained); `Try other screenshots` opening the picker directly, picker Cancel leaving the callout, and `Continue manually`; C with two screenshots (zero requests); D with a hand-selected `Crave NYU` (one request each for `Keep` and `Use`, nothing applied until the choice, `Manually selected`, `Use` replacing the location with a `Suggested` venue and filling the meal and path); A confirm with a picker-selected location (one request, `Autofill` disabled until a selection, selection alone applying nothing); the empty A result (checked row, no callout, no notice, one request); no-header Dining Dollars E (one request); replacing a pending B callout with a new selection (one request, E applied, B retired); a genuine rerun via `Change` preserving requester-owned entries and showing `Screenshot checked. Your existing entries were kept.`; the final Figma-aligned A–D callout styling on the final build (B and D checked visually against Figma `1087:7217`/`1087:7357`); the largest accessibility Dynamic Type size with the longest venue names (D, one request); and VoiceOver on the B callout through Try other screenshots and Continue manually. Server-side request counts came from a request log kept by an out-of-repo Node preload that records every inbound request and intercepts only `fetch("https://api.openai.com/…")`, answering from a synthetic file; the provider key was a fake and nothing reached a real provider.

**QA method and reproduction guidance.** Out-of-repo and not shipped: (1) `mongod --replSet <rs> --port <p> --bind_ip 127.0.0.1` with `rs.initiate`, and `ALLOW_LOCAL_SEED=true QA_ENV_FILE=<json> npm run qa:env -- init` for a named `commonplate_qa_<slug>` database (section 5); (2) `QA_MAIL_SINK_PORT=<p> npm run qa:mail-sink`, with the verification code read from `GET /latest-code?to=<address>` on the sink; verification requires an `@nyu.edu` address; (3) `tsx app.ts` with a loopback `MONGO_URI`, `RESEND_BASE_URL` at the sink, a fake `OPENAI_API_KEY`, and `NODE_OPTIONS="--require <preload>"` for the request log and provider shim (the provider URL is hard-coded in `src/screenshotProposalProvider.ts`, so there is no repository-side mock); (4) a signed Debug build installed with `devicectl device install app`, launched with `devicectl device process launch --terminate-existing --environment-variables '{"COMMONPLATE_DEBUG_API_BASE_URL":"http://<mac-lan-ip>:<port>"}'` (the override is lost if the app is force-quit or opened from the Home screen, which shows an unavailable state; the phone must be unlocked to launch); (5) synthetic order screenshots delivered to Photos by AirDrop and chosen through the real `PhotosPicker`. B/C zero-transfer is observed as zero `POST /api/request/screenshot-proposal` and zero provider intercepts in the request log across the run; the E positive control is exactly one of each.

**Accepted verification limitations (the project owner, 2026-10-18). These are not passes.**

- *State A's final post-Figma visual was not separately confirmed on the physical phone.* The A callout's Figma-aligned styling rests on the shared view's hosted layout tests and the B and D physical checks of the same component.
- *Physical VoiceOver coverage was partial.* The B callout passed; A (the picker and the dimmed `Autofill order details`), D, and the full callout wording were not captured on a device, and the exact wording read for B was reported as a pass without a transcript. Broader VoiceOver and focus acceptance remains W4-A1's where applicable.
- *The physical menu-path-conflict-after-venue-recovery interaction and the physical Off-while-pending and stale-result retirement checks were skipped.* They rest on automated tests and the earlier Simulator evidence.
- *B/C zero-transfer was observed against the controlled QA stack with synthetic evidence,* not an unrestricted production-provider test.
- *No real unsupported-venue accuracy evidence exists.* B/C proof is synthetic and recognition is Meal Exchange identity-line only.
- *No red run was recorded for the Figma-alignment layout tests;* the earlier layout defect's red/green evidence concerns the superseded side-by-side layout.
- The hidden empty/path-only notice (existing `Screenshot checked` / `Change` row with no additional visible notice) is accepted existing behavior.

**Not established, and routed elsewhere.** The post-R4.2 versioned selection-level evaluation (a named S2.1 follow-on) is required before the Week 4 pilot release gate while Screenshot Assistance is enabled; R4.2 acceptance does not satisfy it. Apple local-model qualification, provider and model quality, Release/Archive/TestFlight signing or endpoint behavior, and the two hosted-layout tests that fail only in some simulator environments are unchanged and outside R4.2.

### GoodGrub Public Information Pages (W4-T1) acceptance

The two-page W4-T1 implementation (`GET /guidelines`, `GET /support`; `docs/system-contract.md` section 16) is accepted (the project owner, 2026-10-19), uncommitted at acceptance, based on `main` at `1e3a0dc`. Acceptance covers only those two pages. Registration in `app.ts` is a shared-boundary change, so `FullNonMongo` applied; no persistence, transaction, uniqueness, or index behavior changed, so `npm run test:mongo` was not run.

**Focused verification (rerun after a change in this area).**

```bash
npm run typecheck
npm test -- src/publicInfoPages.test.ts
npm test -- src/confirmSubscriptionRoute.test.ts src/unsubscribeRoute.test.ts src/startupValidation.test.ts
```

`src/publicInfoPages.test.ts` mounts the real `registerPublicInfoRoutes` on an Express app with `helmet()` and drives it over real HTTP. It checks status, content type, title, document structure, security headers, the `public, max-age=300` cache policy, no cookies, no script/form/external resource, the exact `mailto:` target, navigation, no response-time or enforcement promise, and `POST` returning 404. It also checks that the shared helper still sends `no-store` and that `app.ts` has one import and one call and no `/privacy` route. Its wording fixture duplicates the implementation copy, so it guards against drift only and is not independent proof of fidelity.

**Evidence recorded at acceptance.**

- Focused public-information tests: **19 passed**.
- Affected tests after the cache-policy correction: **136 passed**.
- Full backend suite, run **before** the cache-policy correction: **2,997 passed, 519 skipped by Mongo configuration**, 0 failed (based on `main` at `1e3a0dc`, so not additive to other baselines). It was not rerun after the correction, which changed only `src/publicInfoPages.ts` and its test.
- `npm run typecheck` and `git diff --check` passed.
- A fresh independent review found no confirmed defects.
- Independent rendered-content comparison of both pages against the the project owner-approved copy, outside the test fixture: **PASS** (Guidelines 16 blocks, Support 11 blocks, titles, heading order, and every mailto target exact).
- Real `app.ts` HTTP smoke after the correction, against a throwaway local replica set with `PUBLIC_ACTIONS_PAUSED=true`, cron disabled, and a dummy provider key: `/guidelines` and `/support` returned 200 with `Cache-Control: public, max-age=300`, the strict Content-Security-Policy with `script-src 'none'`, `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy: no-referrer`, and no cookie; `/` and `/health` returned 200; `/privacy` returned 404; `POST /guidelines` returned 404; and the confirmation and unsubscribe routes returned `Cache-Control: no-store` in their paused 503 responses.
- The project owner reported successful manual browser, keyboard, text-zoom, dark-mode, VoiceOver, and mailto checks. That is manual observation, not an automated result, and no transcript is recorded.

**Limitations.** The emailed-link `no-store` check in the live smoke covered paused 503 responses only; normal 200 and invalid-link responses were not exercised there, and the shared-helper `no-store` unit test is the remaining proof. Hosted, proxy, and CDN cache behavior is unverified. Acceptance does not establish publication readiness: the Privacy Policy does not exist, the statements about withdrawal and stop-helping controls, account deletion help, and access restriction are unverified against final R5/U1.2/P2 behavior, and the hostname is undecided.

### Requester Request Management (W4-R5) acceptance

W4-R5 is accepted (the project owner, 2026-10-19), with the verification limitations recorded below. It is a cross-stack change (owner reads, Edit, Withdraw, verified-only ordinary reads, the dispatcher notification-generation fence, and the retirement of Active Requests), so it is a full-regression change under the verification-tier policy. Its contract is `docs/system-contract.md` section 16.

**Focused backend verification (rerun after a change in this area).**

```bash
npm run typecheck
npx vitest run src/requestReadGate.test.ts src/requestDetailRoute.test.ts src/requestDetailOwnership.test.ts src/helperNewRequestPush.test.ts src/notifySubscribers.test.ts src/eligibilityNotificationSweep.test.ts src/createRequestRoute.test.ts models/db.test.ts
npm run test:mongo
```

The Mongo suites cannot be run per file: `npm run test:mongo` runs every `.mongo.test.ts` file against a temporary replica set (section 5). Complete `npm test` and `npm run test:mongo` are required by the slice for acceptance; no new pass count is recorded here (section 13).

**Backend evidence.**
- `src/requestUpdateRoute.mongo.test.ts` (real Mongo): owner reads (authorization, privacy by omission, indistinguishable `404`, ordering, bound, phases, `canEdit`/`canWithdraw`); Withdraw and Edit atomicity and ledger behavior (exact replay, `OPERATION_CONFLICT`, `OPERATION_UNAUTHORIZED`, `OPERATION_EXPIRED`, concurrent duplicates); races (concurrent edits, concurrent withdraws, Edit vs Withdraw, claim vs Withdraw, claim vs Edit); the 11:30 PM America/New_York original-creation-day horizon (exact instant, DST days, ASAP refused after the creation day, unchanged timing exempt); U1.1 text and vendor parity; literal storage of `$`-leading text; legacy rows with no revision; no touch of the daily quota or D2's `RequestOperation` ledger; and the dispatcher notification-generation fence on the shared read-only guard.
- `src/requestReadGate.test.ts` and `src/requestReadGate.mongo.test.ts`: the verified-only ordinary reads refuse before any lookup, are identical for existing, fenced, and not-yet-visible ids, set no cache, leak no content or secrets, serve a verified caller through the pair fence, and handle revoked, deleted, ineligible, and Change-Email-replaced authority (`R5-IR-2`); source-wiring assertions cover the registration.
- Changed neighbors: the public detail and claim `410 REQUEST_WITHDRAWN` / `REQUEST_EXPIRED` behavior (`requestDetailRoute*.test.ts`, claim route tests), creation writing revision and generation 1 (`createRequestRoute.test.ts`), the model fields (`models/db.test.ts`), and the push, email, and sweep dispatchers (`helperNewRequestPush*.test.ts`, `notifySubscribers.test.ts`, `eligibilityNotificationSweep*.test.ts`, `helperPushPayload.test.ts`), including real-Mongo cases that skip a withdrawn or earlier-generation request and stop a fan-out when the request is withdrawn mid-dispatch. The three-point ordering inside a dispatcher (before claim, after claim, before provider handoff) is proven with mocks in the unit tests; real Mongo proves the guard and the cases above, not that ordering.

**iOS evidence.** New focused classes under `ios/CommonPlateios/CommonPlateiosTests`: `RequestManagementServiceTests` (what is sent and decoded; which failures are definitive and which leave the outcome unknown), `RequestManagementStoreTests` (owner collection bound to authority, durable-before-send, no automatic retry, user-initiated same-operation replay, participant-bound records), `RequestIdentityReplacementTests` (`R5-IR-1`/`R5-IR-2` and D-R5-2 retirement leaving durable records untouched), `RequestReadAuthorityTests` (nothing sent without authority; typed read classification), `RequestManagementHomeAndNoticeTests` (Home owner sourcing, banners vs alerts, notification-tap reconciliation), `EditRequestPresentationTests` (draft seeding, horizon rules, exact approved copy, `canonicalSpot`), `EditRequestScreenshotAssistanceTests` (D-R5-4 seeding and non-persistence), `OwnerRequestHostedTests` (real `OwnerRequestDetailView`, `EditRequestView`, and `HomeNoticeBanner` in a hosted window at light, dark, and the largest accessibility size), and `RequestCardMealSwipeVisibilityTests` (carried forward from the deleted `ActiveRequestsMealSwipeVisibilityTests`). Caller migration is covered by changes to the existing claim, helper-navigation, notification-routing, reservation-warning, Home-board, and ownership classes. `ActiveRequestsView` and `AppRoute.activeRequests` are deleted; a source search of the app target for them returns nothing.

```bash
xcodebuild test -project ios/CommonPlateios/CommonPlateios.xcodeproj -scheme CommonPlateios \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -only-testing:CommonPlateiosTests/RequestManagementServiceTests \
  -only-testing:CommonPlateiosTests/RequestManagementStoreTests \
  -only-testing:CommonPlateiosTests/RequestIdentityReplacementTests \
  -only-testing:CommonPlateiosTests/RequestReadAuthorityTests \
  -only-testing:CommonPlateiosTests/RequestManagementHomeAndNoticeTests \
  -only-testing:CommonPlateiosTests/EditRequestPresentationTests \
  -only-testing:CommonPlateiosTests/EditRequestScreenshotAssistanceTests \
  -only-testing:CommonPlateiosTests/OwnerRequestHostedTests \
  -only-testing:CommonPlateiosTests/RequestCardMealSwipeVisibilityTests
```

Use the project path, scheme, and destination from sections 7–9. The complete `CommonPlateiosTests` target is the full-regression proof.

**Physical-device evidence (the project owner, physical iPhone).** The walkthrough passed Pass 0, Pass 1, Pass 2 (steps 1–4, 6, and 8; step 7 by waiver), Pass 3 step 1 (step 2 by waiver), and the large-text Home card header after its fix. Pass 2 step 5, Pass 3 step 3 onward (which needs a second participant), the expired, placed, and reserved outcomes on a device, VoiceOver, and the preserved-message accessibility check were NOT RUN or waived. Automated tests cover the unrun scenarios.

**Known limitations.**
- *Two unresolved failures in `RequesterFormHostedFidelityTests`,* assigned outside R5 and not caused by it: `testExtraExtraLargeTextKeepsPostRequestReachableAndTheInfoTargetFull` and `testFilledMealSummaryDetailsGrowsByTheSamePerLineHeightAsMealItemSoTheyShareTheSameTextSize`. A complete-target run is therefore not fully green until they are resolved or re-baselined.
- *Network transfer of Edit screenshots to OpenAI is NOT VERIFIED.*
- *The hourly digest is not generation-fenced* (a recorded deferral), and the dispatcher ordering is mock-proven as above.
- *Recorded evidence of the independent HIGH-risk review, a Release build, and the final complete-backend/Mongo and complete-iOS runs after the last Edit-parity change is not in this document;* treat them as not yet recorded here.

### Dormant messaging foundation (W4-MSG1 CP1) acceptance

The project owner accepted CP1 on 2026-10-19 as a dormant backend foundation. This
candidate-specific record does not replace other accepted baselines or
change verification requirements. The five source/test paths are
`models/messaging.ts`, `src/messaging.ts`, `src/messagingRoutes.ts`,
`src/messaging.test.ts` and `src/messaging.mongo.test.ts`, in that fingerprint
order. SHA-256 of their `shasum -a 256` output is
`3406606fc4365b39a594b7db94271c7dda3b5f5f07aa5ab72d5e92d4e00566ae`;
branch `w4-msg1-cp1-foundation`, base HEAD
`1b31f185714370105217af1c6545f0f591c0f3a0`, uncommitted at closeout.

**Commands and final executed evidence (2026-10-19).**

```bash
npm run typecheck
npx vitest run src/messaging.test.ts
npm run test:mongo
npm test
```

Typecheck passed. The final focused run executed **9 unit and 50 Mongo
tests, all passed**, using an auxiliary disposable local single-member
replica-set runner; it is supplementary evidence, not a replacement for
`npm run test:mongo`. The documented complete Mongo command passed **632
tests across 34 files, 0 failed, 0 skipped**, including all 50 messaging
cases. Complete `npm test` passed **3,081 tests across 76 files**, with
**632 Mongo-gated tests in 34 files skipped by configuration**, not exercised
by that command. Whitespace and source-wiring dormancy checks passed.
Documentation-only closeout retains these results; it does not claim a new
execution of the suites.

**Scope and test isolation.** Mongo proof uses its own
`commonplate_msg1_cp1` database on the disposable replica set (section 5);
`mongod` and `mongosh` must be available. It covers participant/credential
authority, replacement isolation, release/passive lapse/placed compatibility,
12 concurrent ordered sends, six concurrent identical retries, exact identity
and global counts, digest conflicts, cursor/reconciliation, real Block and
lifecycle races, cleanup bounds/retry/TTL lag and no orphan resurrection.
Pickup/moderation/deletion facts are synthetic policy adapters, not proof of
the eventual authoritative integrations. Unit tests cover validation,
projection/identity retention, fail-closed policy and unmounted registration.

All asynchronous test bodies and service/HTTP/cleanup operations have owning
registries. Teardown releases controlled barriers, settles outstanding work
including work started during draining, and refuses fixture reuse while
settlement is incomplete. Rejections remain recorded after pending removal;
only successfully asserted operation failures or bodies returned directly to
the test runner are accounted for intentionally. Unexpected detached
rejections fail after settlement. Timeout is not cancellation.

Opt-in `MSG1_ISOLATION_PROBE=detached|mixed|failure|timeout` subprocess modes
are negative demonstrations, not normal-suite cases or skips. Each final
isolated invocation intentionally exited **1**, with **one failed and one
passing next-fixture test**: detached rejection after a successful body,
rejection with pending read/send, explicit body failure and actual 500 ms
timeout respectively. The next fixture checked settlement, mock restoration,
empty message/receipt collections and sequence restart. The ordinary
explicitly asserted-rejection regression passed. An extracted-class check
demonstrated that the prior registry swallowed a detached rejection and the
repaired registry reported it; mismatched assertions did not consume failures.

**Review and historical qualifications.** The project owner's closeout decision records
independent HIGH-risk review **PASS WITH DEFERRALS**, with no confirmed
production implementation defects, and final narrow independent
test-isolation/rejection review **PASS**, with no remaining findings.
Earlier independent Mongo verification exposed ordering/identical-retry
test-harness failures. After concurrent-batch settlement correction, two
bounded test-only repairs completed universal draining/fixture isolation and
detached-rejection accounting. Production code did not change in those repairs.
An earlier full Mongo attempt hit setup timeouts under host load average
88.49; diagnosis and a later lower-load complete run passed. An earlier
simultaneous workload also failed the unchanged filter's 2-second timing
assertion at 5,071 ms; its separate complete non-Mongo run passed. No
assertions or contention limits were weakened.

Verification used a local `node_modules` symlink to main's existing
dependencies after `npm ci` failed on the pre-existing inconsistent lockfile;
no dependency files changed. A clean-lockfile installation is unproven.
Permanently unsettled driver work can prevent teardown completion; safe
fixture reuse is refused, not forced by a timeout. Unregistered arbitrary
timers/driver cancellation are not universally proven safe.

Success establishes neither integration/deployment nor device/provider
behavior. No production messaging endpoint, iOS chat, real pickup/moderation/
P2 handoff, report-evidence integration, N1 recipient linkage, operational
24-hour cleanup capacity or production configuration is qualified here.
See system-contract section 18 for the dormant boundary and activation owners.

### Dormant WebSocket foundation (W4-MSG1 CP2) acceptance

The project owner accepted CP2 on 2026-10-20 following independent HIGH-risk review
**PASS WITH DEFERRALS**. Branch `w4-msg1-cp2-realtime-902e41a8` remains
uncommitted, based directly on CP1 commit
`43c3ce6c002a892b2d25a721a73744674ba9e154`. This candidate-specific evidence
does not replace historical baselines or reduce verification requirements.

The eight-file SHA-256 fingerprint is
`9cfcbaac44fc65e0473f7678ceab1459559e4544461c836fac694e95e88ba7d1`.
Reproduce by hashing the exact relative-path `shasum` output, including its
two-space separators and LF line endings:

```bash
shasum -a 256 package.json package-lock.json \
  src/messaging.ts src/messagingRoutes.ts src/participantAuthorityGate.ts \
  src/messagingSocket.ts src/messagingSocket.test.ts \
  src/messagingSocket.mongo.test.ts | shasum -a 256
```

**Final executed evidence (2026-10-20).**

| Command | Result |
| --- | --- |
| `npm ci --no-audit --no-fund` | Passed; 402 packages installed into a real directory, not a dependency symlink. |
| `npm run typecheck` | Passed. |
| `npx vitest run src/messagingSocket.test.ts src/messaging.test.ts` | 56 passed: 47 socket/protocol and 9 CP1 unit cases. |
| `VITEST_MAX_WORKERS=1 npm run test:mongo` | 647 passed, zero failed/skipped across 35 files; includes 15 CP2 socket and 50 CP1 Mongo cases. |
| `VITEST_MAX_WORKERS=1 npm test` | Exit 0; 3,128 passed, zero failed; 647 Mongo-gated skips across 35 files, 77 files passed. |
| Tracked, staged and new-file whitespace checks | Passed. |

Clean installation used Node 24.13.0/npm 11.6.2 and the independently generated
CP2 lockfile; this closes CP1's candidate-specific clean-install limitation
for CP2, not retroactively for CP1. Dependency reconciliation with INF1 and
clean-install proof on the eventual integrated tree remain necessary.
No runtime-version pin or new verification command was introduced.

Mongo prerequisites remain `mongod`/`mongosh` and the disposable local
single-member replica-set runner in section 5. CP2 uses its isolated
`commonplate_msg1_cp2_socket` database. Coverage includes real CP1 authority,
Block/closure/credential races, sixteen-socket fanout through two serialized
credential checks, overload isolation and revocation, transaction abort/retry
and publisher failure, HTTP pagination/catch-up races, lost hints, reconnect,
server-composition restart and manual Retry identity. Owner pickup/moderation
facts remain explicitly synthetic. Fixture-owned asynchronous work, including
late barriers, drains before reuse; unexpected detached rejections fail tests.
Timeout is not cancellation.

**History and limitations.** Review corrections added bounded admission and
authorization scheduling, predictable refusal flush/fallback, and accurate
slow-consumer proof wording; CP1 protected-operation semantics were preserved.
Earlier development runs exposed fixture/type/test-placement errors, corrected
before final proof. A first complete Mongo repair run passed 646/647; the new
fence-count test needed an explicit projection of the privacy-hidden field.
Two complete non-Mongo repair runs each passed 3,125 tests but timed out three
unchanged source scans under shared-host/filesystem pressure. Bounded scans
took 5.2-8.0 seconds against their unchanged five-second deadlines. The final
complete run at 11:31-11:32 EDT passed all three scans (all 238 request-route
tests passed), taking 61.30 seconds. Load averages at launch were
3.37/9.31/24.02, versus earlier load above 50; filesystem latency remained
variable, so CPU load alone is not a proven cause or stability guarantee.
No assertion, deadline, worker setting or required gate was weakened.

Local WebSocket/replica-set proof is not deployed Linux/proxy, provider,
simulator or device evidence. Slow-consumer buffering is deterministically
simulated after authorization and before output; it proves neither kernel
saturation, production memory capacity nor Lightsail/Nginx buffering.
Restart proof recreates local HTTP/socket composition, not an OS-process crash.
Tests configure 16 KiB/five-second pre-upgrade HTTP header limits; production
parser/proxy enforcement, single-process topology, capacity and shutdown are
INF1/RC1 qualifications. Multi-process propagation is needed only if that
topology is adopted. Dormancy is verified by source wiring, not a deployed
endpoint probe. Activation owners remain in system-contract sections 18-19.
Documentation-only acceptance synchronization retains these results; it does
not claim newly executed test suites or completed deferred integrations.

### Dormant iOS messaging foundation (W4-MSG1 CP3) acceptance

The project owner accepted CP3 on 2026-10-20 as a **dormant iOS foundation, with an explicit
complete-suite qualification below** (it is not a PASS of the complete target).
Branch `w4-msg1-cp3-ios`, base `e826ea6`; 18 untracked, unstaged files (eight
under `ios/CommonPlateios/CommonPlateios/Messaging/`, ten
`Messaging*Tests.swift` support/test files under
`ios/CommonPlateios/CommonPlateiosTests/`). No tracked source, project file,
scheme or Info.plist changed. This candidate-specific evidence does not replace
historical baselines.

Fingerprint `923e38c1b5289e557860cb28fdd6484815458915eb2117e9f5bde3744f3e283c`;
reproduce from the worktree root before the files are committed:

```bash
git ls-files -o --exclude-standard | sort | xargs shasum -a 256 | shasum -a 256
```

**Executed evidence.**

| Command / run | Result |
| --- | --- |
| Nine focused classes (`MessagingAccessibilityHostedTests`, `MessagingCoordinatorIdentityTests`, `…LifetimeTests`, `…ReconciliationTests`, `…SendTests`, `MessagingHTTPClientTests`, `MessagingPresentationTests`, `MessagingTranscriptTests`, `MessagingWireTests`) via section 9's command with these `-only-testing` selectors; run independently by the rereviewer | **108 executed, 0 failed, 0 skipped, TEST SUCCEEDED** (9/13/6/21/23/10/7/7/12 per class in the order printed). The implementer reported the same 108. |
| Complete `CommonPlateiosTests` target (section 9 command), run independently by the rereviewer on the unchanged candidate | **TEST FAILED** (exit 65): 2,571 executed, 2 skipped, 4 failures (0 unexpected), i.e. 2,566 passed, 3 failed cases. The 2 skips are `OwnerRequestHostedTests` snapshot writers skipped by configuration (`R5_SNAPSHOT_DIR` not set). |
| `git diff --check` | Run at documentation synchronization; see the acceptance report. |

The implementer's earlier report of 2,598 passed / 3 failed / 2 skipped does
not reconcile with the preserved rereview log (2,571 executed); the log's
figures are the recorded ones and the implementer's total is not independently
reproduced. No backend/Mongo suite was required or run (no TypeScript changed).

**Complete-suite failures (not CP3 behavior).** All four assertions are in
Requester hosted-layout classes outside Messaging:
1. `RequesterFormHostedFidelityTests.testPostRequestTransitionsBetweenBottomAnchorAndScrollFollowingAsTheFormGrowsAndShrinks`, line 416.
2. `RequesterMealPresentationHostedTests.testShortCollapsedFormStaysAnchoredAndTallFormStaysFlowing`, lines 278 and 279.
3. `RequesterMealPresentationHostedTests.testLongCollapsedDetailsWrapsFullyAndGrowsCardHeightNaturally`, line 447.

They were reproduced on clean `e826ea6` (implementer and an earlier independent
reproduction; the rereviewer did not re-run clean main). **Baseline
discrepancy:** the accepted entry above in this file (W4-R5, "Known
limitations") names two different `RequesterFormHostedFidelityTests` failures
(`testExtraExtraLargeTextKeepsPostRequestReachableAndTheInfoTargetFull`,
`testFilledMealSummaryDetailsGrowsByTheSamePerLineHeightAsMealItemSoTheyShareTheSameTextSize`);
those did not fail in this run and the three above are not recorded there.
That entry is preserved unchanged. The project owner accepts CP3 with this qualification
and does **not** accept these failures as a new general-purpose baseline. No
assertion was weakened and no Requester layout was repaired under CP3.
Reconciliation (environment/Xcode/simulator dependence, ownership, re-baseline
or fix) is routed to the designated testing/planning owner; no owner is named
here. The complete target must not be reported as PASS until it is resolved.

**Coverage and independent review.** The targeted HIGH-risk rereview confirmed
F1-F4: ten-message outstanding capacity with drafts and ambiguous sends
preserved; UTF-16 text validation matching CP1; coordinator deallocation
cancelling owned tasks and the socket with weak-self catch-up and no resend of
in-flight sends; and hosted accessibility frames, activation, Dynamic Type and
medium/large sheet reachability. Previously covered: frame decoding, transport
configuration, subscribe/catch-up ordering, paging and dedupe, backoff,
send ambiguity/manual Retry, isolation and closure, error classification,
lifecycle and presentation. A reviewer nit (client vs server whitespace
trimming edge scalars) is a recorded deferral.

**Limitations.** Hosted accessibility proof is simulator `accessibilityActivate()`
and real accessibility-frame inspection, not VoiceOver on a physical device.
Not verified: physical device, APNs, deployed HTTPS/WSS, Lightsail/Nginx, real
R3/U1.2/U1.3/P2 integration, production-server behavior, and any claim that a
Figma proposal is approved runtime. Dormancy is verified by source inspection
(no reference from existing app files). CP3 holds the full authorized
transcript in memory; bounded-memory behavior is not tested or claimed and
awaits later iOS consumption of the separately accepted CP4 backend backward
pagination in that CP3 baseline. CP5's accepted consumption and continued
O(loaded history) limitation are recorded below and in system-contract
section 23; this does not alter CP3's historical evidence.

### Dormant backend history pagination (W4-MSG1 CP4) acceptance

The project owner accepted CP4 on 2026-10-21 as a **dormant backend checkpoint**. Independent
HIGH-risk review returned **PASS WITH DEFERRALS**, with no confirmed production
correctness or participant-authorization defect. F1's complete-Mongo-gate gap
was closed before acceptance; the production implementation did not change
after independent review. This evidence applies to the five implementation/
test paths below on branch `w4-msg1-cp4-history-pagination`, based on
`3b68a7166e4b1f0bc5a53f613badff2cca10ea4f`, plus documentation-only closeout:

`src/messaging.ts`, `src/messagingRoutes.ts`,
`src/messagingHistory.test.ts`, `src/messagingHistory.mongo.test.ts`, and
`src/messagingSocket.mongo.test.ts`. The socket file was accepted under CP2;
The project owner's bounded F1 test-hardening authorization retains its test-only polling
budget change from one to five seconds. The original completion predicate and
failure assertion remain; no production WebSocket behavior changed.

**Executed final-candidate evidence (2026-10-20; accepted 2026-10-21).**

| Command / coverage | Result |
| --- | --- |
| `npm run typecheck` | PASS. |
| `npm test` | 3,164 passed, 0 failed; 702 Mongo-gated skips; 78 files passed, 36 skipped by configuration. |
| Unit files within that complete run | `src/messagingHistory.test.ts`: 36; `src/messaging.test.ts`: 9; `src/messagingSocket.test.ts`: 47; all passed. |
| `npm run test:mongo`, two sequential complete runs | Each: 702 passed, 0 failed/skipped across 36/36 files; 43.62s and 41.58s. |
| Messaging Mongo files within each complete run | `src/messagingHistory.mongo.test.ts`: 55; `src/messaging.mongo.test.ts`: 50; `src/messagingSocket.mongo.test.ts`: 15; all passed (120 total). |
| `git diff --check` and new-file whitespace checks | Passed at candidate verification; documentation closeout checks separately inspect the final diff. |

The documented section 5 runner starts a disposable local single-member
replica set on a free loopback port. Final runs used macOS, Node 24.13.0,
npm 11.6.2, Vitest 4.1.10 (default fork pool/file parallelism, no worker
override), `mongod` 8.2.1 and `mongosh` 2.8.2 on a 10-CPU/16-GiB shared host.
The history suite initializes indexes and uses its own
`commonplate_msg1_cp4_history` database, separate from CP1/CP2 fixtures.
No new verification command, production configuration or dependency changed.

**F1 and meaningful concurrency proof.** The independent reviewer initially
obtained 700/701 in each of three complete runs: two hit the socket helper's
one-second poll budget, and one hit the history stress test's five-second
default. Focused messaging Mongo runs passed 119/119 twice before the new
regression. During the bounded follow-up, another full Mongo/Vitest runner
was observed active in a separate worktree under host load/memory pressure;
that attempt failed broadly (9 failed, 144 passed, 549 skipped; 27 failed/
9 passed files), including setup hooks outside messaging. Two later complete
runs with no competing full Mongo runner passed all 702 tests. This is local
test/host-contention evidence, not production capacity qualification.

The original 48-operation history/send/forward stress case and all assertions
remain; only that test's deadline became an explicit 15 seconds (measured
1.145s and 7.827s in the successful full runs). A new barrier-controlled
real-Mongo test pauses history after its snapshot/authorization read, commits
a send, resumes history, verifies more than one authorization attempt and the
updated history head, then proves forward catch-up from the opening page's
boundary recovers the send exactly once. It adds a test rather than reducing
stress operations, weakening authorization, skipping proof or changing
production retries.

**Coverage and limits.** Real-Mongo tests cover latest/older ordering,
exclusive bounds, equal/reversed timestamps, complete 5,000-message traversal,
cross-conversation isolation, current authority on later pages, revocation/
closure races, cleanup/non-resurrection, synthetic policy boundaries,
same-email recreation, forward DTO/behavior preservation and send identity.
Explain and the actual service-query profiler establish reverse
`message_sequence_unique` IXSCAN with no COLLSCAN/in-memory SORT and at most
`limit+1` message keys/documents (maximum 101), not bounded total transaction
cost. Unit/source-wiring proof covers validation, headers, error privacy,
forward response shape and non-mounting; it is not a deployed endpoint probe.
The optional reviewer refinement to explicitly count the revocation-race
retry remains nonblocking; the added deterministic test counts history/send
retry separately.

Not verified: real R3/U1.2/U1.3/P2 adapters, CP5 iOS history/windowing,
physical device/VoiceOver, APNs, deployed HTTPS/WSS, Lightsail/Nginx, production
latency/load/abuse limits or cleanup capacity. Those activation/integration
deferrals remain owner-assigned in system-contract sections 18-21. No iOS
test was run or required for this backend-only change; CP3's accepted
complete-iOS-suite qualification is unchanged. Documentation-only acceptance
synchronization preserves the executed evidence; it does not claim a new
full-suite run, deployment or public availability.

### Requester placed-order continuation (W4-R3) acceptance

The project owner accepted W4-R3 on 2026-10-21 after physical-iPhone and helper-Simulator
passes (helper Home; Waiting page and Contact; Block; Confirm pickup card size;
Maps chooser; pickup retiring both sides; page-by-page UI recheck). Contract:
`docs/system-contract.md` section 22. The accepted candidate is commit `279f67e`
on `w4-r3-current-main-integration` (parent `e826ea6`), integrated into `main` by
merge.

**Two proof gaps the project owner explicitly accepted as known limitations (2026-10-21):**
(1) `npm run test:mongo` was NOT rerun after the final helper-contact
visibility-window change (the 661/661 run predates it); (2) one of the four
remaining hosted-layout failures was NOT independently reproduced against clean
`HEAD`. Neither is a pass.

| Check | Result |
| --- | --- |
| Backend `npm test` | 3,193 passed, 661 skipped by Mongo configuration, 0 failed |
| `npm run typecheck`, `tsc` build | Passed |
| `npm run test:mongo` | 661/661 passed (temporary `mongod`). Run before the final helper contact-window bound; that route's tests are in the non-Mongo suite and passed |
| ESLint | 0 errors, 4 warnings, not classified as pre-existing |
| iOS complete `CommonPlateiosTests` | 2,520 tests; the stale `HelperHeldRequestNavigationTests` assertion was fixed and passes; 4 hosted-geometry failures remain in `RequesterFormHostedFidelityTests` / `RequesterMealPresentationHostedTests`, three reproduced on a clean `HEAD` snapshot and one not baselined |
| iOS Debug and Release builds | Succeeded |
| `git diff --check` | Passed |
| Narrow HIGH-risk rereview | One Medium finding (helper contact route used the 7-day retention); fixed with the ETA + 1 hour bound and a test, then PASS |

Accepted limitations: the four hosted-geometry failures above are not a clean
complete-suite gate; the helper Waiting layout is provisional (no Figma frame)
and the rose Confirm pickup tint is not in Figma; manual accessibility proof is
deferred; `shared/vendors.json` was not changed (street addresses live in
`R3MapsDestination`). The QA backend must be restarted to load the contact-window
fix. Deferred: B1 (Home `Continue helping`, `ASAP` / `Available until` wording,
helper post-pickup experience), N1 (helper notice on pickup), MSG1/v2 (messaging,
Contact on claim). Acceptance is not Release, signing or TestFlight proof.

### Dormant iOS history loading (W4-MSG1 CP5) acceptance

The project owner explicitly accepted CP5 on 2026-10-21, including the failed-suite
qualification and keyboard/device deferrals below. The accepted 18-Swift-file
candidate on `w4-msg1-cp5-ios-history`, base `37bba29`, has fingerprint
`c97e4afee9992bf9a5b696da9bef5047e17f6e8a9acdf199d528e5c8532ee87b`
(SHA-256 over sorted changed-file paths, NUL, file bytes, NUL). Documentation
synchronization does not change those Swift files or establish post-R3
integration evidence. The accepted runtime contract is system-contract
section 23. Messaging remains dormant.

**Executed candidate evidence.** Xcode 26.6 (17F113), iOS 26.5 (23F77),
iPhone 17 arm64 Simulator; section 9's complete-target command:

| Run / coverage | Result |
| --- | --- |
| Exact accepted candidate, complete `CommonPlateiosTests` | **TEST FAILED: 2,619 total, 2,616 passed, 1 failed, 2 configuration skips.** |
| Nine CP3 Messaging neighbor classes within that run | **108 passed**: AccessibilityHosted 9, CoordinatorIdentity 13, CoordinatorLifetime 6, CoordinatorReconciliation 21, CoordinatorSend 23, HTTPClient 10, Presentation 7, Transcript 7, Wire 12. |
| Seven new Messaging history classes within that run | **48 passed**: Coordinator 12, HTTPClient 4, Hosted 8, Identity 9, Memory 3, Transcript 7, Wire 5. All **156 Messaging tests passed**, preserving the earlier 155-test evidence before the added older-reader inset case. |
| Clean `37bba29` qualification comparison | 9 total, 8 passed, 1 failed, no skips: identical Requester failure; HomeRefreshSettleHostedMotionTests 8/8 passed. |
| Earlier six-case history-hosted repeated proof | 18/18 across three runs, then 6/6 with actual Simulator Reduce Motion enabled. |
| Separate standard-motion real Simulator drag run | 1/1: opening rows 102-151; exactly one older request at each bound 102/52/2; chronological traversal through row 1, `hasOlder=false` termination, concurrent append and closure/identity late-page fencing. |

**Exact failed-suite qualification, not a passing baseline.** The sole current
failure is
`RequesterMealPresentationHostedTests.testLongCollapsedDetailsWrapsFullyAndGrowsCardHeightNaturally`,
line 447: 0 versus 180 +/-4 for content displacement below the growing card.
It reproduced identically on clean `37bba29`. Configuration skips are
`OwnerRequestHostedTests.testWriteDarkReviewSnapshotsWhenRequested` and
`testWriteReviewSnapshotsWhenRequested` without `R5_SNAPSHOT_DIR`.

The earlier complete run failed
`HomeRefreshSettleHostedMotionTests.testTheHoldCarriesContentOnFromARealUIKitCollapseWithoutAJumpABounceOrAnOvershoot`
at lines 69/77/83 (96 versus 60 +/-1.5; 96 >61.5; step 36.6667 >=6.5).
It did not recur in the final candidate's complete run or the clean-base
8-case class. Cause remains unattributed; timing/order or cross-test effects
are not ruled out. If further attribution is required, compare matched
candidate/base original-order predecessor context, or matched complete targets
when that context cannot be recovered. The project owner accepted this candidate-specific
qualification, not a new general-purpose passing baseline. Testing/planning
owner designation and reconciliation remain pending; no owner sign-off,
Requester/Home repair, weakened assertion or skipped required case is claimed.

**Independent review.** The separate HIGH-risk review verdict remains
**BLOCKED on verification qualification, with no confirmed CP5 implementation
defect**. The project owner's acceptance does not relabel that verdict. Follow-up found a
probable bottom-pinned viewport-resize defect using an artificial 336-point
safe-area inset: bottom gap 0 to 633 points at standard text and 0 to 329 at
accessibility3. The older-reader inset case had zero drift; it does not
qualify the pinned case. Attempted fixes were reverted; the unresolved
artificial-inset concern is neither PASS nor real-keyboard proof.

**Hosted versus gesture proof.** Hosted geometry measures actual rendered
bubbles after observable layout/correction settlement, not just reducer state.
Partially visible tall bubbles, consecutive pages, concurrent append, pinned
append, Dynamic Type/accessibility sizes, and history Retry accessibility
lookup/activation are covered. Prepend/concurrent-append drift measured below
0.001 point against the unchanged <=2-point requirement. Separate real-drag
evidence uses external CGEvent touches through production pan/KVO; controlled
positioning while the HTTP response is gated establishes the partial anchor
before geometry measurement. The ordinary suite's optional interaction-host
case is smoke coverage, not an automated real gesture. The external driver
is not repository UI-test infrastructure. The project owner accepted the available
interaction evidence and stopped mouse automation; no completed the project owner
keyboard/send/failure-sheet walkthrough is inferred.

**Deferred and mandatory gates.** Real-system-keyboard show/hide and
bottom-pinned viewport qualification are unverified and deferred to integrated
MSG1 CP6 **before activation**, including standard/accessibility text, any
confirmed resize fix, focused rereview and required verification. No further
Simulator keyboard-configuration investigation is required for CP5 closeout.
Actual Reduce Motion drag, remaining hands-on keyboard/send/failure-sheet
coverage, physical-device VoiceOver, long-conversation resources, real
R3/U1.2/U1.3/P2 integration, APNs, deployed HTTPS/WSS and operational capacity
remain separate owner gates. Session retention is O(loaded history), not
bounded total memory. Simulator proof is not device, deployment or provider
proof. No backend/Mongo run is claimed for documentation-only closeout;
post-R3 integration must receive its own required regression evidence.

**Post-R3 isolated integration verification (2026-10-22).** Merged accepted
CP5 `304bf6e` into committed main `28af6a3` in an isolated worktree.
Only the two documentation files conflicted; R3 section 22, CP5 section 23,
both acceptance records and committed Atlas documentation were preserved.
The 18 Swift files retain the exact accepted c97 fingerprint above; no
runtime reconciliation change was made. Main's unrelated uncommitted
testing-document edit was not included.

On the same iPhone 17 arm64 / iOS 26.5 Simulator, the section 9 complete
`CommonPlateiosTests` command finished **TEST FAILED: 2,676 total, 2,673
passed, 1 failed, 2 configuration skips**. All **156 Messaging tests passed**;
the eight HomeRefreshSettleHostedMotion tests passed. The sole failure was
the same Requester long-collapsed-details test and 0 versus 180 +/-4
assertion documented above, already reproduced on clean `37bba29`.
The two skips were the same optional OwnerRequest snapshot cases without
`R5_SNAPSHOT_DIR`; no required test was disabled. This is fresh integrated
evidence, not a relabeling of CP5's historical target or independent review.

A separate focused run passed **307/307, no failures or skips**: all 16
Messaging classes plus RequestIdentityReplacement, HelperHeldRequestNavigation,
PlacedOrderContinuation, PlacedOrderPickupStoreRegression,
RequestOwnershipLifecycle, ParticipantBlockEntry, ParticipantBlockYesNavigation,
ParticipantBlockPostYesAutonomy and ParticipantBlockPostYesStopHome.
Staged whitespace and exact-path/fingerprint checks passed. Backend, Mongo
and browser checks were not rerun: the integration delta changes only the
accepted Messaging Swift files and documentation. No live routing/mounting,
real keyboard, physical-device, safety-adapter, deployment or activation
proof is added. Artificial-inset and other deferred gates above remain open.

## 5. Mongo integration tests

Run:

```bash
npm run test:mongo
```

A prior reference baseline was **172 passed across 13 files**. The complete Mongo-gated suite also passed in the accepted H1 closeout; section 13 deliberately records that pass without inventing an unrecorded new total. `mongod` and `mongosh` must both be on `PATH`. The script creates a temporary data directory, starts a temporary single-member replica set on a free local port, initializes it, injects an isolated `MONGO_INTEGRATION_URI`, runs `*.mongo.test.ts`, and removes the temporary database directory afterward.

A replica set is required because placement verification exercises MongoDB transactions; standalone MongoDB cannot provide that behavior. Mongo verification remains incomplete until this command passes. `npm test` reporting the Mongo suites as skipped does not replace this run.

**Runner concurrency.** `scripts/run-mongo-integration.mjs` runs the Mongo test files one at a time (`vitest run .mongo.test.ts --no-file-parallelism`) against its one throwaway single-member `mongod`. Vitest's default pool (about nine workers on a 10-core machine) made every file contend for that server, and setup hooks (10 s) and 5 s tests timed out: on pristine `071d8ac` the default runner failed 17 of 53 files at low load, while the same suite run serially passed every test. No assertion or timeout was changed. `MONGO_TEST_MAX_WORKERS=<n>` (positive integer) opts in to more parallelism for diagnosis only; `2`–`4` workers still produced timing failures on a shared machine, so it is not a gate configuration. A complete run now takes roughly 200–300 s. Qualification evidence on pristine `071d8ac` plus only this runner change (shared 10-core machine, other agents intermittently active, no overlapping Mongo runner in the measured window): four consecutive `npm run test:mongo` runs, three passing 1,041 tests with 11 skipped across 52 passed and 1 skipped file (53 files; 199–211 s), and one run with two wall-clock timeouts that coincided with a machine-wide load spike (a 5 s test taking 7 s and the CLI-interruption case taking 18 s, against 0.8 s and 1.2 s in passing runs). Diagnostic serial and fixed-worker runs with a private replica set: serial 1,041 passed; 2 workers one clean pass and one timing failure; 3 and 4 workers one timing failure each. Default-parallel control on the same commit: 17 files failed.

**Valid gate conditions.** The run is the gate only when no other `run-mongo-integration`/Mongo test process is executing on the machine; overlapping runners and machine-wide load spikes (for example other agents' builds) can still stall individual wall-clock-bounded tests (the `src/messaging.mongo.test.ts` discovery-batch test and the CLI-interruption case in `scripts/atlas-qualification-probe.mongo.test.ts` are the observed sensitive ones). A failure that is a timeout during a documented load spike may be rerun once on a quiet machine, but only a fully clean run (no failures, no unresolved timeouts) qualifies as PASS; a repeated or non-timeout failure is a real failure.

`MONGO_INTEGRATION_URI` is an integration-test environment input. Do not set it to a real shared or production URI.

The official runner executes Mongo test files serially by default; parallel execution (`MONGO_TEST_MAX_WORKERS`) is a diagnostic mode, not the qualification mode. Per-database isolation remains required for diagnostic parallel runs and as defense in depth: when files run concurrently against the one temporary replica set, suites that clear a whole collection between cases can delete another file's fixtures. Suites sharing a collection must not share a database. Six suites currently touch `Subscriber`, each in its own database:

| Suite | Database |
| --- | --- |
| `src/subscribeRoute.mongo.test.ts` (Day 2 signup) | The runner URI's default database |
| `src/confirmSubscription.mongo.test.ts` (Slice 3A) | `commonplate_confirmation_test` |
| `src/confirmSubscriptionRoute.mongo.test.ts` (Slice 3B) | `commonplate_confirmation_route_test` |
| `src/unsubscribeRoute.mongo.test.ts` (Slice 4B) | `commonplate_unsubscribe_test` |
| `src/subscriptionLifecycle.mongo.test.ts` (Slice 4C) | `commonplate_lifecycle_test` |
| `models/db.mongo.test.ts` (schema projection) | `commonplate_subscriber_schema_test` |

Each of these suites clears state with `Subscriber.deleteMany({})`. The distinct databases are what prevent one suite's cleanup from deleting a concurrently executing suite's fixtures. Apply the same isolation to any new suite that clears a shared collection.

`src/subscriptionLifecycle.mongo.test.ts` additionally clears `Request`, `SendLog`, and `System`, because it drives the real alert path. Those collections are also used by the claim, fulfillment, and availability suites in the runner URI's default database; its own database is what keeps the two apart.

`scripts/run-mongo-integration.mjs` runs all `.mongo.test.ts` files and does not currently support forwarding a single test-file argument. A requested focused Mongo verification therefore necessarily executes the complete Mongo-gated suite.

### Local QA harness and scenario reset (W4-QA1)

Dev/test-only tooling for isolated, repeatable requester/helper QA on a Mac. It adds no endpoint, bypass, credential injection, or quota change, and it does not alter how participants verify. It is **Simulator/local evidence only**: it does not prove real email delivery, APNs delivery, physical-device behavior, signed Release/Archive/TestFlight behavior, or production endpoint selection.

**Prerequisites and safety rules**

- A dedicated, disposable, local MongoDB **replica set** (transactions are required). Never point it at a shared, staging, tunneled, or production database.
- Each environment is one explicit JSON file named by `QA_ENV_FILE`: `{ slug, database, mongoUri, backendPort, mailSinkPort }`. Keep it outside the repository. The tool reads nothing else: no `.env`, no `MONGO_URI`, no default database. Run the tool from a worktree without a `.env`.
- Gates enforced before any connection: `database` is exactly `commonplate_qa_<slug>` (slug is 1-4 lowercase words joined by underscores; production-like names are refused); `mongoUri` is a plain `mongodb://` loopback URI naming that same database; the two ports are explicit and different; `ALLOW_LOCAL_SEED=true` and `NODE_ENV` other than `production` are required for every mutating command. After connecting, the connected database name must match, and a marker document stored in the database (written by `init`) must name the same environment. A database with no marker, or another environment's marker, is refused.
- **Loopback host validation does not establish that the database is physically local.** A tunnel or proxy bound to `127.0.0.1` passes every check. Before the first `init`, confirm that `db.hello().hosts` and `me` list only the member(s) you started and that `lsof -nP -iTCP:<port> -sTCP:LISTEN` shows your own `mongod`, not `ssh`, `socat`, `kubectl`, or another forwarder. The tool does not perform this check.
- Use isolated ports and one Simulator pair per environment. A participant credential belongs to the backend that issued it; nothing here copies or injects credentials.
- Since W4-P2, the backend also needs the P2 identity keyrings and deletion signing secret. The CP2 environment also ran `npm run register:p2-identity-versions` (with `P2_IDENTITY_VERSION_REGISTRATION_CONFIRMED=true`) before startup; whether redemption strictly requires it was not isolated. Keep the generated keyrings stable across backend restarts: the database records a check for each safety-identity key ID, and restarting with new material for the same key ID makes every redemption fail with `503 VERIFICATION_UNAVAILABLE`. Store throwaway secrets outside the repository with owner-only permissions.
- On an iCloud-synced checkout, evicted ("dataless") source files can stall backend startup silently; materialize them before starting.
- Use a Simulator whose app container has not been shared with XCTest runs. During CP2, a Simulator also used for XCTest showed P2's fail-closed `Account deletion unavailable` presentation at launch, which freezes networking; a fresh Simulator did not. The exact leftover state was not isolated.

**Routine use** (`npm run qa:env -- <command>`; run `npm run qa:mail-sink` and the backend on the environment's own ports)

1. Start the local mail sink (`QA_MAIL_SINK_PORT=<mailSinkPort>`; binds 127.0.0.1 only; remembers exact six-digit signup-verification and account-deletion challenge subjects in separate purpose- and recipient-specific stores for 10 minutes). Retrieve signup codes with `/latest-code?to=<address>` and deletion challenges with `/latest-deletion-code?to=<address>`. A local sink response proves only local capture, never external-provider delivery. Start the backend with the environment's `MONGO_URI`, `PORT=<backendPort>`, generated throwaway secrets, `RESEND_BASE_URL=http://127.0.0.1:<mailSinkPort>`, a fake `RESEND_API_KEY`, and `PUBLIC_ACTIONS_PAUSED=false`.
2. Launch the Debug app with `SIMCTL_CHILD_COMMONPLATE_DEBUG_API_BASE_URL=http://127.0.0.1:<backendPort>`. The override exists only in Debug builds (a Release build neither contains nor reads it), accepts only local/private `http://` hosts without credentials, path, query, or fragment, and a present-but-invalid value stops the launch rather than falling back.
3. Verify the requester and helper participants through the app's normal flow and read each code from the sink (`/latest-code?to=<address>`). Keep the Simulators and database alive so verification happens once; a normal reset preserves these identities.
4. `init` stores the environment marker (idempotent). `status` is read-only and prints counts only: no URI, address, or identifier. `reset`, `scenario`, and `drop` refuse to run without the marker.
5. **Idle both apps before `reset` or `scenario`.** Do not mutate one environment from two places at once. Use a separate environment (database, ports, Simulators) for each concurrent slice.

| Command | Effect |
| --- | --- |
| `init` | Create the marker for this environment. |
| `status` | Read-only counts and the base URL. |
| `reset` | Normal reset (below). |
| `scenario <preset>...` | Normal reset, then load presets. |
| `drop --confirm-database <exact database name>` | Full teardown (below). |

**Normal reset.** In one transaction it removes every `Request` in the environment and, for exactly those Requests, their `RequestParticipation`, `Fulfillment`, `PlacementEvidence`, `PushDelivery`, and `SendLog` rows and owned-fixture manifest entries. It clears `Participant.activeReservationRequestId` and `activeReservationClaimExpiresAt` only where the lock points at a removed Request, so a deleted claimed request cannot leave a helper reserved. It preserves `Participant` (all other fields), `ParticipantVerification`, `RequestOperation`, `RequestOperationAuthority`, `Installation`, `Subscriber`, and `System`, and any row that does not point at a removed Request. Simulator credentials therefore keep working. The same transaction removes the `PlacementEvidence` row of each removed Request (W4-H1a), and a guard test fails if a new model referencing `Request` appears, so it must be classified deliberately. QA `/api/stats` totals fall because fulfillment rows go with their Requests.

- **Quota.** The daily limit is unchanged (3 per address per campus day, counted from `Request` rows). Removing the rows is what makes the participant eligible again; nothing writes quota state.
- **D1/D2.** The operation ledger and authority survive, so replaying an operation whose Request was reset reconciles as terminal expired (410 `OPERATION_EXPIRED`), never creates a Request, and no NO-CREATE row is invented. A create still in flight in an app at reset time may therefore end up terminally expired there. Reset does not read or clear an app's private pending-operation state.
- **Orphans.** Rows whose Request had already expired by TTL are not part of the reset and are left alone.

**Full drop.** `drop` is a separate command that needs the exact database name typed as confirmation; `reset` rejects extra arguments and can never drop. It deletes the whole database, including participants, verification challenges, and the operation ledger and authority. Existing Simulator credentials for that environment stop validating and participants must verify again. Restart the environment's backend afterwards (it re-creates its indexes and operation authority at startup), then run `init` again. Use it only for the exceptional case where D1/D2 history must be discarded.

**Scenario presets.** `scenario` validates every preset document and the requester before resetting, so invalid input fails with nothing removed. At most one requester-owned preset per scenario; requester presets need `QA_REQUESTER_EMAIL` to name a participant who already verified through the app (the tool only looks it up and never creates identity).

| Preset | Resulting state |
| --- | --- |
| `clean` | Zero Requests. |
| `helper-board` | Five unowned helper-visible Requests: ASAP, two currently visible Later, ASAP with an estimate, Dining Dollars only. |
| `future-later` | One unowned future Later Request that helpers cannot see before its start. |
| `requester-below-quota` | One current-day ASAP Request owned by the verified requester. |
| `requester-quota-boundary` | Two current-day ASAP Requests owned by the verified requester, so their next real submission is the third of the day. |

Presets never fabricate D1/D2 ambiguity, claim or placement state, fulfillment, R3, or moderation state. Seeded quota requests have no operation history and prove only the quota count. Owned presets are recorded in the owned-fixture manifest, so `seed:ui:owned:cleanup` still removes exactly them. The older `seed:ui*` commands (narrow manifest/fixture cleanup) are unchanged. **Preset Requests expire like any other** (MongoDB TTL, roughly three hours, with a lagging sweep): reload with `scenario <preset>` when the expected state is gone.

**QA1 verification commands** (all from the repository root; Mongo suites need `MONGO_INTEGRATION_URI` for a replica set, which `npm run test:mongo` provides):

```bash
npm run typecheck
npx vitest run scripts/qa-environment.test.ts scripts/seed-ui-request.test.ts scripts/local-mail-sink.test.ts
npm test                 # Mongo-gated suites are skipped by configuration
npm run test:mongo       # runs qa-environment.mongo, qa-environment.operations.mongo, seed-ui-request.mongo
npm run ci-check
```

Focused iOS: `-only-testing:CommonPlateiosTests/APIConfigurationDebugOverrideTests` with the command in section 9, then the complete `CommonPlateiosTests` target. The standard checks in sections 3, 4, 5, 9, 11, and 12 still apply unchanged.

`scripts/qa-environment.mongo.test.ts` gives its suite a file-local 15-second timeout (`QA_CLI_WORKFLOW_TIMEOUT_MS`, passed through the suite helper); it is not a global configuration. Its tests each run several CLI commands that open their own Mongo connection. They take about 0.3-1.5 s on a quiet machine and two exceeded the default 5 s while Xcode was building concurrently. Under heavy CPU contention the slowest took 2-3 s. That is the remaining limit: a machine more than roughly ten times slower than quiet can still time out, and the response is to diagnose rather than raise the limit again.

**Accepted evidence and proof boundaries.** Automated: unit, real-Mongo (including two simultaneous environments, D1/D2 non-resurrection through the real `createRequest` route, the real quota flow, identity preservation, and full-drop separation), two mutation checks, and the iOS override tests. The two-Simulator requester/helper verify-claim-fulfill walkthrough and a live reset-between-apps check were completed on Simulators against an isolated backend (recorded in the weekly spec); independent HIGH-risk review passed with nonblocking findings F1-F5, all dispositioned. Not proven: physical device, real Resend or APNs delivery (the fulfillment email goes to the sink; `notificationStatus: sent` is provider acceptance only), signed Release/Archive/TestFlight, production endpoint selection, and a Release app launch (Release isolation was shown by binary inspection and Release builds). Pre-existing and not QA1-owned: `npm ci` fails on a clean base because `package-lock.json` has drifted from `package.json`, and some hosted-layout iOS tests are environment-dependent (one complete iOS run failed with extra Simulators booted and passed on a rerun with them shut down; cause not established).

## 6. Browser-client bundles

Edit `src/client/*.ts`; never edit `public/js/*.js` directly. Rebuild with:

```bash
npm run build:client
```

The generated bundles are tracked and begin with a generated-file banner. After rebuilding, inspect `git diff` and confirm that only expected bundle changes are present. Current tooling does not independently fail CI merely because regenerated bundles differ, so the reviewer must verify the diff. No generated-output enforcement check exists.

## 7. iOS prerequisites

Full Xcode is required; Command Line Tools alone are insufficient. Verify the selected developer directory with:

```bash
xcode-select -p
```

The expected form is `/Applications/Xcode.app/Contents/Developer`. Correct it when necessary with:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The project is `ios/CommonPlateios/CommonPlateios.xcodeproj`; its shared scheme is `CommonPlateios` and its unit-test target is `CommonPlateiosTests`. The project's `IPHONEOS_DEPLOYMENT_TARGET` is 17.6; accepted test runs have executed against an iOS 26.5 simulator runtime, so use Xcode with a matching installed simulator runtime available. iOS 26.5 is the simulator runtime used for verification, not the deployment target.

## 8. Discovering an available simulator

Run:

```bash
xcrun simctl list devices available
```

Choose an available iPhone simulator from that output and copy its UDID into the test command. Do not assume a particular model exists on every machine.

## 9. Complete terminal iOS test command

**Checkout location.** Run the iOS tests from a checkout that is not under `/tmp`
(for example under your home directory). On macOS `/tmp` resolves to `/private/tmp`,
which shifts the relative paths that the source-scan tests compute and makes
`ScreenshotAssistanceBoundaryTests` and `ScreenshotQualificationFingerprintTests`
fail spuriously. The derived-data path below may stay in the temporary directory.
Some hosted-UI timing tests (for example `HomeRefreshSettleHostedMotionTests`) have
failed intermittently in complete-target runs and passed on rerun; record both
results rather than weakening an assertion.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/CommonPlateios/CommonPlateios.xcodeproj \
  -scheme CommonPlateios \
  -destination 'platform=iOS Simulator,id=<AVAILABLE_SIMULATOR_UDID>' \
  -derivedDataPath "${TMPDIR:-/tmp}/CommonPlate-Tests-DerivedData" \
  -only-testing:CommonPlateiosTests
```

The W4-F1 acceptance complete-iOS proof was **785 passed, 0 failed, 0 skipped, TEST SUCCEEDED**; the current accepted baseline is recorded in section 13. Compilation alone is not a passing test result: the result bundle must complete and the output must contain `TEST SUCCEEDED`. Xcode GUI and terminal runs use the same shared scheme and `CommonPlateiosTests` target.

**Focused routing and its limits.** After W4-S3, the complete target (1,713 tests) took about 242 seconds of test-action time, with most of that cost concentrated in the hosted Requester UI classes (`RequesterFormHostedFidelityTests`, `RequesterIncompleteVsInvalidHostedTests`, `RequesterMealPresentationHostedTests`, and `RequestCreationContinuityHostedGeometryTests`). Focused `-only-testing:CommonPlateiosTests/<TestClass>` runs are tier 1 and tier 2 proof under [Verification tiers and post-fix invalidation](#verification-tiers-and-post-fix-invalidation); they are acceptance evidence (tier 3) only for change classes that section 11 allows to use them, and never replace a complete-target run that a full-regression trigger or an explicit slice contract requires. Named test groups are listed in [Verification routing manifests](#verification-routing-manifests) below. `-skip-testing` is never acceptance evidence: it may shorten a local loop, and any result obtained with it must be rerun with `-only-testing` filters or the unchanged complete command before it counts. Class names and timings drift; re-check the live test target rather than treating a manifest as a maintained list.

Automated routing tests (this target included) prove tap-routing logic against stubbed backend resolution; they do not by themselves prove real APNs terminated-launch handoff on a device. Physical-device proof was required for helper terminated-launch tap routing and for requester-fulfillment push, and both have now passed on a physical iPhone. Release/Archive/TestFlight signing and environment behavior is unrelated evidence and remains a separate, still-open environmental gate (see `docs/system-contract.md` section 11).

Automated and source-text assertions can prove that `RequestFoodView` installs the NYU/New York timezone and calendar into the SwiftUI environment; they cannot prove what a real `DatePicker` renders on a device actually configured to a different timezone. W3-R1 required physical-device verification on a non-Eastern device for exactly that reason: an iPhone configured to Phoenix time (no DST offset from New York for part of the year) displayed the intended NYU/New York wall-clock selection of 10:30 PM rather than device-local Phoenix time, and submitted `windowStart = 2026-08-09T02:30:00.000Z`, `visibleFrom = 2026-08-09T02:30:00.000Z`, and `expiresAt = 2026-08-09T05:30:00.000Z`; the requester email rendered `Aug 8, 10:30 PM – Aug 9, 1:30 AM`. This is device evidence, not part of the automated `CommonPlateiosTests` count above, and it predates and is unaffected by the later presentation-contract correction, which does not touch timezone rendering or submission code.

### W4-F1 Product Truth & Visual Foundation acceptance

For W4-F1 iOS changes, run focused affected suites using the section 9 command
with the applicable repeated `-only-testing:CommonPlateiosTests/<TestClass>`
filters, then run the complete `CommonPlateiosTests` command unchanged. The
final production tree passed focused W4-F1/affected suites at **166 passed, 0
failed, 0 skipped** and the complete target at **785 passed, 0 failed, 0
skipped, TEST SUCCEEDED**. Both final `xcodebuild test` commands succeeded;
their build/test processing also validated the required app resources,
embedded Fraunces registration, and semantic-color assets. `git diff --check`
and the staged diff check passed where run.

Rendered simulator evidence covered Home at normal Dynamic Type (fully visible
action labels, coherent hierarchy and shape), largest accessibility Dynamic
Type (labels grew/wrapped without clipping and Home remained vertically
scrollable), and dark appearance (legible, differentiated hierarchy/colors).
The final simulator could not programmatically navigate to the verification
email/code stages: the host GUI had no usable input/accessibility route and
the app has no existing UI-test or deep-link route that presents that sheet
without changing behavior. This documentation does not claim final rendered
simulator verification-stage screenshots; source/tests establish structural
verification behavior instead.

The project owner performed the final physical-device walkthrough, said it looked good,
and explicitly accepted W4-F1. That physical acceptance supplies the final
rendered/user-visible verification evidence that automation and source tests
cannot substitute for; it does not establish Release/Archive/TestFlight or
production-environment behavior.

### W4-R1 Home and requester experience coverage

The focused onboarding/brand/foundation suites passed **20 tests, 0 failed**.
The complete `CommonPlateiosTests` target passed **795 tests, 0 failed, 0
skipped, TEST SUCCEEDED**. `git diff --check` passed. The fresh independent
review found no MUST FIX, SHOULD FIX, or contract conflict and concluded that
the implementation was ready for visual verification. The project owner then completed
the requested visual walkthrough and accepted the observed first-launch,
walkthrough, recurring Home, requester-entry, responsive-control, and
accessibility-size presentation and interaction behavior.

The automated and source-focused tests establish onboarding persistence and
replay state, exact copy and ordering, route wiring, control-size seams,
typography scope, requester presentation labels, and preservation of the
existing identity/requester behavior. They do not establish VoiceOver reading
order, provider delivery or notification reading, Release/Archive/TestFlight
signing or environment behavior, or any configuration-specific result that
was not rendered or exercised. The project owner's visual acceptance is the evidence for
the observed rendered and interaction behavior; it does not extend those
environmental or provider claims. The separately authorized verification
Cancel → X correction remains outside the R1 evidence and acceptance record.

### W4-C1 R1 carryover reconciliation

Request Food reconciliation required no additional implementation because the
accepted R1 behavior already satisfied it. The only C1 correction replaced the
verification-modal `Cancel` presentation with the accepted top-leading
`xmark`; the cancellation action, destination, and lifecycle behavior are
unchanged. Focused proof passed **21 tests, 0 failed, 0 skipped**. The complete
`CommonPlateiosTests` target passed **795 tests, 0 failed, 0 skipped, TEST
SUCCEEDED**. Independent review was CLEAN. These source-level presentation
tests are not rendered UI proof; the correction is limited to presentation and
does not alter the verification lifecycle.

### W4-H4 Home continuous scroll composition acceptance

W4-H4 is accepted. It is an iOS-only slice: per section 11, its minimum
verification is focused suites plus the complete `CommonPlateiosTests` target.
No backend, Mongo, or browser-bundle check was required or rerun for H4, and
none is claimed here.

Automated coverage proves the count-sensitive ownership preview (0/1/2/3+ and
`See all N`), the ownership partition — including that an owned request hidden
from the two-card Home preview is still excluded from `Needs help right now` —
the `See all N` destination wiring, one unified Home `ScrollView` with exactly
one `.refreshable`, the persistent-CTA `.safeAreaInset` bottom accommodation,
the shared 24-point content-column authority, and the manual-refresh deadline
contract.

`HomeRefreshCallerCancellationTests` covers the physical-device refresh defect
behaviorally rather than by source text: it drives the production
`HomeExchangeView.awaitWithDeadline`, the production
`RequestStore.fetchRequests()`, and a real `URLSession` behind the existing
`RequestFetchingURLProtocol` stub, and proves that a refresh whose calling task
is cancelled mid-flight still applies the new authoritative requests, that
repeated cancelled refreshes leave the latest authoritative result through the
existing generation/collection-revision fence rather than anything added by the
fix, that an operation losing the manual-refresh deadline is still cancelled and
still reports failure without a spurious `refreshError`, and that an uncancelled
refresh is unchanged. These tests do not, and cannot, prove the physical pull
gesture itself; they prove the refresh path applies authoritative data when the
caller is cancelled the way SwiftUI cancels it.

At acceptance: focused Home/H4/refresh suites passed **115 passed, 0 failed, 0
skipped**; the complete `CommonPlateiosTests` target passed **1,009 passed, 0
failed, TEST SUCCEEDED** for the H4 commit set in isolation and **1,032 passed,
0 failed, 0 skipped, TEST SUCCEEDED** on the full working tree (see the
attribution table below); `git diff --check` passed. Independent
engineering review was CLEAN. The ownership-partition review fix and the
refresh cancellation/lifetime fix were each independently rereviewed CLEAN /
RESOLVED.

**Complete-target total attribution (measured, not inferred).** The 1,032
figure was measured on the full working tree, which also carries unrelated
in-progress W4-R2/W4-S1 and dev-seed work, so it is not an H4 total. Three
complete-target runs were taken during H4 closeout to separate the slices, each
in an isolated `git worktree`:

| Tree | Result |
| --- | --- |
| Clean `W4-Q1` commit (`fb3adcd`), no local changes | 976 passed, 0 failed |
| That commit plus exactly the staged W4-H4 commit set | 1,009 passed, 0 failed |
| Full H4 working tree, including unrelated R2/S1/seed work | 1,032 passed, 0 failed |

**1,009 is the H4-attributable total** and is what the target will report once
the H4 commit lands. H4 contributes exactly 33 cases over the committed Q1 tree:
9 in `HomeContinuousScrollCompositionTests`, 6 in
`HomeOwnershipPartitionRegressionTests`, 6 in
`OwnRequestsSeeAllDestinationTests`, 4 in
`HomeRefreshCallerCancellationTests`, and 8 added to
`HomeExchangeBoardStateTests`. The remaining 23 cases between 1,009 and 1,032
belong to unrelated in-progress work and must not be credited to H4.

**Discrepancy flagged, not silently rewritten.** The W4-Q1 row below records
1,001 for `CommonPlateiosTests` at Q1 acceptance, but a clean checkout of the Q1
commit measures 976. That earlier figure therefore appears to have been taken on
a working tree that also carried then-in-progress work, the same way 1,032 does
here. Q1's own acceptance record is left as written — correcting it belongs to
Q1, not to this slice — but no H4 statement relies on 1,001, and the H4 baseline
below uses the measured 976/1,009 pair instead.

Physical-device verification completed by the project owner on a physical iPhone: final
Home proportions and the shared content column, the persistent CTA and its
soft-floating treatment, pull-to-refresh correctness, automatic fresh data on
Home return, larger Dynamic Type, and VoiceOver traversal and focus all passed,
and the native safe-area relationship is accepted. The remaining apparent
CTA-bottom-position difference against Figma is recorded as **NO ACTION /
CONTRACT-LIMITED DEVICE SAFE-AREA DIFFERENCE**: authored CTA bottom padding is
zero and the residual clearance is the device-provided home-indicator safe area,
so moving the CTA lower would require a negative adjustment or safe-area overlap
the accepted contract prohibits.

**Known, accepted limitations.** The repository still has no iOS UI-test
target, so no automated check drives the real pull gesture, the rendered Home
composition, Dynamic Type layout, or VoiceOver traversal; the physical-device
evidence above is the authority for every device-specific safe-area, gesture,
and accessibility observation, and the source and unit tests do not by
themselves establish any of them. Simulator reproduction of the refresh defect
and of the fix was performed with synthetic pointer drags against the local
backend; that is stronger than source inspection but is not physical-device
proof and does not replace it. The authored refresh presentation and polish
remain W4-H3's, and nothing in H4's evidence accepts them. H4 acceptance does
not establish Release/Archive/TestFlight signing or environment behavior, which
remains open (`docs/system-contract.md` section 11).

**Freshness-scope correction (verified).** `docs/system-contract.md` section 1.4
deliberately states Home freshness as "when Home appears" plus manual
pull-to-refresh. Returning CommonPlate to the foreground from the background is
**not** an automatic refetch: with ten open requests present on the backend, an
app foregrounded from the background continued to render Empty Exchange until a
pull-to-refresh was performed, and no `scenePhase` transition invokes
`fetchRequests()`. This was verified on the simulator during documentation sync.
The accepted "fresh data on Home return" physical result is recorded above as
The project owner observed it; it is not documented as a background-to-foreground refresh
guarantee. See the open question raised at H4 closeout.

### W4-D2 Exact Request-Create Terminal Reconciliation acceptance

W4-D2 is accepted (not yet COMMITTED). It extends W3-D1 (section 9 above,
`docs/system-contract.md` section 6.3) with exact-operation terminal
reconciliation, Success→Home continuity, and the exact-created-request Home
continuity exception (`docs/system-contract.md` section 6.4).

Focused iOS coverage for this acceptance: `RequestCreateTerminalReconciliationTests`
(the full recovery matrix — stable unresolved, identity-unavailable,
authority-mismatch, and terminal NO-CREATE Path A/Path B, including the
confirmed matrix-row-2 payload-unreadable-reaching-NO-CREATE case),
`RequestCreateDurableOperationTests` and `RequestCreatePendingOperationScopeTests`
(durable recovery-identity envelope, legacy-record recovery, fresh-submission
classification unchanged), `RequestCreationViewTests` and
`RequestFoodDraftSessionTests` (Path A form restoration and Path B honest-empty
fallback, with no reconstruction/guessing of unreadable fields),
`RequestFetchingTests` and `HomeOwnershipPartitionRegressionTests` (the
Success→Home continuity insertion narrowly superseding the prior W4-R2
no-insertion behavior), `HomeExactCreatedRequestAvailabilityTests` (new — the
exact-created-request loading/unavailable exception, including that it never
reports the board as populated and never leaks stale broader/helper/discovery
content), `RequestCreationContinuityTests`, `RequestCreationContinuityLandingTests`,
`RequestCreationContinuityFallbackCrossfadeTests`, and
`RequestCreationContinuityHomeRevealTests` (the coordinated card-to-card
crossfade fallback and valid-target landing geometry), and
`RequestCreationContinuityHostedGeometryTests` (new — hosted regression
coverage, mounting the real production view inside a real `NavigationStack`
and a real `UIWindow` with a non-zero simulator safe area, for two proven
physical-device geometry defects: a named `CoordinateSpace` not resolving
across the `NavigationStack` hosting boundary, fixed by measuring in
`.global`; and a slot-frame commit reading a captured-once `.task` parameter
instead of the latest delivered value, fixed by mirroring it into `@State`
before commit).

At acceptance: complete `CommonPlateiosTests` — **1,381 passed, 0 failed, 0
skipped**. `git diff --check` passed.

**Hosted (non-UI-test) geometry regression proof.** Per section 10's note that
this repository has no iOS UI-test target, `RequestCreationContinuityHostedGeometryTests`
is this repository's established technique for proving rendered end-state
geometry without one: it mounts the real production `RequestCreationContinuityView`
and `HomeOwnedRequestSlotFrameKey` wiring inside a real `NavigationStack`-hosted
Home slot in a `UIWindow` carrying the simulator's own non-zero safe area, and
reads the actually-drawn pixels. It proves rendered end-state geometry against
Home's real slot for the covered scenarios; it does not replace physical-device
proof of smoothness or of the absence of a visible jump mid-travel.

**Physical-device acceptance.** The project owner completed a physical-iPhone visual
acceptance walkthrough and explicitly accepted W4-D2 on that basis. Confirmed
visually on device: the standard-motion Posting → Success → Home continuity
sequence landing at Home's real requester-owned slot; the geometry-fallback
coordinated crossfade when no usable landing target is captured; the
exact-created-request appearing in `Your request(s)` while broader Home
content is loading/unavailable; and both standard motion and Reduce Motion for
this sequence after the geometry repair above.

**Accepted verification limitation.** As recorded in the current weekly spec's
W4-D2 card, no deterministic, safe, development-only way currently exists to
exercise D2's physical recovery states (stable unresolved; terminal NO-CREATE
Path A; terminal NO-CREATE Path B; write-uncertain/response-loss) on a
physical device. Physical-device termination/relaunch, network-interruption
timing/recovery, and provider/environment behavior for these recovery states
were **not** exercised during the acceptance walkthrough above and remain
unperformed, consistent with the equivalent W3-D1 limitation recorded in this
document. This is an accepted verification limitation, not evidence that
these specific recovery states were physically proven, and it does not
establish Release/Archive/TestFlight signing or environment behavior, which
remains open (`docs/system-contract.md` section 11). A separate, narrow
requester-timing observation from the same walkthrough (`Scheduled pickups
reopen tomorrow.`, since replaced by W4-UI1 CP2's
`Scheduling is closed for today. ASAP only.`) is not a D2 behavior and is not covered by this
acceptance; see the current weekly spec's deferral ledger for its Week HQ
routing.

### W4-R4 Structured Meal Requests & Multi-Screenshot Evidence acceptance

**W4-R4 is accepted and COMMITTED (`7fedbfe`).** The project owner explicitly accepted W4-R4 on
2026-09-29 on the basis of the complete implementation, automated
verification, independent review, and the physical R4 verification recorded
below. This subsection records the accepted verification state; see the
current weekly spec's W4-R4 card for the full lifecycle and contract history.

**Structured request / Screenshot Assistance automated proof.** Current
focused coverage spans: structured Meal Exchange / Dining Dollars
representation and validation (`src/structuredRequest.ts`,
`src/structuredRequest.test.ts`, `src/createRequestRoute.test.ts`,
`src/createRequestRoute.mongo.test.ts`); multi-screenshot analysis and
deterministic proposal validation (`src/screenshotEligibility.ts`/`.test.ts`,
`src/screenshotProposalValidation.ts`/`.test.ts`,
`src/screenshotProposalRoute.test.ts`, `src/screenshotProposalTypes.ts`);
manual authority and field-level provenance, incomplete-vs-invalid
presentation, and menu-path reset (`RequestFoodFormValidation.swift`,
`RequestFoodView.swift`, `RequestIncompleteVsInvalidValidationTests.swift`,
`RequesterIncompleteVsInvalidHostedTests.swift`); requester rendered
geometry, the DD ordering control, and populated/expanded Meal geometry
(`RequesterFormLayout.swift`, `RequesterFormLayoutBehaviorTests.swift`,
`RequesterFormHostedFidelityTests.swift`, `RequesterFormHostedHarness.swift`,
`RequesterMealPresentationHostedTests.swift`); mounted Meal
presentation/focus/accessibility behavior, preserved-entry rerun
qualification/lifecycle, and the unified Meal provenance OR presentation
(`ScreenshotProposalStore.swift`, `ScreenshotProposalStoreTests.swift`,
`ScreenshotPreservedEntryFeedbackLifecycleTests.swift`); and the durable
request-create operation surfaces R4's structured payload flows through
(`RequestCreateDurableOperationTests.swift`,
`RequestCreatePendingOperationScopeTests.swift`,
`RequestCreateTerminalReconciliationTests.swift`,
`RequestCreationViewTests.swift`, `RequestFoodDraftSessionTests.swift`,
`MealSwipeQuantityTests.swift`, `ParticipantContinuationTests.swift`,
`RemoveEmailTests.swift`).

**Accepted complete iOS target.** The latest complete `CommonPlateiosTests`
target at R4 acceptance: **1,483 passed, 0 failed, TEST SUCCEEDED**. A final
focused provenance/badge-unification implementation pass measured **225
tests, 0 failures**. At R4 acceptance this result became the accepted
baseline (section 13 below), superseding the prior W4-D2 acceptance figure
(1,381 passed, 0 failed, 0 skipped); it has since been superseded by the
W4-S3 figures, the latest being the consent-authority revision figure
(1,744 total, 1,742 passed, 0 failed, 2 expected configuration skips), which
is the current accepted baseline (section 13). `git diff --check` was clean after the final
implementation. R4 was subsequently committed as `7fedbfe`.

**Physical-device proof.** Distinct from the automated/simulator proof above,
The project owner completed a physical-iPhone requester and Screenshot Assistance
walkthrough. Requester presentation/interaction confirmed: incomplete
required fields stay neutral and keep `Post request` disabled; DD
ordering-field geometry/copy; adaptive `Post request` placement; collapsed/
expanded Meal presentation; full `Details` wrapping without ellipsis; equal
Meal item/Details hierarchy; materially improved Meal expand/collapse
latency; and the unified Meal provenance presentation. Screenshot Assistance
confirmed: real `PhotosPicker` multi-image selection/analysis; a correct
eligible multi-screenshot structured proposal (three Meal Exchange meals, a
strongly-supported `$2.00` Dining Dollars proposal); no auto-submit; manual
Meal-item and Details authority preserved independently across an eligible
rerun; an untouched screenshot-derived value remaining eligible to update;
provenance clearing/restoration through a later valid reproposal; the exact
qualifying preserved-entry message `Screenshot checked. Your existing entries
were kept.`; its correct absence on a non-qualifying eligible rerun; feedback
cleanup on view disappearance and on Screenshot Assistance disablement; and
the nonqualifying-prior-outcome behavior the project owner exercised. The project owner did not
record a detailed device transcript for every individual
unsupported/failed/cancelled/nil subcase; no physical proof is claimed for a
subcase not individually observed, and the automated F1+F2 focused proof
(`RequestCreateTerminalReconciliationTests`/`ScreenshotProposalStoreTests`
state-machine coverage) is the record for those exact cases instead. This
physical proof does not establish Release/Archive/TestFlight signing or any
provider environment beyond the observed Screenshot Assistance run.

**Hosted-test methodology notes.** As with W4-D2's
`RequestCreationContinuityHostedGeometryTests` technique above, R4's hosted
requester fidelity tests (`RequesterFormHostedFidelityTests.swift`,
`RequesterFormHostedHarness.swift`,
`RequesterIncompleteVsInvalidHostedTests.swift`,
`RequesterMealPresentationHostedTests.swift`) mount the real production
SwiftUI view in a `UIWindow` and inspect rendered geometry/accessibility
rather than source strings; source-string checks do not substitute for
rendered-geometry proof. Some hosted runs can stall when the Mac idles;
`caffeinate -i` was required for reliable execution during this slice. This is
an incidental test-run/environment note, not a product limitation.

**Accessibility limitation.** Hardware-keyboard Tab traversal into the
mounted hidden Meal editor was not physically established. No failure is
known; this is deferred, unperformed physical evidence owned by W4-A1, not a
demonstrated defect (see the current weekly spec's W4-A1 card).

### W4-S3 Shared Screenshot Assistance Runtime & Local-First Routing acceptance

The W4-S3 runtime baseline is COMMITTED (`3d4287f`); the project owner explicitly accepted it on 2026-09-30 and re-accepted it after the retired W4-OBS1/Datadog dependency was removed. The project owner then re-accepted W4-S3 (2026-10-01) for the revised Screenshot Assistance consent-authority behavior; that revision is accepted and not yet COMMITTED. The accepted state below is the post-removal state with the consent-authority revision applied. `docs/system-contract.md` section 15 records the accepted runtime truth; the current weekly spec's W4-S3 card owns lifecycle and deferrals.

**Focused iOS coverage.** New focused files under `ios/CommonPlateios/CommonPlateiosTests/` (shared helpers: `ScreenshotAssistanceTestSupport.swift`, `ScreenshotConformanceSchemaSupport.swift`, `ScreenshotS3FixTestSupport.swift`):
- schema-neutral runtime, ordered multi-screenshot input, and the test-only second-schema conformance workflow: `ScreenshotAssistanceRuntimeTests`, `ScreenshotSharedRuntimeConformanceTests`, `ScreenshotConformanceVectorTests`;
- local-first routing, qualification identity/enforcement, empty production registry, and fail-closed routing matrix: `ScreenshotLocalFirstRoutingTests`, `AppleOnDeviceScreenshotProviderTests`, `ScreenshotQualificationFingerprintTests`, `ScreenshotFingerprintBuildScriptTests` (runs the actual build-phase script text under `/bin/bash`);
- external fallback under standing consent, authority timing/loss, single-use runtime transfer-permission binding, evaluation fencing, and the external-transfer request seam (store → runtime → shipped external provider → `ScreenshotProposalService` → `APIClient` → a recording `URLProtocol`, proved by transport request count and store state: zero requests for a retired, cancelled, stale, replayed, consent-less, or authority-less attempt, exactly one for a valid attempt under standing consent): `ScreenshotFallbackAuthorityTimingTests`, `ScreenshotAuthorityAtFallbackTests`, `ScreenshotExternalPermissionBindingTests`, `ScreenshotEvaluationFencingTests`, `ScreenshotExternalRequestSeamTests`;
- revised consent authority (Off → On disclosure, `Not Now`/`Turn On`, persisted contract-bound consent, revocation on Off, legacy-state and corrupt/mismatched-record fail-closed behavior, no per-attempt popup, Off-blocked local and external processing, stale-result fencing after revocation) and disclosure presentation/source wiring (exact copy, both Settings and Request Food entry points): `ScreenshotAssistanceConsentAuthorityTests`, `ScreenshotAssistanceDisclosurePresentationTests`;
- deadline-bounded local orchestration (non-cooperative provider; late completion stale): `ScreenshotDeadlineEnforcementTests`;
- structural boundary tripwires, including that no Datadog/observability package, initialization, or telemetry reference exists in the app target or project: `ScreenshotAssistanceBoundaryTests`;
- updated Requester regressions: `ScreenshotProposalStoreTests`, `ScreenshotPreservedEntryFeedbackLifecycleTests`, `RequestFoodEntryTests`, `RequestCreationViewTests`. `ScreenshotProposalDisclosurePresentationTests` was removed with the pre-S3 disclosure (superseded; `docs/system-contract.md` sections 12–13).

A focused run uses section 9's command with `-only-testing:CommonPlateiosTests/<TestClass>` in place of `-only-testing:CommonPlateiosTests`.

**Backend drift guard.** `shared/screenshot-conformance-vectors.json` is asserted by `src/screenshotConformanceVectors.test.ts` (backend) and `ScreenshotConformanceVectorTests` (iOS). S3 changed no backend route or runtime code. The focused `npx vitest run src/screenshotConformanceVectors.test.ts` run (118 passed) was executed during the acceptance documentation sync; `npm test` and `npm run test:mongo` were **not** rerun for S3 and their baselines below are unchanged.

**Accepted automated baseline (post-OBS1-removal, pre-consent-revision).** Complete `CommonPlateiosTests`: **1,713 passed, 0 failed, 0 skipped**. Release builds succeeded for the generic iOS Simulator and for the unsigned generic iOS device. The qualification fingerprint derived by the always-run `Derive Screenshot Qualification Fingerprint` build phase was identical across Debug, Release-simulator, and Release-device builds. The Release builds are also the proof gate for a Swift 6.3 release-optimizer crash on the synthesized deinit of generic classes (`docs/decisions/screenshot-qualification-fingerprint-and-release-build-constraints.md`); Debug-only runs do not exercise it. `git diff --check` was clean. The 1,713 total is the measured post-removal suite; the OBS1 telemetry-only tests were deleted with the retired dependency. The acceptance also confirmed by source/project inspection that no Datadog package, product, initialization, `ScreenshotAssistanceTelemetry` file, or stale SwiftPM resolution remains. Compilation alone is not a passing result: the result bundle must complete and print `TEST SUCCEEDED`.

**Revised consent-authority verification (the project owner re-accepted 2026-10-01).**
- *Focused S3 selection:* `ScreenshotAssistanceConsentAuthorityTests`, `ScreenshotAssistanceDisclosurePresentationTests`, `ScreenshotAssistanceBoundaryTests`, `ScreenshotAuthorityAtFallbackTests`, `ScreenshotDeadlineEnforcementTests`, `ScreenshotEvaluationFencingTests`, `ScreenshotExternalPermissionBindingTests`, `ScreenshotExternalRequestSeamTests`, `ScreenshotFallbackAuthorityTimingTests`, `ScreenshotLocalFirstRoutingTests`, `ScreenshotProposalStoreTests`: **205 passed, 0 failed, 0 skipped, TEST SUCCEEDED**.
- *Builds:* the Release generic iOS Simulator build and the unsigned generic iOS device Release build both **succeeded** (unsigned; not a signed/Archive/TestFlight result).
- *Qualification fingerprint:* the same Screenshot Assistance qualification fingerprint, `d0de0ead6c5c373eea8a1eda71393f6f51ee2205d85074b06be2a72c67421bd9`, was observed across the Debug simulator, test-build Debug, Release simulator, and Release generic-device builds.
- *Independent review:* a fresh independent review found no S3 correctness defect in consent persistence, local-processing authority, external-transfer authority, revocation/races, stale-result fencing, payload boundary, legacy/reset behavior, or disclosure source wiring; no S3 code fixes were required afterward.
- *Physical device:* the project owner performed the revised consent flow on a physical iPhone and confirmed (1) an Off → enable attempt shows the disclosure before enabling; (2) `Not Now` leaves Screenshot Assistance Off; (3) `Turn On` enables it; (4) On → Off disables and revokes; (5) a later enable attempt shows the disclosure again. Manual Request Food remained available while Off.
- *Integrated target:* complete `CommonPlateiosTests` — **1,744 total, 1,742 passed, 0 failed, 2 expected configuration skips, TEST SUCCEEDED**. The two skips are the S2.1 development-evaluation tests, which are gated by configuration. This is the current accepted complete-iOS baseline. `git diff --check` passed.
- *Limitation:* source and unit tests prove consent state, authority, fencing, and source wiring; they do not themselves prove SwiftUI presentation, and no iOS UI-test target exists. Presentation was verified by the physical-device walkthrough above only. That walkthrough observed a brief perceptible delay between tapping the enable control and the disclosure appearing; consent sequencing was correct and nothing became enabled before the disclosure. It is a presentation-responsiveness item, not an S3 correctness defect, and is deferred to Candidate Stabilization (UI responsiveness/polish) per the current weekly spec. The walkthrough does not establish Release/Archive/TestFlight signing or endpoint behavior, or provider reachability. `npm test` and `npm run test:mongo` were not rerun for this revision (no backend change).

**Physical-device acceptance and its limits (earlier smoke, pre-revision consent model; the revised-consent walkthrough is recorded above).** A bounded physical-iPhone smoke was performed on an iPhone 16 Pro, iOS 26.3.1, with Apple Intelligence On, using a Debug build. It exercised the real `PhotosPicker` and device preprocessing (Vision OCR) path; the closed production registry (zero entries, so Foundation Models was not invoked despite Apple Intelligence being On) taking the fallback path; the manual flow with no external transfer before the then-current authorization step; and retirement/back-navigation preventing any late result application. These are the project owner-observed device results. They do **not** establish Apple local-model extraction quality or qualification (none exists), held-out corpus quality, or S2 thresholds. The smoke used a temporary, since-reverted development LAN backend configuration (`APIConfiguration.localSimulator` pointed at the development Mac), so it does **not** establish Release/Archive/TestFlight signing or endpoint behavior, which remains open (`docs/system-contract.md` section 11). The Settings-Off retirement path was not separately recorded in the smoke. The smoke was not rerun after the OBS1/Datadog removal: that removal changed no requester-visible or device-only boundary, so the recorded smoke remains the device evidence, and the replaced transfer-timing observation is now covered by the transport request-count proof above.

**Accepted verification limitation.** No iOS UI-test target exists; disclosure presentation, retirement, and routing are proven by store/runtime/source-inspection tests plus the physical-device evidence above, not by UI automation. The deadline test proves control returns without waiting for a non-cooperative provider; it does not prove cancellation of a provider that blocks the main actor.

### W4-H3 Home refresh experience acceptance

W4-H3 is accepted (2026-10-10). It is an iOS-only slice. It is grandfathered under the pre-VP1 complete-target rule (see the prospective transition in the verification-tier policy above): its explicitly contracted gate is the complete `CommonPlateiosTests` target on its final candidate, and that gate was satisfied. No backend, Mongo, or browser-bundle check was required or rerun for H3.

**Accepted candidate.** Branch `w4-h3-home-refresh` at `56c0a17daad52a52276c236bc1e4c8bf3a5ee5ef` plus its uncommitted working tree (nothing staged), identified by that `git status` / `git diff` state (content digest `b426e39d…`). The branch predates W4-QA1 and W4-VP1, so its totals are not additive to a later `main` baseline.

**Automated evidence (executed on the candidate).** Focused H3 / Option B proof green; complete `CommonPlateiosTests`: **1,993 executed, 0 failed, 0 skipped**; Release generic iOS Simulator build succeeded; `git diff --check` and the staged diff check clean; a final fresh focused independent review returned 0 MUST FIX. These results were reported by the H3 slice session; the HQ triage, the physical-device gate, and the documentation sync did not rerun them, and no production or test byte changed after the complete-target run.

**Classes added by H3** (test-method counts by source, not executed counts): `HomeRefreshOutcomeTests` (16), `HomeRefreshAcknowledgmentContextTests` (11), `HomeRefreshExperienceTests` (29), `HomeRefreshSettleSequencingTests` (31), `HomeRefreshSettleProductionStreamTests` (21), `HomeRefreshSettleHostedMotionTests` (8), `HomeRefreshHostedScrollTests` (7), `HomeRefreshNoLaneRecoveryTests` (12), `HomeRefreshNoLaneProductionStreamTests` (6). Together with the modified Home neighbors (`HomeExchangeRefreshDeadlineTests`, `HomeContinuousScrollCompositionTests`, `HomeExchangeBoardStateTests`, `HomeExchangeStatePresentationTests`, `OwnRequestsSeeAllDestinationTests`) they exercise the success-outcome predicate, acknowledgment context-bound suppression and new-refresh retirement, the Decision 12 settle sequencing and parameters, recorded production-stream replay, the successful-recovery fallback and its regression pin, hosted scroll and motion presentation, and the unchanged deadline/cancellation neighbors.

**Not established by automation.** The repository has no iOS UI-test target, and no automated check drives the real pull gesture, the rendered motion, physical VoiceOver announcement or focus behavior, accessibility frames, or hit-testing while the authored offset is active. Source inspection and hosted tests do not by themselves establish them. The Simulator results (Standard Motion, Reduce Motion, repeated pull, dark appearance, large Dynamic Type, scroll-away and navigation-away suppression) were observed by the project owner on the Simulator and are not physical-device proof.

**Physical-device evidence (the project owner-observed).** ifone, iPhone 16 Pro, iOS 26.3.1. Required Rows 1–8 passed: pull/spinner/collapse feel; Standard Motion visuals; healthy → healthy spinner/check sequencing; VoiceOver `Updated` exactly once with stable focus; the check is not a focus stop; the accessibility frame follows the rendered content; hit-testing follows the rendered content during the authored offset (Row 6b, observed under Reduce Motion); Reduce Motion; Unavailable → healthy recovery. Optional Row 9 probes were skipped.

**Environmental label.** That evidence is manual/environmental verification on the H3 candidate source plus one temporary LAN endpoint substitution (made in a throwaway copy only, never in the H3 worktree), an H3-owned synthetic stub backend, and a Debug device build. It is not the byte-identical acceptance candidate and was not run through any test suite; the results above remain attached to the untouched candidate. The stub log records only network requests: it corroborated which build was on the device and when refreshes occurred, not what was rendered, and showed no card-detail fetch inside an offset window for Row 6b, whose evidence is the project owner's observation. Physical scroll performance was observed on a Debug build and is not a Release-performance result.

**Known, accepted limitations.** Residual A (the successful-recovery fallback cannot independently observe a visually open lane), N1, N2, N3, and the stale Figma timing reference are recorded with their revisit conditions in the W4-H3 weekly-spec card; the VoiceOver three-finger refresh gesture was observed to be hard to perform, and H3 does not change refresh activation. H3 acceptance does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (`docs/system-contract.md` section 11).

### W5-IOS1 iPhone Release configuration and Screenshot Assistance exclusion acceptance

The project owner accepted W5-IOS1 on 2026-10-23. The accepted runtime contract is system-contract section 26. Evidence was taken on the integrated tree (based on `main` `542c109`, uncommitted) on an iPhone 17 Pro Max simulator.

- **Backend.** `src/screenshotProposalExclusion.test.ts` sends direct HTTP requests through the real route registration (authenticated and unauthenticated, every `PUBLIC_ACTIONS_PAUSED` value, malformed/oversized/invalid compressed bodies, path-case variants, repeated attempts, and a direct handler call without the test injection) and asserts the refusal precedes the provider, rate limiter and body parsing with zero provider calls. `src/screenshotProposalRoute.test.ts` keeps the preserved route behavior under the injected test flag. `src/iosReleaseConfiguration.test.ts` is a source guard on plist key drift, no ATS in Release, iPhone-only settings and Release plist wiring (source configuration only). `npm run typecheck` passed. `npm test`: 3,677 passed, 1,052 skipped.
- **iOS.** New focused classes: `RequesterScreenshotAssistanceExclusionTests`, `RequestFoodScreenshotAssistanceExclusionHostedTests` and `ProductionAPIConfigurationTests`. Each negative case has an enabled positive control, and about 20 existing Screenshot/Edit/Request test files and `RequesterFormHostedHarness` now inject `.enabledForTesting()`. The complete `CommonPlateiosTests` target ran 2,825 tests with 2 failures, both pre-existing `RequesterFormHostedFidelityTests` hosted-layout cases (`testExtraExtraLargeTextKeepsPostRequestReachableAndTheInfoTargetFull`, `testFilledMealSummaryDetailsGrowsByTheSamePerLineHeightAsMealItemSoTheyShareTheSameTextSize`), unchanged and unresolved. A focused rerun of 434 tests (H1a evidence/fulfillment, manual Request Food creation, push, brand and the IOS1 suites) passed with 0 failures after the last fix.
- **Release.** Executed: Release simulator build; effective built Release `Info.plist` has no ATS, local-network or localhost keys; build settings show `TARGETED_DEVICE_FAMILY = 1` for both configurations; the Release app launched on the simulator shows "unavailable" with the URL unset and the GoodGrub onboarding with a valid placeholder HTTPS host. A local Release archive was development-signed with `aps-environment = development`, and its `app-store-connect` export had `production` with `get-task-allow` false, no ATS keys and the configured key. The test target does not build in Release (`@testable import`); this is a limitation, not a gate.
- **Review.** An independent HIGH-risk review of the integrated exclusion boundary and Release configuration found only the Release test-target reference to `localSimulator`, which was fixed and its suites rerun.
- **Not established.** Deployed production origin and APNs topic (W5-INF1). W5-RC1 owns the signed immutable candidate, physical device checks that no entry point exists, an authenticated production POST returning 503, H1a and manual Request Food against production, APNs and provider behavior, and signed entitlement re-inspection. The archive/export here used a placeholder host and is not a candidate.

### Verification routing manifests

These named groups route verification using **existing** tests only; they are not XCTest targets, test plans, or Vitest projects. A group is a list of test classes or files to pass to the commands below. Membership was checked against the committed test tree at `c3cb034`: every class and file named here exists there. Test classes added after that point (including classes in slices that have not landed) are not members until the slice that adds them updates this manifest. Membership is routing, not coverage certification: a class may belong to a group because it is the closest neighbor, and classes that belong to no group are run by explicit class/file name or by the complete target.

**iOS command template.** Reuse the command at the top of this section, replacing the single `-only-testing:CommonPlateiosTests` line with one repeated filter per class:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/CommonPlateios/CommonPlateios.xcodeproj \
  -scheme CommonPlateios \
  -destination 'platform=iOS Simulator,id=<AVAILABLE_SIMULATOR_UDID>' \
  -derivedDataPath "${TMPDIR:-/tmp}/CommonPlate-Tests-DerivedData" \
  -only-testing:CommonPlateiosTests/<ClassA> \
  -only-testing:CommonPlateiosTests/<ClassB>
```

Do not use `-skip-testing` for acceptance evidence. The `FullRegression` group is the section 9 command unchanged (`-only-testing:CommonPlateiosTests`).

| iOS group | Test classes |
| --- | --- |
| `HomeRefresh` | `HomeRefreshCallerCancellationTests`, `ManualRefreshCancellationTests`, `HomeExchangeRefreshDeadlineTests`, `HomeContinuousScrollCompositionTests`, `HomeExchangeBoardStateTests`, `HomeExchangeStatePresentationTests`, `HomeExchangeContinueHelpingDedupTests`, `HomeOwnershipPartitionRegressionTests`, `HomeRefreshOutcomeTests`, `HomeRefreshAcknowledgmentContextTests`, `HomeRefreshExperienceTests`, `HomeRefreshSettleSequencingTests`, `HomeRefreshSettleProductionStreamTests`, `HomeRefreshSettleHostedMotionTests`, `HomeRefreshHostedScrollTests`, `HomeRefreshNoLaneRecoveryTests`, `HomeRefreshNoLaneProductionStreamTests` |
| `HelperFulfillmentCore` | `ClaimFlowTests`, `PlacementReentryContinuationTests`, `ReservationContinuationTests`, `ReservationFulfillmentContinuationTests`, `ReservationReleaseTests`, `ReservationWarningTests`, `RequestDetailStaleParticipationTests`, `RequestNotYetAvailableRoutingTests` |
| `HelperSuccess` | `HelperCompletionLifecycleTests`, `HelperHeldRequestNavigationTests`, `HelperJourneyFulfillmentTests`, `HelperSuccessForegroundProgressionTests`, `HelperMessageSuppressionTests`, `HelperSuccessAnnouncementFocusTests`, `HelperSuccessVoiceOverTimingTests` |
| `RequesterCore` | `RequestCreationViewTests`, `RequestFoodEntryTests`, `RequestFoodDraftSessionTests`, `RequestFoodBranchAmountDraftTests`, `StructuredRequestDraftTests`, `RequestIncompleteVsInvalidValidationTests`, `RequestTimingContractTests`, `RequestEligibilityTests`, `RequestPostingLimitCopyTests`, `RequesterFormLayoutBehaviorTests`, `MealSwipeQuantityTests`, `RequesterOrderPerImageEvidenceWiringTests`, `RequestCreateDurableOperationTests`, `RequestCreateDurablePersistenceFailureTests`, `RequestCreatePendingOperationScopeTests`, `RequestCreateTerminalReconciliationTests`, `PendingRequestOperationUpgradeTests`, `RequestCreationInstallationCredentialTests`, `RequestCreationContinuityTests`, `RequestCreationContinuityLandingTests`, `RequestCreationContinuityFallbackCrossfadeTests`, `RequestCreationContinuityHomeRevealTests`, `HomeExactCreatedRequestAvailabilityTests`, `RequestTextModerationTests`, `ScreenshotVenueClassifierTests`, `ScreenshotVenueRecoveryTests`, `ScreenshotVenueAuthorityReconciliationTests` |
| `HostedRequesterUI` | `RequesterFormHostedFidelityTests`, `RequesterIncompleteVsInvalidHostedTests`, `RequesterMealPresentationHostedTests`, `RequestCreationContinuityHostedGeometryTests`, `RequestFoodMenuPathHostedTests`, `RequesterVenueRecoveryCalloutLayoutHostedTests` |
| `IdentityAndNavigation` | `ParticipantIdentityTests`, `ParticipantGateTests`, `ParticipantVerificationHierarchyTests`, `ParticipantContinuationTests`, `RemoveEmailTests`, `RemoveEmailInFlightCreateGatingTests`, `RemoveEmailStatusKindTests`, `ChangeEmailPresentationAndOverlayDismissalTests`, `OnboardingPresentationTests`, `OwnRequestsSeeAllDestinationTests`, `SettingsRequestAlertsToggleTests`, `HelperNotificationPayloadParsingTests`, `HelperNotificationRouterTests`, `HelperNotificationDestinationRoutingTests`, `HelperNotificationDestinationTruthTests`, `HelperNotificationTerminatedLaunchRoutingTests`, `RequesterFulfillmentNotificationPayloadParsingTests`, `RequesterFulfillmentNotificationRouterTests`, `TapAuthorityFenceTests`, `ReservationWarningNotificationPayloadParsingTests`, `ReservationWarningRouterTests`, `ReservationWarningRouteDriverTests`, `PushAppDelegateLifecycleTests` |
| `AccessibilitySensitive (overlay)` | `RequestCreationContinuityHomeRevealTests`, `RequestCreationContinuityLandingTests`, `RequestCreationContinuityFallbackCrossfadeTests`, `HelperSuccessForegroundProgressionTests`, `HomeExchangeStatePresentationTests`, `RequesterMealPresentationHostedTests`, `RequesterIncompleteVsInvalidHostedTests`, `ScreenshotHelpPresentationTests`, `RequestCreationViewTests`, `OnboardingPresentationTests`, `HelperJourneyFulfillmentTests`, `RequesterFormHostedFidelityTests`, `CommonPlateStatusTests`, `RequesterFormLayoutBehaviorTests`, `ScreenshotMenuPathApplicationTests`, `ScreenshotAssistanceDisclosurePresentationTests`, `RequestFoodMenuPathHostedTests`, `RequesterVenueRecoveryCalloutLayoutHostedTests`, `OwnRequestsSeeAllDestinationTests`, `HomeExchangeRefreshDeadlineTests`, `HomeContinuousScrollCompositionTests`, `CommonPlateFoundationPresentationTests`, `HomeRefreshAcknowledgmentContextTests`, `HomeRefreshExperienceTests`, `HomeRefreshHostedScrollTests`, `HomeRefreshNoLaneRecoveryTests`, `HomeRefreshSettleSequencingTests`, `HomeRefreshSettleHostedMotionTests`, `HelperSuccessAnnouncementFocusTests`, `HelperSuccessVoiceOverTimingTests` |
| `ParticipantBlocking` | `ParticipantBlockTests`, `ParticipantBlockEntryTests`, `ParticipantBlockManagementTests`, `ParticipantBlockReconstructionTests`, `ParticipantBlockPostYesAutonomyTests`, `ParticipantBlockPostYesStopHomeTests`, `ParticipantBlockYesNavigationTests`, `ParticipantBlockActivePillScrollTests` |
| `FullRegression` | Unfiltered `CommonPlateiosTests` (the section 9 command). |

`AccessibilitySensitive` is an overlay, not a complete accessibility certification: it lists classes that assert accessibility labels, hints, identifiers, Dynamic Type, or Reduce Motion behavior, and is run *in addition to* the primary group when a change touches layout, accessibility, or motion. It does not replace the project owner's physical-device accessibility observations. `HomeRefresh` includes W4-H3's refresh-experience classes (and the overlay its accessibility/Reduce Motion-asserting classes) as of H3 acceptance; the other classes in it are the committed Home/refresh classes. `HelperSuccess`, `RequesterCore`, and the `AccessibilitySensitive` overlay include W4-U1.1's added classes as of its integration; the overlay holds only the two that assert VoiceOver announcement and focus behavior (`HelperSuccessAnnouncementFocusTests`, `HelperSuccessVoiceOverTimingTests`).

**Backend command template.** Pass explicit file paths (a bare name would also match the `*.mongo.test.ts` siblings):

```bash
npm test -- src/<fileA>.test.ts src/<fileB>.test.ts
```

| Backend group | Vitest files |
| --- | --- |
| `RequestCore` | `src/createRequestRoute.test.ts`, `src/requestAvailability.test.ts`, `src/requestDetailRoute.test.ts`, `src/requestDetailOwnership.test.ts`, `src/requestEligibility.test.ts`, `src/requestEligibilityRoute.test.ts`, `src/requestDailyQuota.test.ts`, `src/requestTiming.test.ts`, `src/requestListResponse.test.ts`, `src/structuredRequest.test.ts`, `src/requestOperationTerminalRoute.test.ts`, `src/requestInstallationAssociation.test.ts`, `src/participantTextFilter.test.ts`, `src/requestTextFilteringRoute.test.ts` |
| `FulfillmentCore` | `src/claimRoute.test.ts`, `src/claimRouteParticipation.test.ts`, `src/claimToken.test.ts`, `src/fulfillmentRoute.test.ts`, `src/reservationRoute.test.ts`, `src/requestParticipation.test.ts`, `src/participantTextFilter.test.ts`, `src/fulfillmentMessageFilteringRoute.test.ts` |
| `SubscriptionAndAlerts` | `src/subscribeRoute.test.ts`, `src/confirmSubscription.test.ts`, `src/confirmSubscriptionRoute.test.ts`, `src/unsubscribeRoute.test.ts`, `src/unsubscribeSubscriber.test.ts`, `src/unsubscribeCredential.test.ts`, `src/notifySubscribers.test.ts`, `src/sendDigestEmail.test.ts`, `src/eligibilityNotificationSweep.test.ts`, `src/emailAlertState.test.ts`, `src/emailAlertStateRoute.test.ts`, `src/emailHelpers.test.ts`, `src/participantEmailUnsubscribe.test.ts`, `src/participantEmailUnsubscribeRoute.test.ts`, `src/publicActionsPause.test.ts`, `src/publicActionsRoutes.test.ts`, `src/helperNewRequestPush.test.ts`, `src/helperPushPayload.test.ts`, `src/installationPushRoute.test.ts`, `src/requesterFulfillmentPush.test.ts`, `src/requesterFulfillmentPushPayload.test.ts` |
| `ParticipantBlocking` | `src/participantBlockWiring.test.ts`, `src/claimRoute.test.ts`, `src/claimRouteParticipation.test.ts`, `src/requestAvailability.test.ts`, `src/requestDetailOwnership.test.ts`, `src/reservationRoute.test.ts` (its Mongo-gated suites `src/participantBlock.mongo.test.ts` and `src/participantBlockPostYes.mongo.test.ts` run only through `PersistenceMongo`). |
| `PersistenceMongo` | `npm run test:mongo` — the entire Mongo-gated suite; no selective form is defined (section 5). |
| `FullNonMongo` | `npm test` — the complete non-Mongo suite (Mongo-gated suites skipped by configuration). |

`src/participantTextFilter.test.ts` is a member of both `RequestCore` and `FulfillmentCore` because the one shared filter governs requester text and the helper Message. The `ParticipantBlocking` groups were added by W4-U1.3 acceptance and name classes that W4-U1.3 added (they are not in the tree at `c3cb034`); `claimRoute.test.ts`, `claimRouteParticipation.test.ts`, `reservationRoute.test.ts`, `requestAvailability.test.ts`, and `requestDetailOwnership.test.ts` also remain members of `FulfillmentCore` and `RequestCore` as before, and `HelperJourneyFulfillmentTests` remains in `HelperSuccess`. W4-R4.2 acceptance added `ScreenshotVenueClassifierTests`, `ScreenshotVenueRecoveryTests`, and `ScreenshotVenueAuthorityReconciliationTests` to `RequesterCore` and `RequesterVenueRecoveryCalloutLayoutHostedTests` to `HostedRequesterUI` and the `AccessibilitySensitive` overlay; its backend file `src/screenshotVenueClassifier.test.ts` is in no group and is run by explicit file path. Backend files in no group (for example the `screenshot*`, `apns*`, participant-verification, startup-validation, and `statsRoute` suites) are run by explicit file path or by `FullNonMongo`. `npm test` does not replace `PersistenceMongo`.

## 10. Test-file organization

Add new Week 3 iOS tests in new focused files where practical. Do not keep extending `ClaimFlowTests.swift` merely because it already contains related tests. Preserve existing test files rather than splitting them during unrelated feature work, and keep one endpoint and one user-flow slice per test change. This does not prescribe a new test framework or UI-test target.

## 11. Verification by change type

Applies to slices whose first READY transition is recorded after W4-VP1 landed on `main`; earlier slices use the grandfathered table at the end of this section. Tier numbers are those of [Verification tiers and post-fix invalidation](#verification-tiers-and-post-fix-invalidation); group names are those of [Verification routing manifests](#verification-routing-manifests). Every row also requires `git diff --check` and a content review of the diff. A full-regression trigger or an explicit slice contract always adds tier 4 to any row.

| Change class | Tier 1–2 (focused, affected-neighbor) | Tier 3 acceptance bundle on the candidate | Tier 4 full regression |
| --- | --- | --- | --- |
| Backend, localized (isolated route validation or copy that does not touch persistence, credentials or tokens, response projection/allowlists, lifecycle transitions, or ambiguous-mutation handling) | `npm run typecheck`; focused test file(s); the affected backend group(s). | Typecheck plus the affected backend group(s). | Not required unless a trigger applies. |
| Backend, shared boundary (`app.ts` startup/registration, shared auth/error/public-projection, cross-route contract, notification/delivery, dependency or runtime configuration) | `npm run typecheck`; focused tests; affected groups. | Typecheck and `FullNonMongo`. | `FullNonMongo` (this is the bundle); add `PersistenceMongo` when persistence is involved. |
| Mongo schema, index, migration, transaction, uniqueness, lifecycle transition, concurrency | `npm run typecheck`; focused tests; affected groups. | Typecheck, `FullNonMongo`, and `PersistenceMongo` (`npm run test:mongo`, the entire suite). | Both complete runs (this is the bundle). |
| Browser client source | Focused browser tests; `npm run typecheck`. | `npm run build:client` with the regenerated bundle diff inspected and the generated-file banner preserved; `FullNonMongo` when user-facing copy changed, because the production-source copy guard in section 4 scans bundles. | Not required unless a trigger applies. |
| iOS, localized (SwiftUI layout, accessibility, copy, leaf presentation state, test-only correction confined to one test class/file) | Focused classes for the change; the primary iOS group(s) for the affected area, plus `AccessibilitySensitive` when layout, accessibility, or motion changed, plus `HostedRequesterUI` whenever the change touches Requester UI, the request form, meal presentation, or request-creation continuity; compile. | The same classes and groups on the acceptance candidate, run to `TEST SUCCEEDED`. | Not required unless a trigger or explicit contract applies. |
| iOS, shared boundary (app root/global navigation/routing, app lifecycle/notification handoff, `APIClient → RequestService → RequestStore`, identity, persistence, cache semantics, shared models, project/scheme/dependency/build configuration) | Focused classes; `IdentityAndNavigation` and the affected primary group(s); compile. | Complete `CommonPlateiosTests` (`FullRegression`). | `FullRegression` (this is the bundle). |
| iOS, explicitly contracted slice, cross-slice integration, or release checkpoint | Focused classes; affected groups. | Complete `CommonPlateiosTests` on the final candidate. | `FullRegression` (this is the bundle). |
| Cross-stack contract | Focused tests on each side. | `FullNonMongo` (plus `PersistenceMongo` when applicable) and complete `CommonPlateiosTests`. | Both sides complete. |
| Local QA tooling (`scripts/qa-*.ts`, `scripts/seed-ui-request.ts`, mail sink) | Typecheck; the focused QA unit and Mongo tests listed under the Local QA harness subsection of section 5. | `FullNonMongo` and `PersistenceMongo`; iOS suites only if the Debug override changes (then complete `CommonPlateiosTests`, because it is a build-configuration change). | As the bundle states. |
| Comment/document-only | `git diff --check`; content review; validation that every published command and name exists. | Not applicable; run tests only when executable behavior is also pending in the same working tree. | Not applicable. |

Any user-facing copy change on any surface (backend, browser, or iOS production source) also runs `src/createRequestRoute.test.ts`, which holds the production-source copy guard. A change to `shared/*.json`, `ios/CommonPlateios/CommonPlateios/Resources/SupportedVendors.json`, or any iOS source file that a backend test opens by explicit path (currently `RequestFoodView.swift`, read by `src/createRequestRoute.test.ts`) is a cross-stack contract change.

A change that fits more than one row takes the union of the rows' requirements. A change that does not clearly fit a "localized" row is treated as a shared-boundary change.

**Grandfathered rule (slices whose first READY transition predates W4-VP1).** These were the section 11 requirements before W4-VP1 and remain binding for those slices, in addition to anything their weekly-spec card states:

| Change | Minimum verification |
| --- | --- |
| Backend TypeScript only | Typecheck, focused tests, and `npm test`. |
| Mongo mutation/transaction | The backend checks above plus `npm run test:mongo`. |
| Browser source | Focused browser tests, typecheck, and `npm run build:client`. |
| iOS production or test change | Focused tests plus the complete `CommonPlateiosTests` target. |
| Cross-stack contract | All affected backend and iOS suites. |
| Local QA tooling (`scripts/qa-*.ts`, `scripts/seed-ui-request.ts`, mail sink) | Typecheck, the focused QA unit and Mongo tests listed under the Local QA harness subsection of section 5, `npm test`, `npm run test:mongo`; iOS suites only if the Debug override changes. |
| Comment/document-only | `git diff --check` and content review; run tests only when executable behavior is also pending in the same working tree. |

`npm run ci-check` runs lint, typecheck, prune, and build. It does not run the test suites.

## 12. Final diff checks

Run:

```bash
git diff --check
git diff --cached --check
git status
```

Before committing, inspect generated files, new tracked documentation, and deleted files; each must be intentional. Confirm that local weekly specifications and archived working documents under `docs/` remain ignored and unstaged.

## 13. Current verification baseline

These results are reference evidence, not a substitute for rerunning affected checks after future changes. Where an exact later total is recorded, it is retained; otherwise the row records the accepted H1 pass without inventing a new count.

| Check | Result |
| --- | --- |
| `npm run typecheck` | Passed at W4-Q1 acceptance; passed on the W4-U1.1 final integrated candidate; passed on the W4-U1.3 final behavioral candidate; passed on the W4-H1a accepted candidate |
| `npm test` | Passed at W4-Q1 acceptance: 1,537 passed, 335 Mongo-gated skipped. On the W4-U1.1 final integrated candidate: 2,873 passed, 409 Mongo-gated skipped, 0 failed. On the W4-U1.3 final behavioral candidate: 3,040 passed, 0 failed, Mongo-gated suites skipped by configuration there. On the W4-H1a accepted candidate (based on `main` at `b37972f`, so not additive to the figures above): 2,958 passed, 519 skipped by Mongo configuration, 0 failed. On the W4-R4.2 accepted candidate (current accepted baseline, based on `main` at `38edd30`, so not additive to the figures above): 2,979 passed, 519 skipped by Mongo configuration, 0 failed |
| `npm run test:mongo` | Passed at W4-Q1 acceptance: 335 passed across 24 files. On the W4-U1.1 final integrated candidate: 409 passed across 29 files. On the W4-U1.3 final behavioral candidate: 504 of 504 passed across 31 files. On the W4-H1a accepted candidate (not additive): 519 passed across 31 files, 0 failed. Not run for W4-R4.2 (no persistence, transaction, uniqueness, or index change; the H1a figure remains the latest Mongo run) |
| `npm run ci-check` | Passed (lint, typecheck, prune, build), at the W4-H2 final ownership rereview — not independently rerun for Q1; see the Q1 coverage subsection above for the checks that were |
| `CommonPlateiosTests` | At W4-R2 acceptance: **1,104 passed, 0 failed**. At W4-H4 acceptance, measured in isolated worktrees: **1,009 passed, 0 failed, TEST SUCCEEDED** for the clean W4-Q1 commit plus exactly the W4-H4 commit set — the figure the target reported once H4 landed. The same clean Q1 commit alone measures 976, and the full H4 working tree including then-in-progress R2/S1 work measured 1,032. See the W4-H4 subsection in section 9 for the attribution table and for the flagged 1,001-versus-976 discrepancy in the Q1 record. At W4-D2 acceptance: **1,381 passed, 0 failed, 0 skipped**. At W4-R4 acceptance: **1,483 passed, 0 failed, TEST SUCCEEDED**; a final focused provenance/badge-unification pass separately measured 225 tests, 0 failures. At W4-S3 acceptance, as re-accepted after OBS1/Datadog removal: **1,713 passed, 0 failed, 0 skipped**. At W4-S3 consent-authority revision re-acceptance (current accepted baseline): **1,744 total, 1,742 passed, 0 failed, 2 expected configuration skips** (S2.1 development-evaluation tests gated by configuration), TEST SUCCEEDED. At W4-H3 acceptance (grandfathered complete-target gate, measured on the H3 candidate whose base predates W4-QA1/W4-VP1; not additive to the S3 figure above): **1,993 executed, 0 failed, 0 skipped**. At the W4-U1.1 final integrated candidate (grandfathered complete-target gate, measured on the U1.1 changes integrated onto main at `82274ff`, so it includes W4-QA1, W4-VP1, and W4-H3; not additive to the figures above): **2,085 executed, 0 failed, 0 skipped**, TEST SUCCEEDED. At the W4-U1.3 final presentation candidate (grandfathered complete-target gate, measured on the accepted U1.3 candidate based on `main` at `eeed898`; not additive to the figures above): **2,190 executed, 0 failed, 2 skipped by configuration**, TEST SUCCEEDED; the focused final pill/scroll affected suites separately measured 132 tests, 0 failures. Earlier U1.3 complete-target counts are superseded. At the W4-H1a accepted candidate (grandfathered complete-target gate, measured on the H1a candidate based on `main` at `b37972f`; not additive to the figures above): **2,228 executed, 0 failed, 0 skipped**, TEST SUCCEEDED; the final focused `PlacedOrderEvidenceFlowTests` run measured 27 tests, 0 failures. At the W4-R4.2 accepted candidate (complete-target gate on the final candidate, measured on the R4.2 candidate based on `main` at `38edd30`; current accepted baseline, not additive to the figures above): **2,293 executed, 0 failed, 0 skipped**, TEST SUCCEEDED; the focused callout-layout and disclosure run measured 27 tests, 0 failures. |
| Release generic iOS Simulator build | Succeeded at W4-S3 acceptance and again at the consent-authority revision re-acceptance; succeeded on the W4-H3 acceptance candidate; succeeded on the W4-R4.2 final candidate |
| Release unsigned generic iOS device build | Succeeded at W4-S3 acceptance and again at the consent-authority revision re-acceptance (unsigned; not a signed/Archive/TestFlight result); succeeded on the W4-R4.2 final candidate (unsigned; a signed Debug device build also succeeded and was installed for the physical pass) |
| `npm run build:client` | Passed; no tracked bundle diff (no browser-client source changed in N2, D1, H2, N0, or Q1) |
| `git diff --check` | Passed |

Physical-device proof (helper terminated-launch tap routing; requester-fulfillment push to Home with the one-time notice) has passed on a physical iPhone and is recorded as accepted runtime truth in `docs/system-contract.md` sections 8.2–8.3. It is device evidence, not part of the automated suite above, and it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-C1 physical acceptance (meal-swipe quantity visible in Active Requests, Request Detail, active-reservation presentation, fulfillment/order context, and helper new-request notification/email) is recorded above and in `docs/system-contract.md` section 6.2. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-D1 automated/independent-review evidence (exact-operation idempotency and reconciliation, the bounded-recovery operation tombstone, and durable iOS unresolved-operation persistence and reconciliation) is recorded above and in `docs/system-contract.md` section 6.3. **W3-D1 was accepted without the integrated physical-iPhone runtime scenarios described above.** That remaining physical-runtime proof is an accepted verification limitation, not evidence that the behavior was physically proven; it does not establish Release/Archive/TestFlight signing or environment behavior either, which remains open (section 11 of the same document).

W3-H1 physical-device acceptance is recorded above. It closes H1's reservation-lifecycle device gate only; it does not close the Release/Archive/TestFlight APNs environment gate.

W3-N3 physical-device/environmental acceptance (real future Later request: no early email/APNs initiation, then eligibility-time email + APNs initiation, observed inbox arrival and physical notification presentation) is recorded above and in `docs/system-contract.md` section 8.5. It closes N3's environmental acceptance gate; the physical request's `createdAt` was not old enough to reproduce the former long-lookback omission on its own, which real-Mongo integration coverage establishes separately. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-N2 physical-device acceptance (push enable/disable reaching authoritative On/Off, relaunch-preserved push-management truth, ambiguous push recovery/retry, participant-authorized in-app email unsubscribe, later signup returning to Check Your Email rather than stale Off, and email/push channel independence) is recorded above and in `docs/system-contract.md` sections 8.6 and 9.8–9.9. It closes N2's device-acceptance gate; it does not establish verified email delivery/reading, a production APNs environment, TestFlight signing/configuration, or production backend reachability, which remain open (section 11 of the same document). Sandboxed local-loopback bind failures (EPERM/timeouts) observed during N2 backend verification are recorded as a verification-environment limitation, not a product defect (section 4 notes above).

The non-Eastern `DatePicker` timezone proof required for W3-R1 (see section 9) is likewise device evidence, not part of the automated suite above.

W3-I4 acceptance evidence and its accepted CoreSimulator verification limitation are recorded above (Remove Verified Identity (W3-I4) coverage) and in `docs/system-contract.md` section 3.1.

W4-H2 acceptance evidence (participant-scoped request-list ownership projection, the authoritative backend self-claim guard, iOS ownership presentation/action-gating, and the functional Home/navigation/refresh contract) is recorded above (Home & Navigation Architecture (W4-H2) coverage) and in `docs/system-contract.md` section 1.3. The project owner accepted H2's functional pull-to-refresh behavior; the repository/session contains no explicit record of a physical-iPhone reproduction-or-rule-out walkthrough for the Simulator-only native-`.refreshable`-activation defect noted in the current weekly spec's W4-H2 section, and this documentation does not claim that verification occurred. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document). The current authored refresh visual/motion presentation is explicitly not part of H2's acceptance evidence; it was deferred to W4-H3 and was not accepted as final by H2; W4-H3 has since been accepted (see its subsection in section 9).

W4-N0 acceptance evidence (authorization/privacy/cache-isolation for the participant-authorized Email Request Alert state read, current-participant stale-authority fencing, and Subscriber-lifecycle-to-state mapping) is recorded above (Email Request Alert State Authority (W4-N0) coverage) and in `docs/system-contract.md` section 9.10. No physical-device or environmental proof was required; it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-Q1 acceptance evidence (the participant-authorized request-creation eligibility read sharing its substantive quota authority with `POST /api/request`, authorization/privacy/cache-isolation including a mounted rate-limited response, the current-as-of-read-to-POST-refusal boundary, and iOS fail-closed/stale-response/authority-retirement behavior) is recorded above (Request Creation Eligibility Authority (W4-Q1) coverage) and in `docs/system-contract.md` section 7.1. No physical-device or environmental proof was required; it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-H4 acceptance evidence (the count-sensitive Home ownership preview and `See all N`, the ownership partition, one unified Home scroll with a single native `.refreshable`, the persistent `Request a Meal` structural bottom accommodation and shared 24-point content column, and pull-to-refresh actually applying authoritative data) is recorded above (W4-H4 Home continuous scroll composition acceptance) and in `docs/system-contract.md` section 1.4. The project owner's physical-device pass is the authority for the rendered composition, gesture, Dynamic Type, and VoiceOver observations; no automated check drives them. H4 accepts refresh correctness only — the authored refresh presentation was deferred to W4-H3 and was not accepted as final by H4; W4-H3 has since been accepted (see its subsection in section 9). It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-H3 acceptance evidence (the truthful-success acknowledgment, the Decision 12 Standard and Reduce Motion settle, context-bound suppression and stale retirement, and the successful-recovery fallback) is recorded above (W4-H3 Home refresh experience acceptance) and in `docs/system-contract.md` section 1.5. The complete grandfathered `CommonPlateiosTests` gate was 1,993 executed, 0 failed, 0 skipped on the H3 candidate, with a Release generic iOS Simulator build; physical-iPhone Rows 1–8 passed as manual/environmental verification on that source plus one temporary LAN endpoint substitution, a synthetic H3-owned stub backend, and a Debug build, which is not the byte-identical acceptance candidate. Automation does not establish physical VoiceOver, focus, accessibility-frame, hit-testing, or pull-feel behavior. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-R2 acceptance evidence (the pushed Request Food navigation, the Q1-consuming early eligibility boundary and its distinct retryable/exhausted presentations, in-memory draft-session continuity, Timing's quick-time/native-picker presentation, the Screenshot Assistance completion acknowledgement, the first-use consent/disclosure gate and its Off-state re-entry path, Screenshot Help's centered-overlay presentation, Posting/Success timing and haptics, D1's continued haptic-free distinctness from definitive failure, no R2-authored Home insertion, and the zone-scoped `YOUR REQUEST` eyebrow suppression) is recorded above (W4-R2 Requester Journey Integration acceptance) and in `docs/system-contract.md` section 13, section 1.4, and section 3.1. The project owner's physical-device walkthroughs are the authority for the rendered navigation, consent/Off-state, Screenshot Help, motion/haptic, and Remove Email presentation observations; no automated check drives them. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document). The new-request push notification's title/body composition remains W4-N1's future work, not R2's, per the carve-out recorded in the W3-C1 coverage subsection above.

W3-H2 durable one-successful-participation enforcement, marketplace/detail privacy isolation, and fulfillment re-entry evidence is recorded above and in `docs/system-contract.md` section 5.1. **W3-H2 was accepted without an iOS UI-test target**, so the literal SwiftUI stale-detail render/tap scheduling sequence was not driven end-to-end through UI automation or physical-device interaction; production predicate/action logic and wiring are covered by unit/source-level tests and the full iOS target instead. That remaining limitation is accepted, not a failed or pending check, and must not be described as UI-test or physical-device proof; it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-D2 acceptance evidence (exact-operation terminal reconciliation extending W3-D1, the terminal NO-CREATE Path A/Path B recovery presentation, the Success→Home continuity card handoff including the no-usable-target coordinated-crossfade fallback, and the exact-created-request Home continuity exception during broader board loading/unavailability) is recorded above (W4-D2 Exact Request-Create Terminal Reconciliation acceptance) and in `docs/system-contract.md` section 6.4. The project owner's physical-device walkthrough is the authority for the rendered Success→Home continuity, fallback crossfade, and exact-created-request visibility observations; the hosted `RequestCreationContinuityHostedGeometryTests` proof is the authority for rendered end-state geometry absent a UI-test target. D2's physical recovery-state scenarios (stable unresolved, Path A, Path B, write-uncertain) remain an accepted, unperformed verification limitation, consistent with W3-D1's equivalent limitation above. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document). D2 is ACCEPTED but not yet COMMITTED.

W4-R4 acceptance evidence (structured Meal Exchange/Dining Dollars representation, multi-screenshot Assistance proposal validation, per-field manual authority/provenance, incomplete-vs-invalid presentation, requester hosted-geometry fidelity, and the unified Meal-row provenance badge correction) is recorded above (W4-R4 Structured Meal Requests & Multi-Screenshot Evidence acceptance) and in the current weekly spec's W4-R4 card. **The project owner explicitly accepted W4-R4 on 2026-09-29.** Its complete `CommonPlateiosTests` result (1,483 passed, 0 failed, TEST SUCCEEDED) was the accepted baseline at R4 acceptance, superseding the W4-D2 acceptance figure (1,381 passed, 0 failed, 0 skipped), and has since been superseded by the W4-S3 figures, the latest being the consent-authority revision figure (1,744 total, 1,742 passed, 0 failed, 2 expected configuration skips), the current accepted baseline recorded in the table above. Hardware-keyboard Tab traversal into the mounted hidden Meal editor remains deferred to W4-A1 and is not an R4 acceptance blocker. This evidence does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document). R4 is COMMITTED (`7fedbfe`).

W4-U1.1 acceptance evidence (authoritative requester-text refusal, helper Message suppression with durable content-free suppression truth, same-flow suppression recovery, and the completion-aware VoiceOver success gate) is recorded above (Cross-Participant Text Filtering (W4-U1.1) acceptance) and in `docs/system-contract.md` sections 5.2 and 6. Complete `CommonPlateiosTests` was 1,944 executed, 0 failed, 0 skipped on the pre-integration acceptance candidate and 2,085 executed, 0 failed, 0 skipped on the final integrated candidate, with backend typecheck, `npm test`, and `npm run test:mongo` passing on the integrated candidate (uncommitted); physical-iPhone VoiceOver and readability rows are manual device observation. The intermittent duplicate-beginning VoiceOver announcement is an accepted TestFlight limitation deferred to W4-A1. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-U1.3 acceptance evidence (contextual-only participant Block with separately owned directional records and a server-authoritative pair fence across board, Request Detail, and claim; the helper `No`/`Yes` flow with the atomic post-Yes authority, the C1 refusal of a late `Yes`, Add 5 minutes and Stop helping after `Yes`, and the C3 Stop → Home destination; placed-order continuity with withheld direct contact; and the Blocked Students management and presentation) is recorded above (Participant Blocking & Interaction Fencing (W4-U1.3) acceptance) and in `docs/system-contract.md` section 5.3. Complete `CommonPlateiosTests` was 2,190 executed, 0 failed, 2 skipped by configuration on the final presentation candidate, with backend typecheck, `npm test` (3,040 passed), and `npm run test:mongo` (504 of 504) passing on the final behavioral candidate. Simulator and physical-iPhone rows are manual observation, and the project owner's final visual approval of the `BLOCK ACTIVE` pill, supporting copy, and auto-scroll is manual. The requester-side timing/state inference and the deleted-request `404` are accepted limitations, not unverified behavior. It does not establish APNs/provider behavior or Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-H1a acceptance evidence (the required placed-order screenshot for every new fulfillment, its private `PlacementEvidence` persistence committed atomically with the placement and ledger row, the route-owned bounded transport and content-free refusal, on-device normalization, Finish helping gating, ambiguity and relaunch handling, and the removal of the Request Detail verification note, with the retired Got It wording reconciled in the system contract) is recorded above (Placed-Order Evidence & Manual Fulfillment (W4-H1a) acceptance) and in `docs/system-contract.md` section 5.4. Complete `CommonPlateiosTests` was 2,228 executed, 0 failed, 0 skipped on the final F-P1 candidate, with backend typecheck, `npm test` (2,958 passed, 519 skipped by Mongo configuration), and `npm run test:mongo` (519 passed across 31 files) passing. Physical-iPhone rows are manual observation. P5 (definitive refused-screenshot presentation) and P17 (ambiguous fulfillment) were not physically observed and the HEIC source container was not independently proven; these are accepted limitations, not passes. The Open Grubhub handoff failure (P15) is a parent-H1 integration issue and this entry does not establish a working handoff. It does not establish provider email delivery, APNs behavior, or Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-R4.2 acceptance evidence (the deterministic on-device venue disposition, the single application gate, the B/C pre-transfer stop at the external-fallback decision, the A–D recovery callout in its Figma-aligned stacked form, and the build-derived qualification fingerprint change) is recorded above (Requester Venue Anchoring & Recovery (W4-R4.2) acceptance) and in `docs/system-contract.md` section 14.9. Complete `CommonPlateiosTests` was 2,293 executed, 0 failed, 0 skipped on the final candidate, with backend typecheck and `npm test` (2,979 passed, 519 skipped by Mongo configuration) passing; `npm run test:mongo` was not applicable. Physical-iPhone rows are manual observation against a controlled QA stack with synthetic evidence. State A's final post-Figma visual, full physical VoiceOver coverage, the physical menu-path-conflict-after-recovery interaction, and the physical Off-while-pending retirement check are accepted, unperformed limitations; real unsupported-venue accuracy is unmeasured, and the post-R4.2 selection-level evaluation required before the Week 4 pilot gate is not satisfied by this acceptance. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-I1 physical/environmental verification remains unperformed for real NYU verification-email receipt and real-code redemption; uninstall/reinstall and new-device reverification; remaining Keychain lifecycle behavior; backup/device-migration exclusion where practical; and a real-address Change Email flow. The accepted W3-H1 flow has physically established same-install authority retention through terminate/relaunch continuation; neither that result nor source/simulator inspection proves the remaining outcomes.

W4-R5 (accepted 2026-10-19) records no new `npm test` or `npm run test:mongo` count. The last complete `CommonPlateiosTests` result recorded for it was 2444 executed, 0 failures, 2 configuration skips, taken at the D-R5-2 implementation and before the later Edit-parity changes; it is not a current count for the accepted tree. Later affected-class runs passed except the two unresolved `RequesterFormHostedFidelityTests` failures named in the W4-R5 acceptance section, which are assigned outside R5.

W4-U1.2 CP5 (accepted by the project owner 2026-10-23 for local integration, with exceptions) was reconciled onto main `4812697` and committed. Evidence on the reconciled tree: `npm run typecheck` clean; `npm test` 3,664 passed, 1,052 skipped, 0 failed; `src/moderatorAuth.mongo.test.ts` alone 28 of 28 (supplemental); the iOS sources are identical to the candidate whose last recorded full `CommonPlateiosTests` run was 2,806 executed, 2 skipped, 0 failures; `git diff --check` clean. An earlier independent review of the integrated candidate found no MUST FIX. **Accepted exceptions, not passes:** (1) the official parallel `npm run test:mongo` did not pass: five CP5 suites call `dropDatabase()` on the runner's one shared database while vitest runs files in parallel, and the Atlas-probe interrupt test exceeds its 15-second cleanup window under load; `VITEST_MAX_WORKERS=1 npm run test:mongo` passed 1,040 with 11 skipped and 0 failed and is supplemental only. The testing owner must resolve both before production release qualification. (2) The 410 correction, the two post-walkthrough UI fixes and the final `RequestStore` changes were not independently reviewed. (3) `HomeRefreshHostedScrollTests` is load-flaky and fails identically at the earlier candidate HEAD; no single fully green final full iOS run was recorded. (4) Physical-device proof covered report, moderator dashboard, Remove request, Remove and Suspend, the removal notice, change email after removal and account switching; the final UI fixes, VoiceOver, large Dynamic Type, lost-response recovery and the remaining moderator outcomes were not performed.

W5-ICO1 acceptance evidence (the approved GoodGrub app icon populating the previously empty `AppIcon.appiconset` universal slot, and `CFBundleDisplayName = GoodGrub` in both `Info.plist` and `Release-Info.plist`) is recorded in `docs/system-contract.md` section 27. The change is four files (one new PNG, three one/two-line text edits); no backend or iOS test suite was added or rerun, since nothing in `src/` or `CommonPlateiosTests` changed. Evidence instead: the exported PNG measured 1024×1024, 8-bit RGB, no alpha channel, pixel-sampled against the approved Figma source (`#A24F38` background, `#FBF9F6` artwork, exact match); `Contents.json` validated as well-formed JSON; both plists validated with `plutil -lint`; an unsigned Debug and an unsigned Release `xcodebuild build` for `generic/platform=iOS Simulator` both succeeded, with the Release build additionally passing Xcode's `-validate-for-store` check; both built `Info.plist` outputs resolved `CFBundleDisplayName` to `GoodGrub` and both compiled `Assets.car` outputs contained `AppIcon-1024.png`; `git diff --check` clean; an independent review returned PASS with no correctness findings. **Not established, and not to be described as such:** these are unsigned simulator builds, not a signed device or distribution build. The literal installed Home Screen icon tile was not visually captured (SpringBoard placed the app on simulator Home Screen page 2, confirmed by reading `IconState.plist`, but reaching that page for a screenshot needed touch/swipe navigation that was not performed). Physical-device rendering, a signed/Archive/TestFlight build, and App Store Connect icon/listing proof remain open (W5-RC1, W5-ASC1).

W4-N1 Increment A (accepted by the project owner 2026-10-23) was committed on `w4-n1-increment-a` and merged with main `4a1603a` (W5-IOS1, MSG1 CP6); the merge made W5-IOS1's injected `RequesterScreenshotAssistanceAvailability` the single V1.0 gate and hosts geometry tests that measure the shipping layout with `.shipping`. Evidence on the merged tree: `npm run typecheck` clean; `npm test` 3,712 passed, 1,143 skipped, 0 failed; the official serialized `npm run test:mongo` 1,132 passed, 11 skipped, 0 failed on rerun (the first run had two timing failures in `src/messagingHistory.mongo.test.ts` concurrency tests, which passed 55 of 55 twice alone and in the rerun); the complete `CommonPlateiosTests` run executed 2,946 with 2 skipped and failures in three tests: two hosted-geometry tests fixed by hosting `.shipping`, and `MessagingCoordinatorReconciliationTests.testLongHistoryIsNeverTruncatedByAPageCap`, a timing-sensitive MSG1 test; a focused rerun of those classes and the Screenshot Assistance neighbors executed 216 with 0 failures; `git diff --check` clean; an independent review of the shared Installation seam and merge resolution found no issues. Pre-merge candidate evidence: focused real-Mongo (contact, helper new-request, eligibility sweep, requester fulfillment, serialized) 83 of 83, and physical-device helper new-request (ASAP, Later, mixed, Dining-Dollars-only), tap (open, withdrawn, backend unavailable), requester-fulfillment, Change Email and Sign out walkthroughs. **Not established:** cold-launch tap proof (W5-IOS1/INF1) and signed Release/TestFlight push (W5-RC1).

### W4-MSG1 CP6 bounded moderation integration — accepted candidate (2026-10-27)

The project owner accepted the bounded Report-evidence and removal-closure implementation
on source commit `9036ea5`. On that candidate: `npm run typecheck` passed;
serialized `npm test -- --no-file-parallelism` passed **3,978**, with **1,370
skipped** and **0 failed**; clean serialized `npm run test:mongo` passed
**1,359**, with **11 configuration-gated skips** and **0 failed**. The changed
`messagingCp6Integration.mongo.test.ts` passed **39/39** and
`moderatorAuth.mongo.test.ts` passed **30/30**. The corrected
`moderationFoundationDormant.test.ts` guard passed **11/11**. Focused
`RequestConversationRoutingTests` passed **8/8** on an iPhone 17 Pro Max
simulator (iOS 26.5); this is simulator evidence, not physical-device proof.
The independent HIGH-risk review found no significant findings. `git
diff --check` passed.

The candidate was subsequently synchronized with committed local main
`e31555b` in history-merge commit `1198041`; that merge introduced no changes to the
CP6 implementation files. The verification totals above are from the CP6
candidate before that history merge, not a post-merge full-suite result.
Documentation synchronization is recorded in follow-up commit `5737b62`.
Post-merge heavy suites were not rerun: machine preflight showed swap within
1 GiB of capacity and high load. A physical-iPhone walkthrough was not run;
the connected iPhone was reported unavailable. **Not established:** full
`CommonPlateiosTests` on this candidate, physical keyboard/VoiceOver behavior,
deployment, or production messaging activation.
Full CP6 remains **BLOCKED / NOT READY** pending device proof and the separate
INF1/REV1 gates.

Local-main integration completed on 2026-10-26 in merge `cccf365`, with
parents `eb0eb1a` and accepted candidate `6799e55`. All twelve accepted
implementation/test paths are byte-identical to the candidate; CP4's
unaccepted UI changes and the pending MSG1 history-test lint correction are
excluded. Post-integration `npm run typecheck` passed, and focused
`models/moderation.test.ts`, `src/moderationFoundationDormant.test.ts` and
`src/reportAuthorization.test.ts` passed **51/51**, with no skips.
The merge diff and worktree passed whitespace checks. Earlier complete
backend/Mongo and simulator evidence above is retained, not claimed as a
new combined-main run. Heavy suites were not rerun because preflight showed
only 805.94 MiB swap headroom, below section 14's threshold. Physical-iPhone
proof remains NOT RUN.

## 14. Local QA environments and machine resources

Dev/test-only procedures. They add no verification requirement and change no
accepted command above; they cover the machine those commands run on.

`scripts/qa-processes.sh` implements all of it and touches no database
contents.

### 14.1 Preflight before expensive verification

```bash
scripts/qa-processes.sh preflight
```

Reports free disk, swap, load, free pages, compressor pages, and a
three-second page-in rate. Run it before a full backend, Mongo or iOS suite.

On a 16 GB Mac, under ~10 GB free disk, or swap within ~1 GB of its total, or a
page-in rate in the tens of MB/s, means heavy verification will report
environmental timeouts rather than evidence. Reclaim first; do not reinterpret
the results.

### 14.2 Listing QA processes and establishing ownership

```bash
scripts/qa-processes.sh list
```

Groups mail sinks, `qa-environment` helpers, `app.ts` under `tsx`, and loopback
`mongod` instances by process group, and lists loopback listeners. An
environment the current session did not start belongs to another lane or to an
earlier checkpoint: establish its owner before touching it.

### 14.3 Running and tearing down an owned environment

A QA environment is a process *group*, not a PID: a supervisor, its shell, a
`tsx` process and that process's `esbuild` service. Signalling only the leader
orphans the rest onto `launchd`.

Start a temporary environment through the supervised path, which makes that
teardown automatic:

```bash
scripts/qa-processes.sh run mail-sink --port 3032 \
  --purpose "CP2 walkthrough" -- npm run qa:mail-sink
```

`run` starts the command in a process group of its own, registers it (owner,
purpose, pgid, ports, data directory, teardown command) under
`~/.commonplate-qa/registry`, and tears the whole group down when the command
finishes, fails, or is interrupted with `SIGINT`, `SIGTERM` or `SIGHUP`. The
child's exit status is passed through, so it composes with any other check.
Registrations are runtime state and are deliberately outside the repository.

An environment whose owning command has finished but whose processes are still
running can be reclaimed later:

```bash
scripts/qa-processes.sh sweep
```

`sweep` only touches a registered environment whose owner process is gone,
which is not retained, and whose group still matches the identity recorded for
it — the leader's command and start time. A group that no longer matches is
left alone and reported, because a reused pid is a different process. Age is
never a reason to terminate anything.

To tear down a group by hand:

```bash
scripts/qa-processes.sh stop <pgid>
```

It prints the group's full membership, requires confirmation, sends `SIGTERM`,
waits up to ten seconds, escalates to `SIGKILL` only if needed, and fails
loudly if anything survives. It refuses pgid 0, pgid 1 and its own group. Read
the membership before confirming: everything listed is signalled.

Never use `killall node`, `pkill mongod`, or any pattern kill. Other lanes
share this machine, and a pattern kill has already taken down another session's
backend once.

Stop application layers before the `mongod` they talk to, so the app does not
spend its last seconds retrying a connection.

### 14.4 Explicitly retained persistent environments

Keeping an environment past its checkpoint needs the project owner's explicit
authorization. Record, where the next agent will look: owner, purpose, ports,
process-group identity, data directory, and the exact teardown command. An
unrecorded long-lived environment is indistinguishable from a leak and will be
treated as one.

`--retain` does that recording and keeps the environment running:

```bash
scripts/qa-processes.sh run cp2-api --retain --port 54326 \
  --data "${TMPDIR:-/tmp}/cp2-qa" --purpose "authorised device QA" -- npm start
```

It returns as soon as the environment is registered, prints the teardown
command, and sends the environment's output to a log (`--log`, otherwise
`~/.commonplate-qa/registry/<name>.log`) rather than the caller's stdout, which
a retained process would otherwise hold open. `list` then shows it as
`retained`, and `sweep` skips it until it is stopped deliberately with
`stop <pgid>` or swept with `sweep --force`.

### 14.5 XCTest device clones

`xcodebuild test` with parallel testing clones simulators into
`~/Library/Developer/XCTestDevices` and normally removes them, but leaves them
behind when a run is interrupted.

```bash
scripts/qa-processes.sh clones            # count shutdown clones
scripts/qa-processes.sh clones --delete   # remove them
```

Only shutdown clones are offered: a booted one may belong to a test still
running. A finished run's results live in its `.xcresult` bundle, not in the
clone, so removing clones destroys no evidence.

### 14.6 APFS copy-on-write accounting

`simctl` clones, and APFS file copies generally, share blocks with their
source. `du` reports each copy's apparent full size, so a directory that looks
like hundreds of gigabytes can hold almost no unique blocks.

Treat `du` as an upper bound on apparent size, never as recoverable capacity.
Measure reclaimable and reclaimed space with `df` before and after:

```bash
df -h /System/Volumes/Data
```

Worked example: deleting 76 XCTest clones that `du` totalled at 183 GB
reclaimed essentially nothing, because every clone shared its blocks with the
same source device. By contrast, 12 Xcode build directories that `du` totalled
at 3.3 GB returned a measured 3.07 GB, because build output is not cloned.

### 14.7 Diagnosing memory and swap thrashing

A starved host and a genuinely slow suite look identical in elapsed time.
Separate them by accumulated CPU:

```bash
ps -o pid,pri,stat,etime,time,%cpu,rss -p <pid>
```

A process with minutes of elapsed time and under a second of CPU is blocked on
memory and I/O, not working. Confirm with the page-in rate from 14.1.

Two traps:

* A process started in the background can sit at macOS priority `31T`, the
  *throttled* I/O tier, and get almost no I/O on a busy disk. Re-run it as
  `taskpolicy -t 0 <command>`.
* A pipeline reports its last stage's status, so `npm run typecheck | tail`
  exits 0 even when `tsc` was killed. Take the status from the unpiped command
  before recording a gate as passed.

### 14.8 Confirming no orphaned processes remain

Do not report a checkpoint complete on the strength of having sent a signal:

```bash
scripts/qa-processes.sh sweep         # reclaim anything whose owner finished
scripts/qa-processes.sh list          # no processes, no stray listeners
pgrep -fl 'esbuild --service'         # no orphaned services
```

Anything `list` still shows should be either `retained` on purpose or
something another lane owns. An `orphaned` row is work this machine is holding
for no one.

After any suite that spawns subprocesses, confirm none outlived it. A
timed-out test is the likeliest to leave a child behind: the test function is
abandoned without resuming, so only an `afterEach` still runs.
`src/startupValidation.test.ts` is the worked example.
