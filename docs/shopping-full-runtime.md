# ShoppingFull runtime investigation (SHOPPING-108)

This report distinguishes historical full-run evidence from matched optimization benchmarks. Historical timings establish where time goes; matched measurements determine whether a change improves runtime. The committed [benchmark evidence](benchmarks/shopping-108.json) records test identifiers, product revisions, run order, environments, results, and raw artifact paths.

| Baseline | Commit | Xcode | Tests | Result | xcresult wall |
| --- | --- | --- | ---: | --- | ---: |
| local-main | `edafe1ca0cf2` | 27.0 (27A266a) | 282 | 282 passed / 0 failed | 2785.088s |
| local-phase17 | `1179e39bd5b9` | 27.0 (27A266a) | 284 | 284 passed / 0 failed | 2876.042s |
| hosted | `1179e39bd5b9` | 16.4 | 284 | 283 passed / 1 failed | 3186.331s |

Hosted run: https://github.com/mggarofalo/Shopping/actions/runs/35907303910

Hosted job phases: simulator 150s; build 149s; test command 3205s; job 3557s. The result-bundle test interval is 3186.331s.

## Historical bottlenecks

- GroceryEditingUITests: 835.92s across 11 tests
- ShoppingLaunchTests: 696.82s across 18 tests
- OneTimePromotionUITests: 410.50s across 4 tests
- ChecklistUITests: 337.28s across 10 tests
- CategoryManagementUITests: 296.52s across 7 tests
- ShoppingDeviceUITests: 238.62s across 10 tests
- CatalogRefreshUITests: 133.62s across 5 tests
- ShoppingAppearanceUITests: 82.87s across 3 tests
- ClearInterruptionUITests: 58.54s across 1 tests

## First focused improvement

`ShoppingTests/ShoppingLaunchTests.swift:861-870` sends separate automation commands for each remaining character after select-all/delete. Empty fields can expose their placeholder as value, causing unnecessary deletion attempts. The longest hosted case takes 148.849s. Its 105 top-level individual delete calls account for 44.110s; app launch accounts for 3.353s; 184 accessibility lookups account for 20.628s. This is interval attribution from ordered top-level xcresult activities, not CPU sampling.

The retained change batches exactly the same fallback delete characters into one `typeText` call, as already used by `ShoppingTests/OneTimePromotionUITests.swift:245-250`. The two selected tests passed before and after: 219.33s versus 169.74s command wall time (22.6% less). Individual case durations fell from 141.156s to 104.591s and from 61.631s to 50.466s. The fallback and all assertions remain.

## Reveal metadata reuse

The second focused change reuses metadata within each `GroceryEditingUITests.reveal` attempt instead of repeating the same accessibility queries. Visibility, hittability, scrolling, and all assertions remain. For `testStoreDefaultDoesNotOverwriteAnExistingItemsRules`, command wall time fell from 150.00s to 140.99s (6.0%), and case duration fell from 114.262s to 106.664s (6.6%). Both runs passed. This is a modest improvement in one paired sample; it does not establish a stable percentage improvement for the full suite.

## Positive existence checks

The same grocery case issued 25 positive polling waits after metadata reuse. XCTest often waited about a second before its first existence check, even when the element was already present. `XCUIElement.existsOrAppears(timeout:)` checks `exists` first, then falls back to the original `waitForExistence` and timeout. Existence does not establish hittability, visibility, or a settled interface; those separate assertions and interaction safeguards remain.

With this change, the case passed in 89.488s versus 106.664s (16.1% less), and command time fell from 140.99s to 124.95s (11.4%). Only six polling waits were needed; the other positive checks found their elements immediately. A preceding serial repetition of the baseline case took 105.522s. Builds were separate from these test-without-building measurements; the candidate used a fresh DerivedData directory with the same compiler, runtime, destination, and test selection.

The helper is shared across positive existence assertions in the full UI suites. Negative existence assertions, optional probes, disappearance waits, recovery process-state waits, and the separate performance flows retain their original behavior. No timeout, assertion, test, or deliberate app launch was removed. The final exhaustive run is required to validate this broader application; the focused result alone does not establish a full-suite percentage saving.

The two catalog cases also passed after the shared-helper expansion: 82.523s and 36.824s, versus 104.591s and 50.466s after deletion batching alone. Command wall time fell from 169.74s to 152.29s (10.3%). These commands have variable runner installation, startup, and teardown overhead, so report the command and case measurements together. Relative to the original two-case baseline, the combined changes reduced command time from 219.33s to 152.29s (30.6%); this remains a focused comparison, not a suite-wide estimate.

