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

SHOPPING-171 adds value-only home entry coverage here: unknown and incomplete
discovery cannot appear as confirmed empty; the snapshot preserves exact invitation
and graph identity without carrying archived metadata; scoped forgetting cannot
erase a newer selection or another account, and reconciles the remaining homes.
`ActiveHomeBootstrapTests` retains the actual store and account wiring proof.

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

SHOPPING-172 adds `HomeCreationTests` proof that explicit first local creation reuses
its exact saved IDs after relaunch without account ownership. `ActiveHomeBootstrapTests`
owns available-account discovery before first creation and offline explicit local
creation. The rendered one-tap entry remains UI-owned.

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

SHOPPING-172 adds `HomeInvitationInboxTests` proof that open intent survives import
and relaunch, while dismissal, a newer choice, activation resolution, and an account
change have distinct durable results. `HomeAdoptionBootstrapTests` owns automatic
exact-home activation and a held native verification where a newer home selection
prevents late navigation. UI tests own the direct sheet and tap count.
`PersonalCartUITests/testDismissPendingInvitationPersistsAfterRelaunchAndKeepsGroceries`
owns the direct invitation sheet, Not Now dismissal, no automatic reopening after
relaunch, unchanged groceries, and the recovery row in Homes. Its DEBUG
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

`PersonalCartUITests/testLocalHomeRemainsAvailableInHomesPicker` owns the visible
On This iPhone row after declining an invitation, its original groceries, and
relaunch without fixture reseeding. `HomeAdoptionBootstrapTests` owns actual
local-source retention and return through the account activation boundary.
The UI fixture's account, invitation journal and preferences are scoped to its
unique store. It does not claim a successful accepted-local UI join.
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
SHOPPING-129 now supplies explicit durable owner resolution, covered below; native outcome verification remains in SHOPPING-30.
`ManagedHomeMembershipTransportTests` checks the real SDK factory and secure archive
round trip, including stable participant identity and contributor permission. It
does not save a share or prove server acceptance.

`HomeNameTests` owns exact account/store/root/list routing, actual permission-policy
rollback, retired command rejection, and unchanged People and private carts.
`HomeDetailsModelTests` owns owner/contributor/restricted affordances, stale results,
explicit delivery acknowledgement, pending versus accepted presentation, failed
rename recovery, and the isolated UI fixture's contract.

`HomeDetailsUITests` owns direct presentation of the ordinary system URL share
sheet, retaining and resending a pending invitation after closing that
sheet, contributor renaming through SQLite and relaunch, and restricted membership
with long names at accessibility text size. Its DEBUG fixture requires an explicit
role and unique UI-test store; membership is simulated in memory while renaming
uses the real command. It never sends a message, opens a join URL, or grants native
membership. These scenarios are in the broader UI suite; the six routine acceptance
scenarios remain unchanged. Real link acceptance, revocation, cross-account delivery
and physical accessibility remain SHOPPING-30 evidence.


## Watch commands during refresh (SHOPPING-159)

`WatchShoppingSessionTests` owns a user Add arriving during a deterministically
held local load: the read does not set command busy, the captured action waits,
repeated import notifications and the periodic coordinator coalesce, and the
service executes the exact original command once. Replacement account/home
rejects that deferred action before service execution. Explicit store selection
waits for its selected snapshot so the chooser can dismiss after success.
Same-authority background refresh cannot erase command failure feedback. Existing
service tests continue to own opaque-token validation, private ownership,
read-only restrictions, and stale persistence mutations.

`WatchShoppingUITests/testSwipeAddFailureShowsFeedbackAndRetryAddsOnce` owns the
green swipe Add failure alert and retry. The durable swipe Add scenario owns the
single private cart row and unchanged quantity across a same-store relaunch. The
existing durable card Add and failed card Add scenarios retain dismissal after
success, quantity persistence, failure feedback, and draft-preserving retry.
These UI tests use the existing explicit DEBUG fixtures; the held-load timing
case is deterministic session coverage, not a synthetic CloudKit UI claim.

See [SHOPPING-159 evidence](shopping-159-watch-refresh.md) for the reproduced race,
local validation, and outstanding physical Watch proof coordinated with
SHOPPING-122. Native access verification work remains owned by SHOPPING-129.
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
cache erasure, or private-effect quarantine. The completed SHOPPING-129 local
implementation and coverage for participant leave, access observation, rejoin
authority and outbox quarantine are recorded below. All real-account behavior
remains gated by SHOPPING-30.

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
proofs; native observation, exact participant-zone leave and explicit rejoin
integration are covered separately below. Real-device verification remains in
SHOPPING-30.

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
live checks remain required by SHOPPING-30 and the device responsiveness protocol.

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
the zone purge. Native adapters and acceptance gates are covered below; live proof
remains required by SHOPPING-30.

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
or server conditional-purge guarantee. Native leave integration and explicit rejoin
activation are covered below; both paths still require real two-account proof.

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

`HomeDetailsUITests/testContributorLeaveAlertCanCancelThenConfirmPendingOutcome`
owns the native named Leave alert, Cancel returning without submission,
Leave Home producing an honest pending result, and disabling
a repeated leave. Its isolated DEBUG fixture provides native membership and an
uncertain callback only; it does not seed a completed leave or prove CloudKit.

`HomeDetailsUITests/testSubmittedLeaveWithMissingRootKeepsStatusReachableThroughHomes`
performs Leave now through the real transport and private ledger, with a DEBUG
backend simulating loss of the native callback after exact root/list deletion.
It opens Homes, verifies the removed root is unavailable and retained
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


## Scoped sharing status foundation (SHOPPING-130)

`CloudSyncStatusTests` now owns native event identity, duplicate/out-of-order
hydration, overlapping same-operation activity, equal-start failure cohorts,
private/shared failure isolation, and historical unfinished events. An unfinished
historical event remains an unknown observation, not current busy state. The
native monitor passes Apple's event UUID and history/live origin. Existing Watch
presentation and the 200-event/750 ms coalescing test remain separate owners.

`HomeSharingStatusTests` owns pure composition of account, home access,
invitation/import, store observations, known saved checkout/undo work, owner
sharing preparation, and account-wide leave status. Unavailable access dominates
an engine success; one store's success cannot hide another's failure. Known
pending operations remain visible after an observed upload. No status claims
other-device delivery or offers force sync.

`HomeSharingWorkSnapshotTests` owns account/home-qualified, read-only private
operation counts, checkpoint-value exclusion, held work as a subset, and partial
restore imports with known versus unassigned homes. The read uses existing ledger
validation in one writer transaction, makes a fixed number of ledger queries,
and calls no native permission or publication API. Foreground publication still
needs a matching account, service, local graph, and presentation.

The foundation passed 33 focused tests and all 545 Fast tests, with zero skips or
xcresult runtime warnings. Evidence: `/tmp/shopping-130-status-foundation-focused`
and `/tmp/shopping-130-foundation-fast` result bundles/logs, plus
`/tmp/shopping-130-status-foundation-source.json`. The initial compile failure in
`/tmp/shopping-130-status-foundation` is preserved: the new work snapshot source
was registered in the Watch build phase instead of the phone phase; target
membership was corrected before the successful runs. Two independent reviews
found no surviving defect. Bootstrap/UI wiring, bounded actions, announcements,
and a real UI workflow remain required to complete SHOPPING-130.

The same foundation source passed all 55 Watch unit tests with zero skips or
runtime warnings (`/tmp/shopping-130-foundation-watch.xcresult` and `.log`),
including the shared CloudSyncStatus tests and existing Watch status behavior.

### Sharing status screen and bounded checks

`HomeSharingStatusCheckTests` owns bounded waiting, cancellation, and one in-flight
reservation until an uncooperative operation actually drains. A timeout releases
UI busy state without claiming the underlying native or writer operation stopped.
`HomeSharingStatusBootstrapTests` owns local-only screen reads, forwarding home
observations, full account/service/local-graph/presentation fences, same-graph
presentation renewal, late callbacks, and independent local-check error state.
Its account-boundary regression deliberately keeps the old presentation mounted
while the provider changes accounts; old observations must disappear before the
queued UI transition. Fixtures detach their SQLite stores before deletion and
wait for held workers to drain before asserting late results were discarded.

`HomeSharingStatusTests` also owns local-check failures remaining independent of
CloudKit/association success, and announcement deduplication. Event timestamps,
counts and duplicate observations do not repeatedly interrupt VoiceOver.

`HomeSharingStatusUITests.testStatusCheckAndReturnKeepSavedHomeAtAccessibilityTextSize`
owns opening the native status screen, its explicit Check status interaction,
readable saved-work meaning at accessibility XXXL through Details, and the Groceries
tab preserving existing grocery identities. The initial UI run failed because a generic query
matched both the native Label image and text; it now selects the unique static
text rather than taking the first match. The failure is retained in
`/tmp/shopping-130-status-ui.xcresult`. The existing largest-text empty/recovery
workflow passed in that same run, with zero runtime warnings or skips.

Before the final discovery-order fix, focused wiring validation passed 37 tests
and the expanded Fast run passed 559, with no skips or xcresult runtime warnings
(`/tmp/shopping-130-status-wiring-focused` and `/tmp/shopping-130-status-final-fast`).
The focused run also had no raw Core Data errors. Review then found overlapping
home discovery could let an older failure replace a newer success, or an older
success clear a newer failure. The current request must own both error publication
and clearing; stale graph reconciliation was already protected independently.

Status remains functional without telemetry. There is no available Phase 15
lifecycle diagnostic implementation on this milestone, so this change does not
introduce a Sentry dependency or log account identities, invitation URLs or grocery
content. Simulator observations do not prove another household member's receipt;
SHOPPING-30 retains that live two-account/two-phone gate.

The final request-order guard passed all 561 Fast tests. A separate test-evidence
review found that the first Check status UI assertion could pass on the preceding
automatic-read result. Appearance now reports its local-read scope, while an
explicit completed check reports the broader observation check. The workflow
requires the initial local-read message and then the distinct explicit-check
result after the tap, alongside an enabled button and no remaining progress.
The final unchanged candidate passed all 561 Fast tests and that strengthened UI
workflow, with zero skips or xcresult runtime warnings
(`/tmp/shopping-130-status-complete-fast` and `-complete-ui`). Source hashes are in
`/tmp/shopping-130-status-complete-source.json`. Raw Fast Core Data errors remain
confined to the two intentional invalid-store tests; no missing-path errors were
observed in the preceding final request-order run.

A passing intermediate UI run captured a blank screenshot immediately after the
native Dynamic Type audit. It is retained in `-ui-corrected` and is not visual
proof. Captures before the audit in `-ui-visual` show the actual wrapped, scrollable
status and saved-work content at accessibility XXXL. The final workflow keeps
those pre-audit captures and the audit assertion. The extra visual run is not a
runtime optimization comparison.

Independent functional reviews cleared the final request-order/account guards;
the test-evidence review checked fixture teardown, late-worker draining, target
membership and preserved plan selection. No coverage baseline, CI policy, or
remote-Full attestation requirement changed. The shared event foundation's 55
Watch unit tests passed before this phone UI wiring; the phone Fast build also
compiles the Watch target. Real device announcements and live sharing remain
part of the physical acceptance work.

### Hosted Open/rejoin failure retained

Hosted Xcode 16.4/iOS 18.5 run `36641844287` passed 560 of 561 Fast tests;
`HomeAdoptionBootstrapTests.testExplicitOpenRejoinsBlockedHomeButResolvedEntryCannotGrantAgain`
caught `invalidState`. Release SDK Build and the unchanged coverage gate passed,
but acceptance UI did not run. The raw result remains under
`/tmp/shopping-130-ci-failure/fast-failure-36641844287-1/FastResults.xcresult`,
with summaries in `/tmp/shopping-130-ci-artifacts/`. This failed candidate was not integrated.

The source exposes a concrete race after durable rejoin: an ordinary home
discovery can supersede explicit Open's discovery request while its local read
is suspended. The existing newest-request fence then rejects Open's selection.
The hosted failure has no precise throw location. A controlled held-discovery
regression reproduced both an unexpected ordinary read and the same uncaught
`invalidState` locally before the repair (`/tmp/shopping-130-open-reservation-red`
result bundle and log). Removing request-order or account/access checks is not
a valid repair.

The repair reserves only the final committed discovery/selection phase for the
captured presentation. Ordinary discovery cannot begin or publish while that
phase owns the request; native verification and account/access checks remain
active. Releasing the reservation awaits a fresh ordinary observation on both
success and failure. That observation owns its own error and cannot replace
Open's original result. A second Open from the same presentation is rejected
before competing work; older presentation cleanup cannot remove a replacement.

`HomeAdoptionBootstrapTests` owns the three added interleaving regressions:

- `testOpenSelectionSurvivesRefreshWhileCommittedDiscoveryIsHeld` proves exact
  selection, resolved invitation, one durable grant, duplicate Open rejection,
  and a fresh trailing observation.
- `testEarlierRefreshFailureCannotPublishDuringReservedOpenSelection` proves
  stale ordinary failure cannot replace the valid selection.
- `testFailedOpenDiscoveryReleasesReservationAndPreservesOriginalFailure` proves
  release after failure, separately owned trailing error and idempotent retry.

Sticky gates release and drain their held operations before teardown. All 28 adoption/status-bootstrap tests and all 564
Fast tests passed, with zero skips or xcresult runtime warnings. Evidence uses
`/tmp/shopping-130-open-reservation-{focused,fast}`; the source manifest is
`/tmp/shopping-130-open-reservation-source.json`. The focused log has no Core Data
errors or unlink diagnostics. Fast still emits the previously tracked
HomeCreationTests/PersonalCartServiceTests fixture unlink diagnostics; their
required SHOPPING-131 cleanup and original logs remain intact. The two deliberate
invalid-store tests also emit their expected Core Data errors. No warning-free
log or live-sharing claim is made.


## Cross-feature lifecycle validation (SHOPPING-131)

The [requirement matrix](home-sharing-validation.md) maps local behavior to its
existing proof owners and records the separate, unresolved native checks for
SHOPPING-30. These additions exercise integration boundaries without replacing
cart reducers or expanding the quick acceptance selection.

- `HomeAdoptionBootstrapTests.testTwoInvitationsImportAndOpenInArrivalOrderWithoutReplacingSelection`
  and `testTwoInvitationsImportAndOpenInReverseOrderWithoutReplacingSelection`
  own independent invitation decisions, explicit selection, late-import stability,
  and return to the original groceries/private cart. Two SQLite stores substitute
  CloudKit attachment; marking import ready is the substituted journal boundary.
- `ActiveHomeBootstrapTests.testTemporaryAccountUnavailabilityRestoresHomeCartAndDraftButRejectsLateDiscovery`
  owns A → temporarily unavailable → A through the real account provider,
  presentation retirement, store detach/reopen, held stale discovery completion,
  original cart/draft retention and rejection of captured checkout authority.
  Its held read finishes before detach; only delivery of the value is delayed.
