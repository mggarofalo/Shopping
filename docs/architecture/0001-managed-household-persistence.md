# ADR 0001: Managed household persistence

- Date: 2026-09-05
- Issue: [SHOPPING-27](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/work-items/5e924f74-ae8e-49b0-ab02-1653ffa7ecbb)
- Status: Selected for local implementation; live sharing validation remains required in SHOPPING-30.

## Decision and scope

Use SwiftUI, Core Data, and `NSPersistentCloudKitContainer` for the shared MVP. The app reads and writes a local SQLite store; Apple's mirroring implementation transports changes. Cross-account household sharing is required for release. We will not build a `CKSyncEngine` adapter or a second transport for the MVP. Pull-to-refresh remains an exploration in SHOPPING-31.

SHOPPING-27 supplies an experimental local persistence harness and context simulations. It does not enable cloud entitlements or provide a shopping UI. Local tests run without an Apple Developer membership or iCloud account. They establish app-side behavior, not CloudKit scheduling, record conflict resolution, or share acceptance.

## Household graph and identity

One household owns stores, reusable catalog items, and one logical grocery list. Need rows belong to that list. A remembered need references a catalog item; a one-time need stores its own title without creating a catalog item. Recovery records also belong to the household. The whole graph is intended to live in one share. Never relate objects across households, persistent stores, or shares.

Each object has an immutable application UUID assigned when inserted. Names are display values, not identity. An `NSManagedObjectID` identifies a local stored object; it is not a portable replica ID or a CloudKit record ID. Core Data owns its mirrored record identifiers.

Catalog purchase tags mean where this household chooses to buy. The production model will retain reusable category, tags, and general notes on the catalog, with quantity, carted state and Normal/Urgent on the current need. Re-add does not remember urgency. One-time data must never enter hints or learned defaults without explicit Remember. Events are out of scope.

