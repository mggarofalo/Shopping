# SHOPPING-200 account, permission and sync contracts

`AccountCloudApplicationContractTests` adds seven complementary scenarios to `ShoppingPersistenceTests`, selected by `ShoppingFast`. No existing tests were removed or changed.

| Layer | Scenario | Boundary proved |
| --- | --- | --- |
| Account contract | New refresh wins late successful lookup | Stateful suspended account lookup → real provider → durable binding → offline provider relaunch. |
| Account contract | New refresh wins late authentication failure | An older error cannot invalidate the newer verified account or its persisted offline binding. |
| Account contract | Cache namespace separation | The same cache root cannot authorize another container or environment during a network failure. |
| Integration | Sign out and reverify | Real account provider blocks personal commands; SQLite reopening retains exact membership token and quantity; verified original account can edit again. |
| Integration | Account switch and return | Old service rejects a changed account; new account cannot read or mutate another account's cart; SQLite reopening recovers the original token and quantity. |
| Integration | Permission loss, reopening and restoration | Durable read-only observations block shared changes while private quantity remains editable; stale writable boundary cannot restore permission; fresh boundary restores shared writes. |
| Integration | Local saves, history and cloud observations | Real SQLite commands/history consumption do not invent import/export success or clear a failed export. Import completion leaves export failure; only observed export completion clears it. |

Existing proof remains with `ShopperSessionProviderTests` (notification invalidation and offline eligibility), `PersonalCartServiceTests` (account-qualified commands and recovery), `HomePermissionTests` (permission/causality rules and discovery), `ActiveHomeCoordinatorTests` (selection authority), and `CloudSyncStatusTests` (event ordering and classification). The new coverage composes those production boundaries and adds overlapping refresh and same-root namespace gaps.

Fixtures use fresh UUID directories owned by `SQLiteTestFixtureLifetime`, isolated `NotificationCenter` instances and actor-backed account doubles. Suspended lookups use bounded XCTWaiter results. A timeout resolves a terminal cancellation, cancels and drains the original refresh, and exits before starting another refresh. The gate retains its terminal result so a request arriving after timeout also resolves. Every started refresh is released and awaited before any throwing assertion. Reopening deliberately retains the same test store. The monitor loads a real `NSPersistentCloudKitContainer` on that isolated SQLite graph with no CloudKit options; only engine observations are supplied through its existing receive seam, using the actual persistent store identifier. The loaded monitor store identifier and URL are explicitly asserted equal to the source SQLite store. Monitor publication is cancelled first. A test-owned CloudKit container override tracks the real monitor history context and drains/resets it on its queue before store detachment and fixture deletion. The teardown defer is installed before store loading, so partial-load and assertion failures use the same cleanup. Queued main-actor publication carries only event values and is rejected by the reset generation; no background context reads remain after detachment. There are no live accounts, sleeps, retries, skips, expected failures or policy/baseline changes.

These checks establish local application contracts. They do not prove CloudKit server permissions, export/delivery scheduling, another device's receipt, or physical-device behavior; SHOPPING-30 retains that evidence.

Validation uses Xcode 27 and the iPhone 17 Pro simulator `15066BE0-662A-4573-AA67-12E84FA0C39C`, `ShoppingFast`, one serialized execution, and `-only-testing:ShoppingPersistenceTests/AccountCloudApplicationContractTests -parallel-testing-enabled NO`.

The first build failed before execution because two helper calls were shadowed by a local provider variable and the persistent store identifier required unwrapping. Those test implementation errors were corrected. Raw failure evidence remains at `/tmp/shopping-200-contracts-01.log` and `/tmp/shopping-200-contracts-01.xcresult`.

The corrected focused run passed **7 tests, 0 failures, 0 skips** (XCTest aggregate 0.319 seconds; build/launch excluded). Raw successful evidence is `/tmp/shopping-200-contracts-02.log` and `/tmp/shopping-200-contracts-02.xcresult`. `git diff --check` and `plutil -lint Shopping.xcodeproj/project.pbxproj` also passed. No production defect was observed. Milestone integration and broader Fast/CI validation remain parent-owned.

After review, lookup timeout handling was strengthened to guard the `XCTWaiter` result and terminally resolve/cancel/drain the original task before returning. Loaded source/monitor store identifiers and URLs are now compared directly. The follow-up focused run passed all 7 scenarios with 0 failures or skips; evidence is `/tmp/shopping-200-contracts-03.log` and `/tmp/shopping-200-contracts-03.xcresult` (exit 0). No production changes were needed.


Source states for the retained runs (from this branch's commit/log timeline):

| Run | Source revision before run | Working tree | Result |
| --- | --- | --- | --- |
| 01 | `696569a` | Dirty: new contract tests and PBX registration; initial test compile errors | Build failed, exit 65; no tests executed. |
| 02 | `696569a` | Dirty: corrected tests/PBX; evidence document was added while run was active | 7 passed, aggregate 0.319 seconds; exit 0. Committed afterward as `4e92471`. |
| 03 | `4e92471` | Dirty: gate timeout cleanup, store identity assertions and evidence update | 7 passed, aggregate 0.358 seconds; exit 0. Committed afterward as `85d4e36`. |

A subsequent fixture review found monitor history work could still be queued when the prior test detached the store. The follow-up container override preserves the production history fetch while joining its context queue before detachment. This follow-up will be validated from a clean committed source; its exact revision/result are recorded with the next run artifact.
