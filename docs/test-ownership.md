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

## Catalog contrast audit synchronization (SHOPPING-136)

`ShoppingDeviceUITests/testCatalogRowSupportingTextContrast` waits boundedly for
Search submission to dismiss the keyboard before asserting one visible, hittable
catalog row and auditing its contrast. Hosted run 36067861081 recorded a keyboard
existence check during dismissal; the video ended with it gone. The wait retains
the failure for a keyboard that remains open, all row bounds, and the unchanged
contrast audit. It does not retry the test or add production behavior.

## Checkout feedback synchronization (SHOPPING-137)

`PersonalCartUITests/testPersonalCheckoutAndRecoverySurviveRelaunch` and
`ChecklistUITests/testCartInheritsGroceryScopeAndCheckoutCapturesVisibleItems`
wait boundedly for the specific last-carted item's feedback to disappear before
tapping checkout once. Hosted run 36075824376 recorded the Granola feedback
covering the checkout action during the personal-cart test. Hittability alone
does not prove an overlay has gone. Both tests retain their checkout assertions;
the personal-cart test still terminates, relaunches without reseeding, and undoes
the purchase. No action retries or production timing changes are introduced.

## Consistent list surfaces and content-sized rows (SHOPPING-138)

`ShoppingAppearanceUITests/testCompactGroceryAndPersonalCartTablesAtStandardAndLargeText`
compares a bare grocery row with a notes-and-assignment row in the existing
populated fixture, verifies expanded height and retained metadata, and keeps
quantity targets and the actual cart interaction reachable at standard and
accessibility sizes. The other appearance methods retain catalog, editor,
filter and Settings screenshots in light/dark modes; native management selection
and catalog contrast retain their existing UI owners. No fixture or persistence
contract changes are required. See [list presentation](list-presentation.md) for
the audited List/Form surfaces and deliberate non-row exceptions.

## Household association status (SHOPPING-139)

`ShareAssociationRetryTests` owns the durable association-journal boundary: records for a household without a share remain queued for later sharing without counting as actionable pending work; existing-share work and errors remain visible; overlapping retries serialize and return the final pass result. The injected pass replaces only CloudKit interaction, so these tests do not establish live household delivery. `PersonalCartServiceTests` retains detached-store/account authority validation.

`WatchAssociationStatusTests` owns warning transitions, notification deduplication, preservation and priority of invitation/history/account/CloudKit messages, and rejection of old-runtime or older overlapping completions. `CloudSyncStatusTests` continues to own engine-event classification and per-store import/export failure retention. Real cross-account sharing remains SHOPPING-30.

## Catalog membership actions and text padding (SHOPPING-140)

`CategoryManagementUITests/testCatalogSwipeRemovesExistingNeedAndAddsAgainWithoutLeavingCatalog` replaces the old catalog swipe focus-existing/Need-again scenario because that interaction is explicitly superseded. It owns Remove vs Add controls, remaining in Catalog, Undo, same-store relaunch, re-add and legacy-carted removal. Catalog editor save/add and batch-add rules retain their existing owners.

`PersonalCartServiceTests/testCatalogRemovalRetainsPersonalCartAndOffersAddAfterRelaunch` owns catalog membership, revision-qualified removal, retained private cart membership, SQLite reopen and undo through the same commands used by Catalog. `testCatalogMembershipIsolatesDuplicateNeedsAndKeepsUnrelatedItemsAvailable` proves one ambiguous imported occurrence group does not prevent healthy rows from reporting Add or Remove. Existing grocery removal tests retain stale revision, scope and failure rollback coverage.

`ShoppingAppearanceUITests/testCompactGroceryAndPersonalCartTablesAtStandardAndLargeText` now checks equal padding around actual multiline text bounds as well as expanded row height, visible assignment and independent controls. The existing Catalog appearance and contrast tests supply leading-aligned store-summary screenshots in both appearances and text sizes. Screenshot review is required alongside geometry assertions.

## Watch sync presentation (SHOPPING-141)

`WatchSyncStatusTests` owns typed waiting/working/recent-activity/attention projection, including setup-only activity, unrelated-store success, and preserved account/sharing/history/recovery details. `WatchShoppingUITests` owns the compact control, absence of routine status rows, stable control placement across completion, on-demand details and dismissal, and accessibility-sized interaction. The store-switch/swipe scenario retains the surrounding shopping workflow. These tests do not prove delivery to another device.

