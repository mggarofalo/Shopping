# Test strategy

The repository has one owner for each kind of evidence. `ShoppingFast` owns deterministic app logic and persistence behavior. `ShoppingFull` owns simulator workflows and accessibility; `ShoppingAcceptance` selects six of those workflows alongside all Fast tests for routine feedback. `ShoppingPerformance` owns measurements. `ShoppingDevice` and the manual protocols own system behavior that a simulator cannot prove.

## Test layers

| Layer | Framework | Owner | What it proves |
| --- | --- | --- | --- |
| Unit | Swift Testing | `ShoppingCritical` and `ShoppingFast` | Deterministic value and filtering rules without a store or UI. |
| Integration and persistence | Swift Testing or XCTest | `ShoppingFast` | Core Data commands, SQLite relaunch, recovery, replica ordering, and failure rollback. |
| User interface | XCTest UI automation | `ShoppingFull`, with six workflows selected in `ShoppingAcceptance` | User workflows, accessibility, layout, appearance, and fixture relaunch on Simulator. |
| Performance | XCTest measurement and manual Instruments traces | `ShoppingPerformance` | Stable service and loaded-interface measurements. |
| Device and system | XCTest UI automation plus a recorded manual protocol | `ShoppingDevice` and `docs/device-validation.md` | Signed-device launch, VoiceOver, Reduce Motion, offline behavior, and live CloudKit limits. |

Swift Testing tags add a second, semantic view across source suites. The `.critical` tag selects release-sensitive unit and persistence checks in `ShoppingCritical`. The migrated filter suite also carries `.unit`. The optional-quantity suite carries `.integration` and `.persistence`. XCTest UI automation stays in XCTest because it depends on `XCUIApplication`, accessibility audits, screenshots, and performance metrics.

## Source inventory

The September 23 SHOPPING-108 inventory, based independently on `main`, has 215 fast tests and 67 non-performance UI tests: 282 in `ShoppingFull`. Its pre-commit fast validation passed all 215 tests. Phase 17's separate 284-test inventory is not part of this branch; its open PR remains independent. SHOPPING-119 adds three fixture tests (218 Fast tests) and consolidates the rendered ordering scenarios; the [ownership ledger](test-ownership.md) accounts for the changed UI inventory and the [redesign report](test-redesign.md) records the measured comparisons.

The historical September 8 file-level inventory below covers the 221 tests then maintained: 166 fast tests and 55 non-performance UI tests. The 5 performance tests stay outside the ordinary total. “Fast” means a file contributes to the deterministic run. UI files range from about 10 seconds to several minutes. Six selected methods also run in routine acceptance; the complete files run in the exhaustive plan. Use current xcresult counts and per-test records for runtime comparisons rather than treating this historical table as a current manifest.

