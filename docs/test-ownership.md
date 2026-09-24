# Test proof ownership

This ledger records the SHOPPING-119 redesign from `e341831`. It explains why a scenario remains, which setup can be replaced with a fixture, and where consolidated assertions are now proved. Test counts are inventory, not a measure of behavioral coverage. Current plan membership and commands live in [test strategy](test-strategy.md) and [continuous integration](continuous-integration.md).

## Routine feedback and broader regression

Apple recommends a reduced pull-request plan containing unit tests and key UI workflows on one platform, with the broader suite running separately. Apple also recommends explicit setup so a test does not depend on a previous test's teardown. [Author fast and reliable tests for Xcode Cloud, WWDC22](https://developer.apple.com/videos/play/wwdc2022/110361/)

Shopping applies that guidance through [ShoppingAcceptance](../ShoppingAcceptance.xctestplan), the canonical quick selection. All deterministic tests remain included; six UI scenarios add representative proof of catalog add, remembered creation/cancellation/relaunch, one-time creation, scoped checkout/undo, abrupt-exit recovery, and accessibility-sized checklist controls. The selected scenarios remain in `ShoppingFull`; appearance variants and the broader interaction matrix stay available there. See the CI document for the separate fast-only coverage gate and manual full-run policy.

This is a feedback policy, not a claim that a small application should finish every possible test within an industry-standard duration. Runtime goals must come from measured, passing runs on the actual toolchain and runner. Inventory changes must accompany before/after timing comparisons.

## Ownership rules

- Put rule permutations, normalization, identity validation and rollback in the fast layer. Keep a UI owner for the control, navigation or rendering contract; a service test cannot establish that a button invokes the service correctly.
- A fixture may supply the state before the action under test. It must not execute that action or seed its expected result. Each UI test receives a fresh store identity; deliberate relaunch reopens the same store without fixture reseeding.
- Keep a representative complete creation/edit flow even when other scenarios seed equivalent prerequisites. Check fixture shape and persistence at the fast layer so changing setup cannot quietly change the scenario.
- Before retiring or shortening a test, record the exact removed proof and its retained owner. Similar names or coverage percentages are insufficient. Separate ordinary relaunch, abrupt termination, cancellation, confirmation, accessibility and appearance boundaries.
- Verify the selected test identifiers and outcomes after changing a plan. A quick plan must remain a deliberate selection; the full plan must still execute the maintained regression inventory. Failures, skips and changed inventories remain visible in timing evidence.

## Promotion: retain choices, replace unrelated setup

UI names below are methods in [OneTimePromotionUITests.swift](../ShoppingTests/OneTimePromotionUITests.swift). Fast owners are methods in [OneTimePromotionTests.swift](../ShoppingTests/OneTimePromotionTests.swift).

| Maintained UI scenario | Unique UI proof retained | Setup decision and fast owner |
| --- | --- | --- |
| `testPromotionCancelAndExplicitCreatePreserveOccurrenceAfterRelaunch` | Create a one-time need through the editor; cancel a promotion draft without creating a catalog item; explicitly create the remembered item; reopen the app and verify the same occurrence, notes, quantity, urgency and catalog presence. | Keep the complete creation and promotion path. `testCreatingPromotionPreservesOccurrenceAndSeparatesCatalogFromCurrentNeed` owns field/identity rules; `testSQLiteRelaunchPreservesUUIDCartedDraftAndCatalogRules` owns disk round-trip; neither replaces this UI wiring and app-relaunch proof. |
| `testLinkExistingUsesSavedRulesWithoutOverwritingCatalog` | Select an existing catalog item in the promotion UI; preserve the occurrence and its temporary fields; display the saved catalog purchase rules; do not create a catalog entry under the old one-time title. | `promotionLinkExisting` seeds a one-time Breakfast cereal need and unarchived Granola catalog item with no active need. `testLinkPreservesCatalogRulesAndActiveConflictPreservesBothNeeds` owns linking semantics. The UI still performs the link. |
| `testCollisionAndActiveConflictRequireExplicitDistinctChoice` | Show the collision choice, surface an active-need conflict, cancel without changing the one-time occurrence, and explicitly create a distinct catalog item while keeping two separate needs. | `promotionConflict` seeds an active remembered Granola and a separate one-time Granola. `testLinkPreservesCatalogRulesAndActiveConflictPreservesBothNeeds` and `testCollisionNeedsExplicitDistinctChoiceAndOverflowRollsBackEverything` own conflict/atomicity rules. The UI still performs every promotion decision. |

