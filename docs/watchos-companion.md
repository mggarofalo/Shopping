# watchOS companion

SHOPPING-120/121 supply a native watchOS 10+ target, `ShoppingWatch`, embedded in the iPhone app as an independent companion. It uses the existing app icon and a separate shared scheme. The iPhone scheme and its test plans retain their selections and coverage baseline.

Normal launch uses `PersistentWatchShoppingService`, an account-scoped SQLite replica backed by the same personal-cart engine as iPhone. `WatchPersistenceBootstrap` resolves the actual CloudKit account and attaches managed private/shared stores; it does not create a household when an import has not arrived. No foreground phone or WatchConnectivity transport is required. SHOPPING-103 owns personal-cart semantics; SHOPPING-122 owns real Series 11 phone-left-home acceptance. Enrollment and app-ID/container provisioning are complete, but SHOPPING-10 two-account readiness and SHOPPING-30 live sharing remain gates; local tests do not establish CloudKit convergence.

## Native UI

The entire store title, including the arrows at its right, is a native leading toolbar button that opens Stores. The toolbar reserves room for the system clock instead of placing content under it. The service supplies eligible rows and Settings category order. Rows show a name, optional quantity, urgency, other-shopper presence, and `lock.fill`/`lock.open.fill` for Only buy here/Can buy here. Long names truncate at default size and wrap at accessibility sizes; the card and accessible name always retain the full name. Purchase rules are announced once, not repeated as row prose.

SHOPPING-134 uses small Dynamic Type-scaled category captions above visible native row backgrounds. Store choices show closed/open padlock counts on the trailing side: remaining occurrences that must be bought there, and other remaining occurrences eligible there. These counts cover all stores independently of the current selection, include Any store, exclude the shopper’s own cart and fulfilled/unresolved demand, and retain the canonical archived-store restrictions. Another shopper’s cart is advisory and does not remove demand from these counts. Counts are transient presentation values, not persisted store inventory.

A native `NavigationLink` opens the card. Native trailing `swipeActions` add/remove your cart entry. Cards and named accessibility actions provide the same access. Other shoppers’ quantities are read-only. Missing-demand cart entries can retain a reason and Remove action. A purchase notice requires an explicit Remove or Buy anyway choice. Quantity drafts before Add stay local to the card; a cart quantity command uses the service token for that owner’s membership. Successful Add returns to groceries, where View cart opens the newly created membership. A failed Add retains the card and quantity draft for retry; busy or stale-account completions cannot dismiss it.

Groceries has View cart and Check out at the bottom. Cart has no store/count subtitle and a compact floating checkout action; an addable item card has a floating Add to cart action. A native bottom `safeAreaInset`, extended only through the container’s bottom safe area, anchors controls near the physical screen edge and reserves their actual height for scrolling. No extra scroll margins, row spacers, geometry measurement or custom scrolling are needed.

The native watch bordered style measured 52.5 points even at small control size. Native text toolbar items instead exposed a fixed 35-point accessibility frame despite control-size and label-frame requests. `WatchCompactButtonStyle` therefore retains semantic SwiftUI buttons with a 44-point hit region and a quieter capsule inside. This small presentation layer owns no gestures or scrolling. Native List rows retain 44-point targets plus the platform’s row spacing. The item summary keeps purchase-rule information inline, and quantity uses a compact horizontal decrement/value/increment group.

Checkout shows the service’s frozen names/quantities and store, then submits the same token. Results report actual outcomes and skipped names; Recently cleared displays owner-scoped recovery actions. Controls remain available for cached offline shopping according to individual service capabilities.

## Production adapter boundary

`PersistentWatchShoppingService` implements `WatchShoppingService` on the main actor. `ShoppingWatchApp` selects it for normal launch; `WatchPreviewService` and isolated durable fixtures are explicit DEBUG-only paths.