## Fresh keyboard readiness (SHOPPING-142)

Hosted run36157514880 recorded the first catalog save/add test sending text while the keyboard initialized, followed by Apple's QuickPath introduction and a partial name. The fresh hosted simulators now set the observed `DidShowContinuousPathIntroduction` keyboard preference before tests, preventing unrelated first-use onboarding. `CatalogRefreshUITests/testSaveAndAddToListWorksForNewAndExistingCatalogItemsWithoutDuplicates` explicitly focuses the name field, waits boundedly for its keyboard and exact entered value, and retains the enabled, save/add, editor navigation and no-duplicates assertions. There is still one typing action, no retries, no relaxed timeout policy, and no product behavior or test-selection change.

## Watch scrolling header (SHOPPING-143)

`WatchShoppingUITests/testStoreAndSyncScrollAwayAndReturnOnlyAtTop` owns native header disappearance, absence after a small reverse scroll, retained bottom actions, and usable sync/store navigation after returning to the top. The bounded return-to-header helper replaces the previous fixed-header assumption; history navigation preserves the direct chooser route for missing/revoked households. Existing empty, large-text, store/swipe and sync-completion cases retain their behavior with the scrolling row. No model or synchronization contract changes.

## Catalog column layout and inline assignment (SHOPPING-144)

`ShoppingAppearanceUITests/testCatalogColumnsPreserveLongTextAndCompleteStoreAccessibility` owns the 2:1 catalog presentation at standard/light and accessibility/dark sizes, multiline supporting content, full purchase-rule accessibility and full title in the editor. Its isolated `catalogColumns` fixture adds a long title, three stores including a long store name, and three supporting lines. Existing compact-table appearance coverage retains assigned/unassigned groceries, symmetric padding, independent quantities and cart actions; the extra-height assertion follows supporting notes rather than requiring assignment to occupy a separate line. Existing catalog membership tests retain native swipe ownership, and catalog grouping/contrast tests retain archived rules and accessible metadata.


## Shared rows and Stores-style controls (SHOPPING-157)

`ShoppingAppearanceUITests/testGroceryAndCatalogShareRowHeightAndFilterControlDimensions` owns matching bare Grocery/Catalog row heights, store/filter geometry, plus dimensions and complete store accessibility. The existing content-sized table test keeps title/notes containment and symmetric padding; a short note may fit the shared Catalog minimum without increasing row height. Quantity-bearing and note-bearing rows no longer imply a height ordering. Existing long-column and large-text screenshots retain their proof.

`CategoryManagementUITests/testPeopleUseStoresSelectionControlsAndKeepAssignedPeopleOnDelete` owns Stores/People control dimensions, Select All/Deselect All, Done clearing selection and the confirmed archive of an assigned person. Existing management tests retain native multiselection and large-text controls. The three people-batch cases in `StoreManagementTests` own foreign-scope exclusion, stale-revision skips, retained assignments, restore, late assignments and preservation of an archive preview when an assignment disappears. No acceptance-plan inventory changes.

## Account-bound homes and retained drafts (SHOPPING-124)

`ActiveHomeCoordinatorTests` owns exact account/container/environment/graph selection,
multiple-root choices, reordered discovery, incomplete and duplicate identities,
account suspension/return, access downgrade, stale command rejection before save,
per-home filters and draft lease isolation. Draft lease cases retain the original
scope, prevent late completion from deleting a reopened draft, and prevent parent
completion from resurrecting nested drafts.

`ActiveHomeBootstrapTests` owns actual startup, explicit owned-home creation,
selection retirement and the committed-creation/discovery race using isolated
SQLite and an injected account provider/store opener. Its creation checkpoint
forces another discovery after creation's snapshot but before reconciliation;
a committed graph must not become a retryable creation failure.

`PersonalCartUITests/testCreateAndSwitchHomesPreservesOriginalGroceriesAfterRelaunch`
owns rendered creation, positively selected second-home identity before and after
relaunch, and returning to the original groceries. `testAccountScopedCatalogDraftSurvivesRelaunchAndCancelDiscardsIt`
owns restoring a catalog draft on same-account relaunch and explicit cancellation.
Cross-account draft separation belongs to the fast tests, not that UI scenario.
The DEBUG `SHOPPING_UI_TEST_ACTIVE_HOMES` flag operates only under the existing
unique UI-test store path. It replaces account lookup and store opening with local
fixtures while exercising production bootstrap/coordinator code. It cannot prove
CloudKit membership, account permissions, invitation delivery or two-phone sharing.