The link/conflict fixtures replace repeated `createOneTime` setup. Its quantity increment, switch, keyboard and save interactions remain exercised by the complete first promotion scenario. Additional owners include `ChecklistUITests/testQuickQuantityAndUncartPreserveUrgencyNotesAndPersist` and `GroceryEditingUITests/testAddItemFocusNotesAndInlineCategoryPreserveDraftAtLargeText`.

The original link scenario removed Granola through the editor merely to leave its catalog item without an active need; the redesign seeds that prerequisite instead. That action and its immediate undo proof belong to `ChecklistUITests/testEditorRemovalInCartKeepsUndoVisible`: removal must complete without an intervening confirmation to satisfy its row-absence and undo assertions. `GroceryEditingUITests/testOneTimeIndividualRemovalAndUndoDoNotCreateCatalogKnowledge` explicitly checks the editor's no-confirmation behavior for a one-time need. `ChecklistUITests/testSwipeRemovalSupportsUndoAndRelaunchRecoveryWithoutConfirmation` separately owns remembered swipe removal and recovery. Promotion does not need to repeat these prerequisites.

[PreviewFixtureTests.swift](../ShoppingTests/PreviewFixtureTests.swift), `testPromotionFixturesPreserveDistinctOccurrenceAndCatalogStateAfterReopen`, checks the new fixture fields, catalog rules, independent occurrence identities, active versus inactive remembered need, catalog isolation and SQLite reopen. The fixtures do not seed a completed promotion. Existing `OneTimePromotionTests/testInjectedSaveFailureIsAtomicAcrossSQLiteReopen` and invalid-identity/scope cases remain fast regression owners.

## Suggestions and store defaults

UI methods below are in [GroceryEditingUITests.swift](../ShoppingTests/GroceryEditingUITests.swift).

| Scenario | Retained UI proof | Rule/setup owner |
| --- | --- | --- |
| `testInactiveCatalogSuggestionRequiresSelectionAndKeepsSavedDetails` | Typing `cafe` leaves the typed text and keyboard intact, displays the Café au lait suggestion and context, cancellation creates no need, and selecting the suggestion displays saved notes with normal urgency. | `inactiveCatalogSuggestion` replaces an unrelated trip through the catalog editor. `PreviewFixtureTests/testInactiveSuggestionFixtureHasSavedDetailsWithoutCreatingACurrentNeed` verifies its saved metadata and absence of a current need. `CatalogFilterUnitTests/suggestionNormalization` and `suggestionRankingAndExamples` own matching; `CatalogManagementTests/testCatalogAddCopiesSavedDetailsWithNormalUrgencyAndSurvivesRelaunch` owns saved-data defaults. |
| `testActiveMatchFocusPreservesUrgencyAndExplicitNeedAgainUncarts` | Fuzzy matching opens the existing need with its notes/urgency; a one-time title supplies no active catalog suggestion; editing a carted match does not uncart it; the explicit Need again action does. | `CatalogFilterUnitTests/suggestionRankingAndExamples` owns fuzzy scoring; `GroceryNavigationUnitTests/requestedNeedFocusIsConsumedByMatchingNeed` owns focus routing; `CatalogManagementTests/testCatalogSuggestionAtomicallyRevalidatesStatusAndItemRevision` owns stale status handling. These do not replace the distinct visible Edit current and Need again actions. |
| `testStoreDefaultDoesNotOverwriteAnExistingItemsRules` | Urgent-only and selected-store scope affect the visible active-match controls; opening an existing Any Store item preserves its purchase controls; a new item receives the selected store default. | `CatalogFilterUnitTests/independentPurchaseRuleMatrix` and `suggestionEligibility`, `GroceryNavigationStateTests/testUrgencyCompositionCannotWidenSelectedStoreEligibility`, and `CatalogManagementTests/testScopedCatalogAddCannotWidenFiltersAndCreatesUrgentNeed` own rule permutations. Representative UI scope propagation and purchase-control state remain UI-owned. |
| `testSuggestionContextRemainsReachableAtAccessibilityTextSize` | Suggestion context remains readable/reachable at accessibility XXXL while the draft and keyboard workflow remain correct. | Kept independently. Matcher tests cannot establish layout or accessibility reachability. |

