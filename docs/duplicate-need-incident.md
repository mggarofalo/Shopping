# SHOPPING-244: duplicate grocery occurrence

## Observed incident and recovery

On October 23, 2026, an iPhone 16 Pro running iOS 27.0 and Milk & Bananas
1.6.3 (39) reported `Shopping.NeedServiceError error 14`. The compiled Swift
error mapping identifies this as `invalidOccurrenceIdentity`.

The captured private store passed SQLite integrity checks. Its persistent
history established this sequence (UTC):

| Time | Transaction | Result |
| --- | --- | --- |
| 17:14:34.797 | `app.commands` | Pasta inserted normally. |
| 17:14:43.089 | `app.commands` | Tortilla Chips inserted. |
| 17:14:51.260 | `NSCloudKitMirroringDelegate.import` | A second physical Tortilla Chips record inserted with the same occurrence UUID. |
| 17:14:51.280 | `NSCloudKitMirroringDelegate.import` | Imported record updated. |

Both copies had identical persisted attributes and relationships, including
list, catalog item, quantity, revision, cart flags and recovery ID. Native
metadata assigned distinct CloudKit record names in the same share zone.
Decoded CKRecord creation timestamps were 17:14:43 and 17:14:44. This proves
duplicate physical cloud records, not two independently generated occurrence IDs.
It does **not** identify which native export/share operation created the second
cloud record. No claim of a reproduced CloudKit transport race is made.

The user authorized repair before implementation. With the app stopped, a fresh
account-store backup was retained. A standalone Core Data tool checked model
compatibility and exact equality, deleted only the imported duplicate, and
saved with persistent history enabled. Occurrence identity, other domain rows,
catalog, private cart records and recovery history were preserved. The restored
SQLite/WAL/SHM files were verified byte-for-byte before reopening the app. The
user confirmed normal grocery loading twice. Private backups and the repair
tool are in the ignored local `output/diagnostics/shopping-244/` directory;
household data is not committed.

## Application root cause and reproduction

`PersistentHistoryConsumer` merged imported physical records without reconciling
duplicate occurrence identities. `NeedService.groceryNeedProjection` correctly
rejected duplicate UUIDs; `GroceriesView.refreshProjection` responded by clearing
the entire visible list. Thus one duplicated record made unrelated groceries
unavailable. Mutation identity guards must remain strict.

`ImportedNeedReconciliationTests` uses independent, lifetime-owned SQLite stores.
It creates a normal remembered need, then saves an exact physical copy in a
separate context under the import author. Stable synthetic CloudKit record IDs
are supplied at the native identity boundary. Both local physical-record orders
are exercised; local object IDs must not determine the survivor.

Before enabling reconciliation, the regression failed with
`invalidOccurrenceIdentity`, retained two records, and still failed after reopen.
The result is retained at `/tmp/shopping-244-red.xcresult`. This reproduces the
application failure from the observed imported state, not Apple's transport.

## Repair policy

Physical reconciliation is isolated from grocery policy in
`ImportedNeedReconciler`, called on the serial writer before history is merged
and checkpointed. Production requires owner-private native record identities;
local and participant stores do not acquire deletion authority through this path.

Only identical valid occurrences in one persistent store and one cloud zone are
candidates. Every persisted attribute and relationship participates in equality.
Distinct cloud record names determine a consistent survivor on all replicas.
Different values, missing identities, unknown lifecycle, unresolved list/item
scope, or different zones remain untouched. This does not merge separate requests
for the same catalog item.

Deletion waits until successful completed import **and** export cycles started later
than each copy's last retained Need transaction. Missing history, missing events,
in-progress operations and failed operations defer cleanup. The records are
re-fetched and compared when retrying. This protects a relationship arriving
after its owning row; the split-import regression retains a later assignment.
Startup, subsequent history passes, and successful sync-completion notifications
retry pending cleanup, including duplicates checkpointed
by earlier builds. A later successful sync cycle may be necessary before repair.

Normal save authority and permissions still apply. Write denial rolls back
cleanup while allowing ordinary history merging/checkpointing to continue.
Account changes and detached stores abort the stale operation. No schema change,
cloud record rewrite, or uniqueness constraint is introduced.

Apple's [sharing sample](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
requires consistent replica selection and delayed deletion to allow relationship
synchronization. The application tests do not establish the outcome of an
unseen offline edit racing a native cloud deletion; live multi-device validation
remains necessary. Collecting device unified logs required administrator access
unavailable to this session, so the exact native record-creation mechanism remains
an explicit investigation boundary tracked in SHOPPING-248.

## Validation

- Red regression: observed duplicate import fails grocery projection and relaunch.
- Initial focused selection: 48 tests passed across reconciliation, grocery needs,
  persistence-container and replica-contract suites.
- Reviewed boundary selection: nine reconciliation tests passed, including cart
  preservation, conflicts, cloud identity/zone guards, denied cleanup retry,
  account changes, delayed relationship import, completed-cycle selection and
  completion during a held reconciliation pass. Checkout and restore preserve
  the original occurrence after repair.
- One intermediate test attempt failed before test execution because SpringBoard
  rejected launch as busy. After explicitly booting the documented simulator,
  the selected tests passed with parallel testing disabled. Both results remain.
- Fast on a dedicated iPhone 17 Pro / iOS 26.5 simulator with Xcode 27.1:
  810 passed, zero failed, six expected iOS-27-only capability skips. Raw coverage
  reports 53.04% app line coverage; this newly installed toolchain has no configured
  baseline, so the pinned CI coverage gate remains authoritative.
- Two independent adversarial reviewers confirmed all reported findings resolved.
- The local Catalog Save and Add UI workflow failed before saving: its keyboard
  Done button produced hit point {-1, -1}, and the keyboard remained visible.
  Base comparison and pinned CI evidence are recorded with the PR.