## Recoverable home creation and graph audit (SHOPPING-125)

`HomeCreationTests` owns durable intent before saving, replay after reopening the
SQLite store, preservation of a subsequently renamed home, account/store rejection,
write-denial rollback, partial-graph refusal, and stale acknowledgment/resume
identity. `ActiveHomeBootstrapTests` retains the production bootstrap wiring.
`HomeShareGraphTests` owns complete relationship traversal, archived constraints,
one-time and shared recovery records, exclusion of the separate private graph,
and rejection of foreign-home relationships and duplicate child identities.
These local checks do not establish CloudKit share creation, export, or server-side
failure recovery; managed transport and live evidence have separate owners.

`HomeShareProvisionerTests` owns existing-share reuse, persisted identity mismatch,
missing known-share retention, lost callback reconciliation, explicit same-root replay,
foreign-journal rejection, failed local preparation, and concurrent/cancelled waiters.
Its held callback and observed active request count force overlap deterministically.
The production adapter is compiled against actual managed APIs; these mock cases
cannot prove native crash atomicity, cross-device serialization or exported privacy.
See `docs/architecture/home-share-provisioning.md` for that boundary and live gates.

`PersonalCartUITests/testResumeUnacknowledgedHomeCreationRetainsOriginalHomeAfterRelaunch`
owns the rendered pending-creation resume control, disabled name editing, retention
of the only original home/groceries and durable acknowledgment after another relaunch.
Its DEBUG fixture seeds an unacknowledged command for the existing populated home
only under the fresh UI-test store and active-home fixture flags. The fixture flag is
removed before relaunch so the test exercises the journal, not repeated seeding.

## Incoming invitations (SHOPPING-126)

`HomeInvitationInboxTests` owns durable pre-authentication ingress, full share identity,
account binding, duplicate coalescing, explicit retry, replacement metadata, in-flight
dismissal, restart before/after acceptance, corrupted-journal preservation, and activation
holds. Its worker tests hold lazy opening off-main, establish main-actor progress,
assert FIFO snapshots, and retain later work after an operation fails.
`HomeInvitationControllerTests` owns orchestration with a simulated transport:
store/account readiness, already-joined lookup, sequential invitations, replacement links
arriving during another acceptance, sanitized offline errors, account switches, and import
failure recovery without repeated acceptance. A gated startup test keeps an incoming
invitation's activation hold while an earlier empty worker snapshot publishes. Pending
renewals after acceptance invalidate old import tokens. Their returned graph values do not prove
native imported relationships or CloudKit membership.

`ActiveHomeBootstrapTests/testColdInvitationRestoresSelectionHoldBeforeFirstHomeDiscovery`
owns the production bootstrap ordering which prevents sole-home autoactivation.
`PersonalCartUITests/testDismissPendingInvitationPersistsAfterRelaunchAndKeepsGroceries`
owns the rendered invitation notice, dismissal, and retention after relaunch. Its DEBUG
fixture requires a unique UI-test store and the active-home fixture; the seed flag is
removed before relaunch. It uses no real CloudKit account or archived native capability.
Native cold/warm delivery and real two-account sharing remain SHOPPING-30 proof.

## Safe home adoption (SHOPPING-127)

`HomeAdoptionSnapshotTests` owns exact persisted graph verification across the real
`PersonalCartActivation` SQLite copy: domain UUIDs/relationships, archived-only
restrictions, optional quantities, one-time identities, ordering/People, opaque
recovery data, unchanged cart attribution, and detection of changed values.
`HomeAdoptionJournalTests` owns durable approval/copy/verification checkpoints,
account and source-store mismatch, existing destination refusal, corrupt approval
retention, and completed retries preserving later edits.

`HomeAdoptionBootstrapTests` owns keeping the mounted original usable when account
verification fails, rejecting stale approval, detaching before account opening, and
returning to the original local home—including offline relaunch. The existing mounted
Groceries/FRC retirement scenario in `PersistenceContainerTests` retains its real UI
mount/unmount and post-retirement command checks; the injected failure now occurs
at account-store activation, after successful account verification and detachment.
This replaces the previous assumption that identity lookup itself should retire the
original view. `ActiveHomeBootstrapTests` now explicitly awaits preparation/approval
before inspecting retirement, rather than assuming synchronous account lookup.

