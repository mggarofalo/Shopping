# Managed home-share provisioning

SHOPPING-125 implements the local provisioning boundary selected by ADR 0003.
It does not establish live sharing, invite acceptance or peer receipt.

## Explicit creation

`HomeCreationJournal` saves an account/store-bound command, operation UUID,
household/list UUIDs and name before a household write. `NeedService` commits both
objects atomically. A retry resolves those same identities; partial, foreign or
ambiguous matches fail without creating replacements. A later rename is retained.
The UI acknowledges the command only after receiving its result, holds submission
through acknowledgment, and passes the captured command identity when resuming.
A stale Resume action cannot become a new creation command.

## Initial share and reuse

`PersistenceBootstrap.prepareSelectedHomeShare` captures the selected scope and
presentation authority. A single `HomeShareProvisioner` survives selection changes
within that bootstrap, keeping overlapping requests for the same full scope behind
one native callback. Cancelling a waiter never starts another native request.

`ManagedHomeShareTransport` requires the authenticated account/container/environment,
exact private store and permanent root URI, household/list UUIDs, and owner metadata.
It traverses the complete relationship graph, including archived restrictions,
one-time needs and shared demand/purchase/restore/presence records. Private cart and
legacy review records remain relationship-free; known private share associations
also fail the preflight. Cross-home/store references, ambiguous identities and
unexpected public access fail closed. Managed objects remain on their context queue.

An existing share is reused. Otherwise the provisioning journal records uncertainty
before `NSPersistentCloudKitContainer.share` is called with the original saved root.
The returned private share is persisted through `persistUpdatedShare`. Existing
association journals continue routing later owner insertions to that share;
participant insertions retain the household's actual shared-store routing.

## Uncertain recovery

The journal retains the original operation and full scope across failures/relaunch.
A positive root association records the share's complete record/zone identity.
Once known, disappearance or mismatch never authorizes a replacement share.

After a failed callback, reconcile once. If still unresolved, retain the intent and
require explicit **Retry preparing sharing**. After process restart or a terminal
callback, that retry invokes managed sharing on the same saved root. It relies on
Core Data's documented refusal to share an already-shared graph; an empty local
lookup is not proof that the earlier operation did nothing. There is no automatic
retry loop, arbitrary known-share selection, zone purge or replacement household.

`PreparedHomeShare` means a locally identified private owner share. Its existing-share
recovery path does not prove export completion. Invitation delivery must separately
refresh the known share's server metadata and await managed membership persistence.
Household graph export and peer receipt remain separate observations.

## Evidence and limits

`HomeCreationTests`, `HomeShareGraphTests` and `HomeShareProvisionerTests` exercise
persistent local recovery, graph boundaries, exact share identity, callback failure,
explicit replay, permission refusal and concurrent/cancelled waiters. Their injected
transport does not prove native CloudKit behavior.

Apple does not document a distributed provisioning lock, crash atomicity or guaranteed
cleanup of abandoned server zones. The local gate cannot serialize two owner devices.
SHOPPING-30 must retain failure-injection and concurrent-owner evidence, including
`fetchShares` observations for private exclusions, actual graph delivery and retained
home identities. No speculative zone deletion is implemented to conceal uncertainty.

Sources: [managed sharing API](https://developer.apple.com/documentation/CoreData/NSPersistentCloudKitContainer/shareManagedObjects%3AtoShare%3Acompletion%3A),
[known-share lookup](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/fetchsharesmatchingobjectids:error:),
[managed share persistence](https://developer.apple.com/documentation/CoreData/NSPersistentCloudKitContainer/persistUpdatedShare%3AinPersistentStore%3Acompletion%3A).
The installed Xcode 27 public `NSPersistentCloudKitContainer_Sharing.h` also documents
that the initial callback establishes assignment, not necessarily object export.
