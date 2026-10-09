# Release evidence reuse proposal (SHOPPING-231)

Status: design only. No gate removal or attestation transfer is approved.

The first change to adopt is ordering, already scoped separately in SHOPPING-227.
Spend cheap focused and compiler proof before exhaustive proof. Reuse the existing
manual Swift CI result for that candidate, rather than dispatching another copy.

| Evidence | Owns | Valid reuse | Invalidation |
| --- | --- | --- | --- |
| Focused issue tests | Changed behavioral boundaries | Review and diagnosis of the recorded revision | Relevant source, fixtures, plan, runtime, or selection change |
| Exact candidate manual CI | Pinned Debug tests, independent Fast coverage, Release compilation | SHOPPING-227 preflight for identical SHA and latest successful attempt | SHA or workflow/toolchain change; later failed attempt |
| Local Full | Entire local regression inventory on local SDK/runtime | Existing SHA-keyed attestation | Any new SHA; dirty source; changed plan/environment |
| Hosted Full | Entire regression inventory on pinned older runtime | Exact candidate integration evidence | New SHA; different runtime/toolchain or inventory |
| PR CI | Candidate integrated with current base | Required PR merge check | Base/head/merge revision change |
| Main CI | Actual landed source and deterministic coverage | Existing release gate | New main SHA; newer failed run |
| Signed archive/upload | Distribution build, capabilities, versions, profiles | Processing/distribution retry for same uploaded build | New source, version/build pair, settings, signing identity, profile or entitlements |

## Source-tree equality is insufficient

Phase 33's db9686f and a5a9d59 had the same Git tree, but the app's generated build
identity includes the commit SHA. Two equal trees can therefore build different
binaries. A merge can change parentage, build identity, CI event/ref inputs, or
configuration while leaving many Swift files untouched. An unsigned simulator or
Release archive cannot establish signed app/Watch entitlements or upload validity.
Never copy a local Full attestation to another SHA on tree equality alone.

A future reuse design would need an immutable manifest containing source/tree and
commit identity, generated source hashes, compiler/SDK and runtime, resolved build
settings, dependency graph, app/Watch version and bundle identity, test executable
hashes, exact plan/selection, coverage instrumentation, fixture version, results,
and successful producing run/attempt. For distribution, add signing/profile and
entitlement identity. The consumer must verify every relevant field and fail
closed on a missing field. This is substantially more machinery than the current
SHA gate and is not recommended until measured duplication justifies it.

## Candidate decisions

1. Keep exact-SHA attestations. Local compilation is about 39–50 seconds of a
   65-minute Full cycle, so cross-SHA build reuse offers little local benefit.
2. Keep current within-job build reuse for Fast and Acceptance. Their distinct
   result bundles and Fast-only coverage gate remain authoritative.
3. Keep main CI after integration: it proves the actual release source. Preserve
   both required PR jobs and the unsigned Release archive.
4. Investigate hosted build caching separately only after measuring restoration,
   upload, cache hit rate and compiler invalidation. Historical hosted build was
   290 seconds, an upper bound rather than a promised saving.
5. Do not remove either exhaustive platform on these measurements. Local Xcode 27
   and hosted Xcode 16.4/iOS 18.5 cover distinct compatibility boundaries. A future
   proposal could replace some repeat UI permutations with retained deterministic
   owners, but must enumerate those assertions before changing the inventory.

## Adversarial acceptance cases for any future reuse implementation

Reject same tree/different generated SHA; old result after a test rename; skipped
or duplicated methods; changed source after a pass; unsigned evidence for signed
upload; higher UI coverage masking a Fast regression; old successful attempt after
a failed rerun; base advancement; app/Watch identity mismatch; changed fixture
seed or recovery launch flags; different runtime Settings behavior; and incomplete
xcresult/report output after a cancelled command.

## Savings and decision threshold

One truly avoided local Full would save the retained Phase 33 65m 06s, but none is
approved for removal. Hosted Phase 33 Full saving is unmeasured. Do not add the
local and hosted figure when runs overlap or count summed tests as elapsed time.
The policy work therefore claims zero implemented savings. Prioritize measured UI
execution and correct ordering before adding provenance infrastructure.