`ActiveHomeCoordinatorTests` owns durable Not now behavior when no home is active,
plus the existing exact-home/account selection boundaries.
`HomeInvitationControllerTests` owns hiding a resolved invitation and reopening a
fresh pending grant. Simulated import and decision evidence does not establish native
share receipt or the two-iPhone invitation workflow; SHOPPING-30 retains that gate.

`PersonalCartUITests/testInvitationSetupKeepsOriginalOnDeviceAndReturnsAfterRelaunch`
owns the visible named setup choice, Not now followed by reconnect, keeping the home
on-device, navigating back to its groceries, and relaunch without fixture reseeding.
Its original and simulated account stores have distinct identities; its account,
invitation journal and preferences are scoped to the unique UI fixture.
`testHouseholdSetupAccountFailureKeepsVisibleGroceriesAfterRelaunch` replaces the old
setup-failure expectation that the original UI should retire before identity lookup:
it now asserts the visible error and usable original groceries before and after
relaunch. These tests do not simulate a native accepted share.

The controller recovery tests also own resurfacing hidden in-flight invitations
when import is ready or native acceptance fails. Hiding progress cannot remove the
only in-app path to an explicit home decision or retry.

The imported-home cases in `HomeAdoptionBootstrapTests` execute the actual Open and
Not now commands with two distinct SQLite stores. They own exact invitation-entry
resolution, original-home/private-cart retention and return, no-original deferral
across refresh and relaunch, blocking an invitation still loading in the general
picker, and allowing a different previously joined share in the same store. The
fixture substitutes participant-store attachment and share-identity lookup only;
production defaults and native invitation transport remain intact. The offline case
also distinguishes cached authority for local metadata lookup from the stricter
verified-account gate for native acceptance/import. This is local orchestration
proof, not native sharing or cloud-delivery evidence.

## Home members and invitation delivery (SHOPPING-128)

`HomeMembershipCoordinatorTests` owns the durable one-time participant archive,
per-home serialization through native completion, cancellation, restart at each
submission checkpoint, uncertain-result reconciliation, and explicit resend. An
absent participant after an uncertain submission never authorizes another write.
The submitted-before-native crash window deliberately remains uncertain here;
SHOPPING-129 must provide explicit durable owner resolution before module release.
`ManagedHomeMembershipTransportTests` checks the real SDK factory and secure archive
round trip, including stable participant identity and contributor permission. It
does not save a share or prove server acceptance.

`HomeNameTests` owns exact account/store/root/list routing, actual permission-policy
rollback, retired command rejection, and unchanged People and private carts.
`HomeDetailsModelTests` owns owner/contributor/restricted affordances, stale results,
explicit delivery acknowledgement, pending versus accepted presentation, failed
rename recovery, and the isolated UI fixture's contract.

`HomeDetailsUITests` owns the disclosure's cancellation boundary, the ordinary system
URL share sheet, retaining and resending a pending invitation after closing that
sheet, contributor renaming through SQLite and relaunch, and restricted membership
with long names at accessibility text size. Its DEBUG fixture requires an explicit
role and unique UI-test store; membership is simulated in memory while renaming
uses the real command. It never sends a message, opens a join URL, or grants native
membership. These scenarios are in the broader UI suite; the six routine acceptance
scenarios remain unchanged. Real link acceptance, revocation, cross-account delivery
and physical accessibility remain SHOPPING-30 evidence.

## Member removal and cancelled invitations (SHOPPING-129)

`HomeMembershipRemovalTests` owns explicit cancellation of a submitted invitation
whose native outcome is unknown, version-one journal migration, retained archives,
late participant appearance, suppressed delivery during a held native callback,
imported owner authorizations, exact captured member sets, and explicit retry after
an uncertain removal. A later invitation is never implicitly included in an older
stop-sharing command. Cancelling an attempt does not automatically create its
replacement.

`HomeMembershipPrivateLedgerTests` owns append-only, account-private retention,
idempotency, conflicting operation identifiers, preservation of home/People/cart
records, SQLite reopen, and portable logical-home/share matching across devices.
It resets contexts and detaches stores before reopening or deleting fixture files.
These tests do not prove private CloudKit export or another device's import.

