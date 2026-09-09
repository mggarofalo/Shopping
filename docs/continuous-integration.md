# Continuous integration

SHOPPING-63 separates quick correctness feedback from slower device-level automation. Pull requests no longer wait for every UI test before reporting whether the app builds and its persistence behavior is sound.

## Baseline

The previous workflow created one simulator and ran every test target in one `xcodebuild test` step. The step mixed compilation, UI automation, performance flows, and persistence tests. This made the exact compilation time unavailable. The build column below measures the time from the start of that combined step to the first UI test. It includes compilation and pre-test setup.

| Run | Event | Result | Job | Build and setup | UI suite | Persistence suite | Failure |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| [34163413860](https://github.com/mggarofalo/Shopping/actions/runs/34163413860) | Pull request | Failed | 37m 16s | 2m 13s | 32m 44s | 9s | Performance flow could not find the Catalog search field. |
| [34155183864](https://github.com/mggarofalo/Shopping/actions/runs/34155183864) | Pull request | Failed | 50m 41s | 4m 7s | 42m 21s | Performance flow could not find the Catalog search field. |
| [34153570024](https://github.com/mggarofalo/Shopping/actions/runs/34153570024) | Milestone push | Passed | 40m 9s | 4m 15s | 32m 21s | 10s | None. |
| [34150558212](https://github.com/mggarofalo/Shopping/actions/runs/34150558212) | Pull request | Passed | 44m 37s | 5m 1s | 36m 48s | 12s | None. |
| [34147351181](https://github.com/mggarofalo/Shopping/actions/runs/34147351181) | Pull request | Failed | 38m 57s | 2m 26s | 33m 45s | 12s | Accessibility queries counted duplicated Catalog elements. |

The 5 jobs ranged from 37m 16s to 50m 41s, with a median of 40m 9s and an observed nearest-rank p95 of 50m 41s. Three failed in UI automation after the deterministic persistence suite had passed. Pull-request and milestone runs then repeated the same full suite on closely related commits.

## Test plans

The shared `Shopping` scheme exposes 5 plans:

| Plan | Owner | Contents | Normal trigger |
| --- | --- | --- | --- |
| `ShoppingFast` | Required pull-request check | 166 deterministic unit, persistence, recovery, filtering, and service tests | Every pull request and push to `main` or `milestone/**` |
| `ShoppingCritical` | Semantic local check | 14 Swift Testing cases tagged `.critical` across unit and persistence suites | Local or manual use |
| `ShoppingFull` | Exhaustive regression check | `ShoppingFast` plus UI, appearance, and simulator device tests | Manual remote dispatch only after the exact commit passes locally |
| `ShoppingPerformance` | Performance investigation | The 3 service benchmarks and 2 loaded UI performance flows | Manual dispatch |
| `ShoppingDevice` | Physical-device validation | `ShoppingDeviceUITests` | Manual local run on a signed device |

The full and performance plans do not retry failures. A failed UI test remains visible and actionable. The performance flow moved out of ordinary regression coverage because it is a long measurement route, not a product assertion. `ShoppingFull` retains all product, accessibility, appearance, recovery, and device-simulation workflows.

## Flake ownership

Run 34147351181 counted duplicated Catalog accessibility elements. SHOPPING-60 replaced the parallel custom selection behavior with native `List(selection:)` state and updated the affected queries. The current full plan keeps those assertions enabled.

The two performance-flow search failures remain enabled in `ShoppingPerformance`. That plan owns the loaded route and must pass before using it as performance evidence. It stays manual until the route produces 3 consecutive hosted runs without a lookup failure. No workflow retries or expected-failure annotations mask either class of failure.

The first local `ShoppingFull` validation also exposed a Catalog editor lookup that assumed a newly saved row would already be onscreen. The test now filters by the saved name, addresses the stable `shopping.catalog.item.*` row control, and explicitly closes the search keyboard before continuing. The repaired flow passed 3 consecutive focused runs without a retry policy.

## Validation

On the documented iPhone 17 Pro simulator, the final September 8 `ShoppingFast` run passed 160 tests in about 6 seconds after incremental build setup. The 9-case `ShoppingCritical` plan finished its test execution in 0.04 seconds. This is the local proxy for the required check and is materially quicker than the full-plan baseline.

The initial local `ShoppingFull` run built in 37 seconds and ran 201 tests in 31m 26s. It passed 200 tests and found the Catalog lookup described above. After the fix, a clean build took 42 seconds and all 201 tests passed in 32m 37s. The hosted runner uses the pinned Xcode 16.4 image, which is not installed in the local environment.

The SHOPPING-61 coverage run passed all 209 tests then present in `ShoppingFull` in 34m 56s. The 3 focused navigation cases added afterward passed in the final fast and critical runs, bringing the maintained inventory to 212 without changing app or UI behavior.

The first remediated [hosted pull-request run](https://github.com/mggarofalo/Shopping/actions/runs/34195500331) passed in 6m 2s on the pinned image. Simulator setup took 1m 55s, the summary recorded a 2m 42s build and a 46-second test step, and all 152 tests passed. This first sample is below both the 10-minute target and the 15-minute timeout. A statistically useful post-change p95 requires more hosted runs; the timeout bounds feedback while those samples accumulate.

## Commands

List the plans:

```bash
xcodebuild -project Shopping.xcodeproj -scheme Shopping -showTestPlans
```

Run the fast local gate:

```bash
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingFast -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C'
```

Run the tag-filtered critical check:

```bash
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingCritical -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C'
```

Run exhaustive local coverage:

```bash
.github/scripts/run-local-shopping-full.sh
.github/scripts/dispatch-remote-shopping-full.sh
```

The first command refuses a dirty worktree, exports the exact `HEAD` commit to an isolated temporary source snapshot, runs `ShoppingFull` there on the pinned local simulator, and records a pass only if the original worktree still has the same clean `HEAD` afterward. Push that unchanged commit before running the second command. The dispatch command refuses a missing local pass, a dirty worktree, or a remote branch whose head differs from the attested SHA. It publishes the `local/ShoppingFull` status on that exact commit and explicitly dispatches the hosted workflow. The hosted preflight independently requires a successful status on its exact workflow SHA before allocating the macOS exhaustive runner.

Run the performance plan only when measuring a stable environment:

```bash
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingPerformance -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C'
```

Run the signed physical-device plan by replacing the placeholder with the connected device identifier:

```bash
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingDevice -destination 'platform=iOS,id=<DEVICE-UDID>'
```

CI first rejects test categorization based on `#if targetEnvironment(simulator)`. It then uses `build-for-testing` once and `test-without-building`. Each run publishes a small Markdown and JSON test summary. Fast and full runs also publish line and function coverage from `xccov`. The required fast job fails when coverage regresses materially from `.github/coverage-baseline.json`. Failed runs retain the build log, test log, and complete result bundle for 14 days.

## Coverage ownership

`ShoppingFast` and `ShoppingFull` collect coverage. The fast plan gates the whole app against measured toolchain-specific baselines: Xcode 16.4 uses 39.33% lines and 31.86% functions, while Xcode 26.6 uses 41.71% lines and 34.84% functions. Both gate deterministic domain and service files at 96.42%. An unknown Xcode version requires an explicit measured baseline instead of inheriting another compiler's values. A change may vary by up to 0.5 percentage points before the gate treats it as a material regression.

SwiftUI rendering dominates the lines uncovered by the fast plan. `ShoppingFull` publishes the broader UI-driven report without weakening the fast required check; the final local full run reached 89.83% line and 82.73% function coverage for the app target. [Test strategy](test-strategy.md) records the full inventory, the scoped 90% goal, fixture boundaries, and exclusions.

## Workflow ownership

- Pull requests run the existing `Build & Test` check. Its name stays stable for branch protection. The active `main` ruleset required pull requests but no status-check context on September 8, 2026; changing repository protection is outside this code change.
- Milestone pushes run only the fast workflow automatically. They never start the exhaustive workflow.
- Pushes to `main` repeat only the fast check. The milestone commit must receive exact-SHA local and hosted exhaustive coverage before integration.
- Remote `ShoppingFull` is deliberately infrequent and is expected to pass: it runs only through the exact-commit local pass and dispatch commands above. Missing or stale attestations fail in the lightweight preflight before simulator setup.
- Manual dispatch can run the performance plan without a ShoppingFull attestation. Physical-device automation stays local because signing and device access are unavailable to GitHub-hosted runners.
- Workflow-level concurrency cancels an older run when a newer commit targets the same workflow, branch, and exhaustive suite. Manual performance work does not cancel a full regression run.

This split preserves all maintained tests. New deterministic suites should use Swift Testing tags. UI automation stays in XCTest.
