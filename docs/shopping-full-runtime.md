# ShoppingFull runtime investigation (SHOPPING-108)

The [Phase 33 complete-suite comparison](#phase-33-two-native-workers-on-the-m2-shopping-228) supersedes the historical serial-default recommendation below: two native workers reduce measured local test-command time by 42.5%, with an explicit serial fallback.

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

Keep the existing exact-SHA local-pass requirement and remote attestation preflight. Preserve failed test results, coverage collection and baselines, recovery relaunches, and all assertions. The original SHOPPING-108 evidence supported retaining the serial runner; SHOPPING-228 below supersedes that local-default decision. The short two-worker sample was slower, and the longer selection has not established a reliable whole-command improvement despite shorter worker scheduling. Native parallelism remains promising for long suites; reconsider it with repeatable total command measurements and collector overhead reported separately. The intermittent diagnostic timeout also occurs serially, and hosted performance remains toolchain-specific.

A GitHub Actions matrix would multiply hosted runner allocation and repeat setup/build work unless build products were explicitly transferred. Treat expansion to multiple hosted jobs, automatic exhaustive runs on every push, or removal of the local exhaustive gate as separate workflow-policy proposals requiring approval. This issue provides no evidence supporting those policy changes. Prefer the existing infrequent exact-commit remote confirmation while collecting timing history.

Remaining costs include unavoidable UI interactions and accessibility snapshots, deliberate fresh fixture launches and recovery relaunches, simulator boot and compilation, and scheduling imbalance between long test classes. Do not remove these checks or share mutable app state between tests merely to reduce elapsed time.

## Phase 33 release validation boundaries (SHOPPING-219)

The exact local candidate `97370ca3e29cc36c48189858b1db147a68d381e5` completed with 915 passes, two failures, and no skips on Xcode 27.0 / iOS 26.5. Exit 65 produced no attestation. The result is `/var/folders/46/rfm__t390_j4__pjgy20q29m0000gn/T/shopping-full-97370ca3e29cc36c48189858b1db147a68d381e5.VFdUar/Results.xcresult`; durable reports are in `.git/shopping-test-timings/97370ca3e29cc36c48189858b1db147a68d381e5/20261009T152216Z.SiqXWC/`.

`HomeSharingStatusUITests` failed its final XXXL transition. The native slider reported exactly 100%, but fresh same-process metadata and the recording both showed accessibility XXL. Successful and failed slider gestures had identical coordinates and timing, so this does not establish a short drag or stale observer. Direct-tap experiments failed to change the native slider and were discarded (`/tmp/shopping-phase33-ui-boundaries-fixed.xcresult` and `/tmp/shopping-phase33-slider-track-tap.xcresult`). The retained change leaves Larger Text through its native Back button before reactivating Shopping, and explicitly reopens that page for the next edit. The full focused workflow passed in 117.209 seconds in `/tmp/shopping-phase33-settings-finish-edit.xcresult`. Intermediate Settings-update propagation is a hypothesis, not a proven OS root cause. Exact category, process, sequence, uptime, and original-setting restoration remain required.

`ShoppingLaunchTests.testDirtyArchivedCatalogRestoreConfirmationCancelKeepsEditorDraft` tapped a Restore row at `(201,493)` while the keyboard toolbar occupied y491–539. The helper's fixed keyboard inset incorrectly accepted the row as unobstructed. The correction dismisses the keyboard using the editor's Done control, waits for disappearance, and then performs the single Restore tap. Cancellation leaves the name field offscreen, so a bounded scroll exposes it before the original exact draft-value assertions. The corrected workflow passed in 27.348 seconds in `/tmp/shopping-phase33-ui-boundaries-fixed.xcresult`; the earlier keyboard-only attempt's offscreen-field failure remains in `/tmp/shopping-phase33-restore-keyboard-fixed.xcresult`.

These are correctness experiments, not runtime improvements or suite-wide speed comparisons. The final consecutive selection passed all three workflows (Homes accessibility, sharing-status text transitions, and restore cancellation) in `/tmp/shopping-phase33-ui-boundaries-final.xcresult`, with 210.925 seconds of summed test duration and 227.118 seconds of test-session elapsed time. The new exact-commit local/hosted full results and release receipts are recorded in SHOPPING-219 so the attested candidate can remain unchanged.

## Phase 33: two native workers on the M2 (SHOPPING-228)

The complete matched comparison supports two workers for the maintained local Full runner. On this Mac14,9 with 10 CPU cores and 16 GiB RAM, test-command wall time fell from **64m49s to 37m17s**, saving **27m32s (42.5%)**. Both runs passed the same **917 unique tests: 797 Fast and 120 UI, with no failures or skips**. The [benchmark record](benchmarks/shopping-228.json) preserves complete identifiers, commands, source/environment metadata, phase timings, coverage and sampled resource costs.

| Measurement | Two workers | Serial |
| --- | ---: | ---: |
| Test command, including startup and teardown | 2,236.780s | 3,888.536s |
| Requested base simulator preparation | 0.121s | 5.989s |
| Shopping.app covered lines | 42,709 / 49,612 (86.086%) | 42,707 / 49,612 (86.082%) |
| UI test-bundle covered lines | 7,962 / 8,559 | 7,962 / 8,559 |
| Sampled host free-memory percentage range | 27–57% | 41–74% |
| Sampled host swap-out counter increase | 222,552 pages | 0 pages |

Source was clean `39026e31478945fbf149585992f1946c89f24e3c`, Xcode 27.0 (27A266a), iOS 26.5 (23F77), with the same requested iPhone 17 Pro destination. One fresh DerivedData build-for-testing took **38.976s**, then both runs reused those products with test-without-building. Build time is separate and was not repeated for the serial comparator. This is a warm-host experiment, not a cold-machine compilation benchmark. The parallel run was first, followed immediately by serial; one fixed-order pair establishes an observed improvement, not a distribution of runtime or failure probability.

The parallel command explicitly enabled two workers; serial explicitly disabled parallel testing. Native Xcode scheduling used separate simulator clones, with one result bundle and merged coverage. UI class durations sum to approximately 2,073s and 1,769s in the two worker groups. These sums are not elapsed time; the measured whole command includes Fast execution, clone startup, scheduling and diagnostic collection. The separately timed bootstatus call concerns the requested base destination, not the clones. Neither completed command exhibited the historical ten-minute post-test diagnostic stall; diagnostics remain enabled.

UUID fixture stores, same-store relaunch without reseeding, abrupt termination, app/runner ownership and native Settings changes remain intact. Both full runs passed the Settings/recovery workflows. No test plan, selected identifier, assertion, timeout or fixture setup changed in this comparison. It does not prove that historical intermittent Settings failures are solved.

The 30-second resource samples cover most, but not the exact endpoints, of each command. Whole-host VM counters use 16 KiB pages; swap activity is not an exact per-process allocation or measured disk-byte total. Serial followed parallel without a memory reset. Samples observed at most one xcodebuild process, but do not inventory every background service. The higher pressure is a reason to keep **two** workers, preserve a serial fallback, and avoid competing local workloads. It does not support four workers.

The local runner now defaults to two native workers and records the choice in phase commands and the SHA attestation. Use `SHOPPING_FULL_WORKERS=1 .github/scripts/run-local-shopping-full.sh` for serial diagnosis; other counts are rejected before expensive validation. The runner still uses an isolated clean-source snapshot, a fresh build, coverage, exact-source compiler preflight, unchanged-source checks, and failure-preserving reporting. No attestation was created from these research commands. The final integrated candidate must pass the maintained gates on its own SHA.

This change is local to the M2 runner. Hosted Xcode 16.4 / iOS 18.5 performance has not been measured with two workers, so hosted defaults stay as they are. Native scheduling provides the measured benefit without custom shards, repeated builds or manual result aggregation. Remaining class imbalance suggests a smaller possible optimization, but does not justify more scheduling machinery now.

Raw result bundles, logs, phase records, coverage exports and resource samples are retained in `/tmp/shopping-228-39026e3/`. Product hashes were captured during the serial run after parallel completed; they identify retained artifacts and are not a before/after product-integrity audit. The actual commands establish reuse of the same DerivedData directory without an intervening build. Naturally required final Full runs should extend the timing history; do not run extra suites just to manufacture a reliability sample.


## Pinned release UI diagnostics (SHOPPING-219)

Candidate `1f4d289e93746be65ee19752eab6004cc23ff031` passed local Full with 917 unique tests, zero failures/skips, in 2,127.300 seconds of test-command time. [Hosted Full 38080343221](https://github.com/mggarofalo/Shopping/actions/runs/38080343221) completed its inventory in 57m35s: 908 passes, nine UI failures, zero skips, and passing coverage. Raw result, log, and summary artifacts survived; this was a test failure, not a timeout. The local pass does not establish pinned-runtime compatibility.

Six failures requested native Settings slider position 100% and stopped at 45–55%. The remaining failures involved a departing Home sheet still covering the Homes button, a native category Menu reporting non-hittable despite a working touch, and a quantity sheet whose visible field was incorrectly bounded by the background tab bar. Corrections wait for the actual departing sheet, prove Menu reachability through one touch and its exact destination, and exclude a non-foreground tab bar from the sheet viewport. They retain selection, recovery, and full-frame visibility checks.

The first slider experiment used one native adjustment per category; 27% to 36% overshot to 45% locally. Its synthesized motion lasted only 47 ms after a 250 ms hold, disproving slow movement alone as the explanation. The second experiment used a direct no-hold drag for all positions: it reached 100% and the exact app XXXL category, but returning to 27% landed at 18%. Neither experiment is release proof. Results remain in `/tmp/shopping-phase33-focused-local/` and `/tmp/shopping-phase33-nohold-local/`; the first was stopped after its failure. [Focused hosted run 38085111373](https://github.com/mggarofalo/Shopping/actions/runs/38085111373) was cancelled when the first local experiment failed.

The endpoint-only no-hold candidate `a47ee29` passed all nine focused workflows locally (598.307 seconds, no skips), plus 797 Fast and six acceptance tests in [hosted CI 38085897761](https://github.com/mggarofalo/Shopping/actions/runs/38085897761). Its focused hosted selection passed the three non-slider workflows but failed the six Settings workflows. The first endpoint reached 100%; the native return stopped at 64%, and later endpoint gestures also stopped at 64%. Videos show identical successful and failed endpoint coordinates/timing, with the failed control changing layout during the drag. A later 10,000-point/second local gesture was ignored entirely. These results reject the all-position/high-velocity variants. The endpoint-only gesture remained in the next midpoint experiment and was ultimately discarded with it.

A Settings-only Large launch override was also rejected: it made the slider display the overridden value while Shopping retained XXXL, and the exact restoration assertion failed. That experiment and its resulting simulator-state cleanup are retained in `/tmp/shopping-phase33-stable-settings.xcresult`. There is no Settings launch override in the candidate.

Recorded thumb centers motivated a centered 2,500-point/second experiment; it reached the endpoint but continued to the minimum after release on return. Adding a destination hold changed the endpoint to 91%, exposing the control's pressed-state geometry. These empirical interior-targeting changes were discarded; recordings remain in `/tmp/shopping-phase33-centered-large-baseline.xcresult` and `/tmp/shopping-phase33-held-large-baseline.xcresult`.

The midpoint candidate `ff7c609` selected Large through the standard range (range off, position 0.5), retaining the endpoint-only gesture for XXXL. One local status workflow passed in 119.860 seconds, but the other five produced four passes and one failure: Home replacement returned to actual UIKit XL despite Settings showing the Large midpoint. The retained process, fresh sequence and video agree. Hosted diagnostic [38088316424](https://github.com/mggarofalo/Shopping/actions/runs/38088316424) failed at the XXXL endpoint before the midpoint transition. Both required CI jobs passed separately. These failed experiments are retained, not counted as release validation.

### Supported Simulator system driver (SHOPPING-219)

The repair separates test transport from app observations. `with-system-text-size.py` supervises one xcodebuild invocation; `SimulatorTextSizeDriver` submits unique, expiring requests from the actual runner UDID, including native parallel-worker clones. The host serializes supported `simctl ui <UDID> content_size` commands and requires exact named-category readback. `SystemTextSize` still backgrounds Shopping, activates its retained process and requires nonce, process, sequence, uptime and exact UIKit category before the original UI/layout assertions. It first checks the original global category against Shopping, then restores and observes that same category after the test.

A private per-run directory, lease identity, atomic acknowledgments and poisoned failed leases prevent cross-test/stale commands. Teardown restoration follows any in-flight setter; host cleanup restores abandoned leases and forces a nonzero result. Missing transport fails explicitly. There are no launch overrides, skips, retries or product-code changes.

This deliberately replaces proof of Apple's Settings navigation, range toggle and slider fidelity with proof of actual Simulator OS category changes and app response. It does not claim physical-device behavior or exact Settings range-toggle restoration. The first local status experiment passed in 49.350 seconds at iOS 26.5, compared with the preceding midpoint experiment's 119.860 seconds for the same method; this is a focused mechanism comparison, not a suite-wide speedup or final-source attestation. Raw results: `/tmp/shopping-phase33-host-driver.xcresult`. Focused multi-worker/pinned and final exact-source results follow separately.

The first six-method native-worker run failed before any global mutation: the runner correctly supplied clone `A00CF711-93BC-491B-ACF2-C4AADAB543E0`, but the host looked in the default device set. That clone belongs to Xcode's `XCTestDevices` set. The driver now takes the runner's `SIMULATOR_SHARED_RESOURCES_DIRECTORY`, validates its `UDID/data` suffix and binds the derived device set into every lease/request/acknowledgment. Commands explicitly use `simctl --set`; neither base-device inference nor `booted` is used. The failed result is retained at `/tmp/shopping-phase33-host-driver-six.xcresult`.