`HomeDetailsModelTests` owns confirmation identity, dismissal without authorization,
retired presentation fencing, and retained retry state after removal failure.
`HomeDetailsUITests` owns cancelling and confirming contributor removal, continued
owner access, and independent resend/removal buttons within the same member row.
Its isolated membership fixture never calls native removal or sends an invitation.

The contract prototype models a departing contributor remaining in the roster as
pending. It does not prove the native shared-zone purge, invitation reuse, offline
cache erasure, or private-effect quarantine. Participant leave, access observation,
rejoin authority, and outbox quarantine need their own implementation and coverage
before SHOPPING-129 is complete; all real-account behavior remains gated by
SHOPPING-30.

### Private-effect quarantine core (SHOPPING-129)

`HomeEffectQuarantineTests` owns the account-private access-loss boundary, explicit
fresh grants, stale checkout captures, private history/cleanup, and scope isolation.
SQLite replicas deliver private checkout, quantity/removal, and restore records
before lifecycle dependencies; a restore also arrives before its checkout. These
orders must not publish household effects or fulfill shared demand. Authority and
observed loss dependencies are embedded in the immutable effects, so an absent
separate record is never mistaken for legacy authorization. Genuine older checkout
payloads remain readable before any observed loss.

The same suite covers rejoin without old outbox replay, newly captured work after a
fresh grant, conflicting-share grants, and drain/detach/reopen persistence. The
existing personal-cart tests retain ownership of reducers, native permission-policy
simulation, private recovery, and normal two-replica ordering. These are local ledger
proofs; native observation is covered separately below. Exact participant-zone
leave and explicit rejoin still need integration and real-device verification
before SHOPPING-129 can be complete.

### Temporary permission restrictions (SHOPPING-129)

`HomePermissionTests` owns observed read-only restrictions and fresh writable
resolution, separately from permanent leave/revocation quarantine. It checks stale
checkout captures, private quantity/uncart/history and recovery, resuming temporarily
paused publication, distinct observations versus idempotent retries, and rejecting
an older writable result after a newer read-only observation. Writable-before-
restriction import fails closed. Household save enforcement covers new descendants
and both original and destination homes of a relationship move; unrelated owned
homes remain writable. These local persistence checks do not prove native CloudKit
observation, leave, or real-device sharing.

### Native access observation and runtime publication (SHOPPING-129)

`HomeNativeAccessGateTests` owns initially unverified publication, transient refresh,
late-response fencing, conservative failed retention, account/store/root/share
isolation, portable read-only version deduplication, independent native-loss
identities, narrow known-share error
classification, and native-loss retention when an earlier grant imports late.
The production recorder is used directly for causal ordering checks: a later rejoin
must not authorize effects stamped with the earlier grant. Writable observation
resolves only its captured restriction boundary and never creates a membership grant.
The same test owner checks the shared refresh queue: concurrent foreground readers
coalesce, while an ordinary import invalidating a held check retains a trailing
check and returns its final result to every waiting caller.

`HomePermissionTests` also owns discovery overlays, presentation-generation changes
for effective permission changes, unchanged-observation stability, history merging
without observation-only network feedback loops, and retaining an
unavailable selected home across relaunch instead of selecting another home.
`WatchShoppingSessionTests` owns explicit native-refresh dispatch separate from
local reload/store switching and session busy state. `PersistentWatchShoppingServiceTests`
checks imported read-only facts retiring a checkout capture while keeping private
quantity and removal available. It also holds the real shared refresh queue while
the SQLite service uses the production managed load-recovery policy, requiring
cached loads, store switching, quantity changes and removal to finish before that
queue is released. The bounded check drains both tasks on failure; it does not
exercise native transport or account setup. Its fixture now drains and detaches the original
store before directory cleanup; existing separately reopened fixture stores retain
their own teardown obligations.

The native adapter reads exact managed participant shares and verifies account,
attached store, graph, and share identity around requests. Both apps gate shared
publication and private-intent demand projection, including replay outside the
selected home. Background checks do not occupy Watch snapshot loading. These are
local code and simulator proofs, not evidence of real CloudKit delivery, permission
propagation, device responsiveness, participant leave, or explicit rejoin. Those
remain required by SHOPPING-129/30 and the device responsiveness protocol.

