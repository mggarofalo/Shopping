# Incoming home invitations

SHOPPING-126 receives CloudKit invitation metadata through the iPhone scene delegate,
for both cold connection options and the warm acceptance callback. SwiftUI retains
window ownership. `CKSharingSupported` is enabled in the iPhone Info.plist.

The app-owned `HomeInvitationController` and atomic `HomeInvitationInbox` outlive
scene creation and selected-home presentations. A serial worker owns opening,
secure archiving, decoding, and atomic journal I/O; the main actor publishes immutable,
revisioned snapshots. An independent ingress count holds selection while newer arrivals
are still waiting behind older worker results. Bootstrap awaits inbox preparation before
allowing automatic creation in an empty local store. The inbox is namespaced by the
configured container/environment. Securely archived metadata remains inside the
app sandbox, with file protection and backup exclusion; secure coding restricts
decoding classes, rather than providing encryption. No invitation URL, metadata,
account identity, or raw CloudKit error description is logged or shown.

An arrival may wait unbound before account setup. Only the account provider's
verified `ready` state binds it durably to a session. Cached offline cart authority
does not authorize invitation acceptance. Previously bound invitations cannot move
to another account. The inbox restores its selection hold before first discovery,
including when the account is temporarily unavailable, so a sole imported home
cannot become selected accidentally.

Acceptance waits for the exact account's attached participant-shared store. One
native request remains outstanding until its callback, even after dismissal or
account switching. Other invitations remain queued. The full share record and zone
owner identity distinguish shares. A replacement link updates the queued capability;
an active attempt keeps its own immutable metadata while retaining later ingress
for retry. Fresh metadata reporting pending participation can reopen a completed
invitation after membership removal, including during initial import, bypassing stale
local accepted-share caches. Renewal invalidates older import-resolution tokens.

A successful managed acceptance enters **Loading groceries**. It does not select a
home or imply import completion. The native adapter locates the unique root for the
exact share, verifies its reciprocal grocery list, checks both objects' shared-store
association, and returns only value identities. A home with no needs is valid. This
is usable root/list readiness, not a claim that every record has arrived.

An interrupted acceptance requires explicit retry. Retry first checks existing
managed membership, except a fresh pending re-invitation, which requires renewed
native acceptance. Relaunch after acceptance resumes import discovery without
accepting again. Failed import discovery retains the accepted state; later successful
discovery clears that entry's import error. Errors give precise reasons only when
CloudKit supplies them. Dismissing an outstanding join does not cancel its server
operation, erase its graph, or release its automatic-selection hold.

The ready graph and durable activation hold are the handoff to SHOPPING-127's safe
adoption flow. No inbox callback changes the selected home, copies groceries, merges
catalogs, or moves personal carts. Explicit selection currently uses the existing
home chooser; SHOPPING-127 owns the fuller adoption/recovery choices and resolving
the invitation hold after successful adoption.

## Validation boundary

The unit tests cover the journal, controller with a simulated transport, account
switches, replacement-link races, and bootstrap ordering. A DEBUG UI fixture tests
visible dismissal and relaunch with an isolated local store and fake account; its
opaque metadata is never sent to CloudKit. It is not invitation delivery evidence.

SHOPPING-30 must still demonstrate native cold/warm routing, secure metadata restore,
private one-time links, actual shared import, empty homes, revoked/replacement links,
and account transitions on the two iCloud accounts/iPhones. Capture the device launch
and immediate-scroll Animation Hitches trace on the sharing candidate under the UI
responsiveness contract; the worker gate test is not a physical-device trace.
iOS 17 recipient routing
also remains unproven. There is no public 'all records imported' marker or claimed
crash-atomic native acceptance guarantee.

References: [SwiftUI managed acceptance](https://developer.apple.com/documentation/CoreData/accepting-share-invitations-in-a-swiftui-app),
[share metadata](https://developer.apple.com/documentation/cloudkit/ckshare/metadata),
[managed acceptance](https://developer.apple.com/documentation/CoreData/NSPersistentCloudKitContainer/acceptShareInvitationsFromMetadata%3AintoPersistentStore%3Acompletion%3A).
