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

The shared `Shopping` scheme exposes these plans:

| Plan | Owner | Contents | Normal trigger |
| --- | --- | --- | --- |
| `ShoppingFast` | Independent deterministic coverage gate | 218 deterministic unit, persistence, recovery, filtering, and service tests | Every pull request, push to `main`, or manual Swift CI dispatch |
| `ShoppingAcceptance` | Quick product acceptance | All `ShoppingFast` tests plus 6 explicitly selected UI workflows | Same routine CI events; CI executes Fast and UI portions separately from one build |
| `ShoppingCompatibility` | Pinned-runtime diagnostic | Four existing UI workflows, serial, with cross-test OS restoration receipts | Explicit manual canary mode |
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

Follow the [authoritative staged validation sequence](#staged-validation-receipts-shopping-237)
and supported dispatch helper below after freezing the candidate. The local Full
runner verifies required exact-source CI and the pinned canary before allocating
artifacts or touching a simulator.
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
2. `-testPlan ShoppingAcceptance -only-testing:ShoppingTests -parallel-testing-enabled NO -collect-test-diagnostics never` writes `AcceptanceResults.xcresult`; the plan narrows that UI target to its explicit six methods.

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

The initial diagnostic job ceiling was 90 minutes. Explicit step ceilings allocated 19 minutes
to checkout/toolchain/metadata/simulator/build (2/1/1/5/10), 60 minutes to tests,
and eight minutes to raw logs/raw results/coverage/summary/timing/summary upload
(1/3/1/1/1/1), leaving three minutes for orchestration overhead. These are
failure bounds, not measured completion targets. The initial 60-minute test ceiling was
a diagnostic tradeoff: it could stop a progressing suite earlier than the previous
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


### Evidence-based Full budget correction (SHOPPING-219)

Run [38097940439](https://github.com/mggarofalo/Shopping/actions/runs/38097940439)
on `7165c81e8c3a3cb4ca0350ddf4dcecc16ca003ac` reached that 60-minute test
ceiling while ordinary UI actions were still progressing. Its retained log records
843 XCTest passes and 57 Swift Testing passes: 900 total, including 103 of 120 UI
methods, with no failed test assertions. One UI method was active and 16 had not
started. The incomplete result bundle cannot establish a Full pass or coverage.
Raw logs, the incomplete bundle, and bounded summaries were retained successfully.

The same remaining 17 methods took 343.819 seconds in the earlier hosted run
38080343221. Across 94 UI methods passing in both runs, summed durations rose from
2491.993 to 2952.752 seconds (18.5%). Applying that observed ratio to the remaining
inventory suggests about 407 seconds of work; this is an estimate, not a completed
measurement. Delays were spread across suites. The real-text-size driver's 60
commands totaled 91.693 seconds, with a maximum of 5.276 seconds; they were not a
stalled command or the dominant suite cost.

The test ceiling is now 75 minutes and the job ceiling 105 minutes. This retains
19 minutes for setup/build, eight for artifacts/reporting, and three for
orchestration, while allowing a progressing suite to finish near the observed
65–67-minute estimate with bounded headroom. Test inventory, assertions, serial
hosted execution, coverage baselines, and exact-SHA local attestation are unchanged.
The corrected candidate must complete the existing validation sequence; this
budget change does not convert the canceled run into passing evidence.

## Current Siri schema validation (SHOPPING-241)

`Release SDK Build` uses the standard `xcode-27` runner and Xcode 27.0 to archive
the iPhone/Watch pair and check the generated Siri metadata. It also runs
`CatalogActionTests`, `SpokenGrocerySchemaTests`, and the two modern
out-of-process action tests in `ModernSiriActionTests` on iOS 27. The dedicated
`ShoppingSiri` scheme/plan with the three explicit `-only-testing` selections
requires all 32 cases to pass (20 catalog, 10 schema, 2 native; SHOPPING-258 added
two catalog bound/failure contracts and the unknown-name handoff case; SHOPPING-266 added
three catalog and one schema case for one-time names already on the list; SHOPPING-270
added two schema cases for declined timed reminders; SHOPPING-271 added one for a
refused repeated handoff). `HOSTED_COUNTS` and `UI_TESTS` in
`siri-schema-ci.py` are the manifest. Running the plan without those filters additionally
runs the broader persistence suite. Its `ShoppingSiriTests`
UI target requires iOS 27 and exclusively links AppIntentsTesting, whose SDK
framework cannot load on the pinned iOS 26.5 Full runtime. Existing Full and
Acceptance UI targets retain their previous workflows without that dependency.
ShoppingSiri is separate required modern-system evidence, not a Full attestation.
The older Xcode 16.4
`Build & Test` job retains compatibility and coverage ownership; compiler-gated
iOS 27 code is not validated by that older job. Neither job proves Siri routing
or Apple Intelligence availability. Those require a real system invocation.
Each native case waits for the system to register the reinstalled app's App
Intents metadata before its first lookup. It waits at most 30 seconds in the
"not present" state and fails clearly if the metadata never appears (SHOPPING-262; see
[the Siri launch investigation](siri-ci-launch.md#app-intents-registration-after-install-shopping-262)).
Before each hosted and native session the runner boots its owned simulator if
needed and waits for the device's post-boot work to settle (three 5-second
intervals at or below 1.0 core), so no XCTest launch budget overlaps that work.
Readiness has one 1080-second budget and its own evidence, and fails closed. The
release and Siri diagnostic jobs allow 35 minutes so that budget fits (SHOPPING-249; see
[owned boot and settled device](siri-ci-launch.md#owned-boot-and-settled-device) and
[the budget calibration](siri-ci-launch.md#readiness-budget-calibration-october-30)).

The schema job retains installed Debug intent metadata and focused system
registration logs with 20-second command bounds on simulator operations. Capture runs in a separate `always` step, leaving the preceding test/manifest
verdict untouched. Each capture command status is retained, including errors. Verbose post-failure sysdiagnose
is disabled for this focused job; ordinary xcresult evidence and the exact
25-case assertion remain required. This addresses diagnostic loss, not a test
failure or a proof of metadata readiness.

The combined archive-and-schema job has a 35-minute budget (25 minutes until SHOPPING-249 sized the readiness budget). The previous
15-minute budget expired after an observed six-minute simulator startup, before
the modern test ran (38316984917). This budget covers setup and artifact
collection; no per-test timeout, assertion, selection or retry policy changes.
The capture step has its own three-minute limit. It observes the existing simulator
state and skips live capture if it is shut down; diagnostics never boot it.

## Compatibility canary (SHOPPING-236)

`ShoppingCompatibility` selects four existing UI methods, serially on one
simulator: PersonalCart store-picker Large/XXXL, HomeDetails restricted-membership
Large/XXXL, HomeReplacement exact replacement/landing, and CategoryManagement
anchored merge/delete destination menus. The plan is diagnostic; Fast, Acceptance,
Full, coverage ownership and exact-SHA Full gates are unchanged. It samples native
headings, full-frame membership viewport containment, outgoing invitation completion
and real Menu destinations. It does not cover the separate quantity-sheet/background
tab-bar geometry defect or replace the exhaustive workflow owners.

Run `python3 .github/scripts/run-compatibility-canary.py --simulator <owned-UDID>
--artifacts <new-absolute-directory>`. The existing timing framework records the
no-process driver gate, simulator startup, cold/warm builds, serial execution and
reporting separately. Build products are reused. Exact planned/built/executed
identifiers reject omissions, broadening, duplication and skips. Driver receipts
verify two distinct leases on the requested simulator, exact initial/restored
category across both tests, distinct fixture stores/processes/nonces and real
Large/XXXL round trips. Existing XCTest assertions retain same-process fresh
lifecycle and UIKit restoration proof. `Restoration.json` records individual host
command and host restoration costs; these do not include app activation time.

The existing Swift CI workflow accepts `compatibility_canary=true` for the pinned
Xcode 16.4/iOS 18.5 diagnostic job. Both required jobs are skipped in this mode,
so it cannot supply required CI or exhaustive preflight evidence. Selecting both
`compatibility_canary` and `siri_launch_diagnostic` runs the two independent
diagnostic jobs on separate runners; required jobs remain skipped. Normal CI
also runs the cheap canary tooling contracts. Hosted dispatch
requires explicit task authorization. Do not use Full to tune this selection.
The 30-minute job and 25-minute combined build/run ceilings are failure bounds,
not measured budgets. The proposed five-minute post-build target remains an
experiment until local and pinned measurements establish feasibility.

Declare no more than three unchanged trials per environment/configuration and
stop at the first unexplained failure. Preserve every failure and all raw evidence;
a repetition is not a retry counted as success. Local Xcode 27.1/iOS 26.5 cannot
establish pinned Xcode 16.4/iOS 18.5 compatibility. The runner retains reports under the Git
common directory's `shopping-test-timings/<SHA>/<run-id>/` after each experiment;
large result bundles and build products remain in the printed artifact directory.

The runner refuses dirty source, verifies the same clean SHA after success, and
retains the explicit plan and built xctestrun manifests. It bounds boot to five
minutes, each build and UI execution to fifteen, and reporting to one minute.
On cancellation it forwards TERM through the existing supervisors and allows
265 seconds for an in-flight setter/readback pair plus the restoration
setter/readback pair and supervision margin before a hard stop. The allowance
is derived from the driver's four 60-second operation budgets, 15-second request
margin and 10-second cancellation grace.
A timeout remains failure even if cleanup succeeds. These are containment bounds;
no native operation deadline or UI assertion timeout changes. Reporting failure
cannot replace the original test failure or turn a failed run into passing proof.

## Staged validation receipts (SHOPPING-237)

The authoritative exhaustive-candidate sequence is:

```text
clean committed candidate
  → deterministic prerequisite contracts
  → local fixture selection (25 existing methods) + local compatibility canary
  → push unchanged SHA → normal exact-source manual Swift CI (both required checks)
  → local ShoppingFull (also requires explicit pinned canary on this SHA)
  → existing local/ShoppingFull attestation
  → remote ShoppingFull, whose Ubuntu preflight repeats hosted checks
```

Run local prerequisites with `python3 .github/scripts/run-local-staged-validation.py
--simulator <exclusively-owned-UDID> --artifacts <new-directory-outside-source>`.
The existing `FixtureReadinessTests` and `HomeSharingStatusBootstrapTests` methods
remain in ShoppingFast; ShoppingFixtures selects those same 25 methods explicitly.
Its configuration, coverage setting and exclusions match Fast, and the cheap gate
checks the plan against the maintained fixture classes. The explicit plan is
necessary because Xcode 27.1 did not serialize CLI-only selection into the built
manifest: trial 4c15c01 stopped after a successful 72.913s build, before any test,
and retained its failed attempt marker. Trial 1198fa6 then built the exact 25
identifiers in 58.498s but stopped before tests because Xcode omitted the two
unselected exclusions from that manifest. The verifier permits only omissions
disjoint from the exact selected identifiers; unexpected exclusions or omissions
that affect a selected test still fail. Both failed attempts remain recorded.
The runner checks their built selection, then calls the existing four-method
canary. It retains small receipts in the Git common directory under
`shopping-staged-receipts/<SHA>/{fixtures,canary}/`. Raw artifacts stay at the
requested location. Before gates or native work, the supported local runner writes
a per-SHA running attempt marker and acquires an exclusive directory lock. Failed,
cancelled or still-running attempts block dispatch, including explicit paths to
older passing receipts. Success binds both receipt digests and their current
attempt UUID. Each attempt's final record is retained; this does not discover
arbitrary manual xcodebuild runs. A crash leaves the lock/marker fail-closed. After
confirming that attempt's process has stopped, remove only its stale `attempt.lock`
directory and rerun the supported local stage; removing a lock does not turn a
running/failed marker into a pass. This does not replace broader affected callers when a change
has proof owners beyond these shared boundaries.
Supported dispatch holds that same exclusive lock from receipt validation through
GitHub dispatch. Both Full entrypoints reserve it before local receipt validation
and retain it through hosted preflight and allocation; local Full holds it until
execution finishes. An opaque owner token permits EXIT cleanup across the shell
and Python boundary. A different token cannot release the reservation. Early
errors preserve the previous validation record, while a crash leaves the lock
closed until its owner is confirmed stopped. This prevents a concurrent supported
local attempt from invalidating receipts between the check and allocation.


Supported manual dispatch is `python3 .github/scripts/staged_validation.py dispatch
--stage canary --fixtures <Fixtures-directory> --canary <Canary-directory>`.
Use `--stage ci` for routine manual CI; a hosted canary is not required for that
routine path. Candidates proceeding to Full additionally need `--stage canary`;
the hosted canary and normal CI may finish in either order. Each entry point runs
the cheap contracts, verifies both local receipts and the clean pushed SHA, and
stops before `gh workflow run` on failure. The existing local Full and remote
Full helpers require the retained local receipts, cheap contracts, pinned canary
and exact-source required CI; remote Full still requires the local Full status.
Do not dispatch ordinary CI, a PR, and a focused diagnostic for each experiment.
Use focused diagnostics while investigating, then one normal manual CI run for
the frozen candidate. Routine Fast and Acceptance continue sharing one build;
the modern release/Siri toolchain remains a separate required native job.

### Trust and bypass boundaries

A receipt binds schema/gate implementation and selection digests, exact clean
commit SHA, test plan, built xctestrun, executed identities/results, Xcode/runtime,
ordered successful phases, source verification, and artifact hashes. Canary
receipts also bind the driver log and independent restoration proof. Missing,
changed, stale, dirty, skipped, failed or incomplete evidence is rejected.
The runtime/toolchain pair is explicit in `.github/staged-validation.json`;
changing it requires new evidence. Equal source trees or report copying never
transfer proof to another SHA.

The local fixture runner invokes the existing canary in-process, so parent-only
SIGINT/SIGTERM reaches its active phase supervisor and restoration path. Supported
dispatch commands always use this repository as their working directory and pass
`expected_sha`. Ubuntu compares it with the resolved workflow SHA before native
allocation; a remote branch advance after local validation cannot run a different
candidate with the old receipts. Full dispatch requires that input; ordinary raw
manual CI may omit it but still runs hosted cheap prerequisites.

Local hashes establish integrity, not authenticity. A developer-local report can
only satisfy a local prerequisite; it never creates a hosted success status.
Pinned evidence must come from GitHub's exact-source manual Swift CI run, the
successful named canary job, and that run's unexpired artifact. The downloaded
receipt must identify that run and the actual selected job attempt. A later normal
run's skipped canary does not hide a prior canary; a newer relevant failed,
cancelled, skipped or unfinished canary prevents reuse. A partial rerun may retain
a successful canary from an earlier attempt of the same run, just as existing
required-job preflight permits. Staged Full preflight selects the latest normal
exact-source CI run, ignoring only the two explicitly named diagnostic run titles;
a later normal failure/cancellation/in-progress run still blocks an older pass.
Ordering uses `run_started_at`, which GitHub's [official OpenAPI schema](https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.json)
defines as resetting on rerun. Retained canary jobs use their actual attempt's
start time, so rerunning only Siri cannot refresh an old canary. A later failed,
queued or in-progress attempt of an older run blocks prior proof; ambiguous tied
failures fail closed. Read-only verification of historical run 37716058310 found
attempt 1 at 02:04:21 UTC and attempt 2 at 02:19:56 UTC on October 8, while its
creation timestamp stayed unchanged. One successful normal run must supply all positive cheap/native/aggregate proofs.
Their retained job `started_at` values are compared with every adverse
prerequisite event across relevant normal runs and attempts. A success in a
different run cannot rehabilitate a selected run's stale prerequisite; only its
own newer successful job can supersede the adverse event. A later failed or unfinished native/cheap job
cannot be hidden by refreshing only an older run's aggregate or unrelated job;
no positive proof is assembled across runs. Thus a canary after normal CI does not
force duplicate broad CI. Existing local
Full attestation trust is retained;
it additionally needs independently verified hosted canary and required CI.

Every Swift CI macOS job depends on cheap Ubuntu contracts, so bypassing the
local dispatch helper cannot bypass the cheap hosted prerequisite. A local receipt
cannot be authenticated on GitHub and is not represented as a hosted success.
PR/main-push CI keeps its normal trigger and runs cheap contracts before its
unchanged native coverage. Pinned canary evidence is additionally required only
for Full; routine manual CI does not acquire a separate 14-minute hosted job.
Exhaustive Ubuntu preflight independently repeats cheap, pinned-canary,
exact-source CI and local-Full-status checks before its macOS job.

The required checks remain `Build & Test` and `Release SDK Build`, now Ubuntu
aggregate jobs depending on cheap validation and their respective native jobs.
They use `always()` and fail on failed, cancelled or skipped prerequisites; this
avoids GitHub treating skipped required checks as passing when a cheap gate fails.
Diagnostic mode uses different aggregate names before skipping them, so it cannot
manufacture either required check. The live ruleset is unchanged. Historical
preflight interfaces retain their old job names; the new staged path additionally
requires both native jobs. Cancellation never produces a passing aggregate.

### Measured evidence and limits

The prior SHOPPING-236 candidate `6e1bd27` provides this observed baseline, not
validation of the new receipt implementation:

| Environment/path | Serial test command | Build | Simulator | Whole hosted job |
| --- | ---: | ---: | ---: | ---: |
| Local Xcode 27.1/iOS 26.5, clean candidate | 122.103s | 44.832s empty DerivedData; 2.300s warm | 0.407s already booted | Not hosted |
| Hosted Xcode 16.4/iOS 18.5, run 40722818410 | 264.618s | 367.872s cold; 13.352s warm | 76.164s | 849s (14m09s; 14.15 macOS runner-minutes) |

Hosted phase sums exclude setup/simulator creation and an approximately 55-second
post-boot/pre-build gap including the initial unphased content-size read. They
must not be reported as whole-job duration. The local/hosted five-minute post-build
samples establish feasibility only, not sustained tail latency.

The controlled failing-dispatch contract injects failure at the cheap prerequisite
and observes zero GitHub mutations and zero macOS allocations through fake process
and API boundaries. Its measured latency is printed in the test evidence. This
proves dispatch ordering; it is not a measured production runner-minute saving.
The development cheap-gate run measured 1.189 seconds locally (all prerequisites
passed; `/tmp/shopping-237-gate-phases.jsonl`). This was an uncommitted development
measurement, not final-candidate evidence; record the reviewed candidate separately. No broad speedup, duplicate-run saving, or successful new native path
is inferred from these deterministic checks. Failed historical Full runs are the
motivation, not an equivalent-inventory before/after benchmark. Native and hosted
confirmation remain separately coordinated, and Full is never dispatched to tune
these gates.

The rejected design would have required a standalone pinned canary before every
routine manual CI run. The prior sample indicates an additional 849 seconds and
14.15 macOS runner-minutes for that clean path, including another cold build.
That requirement was not adopted. This is an avoided design cost, not a measured
production saving. No baseline compiler, Fast coverage, acceptance or Full gate
was removed. The additional pinned canary applies only when proceeding to Full.

Semantic workflow validation is required before native confirmation after workflow
edits. Run `actionlint -shellcheck="" .github/workflows/swift-ci.yml
.github/workflows/swift-exhaustive.yml`, adjusting the file list to changed
workflows. `.github/actionlint.yaml` recognizes the existing `xcode-27` label.
This check complements YAML parsing and deterministic shell/selection contracts;
it is not downloaded or required on every staged gate invocation.

The supported dispatch for `a239532` was rejected with GitHub HTTP 422 before a
workflow run existed or a runner was allocated: `cancelled()` had been used in
step environment expressions. Its local 25-fixture/four-canary pass remains
historical evidence for that SHA. Checksum-verified official actionlint 1.7.12
reproduced both expression-context errors in the rejected workflow. After
`7ee53f2` moved cancellation handling to explicit step `if` conditions, actionlint
passed both changed workflows. This negative/positive check validates workflow
syntax, not hosted execution, and does not transfer native proof to a new SHA.

### Acceptance cancellation evidence (SHOPPING-251)

[Run 40748443094](https://github.com/mggarofalo/Shopping/actions/runs/40748443094)
passed all 816 Fast tests with zero skips and passed coverage. Acceptance began
at 19:03:14 UTC, announced its result path at 19:03:19, and was cancelled at
19:18:49 after the native job reached its existing 30-minute limit. Quiet output
and the absence of a readable result bundle left no evidence distinguishing a
launch, execution, or finalization stall. The command, six-test selection, and
job ceiling matched `95aa72a`; no phase-induced cause was established. This run
remains failed, and it does not justify increasing the timeout.

Acceptance now emits ordinary Xcode test progress through the existing streaming
log recorder. The selection remains six methods, with unchanged assertions,
serial execution, and job limit. Before the post-test summary and timing readers,
failed or cancelled validation uploads small raw logs in a separate one-minute
step, followed by available raw result bundles and built selections in a
separate two-minute step. Incomplete bundles need no successful parsing to be
retained. Result compression is disabled to avoid spending CPU on compression;
artifacts retain the existing 14-day lifetime. Successful runs do not upload
these large raw artifacts. A later reporting failure uploads them only if the
early result upload was skipped, preserving the previous failure evidence path
without uploading a bundle twice.

The explicit `failure() || cancelled()` status expression includes cancellation
without GitHub's implicit success requirement. It does not turn a failed or
cancelled job into a pass. The [GitHub cancellation procedure](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation)
re-evaluates conditions and may forcibly stop remaining work after five minutes.
The three-minute early upload allocation is therefore best-effort retention,
not a guarantee after force cancellation, runner loss, or a large artifact that
cannot finish within its bound. Small logs are attempted first so an incomplete
bundle upload cannot be the only source of progress evidence.


### Routine acceptance diagnostic collection (SHOPPING-145)

Only the routine acceptance invocation disables Xcode's automatic diagnostic
collector with `-collect-test-diagnostics never`. The [single-workflow
comparison](shopping-full-runtime.md#routine-acceptance-diagnostic-tail-shopping-145)
reproduced a 600-second collector timeout after a passing test, then retained
the same runtime warning without that tail when collection was disabled.
This is a collection-policy change, not a fix for the warning or collector.

Test progress, runtime warnings, assertions, failure screenshots/attachments,
coverage and xcresult writing retain their existing settings. Automatic
simulator diagnostic archives are no longer collected for routine acceptance;
that evidence tradeoff does not disable XCTest warning detection. The existing
SHOPPING-251 one-minute raw-log and two-minute available-result uploads retain
failure/cancellation evidence before readers, including incomplete bundles.
They remain best effort. No extra post-test collector is introduced.

The exact six workflows, serial execution, native assertion timeouts, 30-minute
job ceiling, failure/cancellation propagation and no-retry policy are unchanged.
Fast, Siri diagnostics, compatibility canaries and local/hosted Full retain their
existing collection settings and validation gates. Pinned hosted acceptance
must validate this policy on its own candidate; the local one-test comparison
is not evidence of a whole-suite or hosted time saving.


### Isolate Siri hosted and UI sessions (SHOPPING-249)

Run `40779521379` passed the 21 hosted contracts, but the subsequent UI launch
requested a background assertion for retired host PID 50365 after Xcode launched
new app PID 51058. The old host had already exited successfully; the assertion was
rejected in 8 ms, before Siri action execution. Passing runs `40776593934` and
`40774419389` either started with no app PID or cleared an intermediate PID before
asserting the current process. These traces identify stale process selection,
but do not establish where the delayed state originated.

The controlled candidate builds the three explicit selections once, then runs the
21 hosted contracts and one native UI test in separate `test-without-building`
invocations. Both use the same owned simulator, serial execution, plan, and
explicit DerivedData directory. This changes IDE session lifetime while holding
simulator state and test inventory fixed. It adds no retry, sleep, or relaxed
timeout. A successful experiment establishes compatibility, not a reliability
cure. It does not address the separate hosted service-hub delay observed in
`40780173582` or the earlier Accessibility bootstrap timeout.

`SiriRegistration/Verdict.json` records each phase command, exit status and elapsed
time. Build and hosted logs and all raw phase result bundles stay under
`SiriRegistration`, which both workflow callers already retain. The native stream
remains `SiriSchema.log`; launch observation applies only to that invocation.
A failed phase stops subsequent execution and preserves its exit status even if
inventory export fails. Inventory exports and result merging use the same process-
group supervisor as test execution, with their existing 20-second command bound;
SIGINT/SIGTERM cleans owned children and returns 130/143. Cancellation stops later
phases. If a test already failed before export was cancelled, that original test
failure remains authoritative. Worker-thread launch sampling keeps its existing
bounded diagnostic path, which does not install main-thread signal handlers.
Each test phase must contain exactly its passing selection, with no skips or
duplicates. After both pass, `xcresulttool merge` produces `SiriSchema.xcresult`;
its 22-case inventory must equal the union of the two executed manifests. Merge
or inventory failure fails validation. Partial raw bundles remain available if
no combined bundle can be produced. Independent review and a declared native
diagnostic are required before adopting this candidate; no native result is yet
claimed for the split.

The first split-session hosted diagnostic, run `40783837065` on clean
`fff80fb111c417fd93af91a3485abe4f999b0a7e`, passed all 21 hosted and one native
case with zero skips. Per-phase and merged-inventory guards passed. Build took
96.360 seconds, hosted execution 306.465 seconds, and native execution 242.730
seconds. This validates native invocation and merge compatibility on that SHA;
it does not establish a speedup or cure the intermittent stale-process failure.
The final integrated candidate still requires ordinary CI.
