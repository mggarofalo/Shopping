# SHOPPING-216: consecutive Watch cart edits

This patch addresses Michael’s physical-Watch report on 1.5.4 (34): the first
Add appeared immediately, while later actions remained disabled during local
save/publication/refresh work. The released session reserved one global busy
flag; the persistence service republished every historic need and returned a
complete projection after each command. Inspection found no normal command-path
wait for CloudKit delivery.

## Change and compatibility

The Watch accepts independent local cart intents immediately, saves through one
serialized writer, and confirms each operation independently. Same-item queued
edits can use only their exact local predecessor’s causal token. A changed phone
membership cancels dependent intents with feedback. Quantity reversals are kept.
Uncertain saves quarantine one occurrence rather than the entire list.

Advisory presence publishes the latest state of changed needs in a bounded
first-edit window. Captured versions protect newer edits from an older completion;
failed needs remain pending without blocking others or spinning while idle.
Existing durable records drive relaunch recovery. Incoming history reconciliation
precedes share-association work, with checkpoints during a continuing local queue.
The existing Core Data model, CloudKit transport, entitlements and audiences are
unchanged. Version 1.5.5 is a patch because saved-data meaning and capabilities
remain compatible.

## Local evidence

Xcode 27.0 (27A266a), watchOS 26.5 Series 11 46mm, iOS 26.5 iPhone 17 Pro.

- Watch unit/persistence: 90 tests passed, zero failures on the final candidate (`WatchFinal.xcresult`).
- Shared personal-cart persistence: 52 cart and replica tests passed, zero failures (`CartReplicaFinal.xcresult`).
- Watch simulator UI: 14 distinct scenarios passed (13 in `WatchUI1.xcresult`,
  corrected rapid-edit scenario in `WatchUI2.xcresult`). Final affected rapid-edit
  and last-row UI checks both passed in `WatchFinal.xcresult`. The failed first fixture
  run remains retained and explained below.
- Complete ShoppingFast: **750/750 passed**, zero failures/skips/expected failures
  (`FastFinal.xcresult`). Two internal QoS priority-inversion warnings remain in
  the result bundle; this does not establish physical-device timing.

Raw logs/result bundles are retained at
`/Users/michael/Documents/Codex/2026-10-07/task/validation-216`.
The first Watch run retained eight failed assertions: five required explicit
waiting for the new coalesced read, and three described the superseded coupling
between successful cart save and selection-file refresh. Assertions were updated
to retain their authority/recovery proof and verify the new local receipt boundary.
The first iPhone command used the wrong test target; the next used unsigned
simulator output and crashed before testing because CloudKit entitlements were
absent. Correct target plus normal simulator signing passed. No retry-as-fix, skips, expected-failure annotations or coverage baseline reductions
hide failures. The first rapid UI scenario held its first save for 45 seconds;
automation reached Remove at 59.42 seconds and the final pending assertion at
68.54 seconds, after the expected release near 56.2 seconds. The fixture now
holds for 90 seconds; pending-state assertions and the final 60-second completion
wait are unchanged. The failed bundle remains retained.

The first complete Fast run (`Fast.xcresult`) found four assertions in the existing
concurrent quantity replica test: suppressing an explicit nil-to-nil edit discarded
causal evidence when another replica set quantity 4. The optimization was removed;
explicit quantity commands again record intent even when their value is unchanged.
The original replica assertions remain intact. Screenshot inspection also caught
an empty category heading after optimistic removal; the session now removes empty
cart sections immediately, with a focused assertion and passing UI recheck. Actual final screenshot pixels
confirm the removed Produce category no longer leaves an empty heading.

## Review and remaining device proof

An independent reviewer identified and verified fixes for arbitrary remote token
adoption, a failed publication blocking other needs, nonconsecutive quantity
intent deduplication, and silent cancellation of accepted dependent edits. The
final reviewed code, including the causal quantity and empty-section corrections,
had no remaining correctness blocker. Required exact-head CI remains the merge gate.

The physical Watch was unavailable to developer tools. These results establish
local simulated interaction and persistence behavior; they do not establish
physical timing, cross-device CloudKit latency or constant background delivery.
`Watch local commit`, `Watch presence batch` and `Watch snapshot read` signposts
support follow-up measurement without conflating local work with cloud delivery.

## Screenshots

Before: [1.5.4 pending Add card](../shopping-215/pending-card-add.png).
After: [quantity controls remain available during a save](pending-quantity-editable.png)
and [large-text item details](long-name-large-text.png). These are simulator
fixtures, not screenshots of a real household.

Rapid interaction: [two independent pending Adds](independent-pending-adds.png),
[quantity and removal before the first save](pending-quantity-and-removal.png),
and [final committed cart without duplicates](committed-consecutive-edits.png).


## Pre-upload recovery correction

PR #85 passed required CI and merged at `c0ae5a9`, but independent follow-up
review identified a cancellation-feedback gap before upload. A predecessor could
save successfully and fail to return its receipt; queued same-item quantity or
Remove commands were correctly withheld, but rereading the saved predecessor
cleared their cancellation warning. `ReceiptRegressionBefore.xcresult` reproduces
this on the unchanged merged session: two methods, six missing-feedback
assertions, with the one-Add and durable quantity-1 assertions passing.

The correction preserves a separate cancellation notice across immediate and
delayed reconciliation, including uncertainty on another item. It does not infer
an exact local successor from a general snapshot or blindly repeat Add. Authority
and scope changes clear old notices. The original no-descendant recovery remains
a silent success when the saved command is confirmed. Final correction validation
and the new exact-head/main gates are required before upload; the superseded main
run was canceled and no 1.5.5 build had been uploaded.


`RecoveryWatchFinal.xcresult` passed both affected native UI workflows (failed
Add acknowledgment/retry and Check cart recovery). Its 94 unit methods had one
fixture failure: the spy restored the requested store before returning, so the
new automatic-store-change case never changed scope. The fixture now uses its
existing return hook and independently asserts the new selected store. Product
code was unchanged for that correction. The new lost-receipt, delayed recovery,
and explicit-OK assertions passed in that run. Independent review found no
remaining blocker after the notice lifecycle fixes.


Final correction validation: **94/94 Watch unit tests** passed in
`RecoveryWatchUnits.xcresult`; both affected native retry/Check cart UI workflows
passed in `RecoveryWatchFinal.xcresult`; complete ShoppingFast **750/750** passed
with zero failures/skips in `RecoveryFastFinal.xcresult`. Its two internal QoS
warnings remain retained. The original 14-scenario Watch UI evidence and final
rapid-edit screenshots remain applicable; the correction changes only recovery
feedback and its acknowledgment, not row geometry or command persistence.
