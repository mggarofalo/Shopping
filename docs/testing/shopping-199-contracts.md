# SHOPPING-199 application replica contracts

The new tests complement `PersonalCartServiceTests` rather than repeat its quantity versus checkout, remove/re-add versus checkout, late purchase rules, replacement occurrence recovery, and migration scenarios. The prototype contract suite remains architectural evidence; these tests exercise application types and real Core Data.

| New owner | Distinct proof |
| --- | --- |
| `PersonalCartReducerContractTests` | Missing transitive causality is rejected even when every parent is present; another owner's incomplete history cannot block or populate the requested scope; restore requires exact demand evidence and no replacement occurrence. |
| `ReplicaApplicationContractTests/testDeliveryDistinguishesPhysicalDuplicatesFromReplayAndPreservesConflicts` | Physical identity is separate from logical event identity: repeat transport is idempotent; distinct equivalent rows reach the reader; distinct conflicting rows remain persisted and produce `corruptRecord`. |
| `testConcurrentQuantityTipsConvergeWithCompleteEvidenceAfterReplayAndReopen` | Two offline quantity tips, including unspecified quantity, converge in opposite delivery orders with complete evidence, stable generation, fixed-point replay, and SQLite reopening. |
| `testConcurrentRemovalWinsQuantityAndExplicitRecartCapturesBothBranches` | Concurrent removal wins a quantity edit in both orders; demand remains; explicit recart creates a new generation containing both branches without inheriting quantity. |
| `testChildBeforeParentImportFailsClosedThenRecoversWithoutLosingSavedPayload` | A private quantity child imported first remains durable, reports incomplete import before and after reopening, and recovers when the missing parent arrives. |
| `testRestoreArrivingBeforeCheckoutConvergesAndDoesNotDuplicateRecovery` | An undo record arriving before its checkout does not manufacture history; complete import restores one original cart and one history entry, retaining the result after replay/reopening. |
| `testHouseholdOnlyImportsPreserveOtherShopperCartAndUndoNotice` | Advisory presence and purchase/retraction records cross SQLite replicas without purchaser-private data; another shopper keeps ownership/quantity, sees and loses the notice with receipt/undo, and cannot mutate the purchaser's token. |
| `testChangedUrgencyRetiresCapturedCheckoutWithoutChangingPrivateQuantity` | A shared need urgency edit retires exact captured checkout while preserving independent private quantity and outstanding demand after reopening. |
| `testArchivedRestrictionRemainsRestrictedAndUrgentAfterSQLiteCopyAndReopen` | Archived-only catalog restrictions retain explicit store identity, urgent status and unspecified quantity across a copied/reopened database; unrelated-store checkout cannot widen eligibility. |

`ReplicaContractFixture` owns every UUID fixture directory, controller and context through the established `SQLiteTestFixtureLifetime`. Replica inputs copy saved semantic records into their correct Core Data stores; services and reducers compute the asserted outcomes. No live account, CloudKit transport, normal app data, sleeps, retries, skipped tests, or weakened gates are used. This is local application-contract evidence, not live household-sharing proof.

Validation on October 5, 2026: the final focused ShoppingFast selection passed **11/11** (8 XCTest integration, 3 Swift Testing unit), with zero failures, skipped tests, expected failures, or runtime warnings. Environment: Xcode 27.0 (27A266a), iPhone 17 Pro Simulator iOS 26.5, serial execution, isolated derived data at `/tmp/shopping-199-derived`. The initial focused selection also passed 11/11; the final incremental run strengthened exact restriction failure and cross-account import rollback assertions. No production defects were found.

```sh
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -testPlan ShoppingFast \
  -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C' \
  -only-testing:ShoppingPersistenceTests/ReplicaApplicationContractTests \
  -only-testing:ShoppingPersistenceTests/PersonalCartReducerContractTests \
  -parallel-testing-enabled NO -derivedDataPath /tmp/shopping-199-derived \
  -resultBundlePath /tmp/shopping-199-final.xcresult
```

Raw final evidence: `/tmp/shopping-199-final.log` and `/tmp/shopping-199-final.xcresult`; initial evidence: `/tmp/shopping-199-focused.log` and `/tmp/shopping-199-focused.xcresult`. `git diff --check`, Swift parse validation and project plist validation passed. The new files are registered only in `ShoppingPersistenceTests` and run in ShoppingFast. Broader integrated Fast and exact-source CI remain parent milestone validation; no remote workflow was dispatched.