- `ActiveHomeBootstrapTests.testTwoHomesRequireChoiceAndSwitchRetiresCapturedCommands`
  now also owns checkout capture and editor lease retirement across a home switch,
  absence of unintended history, and restoration of the original cart/draft.
- `HomeMembershipPrivateLedgerTests.testStopSharingReopensDurableTargetsAndRequiresExplicitRetryAfterFailedSubmission`
  owns the durable private removal capture before membership-journal submission,
  SQLite/coordinator reconstruction, failure without passive retry, explicit retry,
  exact accepted/pending targets and retention of later members and original data.
- `HomeDetailsUITests.testOwnerInviteAndCancelPendingInvitationPreservesGroceries`
  owns direct Invite presentation and the pending-member confirmation binding:
  cancel preserves membership, then confirm removes only the captured pending
  invitation while owner/home/groceries remain usable. The isolated membership
  fixture supplies native results; the UI never sends a real invitation or
  removes a CloudKit participant. Stop Sharing backend recovery remains owned by
  `HomeMembershipRemovalTests` and `HomeMembershipPrivateLedgerTests`.
- `PersistenceContainerTests.testPostShareChildrenStayWithEachRootAndOnlyOwnerGraphEntersAssociationJournal`
  owns real child creation in two SQLite stores and owner-only association staging.
  The internal role-lookup overload substitutes store classification only; production
  forwards the controller's actual bindings. Private cart/lifecycle objects are
  excluded. This does not prove actual CloudKit zone association or server ACLs.

### SQLite fixture lifetime repair

`SQLiteTestFixtureLifetime` retains every registered controller and extra context,
resets writer/extra/view contexts, verifies empty context state, then detaches all
persistent stores before removing any registered directory. A detach failure
preserves directories and fails teardown. These synchronous fixtures have no owned
background worker to drain; bootstrap fixtures separately drain their invitation
journal before directory cleanup.

`HomeCreationTests` retains all seven methods and assertions; `PersonalCartServiceTests`
retains all 33, including separately opened stores and replica ordering. Seventeen
extra contexts are registered. No logs or errors are suppressed. The baseline
unlink/openDirectory diagnostics recorded under SHOPPING-128/130 remain evidence.

An isolated run of these unchanged 40 methods passed with zero failures, skips or
xcresult runtime warnings. The raw log contains no vnode, openDirectory or Core
Data error diagnostics. Evidence: `/tmp/shopping-131-fixture-focused.xcresult`,
`/tmp/shopping-131-fixture-focused.log` and the four-file hash manifest
`/tmp/shopping-131-fixture-source.json`. Both validation copies and the active issue
worktree matched that manifest during independent review. Other compiler warnings
remain; this is not a warning-free build or suite runtime improvement claim.

The final full-suite attestation and pinned CI must validate the complete committed
candidate; this isolated selection does not validate the later matrix additions.
Native keyboard-accessory layout diagnostics observed in earlier UI runs remain
an investigation, not a resolved application defect or waived live acceptance.

The combined affected Fast selection passed all 92 methods across six suites,
with zero skips or xcresult runtime warnings (`/tmp/shopping-131-matrix-focused`).
All source hashes still matched `/tmp/shopping-131-matrix-source.json`; only docs
changed afterward. There were no vnode/openDirectory diagnostics. The 502 raw
Core Data error lines were confined to the intentional
`PersistenceContainerTests.testLoadFailurePreservesOriginalBytes` invalid-store
case. A trailing unbalanced appearance-transition message is retained in the raw
log; zero structured runtime warnings is not a clean-console claim.

The first Stop sharing UI run passed (`/tmp/shopping-131-stop-ui`), but independent
review found its initial navigation-title wait did not establish that the async
grocery projection was ready. The corrected workflow waits for the known complete
fixture rows before capture and the preserved set on return. The initial pass is
intermediate evidence, not validation of that later readiness correction.

The complete Fast plan passed all 569 tests (the 564-test baseline plus five new
integration methods), with zero failures, skips or xcresult runtime warnings.
No vnode/openDirectory diagnostics recurred. Evidence is
`/tmp/shopping-131-complete-fast.xcresult` and `.log`; the source manifest is
`/tmp/shopping-131-complete-source.json`. Two independent functional reviews found
no remaining defect after the UI readiness correction. Live CloudKit assertions
remain outside this local result.

The corrected Stop sharing workflow passed with zero failures, skips or xcresult
runtime warnings (`/tmp/shopping-131-stop-corrected-ui.xcresult` and `.log`).
Its 44.686-second test duration is validation evidence, not a runtime improvement
claim. The full candidate's non-documentation source still matched the frozen
manifest after both final runs. The independent reviewer confirmed the Fast
inventory is exactly the baseline plus five additions, with no omitted or duplicate
methods. Remaining Fast Core Data errors belong to the two deliberate invalid-store
tests; one raw appearance-transition message remains visible.

### Full-suite stale UI expectations (SHOPPING-131)

The first clean candidate, `da3ef24667867310a109389200b25d94fe1c621f`, ran
all 662 selected methods (569 Fast and 93 UI): 660 passed, two failed, none
skipped. The runner exited 65 and produced no full-suite attestation. Evidence:
`/tmp/shopping-131-local-full.log` and the repository timing history under
`.git/shopping-test-timings/da3ef24667867310a109389200b25d94fe1c621f/20260929T234512Z.zAfkKV`.
The result retained 28 invalid-frame runtime warnings; their individual stacks
have not been matched to the earlier keyboard-accessory investigation.

Both failures reproduced unchanged on clean `main` at
`ba09d80de520aed566a4be04560575f9e4cc5f82`
(`/tmp/shopping-131-main-baseline-ui.xcresult` and `.log`, two failures, no skips).
`ShoppingDeviceUITests.testCompactGroceryDensityAndSelectedStoreAlignment`
still expected the title and quantity button to share a vertical center, contrary
to SHOPPING-157's documented title/store baseline and quantity controls below the
store summary. The identical 33.17-point difference occurred on both revisions.
Its replacement assertions retain density, store eligibility, assignment, notes
and 44-point targets, and prove separate, hittable right-column controls with
matching vertical centers, no overlap and containment inside the row. Standard
text size is explicit; editor dismissal is awaited before measuring geometry.
The existing appearance tests retain large-text, padding and shared-column proof.

`ShoppingLaunchTests.testLaunchShowsEmptyGroceriesAndConnectedTabs` still expected
release 1.2.0; both revisions correctly display 1.2.2. It now verifies the complete
visible semantic-version/source-revision format. `AppPresentationTests` retains
independent known-value formatting and fallback assertions; the release workflow
owns marketing-version consistency and the exact version/build/source record.
No production layout, test-plan selection or coverage threshold changed.

The first four-test correction run retained two failures and passed both modern
appearance tests (`/tmp/shopping-131-corrected-layout-ui.xcresult`). A two-test
diagnostic run (`/tmp/shopping-131-layout-ax-diagnostics.xcresult` and `.log`)
confirmed that SwiftUI expands the edit button's accessibility frame across the
row and combines the native `App Version` label with its value. The final checks
use the containing cell and title frames for geometry, and allow that specific
native label prefix. Neither failed run validates the final correction.

The final affected selection passed all four methods with zero failures, skips
or structured runtime warnings (`/tmp/shopping-131-final-layout-ui.xcresult`,
`.log` and `-summary.json`). Both corrected methods and the existing standard/
large-text and shared-dimension appearance workflows ran. Their source hashes
still matched `/tmp/shopping-131-final-layout-source.json` after execution.
Independent review found no remaining issue in the correction. This focused pass
does not replace the new clean-commit full-suite attestation or pinned CI.

### Pinned-runtime failures and diagnosis (SHOPPING-131)

Clean candidate `13527ff7285c296e233151f2436a5946abd0e1b5` passed all 662
methods locally (569 Fast + 93 UI, no skips). Regular pinned CI passed Fast,
all six acceptance workflows, the unchanged coverage gate and Release SDK Build.
That CI checkout was merge commit `b32aaa7e362b79fc7455c85d5e9601622b24752d`;
its tree exactly equals the candidate tree. Local Full retained 28 frame warnings
and one appearance-transition message. Subsequent independent stack inspection
matched all 85 archived frame events in both local Full runs to the same native
`InputAccessoryBar` signature and per-test distribution. The underlying trigger
remains unresolved; these passes do not establish warning-free operation.

