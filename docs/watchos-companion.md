# watchOS companion

SHOPPING-120 supplies a native watchOS 10+ presentation target, `ShoppingWatch`, embedded in the iPhone app as an independent companion. It uses the existing app icon and a separate shared scheme. The iPhone scheme and its test plans retain their selections and coverage baseline.

Normal launch shows setup required until SHOPPING-121 installs the production service. This target does not establish offline persistence, household sharing, personal-cart authorization, or CloudKit convergence. SHOPPING-103 owns personal-cart semantics; SHOPPING-121 integrates its service; SHOPPING-122 owns the real Series 11 phone-left-home acceptance. SHOPPING-10 and SHOPPING-30 remain live-sharing gates.

## Native UI

The entire store title, including the arrows at its right, is a native leading toolbar button that opens Stores. The toolbar reserves room for the system clock instead of placing content under it. The service supplies eligible rows and Settings category order. Rows show a name, optional quantity, urgency, other-shopper presence, and `lock.fill`/`lock.open.fill` for Only buy here/Can buy here. Long names truncate at default size and wrap at accessibility sizes; the card and accessible name always retain the full name. Purchase rules are announced once, not repeated as row prose.

A native `NavigationLink` opens the card. Native trailing `swipeActions` add/remove your cart entry. Cards and named accessibility actions provide the same access. Other shoppers’ quantities are read-only. Missing-demand cart entries can retain a reason and Remove action. A purchase notice requires an explicit Remove or Buy anyway choice. Quantity drafts before Add stay local to the card; a cart quantity command uses the service token for that owner’s membership.

Groceries has View cart and Check out at the bottom. The native watch bordered style measured 52.5 points even at small control size, so `WatchCompactButtonStyle` preserves a native 44-point Button hit region while drawing a 32-point capsule at standard text size. It owns presentation only, not gestures or scrolling; larger text expands naturally. Native List rows retain 44-point targets plus the platform’s 5-point row spacing (`listRowSpacing` is unavailable on watchOS). Cart has no store/count subtitle and a compact floating checkout action. A native bottom `safeAreaInset` and scaled scroll-content clearance let the last row scroll above the controls. Checkout shows the service’s frozen names/quantities and store, then submits the same token. Results report actual outcomes and skipped names; Recently cleared displays owner-scoped recovery actions. Controls remain available for cached offline shopping according to individual service capabilities.

## Production adapter boundary

Implement `WatchShoppingService` on the main actor. Install it in `ShoppingWatchApp` in place of `UnavailableWatchShoppingService`; do not select `WatchPreviewService` in production.

- `load(storeID:)` returns `WatchShoppingSnapshot`: active stores, valid selected store, preordered eligible grocery/cart sections, owner recovery operations, and capabilities. Nil selection may restore a service-owned last valid selection. Invalid/archived stores return no selected store; never widen to All stores. Grocery and cart ordering/filtering are service responsibilities.
- `execute(_:)` handles add, owner removal, owner quantity, and explicit buy-anyway commands. Each item’s opaque token identifies the validated account binding, household/list/occurrence, immutable cart-membership generation and causal evidence. The UI never supplies an owner ID or derives ownership from `Person`. Account switches invalidate tokens. Reject stale/unauthorized tokens before writes.
- `captureCheckout(storeID:)` durably captures the exact scope and returns a token plus frozen display rows. `checkout(token:)` revalidates and applies only that capture. The UI retains a failed preview and retries the same token; never rerun a broad cart query under that token.
- `restore(token:)` addresses the original owner-qualified receipts and returns actual restored/skipped/pending outcomes. Both checkout and restore return `WatchActionResult` with the new durable snapshot, human-readable status and skipped names.
- `onChange(.dataChanged)` notifies the session after durable imports. The session reloads its current scope, coalescing notifications during an active command. Before an account/authority transition, synchronously send `.authorityInvalidated`: the session immediately clears the old snapshot/sheets and discards any stale async completion before reloading. Each ready snapshot includes an opaque `authorityID`, stable across ordinary imports but different for another account/authorization epoch. Non-ready snapshots and changed authority IDs also clear captured/result presentations. Foreground activation also reloads. The previous durable snapshot remains visible after failed commands; errors are surfaced without optimistic row removal.
- Capability flags are per action. Keep availability ready while a private cart remains readable, even if household publication is revoked; reserve unavailable for the absence of a usable snapshot. Stores also links to your retained cart when no valid store is selected. An inaccessible household can still permit private owner removal/history while prohibiting publication. `statusMessage` reflects observed state and never treats phone unreachability as offline or a history token as synchronization proof. Presence remains informational and may be stale.

All snapshot identity strings must be stable across refreshes. An orphaned cart entry still needs its own presentation ID; it cannot disappear merely because its need is unavailable. `canCheckout` is service-owned and must exclude unresolved purchase notices; the preview can contain fewer rows than the visible cart. No watch view reproduces persistence or purchase-eligibility rules.

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

The watch scheme owns session boundary tests and native UI tests; they do not join or alter the iPhone Fast coverage collection. Tests use a new in-memory preview service per launch; they never access the real household. `SHOPPING_WATCH_FIXTURE=populated`, `empty`, `longNames`, `fullCart`, `saveFailure`, `loading`, or `unavailable` selects explicit DEBUG-only fixtures. Release builds exclude fixtures. Xcode previews also show purchase notices and partial checkout results.

Session tests cover setup-only normal launch, failed-save snapshot retention, opaque commands, captured checkout retry, invalid store capture, authority invalidation during a suspended checkout, and offline owner removal/recovery. UI tests cover normal launch, full-title store switching, native swipe/cart flow, purchase notice choice, captured checkout and recovery. Simulator screenshots and accessibility-tree assertions are local presentation evidence only. UI tests exercise simulated Digital Crown scrolling; physical VoiceOver, physical Crown handling, Reduce Motion, oldest supported runtime, signing/install distribution, and real sync remain device/integration acceptance work.

Local validation on September 24, 2026: the Series 11 46mm simulator passed all eight session tests and six native UI tests. The 42mm simulator also passed the full suite before the final compact toolbar adjustment, followed by focused store-switching, large-text, and footer-clearance checks. Generic iOS Simulator embedding and Release watchOS Simulator builds succeeded. These checks validate the native shell and injected fixtures, not production persistence or cross-device synchronization.

## First-party guidance

- [Building a watchOS app](https://developer.apple.com/documentation/watchos-apps/building_a_watchos_app)
- [Creating independent watchOS apps](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps)
- [SwiftUI swipe actions](https://developer.apple.com/documentation/swiftui/view/swipeactions(edge:allowsfullswipe:content:))
- [SwiftUI safe area inset](https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)-6gwby)

The installed SDK confirms these native APIs at the watchOS 10 minimum. The target opts into `WKRunsIndependentlyOfCompanionApp`; that installation capability does not itself implement independent account bootstrap or prove shopping without the phone.