The Watch status assertion for completed activity was synchronized with the
existing shared message adopted in main `838c22e` (SHOPPING-146–152). It now checks
`Recent iCloud activity completed.` exactly, as the iPhone owner already does,
instead of expecting the removed disclaimer. The first native-access Watch run
retains that stale-assertion failure; it is not treated as a passing validation.

### Participant leave durability (SHOPPING-129)

`HomeLeaveLedgerTests` owns atomic private leave authorization and quarantine,
retention across SQLite reopen, original-store identity checks, at-most-once
native-submission authorization, completion without a membership grant, and
retirement of an old destructive authorization by a covering rejoin grant.
Checkpoint-first imports carry the full command and require their missing block;
failed saves retain neither half. Captured unpublished checkout/restore IDs and
cart generations are evidence; the permanent membership boundary also covers old
effects arriving after confirmation. Unknown legacy restores are retained as
unresolved evidence, and incomplete earlier private imports do not require a peer
to synchronize before explicit leave submission. These tests do not invoke CloudKit purge or
prove participant leave, uncertain native outcome reconciliation, or rejoin UI.
Submitted operations require reconciliation; they cannot automatically retransmit
the zone purge. Native adapters, acceptance gates, and live proof remain required.

### Participant join ordering (SHOPPING-129)

`HomeJoinGateTests` owns rejection of pending leaves across every share record
in the same account/container/environment/owner zone, block-first and
checkpoint-first import ordering, and cart/checkout/restore effects imported
before the lifecycle history they reference. Until a referenced block arrives,
its zone cannot be classified safely and joining waits. Once history is complete,
another zone remains independent. A completed leave opens this gate without
granting membership or replaying old effects. An unclassified restore still waits
for its declared scope or original checkout. Account-private reads stay scoped to
the captured session; native callers must also verify that account remains active.

The held-callback test proves local zone operations retain their turn through
caller cancellation and native failure, while another zone proceeds. iPhone
invitation import/acceptance and Watch acceptance use this gate and revalidate
their native account/store environment. This is local ordering, not a cross-device
or server conditional-purge guarantee. Native leave still requires integration. Explicit rejoin activation is covered
below; both paths still require real two-account proof.

### Explicit rejoin authority (SHOPPING-129)

`HomeRejoinTests` owns SQLite capture/commit against a complete loss boundary,
rejection of a newer loss, same-entry idempotency across reopen, a distinct grant
after a later loss, and unchanged historical cart/checkout/restore payloads and
publication authority. It also owns read-only membership with private cleanup,
exact graph/account/store validation, pending-leave rejection, and transaction
rollback if presentation or individual Open authority retires before saving.

`HomeAdoptionBootstrapTests` owns the real bootstrap Open/Not now wiring: only
explicit Open verifies membership and grants; resolved entries cannot grant
again; a new loss, retired presentation, or replacement invitation rejects a
held callback. The held journal scenario checks both an existing Open and a new
Open after synchronous ingress while the old entry is still published. Both
completions are bounded before the test releases and drains the journal queue.
These fixtures use isolated plain SQLite stores and substitute the native
membership verification boundary. They do not establish CloudKit acceptance,
server permissions, or cross-device convergence.

`ActiveHomeCoordinatorTests.testExplicitMembershipRenewalRetiresCapturedAuthorityForTheSameGraph`
owns generation renewal and rejection of an older discovery result even when the
selected graph is unchanged. Initial bootstrap discovery can overlap the next
explicit refresh; the integration fixture waits boundedly for the already-running
discovery to publish its unresolved state rather than assuming its own request won.

The September 29 explicit-rejoin checkpoint passed 42 focused tests, all 484
`ShoppingFast` tests, and all 47 Watch unit tests on the local iOS/watchOS 26.5
simulators. The unchanged source was recorded in
`/tmp/shopping-129-rejoin-corrected-source.json`; result bundles are
`/tmp/shopping-129-rejoin-{corrected,fast,watch}.xcresult`. All three have zero
skips and zero xcresult runtime warnings. Existing coordinator fixtures still
emit Core Data model-ambiguity log warnings; this is not a warning-free log claim.
The earlier 18-pass/4-fail discovery-timing result remains preserved at
`/tmp/shopping-129-rejoin-focused.xcresult`. This checkpoint does not prove native
leave, pre-acceptance loss retention, or live sharing.

### Invitation acceptance retains observed loss (SHOPPING-129)

