# SHOPPING-215: optimistic Watch Add to cart

The accepted SHOPPING-214 iPhone design remains unchanged. Patch 1.5.4 adds immediate Watch cart presentation while the existing local persistence command completes. This is a responsiveness correction to the existing Add workflow, with no new persistence or CloudKit model.

## Behavior

- Add moves the occurrence from groceries into the cart immediately, retaining the exact optional quantity. Cart rows announce Adding to your cart and show a small clock; the item card keeps its quantity visible with Adding to cart… until the save returns.
- The foreground session owns one pending presentation overlay over the latest saved snapshot. It reserves the existing serialized command before waiting for a refresh. Older reads can refresh the saved base without undoing the pending Add. Need identity connects the grocery row to its distinct durable membership ID; existing claims retain their authoritative quantity.
- Pending entries have no usable membership command. Quantity changes, removal, Buy anyway, and checkout wait for authoritative state. Exact repeated Add taps coalesce without creating another command.
- Ordinary write failures reconcile from a fresh read and expose feedback with a retryable item. A command can commit before its final read or selection-file write fails; reconciliation never re-executes that command. If both reads fail, the item remains explicitly unconfirmed, mutations are blocked, and Check cart or a later successful local refresh resolves it.
- Account/authority invalidation removes pending state immediately. Scope changes remove the overlay. Successful reconciliation releases the overlay, so later authoritative removal or quantity changes remain visible.
- Offline saves use the existing independent Watch SQLite/CloudKit path. The pending indicator means local save confirmation, not phone delivery. No WatchConnectivity dependency or new outbox was added.

## Proof owners

`WatchShoppingSessionTests` owns immediate state, exact quantities, duplicate taps, held refresh ordering, existing memberships, failure/retry, uncertain success, recovery to an uncarted state, offline/status/reconnect observations, category rank, and authority invalidation during reconciliation.

`PersistentWatchShoppingServiceTests` owns a real blocked writer with visible pending state and a committed Add followed by a real selection-file failure. Existing production-adapter durable relaunch and checkout recovery remain in the Watch aggregate.

`WatchShoppingUITests` owns card and swipe wiring, pending visibility before a controlled-latency service returns, safe Check cart recovery, and retained failure/retry workflows. The 30-second latency is only a DEBUG fixture and is not a claimed production duration or a test retry. Durable UI flows retain isolated SQLite stores across explicit relaunches.

## Evidence

Local environment: Xcode 27.0 (27A266a), watchOS 26.5 Series 11 46mm and
42mm simulators, and iOS 26.5 iPhone 17 Pro. Serial tests per simulator, separate
Watch/iPhone DerivedData. No latency or physical performance claim is inferred
from these test durations.

| Run | Result | Scope |
| --- | --- | --- |
| WatchOptimisticFocused | 26 passed | Initial session boundary suite before the additional tests. |
| WatchOptimisticValidation | 74 unit/persistence passed; 4 UI passed, 1 UI failed | Pending card/swipe and existing failure/retry passed. Recovery assertion incorrectly expected an offscreen virtualized Remove button without scrolling. |
| WatchOptimisticDurable | 4 UI passed | Recovery uses the existing bounded reveal, retains enabled-state/quantity assertions and verifies one cart row. Both durable Add/relaunch workflows and large-text details passed. |
| WatchOptimisticSmall | 1 UI passed, 1 UI failed | 42mm pending swipe passed; existing large-text reveal overshot a narrow clear-frame window. |
| WatchSmallAlignmentDiagnosis | Interrupted, exit 75 | Repeated geometry established the overshoot; stopped after collecting evidence. |
| WatchOptimisticSmallFinal | 3 UI passed, zero failed/skipped | 42mm large text, pending swipe and Check cart recovery with corrected alignment. |
| WatchOptimisticCompatibility | 74 unit/persistence and 1 pending-swipe UI passed | Final compiler-compatible source; zero failed/skipped. |
| WatchPatchFinalFast | 748 passed, zero failed/skipped | Required aggregate repeated after the compatibility correction. |
| WatchPatchFast | 748 passed, zero failed/skipped | Required iPhone Fast aggregate with the Watch patch. |

The failed result bundle and hierarchy are retained. The recovery failure showed
confirmed quantity 3 and enabled controls, with Remove below the visible list.
Only the test lookup changed; no product workaround, wait increase, retry,
skipped assertion or baseline change was introduced. Production source is the
same across the aggregate and corrected UI runs.

On 42mm, the long-name row measured 107.5 points in a viewport from 40 to
156.5 points: only 9 points of placement margin. Crown steps oscillated between
y = -2 and y = 65.5; the old helper switched to fine motion only within 15
points, so it never entered the fit window. After a measured direction reversal,
fine motion now begins within 60 points. The same hittability, full clear-frame
or oversized-row assertions, and 24-step bound remain. This is a test helper
correction, not an app layout change. The failed run and deliberately interrupted
diagnostic retain their original outcomes.

Hosted verification belongs to the exact integrated draft PR head; see PR #84
for its final SHA and required Build & Test / Release SDK Build results.

| State | Screenshot |
| --- | --- |
| Before card Add | [Item and quantity](before-card-add.png) |
| Pending card Add | [Immediate status with retained quantity](pending-card-add.png) |
| Before swipe Add | [Grocery row](before-swipe-add.png) |
| Pending cart | [Quantity and clock before save completes](pending-cart.png) |
| Confirmed cart | [Clock removed, checkout enabled](saved-cart.png) |
| Unconfirmed outcome | [Safe Check cart recovery](unconfirmed-add.png) |
| Reconciled cart quantity | [Confirmed quantity and enabled controls](recovered-quantity.png) |
| Durable relaunch | [Saved membership and quantity](durable-cart-after-relaunch.png) |
| Large text | [Full long item name](long-name-large-text.png) |
| 42mm large text | [Aligned long-name row](small-large-text.png) |
| 42mm pending cart | [Pending membership and quantity](small-pending-cart.png) |
| 42mm recovery | [Confirmed editable quantity](small-recovered-cart.png) |

All pixels above were captured from the running Watch simulator and reviewed.
The before images show the state immediately before Add in the same workflow;
they are not presented as screenshots of a different released binary.

Simulator evidence cannot establish physical Watch VoiceOver/Crown behavior, on-device frame timing, or live CloudKit convergence with the phone off. Those remain the established device-validation scope; no physical app was replaced.


The first integrated candidate (`e44f0c8`) failed Release SDK Build in
[CI 37709353537](https://github.com/mggarofalo/Shopping/actions/runs/37709353537):
the hosted compiler resolved a later local `item` declaration inside earlier
closures and rejected the capture-before-declaration. Local Xcode 27 accepted
that shadowing. The temporary value was renamed `projectedItem`, preserving
behavior and making the stored-property references unambiguous. The failed CI
log is retained; the replacement candidate must pass both required jobs.