The repeated Add-sheet presentations in the active-match and store-default scenarios are shortened by changing the search query within an already open sheet. Their assertions remain: ordinary editing and explicit renewal still use distinct actions, one-time exclusion still queries the UI, and urgent/store filtering still checks the visible suggestions. The required cancel, editor navigation and draft-default boundaries remain.

The catalog editor setup removed from the inactive-suggestion scenario remains covered by `ShoppingLaunchTests/testCatalogEditorCancelAndSavedAnyStoreItemDoNotCreateGroceries`, which creates catalog metadata, saves it, exercises cancel/edit, and verifies that no grocery appears. `CatalogManagementTests/testAtomicCatalogSaveChangesMetadataAndRulesWithoutChangingNeedFieldsAfterReload` owns catalog persistence rules.

The one-time suggestion-exclusion assertion is retained: `CatalogRefreshUITests/testGroceryAddNewPrefillsCatalogEditorAndOneTimeRemainsExplicit` proves explicit creation and absence from Catalog, but does not search for that one-time need afterward. Those are different UI boundaries.

## Ordering consolidation

`OneTimePromotionUITests/testCartAndCheckoutUseCategoryOrderInsteadOfAddedOrder` is retired after moving its assertions into `ChecklistUITests/testGroceryCartAndCheckoutUseCategoryOrder` (formerly `testAllAndStoreGroupsUseCategoryOrder`). The receiving test keeps all original grocery All/store ordering assertions, then verifies cart and checkout ordering using the same Bananas, Strawberries and Granola dataset as the retired method. It retains both within-category name ordering (Bananas before Strawberries) and cross-category ordering (Produce before Pantry) in both destinations. The merged cart/checkout checks run in the selected Costco scope rather than the former standalone All scope; all three rows are eligible, so the expected visible dataset remains identical.

Strawberries starts carted; Bananas and Granola are carted through the UI afterward. Requiring Bananas before Strawberries therefore distinguishes category/name ordering from cart insertion order. The merged test still asserts cart row geometry and checkout row sequence. `ChecklistSafetyTests/testCartedOrderUsesCategoryThenNameAndRecartDoesNotPerturbIt` and `testListAndCartStoreProjectionsUseIdenticalCategoryAndItemOrdering` own projection rules, including unfiltered cart/checkout ordering in the former; they do not replace the retained rendered ordering assertions.

`ChecklistSafetyTests/testCheckoutCapturesAllCartedRowsAndSkipsLaterChangesWithoutLosingCatalog` continues to own captured occurrences and revision safety. Its late-change matrix is not repeated through UI merely to increase the number of checkout tests.

## Catalog archive and duplicate-editor setup

The second redesign loop shortens two scenarios in [ShoppingLaunchTests.swift](../ShoppingTests/ShoppingLaunchTests.swift):

