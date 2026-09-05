# Application persistence

The app uses a local SQLite database as its working copy. The normal development launch creates an empty household grocery list and no sample groceries. Preview fixtures use isolated stores. A disk or model-loading error stays visible with a retry action; the app never replaces a failed store with an empty database or an in-memory fallback.

## Schema and stored data

`Shopping.xcdatamodeld` preserves the initial production model as `ShoppingV1.xcdatamodel`. Managed classes remain handwritten. Attributes have defaults or are optional, relationships are optional and unordered with inverses, and delete rules preserve grocery data. UUID IDs are optional in storage because native Core Data does not supply UUID defaults. A custom managed-object accessor returns the existing invalid-ID sentinel when the primitive value is absent; reading an incomplete import never creates or persists an identity. Local creation assigns a fresh UUID, and commands reject invalid or ambiguous occurrence IDs. Catalog and store projections omit incomplete identities until they arrive; a placeholder store cannot make a grocery eligible at a shopping destination. Application commands validate the stronger household, purchase-rule and occurrence-identity requirements. The binary clear snapshot is optional because its payload may arrive after the operation; undo reports missing recovery data and leaves groceries unchanged until it is available.

The saved V1 SQLite fixture is a baseline for compatibility and future migration tests. V1 is the first production schema, so there is no prior released version to migrate. When a later model is introduced, retain V1 and prove migration using this fixture before shipping. A model version label alone is not evidence of migration, and a failed migration must preserve the original store.

## Local and managed configurations

Local configuration omits CloudKit options and supports development without enrollment. Managed configuration uses `NSPersistentCloudKitContainer` with separate owner-private and participant-shared SQLite stores under one CloudKit container identifier. The same command service resolves an existing household's actual persistent store for its children. A new owner's household belongs in the private store; an invited household must wait for shared import rather than create a substitute household.

The managed permission policy checks whether the destination store permits inserts and whether existing records permit updates or deletion. A local cached object is not evidence that a revoked or read-only share remains writable. Commands validate changes before saving and roll back on failure.

Owner-side share association uses the supported existing-share API. Pending association is local bookkeeping, staged before the domain save and retried across interruption. Acknowledgement removes only the completed captured IDs, preserving groceries queued concurrently. Objects already in the intended share are handled idempotently. Association completion does not acknowledge cloud export. Participant-created children stay in the shared persistent store and related household graph. Actual participant zone assignment, owner additions after invitation, permissions and convergence still require [SHOPPING-30](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/work-items/0d073ba9-ea40-4a49-b766-e19b12c354dc).

## Changes, history and recovery

Local command saves merge into the view context. The persistent-history consumer handles launch, foreground and remote-change triggers, consuming transactions separately for each persistent store. It merges on the view context's queue before advancing the stored checkpoint. Failed processing retains a replayable checkpoint; missing or invalid checkpoints lead to replay or refetch, never grocery deletion. History is not purged merely because the UI has consumed it.

Share metadata is separate from object history and needs its own permission/share refresh. A history token is a local checkpoint, not a server synchronization acknowledgement. There is no pull-to-refresh control or promise to force CloudKit scheduling.

Clear recovery remains part of the stored household graph. Reopening SQLite retains exact occurrence IDs, quantity, notes, urgency, one-time details, archive ownership and clear tokens. Neither history replay nor a failed store load can promote one-time groceries into the catalog.

The ID accessor follows Apple’s [custom managed-object storage access guidance](https://developer.apple.com/documentation/coredata/nsmanagedobject/primitivevalue(forkey:)).

See [ADR 0001](architecture/0001-managed-household-persistence.md) for the architecture and live validation boundary. The store roles, permission APIs and per-store history design follow [Apple's sharing sample](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users); model evolution follows [Apple's migration guidance](https://developer.apple.com/documentation/coredata/migrating-your-data-model-automatically).