[Remote Full 36656430900](https://github.com/mggarofalo/Shopping/actions/runs/36656430900)
tested the exact clean candidate on Xcode 16.4 / iOS 18.5 (22F77). It executed the
same 662 methods once each: 659 passed, three failed, none skipped. The complete
failure bundle and logs remain at `/tmp/shopping-131-remote-failure-36656430900`;
reports are at `/tmp/shopping-131-remote-36656430900`. This failed run is not
waived by the local or regular-CI passes.

The link-existing promotion workflow passed its occurrence-identity, temporary
fields and saved purchase-rule checks, then queried Granola immediately after
switching to Catalog, before its asynchronous projection was ready. It now waits
boundedly for Catalog and Granola before asserting the old one-time name absent.
The status workflow captured an empty grocery projection immediately after its
navigation title appeared; the final snapshot contained two grocery identifiers.
It now waits for a rendered grocery before capturing and comparing identities.
Both workflows retain their original data assertions.

The remote result also contains two Home details Dynamic Type audit issues and a
separate Sharing status audit issue. The summary only lists the first failure
per test. Default attachments do not identify the offending elements, so both
audit handlers now retain element descriptions and return `false`, preserving
audit failures. Neither fonts nor audit scope have been changed without evidence.

The first local three-method correction run passed Home details and promotion,
but failed status navigation (`/tmp/shopping-131-remote-correction-focused.xcresult`
and `.log`, two passed, one failed, no skips). The status helper exhausted twelve
full-screen swipes yet allowed a tap based only on existence and hittability.
Its retained hierarchy placed the row at y=-45.7...166 with the navigation bar
at y=62...116; the synthesized tap at y=60.17 was outside the content viewport.
The replacement uses bounded, measured drags within the visible list and fails
unless the whole target is visible. The workflow stops at its first failure so
later navigation assertions cannot obscure the original cause. This failed
measurement remains separate from validation of the replacement.

The first measured-scroll check reached the status screen and completed the
explicit check, then failed the full-visibility requirement for the saved-work
text (`/tmp/shopping-131-status-scroll.xcresult` and `.log`). Its diagnostic bundle
is retained; the scroll correction is not yet validated. Readable long text and
fully visible actionable controls need distinct, evidence-backed checks.

The retained screenshot shows the saved-work paragraph reached but continuing
below the tab bar at XXXL. No exact text frame was retained in the exported
accessibility snapshots. The failed test itself took 59.37 seconds; Xcode's
separate simulator-diagnostic collection timed out after 600 seconds, making
the command take 668.35 seconds. This is not measured application latency.
The subsequent correction captures the beginning, overlapping scroll-through
views and ending of the long paragraph, preserves its complete-copy assertions,
and runs the unfiltered Dynamic Type audit at both endpoints. Buttons still
require full visibility before tapping. Half-viewport drags remain bounded.

The final status-only selection passed in 62.99 seconds with no failures, skips
or structured runtime warnings (`/tmp/shopping-131-status-text-edges.xcresult`,
`-summary.json`, `-timing.json` and `.log`). Captured test-source hashes still
matched after execution. Beginning, intermediate and ending screenshots show the
complete paragraph can be read by scrolling; both unfiltered Dynamic Type audits
and return-to-groceries identity comparison passed. The preceding three-method
run already passed the unchanged Home details and promotion corrections. These
local results do not resolve the pinned iOS 18.5 audit failures. The temporary three-workflow CI diagnosis was subsequently authorized and
executed; see the pinned diagnosis below. Existing release gates remained
unchanged.

### Creation selection fixture ordering (SHOPPING-131)

[Regular CI 36663291160](https://github.com/mggarofalo/Shopping/actions/runs/36663291160)
tested clean merge `761c1de485047466e38820adef1ed25a35cfd512`, whose tree equals
`d74596620170a08366e5199e00b2546c4cf876a7`. All 569 Fast methods ran once:
568 passed, one failed, none skipped. Coverage and Release SDK Build passed;
acceptance UI did not run after the Fast failure. These passes do not waive the
failed gate. Raw evidence remains at `/tmp/shopping-131-ci-failure-36663291160`;
reports are also retained under `.git/shopping-validation-evidence/shopping-131/ci-36663291160`.

The sole failure was `first.selected` in
`ActiveHomeBootstrapTests.testExplicitCreationWorksFromEmptyImportWithoutReplacingAnotherHome`.
Its subsequent graph-preservation and selection checks passed. This test is the
only direct positive owner of automatic selection after `createHome`, so both
`selected == true` assertions remain. The fixture now observes completion of the
real startup discovery fetch through its existing injected loader before starting
creation. The local-store fixture does not consume persistent history; its
startup access replay can otherwise issue a competing discovery after ready state
appears. The failure artifact does not identify the exact guard that won the
race, so that mechanism is supported by source analysis rather than a trace.

The bounded expectation establishes ordering without a sleep, creation retry,
manual selection fallback or production change. Exact active household/list IDs
are now asserted after both creations. The existing forced-overlap test remains
the negative owner: a superseding discovery must leave one committed graph
available without reporting creation failure. All six ActiveHomeBootstrap tests
passed the focused correction with no failures, skips or structured runtime
warnings (`/tmp/shopping-131-home-creation-order.xcresult` and associated reports).

The subsequent complete local Fast run passed all 569 methods once, with no
failures, skips or structured runtime warnings. Its identifier set exactly
matches the failed CI inventory, and captured test-source hashes were unchanged
during execution (`/tmp/shopping-131-creation-final-fast.xcresult`, `-summary.json`,
`-timing.json`, `-source.json` and `.log`). This validates the fixture correction locally. Regular pinned CI 36664654855
subsequently passed all 569 Fast methods and the six canonical acceptance
workflows once, with no skips, plus coverage and Release SDK checks. Its clean
merge 4a9a1b1035ec1fed51cc435ee908b47a811ecdd8 had the same tree as candidate
82a421e. The unresolved iOS 18.5 accessibility diagnosis remained required.

### Pinned Dynamic Type diagnosis (SHOPPING-131)

User separately authorized the temporary three-method CI job. It leaves all
existing release gates and Full attestation requirements unchanged and must be
removed before integration.

[Run 36718618360](https://github.com/mggarofalo/Shopping/actions/runs/36718618360)
executed exact clean `29991722fff20e664e2b0dc3aeee4dcd8f37ca0f` on Xcode 16.4 /
iOS 18.5 (22F77). Exactly three methods ran once, with one pass (Catalog linking),
two failures (both sharing Dynamic Type audits), and no skips. Both audit
attachments report no associated element. Home details remained populated;
Sharing status was populated before the audit and blank in its failure capture
about 5.34 seconds later. Status stopped at its first audit, so its ending audit
and return-to-groceries proof did not execute. This timing does not identify a
production or framework cause. Raw results and attachments remain under
`/tmp/shopping-131-focused-36718618360`; lightweight evidence is retained under
`.git/shopping-validation-evidence/shopping-131/focused-36718618360`.

The controlled [comparison 36720689803](https://github.com/mggarofalo/Shopping/actions/runs/36720689803)
removed only the two fixed launch-size overrides and relabeled screenshots,
retaining every assertion and unfiltered audit. Exact clean `f27c0bc20039730f71ba493e1edf43aac85b7dc2`
again ran the same three methods once: one passed, two failed, none skipped.
Home details failed its expected largest-text height assertion (42.33 points
versus greater than 44), then produced three Dynamic Type issues with no
associated element. Status failed its first audit with the same no-element
report and again stopped before its ending and return checks. Thus removing the
override did not resolve either audit. This run is not XXXL coverage. Evidence
is under `/tmp/shopping-131-focused-36720689803` and the corresponding retained
`focused-36720689803` directory.

`5ca102a6342457f7c14ef14cc5ce2949bea6c804` restores both sharing test files exactly
to their pre-comparison source, including XXXL interaction and all audits. Its
temporary Catalog control adds an unfiltered Dynamic Type audit only after all
promotion preservation assertions complete. No production code changed.

[Catalog control 36722724521](https://github.com/mggarofalo/Shopping/actions/runs/36722724521)
ran all three methods once on exact clean `5ca102a`: zero passed, three failed,
none skipped. Promotion's preservation assertions completed before its added
audit reported partially unsupported Dynamic Type for the identifiable Costco
caption. Sharing audits still reported unsupported Dynamic Type without an
associated element. These differing findings do not establish a common cause
or a framework defect. The no-override Home details screenshot shows the list
at its top, so deep scrolling is not necessary for its audit failure. Raw
results are at `/tmp/shopping-131-focused-36722724521`, with corresponding
lightweight evidence under the git common-directory validation evidence.

Retained screen recordings materially narrow the diagnosis. Status shows huge
saved-work text at 28.475 seconds, smaller top-summary text at 30.228 seconds,
then successively larger text and a blank list at 32.812 seconds. Home details
shows huge member text at 20.000 seconds, smaller Home/member/footer content at
21.880 seconds, then huge member text again at 22.992 seconds. Thus both views
responded to live font-size changes during the audits, even with the launch
override present. This does not establish every element/category's conformance
or identify why the audit lost its associated element. Timestamped extraction
evidence is retained under `video-diagnosis` in the validation evidence directory.

`fca1a4ef5f75e4f0769b69cc157fb63d32792902` adds unfiltered top-of-screen audits at
XXXL before the original sharing workflows, preserving all existing deep audits
and assertions. The first audit can itself alter layout, so subsequent workflow
results are conditioned on that audit and cannot alone establish a viewport
cause. Status temporarily allows continuation after the added audit's recorded
failures only; a defer restores its original stop-on-failure behavior.

[Top comparison 36724830739](https://github.com/mggarofalo/Shopping/actions/runs/36724830739)
ran exact clean `fca1a4e`: all three methods failed, none skipped. Both added
top audits executed without findings. Home details then failed its retained
member audit with a partially-unsupported/no-element finding. Status stopped
before its deep audit: the initial result text was not present in either
retained hierarchy at any element type; action rows extended below the viewport.
The automation type-mismatch hint therefore does not establish a type change
for that absent result. Catalog again reported the identifiable Costco caption.

The next candidate adds a temporary native SwiftUI App with short semantic-font
stack and List controls, bypassing ShoppingApp, its persistence bootstrap and
app delegate. Promotion preservation assertions finish before three unfiltered
calibration audits (stack top, List top and visible deep List text); its original
isolated store is then reopened without reseeding. Any calibration issue or
exception remains a test failure. Status now reveals its initial/finished result
text and brings Check status back onscreen for one tap and its enabled check.
All original exact-copy, audit and saved-identity assertions remain.

Local Xcode 27 / iOS 26.5 validation of dirty `fca1a4e` plus these changes ran two
methods once: Status passed completely; promotion failed only the added Catalog
Costco audit. All three native audits executed and returned without findings.
Source hashes matched before/after; an invalid-frame runtime warning remains.
This is not clean-commit Full evidence. Raw evidence is under
`/tmp/shopping-131-native-calibration-local*`; source manifest and timing reports
are retained under `native-calibration-local` in the validation evidence directory.
The independent review found no blocker for the same approved pinned diagnostic.

Clean `1e51139fb34a85ff2d103adc47bf885a3c15fc04` was tested in
[native calibration 36727897191](https://github.com/mggarofalo/Shopping/actions/runs/36727897191).
All temporary native controls, entry-point dispatcher, diagnostic call sites,
and the approved workflow must be removed before integration.

### Catalog action timing found by regular CI (SHOPPING-131)

[Regular CI 36724830475](https://github.com/mggarofalo/Shopping/actions/runs/36724830475)
tested clean PR merge `affb0b0471cfab3aa711b88e1540a67a89852c86`, whose tree
`364140df00ff4d63a2faa98f393a3c5f2ab80b86` equals `fca1a4e`. All 569 Fast methods
passed and the coverage/Release SDK checks passed. Canonical acceptance ran six
methods once: five passed; Catalog Save and add failed at the separate View
existence assertion before its tap. This is unrelated to the temporary Catalog
audit, whose method is not in acceptance.

The recording shows Added 1 and View visible, then gone. The success toast uses
its production three-second duration; the preceding Added 1 hierarchy query took
5.477 seconds. This supports a transient-action expiry race, rather than a failed
save or missing View action. Evidence, timing and two frames are retained under
`ci-36724830475` in the git common-directory validation evidence.

The focused correction dismisses the editor keyboard through its existing Done
control and verifies disappearance before checking/enacting Save and add. It
retains Added 1, directly taps View without a redundant existence query, and
retains the exact editor name and both no-duplicate assertions. The real toast
timer and unique store remain unchanged; no test-only lifetime override or retry
was introduced. Independent review found no proof-loss issue. Local raw logs
show the complete method passed in 23.574 seconds, with source hash unchanged;
Finalized xcresult confirms one pass, no failures/skips, and one structured
invalid-frame runtime warning. xcodebuild exited zero; simulator diagnostic
collection separately timed out after 600 seconds. Raw logs and phase records
retain that collection delay and warning. Pinned validation remains required.

### Native calibration result and diagnostic removal (SHOPPING-131)

[Native calibration 36727897191](https://github.com/mggarofalo/Shopping/actions/runs/36727897191)
ran the exact three methods once, zero skips, on clean `1e51139` and pinned
Xcode 16.4/iOS 18.5. All three methods failed. Native stack-top and List-top
audits returned without findings. The native deep audit ran after its exact
short-text and full-viewport containment checks; the before screenshot shows
“Saved work remains on this device.” fully visible, the after screenshot is
blank, and its unsupported-Dynamic-Type finding has no associated element.
This reproduces the no-element deep-list behavior without Shopping bootstrap,
Core Data or app delegates. It does not establish every sharing finding as a
false positive or identify the audit's internal cause.

Home details' top audit passed and its deep member audit recorded three
no-element findings. Status passed both result-label checks, the single Check
action and the enabled recheck, then failed the saved-work beginning audit;
its ending audit and return identity check did not execute. This confirms the
visibility correction without claiming the complete pinned workflow passed.
The added Catalog audit identified Pantry in this run (earlier runs identified
Costco); neither finding is silently treated as the same no-element issue.

Independent evidence review confirmed these limits. Full raw evidence remains
at `/tmp/shopping-131-focused-36727897191`; reports, log, audit details and native
before/after screenshots are retained under `focused-36727897191` in the git
common-directory validation evidence. Commit `1e51139` retains the reproducer.

The temporary workflow, native app/dispatcher/project entries and calibration
call sites, top comparison audits and Catalog audit were removed after diagnosis.
All original sharing audits remain unfiltered. The evidence-supported Status
visibility and Catalog keyboard/interaction corrections remain. The unresolved
pinned deep-audit failures still block SHOPPING-131 integration; no gate or
coverage baseline was changed and no speculative remote Full was dispatched.

[Regular CI 36727897239](https://github.com/mggarofalo/Shopping/actions/runs/36727897239)
subsequently passed all 569 Fast and the exact six acceptance methods once,
without skips/duplicates, plus coverage, selection checks and Release SDK Build.
Its clean tested merge `69d379f74c3b326d0f23a1d00ea4b259722ab316` has the same tree
as diagnostic candidate `1e51139`. App line coverage was 48.37%; deterministic
scope 96.29% passed the unchanged tolerance. The summary artifacts omit runtime
warning fields. This validates that diagnostic candidate's regular checks, not
the later toast fix/cleanup, and does not supersede the failed focused audit run.

The cleaned-up source passed the four affected local UI methods once with zero
failures/skips: Catalog Save and add, Home details XXXL, Status check/return XXXL,
and linking an existing catalog item. The result bundle records two invalid-frame
runtime warnings; xcodebuild exited zero. All six captured app/project/test hashes
matched after execution. Reports and manifest are retained under `cleanup-local`
in the git common-directory validation evidence; raw logs and xcresult are at
`/tmp/shopping-131-cleanup-local*`. This dirty-source focused run is not a new
clean-commit Full attestation and does not resolve the pinned audit blocker.

### Ordinary system text-size probe (September 30)

The user explicitly approved the ordinary-size diagnostic on a fresh CI simulator. It retains the same three test methods, all their original assertions, coverage baselines and Full attestation gates. A temporary native app entry point bypasses Shopping bootstrap and persistence, and exposes a plain SwiftUI List. A nonce-scoped host controller changes the actual simulator setting Large → accessibility XXXL → Large while the same native process remains alive. The test captures the viewport immediately and after settling before any scroll, then verifies the full deep text can be reached. Readbacks and cleanup verify the original setting is restored. This is additive diagnosis, not replacement production accessibility coverage.

- Local run: Xcode 27.0 / iOS 26.5 (23F77), a fresh task-owned iPhone 16 Pro simulator. The three methods executed once and passed, zero skips. The native List remained populated after both changes; the same complete deep text was reachable at each size. Its frame changed from `(16, 477.667, 370, 52)` to `(16, 355, 370, 217.333)` and back. Same process PID throughout. Actual setting readbacks were Large → accessibility XXXL → Large → original Large. Final and independent cleanup verified restoration.
- Local timing: build 54.302 seconds; test command 823.564 seconds; summed test duration 211.007 seconds. Xcode's diagnostic collector timed out after 600 seconds, retained in the raw log; xcodebuild still exited zero. One invalid-frame runtime warning remains visible. Captured source was dirty cb38992 plus the probe; all eight source hashes matched committed 3ca3244. Generated Python bytecode files in the capture were separately recorded and removed. This is not a clean Full attestation or pinned iOS 18.5 evidence.
- First pinned attempt [36733302043](https://github.com/mggarofalo/Shopping/actions/runs/36733302043), exact clean 3ca3244: build passed in 296.509 seconds, but the controller stopped the owned test process during startup when read-only runner-container discovery exceeded its ten-second command timeout. No tests, size requests or native probe executed, and no finalized usable result bundle was produced. Controller restoration readback also timed out; the independent always-step restored and verified the original category. This attempt establishes no ordinary-resize result.
- Startup repair 4c2bb8a retries only read-only runner-container discovery while the same owned child is alive, within eight minutes plus an in-flight lookup and the existing overall bound. No test is restarted. Four mocked cases passed: timeout then readiness; startup exhaustion; early child exit; child exit during a timed-out discovery. Independent review found no blocker. The existing probe, mutation/readback and restoration bounds are unchanged.
- [Regular CI 36733302033](https://github.com/mggarofalo/Shopping/actions/runs/36733302033) passed 569 Fast and the exact six acceptance workflows, all once with zero failures, skips or duplicate identifiers; coverage, selection gates and Release SDK Build passed. Its clean tested merge b6bb93166fbd94bf4412ada544bc4ddb4b91c655 had tree 85fe7d180c3117404aed12d53a0da802f195ac21, identical to 3ca3244. App line coverage was 48.38%, deterministic scope 96.29%; baselines unchanged.

Lightweight local evidence is retained under `.git/shopping-validation-evidence/shopping-131/native-system-resize-local/`, `focused-36733302043/`, `controller-startup-regression/` and `ci-36733302033/`. Raw local artifacts use `/tmp/shopping-131-native-system-resize-local*`. The failed pinned attempt remains retained alongside subsequent results.

- Second pinned attempt [36735791055](https://github.com/mggarofalo/Shopping/actions/runs/36735791055), exact clean 4c2bb8a: startup discovery recovered from a ten-second lookup timeout and found the runner at 34.187 seconds. All three methods executed once, all failed, zero skips. Both original sharing audits reported unsupported Dynamic Type. Promotion's original assertions completed before its additive native probe failed during initial readiness. The controller applied/read back Large and restored/read back original Large; no XXXL request occurred. The native List was populated at failure (twelve visible text elements recorded). One full readiness enumeration/signature took about five seconds; the second crossed the eight-second XCTest waiter deadline, so the native probe did not reach its baseline deep-text or resize phases. This is another incomplete resize experiment, not evidence of a blank List after an ordinary size change. Build 378.792 seconds, test command 384.407 seconds (exit 65), summed test duration 274.680 seconds. Controller and independent workflow restoration passed. Raw and lightweight evidence retained under the run-specific paths.

- Readiness-query repair 1a2e115 selects one actually visible native label, re-resolves its stable identifier, and requires matching frames across observations within the unchanged eight-second limit. It resets stability if the anchor disappears or leaves the viewport. Full-list captures cache only the viewport frame; they retain their full content criteria. The later exact-copy, complete visibility, growth and roundtrip checks are unchanged. The capture labeled “settled” now establishes a stable visible anchor, not simultaneous stability of every row. Independent review found no blocker.
- First affected local one-method check on the reused task simulator failed before this helper: the controller found the previous runner container before Xcode reinstalled the runner. Nonce-matching requests were written in the replacement container, so no host readback arrived. Build 51.118 seconds (exit 0), test 92.044 seconds (exit 65), one failed method with setup/restoration-handshake issues. The actual system category remained/restored Large; raw evidence retained at `/tmp/shopping-131-native-readiness-local*`. This does not validate the helper. A fresh-simulator check uses the same unchanged source and the same disposable-simulator condition as the approved remote workflow; the reused-container limitation is not being hidden by retrying a method within a run.

- Fresh local check on unchanged clean 1a2e115 passed the one affected Promotion method plus its additive native probe: 99.090 seconds, zero failures/skips, test/controller wall 125.792 seconds and exit 0. It reused the exact hashed products from the 51.118-second local build, on a newly created task-owned iPhone 16 Pro/iOS 26.5 simulator with no previous runner installation. All seven samples and all four setting handshakes were recorded. Pre-scroll visible-content counts were four at XXXL and eleven after return to Large; deep text remained fully reachable with exact copy and frame heights 52 → 217.33 → 52. Original Large was restored and independently verified; simulator shut down. This proves local wiring, not iOS 18.5 behavior. Source/product hashes and both failed reused-simulator and successful fresh-simulator runs remain retained separately.

- Completed pinned ordinary-size result: [36738480617](https://github.com/mggarofalo/Shopping/actions/runs/36738480617), exact clean 1a2e115, Xcode 16.4/iOS 18.5. The three methods ran once: Promotion plus native probe passed; both original sharing methods failed their unfiltered Dynamic Type audits. No skips. The native probe completed all seven samples with no failures and all four matching setting readbacks. The pre-scroll viewport remained populated at XXXL (four visible native texts) and after return to Large (twelve). Deep text was fully reachable with exact copy and frame heights 44 → 209.33 → 44; baseline/restored frames matched. Controller and independent workflow cleanup restored original Large. Build 264.757 seconds, test command 342.131 seconds (exit 65 from the retained sharing failures), summed test duration 257.651 seconds. This demonstrates that ordinary system size changes did not reproduce the native List blanking in this pinned probe. It does not prove production home/status behavior or invalidate all app audit findings. Original sharing audit failures remain blocking until an equivalent user-behavior proof is implemented and validated.

All ordinary-size workflow/controller/native-control code was removed after diagnosis. The retained product/test source returned to the cleaned cb38992 baseline; the subsequent production accessibility repair is evaluated separately.


### Production Settings text-size coverage (September 30)

The two existing home/status methods now exercise public Settings controls on the same running Shopping process. The original failing deep Dynamic Type audit calls are replaced with explicit user-behavior checks; findings are not filtered or marked expected. The original method inventory, role restrictions, exact member copy, status check, saved-work copy and Return-to-home grocery identities remain. The native calibration above explains why the proof mechanism changed, but is not itself production validation. This coverage verifies selected semantic styles and complete critical text at Large and accessibility XXXL; it does not claim every Apple audit heuristic or intermediate category is covered.

| Original proof | Retained production owner |
| --- | --- |
| Largest-text restricted Home details and long member | Same method at actual accessibility XXXL: rename disabled, invite absent, current member and full long name, wrapping height above 44 points, single Check members and no error. |
| Members Dynamic Type audit | Four witnesses using headline, caption, subheadline and body: full viewport containment and screenshots; each rendered height grows at XXXL and height/width returns at Large. |
| Sharing summary and explicit Check | Same truthful summary; automatic observation copy differs from the single explicit Check result; progress ends and Check is enabled. |
| Saved-work beginning/end audits | Exact full paragraph at each size; screenshots cover beginning through end with measured overlap and progress, stable dimensions within each phase, horizontal containment, growth and return. |
| Return preserves saved groceries at largest text | Single visible Return action at actual XXXL; exact grocery-row ID set captured and compared at that same category. |

After each Settings return, the tests check the original destination and visible top identity before scrolling. Native List may virtualize deeper content after reflow; those exact identities are verified after bounded scrolling without reopening or reseeding. Process continuity alone is not a claim that every view-model object or offscreen row survived.

A DEBUG-only opt-in observer publishes actual UIKit category, a process UUID, nonce, sequence and main-thread monotonic observation time to an atomic JSON file beside the supplied isolated UUID fixture. A private serial queue performs writes; it neither creates a shared container nor remaps paths. Existing key-window, scene-activation and category-change notifications trigger observations. The reader requires the original process, matching nonce, increasing sequence, foreground app and an observation captured after activation began. No SwiftUI state, environment, font, layout or accessibility property is mutated. Missing/unwritable observations fail within eight seconds. Existing fixture-path tests own writable-path retention and unwritable fallback; the UI method additionally demonstrates transport on its runtime.

Settings controls use bounded readiness and a single action. Before any global mutation, teardown captures and registers restoration of the original range switch, exact slider position/displayed value and actual UIKit category. The initial local state was Large despite the accessibility range switch being on, so category-only restoration would be insufficient. The same process/category checks apply on restoration. A host kill can prevent teardown; these methods require exclusive simulator ownership.

Failed transport attempts remain evidence. The first two-method window-identifier attempt failed both methods before Settings mutation (12.568 and 12.061 seconds). A one-method logging probe failed in 12.212 seconds: installation and key/scene events wrote/read the identifier, but later accessibility output was empty. A delayed readback then observed the same key UIWindow identifier cleared during startup; the responsible framework actor was not established. All window mutations and temporary logging were removed. These attempts and their source hashes are retained separately; they are not passing product evidence.

The first fixture-file attempt reached real Settings changes but failed both methods (36.821 and 27.607 seconds) because an immediate hittability guard observed Settings before foreground controls were ready. Restoration passed. The replacement waits within the existing eight-second bound before the single action. Independent review also caught a freshness gap: a queued pre-activation observation could satisfy a sequence-only check. Capturing monotonic time on main before queueing and comparing it with activation start closes that gap. Review also required stable paragraph dimensions and preserving Return at actual XXXL; both are included.

The next two-method local run passed Home details in 98.672 seconds and failed Status in 130.311 seconds. Status measured the Home section below Actions and then tried to reveal Check by scrolling downward; Check was above. The failure occurred before any Check tap. Only that first reveal direction and its missing-element diagnostic were corrected; the successful Home details source and shared runtime/Settings helper were unchanged. Original setting restoration succeeded. This failed run remains retained at `/tmp/shopping-131-settings-ready-local*`.

The corrected Status-only run then failed before opening Status: after a visible seven-tick normal range and midpoint slider adjustment, a fresh same-process UIKit observation reported XL rather than Large. The slider-position assertion passed, exposing why UIKit remains authoritative. Video showed the range change completed before the adjustment; the cause was not established. Teardown restored the original setting. Apple's [slider API](https://developer.apple.com/documentation/xcuiautomation/xcuielement/adjust%28tonormalizedsliderposition%3A%29) documents best-effort adjustment. The helper now keeps the accessibility range on for both test categories (Large at 3/11, XXXL at 1), removing repeated range changes while preserving exact original-control restoration and failing on any category mismatch. It records control and runtime observations for each phase; it never repeats an adjustment to turn a failed category assertion into a pass.

Independent visual review of the passing Home details run inspected all twelve target screenshots: headline wrapping changed 1 → 2 → 1 lines, caption 1 → 3 → 1, role subheadline 1 → 3 → 1, and the full long member name 2 → 4 → 2, without clipping or ellipsis in the target captures. Category attachments shared one process UUID and recorded Large → accessibility XXXL → Large. Original/restored switch, slider position/display value and category matched. Exact numeric frames were test assertions rather than separately retained measurement attachments. This is prior-helper local iOS 26.5 evidence, not Status or pinned validation; review JSON and screenshot paths are retained under `/tmp/shopping-131-settings-details-visual-review/`.

The fixed-range two-method run passed Home details in 94.456 seconds. Status passed actual-category transitions, the explicit Check, and paragraph overlap/growth/return, then failed before tapping Return: the final category transition deliberately positioned the view at the summary, but the inherited Return lookup scrolled upward although the button was below. The correction changes only that reveal direction. The successful Settings/metadata and Home details source remains unchanged for the focused Status follow-up; no failed action is retried within a run.

The bounded follow-up changed only the final Return reveal direction and ran Status once on local iOS 26.5. It passed in 160.476 seconds (170.874 seconds total build/test wall time, exit zero), including the Return action and exact grocery identities at XXXL. Settings restoration completed and independent system readback returned original Large. All six captured source hashes matched after execution. Raw result, timing, metadata and source manifest are retained at `/tmp/shopping-131-bounded-status/`. This is focused local evidence, not a clean Full attestation or pinned-runtime pass. The original approved three-method diagnostic workflow is temporarily restored for one pinned-runtime check and must be removed before integration.

Pinned run [36748933017](https://github.com/mggarofalo/Shopping/actions/runs/36748933017), clean `f5eb63f`, executed each of the three selected methods once: Promotion passed; both sharing methods failed at the `DISPLAY_AND_TEXT` button lookup before product text-size checks. A bounded artifact-only inspection found the identifier on a StaticText inside the visible Display & Text Size cell in both iOS 18.5 hierarchies; retained video frames confirmed that row was fully onscreen. `SystemTextSizeSettings` now retains the unique button route and additionally resolves the unique cell containing that StaticText when no matching button exists. It requires the Accessibility destination, bounded hittability, a single tap and the Display & Text Size destination. The evidence does not establish the pinned Larger Text controls. Runtime/category freshness, exact restoration, test inventory and product assertions remain unchanged.

The locator-only change ran Home details once on local iOS 26.5 and passed in 94.437 seconds (104.035 seconds build/test wall time, exit zero). The exact inventory was one passed method with no failures or skips. Attachments retained Large → accessibility XXXL → Large in one process and matching original/restored switch, slider position/displayed value and category; system readback returned Large. Five captured helper/test/product source hashes remained unchanged. Evidence is at `/tmp/shopping-131-settings-locator-local.09k2Du/`, based on `f5eb63f` with the uncommitted helper change. The initial timing export encountered a transient unavailable-summary error; that report is retained alongside the successful final export. Status was not rerun, and the iOS 18.5 cell route remains unvalidated. No remote run or new Full attestation was created; the temporary diagnostic workflow still requires removal before integration.

Pinned run [36754105550](https://github.com/mggarofalo/Shopping/actions/runs/36754105550), clean `389733d`, confirmed the Display & Text Size cell route and destination on iOS 18.5. Both sharing methods then failed at the `LARGER_TEXT` button lookup before any product text-size checks (Home details 43.485 seconds; Status 37.253 seconds); Promotion passed in 97.612 seconds. All three selected methods ran once, with no skips. Both retained hierarchies place `LARGER_TEXT` on StaticText inside a visible Larger Text cell. The test phase exited 65 after 791.121 seconds. Routine [CI 36754105464](https://github.com/mggarofalo/Shopping/actions/runs/36754105464) passed Build & Test and Release SDK Build on the same candidate. Durable failed-run logs, timing and hierarchies are under `.git/shopping-validation-evidence/shopping-131/focused-36754105550/`; the raw result bundle is at `/tmp/shopping-131-focused-36754105550-inspection/FocusedResults.xcresult`.

The navigation helper was first refactored to accept identifier/source/destination while retaining the existing Display & Text Size behavior, then reused for Larger Text. Both rows now share the unique button-or-containing-cell lookup, bounded hittability, single tap and destination verification. One local iOS 26.5 Home details check passed in 102.703 seconds (118.180 seconds build/test wall time, exit zero), with exactly one passing method and no skips. Attachments confirmed same-process Large → accessibility XXXL → Large and exact original switch/slider/category restoration; system readback returned Large and five captured source hashes remained unchanged. Evidence is at `/tmp/shopping-131-settings-navigation-local.feIrrJ/`, based on `389733d` with the uncommitted helper change. Status and the pinned Larger Text route remain unvalidated on this change. No additional hosted run or Full attestation was created. Temporary-workflow cleanup was deferred after the new pinned failure and remains required before final exact-SHA validation and integration.

Approved pinned follow-up [36758816146](https://github.com/mggarofalo/Shopping/actions/runs/36758816146), clean `4a7c376`, passed both cell navigation steps and reached the Larger Text destination. Both sharing methods failed at the outer `LARGER_DYNAMIC_TYPE_SWITCH` uniqueness check before global Settings mutation or product size checks (Home details 36.803 seconds; Status 17.711 seconds). The short-circuit guard did not evaluate the nested switch or slider. Promotion passed in 59.009 seconds; all three methods ran once with no skips. The test phase exited 65 after 578.024 seconds. Routine [CI 36758816228](https://github.com/mggarofalo/Shopping/actions/runs/36758816228) passed Build & Test and Release SDK Build. This failed result retains recordings and synthesized events, but no Larger Text hierarchy attachment; the exact range/slider element shapes remain unknown. Failed-run logs and timing are retained under `.git/shopping-validation-evidence/shopping-131/focused-36758816146/`; raw results are at `/tmp/shopping-131-focused-36758816146-inspection/FocusedResults.xcresult`.

The paused follow-up first centralizes range and slider queries, then collects both controls' reachable counts and values before the verdict and always attaches the full Settings hierarchy. A missing or ambiguous parent is reported without resolving a child against it; the other control is still observed. The existing unique outer switch, unique nested actuator, unique slider cell, unique slider and original-value requirements remain strict. Capture and verdict precede teardown registration and the first global size mutation. This diagnostic change typechecks against the iOS 17 simulator target but has not run in a UI test or on iOS 18.5. No further hosted run or Full attestation was created. A task-local compiler-backed source audit in `.git/shopping-validation-evidence/shopping-131/` accounts for one Settings owner, two callers, five identifiers and all resolved UI references; it also rejects a helper changed since its reviewed fingerprint. Source completeness does not establish Apple's runtime hierarchy. Temporary-workflow removal and final exact-SHA local/remote Full validation remain pending.

The bounded complete capture on pinned [36763446056](https://github.com/mggarofalo/Shopping/actions/runs/36763446056), clean `d709999`, retained both Larger Text hierarchies before Settings mutation. Both sharing methods failed; Promotion passed; all three ran once without skips. The range identifier is on StaticText inside a Cell containing one Switch, and the single Slider/Cell has no expected identifier. Routine [CI 36763446164](https://github.com/mggarofalo/Shopping/actions/runs/36763446164) passed both required jobs.

The subsequent [offline Settings contract review](shopping-131-settings-contract.md) maps every lookup, value read, size change and restoration operation to retained evidence and explicitly marks runtime gaps. The local repair first separates control resolution, then supports both evidenced shapes with strict uniqueness and one shared mutation/restoration path. It typechecks and has complete task-local source accounting; it has not run in UI automation. No tests, CI, push or new Full attestation were performed for this repair. Work stops at the reviewable patch and evidence table.

The authorized runtime follow-up at clean `927a698` passed both affected methods locally on iOS 26.5 with exact original Settings restoration, then failed pinned [36770676048](https://github.com/mggarofalo/Shopping/actions/runs/36770676048). All repaired locators resolved; Large was established in both retained processes and Status also established XXXL. Subsequent native Slider adjustments stopped at 73% instead of 100% (Home details) and 64% instead of 27% (Status). Home details restoration failed; Status restored the state captured after that failure. Promotion passed; all three methods ran once, no skips. Routine [CI 36770676040](https://github.com/mggarofalo/Shopping/actions/runs/36770676040) passed. The [contract review follow-up](shopping-131-settings-contract.md#authorized-runtime-follow-up) records the action and restoration evidence. These failures block integration; no additional diagnostic run, Full attestation, merge or TestFlight upload followed.

The user subsequently deferred this iOS 18.5 automation regression to SHOPPING-160 and authorized TestFlight validation build SHOPPING-161 from passing iOS 26.5 / Xcode 27 evidence. The temporary diagnosis workflow is removed. This validation-build exception claims no new Full attestation or iOS 27 runtime proof; assertions, plan inventory, coverage baselines and hosted preflight remain intact. SHOPPING-131 and SHOPPING-30 remain open. See the contract review disposition above.


### Immutable presence upgrade recovery (SHOPPING-162)

`PersonalCartServiceTests` owns deterministic old-producer presence payloads
across remove/re-add/checkout, unchanged replay and SQLite reopen, both the old
and current generation rules, current-generation authority after rejoin, and
retaining genuine conflicts without changing private records. The compatibility
matrix changes each payload field independently; only the exact historical
producer generation variant is accepted. Existing quarantine and permission
suites retain authority-boundary ownership. These checks do not establish
CloudKit delivery or two-iPhone sharing.

A local-only, disconnected copy of the attached iOS 27 TestFlight device stores
reproduced one current-rule conflict matching the exact historical variant.
The corrected production service completed two replay passes and home discovery
without changing the private record count or advisory presence values. The
snapshot and temporary diagnostic test remain local evidence, outside committed
fixtures. Physical build verification remains SHOPPING-162; two-phone proof
remains SHOPPING-30.

The broader Fast run exposed a separate activation-test completion race:
the injected provider fulfills its expectation before throwing. The test now
waits boundedly for bootstrap's failed state before retaining the original
retirement, store-detach, and retained-local-data assertions. Provider entry is
not treated as completion.

### Account-status recovery and Settings simplification (SHOPPING-163/164)

`ActiveHomeBootstrapTests` owns notification-driven, single-request reopening of
an identical verified account, mounted-presentation retirement before store detach,
retained SQLite groceries/cart/editor draft, separate-store account switching and
return, sign-out and network failure without invalidated-cache fallback, and a
second notification rejecting a suspended identity response. Existing
`ShopperSessionProviderTests` retains synchronous invalidation and late-response
fencing. The provider owns its notification subscription boundary so injected
centers exercise the real bootstrap observer without cross-fixture notifications.

`HomeSharingStatusUITests` keeps the same Large → accessibility XXXL → Large
geometry and full saved-work paragraph proof through a Details destination.
Groceries uses the existing tab; the duplicate Return to home action is removed.
`PersonalCartUITests` reaches migration claim/discard through Recovery, retains
same-store relaunch and historical restore access, and checks that recovery tools
are absent from root Settings. The unavailable-home retained-cart route remains
on the waiting root. No recovery data is hidden based on an unknown count, and
no persistence query was added to a view body. Live account events and two-phone
sharing remain device evidence, separate from injected notification proof.

### Consumer Home settings cuts (SHOPPING-165)

Michael rejected the diagnostic paragraphs and empty rows introduced by the
sharing-status screens. The consumer presentation is now distinct from internal
observation/accounting semantics: HomeSharingActivityTests owns healthy-state
omission, scoped latest-success time, exclusion of previous-account observations,
independent cloud failures, and omission of unactionable held-work/preparation
counts. HomeSharingStatusTests and bootstrap tests retain observation truth,
account boundaries, scoped work and bounded checks without rendering that ledger.

| Changed UI proof | Current owner |
| --- | --- |
| Summary, saved-work paragraph and diagnostic Details geometry | Retired with the removed product UI. HomeSharingStatusUITests retains actual same-process Large → accessibility XXXL → Large, full Check control containment/growth/restoration, one explicit check, absent success/error boilerplate on a healthy fixture, and identical grocery IDs on the existing Groceries tab. |
| Healthy membership counts and verification caption | Retired with removed text. HomeDetailsUITests asserts actual member identities, roles, pending invitation/resend, cancellation/removal outcomes and preserved groceries. The text-size method retains headline, role and long-name witnesses; it uses native pull-to-refresh instead of an unconditional duplicate Check members button. |
| Settings Recovery routes | Removed by product direction. PersonalCartUITests reaches explicit legacy claim/discard only through My cart when pending entries exist, asserts the contextual link disappears after a durable decision/relaunch, then restores earlier cleared groceries through My purchases. The create/switch workflow opens the original home's saved private cart from the new home and verifies its contents again after relaunch/switching back. The missing-home private-cart cleanup and Groceries purchase undo routes remain unchanged. |
| Settings Home/Homes/Sharing links | One Home entry owns Home → Sharing status / Manage homes. Existing create/switch/resume/adoption workflows use that route. ShoppingDeviceUITests retains trailing-edge geometry on the Home row rather than the deleted status row. |
| Outgoing private invitation | HomeInvitationActivitySourceTests verifies message/mail purpose and exact URL, URL-only Copy/Reading List, and preview metadata retaining the same URL. HomeDetailsUITests keeps native sheet cancellation, pending invitation/resend, private-cart consent and one-person link disclosure. No recipient is contacted by automation. |

PersonalCartPresentationTests owns background pending legacy discovery, omission
after an explicit decision without deleting its audit record, actual checkout and
private cleanup remaining available when imported legacy records are incomplete,
nonempty other-home cart/history discovery, and earlier-clear discovery in a
second SQLite store. That store fixture proves discovery across stores, not live
Contributor sharing. A shared EarlierClearedGroceriesLink applies one selected
home/list policy in both legacy review and My purchases; mismatching/nil selection
tests prevent a saved cart from opening another home's recovery. Existing blocked
writer tests retain main-actor responsiveness. No view body queries persistence.
The new concise check-problem state shares the existing bounded check lifecycle;
bootstrap tests assert timeout/failure/busy text and no problem on success.

Two independent product passes required further cuts after the first structural
pass: no empty activity row, no held-work advice that cannot release publications,
one failed-check notice, and no bulk Stop sharing beside the same single-member
removal. Interrupted invitations use one set of pending controls; an unavailable
leave-status read retains its retry. Essential consent stays at the action.
The visual second pass also removed Rename home for read-only members; the
restricted text-size workflow asserts its absence while retaining identity and
role readability. Allowed users retain temporary busy/stale disabling.

This scope uses Fast and the affected simulator workflows plus routine CI, without
a new ShoppingFull attestation. The deferred iOS 18.5 Settings slider automation
regression remains SHOPPING-160; local system-text-size evidence is iOS 26.5.
Two-phone CloudKit proof remains SHOPPING-30. No physical timing target is claimed
from these simulator checks.

### Stable phone check indicator (SHOPPING-166)

The conditional Checking progress row is removed. A single native Check status
button owns its persistent trailing cloud symbol, active pulse and accessible
Checking value; Reduce Motion suppresses the pulse. It observes the existing busy
state and does not start persistence work during rendering. No domain or check
lifecycle behavior changes. HomeSharingStatusUITests retains navigation, one
explicit check, Large → accessibility XXXL → Large geometry and identical
grocery identities. HomeSharingStatusCheckTests and bootstrap tests still own
bounded waiting, duplicate suppression, background local reads and stale-result
isolation. No test selection, coverage baseline or Full attestation changes.
Simulator checks do not establish physical-device timing or two-phone delivery.


### Home title, member menus and fixed activity (SHOPPING-169)

Home details now uses the saved home name as its navigation title. The removed
home-name card's headline witness is replaced by the Members heading; the
restricted text-size workflow still measures actual Large → accessibility XXXL
→ Large in the same process, with full role/name containment, long-name wrapping,
growth and restoration. Rename remains a native pencil toolbar action and is
absent for read-only members. Sharing status is a native cloud toolbar link,
rather than a list navigation row.

HomeDetailsUITests retains owner removal cancellation/confirmation, stop-sharing
consent, invitation sheet cancellation and resend, contributor rename/relaunch,
read-only restrictions and preserved grocery identities. Resend and removal are
now exercised through the member's native Menu. The new suspended-refresh
workflow proves cloud navigation stays interactive on entry and return, no
Checking home row is inserted, and the cloud control keeps its size/position
when the refresh finishes. Its explicit opt-in delay is confined to the isolated
Home details UI fixture; production reads are unchanged.

HomeMemberPresentationTests owns optional email/name fallback, one Owner role
for an unnamed current owner, omission of a repeated fallback role, pending-link
anonymity and read-only labeling. Emails come only from the participant identity
already returned by CloudKit. There is no recipient lookup or new permission.

Create home and Resume creating home are removed by product direction. The
former create/switch UI method is replaced by
testSwitchExistingHomesPreservesOriginalGroceriesAfterRelaunch, which seeds a
second existing home in its isolated fixture, chooses the original, carts an
item, switches away, checks the saved private cart, relaunches and switches back.
The removed creation/resume UI controls have no UI proof owner.
HomeCreationTests retains journal identity/replay, acknowledgement and stale
resume, changed-account denial, failed-save retention and partial-graph safety;
ActiveHomeBootstrapTests retains explicit creation/discovery and home-selection
authority. Existing invitation/adoption/retained-local-home UI routes remain.
This change does not delete saved creation journals or recovery services.

Validation uses Fast and these focused UI owners; no Full attestation is claimed.
Physical timing for the changed build remains a separate device observation.

Validation on iOS 26.5 for SHOPPING-169: ShoppingFast passed all 597 tests.
The affected owner invitation/removal/stop-sharing, contributor rename/leave,
read-only Large → accessibility XXXL → Large, existing-home/cart relaunch,
retained-local adoption, and invitation-dismissal workflows passed. The final
cloud-toolbar workflow passed its suspended-read navigation and unchanged
position/size assertions; the final Sharing status large-text workflow also
passed. Earlier failures and the bounded corrective reruns remain in the local
evidence; this is not a claim that every affected owner ran together on the
final candidate. No Full suite or new Full attestation was run. Physical-device
before/after timing is recorded separately with the release evidence.

## Native home entry and selection (SHOPPING-172)

`PersonalCartUITests.testFirstHomeCreatesInOneTapAndRestoresAfterRelaunch`
uses a unique empty account fixture to prove the first Create Home action mounts
My Home with an empty list and restores it after relaunch. It does not depend on
a production iCloud account.

`PersonalCartUITests.testAcceptedInvitationOpensExactHomeWithoutAppJoinTap`
uses a unique accepted invitation fixture to prove the direct Invitation sheet,
absence of a second Join action, automatic selection of Second home, and the
original home still present in Homes. `testDismissPendingInvitationPersistsAfterRelaunchAndKeepsGroceries`
uses a separate incomplete archive fixture to prove Not Now survives relaunch,
retains the selected groceries, and leaves an Open Invitation recovery row.
The fixture does not assert successful native CloudKit delivery.

`PersonalCartUITests.testSwitchExistingHomesPreservesOriginalGroceriesAfterRelaunch`
owns the flat Homes picker and scope-specific grocery/cart contents across
switch and relaunch. `testLocalHomeRemainsAvailableInHomesPicker` owns the
On This iPhone row, unchanged local groceries after declining an invitation,
and the retained local home's explicit Use iCloud action before copying.
Account activation and exact retained source are covered by
`HomeAdoptionBootstrapTests`; no accepted-local UI journey is claimed.

`HomeDetailsUITests.testOwnerDirectShareCancellationKeepsPendingInvitationAvailableToResend`
proves Invite opens the system share sheet in one action, cancellation retains
pending membership, and Resend opens the sheet again. The owner pending-member
removal and contributor native Leave alert scenarios remain separate UI owners.
`HomeMembershipRemovalTests` retains Stop Sharing backend recovery proof after
its ordinary UI entry was removed. SHOPPING-173 owns owner Delete Home UI proof.

## Home deletion and retained local conversion (SHOPPING-173)

`HomeDetailsUITests.testOwnerDeleteRequiresExactHomeConfirmationAndCanRecreateAfterRelaunch`
owns the owner-only native exact-name Delete alert, cancellation without
submission, deletion of the fixture's sole home, `No Homes` after relaunch,
continued private-cart recovery access, and explicit creation of a new home.
The contributor fixture asserts Delete is absent. Its unshared fixture does
not claim a live CloudKit delete.

`PersonalCartUITests.testLocalHomeDeleteCanCancelThenRecreateAfterRelaunch`
owns the equivalent local-only exact-name warning and explicit recreate after
relaunch. `testRetainedLocalUseICloudCopiesHomeAndKeepsSourceSelectable`
uses the isolated retained-local fixture to prove one explicit copy opens an
owned home with its grocery need while the source stays selectable. Domain
tests own the exact captured identity, account guard, replay, cart disposition,
and pending remote deletion permutations. The Homes recovery row reconciles
the recorded command. An owner purge can retry only after fresh exact share,
owner, account, store, and zone validation. No two-phone deletion proof is claimed.

`HomeDeletionTests` owns complete local and unshared owner graph removal,
preservation of every prior private record and unrelated home, SQLite reopen,
retired presentation and changed graph rejection, durable local intent before
save, and account fencing. Its injected native backend owns offline failures
before submission, uncertain submission, and local removal before server
confirmation. Reconciliation checks ownership again; a completed operation
does not submit another purge. These deterministic tests do not prove live
CloudKit zone behavior. `HomeAdoptionBootstrapTests` owns discovery and recovery
of an interrupted retained-local deletion while the account store is mounted.

The 13 `HomeDeletionTests` cases own these boundaries:

| Test | Boundary |
| --- | --- |
| `testLocalDeletionRemovesCompleteGraphPreservesOtherHomeAndSurvivesReopen` | Complete local graph, unrelated home, durable deletion, fresh IDs, rejected old-ID replay. |
| `testOwnedUnsharedDeletionRetainsPrivateCartAndEveryPriorSemanticRecord` | Unshared owner deletion preserves private record bytes, cart tokens and quantities after reopen; household demand becomes unavailable. |
| `testStaleCapturedGraphAndRetiredPresentationNeverRetainDeletion` | Changes before confirmation and retired UI authority cannot start deletion. |
| `testLocalMarkerBeforeSaveCanFinishAfterReopen` | A retained local command survives termination before graph deletion. |
| `testOfflineSubmittedOwnerDeleteRetriesOnlyAfterFreshOwnershipValidation` | Uncertain native submission can resume after fresh validation. |
| `testOfflineBeforeSubmissionRetainsExactConfirmationAndResumesAfterReconnect` | Offline preflight retains intent without falsely recording native submission. |
| `testLocallyPurgedButServerZonePresentRecoversWithoutDeletedRoot` | Recovery does not depend on an already removed local root. |
| `testAccountChangeCannotRetryOldSubmittedDelete` | Another account cannot resume the captured deletion. |
| `testConfirmedDeletionCoversLaterImportedChildrenOfOnlyTheSameHome` | Later children require validated, append-only coverage; the original command remains unchanged. |
| `testConfirmedServerAbsenceCleansLocalResidueWithoutAnotherPurge` | Confirmed server-zone absence permits exact local cleanup, preserving private evidence. |
| `testCompletedDeletionRetiresOnlyItsPendingCreationAndAllowsFreshIDs` | Local and account creation journals retire only the deleted result and allocate new identities. |
| `testPartialLocalRootOrListRetriesRecordedCoverageWhileServerZoneExists` | Missing root or list does not strand already covered children; missing relationships cannot expand authority. |
| `testPartialLocalRootOrListCleansRecordedCoverageAfterServerZoneIsGone` | The same partial residues are removed after authoritative server absence; every covered URI must disappear. |

`ActiveHomeBootstrapTests.testImmediateCreateRetiresDeletedPendingIDsBeforeStatusHydration`
owns the immediate local Create boundary: an old pending creation still exists,
the screen already offers Create, and no deletion-status refresh is requested
before the action. The result must have fresh household/list IDs and exactly
one home. Creation itself awaits exact completed-deletion retirement; screen
hydration is not the authority for choosing IDs.

`RetainedHomeConversionTests` owns the selected source graph, exact-ID replay
after save but before acknowledgement, private-cart/history exclusion,
unchanged source and unrelated homes, account rejection, and fresh recopy IDs
after a completed destination deletion. The Bootstrap owners are:

- `HomeAdoptionBootstrapTests.testExplicitRetainedCopyCreatesOwnedAccountHomeAndKeepsOriginal`
- `HomeAdoptionBootstrapTests.testCompletedCopiedHomeDeletionPermitsOneNewExplicitCopy`
- `HomeAdoptionBootstrapTests.testRetainedDeviceHomeStaysReachableAcrossAccountChangeWithoutCopyingToNewAccount`
- `HomeAdoptionBootstrapTests.testPendingRetainedLocalDeletionReconcilesWhileAccountHomeIsOpen`
- `ActiveHomeBootstrapTests.testDismissingInviteDuringHeldAccountLookupAllowsFirstLocalHome`
- `ActiveHomeBootstrapTests.testDeferredUnboundInvitationAllowsExplicitOfflineFirstHome`

### SHOPPING-173 local validation record — October 2, 2026

These runs used the issue worktree before integration. Their names identify
the local `/tmp/shopping-phase24-173*.log` evidence; they are not CI or
exact-commit release attestations.

| Run | Result and correction |
| --- | --- |
| `173b` | Fast: 628 passed, 2 failed. The deletion test incorrectly expected `demandAvailable` to remain true after removing the household; it now separately asserts unavailable demand, unchanged private record bytes, cart tokens and quantities. The conversion test queried account A's store through account-bound discovery after switching to B; discovery correctly rejected it. The test now checks the unchanged raw root count without bypassing the account guard. |
| `173d` | Focused run failed `testDeferredUnboundInvitationAllowsExplicitOfflineFirstHome` with `scopeChanged`; all 11 deletion cases then present passed. The test attempted Create while its automatic connection transition could still be in flight after Not Now. A bounded wait now settles that exact task and checks the visible `noHomes` state; production authority checks remain intact. |
| `173e` | Full ShoppingFast passed **638/638**, including all 13 deletion cases and the immediate-Create Bootstrap regression. One QoS runtime warning remained in the run evidence. |
| `173-ui-a` | Three of four focused UI cases passed. Retained copying left a stale local Home Settings screen after the account store became ready. The view now dismisses on that ready store transition; copy/content/original-source assertions remain. |
| `173f` | Focused: 56 passed, 3 failed methods. Two retained-copy methods exposed missing returns in source-identity properties; fixed. Immediate-Create seeded/deleted its graph after Bootstrap started, allowing startup discovery to select it; the fixture now persists and closes its store before cold launch. Xcode's post-failure simulator diagnostic collection stalled for over five minutes; its diagnostic child was stopped after sampling, and the failed result bundle was retained. The test process was not stopped. |
| `173g` | Focused: **58/58 passed** across home adoption, retained conversion, first-home Bootstrap and home naming. Two QoS runtime warnings remained. This validates the corrected source and fixtures, not the earlier `173e` source. |
| `173-ui-b` | **4/4 passed**: owner delete/relaunch/recreate; local rename/relaunch, cancel/delete/recreate; retained copy with selected contents and original-source return; retained Homes picker. One QoS runtime warning remained. |

Independent review found replacement-source and interrupted-copy deletion gaps.
`DeviceLocalHome` now identifies an explicitly selected local graph independently
of the immutable initial adoption record. Conversion history retains each source
command, and exact completed deletion also retires a bound copy whose save
committed before its acknowledgment. The added proof owners are:

- `HomeAdoptionBootstrapTests.testDeletedRetainedSourceCanCreateAndCopyNewLocalHomeWithoutRewritingAdoption`
- `HomeAdoptionBootstrapTests.testJoiningAfterReplacingDeletedLocalSourceKeepsNewHomeReachable`
- `RetainedHomeConversionTests.testDeletedBoundDestinationRetiresCopyInterruptedBeforeJournalAcknowledgement`
- `HomeNameTests.testLocalRenameKeepsExactGraphAndRejectsRetiredOrMismatchedCommands`

The local rename UI scenario now verifies the saved name after relaunch and the
same name in the deletion confirmation. Review also required the exact invitation
open intent to be checked again after writing a selected-local reference, so Not
Now cannot be overtaken by that asynchronous write. Both independent reviewers
verified their requested fixes; the test review found no weakened assertions or
fixture-isolation defect.

Final validation of the committed, combined milestone source remains separate
from these issue-worktree runs.
Injected native backends prove command/recovery behavior, not actual CloudKit
zone deletion. Owner deletion and its propagation still require live two-phone
validation; the user's successful invitation join/sync does not establish that
separate deletion result.

## Watch home scope (SHOPPING-183)

`PersistentWatchShoppingServiceTests/testHomeNameFollowsWatchSelectionAndRefreshesAfterRename`
owns the selected household's displayed name across two separate homes and a
rename, including stable command authority through a rename. The existing
`WatchShoppingUITests/testStoreAndSyncScrollAwayAndReturnOnlyAtTop` and
`testSyncIconShowsDetailsWithoutRoutineBannerAndDismisses` also assert the home
label on groceries, store selection, and cart, with the complete name available
to accessibility. Watch selection remains independent of iPhone selection.
These fixtures do not prove physical presentation or CloudKit delivery.

## Saved cart home identity (SHOPPING-184)

`PersonalCartServiceTests.testSavedCartHomeDisplayUsesExactGraphAndFallsBackForMissingOrAmbiguousHome`
owns exact household/list name resolution and generic Saved Home for absent or
duplicate roots. `testSavedCartHomeDisplayRejectsAnotherAccount` owns account
isolation. `HomeDeletionTests.testOwnedUnsharedDeletionRetainsPrivateCartAndEveryPriorSemanticRecord`
also checks the deleted home's captured name after reopening its private cart
ledger. These reads use the serial persistence writer off the main actor.

`PersonalCartUITests.testSwitchExistingHomesPreservesOriginalGroceriesAfterRelaunch`
owns the distinction between the selected home shown across Groceries,
Catalog, Settings and current My cart, and the static original-home label in
the saved cart before and after relaunch. Its cart contents and home-switch
assertions remain in place. This simulator workflow does not prove CloudKit
delivery or the two-phone acceptance required by SHOPPING-174.

## Account-bound home navigation (SHOPPING-185)

`HomeInvitationInboxTests.testAccountBoundaryDurablyDefersOnlyBoundOldNavigationAndKeepsManualOpen`
owns the atomic journal boundary: it retires old account automatic Open while
preserving accepted state, the current account's intent, an unbound native
delivery, and manual Open after a cold journal read.
`testPersistedUnknownAccountInvalidationDefersAllBoundButNotFreshUnboundIngress`
owns the narrower crash recovery rule when the provider has saved only that an
account changed: all older bound auto Opens retire atomically, while a new
unbound native delivery remains eligible for verified onboarding.
`ActiveHomeBootstrapTests.testAccountChangeDefersQueuedNavigationBeforeNewMountAndColdReturnKeepsPriorHome`
owns the held account verification ordering and restored prior selection across
A→B, termination, and B→A. `testCachedOtherAccountDefersOldIntentWhenVerifiedBeforeReturning`
owns the cold cached-B to verified-B boundary; it leaves the old intent intact
while offline and retires it on verification before returning to A.
`HomeAdoptionBootstrapTests.testAccountChangeDuringHeldAcceptedOpenDoesNotReviveItAfterColdReturn`
owns the imported-ready automatic activation path with native verification held,
a prior selected home, cold return, and a later explicit Open.
`testColdInvalidatedAccountRetiresReadyInvitationBeforeSameAccountVerification`
owns the interrupted provider invalidation before any inbox write, including
the same account being freshly verified on restart.
`ShopperSessionProviderTests.testTypedAccountEventsCaptureOutgoingIdentityAcrossFastReverificationAndSignOut`
owns the exact outgoing identity carried by account-change and sign-out events
even if the provider resolves again before Bootstrap handles the event.
`testInterruptedCopyAfterAccountChangeCompletesWithoutRearmingOldSelection`
owns the separate conversion-command versus navigation-intent result: A's copy
recovers after B without selecting it over A's saved home. These isolated stores
and substituted account lookups do not prove live CloudKit propagation.

The first SHOPPING-185 focused attempt (`185-a`) selected the obsolete
`ShoppingFastTests` target and stopped before building or running tests. The
corrected `185-b` compiled until an out-of-scope `session` reference in the new
copy-intent guard; no tests ran. `185-c` ran 74 focused tests: 73 passed, and
the existing retained-copy test observed durable `.copied` before the later
home-discovery/selection task completed. Its assertion now awaits that exact
selected copied home within a bound. The final source and added cases require
the next exact-tree validation; these earlier runs do not validate them.
The committed `7b477ab` candidate passed ShoppingFast **649/649** with three
runtime QoS warnings. Review then found a persisted account invalidation that
could lose its meaning across a crash, plus delayed provider callbacks that
could mistake a fresh account for the invalidated one. The successor adds the
cold-start journal barrier, exact outgoing-session event capture, and a bounded
drain assertion after releasing held native verification. This later production
source and its fixture changes require exact-tree validation before integration.


## Final Phase 24 validation (SHOPPING-174)

The committed combined lifecycle source `2e634c631f68dfcf2f8be0a8c54701f30290d7a3`
was integrated as `8433077` with exact tracked-tree equality. Final local proof
was ShoppingFast **642/642**, eight home UI workflows **8/8**, and Watch
**63/63** (61 unit checks and two UI workflows). Fast retained two QoS runtime
warnings, home UI one, and Watch none.

SHOPPING-184 source `e6773f6` passed Fast **644/644** with three QoS warnings.

## Homes picker compiler compatibility (SHOPPING-186)

`HomeSelectionView` now builds its existing native List from small section and
row builders so the pinned Release compiler can type-check it. This is a
structural change: the same home, local, invitation, create, Settings, status,
and error rows retain their conditions, actions, labels, and accessibility
identifiers. Existing `PersonalCartUITests.testSwitchExistingHomesPreservesOriginalGroceriesAfterRelaunch`
owns flat selection and saved-cart scope; `testLocalHomeRemainsAvailableInHomesPicker`
owns the local row. No new behavioral test is added for the split.
The clean local source `8e0039c` has the same tracked tree as integrated
`a8f10c0`. Its unsigned
Xcode 27 Release archive passed (`/tmp/shopping-phase24-186-release.xcarchive`,
`/tmp/shopping-phase24-186-release.log`), and the focused native picker UI run
passed **2/2** without runtime issues (`/tmp/shopping-phase24-186-ui.xcresult`,
`/tmp/shopping-phase24-186-ui.log`). Pinned Xcode 26.3 verification is pending.
The first CI run `37029619808` on head `24b7e35` failed Release compilation in
`HomeSelectionView.body`; Fast passed **649/652**, with three copy-selection
failures assigned to SHOPPING-187. Coverage passed; Acceptance was skipped.
The destination-readiness test successor `b9a1d00` passed switch/relaunch UI
**1/1** without runtime warnings. Its integrated tree `6904246` matches issue
`d1042c2`; the extra change was trailing whitespace cleanup. The first 184 build
stopped before tests because a project path containing `+` was unquoted; the
quoted path passed project lint and subsequent builds.

SHOPPING-185 source `423cd8a` ran Fast **651/652**. The first-home test helper
repeated `start()` through the no-transition loading branch, permitting a late
local fixture load to publish during account entry. The helper now drives only
the requested account transition. Review also replaced a default notification
broadcast with the exact fixture's private center. Existing outcome assertions
were preserved. Final committed `ac5512b` passed Fast **652/652** and five native
UI workflows **5/5**; its tracked tree equals integrated `d1feb35`. Fast retained
three QoS warnings; UI none. A navigation-update warning appeared in the Fast
log during presentation retirement. No physical responsiveness result is claimed.

## Retained-copy home selection (SHOPPING-187)

Pinned CI run `37029619808` on the pre-fix milestone source passed **649/652**
Fast tests. Three `HomeAdoptionBootstrapTests` methods found that the explicit
Use iCloud copy committed while ordinary same-account discovery left the
existing account home selected: initial retained copy, deletion followed by
recopy, and deletion of the retained source followed by copying a fresh local
home. The original graph, home-count, name, and selected-row assertions remain.
`ActiveHomeCoordinatorTests.testDiscoveryAuthorityDoesNotReplaceExplicitHomeChoice`
owns the distinction between access/discovery command authority and an explicit
home choice, including same-home reaffirmation and Not Now. The two held-copy
Bootstrap tests own a same-account access refresh with delayed copied-graph
discovery and a newer reaffirmed home choice during that delay. The exact copy
destination must be discovered in the verified account before automatic Open;
an unavailable first observation keeps the in-memory intent for a later refresh.
`testAcceptedInvitationDuringHeldCopyKeepsNewerNavigationIntent` owns a native
invitation ingress while copied discovery is held; it drains the actual copy
consumer before asserting that the accepted invitation stays open and the
existing account home stays selected. The Homes picker sends a checked-row tap
through the same selection command so reaffirmation is recorded.
`testAcceptedInvitationDuringCopyAccountLookupCannotBeOverwrittenByLateCopyIntent`
holds account verification before the copy journal is prepared, accepts a newer
invitation, then drains the copy consumer. The copy may commit, but its older
navigation choice must not be installed after the newer invitation arrives.
`testAccountInvalidationDuringCopyLookupDoesNotRearmOpenAfterSameAccountVerification`
holds that same lookup across an exact CloudKit account invalidation and a fresh
verification of the same account. It waits for the actual in-flight approval to
retire before releasing the old lookup; a committed copy must leave the prior
account home selected. The preparation task and copy consumer have bounded
completion checks before fixture cleanup.
The existing account-change copy test continues to own the different-account
deferral rule. CI coverage passed its app and domain gates; no baseline changed.
The fix awaits exact-source local and pinned-CI validation.
The first focused source passed **62/62**, and its successor passed Fast
**656/656** with no failures or skips. Both precede the held account-lookup
ordering fix and do not validate that final source.
The next candidate passed Fast **657/657** with no failures or skips. Review
then found an account-invalidation window before the copy intent was installed;
the exact-session preparation fence and held-lookup regression were added
after that run and need final validation.

The [home-sharing execution record](home-sharing-validation.md) records source,
local bundles, app-menu counts and remaining physical acceptance. Pinned CI and
its final pushed SHA belong in the phase PR and SHOPPING-174 comment. These
focused UI selections are not ShoppingFull attestation.

The first combined SHOPPING-187 Fast attempt (`187-fast-a`) stopped before tests
at an optional Boolean assertion in the new invitation-ingress regression. The
assertion now explicitly requires `true`. Review also bounded the owned copy
consumer completion and teardown expectations; selection assertions remain intact.
The earlier focused `187-focused-a` run passed **62/62** before the invitation
ordering and completion follow-ups. Final combined validation is still pending.

Final SHOPPING-187 production candidate `71d86d2` passed the six affected
account/invitation/recovery suites **119/119**, with no skips and one QoS warning
(`/tmp/shopping-phase24-187-final-focused.xcresult` and `.log`). The same committed
source passed four native UI workflows **4/4**, no skips or runtime warnings
(`/tmp/shopping-phase24-187-final-ui.xcresult` and `.log`): automatic accepted
invitation Open, durable Not Now, retained local Use iCloud, and switching with
saved-cart scope across relaunch. The ordinary preparation callback now shares
185's current-provider authority; exact invalidation retains outgoing identity.
Both independent production reviewers verified the final fixes; test review
verified bounded preparation/consumer cleanup and fixture isolation.

Earlier committed `3146c2c` passed full local Fast **657/657**, no skips and three
QoS warnings (`/tmp/shopping-phase24-187-final-fast.xcresult` and `.log`). This
predates the account-preparation follow-up. `9d5773b` passed affected suites
**119/119**, one QoS warning, before the ordinary-callback correction
(`/tmp/shopping-phase24-187-account-focused.xcresult`). The final complete pinned
Fast/Acceptance/Release/coverage result must be recorded against the pushed SHA
in PR 68 and Plane. No Full attestation, physical CloudKit proof, or device trace
is claimed by these focused local runs.

Pinned CI `37036719461` built the Release app and passed coverage (app
**51.70%**, domain **96.30%**), but Fast passed **656/658**. All three original
copy-selection regressions passed. Two new held-order methods failed: the
discovery gate allowed a competing two-home refresh to escape before its
synthetic access observation, and the copy consumer handle could be replaced by
a later account load while the original resume task still owned the write.
The gate now holds every real two-home result until release and identifies the
synthetic access refresh with a task-local request value. Bootstrap serializes
retained-copy resume tasks under one owned completion chain; a later task waits
for its predecessor, and tests drain the actual chain. A distinct approval ID
keeps an older failed resume or awaited fulfillment from clearing a newer
explicit approval that happens to reuse an idempotent conversion command.
The copied-home count and selected-home assertions remain unchanged. This
successor requires exact-source validation; the earlier CI result does not
validate it.

Committed ownership follow-up `55180bf` passed six affected suites **119/119**,
no skips and one QoS warning (`/tmp/shopping-phase24-187-ownership-focused.xcresult`
and `.log`). The same source passed retained-copy and switch/relaunch native UI
**2/2**, no skips or runtime warnings
(`/tmp/shopping-phase24-187-ownership-ui.xcresult` and `.log`). Both production
reviewers and test review verified task ownership, approval guards, all-discovery
holding, explicit task-local access tagging, and bounded cleanup. Complete pinned
Fast/Acceptance/Release/coverage remains required on the next exact pushed SHA.

### SHOPPING-188 duplicate home identity

`ActiveHomeCoordinatorTests.testDuplicateHomeNamesKeepStableContextAcrossDiscoveryAndStoreMounts`
owns the iPhone snapshot boundary: same-name owner homes remain distinct in the
picker and selected scope after discovery order, store URI, and store identifier
change. `testDuplicateNamesUseExistingRoleAndLocalContextBeforeGeneratedTags`
owns the concise role/local context rule and unchanged unique names.
`testGeneratedContextsStayUniqueWhenShortWordTagsCollide` owns collision
extension without exposing graph identifiers.
`testLiteralHomeNameCannotMatchAnotherHomesGeneratedContext` owns final-title
collisions between a literal saved name and either a role label or word tag,
including discovery order changes.
`PersonalCartServiceTests.testSavedCartNameUsesWholeHomeRosterWhenOnlyOneCartScopeIsRequested`
owns saved-cart labels when only one of two same-name scopes has a visible cart.
`PersistentWatchShoppingServiceTests.testDuplicateHomeNamesRemainDistinctOnWatchAcrossSelectionAndReload`
owns Watch selection and reload projection. All labels are presentation-only;
the household name and graph identities remain unchanged. These new tests await
focused and exact-source validation.
`HomeDetailsUITests.testOwnerRemovalConfirmationCanCancelThenRemoveOnlyContributor`
continues to own native removal-alert cancel and exact-contributor removal. It
uses the alert’s unique action identifiers and retains the surviving-owner and
member assertions; the pending-invitation cancellation and groceries proof
remains in its separate existing UI test.

## Catalog UI first-home readiness (SHOPPING-189)

Pinned CI `37040057456` passed Release, Fast **658/658**, and coverage, but
Acceptance passed **5/6**. `CatalogRefreshUITests.testSaveAndAddToListWorksForNewAndExistingCatalogItemsWithoutDuplicates`
stopped before its Catalog actions because a fresh isolated store showed the
approved Create a Home screen. The class's two raw fresh launches now use its
existing `launchApp` helper. That helper gives each test a unique store, uses
the isolated no-account provider, explicitly taps Create Home only when no
fixture was supplied, and waits for Groceries. The populated-fixture path and
all catalog save/add, duplicate, Recently added, navigation, and one-time
assertions remain unchanged. Focused catalog UI and exact-source pinned
Acceptance validation are pending.

### Native home scope layout (SHOPPING-190)

`PersonalCartUITests.testTabHeadersStayVisibleAndSettingsStartAtTop` owns visible,
top-aligned Groceries/Catalog/Settings titles, a short Settings list beginning in
the upper half, and title visibility after scrolling. It uses actual system Large
and accessibility XXXL sizes and restores the original setting before app/store
cleanup through ordered XCTest teardown blocks. Screenshots retain all three tabs
at both sizes. Only Groceries presents a home switch action. The existing
`testFirstHomeCreatesInOneTapAndRestoresAfterRelaunch` also checks the onboarding
title placement. Cross-home selection, private/saved carts, and relaunch remain
owned by `testSwitchExistingHomesPreservesOriginalGroceriesAfterRelaunch`; its
helper now returns through the native Groceries back stack before switching,
while the other tabs assert the same home through passive labels.

Initial candidate `31b98ed` passed native invitation cancellation, contributor
removal/cancel, and automatic accepted-invitation UI **3/3**, but two additional
UI scenarios failed: a switch helper assumed reselecting a tab reset its retained
cart navigation stack, and the new layout fixture omitted the active-home fixture
flag. Those setup assumptions were corrected without removing outcomes.
`f86ef6e` then passed both affected Catalog workflows, retained-home copy, and
cross-home/cart/relaunch **4/4**. The layout body passed all six normal/XXXL tab
screens and scrolling assertions, but failed its restoration guard because Swift
`defer` stopped the app before the text-size helper's XCTest teardown. Cleanup is
now registered first as a teardown block, so restoration executes while the app
and metadata are available. Failed runs remain at
`/tmp/shopping-phase24-190-layout-ui{,-b}.xcresult` and corresponding logs.
These are focused selections, not ShoppingFull attestation. Final candidate,
Fast, Watch identity, and pinned CI validation remain pending.

Final local candidate `155e7dd` passed ShoppingFast **663/663**, no skips;
header/onboarding/actual-size/restoration UI **2/2**, no skips; Watch duplicate-home
selection/reload **1/1**, no skips; and the four Catalog/copy/switch/cart/relaunch
UI scenarios **4/4**, no skips. Bundles/logs use prefixes
`shopping-phase24-190-final-fast`, `shopping-phase24-190-layout-ui-c`,
`shopping-phase24-188-watch-identity`, and `shopping-phase24-190-navigation-final`
under `/tmp`. All six Large/XXXL tab screenshots were inspected. No Thread
Performance Checker or runtime warning was reported in these runs.

The earlier `-b` run's simulator-diagnostic collection never finalized its bundle;
the post-test build process was stopped with exit 143 after its logged outcomes.
It is not a successful validation run. The final navigation run also waited in
simulator diagnostic collection after all four tests passed. A process sample
(`/tmp/shopping-phase24-190-result-writer-sample.txt`) identified
`XCTHProcessInvocation.simCtlDiagnose`. Stopping only that diagnostic child
allowed xcodebuild to close a readable 4/4 bundle and exit 0. The sample, completed
bundle and full log preserve this intervention. Pinned CI remains required; no
remote ShoppingFull was dispatched and no local Full attestation is claimed.


### SHOPPING-187 published roster readiness follow-up

Pinned CI `37050761193` on `21fb7d8` passed Release and coverage, but Fast
passed **661/663**, with no skips. The two copy-account-lookup ordering methods
failed only the immediate `homes.count == 2` assertion; copy completion, current
Account home, exclusion of copied-home selection and the pending invitation
assertions passed. Full result, logs and summaries are retained under
`/tmp/shopping-phase24-ci-failure-37050761193` and
`/tmp/shopping-phase24-ci-summary-37050761193`.

`testAcceptedInvitationDuringCopyAccountLookupCannotBeOverwrittenByLateCopyIntent`
and `testAccountInvalidationDuringCopyLookupDoesNotRearmOpenAfterSameAccountVerification`
remain the proof owners for newer navigation intent during held account lookup.
The owned conversion-consumer chain does not own a later startup/history
request that supersedes its discovery. These tests now separately observe the
actual published two-home roster within five seconds, as the ordinary explicit
copy test already observes published selection separately from copy completion.
All original copy, count, home-name, selection and invitation assertions remain;
there is no refresh retry, fixed delay, expected failure or assertion removal.
This test-only follow-up requires affected-suite validation and new exact-source
pinned CI. The UI source and installed candidate remain unchanged.


Committed test-only candidate `7cb2aa7` passed all **40/40** home-bootstrap
methods, with no skips and exit 0, on iPhone 17 Pro/iOS 26.5 using ShoppingFast
(`/tmp/shopping-phase24-187-roster-focused-b.xcresult`, `.log` and `-summary.json`).
Both held account-lookup methods passed. One internal QoS warning occurred in
`testDeletedRetainedSourceCanCreateAndCopyNewLocalHomeWithoutRewritingAdoption`,
an unchanged production path; no runtime warning was reported. The first
invocation used the wrong target name (`ShoppingTests` instead of
`ShoppingPersistenceTests`) and exited 70 before running tests; its raw log and
result path `/tmp/shopping-phase24-187-roster-focused` are retained. Independent
production and test reviews found no defect in the bounded readiness correction
or permanent stale-state risk. Exact pushed-source CI remains the final gate.


### SHOPPING-191 bootstrap publication readiness

Pinned CI `37052765701` on `c175e80` passed Release and coverage, but Fast was
**661/663**, with no skips; Acceptance was skipped. Both prior held copy-lookup
methods passed. The first-home fixture observed name `nil` and roster count 0
before committed creation published. The sharing-status fixture accepted the
old `.ready` presentation before the latest discovery applied renewal; only
the presentation UUID inequality failed. Complete evidence is retained under
`/tmp/shopping-phase24-ci-failure-37052765701` and
`/tmp/shopping-phase24-ci-summary-37052765701`.

`ActiveHomeBootstrapTests.testFreshAvailableAccountDiscoversBeforeOfferingAccountHomeCreation`
still owns discover-before-offer and explicit account-home creation. It reuses
`waitForPublishedHomes(count: 1)` before the unchanged name/count assertions.
`HomeSharingStatusBootstrapTests.testRenewedPresentationOfSameGraphDiscardsHeldRead`
still owns same-graph renewed authority and discarding the held `888` result.
The existing bounded `ready` helper now supports a predicate; this method awaits
the same scope, current and newer generation, and a different presentation ID
before its unchanged scope/UUID/stale-result assertions. An idempotent teardown
opens the held gate and drains its actual completion if readiness fails.
Neither method repeats a command or weakens any assertion. Independent source
review confirms superseded discovery intentionally returns before the winning
publication; no permanent stale-state defect was verified. This is test-only
readiness work, requiring affected-suite validation and exact-source pinned CI.


Committed test-only candidate `2255356` passed the two affected suites
**27/27**, with no skips and exit 0, on iPhone 17 Pro/iOS 26.5 using ShoppingFast
(`/tmp/shopping-phase24-191-focused.xcresult`, `.log` and `-summary.json`). Both
pinned-CI failures passed. One internal QoS warning occurred in unchanged
`testColdInvitationDoesNotCreateAnEmptyLocalHomeBeforeAccountSetup`; no runtime
warning was reported. Independent correctness and test reviews found no issues
in readiness predicates or bounded held-read teardown. App/Watch/UI source is
unchanged from polished candidate `21fb7d8`; exact successor CI remains required.


### iPhone store purchase-rule counts (SHOPPING-192)

`StorePurchaseCounts` owns the shared Watch/iPhone value projection: distinct
outstanding occurrences, active-store availability, archived restrictions and
unresolved identity handling. The existing `CatalogFilterUnitTests` suite adds
three focused checks without replacing Watch persistence coverage.

`CatalogFilterTests.testStoreCountsUseUnfilteredOutstandingOccurrencesAndExactHome`
owns the background iPhone projection across search/selection, legacy cart flags,
quantity, remembered/one-time demand, archived stores, unresolved identity and
a foreign home. `PersonalCartServiceTests.testGroceryStoreCountsExcludeOnlyMyCartAndFulfilledDemand`
owns private cart membership and fulfilled demand after personal-cart activation.

Two isolated `PersonalCartUITests` methods own native store selection, Settings
order, filter-independent counts and live personal-cart updates, plus readable
semantic count values and row geometry at actual system Large and accessibility
XXXL sizes. They retain screenshots; the text-size helper restores Settings.
All fixture stores are unique and removed after app termination. No coverage
baseline or CI test selection is changed. Exact-source validation follows below.

Initial candidate `9ac693e` passed focused projection/cart tests **64/64** and
the two store-picker UI methods **2/2**, with no skips. Raw artifacts are
`/tmp/shopping-phase25-192-focused` and `-ui` (`.log`, `.xcresult`). Review
identified an exposed mismatch for a mixed valid/incomplete store restriction:
the previous iPhone eligibility resolution accepted it while Watch failed closed.
The existing Watch relationship validation was extracted first into
`PurchaseRuleIdentity` (`78e66b9`), then applied to count rules only. The new
`testStoreCountsRejectMixedValidAndUnresolvedStoreRelationships` covers remembered
foreign-home restrictions and one-time incomplete imports, including Any store
overrides. Existing filtering behavior is preserved. The UI row helper now awaits
exactly one matching row before resolving it, and awaits the native title before
checking hittability; count-value assertions are unchanged. Final evidence follows.

Final behavior candidate `2cb589f` passed ShoppingFast **669/669**, no skips,
exit 0 (`/tmp/shopping-phase25-192-fast.xcresult`, `.log`, `-summary.json`).
The final picker-only contrast/separator successor `e8b03cd` passed both affected
Watch persistence count methods **2/2** on watchOS 26.5 and both focused iPhone
UI methods **2/2** on iPhone 18 Pro/iOS 27, no skips, exit 0. Artifacts:
`/tmp/shopping-phase25-192-watch` and `-ui-final` (`.xcresult`, `.log`,
`-summary.json`); screenshots and actual Settings text-size evidence are retained
in `-ui-final-attachments`. Inspected Large, accessibility XXXL and selected-store
after-cart screenshots: semantic colors, aligned separators, visible counts and
native checkmark are correct. Independent production and test reviewers verified
the resolution/readiness corrections and found no remaining defect. The final
integration changes only documentation from `e8b03cd`; exact pushed-source CI is
still required for oldest pinned compiler/runtime compatibility and coverage.


### Committed catalog name observation (SHOPPING-194)

Pinned CI `37061467701` on integration `991dea4` passed Release, Fast
**669/669** and the unchanged coverage baseline, but Acceptance was **5/6**,
with no skips. The unchanged catalog Save/Add workflow timed out at its exact
KVC-based text-value wait before keyboard dismissal. Raw results and video are
retained in `/tmp/shopping-phase25-ci-failure-37061467701`; summaries are in
`/tmp/shopping-phase25-ci-summary-37061467701`. Extracted frame
`/tmp/shopping-phase25-ci-name-failure.png` visibly shows the full requested name.
Activity evidence contains one property lookup during that predicate; stale
observation is plausible, but the actual AX value was not captured.

The catalog UI helper first gained explicit ownership of its unique fixture
directory and termination-before-removal teardown. The workflow types once,
commits editing through the existing native keyboard Done action, waits for
keyboard disappearance, then polls a fresh field query with the same exact value
and three-second bound. The separate exact-name, destination editor and one-need
assertions remain. A failed wait now retains the accessibility hierarchy. No
command retry, relaunch, timeout inflation, skip or acceptance selection change
is introduced. This is test-only; app and Watch source stay at `e8b03cd`.

Independent challenger review caught a fixture fallback collision introduced by
the new catalog helper's constant SQLite basename. `uiTestStoreURL` maps
non-writable runner paths into app Application Support using the basename only.
The helper now preserves its unique directory identity in that filename too.
The new count test's explicit fixture and shared PersonalCart UI launch helper
use the same unique-basename rule. This prevents app-side fallback stores from
sharing state while preserving each test's deliberate relaunch path. Existing
bootstrap fallback tests own the path mapping; affected catalog/count workflows
will validate the correction.

Candidate `ecd11e3` passed all five affected catalog UI workflows **5/5**.
The final fixture successor `8ce6809` passed the corrected catalog workflow,
both count workflows (actual Large/XXXL and cart refresh), and first-home
creation/relaunch **4/4**, no skips, on iPhone 18 Pro/iOS27. Raw bundles/logs and
summaries: `/tmp/shopping-phase25-194-ui` and `-ui-final`. Both runs completed
all test assertions before Xcode27's diagnostics child stalled. Samples retained
under `/tmp/shopping-phase25-194-*-sample.txt` show the parent waiting in
`collectSimulatorDiagnostics` / `simCtlDiagnose` and the child waiting for its
diagnostic subprocess/group. Only each stalled `simctl diagnose` child was
terminated; complete bundles and xcodebuild exit0 were preserved. No test or
runner process was stopped. Independent correctness and test reviews verified
exact-value proof, unique fallback filenames and stable relaunch paths. Hosted
pinned iOS18.5 acceptance remains required on the exact integration successor.


## Home picker placement in Settings

The picker now belongs to Settings; this supersedes the Groceries-only placement
recorded in the historical SHOPPING-190 evidence above. Its existing
`HomeSelectionView` and root-level onboarding/invitation presentation are unchanged.

- `PersonalCartUITests.testSettingsHomePickerDismissalKeepsSelectedHomeAndGroceries`
  owns the new interaction boundary: a single-home fixture has no switcher on
  Groceries or Catalog, opens Homes from Settings, dismisses and reopens it twice,
  remains on Settings with the same selected home, and returns to the unchanged
  grocery occurrence identities. The fixture supplies a selected home, not a
  completed dismissal or switching outcome.
- `testTabHeadersStayVisibleAndSettingsStartAtTop` retains native title, Settings
  placement, scrolling, actual Large/XXXL system-size and screenshot proof, and
  now asserts Settings is the only tab with an actionable home picker.
- `testSwitchExistingHomesPreservesOriginalGroceriesAfterRelaunch` retains
  cross-home selection, groceries, private/saved carts and selected-home relaunch
  proof. The helper now uses the Settings back stack. Groceries, Catalog and
  carts assert their home context is read-only; Settings checks its active picker.
- `testFirstHomeCreatesInOneTapAndRestoresAfterRelaunch`,
  `testLocalHomeDeleteCanCancelThenRecreateAfterRelaunch`,
  `testAcceptedInvitationOpensExactHomeWithoutAppJoinTap`,
  `testLocalHomeRemainsAvailableInHomesPicker`,
  `testRetainedLocalUseICloudCopiesHomeAndKeepsSourceSelectable`, and
  `HomeDetailsUITests.testOwnerDeleteRequiresExactHomeConfirmationAndCanRecreateAfterRelaunch`
  retain their creation, invitation, retained-local, deletion and recovery
  boundaries. Selected-home checks and picker entry use Settings; the accepted
  invitation still proves automatic opening through passive Groceries context.

The new UI method belongs to ShoppingFull's existing whole-target selection.
ShoppingAcceptance's six-method selection is unchanged. Simulator execution of
these updated UI workflows remains required; static inspection is not UI proof.

## 1.5.0 release CI recovery

Feature merge CI `37128993131` failed the retained-copy access-refresh generation assertion; its tree matched the passing feature PR. The test's task-local access override applied to one asynchronous discovery, while a newer automatic history discovery could supersede that request. The fixture now treats the simulated restriction as source state until its held copy discovery is released, so newer refreshes observe the same access. The test waits boundedly for publication and retains the generation-change, unchanged choice revision, Account home, and final copied Original home assertions; it also asserts the published restricted access. Production request fences are unchanged.

Version PR CI `37129034743` passed Fast 672/672, coverage and Release SDK, but Catalog Save and add failed the View tap. Its result activities place the save event at 14:28:42.147 and View lookup at 14:28:46.252, already beyond the three-second success window. The recording shows Added 1 and View during editor dismissal before expiry. Actionable feedback now uses at least the existing ten-second Undo window, giving a person time to read and act while preserving automatic dismissal. Plain success and attention notices retain their existing durations. `AppPresentationTests.testSuccessActionHasTimeToReadAndNavigateBeforeAutomaticDismissal` owns the action's scheduled deadline and navigation/dismissal; the existing test owns normal expiry and unsuccessful-action retention. The Catalog UI method is unchanged and still owns Added 1, View navigation, exact Oat milk editor content, and both duplicate checks. There are no test-only timers, retries, removed assertions or selection/coverage changes. Focused local and exact-head CI results belong in release PR #74 and the release receipt.


## Build 29 sharing recovery (SHOPPING-196)

`HomeShareGraphTests.testReplicatedEventIdentityDoesNotPreventSharingOrDiscardEvidence`
owns the observed preflight blocker: equal logical event replicas remain in the
physical share graph, decode to one semantic event, and conflicting payloads still
fail the domain reader. Existing duplicate-domain-identity, foreign-home and
private-graph tests retain their rejection boundaries. No stored device records
or identifiers are included in fixtures.

`HomeDetailsModelTests` owns local recovery before an unavailable server read,
preparation-state restoration, truthful structural/CloudKit/Cocoa errors, and
retry eligibility. `HomeMembershipCoordinatorTests` owns accepted/removed intent
retirement and preserving the original definitely-not-submitted CloudKit cause
with the same retry identity. `HomeInvitationInboxTests` owns fresh Open intent
for a previously accepted link, persistence and deferral without reacceptance;
the renewed-grant test still requires native acceptance and an explicit choice.

The new `HomeDetailsUITests` failure workflow injects only an operation failure
through the existing isolated DEBUG fixture. It drives Invite and verifies the
specific inline error, no invented pending invitation or cloud warning, and a
second explicit attempt. Existing native share-sheet cancellation, cancellation
of a pending grant, and automatic accepted-home opening own delivery/navigation.
The acceptance plan, fixtures, timeouts, coverage baseline and retry policy are
unchanged.

Validation on Xcode 27 / iPhone 17 Pro / iOS 26.5: focused persistence selection
passed 66/66; final Fast passed 680/680 (645 XCTest + 35 Swift Testing), no skips.
Results are `/tmp/shopping-196-focused-c.xcresult` and
`/tmp/shopping-196-fast-final.xcresult`, with corresponding logs. The first focused
invocation selected the wrong target and stopped before building. The corrected
selection exposed the old inbox assertion that reopening an accepted link had no
Open intent; it was changed to assert the intended fresh intent, preserving all
renewed-grant acceptance assertions. That failure is retained in
`/tmp/shopping-196-focused-b.xcresult`. Existing Core Data multi-model warnings and
AppIntents extraction notices remain; no warning was suppressed.

All four selected native UI workflows passed, no skips, in
`/tmp/shopping-196-ui-a.xcresult` (80.9 seconds test execution, 97.9 seconds Xcode
reported testing duration). This is a focused selection, not Full attestation.
Two independent read-only correctness reviewers found no confirmed defects,
including the final error-cause and preparation-recovery changes. Exact-source
pinned CI and signed-device invitation creation remain separate checks.

## Cloud application contracts (SHOPPING-198/199/200)

The [cloud application testing model](cloud-application-testing.md) separates
unit contracts, mock semantics and cross-boundary application evidence. New
stateful service doubles replace external observations and writes while the real
SQLite stores, validators, transports, coordinators, journals and presentation
rules remain in the execution path. Tests do not require a live iCloud account.

| Owner | Retained proof |
| --- | --- |
| `HomeSharingBackendContractTests` | Expected-version writes, membership lifecycle, offline behavior, lost completion and duplicate-create rejection in the sharing fake. |
| `HomeSharingApplicationContractTests` | Invite across equivalent physical event replicas; graph/private-record rejection; validation at the submission boundary; durable offline preparation, pending links and uncertain create/save recovery; accepted membership; account, authority and permission changes. |
| `HomeAdoptionBootstrapTests.testReopenedAcceptedInvitationAfterRelaunchHonorsNewerChoiceThenOpensWithoutAcceptance` | Reopened accepted ingress renews Open after cold reconstruction, respects a newer home choice, later activates without accepting again, and preserves both homes and the original private cart. |
| `PersonalCartReducerContractTests` | Transitive ancestry rejection, account/scope isolation and restore evidence input/output contracts. |
| `ReplicaApplicationContractTests` | Independent SQLite replicas, out-of-order and repeated delivery, conflicting physical payloads, checkout/undo, urgency, archived restrictions and private-cart isolation. |
| `AccountCloudApplicationContractTests` | Latest-refresh authority, durable cache namespaces, sign-out/account-switch command authorization, persisted permission restoration and independent local-write/import/export status. |

No existing test, acceptance selection, coverage baseline, retry rule or skip
policy was removed or weakened. Focused source identities and all implementation
failures are retained in the issue evidence records under `docs/testing/`.
Restoring the pre-fix blanket duplicate-event-ID rejection made the real Invite
integration regression fail; restoring the fix made the same test pass. The
negative run is deliberate mutation evidence, not an expected-failure test in
the maintained suite.

Integrated clean source `81a7b0a8c62ab55a1da097ceb5f452da0f2714af` passed
**715/715 Fast tests** (677 XCTest and 38 Swift Testing), with no failures or
skips, on Xcode 27.0 (27A266a), iPhone 17 Pro iOS 26.5, serial execution.
`/tmp/shopping-phase27-fast-source.json` records the empty dirty state;
`/tmp/shopping-phase27-fast.xcresult`, `.log`, `-phases.jsonl` and `-report.json`
retain execution and per-test evidence. Core Data multiple-model warnings remain
visible; this is not a warning-free claim.

The affected UI selection is Home Details' truthful Invite failure, successful
Invite/cancel with retained groceries, direct-share cancellation/resend, and
interactive cloud toolbar during refresh/return. Its exact source and artifacts
use the corresponding `/tmp/shopping-phase27-ui-*` metadata/report paths and
`/tmp/shopping-phase27-ui.xcresult` / `.log`. Final UI and hosted CI receipts are
recorded in [PR 78](https://github.com/mggarofalo/Shopping/pull/78). Hosted CI
retains the independent Fast coverage gate and six routine acceptance workflows.
Two independent production reviewers and an independent test reviewer checked
the final implementation and target registration. The behavior-bearing source
matches the focused review; this ledger follow-up changes documentation only.

A subsequent compiler-log audit found new fixture capture warnings.
`f58e8ba` captures store identity as a value and captures writer/view contexts on
the fixture's actor before resetting them on their queues. Independent test
review found no lifetime or contract change. All 16 sharing contracts passed on
that clean source (`/tmp/shopping-phase27-fixture-source.json`, `.xcresult` and
`.log`); the new capture warnings are absent. Application source is unchanged
from the 715-test/four-UI-workflow candidate above. Final Fast and hosted receipts
for this test-only follow-up are recorded in PR 78.


## Phase 28 — named Home invitations (SHOPPING-202…205)

`HomeDetailsModelTests` owns independent command/refresh progress, stale-read
suppression, coalescing, retained authority during ordinary refresh failures, and
blocked-writer responsiveness. `HomeNamedInvitationsModelTests` owns private
record loading, scope retirement, draft recovery, normalized-name reuse, and
share-sheet callbacks racing another command or a local load.

`HomeNamedInvitationTests` owns durable preparation before capability submission,
link reuse, uncertain binding recovery, legacy naming, individual cancellation of
concurrent links, draft removal, and accepted/cancelled history projection.
`HomeSharingApplicationContractTests` exercises the managed named-action factory
against the stateful sharing backend, SQLite reopen, owner-local share association,
and cached-account history without granting cached membership authority.

`HomeDetailsUITests` retains all ten existing workflows. Invitation workflows now
name the invitation, inspect its detail, retry a real injected failure, dismiss the
native share sheet repeatedly, reuse a normalized name, and verify the same record
after relaunch. Cancellation still asserts exact grocery identity preservation.
The fixture persists value-only events in its test-owned store directory; it never
contacts a recipient. Delete/leave, contributor removal, large text, rename, and
sharing-status navigation assertions remain in place.

These are simulator and stateful backend tests. SHOPPING-205 separately owns real
owner-device synchronization, recipient acceptance, VoiceOver and physical
Animation Hitches evidence. No simulator timing establishes that device gate.

## SHOPPING-212: Quiet Home Settings presentation

The former cloud-toolbar delayed-refresh workflow now proves the custom home
title, absence of a background spinner and elapsed-check timer, explicit Sharing
details navigation during the suspended read, and eventual member presentation.
Contributor rename still proves the updated title and persistence after relaunch;
restricted-access and native Dynamic Type coverage remain. HomeSharingStatusUITests
uses the labeled details row. Local-home settings tests retain their separate screen.
