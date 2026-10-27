# SwiftUI geometry measurement must use `.global`, never a named `CoordinateSpace`, across a `NavigationStack` hosting boundary

**Status.** Accepted (established during W4-D2, 2026-09-18).

**Context.** CommonPlate pushes Request Food as a subordinate destination on
`ContentView`'s existing root `NavigationStack` rather than presenting it in a
separate nested stack (`docs/system-contract.md` section 13). W4-D2's
Success→Home continuity handoff needs to measure Home's real owned-request
slot from inside that pushed destination and compare it against the
continuity overlay's own card frame, to land or crossfade the card at the
correct on-screen position.

**Decision.** Cross-boundary geometry comparison in this app must use SwiftUI's
`.global` coordinate space, never a named `CoordinateSpace` declared with
`.coordinateSpace(name:)`. A named coordinate space anchors to whichever view
subtree declares it; declaring it above a `NavigationStack` push boundary does
not make it resolve identically inside a pushed destination hosted by that
stack — the two sides end up measured in different origins, and subtracting
them silently produces a wrong (but plausible-looking) offset rather than an
error. `.global` is anchored to the window itself and resolves identically on
both sides of the boundary.

**Consequence for future work.** Any future feature that measures or
compares view geometry across a `NavigationStack` push/pop boundary in this
app (or across a sheet/overlay boundary with similar hosting semantics) must
use `.global`, not a named coordinate space, for that comparison. This was
found as a real, physical-device-reproducible defect (~62pt vertical
misplacement, matching the simulator's safe-area top inset) in
`RequestCreationContinuityLayout`'s Success→Home landing geometry; the fix and
its hosted regression coverage are `RequestCreationContinuityHostedGeometryTests`
(mounting the real production view inside a real `NavigationStack` and a real
`UIWindow` with a non-zero safe area, per `docs/testing.md`'s no-UI-test-target
constraint). Do not reintroduce a named coordinate space for any geometry
comparison that crosses this kind of hosting boundary without re-deriving this
reasoning.

**Related, not covered by this decision.** A second, unrelated defect fixed in
the same pass — a slot-frame commit reading a captured-once `.task` parameter
instead of the latest delivered value, fixed by mirroring it into `@State`
before commit — is an ordinary SwiftUI state-freshness bug, not a coordinate-
space issue, and does not generalize into a durable rule beyond "commit the
latest `@State`-mirrored value, not a captured task parameter."