| Shortened scenario | Retained UI proof | Removed setup and retained owner |
| --- | --- | --- |
| `testDirtyArchivedCatalogRestoreConfirmationCancelKeepsEditorDraft` | Reveal an archived item using the catalog filter, edit its name and notes, request Restore, choose Keep editing, and verify both draft values are unchanged. | `archivedCatalogItem` supplies populated data with Granola archived and its current need still active. `testCatalogArchiveFilterAndRestorePreservesActiveGrocery` retains the complete editor Archive confirmation, archived filter, Restore action, filter reset and active-grocery proof. The shortened test still performs the dirty-draft Restore interaction itself. |
| `testCatalogEditorCancelAndSavedAnyStoreItemDoNotCreateGroceries` | Cancel a new catalog draft; create and save notes, category and purchase rules; cancel and save edits to the existing item; verify no grocery is created; delete the unreferenced catalog item. | The intervening Add → duplicate name → Edit existing → Cancel detour is consolidated into `CatalogRefreshUITests/testNewCatalogItemAppearsWithoutNavigatingAway`, which already uses Add → Fresh basil → Edit Fresh basil. Its existing editor-title assertion now also requires keyboard disappearance. The launch test retains the editor Cancel action and unchanged-name assertion after entering that same editor from the saved row. |

`PreviewFixtureTests/testArchivedCatalogFixturePreservesActiveNeedAndRulesWithoutChangingAnotherStore` verifies the archived flag, saved rules/category, unchanged active need fields, and independent household/item/need identities against a separate populated store. `CatalogManagementTests/testArchiveRestoreRetainsActiveNeedAndArchivedReadFilterIncludesCatalogItem` remains the fast owner of archive/filter/restore persistence semantics. The fixture replaces the prerequisite archive action only; it does not seed the draft, confirmation or expected cancellation result.

The duplicate-name route still has UI proof of selecting the existing editor and dismissing its keyboard; editor cancellation remains covered through its ordinary row entry. This consolidation does not claim a separate duplicate-route cancellation assertion remains. No performance saving is established by the ownership mapping itself; passing timing evidence determines whether to keep each change.

## Boundaries deliberately kept separate

| Boundary | Existing owner retained | Why it remains |
| --- | --- | --- |
| Clear completes, UI acknowledges it, then the app relaunches | `ChecklistUITests/testOneTimeClearRecoverySurvivesRelaunchWithoutRemembering` | Proves the normal recoverable-clear workflow, restored cart state, uncart and catalog isolation. |
| Clear commits, process exits before UI acknowledgement | `ClearInterruptionUITests/testCommittedOneTimeClearRecoversAfterExitBeforeUIAcknowledgement` | Proves the interruption hook, launch recovery, original occurrence identity, notes and one-time lifecycle. A normal terminate/launch is not the same failure boundary. |
| Scoped checkout cancellation and confirmation | `ChecklistUITests/testCartInheritsGroceryScopeAndCheckoutCapturesVisibleItems` | Proves destructive actions use the visible scope and that cancel, confirm and undo controls work. |
| Appearance and text-size variants | `ShoppingAppearanceUITests` and `ShoppingDeviceUITests`, including `testVisibleGroceryRowAccessibilityAtLargestText` and `testCheckoutEditorAndSettingsAtLargestText` | Rendering, hit targets and accessibility are UI evidence. Quick acceptance selects one representative accessibility scenario; the full suite retains the variants. |
| Actual device and household sharing | The device protocol and SHOPPING-30 | Simulator automation and local replicas cannot establish signed-device, VoiceOver or real two-account CloudKit behavior. |

## Maintaining this ledger

Update the relevant row when adding a new UI owner, changing a fixture boundary or consolidating a scenario. Keep exact method names so a reviewer can locate the proof. Use [the testing skill](../.agents/skills/shopping-testing/SKILL.md) and [read-only reviewer](../.codex/agents/shopping-test-reviewer.toml) for the corresponding implementation and review checks. Test execution evidence belongs in the timing report and PR, not in an unmeasured promise of runtime savings.

## Personal-cart architecture contract (SHOPPING-118)