- `load(storeID:)` returns `WatchShoppingSnapshot`: active stores, valid selected store, preordered eligible grocery/cart sections, owner recovery operations, and capabilities. Nil selection may restore a service-owned last valid selection. Invalid/archived stores return no selected store; never widen to All stores. Grocery and cart ordering/filtering are service responsibilities.
- `execute(_:)` handles add, owner removal, owner quantity, and explicit buy-anyway commands. Each item’s opaque token identifies the validated account binding, household/list/occurrence, immutable cart-membership generation and causal evidence. The UI never supplies an owner ID or derives ownership from `Person`. Account switches invalidate tokens. Reject stale/unauthorized tokens before writes.
- `captureCheckout(storeID:)` captures the exact scope and returns a token plus frozen display rows. `checkout(token:)` revalidates and durably records only that capture. The UI retains a failed preview and retries the same token; never rerun a broad cart query under that token. An unconfirmed sheet need not survive relaunch; a confirmed checkout intent must.
- `restore(token:)` addresses the original owner-qualified receipts and returns actual restored/skipped/pending outcomes. Both checkout and restore return `WatchActionResult` with the new durable snapshot, human-readable status and skipped names.
- `onChange(.dataChanged)` notifies the session after durable imports. The session reloads its current scope, coalescing notifications during an active command. Before an account/authority transition, synchronously send `.authorityInvalidated`: the session immediately clears the old snapshot/sheets and discards any stale async completion before reloading. Each ready snapshot includes an opaque `authorityID`, stable across ordinary imports but different for another account/authorization epoch. Non-ready snapshots and changed authority IDs also clear captured/result presentations. Foreground activation also reloads. The previous durable snapshot remains visible after failed commands; errors are surfaced without optimistic row removal.
- Capability flags are per action. Keep availability ready while a private cart remains readable, even if household publication is revoked; reserve unavailable for the absence of a usable snapshot. Stores also links to your retained cart when no valid store is selected. An inaccessible household can still permit private owner removal/history while prohibiting publication. `statusMessage` reflects observed state and never treats phone unreachability as offline or a history token as synchronization proof. Presence remains informational and may be stale.

All snapshot identity strings must be stable across refreshes. An orphaned cart entry still needs its own presentation ID; it cannot disappear merely because its need is unavailable. `canCheckout` is service-owned and must exclude unresolved purchase notices; the preview can contain fewer rows than the visible cart. No watch view reproduces persistence or purchase-eligibility rules.

## Account and CloudKit configuration

On September 24, 2026, the container was created and assigned to both app IDs on team `649367BDD4`. A signed Debug iPhone build with its embedded Watch app passed; inspection of both signatures confirmed the container, Development environment, CloudKit service and development push entitlement. Schema initialization, Production deployment and two-account device proof remain unverified. The user confirmed the second account/device is not ready and requested simulator validation first.

Both app IDs must belong to the same developer team and be associated with `iCloud.com.mggarofalo.shopping`. Enable iCloud/CloudKit and Push Notifications for the iPhone and Watch app IDs, then regenerate their provisioning profiles. An existing iPhone distribution profile without CloudKit does not establish this configuration. Keep certificates, account credentials and provisioning secrets out of the repository.

The entitlements and generated Info settings use matching `SHOPPING_CLOUDKIT_ENVIRONMENT`/`ShoppingCloudKitEnvironment` values: Development in Debug and Production in Release. `APS_ENVIRONMENT` is development/production respectively. The iPhone target enables the remote-notification background mode; both native delegates register for silent push delivery. No visible-notification permission is required for this registration. The Watch delegate accepts invitations through the managed participant store, with `CKSharingSupported` enabled.

Enable personal carts on the first iPhone by explicitly choosing whether to copy its local household. Other devices import the existing household instead of copying another local list. The Watch uses the same authenticated account binding, private owner records, versioned model and shared household graph. Account changes invalidate UI tokens and detach the prior stores. Never copy another shopper’s private cart into the household share.

Initialize and inspect the managed CloudKit development schema as part of SHOPPING-30, then deploy the verified schema before any Production/TestFlight sync claim. Do not call schema initialization from ordinary app launch. Verify owner and invited-participant paths with two different iCloud accounts. For SHOPPING-122, turn the iPhone off before Watch cold launch, import, offline shopping and later publication; turn it on afterward to compare the resulting personal cart and household demand.

## Build and validation

Use Xcode 27 and the installed Series 11 watchOS 26.5 simulator:

```sh
xcodebuild build -project Shopping.xcodeproj -scheme ShoppingWatch \
  -destination 'platform=watchOS Simulator,id=6CC1A722-336A-4CBF-B554-31B32BDB9A22' \
  -derivedDataPath /tmp/shopping-watch-derived
xcodebuild test -project Shopping.xcodeproj -scheme ShoppingWatch \
  -destination 'platform=watchOS Simulator,id=6CC1A722-336A-4CBF-B554-31B32BDB9A22' \
  -derivedDataPath /tmp/shopping-watch-derived \
  -resultBundlePath /tmp/shopping-watch-tests.xcresult
```

The watch scheme owns session boundary tests and native UI tests; they do not join or alter the iPhone Fast coverage collection. Presentation tests use a new in-memory preview service per launch. Durable integration tests use the real adapter and a unique SQLite directory that is reopened, without reseeding, across deliberate relaunches. Neither accesses a real household. The scheme also sets an unavailable fixture for hosted unit-test app startup; ordinary Run remains the production path. `SHOPPING_WATCH_FIXTURE=populated`, `empty`, `longNames`, `fullCart`, `saveFailure`, `loading`, or `unavailable` selects explicit DEBUG-only fixtures. Release builds exclude fixtures. Xcode previews also show purchase notices and partial checkout results.

Session tests cover unavailable service launch, failed-save snapshot retention, opaque commands, captured checkout retry, invalid store capture, authority invalidation during a suspended checkout, and offline owner removal/recovery. UI tests cover isolated unimported-replica launch, full-title store switching, native swipe/cart flow, purchase notice choice, captured checkout and recovery. Simulator screenshots and accessibility-tree assertions are local presentation evidence only. UI tests exercise simulated Digital Crown scrolling; physical VoiceOver, physical Crown handling, Reduce Motion, oldest supported runtime, signing/install distribution, and real sync remain device/integration acceptance work.

Local validation on September 24, 2026: the Series 11 46mm simulator passed all eight session tests and six native UI tests. The 42mm simulator also passed the full suite before the final compact toolbar adjustment, followed by focused store-switching, large-text, and footer-clearance checks. Generic iOS Simulator embedding and Release watchOS Simulator builds succeeded. These checks validate the native shell and injected fixtures. Subsequent SHOPPING-121 validation passed 258 iPhone Fast tests, 40 focused persistence tests after the final account-detachment guard, and the final Watch suite of 17 unit tests plus nine UI workflows, including three durable workflows using the production adapter. The Watch result is `/tmp/shopping-121-final-snap-verified.xcresult`. Earlier UI failures came from the test helper skipping virtualized buttons or snapping at a partial row; measured Crown movement was corrected without weakening visibility assertions or changing production UI. An unsigned device Release archive and a signed Debug iPhone/embedded-Watch build also passed. These checks establish local persistence and packaging, not cross-device synchronization.

## First-party guidance

