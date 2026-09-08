# Test strategy

The repository has one owner for each kind of evidence. `ShoppingFast` owns deterministic app logic and persistence behavior. `ShoppingFull` owns simulator workflows and accessibility. `ShoppingPerformance` owns measurements. `ShoppingDevice` and the manual protocols own system behavior that a simulator cannot prove.

## Test layers

| Layer | Framework | Owner | What it proves |
| --- | --- | --- | --- |
| Unit | Swift Testing | `ShoppingCritical` and `ShoppingFast` | Deterministic value and filtering rules without a store or UI. |
| Integration and persistence | Swift Testing or XCTest | `ShoppingFast` | Core Data commands, SQLite relaunch, recovery, replica ordering, and failure rollback. |
| User interface | XCTest UI automation | `ShoppingFull` | User workflows, accessibility, layout, appearance, and fixture relaunch on Simulator. |
| Performance | XCTest measurement and manual Instruments traces | `ShoppingPerformance` | Stable service and loaded-interface measurements. |
| Device and system | XCTest UI automation plus a recorded manual protocol | `ShoppingDevice` and `docs/device-validation.md` | Signed-device launch, VoiceOver, Reduce Motion, offline behavior, and live CloudKit limits. |

Swift Testing tags add a second, semantic view across source suites. The `.critical` tag selects release-sensitive unit and persistence checks in `ShoppingCritical`. The migrated filter suite also carries `.unit`. The optional-quantity suite carries `.integration` and `.persistence`. XCTest UI automation stays in XCTest because it depends on `XCUIApplication`, accessibility audits, screenshots, and performance metrics.

## Source inventory

The September 8 inventory covers all 212 maintained tests: 160 fast tests and 52 non-performance UI tests. The 4 performance tests stay outside the ordinary total. “Fast” means a file contributes to the roughly 6-second deterministic run. UI files range from about 10 seconds to several minutes and run only in the exhaustive plan.

| Source | Tests | Layer | Runtime dependency | Cost | Coverage owner and notes |
| --- | ---: | --- | --- | --- | --- |
| `CatalogFilterUnitTests.swift` | 6 | Unit | None or isolated UserDefaults | Fast | Swift Testing; filter and navigation state tagged unit and critical. |
| `CatalogFilterTests.swift` | 5 | Integration | In-memory and SQLite Core Data | Fast | Catalog metadata, identity, and relaunch behavior. |
| `CatalogManagementTests.swift` | 17 | Integration | In-memory and SQLite Core Data | Fast | Catalog commands, stale batches, recovery, and rollback. |
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
| `GroceryEditingUITests.swift` | 8 | UI | Simulator app and isolated store | Slow | Full plan; editing, relaunch, Dynamic Type, and optional quantity. |
| `OneTimePromotionUITests.swift` | 4 | UI | Simulator app and isolated store | Slow | Full plan; promotion choices, conflicts, relaunch, and sorting. |
| `ShoppingAppearanceUITests.swift` | 3 | UI | Simulator app in 2 appearances | Very slow | Full plan; light, dark, and accessibility-size layouts. |
| `ShoppingDeviceUITests.swift` | 8 | UI and device | Simulator or signed device | Slow | Full and device plans; accessibility, compact layout, and recovery copy. |
| `ShoppingLaunchTests.swift` | 15 | UI | Simulator app and isolated store | Very slow | Full plan; broad launch, settings, filters, catalog, and store workflows. |
| `PerformanceRegressionTests.swift` | 2 | Performance | Loaded in-memory service fixture | Measured | Performance plan only; service latency baselines. |
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
- No verified duplicate or implementation-mirroring assertion should be removed. Similar clear, identity, and scope checks cover different persistence boundaries.

## Fixtures and relaunch

Every test creates a unique store. Unit tests use no store. Integration tests use in-memory stores or unique directories under the test host’s temporary directory. UI tests pass a requested path through `SHOPPING_UI_TEST_STORE_PATH`. The app keeps writable Simulator paths and maps paths from another device-runner sandbox into its own Application Support directory.

Fixture launch is idempotent. A deliberate relaunch removes `SHOPPING_UI_TEST_FIXTURE`, reuses the resolved store path, and does not seed again. The pruning policy removes only complete app-owned SQLite groups and old history tokens. It never reads, writes, logs, or deletes the user’s normal Shopping store.

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