`HomeInvitationAcceptanceTests` owns the common phone/Watch orchestration: capture
retained exact-share evidence, freshly observe native access, commit typed loss
to the private ledger, recheck pending leave history, then invoke acceptance.
An old unpublished checkout stays quarantined after accepted access and explicit
Open. Observation or private-save failure leaves acceptance unsubmitted. Stale
pending invitation metadata alone does not establish lost access when fresh
membership is accepted. A leave imported during observation rejects acceptance
at the final gate. First-time acceptance without retained identity skips native
loss observation but still enforces that final gate. The fixture substitutes
native lookup and acceptance; private
retention, publication rules, and join gating use the production SQLite paths.

The native adapter resolves either an attached exact-share root or retained
portable access/leave evidence, and checks account, store, scope, and graph again
before saving. No retained identity means this particular observation cannot
classify an earlier membership loss. This is the documented offline-discovery
limit, not proof of uninterrupted membership: a separate replica can miss a
revocation/reinvitation before observing current accepted access. The app does
not promise immediate discovery of unobserved remote loss or use participant ID
or a general share change tag as a guaranteed membership incarnation.

The September 29 pre-acceptance checkpoint passed 19 focused tests, then the
expanded eight acceptance tests (including first join), and all 492 Fast tests.
The same production source passed all 47 Watch unit tests; only the two phone
test methods were added afterward. All recorded bundles have zero skips and zero
xcresult runtime warnings. Bundles use `/tmp/shopping-129-preaccept-` with suffixes
`focused`, `first-join`, `final-fast`, and `watch`; the corresponding `.log` files
and `final-source.json` retain evidence. Earlier 490-test Fast evidence is also
preserved. Existing model-ambiguity log warnings remain separate from xcresult
runtime warnings. Independent correctness and test-evidence review found no
remaining issue after the final gate and first-join checks were added.

### Participant leave execution (SHOPPING-129)

`ManagedHomeLeaveTransportTests` owns the production prepare/execute/reconcile
sequence with unique SQLite stores and a simulated platform backend. It checks
committed authorization and quarantine before purge, at-most-once submission,
private cart/history retention after actual fixture graph deletion, read-only
participant leave, rejection of owner/pending/public or changed participants,
known same-zone scope collisions, wrong returned zones, and account changes
during a held callback. Held callbacks have bounded arrival checks and are always
released and drained before teardown. Stores are detached before fixture removal.

UI authority must remain current through the atomic confirmation save. After that
durable handoff, the account service owns completion: quarantine may itself
retire the screen. A covering rejoin grant still retires destructive authority.
`HomeLeaveLedgerTests` owns the final pre-purge submitted/uncompleted/quarantine
check and a covering grant arriving after the submission checkpoint. The transport
suite owns the corresponding refusal to invoke purge and both sides of the UI
authority handoff.

The relaunch case detaches and reopens the same SQLite store, reconstructs its
service/backend/transport, and proves that a submitted uncertain command never
purges again. A readable or failed zone observation stays pending. An absent zone
requires fresh local absence of both original home and list before completion.
Quarantine and private history survive that completion. A crash after the submitted
marker but before the native call remains uncertain; no timeout or generic error
is converted into permission to resend a destructive operation.

The backend fixture supplies native membership, environment/mapping verification,
zone observations, and purge completion. Tests do not establish CloudKit mapping,
permission propagation, server zone deletion, or actual cross-device cleanup. The
production adapter uses a nonnil captured participant store and exact zone; only
zone-not-found from an exact zone fetch counts as absence, never a missing share
or permission failure. Native device proof remains required before release exposure. The confirmation
and status UI proof is recorded below.

The September 29 native-leave checkpoint passed 21 leave-focused tests, then 26
including the home-creation concurrency fixture, all 506 Fast tests, and 47 Watch
unit tests. Result bundles are `/tmp/shopping-129-leave-relaunch-focused.xcresult`,
`/tmp/shopping-129-leave-discovery-focused.xcresult`,
`/tmp/shopping-129-leave-validated-fast.xcresult`, and
`/tmp/shopping-129-leave-watch.xcresult`; logs and
`/tmp/shopping-129-leave-validated-source.json` retain source evidence. All have
zero skips and zero xcresult runtime warnings. Existing Core Data model-ambiguity
log warnings remain. The earlier `leave-final-fast` bundle retains 505 passes and
one failure: a superseded discovery request returned before the newer request
published. The fixture now waits boundedly for that publication after each single
refresh, preserving its no-duplicate-creation and selection assertions.