- [Building a watchOS app](https://developer.apple.com/documentation/watchos-apps/building_a_watchos_app)
- [Creating independent watchOS apps](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps)
- [Sharing Core Data objects between iCloud users, including watchOS](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
- [SwiftUI swipe actions](https://developer.apple.com/documentation/swiftui/view/swipeactions(edge:allowsfullswipe:content:))
- [watchOS 10 interface composition](https://developer.apple.com/documentation/watchos-apps/creating-an-intuitive-and-effective-ui-in-watchos-10)
- [Native bottom toolbar placement](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/bottombar)
- [SwiftUI safe area inset](https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)-6gwby)

The installed SDK confirms these native APIs at the watchOS 10 minimum. The target opts into `WKRunsIndependentlyOfCompanionApp`. Its managed bootstrap supplies the independent data path; physical phone-powered-off validation still belongs to SHOPPING-122.

### Compact sync status

Shopping, cart, and store selection expose a small sync control; tapping opens current details. Routine CloudKit activity does not insert message rows or automatically present a sheet. The icon distinguishes waiting, working, recently completed activity, and attention; recent activity does not establish delivery to another device. Account, sharing, import-history and recovery messages remain in details, while blocking setup and action alerts keep their existing flows.

On the grocery screen the store switcher and sync control occupy the first native `List` row (SHOPPING-143). They scroll away with groceries and return at the top; there is no scroll-direction tracking or automatic reappearance on an upward movement. Separate leading/trailing watchOS toolbar items move the system clock to the center and overlap a wide store-name control; `principal` placement is unavailable on watchOS. The scrolling row avoids that collision without custom offsets or gesture handling. Cart and store selection retain native trailing toolbar controls. The small symbol has a full 44-point header target, and details use a scrollable native list with Back and Done.

SHOPPING-143 keeps the header as ordinary scrolling content, so accessing store or sync controls after shopping farther down requires returning to the top. `testStoreAndSyncScrollAwayAndReturnOnlyAtTop` proves disappearance, no reappearance after a small reverse scroll, fixed footer clearance, and working details/store navigation after returning. Existing empty-state, accessibility-text and store/swipe workflows retain those boundaries on both supported simulator sizes.


### Optimistic Add (SHOPPING-215)

The cart is a local membership/quantity view over the authenticated shopper’s
private durable graph. Eligible active household needs outside that cart appear
in groceries. Purchased, archived, unavailable and orphaned saved entries retain
their existing semantics; this is not a complement of the entire catalog.

SHOPPING-216 replaces the single pending Add/global busy gate with a serial local
commit queue. Add and Remove navigation completes on acceptance; independent
rows and pending quantities remain editable while the writer is occupied.
Checkout and scope/recovery actions remain barriers until local edits settle.
Each receipt retires only its own intent. Same-item queued edits may use only
that operation’s exact causal successor; a concurrent phone replacement cancels
dependent intents rather than retargeting them. Failed or uncertain saves affect
that occurrence; independent items can continue. An authoritative read resolves
uncertainty without resubmitting the mutation.

SHOPPING-257: every read mints new opaque tokens for unchanged rows, and a full
read follows each drained queue. A tap handled after that read replaced the
snapshot, but before SwiftUI re-rendered, carried the superseded token. The
session accepted it without an optimistic row, so the card dismissed and the
item stayed in groceries until a later read, which looks like an ignored tap; a
second tap could then queue another Add for the same item. Add is therefore keyed
by the tapped occurrence: `WatchShoppingSession.add(_:quantity:)` submits the
current row's token, and a row already in your cart, pending or saved, makes the
repeat a no-op. Quantity and Remove tokens carry membership causality and keep
the rules above. Queue depth is unbounded: session tests cover 1, 2, 3 and 8
queued Adds and a failure mid-queue; SQLite tests cover four Adds behind a held
writer and a tap from a row rendered before a read replaced its token.

SHOPPING-265: a Remove tapped from a row rendered while its Add was saving still
carried the Add token, which names no membership, after the Add's receipt had
already retired it. The service rejected it as a changed entry and the Watch
reported a problem, although the removal matched the shopper's intent. The
session now records each successor token that its own receipts return, and
resolves a rendered Remove or Quantity token through that chain before it
queues the edit. `WatchShoppingSession.remove(_:)` keys the optimistic removal
by occurrence, so a row from before a read is hidden at once, and a repeat tap
is a no-op; card quantity edits use `setQuantity(_:quantity:)` the same way. A
token from a full read is never adopted, so the service still rejects a
membership that another device changed, and that conflict is shown. A chain
whose end is spent or uncertain is retired so its operation ID cannot replay.
One narrower case remains: a row rendered before a read, tapped after another
edit of the same item through the refreshed row, still reports a change.

### Local-first shopping (SHOPPING-269)

On 1.6.5 a shopper quickly added three items on the Watch, then removed them.
The cart emptied at once, but the items did not return to groceries until
CloudKit sync finished. The Watch store was already local. The session was not:

- A Remove's optimistic projection and its receipt both dropped the row. Only a
  later full projection read put it back in groceries.
- Each drained queue schedules that full read. A commit queued while a read was
  in flight waited for the whole read before it started.
- Every full read is several writer transactions over the private command
  history, on the same store coordinator that CloudKit mirroring uses for its
  import and export. On a Watch during sync, the read finishes when the sync
  work does. A Remove could therefore wait for two reads in turn. No device
  trace was captured; the SQLite tests reproduce the dependency on the read.

The target design: every result the shopper sees comes from the Watch's own
durable receipt, and a full read only converges what arrived from elsewhere.

- `PersistentWatchShoppingService` builds grocery and cart rows through one
  `RowContext`, used by full reads and local receipts alike. If a removed
  occurrence was outstanding and eligible at the selected store in the last
  read, the removal receipt returns its grocery row with a fresh Add token
  (SHOPPING-291).
- `WatchShoppingSnapshot.replaceItem(occurrenceID:with:section:)` places a row
  in cart or groceries with the service's ordering. The session's pending
  projection and the adapter's receipt patch share it.
- Commits never wait for a read. A read that overlaps an applied receipt is
  discarded in the session and not adopted by the adapter, because it may
  predate that receipt, and a new read is requested. A removal's grocery row is
  never recorded as a successor token.
- Checkout, restore and store choice remain barriers until local edits settle.
  They never wait for an in-flight read (SHOPPING-279); that read is discarded.
- One read still waits: after a commit throws, the session waits for any
  in-flight read, then reads once to learn whether the failed write committed.
  Later edits queue behind that check.

| Watch interaction | Shown from | Needs network, phone or sync |
| --- | --- | --- |
| Add, Remove, Quantity | the local receipt (pending row until it lands) | no |
| Groceries after Remove | the pending projection, then the removal receipt | no (was: a full read) |
| Checkout and Buy anyway result | local capture and the private intent's outcome | no; household receipt publishes later |
| Restore | private restore intent and one local cart read | no; retraction publishes later |
| Relaunch | the account's cached session and SQLite replica | no |
| Another device's changes | the next read after a history import | yes, by definition |

Offline: an already provisioned Watch uses its cached session, so launch and
every command above work in airplane mode with the phone away. Presence,
purchase receipts and retractions stay in the durable outbox and publish when
CloudKit exports them.

Convergence: cart records are immutable causal envelopes (ADR 0002). An import
from the phone or another shopper changes nothing already shown until a read
adopts it. Concurrent Adds of one occurrence resolve to one membership on every
replica; a concurrent Remove wins; another shopper's purchase leaves your entry
with a purchase notice. Imports only request a read, and that read can't undo a
newer local receipt.

Relaunch: commands are durable before their receipts return, so a relaunch,
offline or not, reads the same cart, quantities and groceries from SQLite.
Native share verification runs in the background and never gates that read.

Tests with no refresh read and no network: rapid Add then Remove returning
every item to groceries; rapid quantity edits and removal surviving a relaunch
while native verification never answers; and an import of the same shopper's
phone edits plus a new household item, converging with each item once.

### Cart and list from local state (SHOPPING-291)

On 1.6.7 (43), removed cart items reached the Watch list only after a delay,
each showed a clock while the Watch waited, and Checkout was slower than on
the iPhone. None of it waited for iCloud. It waited for the Watch's own store:

- **The clock** marks a row whose local save hasn't returned. The session
  commits its queue one command at a time, so each row's clock clears in turn.
- **Per-item cost.** Each command took two writer transactions: the command,
  whose receipt was discarded, then a second read for the Watch row. The
  iPhone takes one. The writer shares the coordinator with CloudKit mirroring,
  so each transaction can wait behind sync work.
- **The list.** A pending Remove dropped the row from the cart but didn't put
  it on the list. Only its receipt did, after every save queued ahead of it.
- **Checkout and Buy anyway** ran a full snapshot read before returning.

Now:

- A pending Remove moves the row to groceries at once
  (`WatchShoppingItem.listReturn`), with the clock and without Add until its
  receipt mints a fresh Add token. The row never waits to move.
- A command is one writer transaction. `PersonalCartReceipt.successor` names
  the membership the operation wrote, which decides whether queued edits may
  chain onto it.
- Checkout and Buy anyway patch the cart and recovery list from their own
  outcome. Restore uses one local cart read. A later read confirms each.
- A restored entry no longer shows the shopper's own purchase as "Already
  purchased" while its retraction waits in the outbox.
- Commands still save one at a time. Saving several in one transaction would
  let one stale item fail the others, and rows no longer wait for saves.

### Account session (SHOPPING-278)

Before 1.6.7, `ShopperSessionProvider.refresh()` invalidated the saved account
binding whenever iCloud answered `couldNotDetermine` or
`temporarilyUnavailable`, or a lookup failed with anything other than a network
error. The binding stayed invalidated after relaunch, and the Watch then retired
its store as an account change. A Watch away from its phone can get exactly
those answers, so checkout stopped working until the phone came back. The Watch
also re-asked for the account every 30 seconds while shopping.

Apple's guidance:

- [`CKAccountStatus.temporarilyUnavailable`](https://developer.apple.com/documentation/cloudkit/ckaccountstatus/temporarilyunavailable):
  "Don’t delete any cached data and don’t enqueue any CloudKit operations after
  receipt of this account status. Instead, use the CKAccountChanged notification
  to listen for when the status changes to available."
- [`CKAccountStatus.couldNotDetermine`](https://developer.apple.com/documentation/cloudkit/ckaccountstatus/couldnotdetermine):
  "CloudKit can’t determine the status of the user’s iCloud account."
- [`CKContainer.accountStatus(completionHandler:)`](https://developer.apple.com/documentation/cloudkit/ckcontainer/accountstatus(completionhandler:)):
  "While your app is running, use the CKAccountChanged notification to detect
  account changes, and call this method again to determine the status of the
  new account."

The notification arrives only while the process runs, so both apps also check
once at launch and each time they become active. Nothing polls.

| Answer | Saved binding | State | Store |
| --- | --- | --- | --- |
| `available`, same account | kept | `.ready` | kept |
| `available`, different account | replaced | `.ready` (new) | old one retired, kept on disk |
| `noAccount`, `restricted` | invalidated | `.setupRequired` | retired |
| `couldNotDetermine`, `temporarilyUnavailable` | kept | `.cached` | kept |
| Network, server or authentication error | kept | `.cached` | kept |
| Malformed identity (`invalidIdentity`) | kept | `.setupRequired` | retired until a good answer |
| `CKAccountChanged` | kept | `.ready` becomes `.cached`, then re-check | decided by the re-check |

Without a usable saved binding, the indeterminate answers give
`.temporarilyUnavailable`, as before. A `.cached` session runs every local
command. Background CloudKit work (native access, share associations) may still
fail, and it retries as usual. Sync details say "Using saved account"; this is
never an alert. The wrong-account guard is unchanged: each account's store
directory is named by its `accountBinding`, and every transaction rechecks the
current session before writing.

Switching iCloud accounts passes through sign-out, and `noAccount` is
definitive. A re-check after `CKAccountChanged` that is still indeterminate
therefore keeps the saved account, as Apple directs for `temporarilyUnavailable`.
A verified lookup for a different account invalidates the old binding even when
the new one can't be saved.

`WatchPersistenceBootstrap.checkAccount()` coalesces the launch check and the
activation check (`WKApplication.didBecomeActiveNotification`), so a second
check can't discard the first one's answer. A Watch that launched with no saved
account and no answer waits for the next activation or `CKAccountChanged`; the
60-second local reread doesn't ask iCloud. If `CKAccountChanged` supersedes that
launch check, the first load can fail once; the newer check's answer then
reloads through `onDataChanged`. On iPhone, `PersistenceBootstrap` already checks when it
opens the personal store and in `applicationDidEnterForeground()`.

`ShopperSessionProviderTests` covers every `CKAccountStatus` value and each
error class (including a rejected identity), on cached and uncached state,
launch after a transient answer, transient answers after verification and after
an in-session sign-out, and `CKAccountChanged` to the same account, another
account, sign-out and an indeterminate answer, and a different account whose
binding can't be saved.

Each answer is logged under the app's bundle identifier, category `Account`
(`Account lookup:`, `Account lookup failed:` with error domain and code,
`Account state:`, `CKAccountChanged: re-checking`). Logs never include the
account record name or binding.

### A participant's own checkout (SHOPPING-273)

Two rules decide whether a checkout fulfills a need:

- **The shopper's own view** (`PersonalDemandProjection.shopperFulfilledNeedIDs`):
  groceries, outstanding needs and cart Add checks on the Watch and the iPhone.
  The shopper's own checkout counts at once, while the durable access ledger
  still authorizes it (`homeEffectAuthorized`). Pending native verification
  doesn't matter, so an invited shopper's offline checkout leaves their own
  groceries straight away, and stays out after an offline relaunch.
- **The household rule** (`PersonalDemandProjection.fulfilledNeedIDs`): it feeds
  replacement lineage in `HouseholdDemandJournal`. An own checkout counts only
  while this device may publish it (`homeEffectMayPublish`: the ledger plus
  verified native publication). This rule is unchanged. Other shoppers learn of
  the purchase only from its published receipt. Remembered-need dedupe and
  re-add use this rule too, so they agree with the lineage the journal records
  in the same save. A re-add after an unpublished checkout renews the same need.
  Its new demand evidence returns it to groceries, and the later receipt doesn't
  fulfill it. One need, never two.

When verification later:

- **succeeds:** the outbox publishes the receipt once (stable receipt IDs), and
  both rules agree. Nothing reappears or duplicates.
- **observes a loss (left or revoked):** the durable block withdraws the
  checkout's authority, and no later rejoin restores it. The need is
  outstanding again for this shopper, because the household never learned of
  the purchase. The purchase stays in purchase history, marked pending
  publication; it's never deleted.
- **observes read-only access:** the need shows again while the restriction
  holds. When writable access returns, the checkout hides the need again and
  publishes once.

`HomeNativeShareSource` holds the native CloudKit facts (a participant home's
share identity, and whether the session is verified and CloudKit lets it write).
Tests substitute an offline participant source over real SQLite.

### Shopping with only the Watch (SHOPPING-279)

With the phone left behind, checkout stayed impossible until the phone came
back. Four gates depended on sync rather than on the Watch's own store:

- Household access read `canUpdateRecord`, which answers from CloudKit share
  metadata. Missing share metadata also made the native identity throw, which
  failed the whole snapshot.
- Any incomplete import of household records (another shopper's presence, a
  purchase receipt) marked the whole household unwritable.
- `commit`, `captureCheckout` and `checkout` each ran a full projection read
  first, and Restore ran another.
- The session made Checkout, Restore and store choice wait for any in-flight
  refresh read, which on a syncing Watch finishes when the sync work does.

The rules now:

- **One access authority** (`WatchPersistentProjection.mayPublish`): the
  durable `HomeAccessRecord` ledger plus the last finished native observation.
  A finished read-only or lost observation blocks Add, Buy anyway, Checkout and
  Restore. A pending, failed or missing verification never does. Capture,
  Checkout and Restore recheck it in one small writer transaction, so an
  observation that finishes after the snapshot still blocks them.
- **Imports degrade what they describe.** A need without an identity yet is left
  out until it arrives. Demand or history that can't be read yet withholds
  groceries or saved purchases, with "Some household items are still arriving".
  The cart, its edits and Checkout stay available. Presence is advisory only.
- **Capture uses the receipt-patched snapshot.** `canCheckout` is derived from
  the same rows Checkout captures (`hasCheckoutRows`), so a local receipt keeps
  it current without a full read.
- Publication, presence and export stay asynchronous in the durable outbox, as
  before. Tests cover an owner and a participant with verification held and an
  incomplete import, through Add, Quantity, Remove, Checkout, relaunch and
  Restore, then exactly one purchase and one retraction after verification.

A household record still importing no longer fails a cart read, Checkout or
Restore (SHOPPING-285). It concerns no need until its payload arrives; see
[personal carts](personal-carts.md#storage-and-commands).

The engine stays `NSPersistentCloudKitContainer` mirroring. Nothing above
needed a different sync engine; Apple still controls export and import timing.

Private cart commands save promptly using the existing causal records and
removal evidence. A fixed two-second window publishes the latest advisory
presence for changed needs only; continuous tapping does not reset the window.
Captured versions acknowledge only their own batch. Failed needs stay pending
while other needs publish, and durable replay recovers publication after relaunch.
CloudKit continues to mirror the existing private/shared stores. This local
coalescer does not configure or promise a two-second network interval: Apple
provides no API to control managed synchronization timing ([TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)).

Remote store notifications consume persistent history and publish imported
state before unrelated share-association work. Local-author history does not
cause an echo reload. Imports coalesce behind local commits; they never overwrite
newer pending intents. Activation and the existing active-view fallback reread
the local replica to catch missed/coalesced notifications. Background suspension
can delay publication and pushes; persisted commands remain the recovery source.
No schema, entitlement or transport migration is part of this patch.

The physical Watch was unavailable to developer tools on October 8. Simulator
and SQLite tests establish the queue and persistence behavior, not real-device
CloudKit delivery or a measured physical responsiveness improvement.