## Parallel isolation and reuse

- All ordinary UI fixture launches use UUID filenames; source examples: Launch575, Grocery346, OneTime171, Checklist299, Category267, CatalogRefresh173, Device396, Appearance8/53/90, Clear8.
- No UI test changes XCUIDevice orientation or declares global/static mutable state. Content size and appearance overrides use per-process launch arguments. Persistent appearance test restores System using defer (`ShoppingAppearanceUITests.swift:93`).
- Native Xcode workers on separate simulator clones isolate app processes and preference domains. Never run concurrent UI automation against one shared simulator. Retain each test’s intentional relaunch and SQLite path; reuse built products only.
- App UserDefaults remain per-simulator app scoped (`Shopping/App/GroceryNavigationState.swift:29`). Parallel full validation must establish absence of hidden ordering assumptions. Native two-worker execution would avoid duplicate GHA jobs/builds and preserve one xcresult and the existing attestation preflight; the measurements below do not justify enabling it by default.
- Test methods remain indivisible. The 835.9s GroceryEditing class dominates coarse class-level scheduling, so worker imbalance and boot overhead limit speedup. More than two workers requires a new benchmark and memory/CPU evidence.

## Two-worker experiment: serial default retained

The short four-test sample covers a catalog save, interrupted-clear recovery, appearance persistence, and people persistence. All four passed in every run. Serial command wall time was 154.98s; two native simulator workers took 163.09s, then 749.21s on repetition. The repeated run reported a 600-second simulator diagnostic collection timeout after the test processes completed. Per-test durations remained similar. These short samples do not establish a parallel speedup, and the timeout is not specific to parallel execution: the serial appearance validation below encountered it too.

A longer four-test selection completed serially in 347.79s with all tests passing. With two workers, the scheduling log runs from 17:41:08 to the last worker finishing successfully at 17:44:56: approximately 228s. All four cases passed: catalog create/cancel 109.416s, archived-catalog restore 51.688s, interrupted-clear recovery 53.274s, and grocery purchase rules 107.879s. The workers then exited with code 0, and `simctl diagnose` began collecting both simulator clones with a 600-second timeout. The command finished successfully in 861.39s, including the 600-second diagnostic collection timeout.

The approximately 228s scheduler interval is not directly comparable to the serial command wall time: command startup and diagnostic collection lie outside it. It shows why native parallelism may help long suites, but these experiments have not established a reliable whole-command improvement. Keep serial execution as the default. Reconsider two workers after representative measurements show reliable total command time, with collector overhead reported separately. The same collector stall occurred serially, so the evidence does not identify parallelism or interrupted-clear recovery as its cause.

The timestamped scheduler log and four passing case lines are preserved in `/tmp/shopping-108-evidence/long-parallel-scheduling-evidence.txt`; the original result bundle remains intact.

## Diagnostic collection overhead

The corrected appearance test passed in 126.358s under serial execution, but its command took 746.86s and reported a 600-second diagnostic collection timeout. The test runner confirmed the end of its session in 0.001s and exited with code 0. Xcode logged `_finishWithError:(null)` and that it was still waiting for asynchronous diagnostics.

A one-second sample of the waiting `simctl diagnose` process found a worker blocked in `NSConcreteTask waitUntilExit` and another in a dispatch-group wait. A process listing at the time showed no live direct child. Diagnostic files had stopped changing, and `diagnose.log` was empty. The sample is retained at `/tmp/shopping-108-evidence/simctl-diagnose-sample.txt`.

This evidence locates the delay in post-test CoreSimulator diagnostic collection. It does not establish the underlying task-completion cause or an application defect. The same overhead affects serial and parallel commands, so compare test execution and command wall time separately. Keep failure diagnostics enabled; disabling them would remove useful evidence rather than fix the collector. The sample and result bundle provide a concrete basis for a separate tooling investigation or an Apple bug report.

## Reliability prerequisite

The unchanged main branch has the same vulnerable appearance tap as Phase17. The focused `d5ae39ad8053722410a6f71ebfc3dd013c9b834a` patch checks full bottom-edge visibility and hittability, scrolls when necessary, and adds assertions. Copying this fix independently preserves coverage and does not modify Phase17. Keep its runtime effects separate from optimization claims.

## Validation exposed a feedback obstruction

The first committed local candidate, `19a4ccc00aea34b170839a421fa912d54bb1e0b4`, failed two clear-recovery routes at the Checkout tap. Faster positive assertions reached that circular button while the three-second cart feedback toast still occupied the same bottom area. The session logs recorded corner hit points `{324,726}` for both failed taps, versus center points `{352,754}` for passing Checkout taps. Hittability alone did not ensure that the chosen point activated the circular control. This is evidence against treating existence checks as a transition or obstruction wait.