## Leave confirmation and retained status (SHOPPING-129)

`HomeDetailsModelTests` owns accepted-participant eligibility, exact command and
scope matching, cancellation, repeated confirmation, and stale prepare/confirm
completion after presentation retirement. The native transport remains the owner
of durable authorization, quarantine, and at-most-once purge behavior.

`HomeDetailsUITests/testContributorLeaveDisclosureCanCancelThenConfirmPendingOutcome`
owns the visible unsynced-change/private-history disclosure, Cancel returning
without submission, Leave now producing an honest pending result, and disabling
a repeated leave. Its isolated DEBUG fixture provides native membership and an
uncertain callback only; it does not seed a completed leave or prove CloudKit.

`HomeDetailsUITests/testSubmittedLeaveWithMissingRootKeepsStatusReachableThroughChooseHome`
performs Leave now through the real transport and private ledger, with a DEBUG
backend simulating loss of the native callback after exact root/list deletion.
It opens Choose a home, verifies the removed root is unavailable and retained
leave status remains reachable, then checks the explicit status action's
idle → checking → uncertain-result transition. The bounded simulated network
response makes that interaction distinguishable from an earlier automatic check;
no completed leave or expected status result is seeded before the user action.

`HomeLeaveBootstrapTests` owns the real bootstrap integration with unique private
and participant SQLite stores: confirmed leave preserves private cart/history,
does not select an unrelated home, and retains account-wide status after root
removal and reopening. A cached offline account can read its retained status but
cannot resume or query native membership. A late status callback cannot publish
into a different account. An unsubmitted durable confirmation can resume on its
original store; submitted uncertainty only reconciles and never purges again.

The initial 24-test model/bootstrap run passed its assertions but emitted
post-suite missing-SQLite errors (`/tmp/shopping-129-leave-bootstrap-focused`).
Its account-change fixture had left the replacement account's asynchronous load
unfinished before deleting its directory. The corrected fixture gives each
account separate store paths, awaits the replacement runtime, and verifies store
detachment before cleanup. The focused five-test rerun
(`/tmp/shopping-129-leave-bootstrap-isolation.xcresult` and `.log`) passed with
zero skips/runtime warnings and no Core Data errors or missing-path messages.
Pre-existing model-ambiguity warnings remain separately tracked by SHOPPING-131.

Final integration review caught an access-only import invalidating every native
access observation without scheduling another verification pass. Phone and Watch
now share `HomeNativeAccessGate.applyImportedHistory`: durable access facts remain
enforced by the ledger, while only ordinary imports invalidate native verification.
`HomeNativeAccessGateTests` proves two verified homes survive an access-only import,
a held observation can finish without an extra pass, and ordinary imports still
invalidate verification and request a trailing pass. The focused gate, permission,
and bootstrap run passed all 24 tests (`/tmp/shopping-129-leave-history-focused`).

The final UI/backend source passed 519 Fast tests and 47 Watch unit tests, with
zero skips and zero xcresult runtime warnings (`/tmp/shopping-129-leave-ui-fast`
and `/tmp/shopping-129-leave-ui-watch`). Raw Fast Core Data errors came only from
the two intentional invalid-store load tests; model-ambiguity warnings remain.
Source hashes are retained in `/tmp/shopping-129-leave-ui-final-source.json`.

The new Cancel/Leave workflow passed independently. The root-gone workflow first
proved navigation, then gained a stronger assertion of the status check's actual
transition. Its first strengthened run failed because the query assumed a
ProgressIndicator accessibility type; the stable-identifier query now requires
one matching element without assuming that type. The failure remains in
`/tmp/shopping-129-leave-ui-validated.xcresult`; the corrected single-test run
`/tmp/shopping-129-leave-status-interaction-ui.xcresult` passed with no skips or
runtime warnings. No product behavior or assertion was disabled to pass it.

The unchanged final source also passed all six standard acceptance UI workflows
(`/tmp/shopping-129-leave-ui-acceptance.xcresult` and `.log`), with zero skips.
The same four negative/non-finite frame runtime warnings remain tracked by
SHOPPING-131; this run does not claim those warnings are resolved.
