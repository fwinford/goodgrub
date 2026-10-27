# Repository Guidelines

Guidance for contributors and coding assistants working in this repository.
It states only lasting, portable repository rules.

## Project Structure

`app.ts` starts the Node/Express service. Backend routes and helpers live in
`src/`, with Mongoose models in `models/`.

Browser client source is `src/client/*.ts`; tracked generated bundles are
`public/js/*.js`. Static pages, CSS, and images are in `public/`. Maintenance
scripts are in `scripts/`.

The SwiftUI app and XCTest target are under `ios/CommonPlateios/`.

## Sources of Truth

* `docs/system-contract.md` is the durable current technical contract.
* `docs/testing.md` defines verification commands, prerequisites,
  organization, limitations, and accepted baselines.
* `docs/decisions/` contains durable technical decisions.
* `README.md`, `CONTRIBUTING.md`, and `SECURITY.md` describe scope,
  contribution flow, and vulnerability reporting.

The maintainer may keep private planning notes that are not part of this
repository. Do not depend on them. When repository sources conflict, say so
instead of silently choosing one.

## Change Discipline

Inspect current code, tests, Git state, and the applicable contract before
editing.

Deliver one coherent behavioral change at a time. Preserve accepted
architecture unless repository evidence requires revisiting it.

Do not silently resolve product questions. If accepted behavior is incomplete
or conflicts with repository evidence, stop and ask the maintainer.

Keep correctness fixes, product changes, broad cleanup, and documentation
separable enough to review. Do not introduce unrelated features or redesigns.

## Backend Rules and Traps

`src/day4Errors.ts` is the shared structured API-error contract despite its
milestone-era name. Reuse it; do not create new milestone-specific error
modules.

New endpoint behavior should normally live in a focused `src/*Route.ts` or
`src/*Routes.ts` module with minimal `app.ts` registration.

`app.ts` connects to MongoDB, schedules jobs, and listens at module scope. Some
tests inspect its source text instead of executing a test app. Do not broadly
reformat, reorder, or refactor `app.ts` within an unrelated change.

Do not reorder `models/db.ts` merely for style.

Preserve the transaction, uniqueness, privacy-by-omission, credential,
operation-identity, and ambiguous-mutation boundaries recorded in
`docs/system-contract.md`.

Use atomic conditional database mutations for lifecycle transitions. Do not
replace an accepted atomic mutation with read-check-save behavior.

## Browser Client Rules

Edit `src/client/*.ts`; never edit generated `public/js/*.js` directly.

After browser-client changes:

* run focused client tests;
* run `npm run typecheck`;
* run `npm run build:client`;
* inspect regenerated bundle diffs;
* preserve the generated-file banner.

CI does not independently determine whether generated bundle differences are
intentional.

## iOS Rules

Preserve the:

```text
APIClient → RequestService → RequestStore → SwiftUI
```

boundary.

Raw claim tokens and exact ambiguity-recovery payloads remain private to the
owning store. Do not expose or persist them without an accepted product and
security contract.

Never fabricate claim, placement, notification, subscription, or credential
state after an ambiguous response.

Preserve operation identities, collection revisions, stale-response guards,
cancellation boundaries, and one-use recovery limits.

Do not broadly split `RequestStore` during unrelated work.

Add new iOS tests in focused files where practical rather than continually
extending large existing test files.

## Subscription and Public-Action Boundary

The accepted subscriber lifecycle is:

```text
pending → confirmed → unsubscribed
```

Pending and unsubscribed subscribers are ineligible for alerts.

`docs/system-contract.md` defines current activation, eligibility,
confirmation, unsubscribe, credential, delivery, and pause behavior.

Do not change any of the following without an accepted product and technical
contract:

* `PUBLIC_ACTIONS_PAUSED`;
* subscriber eligibility;
* confirmation or unsubscribe credentials;
* reconfirmation behavior;
* activation sequencing;
* alert-delivery eligibility;
* notification-channel ownership.

Provider acceptance is not verified delivery, reading, or pickup.

## Verification

`docs/testing.md` is authoritative.

Compact minimum:

* TypeScript/backend: `npm run typecheck` plus focused and affected-neighbor
  tests.
* Complete non-Mongo backend, when `docs/testing.md` requires it: `npm test`.
* Mongo persistence, transactions, uniqueness, concurrency, or index work:
  `npm run test:mongo` in addition to `npm test`.
* Browser client: focused tests, `npm run typecheck`, and
  `npm run build:client`.
* iOS or cross-stack work: focused iOS tests, affected-neighbor tests, and the
  complete `CommonPlateiosTests` target when `docs/testing.md` requires it.
* Every change: `git diff --check`.

`npm test` does not replace the real Mongo integration suite. Use a replica set
for Mongo integration testing.

Keep `.env` untracked. Never commit secrets or use production-like databases
with local seed or integration tools.

Verification output must distinguish tests actually executed, tests skipped by
configuration, behavior verified only by source inspection, behavior verified
manually on a simulator or device, and behavior not yet verified.

## Local QA Processes and Machine Resources

Start any temporary QA environment through `scripts/qa-processes.sh run` so its
whole process group is registered and torn down on completion, failure, or
interruption. Do not leave one running past the checkpoint that started it.

Terminate only processes you own, identified by PID or verified process group.
Never use pattern kills such as `killall node`: other work may share the
machine.

Before resource-heavy verification, check free disk, swap, and load. A starved
host produces environmental timeouts that look like test failures; stop and
report instead of reinterpreting results. `docs/testing.md` holds the
executable procedures.

## Documentation Boundaries

`docs/system-contract.md` records durable accepted runtime truth, not proposed
behavior. `docs/testing.md` changes only when verification commands,
prerequisites, organization, limitations, or accepted baselines change.

Do not copy chat transcripts into repository documentation. Do not add weekly
status, temporary notes, implementation chronology, or changing test totals to
this file. Keep `CLAUDE.md` a thin bridge to this file.

## Safety Invariants

* Public request data is explicitly allowlisted.
* Pickup names and raw claim tokens are winner-only.
* Credentials, tokens, signatures, and secrets are never logged or exposed.
* Provider acceptance is not verified delivery, reading, or pickup.
* Ambiguous mutations are never automatically retried.
* Fulfillment email failure does not undo committed placement.
* No recovery path may suggest placing a second external order.
* No client may fabricate backend lifecycle or subscription truth.
* Public-action activation must fail closed when required configuration is
  missing.
* Privacy promises in the product must match runtime behavior.