The repair adds bounded disappearance assertions for the exact `Weekend ice moved to In cart.` and `Fresh ice moved to In cart.` messages before the Checkout interactions. It retains every existing assertion, the single tap, forced process exit, relaunch, identity check, restored notes, and catalog-isolation checks. No sleep, retry, or assertion removal is used. The failed run remains in timing history and receives no local attestation; the corrected commit requires fresh local and hosted validation. Session excerpts are retained in `/tmp/shopping-108-evidence/checkout-obstruction-evidence.txt`.

The first full attempt completed with 280 passed, two failed, and no skipped tests; the command returned 65 and the timing framework retained its failed history without creating an attestation. The repaired two-case selection passed completely in 101.86s command time (43.655s and 41.302s per case). These are correctness validation results, not performance comparisons against the aborted failed cases. Both attempts are recorded in the benchmark JSON.

[SHOPPING-109](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/02528008-9153-4102-a3a4-78560164d00a) separately tracks the pre-existing product hit-testing question. The current evidence supports obstruction as an inference; direct visual/manual confirmation and any toast interaction-policy change remain outside this runtime work.

## Hosted validation exposed navigation ambiguity

Candidate `4e2b9d4126a82f74ccf5a4f97a900a6d23f1c6c9` passed all 282 local tests. Its result interval was 2059.294s (34m19s), 26.1% below the historical main interval of 2785.088s (46m25s); the test command took 2061.758s. Independent review verified identical test identifiers. This is a historical single-run comparison on Xcode 27.0 / iOS 26.5, not a repeated controlled full-suite benchmark.

