# Validation and release turnaround — SHOPPING-226

Research snapshot: October 9, 2026. UI automation dominates local validation. The largest avoidable release cost is discovering problems after an hour-long exhaustive run. Prioritize earlier compiler checks, then a controlled two-worker benchmark. Local build caching has a much smaller ceiling.

Research only: no tests, builds, simulator operations, workflow changes or CI dispatches. Completed xcresults were read with xcresulttool; GitHub queries were read-only. SHOPPING-226 and branch `docs/shopping-226-validation-turnaround-research` existed before repository writes. The active release was left alone.

## Evidence and limits

The [evidence snapshot](benchmarks/shopping-226.json) preserves existing phase records, metadata, counts, failures, report hashes, Phase 33 UI inventory, five activity samples, hosted compatibility phases and a hypothetical sharding calculation. It reuses the existing reporting framework rather than adding a timer or runner.

- Research base: `0c707c6`. Phase 33 source inspected separately at `a5a9d59887ba2d0767e8711611506d9ad257c4df`, including its ownership-ledger additions.
- Shared history: `/Users/michael/Source/Shopping/.git/shopping-test-timings`. Snapshot contains 21 completed local reports (14 marked Passed), one incomplete local run, plus separate hosted/experimental evidence. These are selected development runs with different inventories, not a statistical performance sample.
- Local Phase 33: Xcode 27.0 (27A266a), macOS 27.0.1 arm64, iPhone 17 Pro simulator, iOS 26.5 (23F77), destination `15066BE0-662A-4573-AA67-12E84FA0C39C`. User identifies the host as MacBook Pro M2; RAM, memory pressure, thermal state and competing processes were not measured.
- Passing baseline: `61d56b21c4fb0da116c104281c2293fb435288ed`, run `20261009T164022Z.m3KtHN`. Raw result still existed at `/private/var/folders/46/rfm__t390_j4__pjgy20q29m0000gn/T/shopping-full-61d56b21c4fb0da116c104281c2293fb435288ed.1sBByV/Results.xcresult`.
- Newest `a5a9d59` had only snapshot, simulator and build records at capture. Build was 39.316 seconds. No final duration, pass or speedup is inferred from that incomplete run.
- Local Full creates fresh source/DerivedData directories on a warm host, builds once, then tests without building. This is not a cold-machine benchmark. Command metadata has no explicit worker count; the trace is consistent with serial execution.
- Read AGENTS.md, shopping-testing, test strategy, complete ownership ledger, runtime report and continuous-integration guide. Also inspected release guidance, plans, runner/workflows, Phase 33 progress/commits, hosted artifacts and selected test sources.

## Cost separation

### Completed local Phase 33 pass

| Cost | Seconds | Interpretation |
| --- | ---: | --- |
| Snapshot | 0.19 | Retain exact-source isolation. |
| Simulator preparation | 0.15 | Already available simulator, not cold boot. |
| Build for testing | 49.99 | 1.28% of recorded phase time. |
| Test command | 3,851.68 | 64m12s including session overhead. |
| Summary | 4.06 | No separate local coverage-export phase. |
| **Recorded phase sum** | **3,906.07** | **65m06s**, excluding small gaps and final timing export. |
| Result-bundle interval | 3,848.08 | Distinct from command wall time. |
| 120 UI cases, summed | 3,769.50 | 62m49s; 98.3% of summed case time. |
| 797 Fast cases, summed | 63.79 | 1m04s. |

Command time minus all case durations is only 18.39 seconds. This pass does not exhibit the historical ten-minute diagnostic stall. Case sums help attribute this serial trace but are not elapsed time under parallel execution. Coverage instrumentation is included, not measured as a separable execution cost.

| Largest UI classes | Cases | Summed seconds |
| --- | ---: | ---: |
| GroceryEditingUITests | 12 | 615.05 |
| PersonalCartUITests | 19 | 599.04 |
| ShoppingLaunchTests | 19 | 426.82 |
| HomeDetailsUITests | 12 | 419.82 |
| ChecklistUITests | 12 | 287.37 |
| ShoppingAppearanceUITests | 7 | 278.54 |
| ShoppingDeviceUITests | 11 | 254.89 |

Top four: 2,060.73 seconds, 54.7% of UI time. Older Full measurements covered 282 tests in 34–46 minutes, versus 917 now, including 120 UI methods. This increase cannot all be called a regression in unchanged tests. Documentation's 218-Fast inventory is historical. Across 21 local reports, build median is 34.11 seconds, range 20.40–50.84 seconds, with differing inputs.