| Source | Tests | Layer | Runtime dependency | Cost | Coverage owner and notes |
| --- | ---: | --- | --- | --- | --- |
| `CatalogFilterUnitTests.swift` | 11 | Unit | None or isolated UserDefaults | Fast | Swift Testing; filter, suggestion matching, and navigation state tagged unit and critical. |
| `CatalogFilterTests.swift` | 5 | Integration | In-memory and SQLite Core Data | Fast | Catalog metadata, identity, and relaunch behavior. |
| `CatalogManagementTests.swift` | 18 | Integration | In-memory and SQLite Core Data | Fast | Catalog commands, stale suggestions and batches, recovery, and rollback. |
| `CategoryManagementTests.swift` | 9 | Integration | In-memory Core Data | Fast | Category ordering, scope, deletion, and revision behavior. |
| `ChecklistSafetyTests.swift` | 9 | Integration | In-memory Core Data | Fast | Captured checkout, stale changes, and invalid graph handling. |
| `GroceryEditingTests.swift` | 16 | Integration | Core Data writer contexts | Fast | Atomic edits, permission failures, responsiveness, and recovery. |
| `GroceryNavigationStateTests.swift` | 11 | Integration | UserDefaults and Core Data | Fast | Filter persistence, canonical scope, sorting, and add-scope behavior. |
| `GroceryNeedTests.swift` | 13 | Integration | In-memory and SQLite Core Data | Fast | Need identity, re-add, one-time isolation, and clear behavior. |
| `LocalDataRegressionTests.swift` | 4 | Integration | 2 SQLite contexts | Fast | Explicit local merge and duplicate-occurrence regressions. |
| `ManagementWriterScopeTests.swift` | 2 | Integration | Multiple persistent stores | Fast | Stale scope rejection for category and catalog writers. |
| `OneTimePromotionTests.swift` | 9 | Integration | In-memory and SQLite Core Data | Fast | Promotion identity, collisions, rollback, and relaunch. |
| `OptionalQuantityTests.swift` | 3 | Integration | In-memory and SQLite Core Data | Fast | Swift Testing; tagged integration, persistence, and critical. |
| `PersistenceContainerTests.swift` | 15 | Integration | Persistent stores and history | Fast | Store routing, history, journaling, load failure, and imported graphs. |
| `PersistenceHarnessTests.swift` | 16 | Integration | Disk-backed local harness | Fast | Save ordering, relaunch, trimming, recovery, and store ownership. |
| `PreviewFixtureTests.swift` | 7 | Integration | App-owned fixture stores | Fast | Fixture content, writable paths, pruning, and deliberate relaunch. |
| `SchemaVersionTests.swift` | 3 | Integration | Bundled model and saved fixture | Fast | Schema contract, optional IDs, migration, and recovery graph. |
| `StoreManagementTests.swift` | 15 | Integration | Multiple persistent stores | Fast | Canonical scope, ordering, archive, restore, and removal. |
| `CategoryManagementUITests.swift` | 6 | UI | Simulator app and isolated store | Slow | Full plan; native selection and accessibility workflows. |
| `ChecklistUITests.swift` | 7 | UI | Simulator app and isolated store | Slow | Full plan; cart, clear, recovery, quantity, and accessibility. |
| `ClearInterruptionUITests.swift` | 1 | UI | Simulator app and forced process exit | Slow | Full plan; committed clear recovery after abrupt termination. |
| `GroceryEditingUITests.swift` | 11 | UI | Simulator app and isolated store | Slow | Full plan; editing, filtered category/cart feedback, keyboard dismissal, catalog suggestions, relaunch, Dynamic Type, and optional quantity. |
| `OneTimePromotionUITests.swift` | 4 | UI | Simulator app and isolated store | Slow | Full plan; promotion choices, conflicts, relaunch, and sorting. |
| `ShoppingAppearanceUITests.swift` | 3 | UI | Simulator app in 2 appearances | Very slow | Full plan; light, dark, and accessibility-size layouts. |
| `ShoppingDeviceUITests.swift` | 8 | UI and device | Simulator or signed device | Slow | Full and device plans; accessibility, compact layout, and recovery copy. |
| `ShoppingLaunchTests.swift` | 15 | UI | Simulator app and isolated store | Very slow | Full plan; broad launch, settings, filters, catalog, and store workflows. |
| `PerformanceRegressionTests.swift` | 3 | Performance | Loaded in-memory service fixture | Measured | Performance plan only; service and catalog-suggestion latency baselines. |
| `PerformanceFlowUITests.swift` | 2 | Performance | Loaded simulator fixture | Measured | Performance plan only; UI trace routes and metrics. |

`LocalTwoContextHarness.swift` and `Fixtures/generate-shopping-v1-fixture.swift` are support code, not test suites.

## Inventory findings

The earlier suite already had good product coverage, but its categories lived mostly in target and class names. SHOPPING-63 moved the execution boundaries into shared plans. SHOPPING-61 made the remaining ownership explicit, moved 6 suitable checks to Swift Testing, and added 3 focused navigation-state checks.

The inventory found these boundaries:

- The first 3 tests in `CatalogFilterTests.swift` were pure value tests mixed with Core Data integration. They now share the tagged unit file with focused store-selection, focus-routing, and recovery-copy checks.
- Optional-quantity behavior spans in-memory commands, recovery, and a 2-context SQLite simulation. It remains an integration suite but now uses Swift Testing tags and traits.
- UI files contain workflow assertions rather than domain assertions. Moving them to Swift Testing would remove required XCTest UI APIs and add no value.
- Performance tests were misplaced in ordinary regression coverage before SHOPPING-63. They now run only through `ShoppingPerformance`.
- No test uses `#if targetEnvironment(simulator)` to decide its category or locate a fixture.
- Consolidation requires an explicit retained owner for each behavior in the [test ownership ledger](test-ownership.md). Prefer deterministic coverage for rule matrices and isolated fixtures for incidental setup. Preserve representative UI interactions and distinct clear, identity, and recovery boundaries even when related domain rules already have fast tests.

## Quick acceptance boundary

Following [Apple’s guidance](https://developer.apple.com/videos/play/wwdc2022/110361/), `ShoppingAcceptance.xctestplan` combines the exact `ShoppingFast` target/options with six explicit UI methods on one platform. The canonical manifest covers catalog add/reuse, scoped checkout, abrupt-exit clear recovery, one-time isolation, remembered editing/relaunch, and large-text checklist controls. The [ownership ledger](test-ownership.md) records the proof retained by these scenarios and the exhaustive suite.

Routine CI builds this plan once, then runs `ShoppingFast` and the selected UI target into separate result bundles. The unchanged Fast-only coverage gate cannot be boosted by the UI portion. Built-selection and result-selection checks reject accidental broadening, missing methods, skips, and duplicate executions. All remaining maintained UI tests stay in the manual `ShoppingFull` plan with its exact-SHA local attestation requirement. See [CI commands and triggers](continuous-integration.md) for the execution sequence and provisional feedback budgets.

## Fixtures and relaunch

Every test creates a unique store. Unit tests use no store. Integration tests use in-memory stores or unique directories under the test host’s temporary directory. UI tests pass a requested path through `SHOPPING_UI_TEST_STORE_PATH`. The app keeps writable Simulator paths and maps paths from another device-runner sandbox into its own Application Support directory.

Fixture launch is idempotent. A deliberate relaunch removes `SHOPPING_UI_TEST_FIXTURE`, reuses the resolved store path, and does not seed again. The pruning policy removes only complete app-owned SQLite groups and old history tokens. It never reads, writes, logs, or deletes the user’s normal Shopping store.

## Catalog suggestion tuning

Catalog suggestions normalize case, diacritics, character width, and repeated whitespace before matching. Exact matches rank ahead of prefixes, then substrings, then Jaro–Winkler fuzzy matches. Substring matching starts with 1 character; fuzzy matching starts with 3 characters and requires a score of at least 0.85. Results use deterministic name and identity tie-breaks and are capped at 5.

The matcher runs locally and synchronously over the already scoped catalog snapshot, so typing cannot create persistence writes or publish a result for an older query. The performance fixture measures an exact result near the end of a 1,000-item catalog over 20 iterations. On the documented iPhone 17 Pro simulator it recorded p50 36.09 ms, p95 36.61 ms, and worst 36.68 ms against a 100 ms ceiling. Grocery UI tests own selection semantics, keyboard focus, store-scope narrowing, saved metadata, cancellation, and accessibility XXXL layout.

## Coverage baseline and gate

`ShoppingFast` and `ShoppingFull` collect coverage. The required CI job exports machine-readable `xccov` JSON, a short Markdown summary, and the existing test summary. `.github/scripts/check-coverage.sh` compares the app target with `.github/coverage-baseline.json`.

The September 8 `ShoppingFast` baselines are toolchain-specific because Xcode 16.4 and Xcode 26.6 produce different coverage maps for the same maintained source:

| Scope | Line coverage | Function coverage |
| --- | ---: | ---: |
| Whole `Shopping.app` target, Xcode 16.4 | 39.33% | 31.86% |
| Whole `Shopping.app` target, Xcode 26.6 | 41.71% | 34.84% |
| Deterministic domain and service files | 96.42% | Not gated |

The gate allows a 0.5 percentage-point change before it treats the result as a material regression. Raise the committed baseline when coverage grows. Do not lower it to make a change pass.

The deterministic scope includes `CatalogFilter.swift`, `GroceryNavigationState.swift`, `NeedService.swift`, `PersistenceConfiguration.swift`, and `PersistenceModels.swift`. It exceeds the 90% goal. The fast whole-app number remains below 80% because `ShoppingFast` deliberately does not render the large SwiftUI view files. `ShoppingFull` owns those paths; its final local validation reached 89.83% line coverage and 82.73% function coverage for `Shopping.app`, clearing the maintained-source goal without slowing required pull-request feedback. Generated Core Data accessors need no exclusion because this project defines its managed object properties in maintained source.

## Reliability and skips

The plans do not retry failures. Runtime skips are allowed only when a real capability is unavailable, and the reason must appear in the result. Current tests need no platform-category skips.

Known lookup and accessibility-count flakes were fixed under SHOPPING-60 and SHOPPING-63. The performance UI flow remains manual until it produces 3 consecutive hosted passes. A physical `ShoppingDevice` run still needs the signing account and profiles tracked by SHOPPING-10. Until then, simulator checks remain required and the manual device record must state the exact missing proof.

## Runtime measurements

`.github/scripts/test-timing.py` records phase wall time with a monotonic clock and exports every test's duration and result from `xcresulttool get test-results tests`. Numeric durations are retained when available; formatted durations from older result schemas are marked as rounded, and missing durations stay unknown. Suite totals sum their tests; these totals are not elapsed time when tests overlap. The Markdown report lists the slowest 15 suites and 20 tests, while JSON retains every test, failure, phase exit status, device, toolchain, and source revision.

The full local runner retains lightweight pass/failure reports in the Git common directory at `shopping-test-timings/<SHA>/<unique-run-id>/`; raw result bundles and logs remain temporary. These durable reports provide the history for later regression comparisons. The focused example below uses temporary storage, so retain its reports with the investigation evidence when comparing results.

For focused experiments, capture metadata before building, time the command, then export the result. Use the same simulator, test selection, and build conditions for before/after comparisons:

```bash
artifacts="$(mktemp -d "${TMPDIR:-/tmp}/shopping-timing.XXXXXX")"
.github/scripts/test-timing.py init --plan ShoppingFull --json "$artifacts/Metadata.json"
.github/scripts/test-timing.py run --phases "$artifacts/Phases.jsonl" --phase test --record-command \
  --log "$artifacts/Test.log" -- \
  xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingFull \
  -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C' \
  -only-testing:ShoppingTests/ChecklistUITests \
  -resultBundlePath "$artifacts/Results.xcresult"
.github/scripts/test-timing.py report --plan ShoppingFull --metadata "$artifacts/Metadata.json" \
  --phases "$artifacts/Phases.jsonl" --result "$artifacts/Results.xcresult" \
  --json "$artifacts/Timing.json" --markdown "$artifacts/Timing.md"
```

`--record-command` saves the command arguments to the phase record for reproducible test selections and worker settings; use it only with commands that contain no secrets. The command wrapper returns the original failure status, including signal exits. Run `report` after a failed command as well; an absent or incomplete result bundle produces a diagnostic report rather than a passing test result. Standalone reporting without `--metadata` explicitly warns that revision and toolchain describe the reporting environment. Captured metadata is required for a historical before/after comparison. This framework records observations without retrying tests or introducing a timing gate.

Validate reporting and the local attestation runner without a simulator:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .github/scripts -p 'test_test_timing.py'
```