The exact-SHA [hosted confirmation](https://github.com/mggarofalo/Shopping/actions/runs/35933324845) then reported 281 passes and one failure in `ChecklistUITests/testCartInheritsGroceryScopeAndCheckoutCapturesVisibleItems`. Reading `shopping.store.menu.label` matched two Publix buttons in separate collection views after navigation. Both screens use the same scope control; destination navigation-title existence alone does not prove the outgoing content has left the accessibility snapshot. The test activity checked the destination title about 0.56 seconds after the tap and read the menu about 0.77 seconds after it. The initial sparse failure snapshot contained two menus, while the final failure hierarchy about 1.67 seconds after the tap contained one collection view and one menu: direct evidence that this ambiguity settled during failure reporting. The repair adds a bounded uniqueness assertion before the existing menu-label assertions at both navigation boundaries. It retains the separate expected labels and every filtering, checkout, undo, and recovery assertion; it does not select an arbitrary first match or filter away an incorrect value.

The failed hosted test command took 2471.175s, simulator startup 160.501s, and build 213.125s. Coverage passed unchanged thresholds (app 87.59%, deterministic logic 96.36%), and complete timing reports exported without warnings despite exit 65. These timings are diagnostic evidence, not an accepted passing performance comparison. The corrected commit requires another exact-SHA local pass before remote confirmation.

The repaired complete workflow passed three fixed local iterations with fresh test-runner processes: 30.382s, 29.708s, and 29.699s; the command took 101.455s. No retry-on-failure option was used. This validates the correction on local iOS 26.5; fresh full local and pinned hosted validation remain required. The result bundle and repetition nodes are recorded in the benchmark JSON.

## External runtime expectations

The research found no credible universal runtime budget tied to low-to-medium app complexity. Workflow depth, accessibility queries, waits, launches, host/toolchain, coverage, and concurrency are more informative than app size or total test count.

- [Wirex's firsthand account](https://hackernoon.com/how-to-implement-ios-ui-testing) reports 21 UI tests in eight minutes, with individual cases taking 13–34 seconds.
- [Grab Engineering](https://engineering.grab.com/tackling-ui-test-execution-time-imbalance-for-xcode-parallel-testing) reports roughly half its UI tests taking 20–40 seconds, and longer multi-flow cases reaching two minutes.
- [Wealthfront's partitioning report](https://eng.wealthfront.com/2021/02/05/halving-ios-test-time-with-partitioning-in-jenkins-pipelines/) describes 90 UI tests exceeding 90 minutes before three Mac Mini agents reduced the job to about 40 minutes. This is an optimization case study, not an acceptable-time standard.
- [Wealthfront's wait investigation](https://eng.wealthfront.com/2025/03/17/how-we-sped-up-ios-end-to-end-tests-by-over-50-with-40-lines-of-code/) reports a greater-than-50% improvement from reducing polling overhead, while overly aggressive polling overloaded parallel hosts. It supports measuring waits rather than blindly copying a polling interval or improvement percentage.

These examples differ in age, app scope, machines, coverage, and build accounting. Shopping's historical 67 UI methods averaged 40.7 seconds, while 215 non-UI methods totaled about 12 seconds; sums are not elapsed wall time. Provisional planning goals are 35 minutes for local test execution and 45 minutes hosted / 50 minutes for the whole hosted job. These are engineering targets to calibrate against passing runs, not industry norms or CI gates. Collect several naturally authorized passing runs before setting reporting thresholds; do not run extra full suites just to populate statistics.

## Caveats

- Phase17 has 284 tests; main historical baseline has 282. Do not claim exact paired comparison across these revisions.
- Hosted baseline failed offscreen tap and aborts remaining loop iterations; not a passing runtime baseline.
- Local results and attestations establish Xcode 27.0, overriding supplied recollection of 26.6.
- Swift Testing suite wrappers can cause reported durations unlike sequential XCTests; raw testcase sums must not replace wall time.

## Evidence locations

The raw historical artifacts remain outside Git because complete result bundles are large:

- Hosted baseline: `/tmp/shopping-107-full-failure/ExhaustiveResults.xcresult`, downloaded from run `35907303910`; its build and test logs are in the same directory. Original published summaries are under `/tmp/shopping-107-full-summary`.
- Local main baseline: `/var/folders/46/rfm__t390_j4__pjgy20q29m0000gn/T/shopping-full-edafe1ca0cf2bc4254bf4f3968ff0f149f24beec.jNfh7S.xcresult`.
- Local Phase 17 baseline: `/var/folders/46/rfm__t390_j4__pjgy20q29m0000gn/T/shopping-full-1179e39bd5b95a7007cef9fd7ef90626cf1a3f9e.66xCJU.xcresult`.
- Exported per-test trees, summaries, sampled activity tree, GitHub run metadata, and compact machine-readable analysis: `/tmp/shopping-108-evidence/`. `baseline-analysis.json` records exact SHAs and source bundles. `hosted-download/` contains a fresh download of the original hosted summary artifact.
- Local compiler metadata comes from `.git/shopping-full-attestations/<SHA>`; simulator metadata and test counts come from each result bundle.

## Matched benchmarks and final validation

The completed paired samples are recorded in [the benchmark JSON](benchmarks/shopping-108.json):

| Focused change | Tests | Baseline wall | Candidate wall | Result |
| --- | ---: | ---: | ---: | --- |
| Batched fallback deletion | 2 | 219.33s | 169.74s | Both selections passed |
| Reveal metadata reuse | 1 | 150.00s | 140.99s | Both selections passed |
| Positive existence check | 1 | 140.99s | 124.95s | Both selections passed |
| Shared positive checks in catalog cases | 2 | 169.74s | 152.29s | Both selections passed |

The longer serial selection passed in 347.79s. Its native two-worker counterpart also passed all four cases, but took 861.39s command wall time including a 600-second diagnostic collection timeout. Final exact-commit local and hosted full-run results belong in the Phase 18 PR and Plane issue, with their SHA, counts, timing artifacts, coverage, and Actions links. Keeping those completion records external lets the candidate retain the same SHA from local attestation through remote confirmation. Compare the 282-case main inventory separately from the 284-case Phase 17 inventory, and distinguish command wall time from per-test time when diagnostic collection stalls.

## Workflow recommendations

Keep the existing exact-SHA local-pass requirement and remote attestation preflight. Preserve failed test results, coverage collection and baselines, recovery relaunches, and all assertions. Retain the serial runner. The short two-worker sample was slower, and the longer selection has not established a reliable whole-command improvement despite shorter worker scheduling. Native parallelism remains promising for long suites; reconsider it with repeatable total command measurements and collector overhead reported separately. The intermittent diagnostic timeout also occurs serially, and hosted performance remains toolchain-specific.

A GitHub Actions matrix would multiply hosted runner allocation and repeat setup/build work unless build products were explicitly transferred. Treat expansion to multiple hosted jobs, automatic exhaustive runs on every push, or removal of the local exhaustive gate as separate workflow-policy proposals requiring approval. This issue provides no evidence supporting those policy changes. Prefer the existing infrequent exact-commit remote confirmation while collecting timing history.

Remaining costs include unavoidable UI interactions and accessibility snapshots, deliberate fresh fixture launches and recovery relaunches, simulator boot and compilation, and scheduling imbalance between long test classes. Do not remove these checks or share mutable app state between tests merely to reduce elapsed time.
