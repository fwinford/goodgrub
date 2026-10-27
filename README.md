# GoodGrub

GoodGrub is the iOS app and backend for CommonPlate's campus meal-request
flow. It helps students request a meal and coordinate with a verified peer
who chooses to help.

## Project status

GoodGrub V1 is an iPhone app with a supporting Node.js backend. This
repository is the source for that work; it is pre-release. It does not
describe or operate a public production deployment, and nothing here states
that the app is available on the App Store or through TestFlight. The
backend's public actions (such as alert signup and confirmation) are gated by
the `PUBLIC_ACTIONS_PAUSED` setting, which the example configuration sets to
`true`. The repository documents accepted local source
behavior, not a verified production release.

A GoodGrub website is planned for V2 and is not currently shipped.
[commonplatenyu.org](https://commonplatenyu.org/) is the deprecated and
unsupported legacy CommonPlate website. It may still be reachable, but it is
not a supported GoodGrub V1 experience, and no migration or continued feature
maintenance of it is planned. Its deployed revision and behavior have not been
reconciled with this source. The legacy browser pages and client bundles
remain in the repository, and the legacy browser fulfillment page in the
accepted source is disabled; that does not establish what the deployed site
currently does or that it is security-cleared.

## Product scope

The current V1 journey is **create → list → claim → fulfill → placed**. A
requester posts a meal request, another verified participant may claim it,
place the order independently, and record the fulfillment details. GoodGrub
coordinates the request; it does not process payments or place provider
orders. After placement, the requester may confirm pickup in the app; this is
the requester's report, not provider-verified pickup. CommonPlate attempts
requester confirmation and fulfillment emails; request creation and provider
submission do not guarantee delivery.

Request-linked messaging (HTTP, WebSocket and unread-tracking foundations, and
an iOS client) is present in the source but dormant: the backend routes are not
mounted by `app.ts`, and the shipping iOS composition never enables a
conversation entry point. It is not an available feature, and nothing here
promises its release. Authentication beyond the accepted verified-participant model, maps, payments,
cancellation, and a no-show lifecycle are not part of the current supported
product.

## Architecture

- **iOS:** SwiftUI app. Networking and state follow
  `APIClient → RequestService → RequestStore → SwiftUI`.
- **Backend:** Node.js and TypeScript with Express; MongoDB is accessed through
  Mongoose. The backend owns request lifecycle and participant-authority
  decisions.
- **Legacy web:** Browser client and static assets remain in the repository.
  They are not the direction of current GoodGrub development.

See [the system contract](docs/system-contract.md) for accepted runtime
behavior and [the verification guide](docs/testing.md) for test procedures
and limitations.

## Local setup

The documented local baseline is Node.js **24.13.0** and npm **11.6.2**.
Install dependencies and run the backend checks:

```bash
npm ci --no-audit --no-fund
npm run typecheck
npm test
```

`npm test` skips Mongo integration suites when their test environment is not
configured; it is not Mongo persistence proof. For persistence changes, use
`npm run test:mongo`, which starts its own disposable local replica set and
requires `mongod` and `mongosh`. Never point tests at a shared, staging, or
production database.

Running the app requires a local MongoDB deployment that supports
transactions; a dedicated single-member replica set is sufficient. Copy
`.env.example` to an untracked `.env` and use local development values only.
For example, the non-secret settings can look like:

```env
NODE_ENV=development
PORT=3000
PUBLIC_ACTIONS_PAUSED=true
MONGO_URI=mongodb://127.0.0.1:27017/commonplate_development?replicaSet=rs0
```

The app validates additional environment values at startup; consult the
comments in `.env.example` before running `npm run dev`. Do not use production
credentials, shared databases, or checked-in secrets. The test runner does
not require starting the app or configuring `MONGO_URI`.

For iOS, open
`ios/CommonPlateios/CommonPlateios.xcodeproj` in full Xcode and select the
`CommonPlateios` scheme and an available simulator. The `CommonPlateiosTests`
target and exact terminal command are documented in
[docs/testing.md](docs/testing.md#9-complete-terminal-ios-test-command).

## License and contributions

The MIT license applies only to original source code its author is authorized
to license. It does not grant rights to the official GoodGrub name, logo, or
brand identity; third-party assets keep their own terms.

See [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and
[CONTRIBUTING.md](CONTRIBUTING.md).