The prototype uses a programmatic model to keep the experiment small. Attributes have defaults or are optional; relationships are optional, unordered, and have inverses. There are no uniqueness constraints or Deny delete rules. Commands enforce local invariants, while imported incomplete graphs must be handled as incomplete rather than force-unwrapped. These choices follow [Apple's CloudKit model restrictions](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit); actual mirroring validation remains a separate gate.

## Private and shared store routing

The live container will load two separate SQLite store descriptions using the same model and CloudKit container identifier, with `.private` and `.shared` database scopes. These are roles on a device, not two copies of the same list: the owner's household remains in their private store, and an invited participant sees that household through their shared store. Both may be fetched through the same container, but all commands must resolve the selected household and its store explicitly.

The owner saves the household graph to the private store, then uses `share(_:to:completion:)` to associate it with a `CKShare` and the system invitation UI. The participant accepts invitation metadata with `acceptShareInvitations(from:into:completion:)` into the shared store. Invitation acceptance and arrival of the household graph are separate stages; the UI must wait for the imported household rather than create a replacement list.

Core Data uses zone sharing and can infer the zone of related objects. An owner adding previously unshared objects can associate them with an existing share using `share(_:to:completion:)`. A participant must create data in the household's shared store and related graph, not a new private household. Participant zone assignment from these relationships is an intended route, not a result established by this prototype; it requires the explicit post-invitation creation tests below. Do not assume the participant can invoke the owner's share-creation route. [Apple's sharing walkthrough](https://developer.apple.com/videos/play/wwdc2021/10015/) describes store roles, invitation acceptance, relationship inference, and existing-share association.

Sharing permissions must gate writes. A revoked or read-only share is not writable merely because its local objects still exist. Share metadata is fetched through the persistent container and the supported sharing APIs. Never edit the managed `CKRecord` payloads directly. Sharing a connected object traverses its graph, so catalogs and stores must be household-owned; a global cross-household catalog would violate this boundary. [Apple's sample](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users) documents graph movement, cross-share restrictions, and share lifecycle.

## Local commands and UI updates

All production mutations will pass through one serialized local command boundary. Views submit application IDs and intended edits instead of saving arbitrary managed objects. A command resolves current rows inside its context queue, validates household/store membership, applies the edit, and saves atomically or rolls back. The prototype exposes raw second contexts only to exercise competing saves.

Enable persistent history and remote-change notifications on each SQLite store. The read context merges completed local writes. The live implementation will serialize history consumption on launch, foreground entry and remote-change notifications; fetch transactions after a token scoped to that store; merge object-ID notifications into the view context on its queue; and persist the token only after successful consumption. A missing or expired token triggers a safe refetch/replay, never deletion of grocery data. Share metadata changes need a separate refresh because they need not produce object-history transactions.

History tokens are local bookkeeping, not sync acknowledgements. Do not purge history merely because the UI consumed it: mirroring may still need it. A production retention policy must account for successful exports and every local consumer. [Apple's history guidance](https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes) explains transaction consumption; [the sharing sample](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users) additionally covers per-store tokens, share metadata, and export-aware cleanup.

## Conflict policy and safety boundary

Managed mirroring's last-writer-wins behavior is the cloud conflict baseline. A local context's merge policy only resolves its Core Data save conflicts; it does not configure CloudKit. An `updatedAt` value is diagnostic, not enforcement of a global chronology. Offline clocks and delivery order mean we cannot promise that the last wall-clock tap wins. [Apple's collaboration discussion](https://developer.apple.com/videos/play/wwdc2019/202/?time=912) describes managed LWW and the role of modeling independently edited data.

Start with simple scalar need fields and test property-level context conflicts. Passing that test is not evidence that cloud mirroring merges disjoint fields identically. SHOPPING-30 must exercise same-field and disjoint quantity/carted edits in both delivery orders. Split independently edited state into related records only if that evidence requires it, before production schema promotion; do not add a speculative event log or custom merge engine here.

Clearing is an archive operation, never a hard delete or a fresh broad query. Capture the list scope and exact occurrence IDs/revisions before confirmation. On confirmation, refetch those same rows, skip anything changed or no longer carted, and persist recovery information in the same save. A retry must revalidate the captured set, not add newly carted rows. The eventual UI must show the captured count/scope and report skipped rows. There is no Delete all action.

Recovery must survive relaunch and preserve both catalog knowledge and later edits. Undo applies only to the same archived occurrence and matching operation/revision; it must not overwrite an uncart, re-add, later archive, or already active remembered occurrence. Recently cleared needs remain stored, including one-time rows. No automatic purge policy is introduced by this prototype.

A local revision check cannot observe a second phone's unsynced edit or act as a CloudKit compare-and-swap. Therefore, context simulations establish safe handling of changes already visible locally. The shared release must additionally prove clear-versus-uncart/re-add convergence on two accounts. If managed LWW on the selected schema cannot preserve the required newer occurrence, revise the lifecycle representation before release. Recovery is still required even after those tests pass.

## Duplicates and incomplete imports

The normal local add command reuses an existing active need for a catalog item, explicitly returning carted demand to needed and resetting urgency to Normal unless requested. Read-only focus does not change its values. Independent offline adds can still create duplicate rows because CloudKit does not provide the model's uniqueness constraint. The production reconciliation key is household/list plus catalog item ID, never title; one-time needs remain independent even when their titles match.

For independently created active needs with the same reconciliation key, the proposed canonical row is the one with the lexicographically smallest UUID. Preserve other occurrences and their values for recovery/reconciliation; never silently sum quantities. A live import handler must apply this choice consistently and respect write permission. SHOPPING-21 prevents duplicates in serialized ordinary adds, prevents undo from creating a second active remembered need, and exposes already imported duplicate candidates with their IDs, revisions and values. A command encountering several active candidates rejects the ambiguous add without mutating them. It does not implement an import deduplicator or silently apply the proposed canonical choice. A future resolver must preserve divergent source values for recovery and pass the live gate before automatically retiring any candidate. Do not merge catalog items or stores merely because their display names match. Cross-account import reconciliation, interrupted relationships and account/share changes remain required live integration work; local uniqueness must not be advertised as distributed uniqueness.

## Schema and migration policy

The harness uses a disposable experimental schema and isolated temporary SQLite stores. It is not installed as the app's production database and must not accumulate real grocery data. Before model work ships, capture the initial model as a versioned production schema and preserve every released model version needed for migration.

Use explicit migration tests against saved store fixtures. Compatible additive changes may use inferred lightweight migration; incompatible changes require a planned mapping or staged migration. A load or migration failure must surface an actionable error and preserve the original store, never fall back to deleting/recreating it.

Live development schema initialization is an explicit developer/test action after model changes, not a normal launch path. Inspect the generated schema and deploy it before TestFlight. Production CloudKit evolution is additive: retain old fields/types and support older clients deliberately. No reset or promotion is part of SHOPPING-27. [Apple's schema guidance](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit) describes these constraints.

## Evidence and remaining gate

The shared `Shopping` scheme includes `ShoppingPersistenceTests` alongside the existing UI launch test. `PersistenceController` uses `NSPersistentContainer` with cloud options absent for this experiment; the live container substitution and both database scopes are not enabled. Each command uses a private writer context with `NSErrorMergePolicy`, resets its cache before reading, saves once, and rolls back on error. A save conflict fails the command rather than overriding the revision check. There is no automatic command retry.

`NeedService` returns IDs/value tokens across the context boundary. Its clear token contains household ID, list ID, an operation UUID, and the captured need revisions. `ClearOperation` persists the encoded token; repeating its ID is a no-op. Undo restores the previous carted occurrence only when archive ownership and revision still match. Editing an archived row is rejected; re-adding a remembered item creates a new occurrence if the previous one is archived. Explicit same-value edits advance the local revision. These counters are local guards, not distributed clocks.

The SQLite simulations stage both contexts' edits before either saves, disable automatic merging in those simulation contexts, and keep their registered objects alive. The resulting local observations are:

| Case | Observed / required local result |
|---|---|
| Explicit same-value carted command | Advances the need revision. |
| Competing quantity edits | The later property-object-trump context save wins. |
| Disjoint quantity and carted edits | Both survive in either save order. |
| Independent store-tag additions | Core Data merges the to-many additions as a union; this is not whole-set LWW. |
| Clear after an external-context edit | Changed captured rows are skipped; newly carted rows outside the token survive. |
| Repeated clear token | Does not archive another set or create another operation. |
| SQLite close/reopen and undo | Restores one-time data without catalog creation. |
| Re-add after clear, then undo | Keeps the replacement active and declines to restore a duplicate. |
| Normal remembered add | Reuses the active occurrence; one-time adds do not seed the catalog. |
| Invalid command scope / quantity | Rejects cross-household links; SHOPPING-21 completes the quantity range of 1–99. |

Local validation on 2026-09-05 passed all 9 persistence tests and the existing UI launch test on Xcode 26.6 / iOS 26.5. The test log confirmed Core Data multithreading assertions were enabled. The same shared scheme runs in CI on the pinned Xcode 16.4 / iOS 18.5 configuration.

The tag-union observation is a reason to test tag removals and competing purchase-rule edits explicitly in SHOPPING-30. It does not change the product's requested conflict baseline. No local test establishes the cloud's whole-tag-set behavior. Retain this distinction when building production tags.

SHOPPING-30 requires Developer enrollment and two different iCloud accounts, with final evidence on the two physical iPhones. Test initial invitation, participant permissions, owner and participant additions after sharing, relaunch, offline edits and reconnection, same-field/disjoint-field conflicts, tag changes, duplicate adds, incomplete imports, one-time recovery, and clear-versus-uncart/re-add. Record versions, action order, observed convergence, and failures.

A few seconds of healthy foreground convergence is desirable, not a deadline the managed API guarantees. Apple controls synchronization timing and exposes no force-sync scheduling API; delayed sync is accepted and pull-to-refresh remains deferred. [TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer) describes managed synchronization constraints. Local tests and simulator screenshots do not substitute for the live gate.