`Prototypes/PersonalCartContract/Tests/PersonalCartContractTests/CartContractTests.swift`
owns the isolated architecture fixture: causal same-owner edits, concurrent quantity and
remove outcomes, unseen edits versus checkout in both delivery orders, new occurrence
isolation, A/B/C checkpoint reopen/replay, owner isolation, multiple purchase receipts and
scoped restore, stale/id-reuse rejection, and presence repair reaching a fixed point.
Run it with `swift test --package-path Prototypes/PersonalCartContract` on the host.
This does not replace any app Fast or UI proof and is not included in app coverage.
SHOPPING-103 must port these contracts to real Core Data/account/migration boundaries;
SHOPPING-30 still owns live permissions and cross-device delivery. See
[ADR 0002](architecture/0002-personal-carts.md).

## Personal-cart production integration (SHOPPING-103)

`PersonalCartServiceTests` owns account-qualified commands, independent cart quantities, exact captured checkout, competing receipts, conditional demand, SQLite recovery and migration decisions. `ShopperSessionProviderTests` owns real-provider state transitions with injected account lookup, durable account binding, offline eligibility and stale response rejection. `PersonalCartActivationTests` owns the local-to-account copy ledger, source preservation and interrupted-copy replay; it does not prove CloudKit delivery.

`PersonalCartUITests/testPersonalCheckoutAndRecoverySurviveRelaunch` owns the actual personal-service UI route from grocery swipe to captured checkout, reopening SQLite and undo. `testLegacyCartRequiresExplicitClaim` proves old cart flags are not automatically assigned. `testOtherPurchaseKeepsOwnEntryUntilExplicitBuyAnyway` starts with two shoppers’ competing claims and a completed other-shopper purchase, then verifies retained own entry, notice, and explicit acknowledgement before the tested purchase. Its fixture supplies prerequisites only. `testPurchasedRememberedItemCanBeRequestedAgain` owns the catalog re-add route after fulfillment while retaining another occurrence in the personal cart. `testRetainedCartCanBeRemovedAfterHouseholdDisappears` verifies relaunch without recreating a household and the saved-cart cleanup route. These scenarios supplement the retained legacy workflow owners while existing installations await explicit activation; they do not substitute for account/replica or physical sharing tests.

Personal UI fixtures require both an isolated UI-test store path and explicit DEBUG launch options. Normal launch uses the real account provider; previews and UI fixtures never establish authenticated or live-cloud evidence. SHOPPING-30 and SHOPPING-122 remain the physical account/watch proof gates.

## Watch presentation and persistence (SHOPPING-120/121)

`WatchShoppingSessionTests` owns immutable checkout retry, error snapshot retention, store-capture validation and synchronous authority invalidation during suspended commands. `WatchShoppingUITests` owns native store switching, swipe/card actions, purchase-notice choice, captured checkout/recovery, large text and last-row clearance. Presentation fixtures are DEBUG-only, explicit and recreated per launch; they prove controls and rendering, not disk persistence.

The durable Watch UI scenarios use `WatchPersistentTestFixture` with the production adapter and Core Data SQLite. Each test has a unique UUID directory, explicit seed marker, same-store relaunch and explicit cleanup launch. `testDurableQuantityCheckoutRelaunchAndRestore` owns quantity editing, persisted cart state, confirmed checkout, relaunch and owner recovery through the actual Watch UI. `testDurableMissingAndRevokedHouseholdRetainPrivateCleanupAndHistory` supplies a previously carted item and completed purchase, then performs private removal through the UI and verifies retained history after relaunch. It simulates lost membership; it does not establish CloudKit revocation delivery. `testDurableEmptyHouseholdDiffersFromMissingSetup` distinguishes an imported empty household from an unimported replica. Every Watch UI launch uses an explicit fixture, never a real simulator account or household.

`PersistentWatchShoppingServiceTests` owns real-adapter SQLite reopening, stale command rejection, retained private cleanup, store restrictions, captured checkout and account invalidation. `PersonalCartPresentationTests` proves malformed shared receipts cannot hide private cart removal/history. `CloudConfigurationTests` runs in both hosted app targets and verifies their packaged container/environment settings, iPhone background mode and Watch independence/sharing configuration. `PersonalCartServiceTests` also verifies detached/account-changed share workers cannot acknowledge pending associations. These are local authority and packaging checks, not live server delivery proof.