### Hosted compatibility

[Run 37969439347](https://github.com/mggarofalo/Shopping/actions/runs/37969439347), source `db9686f883daf504bcefbbff42a3f56349361152`, passed both jobs. Git tree IDs confirm it matches milestone `a5a9d59`; this does not transfer attestation across SHAs.

| Cost | Seconds |
| --- | ---: |
| Simulator phase | 164.01 |
| Shared build command | 290.03 |
| Fast command, 797 passes | 138.24 |
| Acceptance command, six passes | 250.10 |
| Fast coverage export/gate | 6.28 |
| Both summaries | 4.20 |
| Build & Test whole job | 919 (15m19s) |
| Concurrent Release SDK Build job | 267 (4m27s) |
| Unsigned archive step within Release job | 258 (4m18s) |

Whole-job time includes creation/setup, selection checks and finalization beyond timed commands. Do not add concurrent Release job time to the critical path or count shared build time twice. Hosted tests use Xcode 16.4/iOS 18.5, Release compilation Xcode 26.3; neither matches local Xcode 27.

Hosted caching has more potential than local caching. But [SHOPPING-207](cicd-startup.md) already found startup/build overlap slower in its sample: 9m35s versus 7m26s serial. There is no evidence to enable that rejected optimization.

## Repeated validation and workflow policy

Completed Phase 33 Full attempts before the active candidate consumed **144m22s of recorded phases**, including only **2m31s of compilation**:

| Candidate | Phase total | Outcome |
| --- | ---: | --- |
| `8b90596` | 15m43s | Interrupted, exit 75, partial 829-test result after Release-only preview compile defect discovery. Not a completed-suite failure rate. |
| `97370ca` | 63m33s | 915 passes, two failures: native Settings size fidelity and keyboard/restore interaction boundaries. |
| `61d56b2` | 65m06s | 917 passes. Hosted checks later exposed IntentDialog inference and Release SwiftUI type-checking failures. |
| `a5a9d59` | Incomplete | Compiler fixes passed compatibility CI; fresh exact-source Full active at capture. |

Evidence: durable reports, these commits, retained `/tmp/shopping-phase33-progress.md`, [failed PR CI](https://github.com/mggarofalo/Shopping/actions/runs/37968595819), and [canceled hosted Full](https://github.com/mggarofalo/Shopping/actions/runs/37968561815). Repeats were required after input changes under current rules. Earlier compiler checks could avoid spending a Full before discovering incompatibility, plus potentially the partial Release-preview attempt. These are conditional avoided costs, not guaranteed savings; subtract extra preflight cost.

| Proof stage | Distinct value / reuse boundary |
| --- | --- |
| Focused tests and Fast | Quick localization during development; broader final checks still apply. |
| Exact local Full | Complete inventory on local platform. Changed inputs invalidate clean-SHA attestation. |
| Hosted Full | Full older-runtime/compiler compatibility. Local success cannot substitute; exact local pass remains prerequisite. |
| Required PR CI | Independent Fast-only coverage, six acceptance methods, Release compilation. Overlapping methods do not make these contracts redundant. |
| Push-to-main CI | Actual integrated-source proof required by upload preflight. Branch/merge SHA equivalence cannot be assumed. |
| Signed archive/export | Production configuration, both signatures/capabilities and final version/build. Simulator products and unsigned archives do not replace it. |
| Apple processing/distribution | Valid processed upload and tester availability. Verify existing uploads instead of repeating upload because processing is slow. |

Milestone-push/PR duplication was already removed. Main CI remains intentional. An ordinary hosted cycle costs about 15m19s in this sample, saving that wall time only if removed from the critical path. No completed current Phase 33 hosted Full or signed-upload duration was available. Historical hosted Full took about 59 minutes with a different inventory. Apple review/processing is unmeasured external latency; a precise total-release saving is unsupported.

## Prioritized recommendations

Estimates are hypotheses or avoided-work arithmetic, not measured improvements. They overlap: reducing serial UI work reduces the work left to parallelize.

| Priority | Action | Estimated benefit | Risk / evidence needed |
| --- | --- | --- | --- |
| 1 | Pinned test/Debug and Release compiler checks plus changed UI boundaries before final Full | Avoid ≈65 minutes per late compiler-failure cycle; potentially 16-minute partial failure too | Preflight costs time. Reuse existing CI at appropriate stage; preserve final checks. |
| 2 | Benchmark two isolated UI workers, one build | Trial target 35–45 minute local Full, ≈20–30 minutes saved | Unproven M2 benefit; contention, Settings state, startup and diagnostics may erase it. |
| 3 | Reduce repeated queries, positive polling and incidental setup | Planning target 3–8 minutes off serial Full | Small sample does not establish suite saving; require retained owners and matched comparisons. |
| 4 | Diagnose SpringBoard idle timeouts | Ceiling ≈120 seconds per Full; zero guaranteed | Preserve real Home Screen delivery; supported remedies only. |
| 5 | Separately design evidence-reuse policy | One avoided Full ≈65 local minutes; ordinary hosted cycle ≈15 minutes | Highest provenance risk; current exact-SHA rules stay unchanged. |
| 6 | Measure hosted caching/startup under SHOPPING-145 | Exploratory 1–3 minutes/job; build ceiling 4m50s before cache costs | No positive benchmark; local reuse ceiling only ≈50 seconds/Full. |

### Sharding and isolation

[Apple documents distributed testing on simulator clones with class-level distribution](https://developer.apple.com/videos/play/wwdc2020/10221/). Greedy longest-first assignment of current serial UI classes produces bins of **1,891.42 and 1,878.07 seconds**. This is a scheduling calculation, not actual Xcode scheduling. Ideal UI half is 1,884.75 seconds; largest class is 615 seconds, so class granularity alone does not prevent useful two-worker distribution.

Adding current Fast/build/overhead yields an idealized floor near 34 minutes. A 35–45 minute trial target allows overhead but is not a confidence interval. Try native scheduling before custom method shards. Four workers require separate resource evidence.

[SHOPPING-108](shopping-full-runtime.md#two-worker-experiment-serial-default-retained) was inconclusive: short serial selection 154.98s versus two workers 163.09s, then 749.21s on repetition. A longer parallel run had ≈228s scheduler activity but 861.39s command time due to diagnostics. Serial execution also encountered a 600-second stall. Neither reliable speedup nor parallelism as the stall's cause is established.

After release and simulator availability, compare identical committed inventory with existing timing tooling, complete command time and resource measurements. Retain failures and warm/cold conditions. Start with representative isolation proof, then complete comparisons before defaults change. Native clones avoid custom result aggregation; manual shards need merged exact inventory, failure propagation and coverage checks. Never run simultaneous UI sessions on one simulator or concurrent writes to shared build products.

Current suites change **system Settings text size**, beyond the older report's process-local overrides. `SystemTextSizeSettings` verifies fresh same-process UIKit observations and restores original controls/category. Separate clones are essential; sequential cases still require reliable restoration. Failed restoration remains failure. Do not replace actual Settings changes with launch arguments. Recovery retains abrupt termination, ordinary relaunch, same-store continuity and removal of seed flags. Missing, duplicate and skipped records must fail inventory checks before attestation.

### UI automation, fixtures and waits

Five passing xcresult activity samples were inspected. Adjacent top-level activity-start intervals include framework/app work, not CPU samples; never add child durations to parents.

- Grocery purchase-rule case: **71.11s**. 155 existence-check intervals total **12.158s**, 140 finds **11.103s**, 24 taps **25.309s**, 11 typing intervals **7.396s**. Review `GroceryEditingUITests.reveal` for repeated reads within one stable attempt. Do not cache across scroll/navigation/edit; filter and rule-selection interactions are the proof.
- Primary appearance route: **107.40s**. Four opens **11.893s**, 44 taps **60.865s**, eight swipes **16.333s**. Preserve both appearances, geometry and visibility. Removing opens has a smaller ceiling and may remove persistence proof.
- `PersonalCartUITests` still has positive `waitForExistence` alongside `existsOrAppears`. Audit ready-now waits, but preserve uniqueness, separate expected values, hittability, disappearance and negative windows. `storeChoice`/`assertStoreCount` predicate waits are not plain existence waits.
- Catalog cancel/save route: **77.97s**. First-Home tap interval only **0.494s**: fixture substitution there alone saves little. Trace shows placeholder-length deletion fallback in the old local text helper. Compare with shared placeholder handling while retaining resulting-value checks. Batched deletion already exists; do not count its historical gain again.
- Home Screen action: **132.907s**. Long press **61.536s**, Add item tap **60.968s**. Nested SpringBoard idle waits end after **60.037s and 60.034s** with “App animations complete notification not received.” This establishes ≈120s of framework waiting. Injected routing would remove the unique OS-delivery proof; no global synchronization disable, private API, sleep or skip is recommended.

Fixtures are already widespread. Seed unrelated **pre-action state**, verified by Fast checks for identity, saved fields, lifecycle and relationships. A one-time removal/undo case can be assessed for preexisting one-time data while creation stays in its named UI owner. Never fixture away promotion, destructive cancel/confirm, mutation, recovery or rendered ordering. Keep UUID stores per test; no cross-test app/store reuse.

Historical SHOPPING-119 records show eight-case baseline interval 1,081.76s versus redesigned 356.07s. Scenarios/fixtures changed; this is not a matched current-inventory speedup or a promise of another 67% reduction. Use [ownership ledger](test-ownership.md) and [redesign report](test-redesign.md); map every shortened scenario to retained proof. Refactor responsibilities before changing behavior.

### Selection, build reuse and release

Keep all Fast tests in routine CI: local case time is only ≈64s. Six acceptance methods sum to **190.19s** inside Full, not a standalone command benchmark; hosted acceptance command is **250.10s**. Using affected tests plus acceptance instead of unnecessary iterative Full can avoid most of an hour, but required final runs remain required.

[Apple recommends representative PR plans and broader validation separately](https://developer.apple.com/videos/play/wwdc2022/110361/); Shopping already does this. Avoid whole-class acceptance additions. Phase 33 quick actions/replacement are outside the six-method selection: use affected owners during development, justify permanent additions by unique proof and measured cost. Changed-file-only selection is unsafe across persistence, bootstrap, navigation and recovery; uncertainty should select broader owners.

[Build-for-testing/test-without-building](https://developer.apple.com/library/archive/technotes/tn2339/_index.html) already exists locally and in CI. Reuse built products for unchanged focused repetitions, not mutable test state. Local attestation deletes its isolated build snapshot; a cache must key source/dependencies, toolchain/SDK, architecture, settings, coverage and generated build identity and measure restore/save costs. Preserve clean-source provenance. Cross-toolchain/simulator products cannot serve signed archives.

Unsigned Release compilation and signed upload differ in signing/configuration and potentially source/build identity. Treat archive reuse as separate design work. Apple processing/review is not M2 compute time; existing verify-only avoids duplicate uploads. SHOPPING-132 is Done in Plane: do not recreate the signing repair from stale fallback documentation. Current live proof should determine the release route.

## Plane backlog

New items are Backlog, parented to [SHOPPING-226](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/a18b1d44-9d3e-490f-acdc-d665c01124b5), in Phase 18: Full Suite Runtime. This research does not authorize implementation or policy adoption.

| Issue | Scope / acceptance |
| --- | --- |
| [SHOPPING-227](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/68be7ae1-07e8-44f5-902a-d456f7e81e9a) | Earlier compiler/changed-boundary gates; fail before Full, retain exact-source checks, measure net turnaround. |
| [SHOPPING-228](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/a078b878-9631-40b4-9098-17334962054a) | Two-worker benchmark, merged inventory, clone isolation, Settings/recovery fidelity and command timing. |
| [SHOPPING-229](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/21b994cd-d8a4-48ed-8fb5-859ef671c845) | Query/fixture optimization; refactor first, retain owners, measure matched scenarios. |
| [SHOPPING-230](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/22ba2a32-b596-43f3-a909-2d68005f2b01) | Supported SpringBoard-idle remedy preserving actual Home Screen interaction. |
| [SHOPPING-231](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/7169044b-4fe2-46f4-af2a-aa4998ae3176) | Design-only evidence reuse; invalidation/provenance rules, separately authorized adoption. |
| Existing [SHOPPING-145](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/80f99f0c-3493-4198-bbb1-7ce9864dd4b9) | Reuse hosted startup/finalization investigation; consider separately scoped cache measurement. |
| Existing [SHOPPING-160](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/a787ae1e-6a25-4fa4-acfa-3bc9ddcecc44) | Older-runtime Settings/restoration reliability; Phase 33 local fixes alone do not establish pinned-runtime proof. |

Recommended next authorized work: SHOPPING-227, then SHOPPING-228 after exclusive simulator access. Exact-SHA attestation, coverage thresholds, required CI and release authorization remain unchanged.
