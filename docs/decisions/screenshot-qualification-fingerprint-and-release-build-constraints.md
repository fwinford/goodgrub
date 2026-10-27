# Screenshot qualification is pinned to a build-derived implementation fingerprint, and Release builds gate generic-class deinit

**Status.** Accepted (established during W4-S3, 2026-09-30).

**Context.** W4-S3 gates local Screenshot Assistance providers behind an exact
qualification entry (`docs/system-contract.md` section 15). Version-string
labels alone cannot prove that the code a qualification was measured against
is the code that ships: a prompt, normalizer, vendor-grounding, or validator
edit that forgot to bump a label would silently inherit an old qualification.
Separately, building S3 for Release exposed a compiler crash that Debug and
simulator-only runs never hit.

**Decision 1 — fingerprint-bound qualification.** A qualification entry pins an
implementation fingerprint in addition to its version labels. The always-run
`Derive Screenshot Qualification Fingerprint` build phase hashes every file
under `Services/ScreenshotAssistance` (recursively) plus
`ScreenshotImageNormalizer.swift`, `ScreenshotLocalTextRecognizer.swift`,
`SupportedVendorCatalog.swift`, `ScreenshotProposal.swift`,
`CommonPlateModels.swift`, and `shared/vendors.json` into the generated
`ScreenshotQualificationFingerprint.current`. Any change to those inputs changes
the fingerprint and therefore invalidates every existing entry, so
qualification must be re-earned rather than inherited. Consequences:

- `ScreenshotQualificationRegistry.production` lives in
  `Services/ScreenshotQualificationProduction.swift`, deliberately outside the
  hashed directory; otherwise adding an entry would change the fingerprint it
  pins. It currently has zero entries.
- The script carries paths NUL-terminated end to end and fails the build on a
  missing or unreadable input; Debug, Release-simulator, and Release-device
  builds must derive the same value.
- The app target sets `ENABLE_USER_SCRIPT_SANDBOXING = NO`. Xcode's script
  sandbox lets a script list a declared directory but not read its files, so a
  directory input would otherwise require every file to be registered by hand.
  This is scoped to the app target, whose only script phase is this one. Do not
  add another script phase to that target without re-deriving this reasoning.

**Decision 2 — explicit `deinit {}` on generic classes.** Under this project's
default MainActor isolation, the Swift 6.3 release optimizer crashes
(`EarlyPerfInliner`, recursion in `isCallerAndCalleeLayoutConstraintsCompatible`)
on the synthesized deinit of a generic class, for both the simulator and the
device (TestFlight-shaped) Release builds. The workaround is an explicit empty
`deinit {}`, as on `ScreenshotAssistanceRuntime`. A repository-wide automated
rule for this was tried and deliberately removed as outside S3's scope, so the
Release build is the only guard.

**Consequence for future work.** Any change that adds or edits a generic class
(including H1's use of the shared runtime) must be proven with Release builds
for the generic iOS Simulator and the unsigned generic iOS device, not only a
Debug test run (`docs/testing.md`). Revisit Decision 2 when the toolchain is
upgraded past the crashing Swift release; revisit Decision 1 only with new
qualification-evidence rules from W4-S2.