Watch tests run in the `ShoppingWatch` scheme separately from iPhone Fast coverage. Existing iPhone acceptance selection and coverage thresholds remain unchanged. Real owner/participant bootstrap, cross-device CloudKit delivery, physical accessibility and phone-powered-off Series 11 behavior remain SHOPPING-30/122 evidence.

## Household setup and legacy review regression (SHOPPING-133)

`PersistenceContainerTests/testActivationRetiresMountedGroceriesBeforeInvalidatingFetchedObjects`
owns the real `PersistenceRootView`/`GroceriesView` hosting boundary: activation
retires presentation authority before a queued Core Data callback and waits for
the loading view’s lifecycle before detaching the old store.
`testAccountFailureUsesSamePresentationRetirementBoundary` owns the same
authority ordering during an account failure.
`testActivationRejectedDuringRetirementDoesNotBlockLaterRetry` covers overlapping
activation and retirement without permanently blocking retry.
`testRetiredMountedCartIgnoresContextInvalidationNotifications` retains the actual
cart screen through context invalidation and verifies its retired callback guard.

`PersonalCartUITests/testHouseholdSetupCopyRetiresVisibleGroceriesBeforeAccountFailureAndRelaunch`
owns Settings → Set up household → Copy existing groceries, the visible failure
state, and recovery after relaunch. The fixture supplies legacy data and an
isolated unavailable account; the UI performs setup itself. It cannot prove
real CloudKit delivery.
`testLegacyDiscardRemovesPendingCardAfterRelaunchAndKeepsEarlierHistoryRoute`
owns the discard control, pending-card disappearance, same-store relaunch, and
separate earlier-history navigation. `PersonalCartServiceTests` owns migration
selection, equivalent duplicate identities, durable claim/discard receipts,
late merges, and preserved scoped historical recovery without personal-cart
ownership. No fixture contains a copy of a shopper’s real records.

`CloudSyncStatusTests` runs in both app targets and owns per-store/per-operation
error retention, observed success wording, partial-error classification, stale
event ordering, and account/container reset. Successful engine events are
never treated as proof that another device received the records.

## Compact category tables and Watch store counts (SHOPPING-134)

`ShoppingAppearanceUITests/testCompactGroceryAndPersonalCartTablesAtStandardAndLargeText`
owns the grocery-to-personal-cart interaction with native category tables, row
hit targets and screenshot evidence at standard/light and largest-accessibility/dark
settings. It waits for the specific cart toast to disappear before checking the
checkout control. The fixture supplies groceries only; the UI performs the cart
action. Existing personal checkout/recovery and legacy scoped-checkout tests
retain their lifecycle and scope assertions.

`PersistentWatchShoppingServiceTests` owns per-store count semantics, including
Any store, sole/multiple restrictions, archived-only and unresolved rules,
independent same-title occurrences, selected-store independence, own versus other
cart membership, removal and fulfilled demand. Native Watch UI tests own count
labels in the chooser and actual footer/last-row reachability; visual clearance
is not a substitute for a successful row interaction.

## Watch item-card Add transition (SHOPPING-135)

`WatchShoppingSessionTests` owns command completion results: success is returned
only after an applied snapshot from the same authority; save failure, busy calls,
changed authority and suspended stale results cannot trigger success navigation.
`WatchShoppingUITests` owns card dismissal after Add using the real isolated SQLite
adapter, preserved quantity across relaunch, and failed Add retaining its draft
and allowing retry. Root errors are presented from the outer navigation stack so
pushed item cards can show them; checkout sheets retain their own exclusive alert
presenter. Large-text row revelation uses small final crown adjustments while
retaining whole-row visibility and actual tap assertions. The existing durable
swipe-add/checkout/recovery route remains
separate. The DEBUG-only add-failure fixture fails before mutation and is never
selected during normal or release launch. Generation-qualified persistence IDs
and command tokens remain unchanged.
