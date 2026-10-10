# Continuous integration

SHOPPING-119 follows [Apple’s reduced pull-request plan guidance](https://developer.apple.com/videos/play/wwdc2022/110361/): deterministic tests plus a small selection of important UI workflows on one pinned platform. Exhaustive UI regression remains a separate, manual confirmation. Routine CI runs once per pull-request update rather than also repeating on its milestone push.

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

The shared `Shopping` scheme exposes 6 plans:

| Plan | Owner | Contents | Normal trigger |
| --- | --- | --- | --- |
| `ShoppingFast` | Independent deterministic coverage gate | 218 deterministic unit, persistence, recovery, filtering, and service tests | Every pull request, push to `main`, or manual Swift CI dispatch |
| `ShoppingAcceptance` | Quick product acceptance | All `ShoppingFast` tests plus 6 explicitly selected UI workflows | Same routine CI events; CI executes Fast and UI portions separately from one build |
| `ShoppingCritical` | Semantic local check | 14 Swift Testing cases tagged `.critical` across unit and persistence suites | Local or manual use |
| `ShoppingFull` | Exhaustive regression check | `ShoppingFast` plus UI, appearance, and simulator device tests | Manual remote dispatch only after the exact commit passes locally |
| `ShoppingPerformance` | Performance investigation | The 3 service benchmarks and 2 loaded UI performance flows | Manual dispatch |
| `ShoppingDevice` | Physical-device validation | `ShoppingDeviceUITests` | Manual local run on a signed device |

`ShoppingAcceptance.xctestplan` is the canonical UI selection: catalog save/add without duplication; store-scoped checkout; committed-clear recovery after abrupt exit; one-time add without catalog pollution; remembered-item edit/cancel and relaunch; and checklist controls at accessibility text size. The [behavior ownership ledger](test-ownership.md) explains why these UI boundaries remain. Acceptance is a subset of `ShoppingFull`, not a replacement for it. Additions require a distinct behavior owner and measured impact on feedback time; do not select an entire UI class for convenience.

The full and performance plans do not retry failures. A failed UI test remains visible and actionable. The performance flow moved out of ordinary regression coverage because it is a long measurement route, not a product assertion. `ShoppingFull` retains all product, accessibility, appearance, recovery, and device-simulation workflows.

## Flake ownership

Run 34147351181 counted duplicated Catalog accessibility elements. SHOPPING-60 replaced the parallel custom selection behavior with native `List(selection:)` state and updated the affected queries. The current full plan keeps those assertions enabled.

The two performance-flow search failures remain enabled in `ShoppingPerformance`. That plan owns the loaded route and must pass before using it as performance evidence. It stays manual until the route produces 3 consecutive hosted runs without a lookup failure. No workflow retries or expected-failure annotations mask either class of failure.

The first local `ShoppingFull` validation also exposed a Catalog editor lookup that assumed a newly saved row would already be onscreen. The test now filters by the saved name, addresses the stable `shopping.catalog.item.*` row control, and explicitly closes the search keyboard before continuing. The repaired flow passed 3 consecutive focused runs without a retry policy.

## Validation

On the documented iPhone 17 Pro simulator, the final September 8 `ShoppingFast` run passed 160 tests in about 6 seconds after incremental build setup. The 9-case `ShoppingCritical` plan finished its test execution in 0.04 seconds. This is the local proxy for the required check and is materially quicker than the full-plan baseline.

The initial local `ShoppingFull` run built in 37 seconds and ran 201 tests in 31m 26s. It passed 200 tests and found the Catalog lookup described above. After the fix, a clean build took 42 seconds and all 201 tests passed in 32m 37s. The hosted runner uses the pinned Xcode 16.4 image, which is not installed in the local environment.

The SHOPPING-61 coverage run passed all 209 tests then present in `ShoppingFull` in 34m 56s. The 3 focused navigation cases added afterward passed in the final fast and critical runs, bringing the maintained inventory to 212 without changing app or UI behavior. As the exhaustive inventory grew, a later pinned run reached the former 60-minute job ceiling before `xcodebuild` could write its result bundle. The hosted job now allows 90 minutes so setup, build, the no-retry full suite, coverage export, and artifact publication can finish without weakening any test assertion.

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

Run the complete quick acceptance plan locally:

```bash
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingAcceptance -parallel-testing-enabled NO -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C'
```

This combined local result is useful for product feedback, but it cannot replace the separate `ShoppingFast` result used by the CI coverage gate.

Run the tag-filtered critical check:

```bash
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingCritical -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C'
```

Before freezing an exhaustive candidate, run the focused UI workflows affected by
its changes, including recovery, system Settings, and abrupt-exit boundaries when
applicable. Quick acceptance alone cannot establish a changed workflow outside
its six selected methods. Record the selection, result bundle, and source SHA in
the issue; fix failures before committing the candidate.

The candidate gate order is:

```text
changed-boundary tests → clean committed candidate → push exact branch
  → manual Swift CI (Build & Test + Release SDK Build)
  → local ShoppingFull → push unchanged SHA → hosted ShoppingFull
  → integration → required main CI → signed release
```

Start the existing compatibility checks early with `gh workflow run swift-ci.yml
--ref <issue-or-milestone-branch>` after pushing the candidate. Wait for both jobs
to pass. `run-local-shopping-full.sh` verifies the latest exact-source manual run
(or main push) before allocating local Full artifacts or touching a simulator.
It rejects missing, running, failed, skipped, or cancelled proof. For a partial
rerun, it checks the most recent execution of each required job within that same
exact-source run; an older success never overrides a newer failure or skip. Pull-request
runs compile a synthetic merge commit and do not replace this exact-source gate.
A source change requires another exact-source check; the preflight never copies
proof between SHAs. Required PR/main CI and the hosted Full attestation remain.

This reorders the existing manual compatibility check; it adds no compiler job.
The retained Phase 33 successful manual run took 15m 19s for Build & Test and
4m 27s for Release SDK Build concurrently. Treat the former as elapsed wait,
not their sum. If that run was already required, incremental hosted compute is
zero; otherwise the early gate adds one routine CI run. It avoids the measured
65m 06s local Full cost when the pinned compiler rejects the candidate. A clean
release has no demonstrated time saving from this ordering alone. Capture live
queue time and job duration for subsequent candidates rather than claiming the
historical sample as a new measurement.

Run exhaustive local coverage:

```bash
.github/scripts/run-local-shopping-full.sh
.github/scripts/dispatch-remote-shopping-full.sh
```

The local Full runner uses two native simulator workers by default. The [complete M2 comparison](shopping-full-runtime.md#phase-33-two-native-workers-on-the-m2-shopping-228) saved 27m32s with all 917 tests passing, at higher memory pressure. Keep local validation exclusive. Use `SHOPPING_FULL_WORKERS=1 .github/scripts/run-local-shopping-full.sh` for serial diagnosis; other worker counts are rejected. Commands and attestations record the selected count. Hosted worker defaults are unchanged.

The first command refuses a dirty worktree, exports the exact `HEAD` commit to an isolated temporary source snapshot, runs `ShoppingFull` there on the pinned local simulator, and records a pass only if the original worktree still has the same clean `HEAD` afterward. Push that unchanged commit before running the second command. The dispatch command refuses a missing local pass, a dirty worktree, or a remote branch whose head differs from the attested SHA. It publishes the `local/ShoppingFull` status on that exact commit and explicitly dispatches the hosted workflow. The hosted preflight independently requires a successful status on its exact workflow SHA before allocating the macOS exhaustive runner.

Run the performance plan only when measuring a stable environment:

```bash
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingPerformance -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C'
```

Run the signed physical-device plan by replacing the placeholder with the connected device identifier:

```bash
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingDevice -destination 'platform=iOS,id=<DEVICE-UDID>'
```

CI first rejects test categorization based on `#if targetEnvironment(simulator)`. The existing `Build & Test` job boots one iPhone 16 Pro/iOS 18.5 simulator, uses `build-for-testing -testPlan ShoppingAcceptance` once, and reuses that `DerivedData` for two `test-without-building` commands:

1. `-testPlan ShoppingFast` writes `FastResults.xcresult`; only this bundle feeds the existing coverage gate.
2. `-testPlan ShoppingAcceptance -only-testing:ShoppingTests -parallel-testing-enabled NO` writes `AcceptanceResults.xcresult`; the plan narrows that UI target to its explicit six methods.

The built `.xctestrun` selection is checked before either run. After UI execution, the timing report must contain exactly the selected six passing methods, with no skipped, duplicate, or additional tests. These checks prevent a renamed selection silently disappearing or a target filter accidentally broadening to the exhaustive UI suite. Contract tests also protect plan membership, trigger ownership, shared build products, failure propagation, and the independent Fast coverage source:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .github/scripts -p 'test_acceptance_contract.py'
```

Each result publishes a Markdown and JSON summary. Fast and full runs publish line and function coverage from `xccov`; adding UI coverage cannot mask a deterministic coverage regression. Failed runs retain the shared build log, both test logs, and result bundles for 14 days. No test retries are enabled. The Build & Test job has a 30-minute limit after the September 27 Phase 19 cold run used about 11 minutes for setup, compilation, Fast tests, and coverage, then reached the former 15-minute limit during the selected UI workflows. The planning goals remain roughly 3 minutes of selected UI execution and under 10 minutes for the routine job; measurements, rather than those provisional budgets, determine whether another redesign is needed. These are not new timing gates.

## Coverage ownership

`ShoppingFast` and `ShoppingFull` collect coverage. The fast plan gates the whole app against measured toolchain-specific baselines: Xcode 16.4 uses 39.33% lines and 31.86% functions, while Xcode 26.6 uses 41.71% lines and 34.84% functions. Both gate deterministic domain and service files at 96.42%. An unknown Xcode version requires an explicit measured baseline instead of inheriting another compiler's values. A change may vary by up to 0.5 percentage points before the gate treats it as a material regression.

SwiftUI rendering dominates the lines uncovered by the fast plan. `ShoppingFull` publishes the broader UI-driven report without weakening the fast required check; the final local full run reached 89.83% line and 82.73% function coverage for the app target. [Test strategy](test-strategy.md) records the full inventory, the scoped 90% goal, fixture boundaries, and exclusions.

## Workflow ownership

- Pull requests run `Build & Test` and `Release SDK Build`. The maintained main policy in `.github/main-ruleset.json` requires both checks from GitHub Actions on an up-to-date branch. Their names remain stable. GitHub approval count stays zero for this single-contributor repository; independent agent review and remediation happen before the phase PR. Inspect the proposed live-policy update with `python3 .github/scripts/main-ruleset.py`, explicitly apply with `--apply`, and verify without writing with `--check`. The reconciliation preserves other protections and refuses unexpected scope or approval-policy changes.
- Milestone pushes do not start routine CI independently. An open pull request targeting `main` or `milestone/**` runs the quick check on each update; use manual Swift CI dispatch when validation is needed before opening a PR. This removes the duplicate push/PR job pair.
- Pushes to `main` and manual Swift CI dispatch run the same quick acceptance check. The milestone commit must still receive exact-SHA local and hosted exhaustive coverage before integration.
- Remote `ShoppingFull` is deliberately infrequent and is expected to pass: it runs only through the exact-commit local pass and dispatch commands above. Missing or stale attestations fail in the lightweight preflight before simulator setup.
- Manual dispatch can run the performance plan without a ShoppingFull attestation. Physical-device automation stays local because signing and device access are unavailable to GitHub-hosted runners.
- Workflow-level concurrency cancels an older run when a newer commit targets the same workflow, branch, and exhaustive suite. Manual performance work does not cancel a full regression run.

The exhaustive plan retains all maintained regression workflows. Scenario consolidation must name the retained UI or deterministic owner in the [behavior ledger](test-ownership.md); runtime alone is not grounds to remove proof. New deterministic suites should use Swift Testing tags. UI automation stays in XCTest.

## Timing artifacts

Routine and exhaustive jobs retain `*Timing.json`, `*Timing.md`, `*TimingMetadata.json`, and `*Phases.jsonl` alongside their existing summaries for 30 days. The Actions summary shows simulator startup, build, test, coverage, and summary wall time plus the slowest suites and tests. Routine CI keeps its existing `fast-summary-*` artifact name and includes both `Fast*` and `Acceptance*` reports. Simulator startup and the shared acceptance build appear once in `FastPhases.jsonl`; `AcceptancePhases.jsonl` owns only the selected UI execution and reporting. The acceptance summary references the same shared build time, so do not add the two summaries’ build times together. Both metadata snapshots are captured before reports are copied into the checkout. Metadata captures the exact checkout SHA, dirty state, Xcode, host, and Actions run URL before artifact creation; the result supplies simulator details. Failed commands retain their original exit status, and the reporting step runs even when setup or tests fail. A job canceled before a command exits may have incomplete timing; the report states missing data rather than treating it as zero.

The local `run-local-shopping-full.sh` prints two paths. Lightweight `Timing.{json,md}`, `Metadata.json`, `Phases.jsonl`, and `Summary.{json,md}` reports persist in the Git common directory under `shopping-test-timings/<SHA>/<unique-run-id>/` for both successful and failed runs. Each run has a separate directory, including repeated runs of one commit. This history survives temporary-directory cleanup and is shared across worktrees without modifying source files. Large build/test logs and the result bundle stay in the printed temporary artifact directory and may be removed by the operating system. The attestation points to the durable timing report. Each report records the absolute temporary `result_bundle_path`, and logged phases record `log_path`, so failed runs can be traced back to raw artifacts while those temporary paths still exist. It measures source snapshot, simulator startup, build-for-testing, test-without-building, and summary separately. The runner still requires a clean commit, tests an isolated snapshot, checks the original clean SHA again, and records its attestation only after successful tests. Reporting runs on failure too. The remote exact-SHA attestation preflight and coverage gates remain mandatory.

The JSON report uses `schema_version: 1`. `phases[].wall_seconds` is monotonic elapsed command time; build/test phases also retain the exact argument array, including test selection and worker options; `tests[].duration_seconds` and `suites[].summed_test_seconds` are xcresult measurements, which can overlap under parallel execution. Preserve this distinction when comparing runs. Compare the same plan and test inventory on the same toolchain/runtime, and retain the raw reports as evidence. See [runtime measurements](test-strategy.md#runtime-measurements) for focused local commands and [ShoppingFull runtime investigation](shopping-full-runtime.md) for measured bottlenecks and policy recommendations.

## CI dependency maintenance

External Actions use full commit SHAs, with readable version comments. Weekly Dependabot PRs propose GitHub Actions updates; they receive the same required CI and independent review. `ruby .github/scripts/check-action-pins.rb` rejects mutable references across every workflow. Never automatically merge dependency updates solely because a newer version exists.

The [CI startup experiment](cicd-startup.md) records why the overlap candidate was rejected: its combined startup/build interval took 9m 35s versus 7m 26s for the fresh serial baseline. Routine CI retains serial setup and compilation.

### Hosted Full cancellation evidence (SHOPPING-232)

Run [37997790146](https://github.com/mggarofalo/Shopping/actions/runs/37997790146)
on `527ea1766e781b80958e92462ed7e064461db73e` exhausted the 90-minute job
budget: 9m47s before testing and 80m28s in the test step. The simulator took
182.254s and build took 390.845s. The retained summary could not read the
incomplete xcresult; quiet output did not establish completed inventory or
whether execution or finalization stalled. Do not count this run as passing.

The job ceiling remains 90 minutes. Explicit step ceilings allocate 19 minutes
to checkout/toolchain/metadata/simulator/build (2/1/1/5/10), 60 minutes to tests,
and eight minutes to raw logs/raw results/coverage/summary/timing/summary upload
(1/3/1/1/1/1), leaving three minutes for orchestration overhead. These are
failure bounds, not measured completion targets. The 60-minute test ceiling is
a diagnostic tradeoff: it can stop a progressing suite earlier than the previous
job-wide limit, but reserves time to retain its evidence. This does not establish
that hosted Full fits the budget. Choose a later budget correction from actual
progress and result evidence; do not infer hosted speed from the local M2.

The hosted test command emits normal Xcode progress. Before any xcresult reader,
`always()` uploads small raw logs and then the raw bundle as separate artifacts
(`exhaustive-logs-*`, `exhaustive-results-*`, 14 days). This also retains evidence
if later coverage or reporting fails after passing tests. Bundle compression is
disabled to bound CPU overhead; successful runs now also retain the raw bundle,
which adds storage/upload cost. Missing files after setup failure are reported
as warnings; failures and cancellations remain failures/cancellations. Report
steps each have a one-minute ceiling; summaries retain their existing 30 days.

This is best-effort evidence retention, not a guarantee after runner loss or
force cancellation. GitHub's [cancellation procedure](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation)
can forcibly terminate work. The separate small log upload prevents a large or
incomplete bundle from being the only source of diagnostic evidence. No test
selection, worker count, fixture, assertion, coverage baseline, or exact-SHA
attestation rule changes.


The exhaustive and acceptance test commands run through
`.github/scripts/with-system-text-size.py`. It supervises the unchanged
xcodebuild selection, drives real global text size on the actual runner
simulator, and restores outstanding leases before returning. Failed driver
operations or cleanup force failure even if xcodebuild exits zero. Timing/log
capture, raw-result retention, coverage and exact-SHA attestations remain in
the outer existing workflow. Deterministic driver contracts also run in CI.
