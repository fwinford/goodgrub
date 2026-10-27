# Contributing

Contributions are welcome through focused pull requests. GoodGrub is a
pre-release project; a contribution does not imply a public release, a support
commitment, or an ongoing maintenance promise.

## Forks and pull requests

1. Fork the repository, then create a branch from `main` in your fork. Use a
   short descriptive branch name such as `docs/clarify-setup` or
   `fix/request-state`.
2. Keep each change focused. In the pull request, explain the problem,
   summarize the change, and call out behavior or configuration effects.
3. Open a pull request against the official repository's `main` branch.
   Include the checks you actually ran, their results, any configuration-based
   skips, and relevant manual verification or limitations. Do not describe
   skipped tests as passing.
4. Do not include credentials, tokens, personal data, or production
   configuration in a commit, issue, or pull request.

Contributors work through forks and pull requests; outside contributors are
not given official-repository write, administrator, merge, or deployment
permissions. Faith is the sole final authority for official-repository merge
decisions. A pull request or successful check does not authorize a merge.

## Local checks

Use the checks that match the changed code. The commands below are documented
in [docs/testing.md](docs/testing.md); follow its prerequisites and limits.

```bash
npm ci --no-audit --no-fund
npm run lint
npm run typecheck
npm test
```

`npm test` skips Mongo-gated suites unless they are run separately. Changes to
Mongo persistence, transactions, uniqueness, concurrency, or indexes also
require the complete `npm run test:mongo` procedure with its disposable
replica set. Browser-client source changes require focused client tests and
`npm run build:client`; inspect generated bundle changes rather than editing
bundles directly. For iOS changes, use the focused tests and complete-target
requirements in `docs/testing.md`, with the `CommonPlateios` scheme on an
available simulator.

## License and review expectations

Contributed original code must be material you have the right to submit.
Accepted contributions to the original source are distributed under the
repository's [MIT License](LICENSE). No mandatory Contributor License
Agreement (CLA) or Developer Certificate of Origin (DCO) is required. The MIT
license does not grant rights to GoodGrub branding or third-party assets.

Expected quality includes focused changes, tests appropriate to the change,
clear descriptions of limitations, and no weakening of privacy or safety
boundaries. Review and merge remain subject to Faith's decision; no review
timeline or merge is guaranteed.

## CI and ownership

Pull requests run the `contributor-ci` workflow
(`.github/workflows/contributor-ci.yml`) on GitHub-hosted Linux: locked
dependency install, lint, typecheck, and the non-Mongo `npm test` suite. It
does not run the Mongo integration suites or the iOS tests, so a passing check
is not proof of those areas; run them locally when your change requires them.
The workflow runs on `pull_request` with read-only repository permissions and
no secrets. Its behavior for pull requests from forks has not been tested.

`.github/CODEOWNERS` routes every path, including `.github/`, to Faith
(`@fwinford`). Branch protection or rulesets for `main` are not described here
as active; do not assume that required checks, required reviews, or branch
restrictions are enforced by GitHub until the repository states that they are.
