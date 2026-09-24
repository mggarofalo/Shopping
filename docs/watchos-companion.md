# watchOS companion

SHOPPING-120/121 supply a native watchOS 10+ target, `ShoppingWatch`, embedded in the iPhone app as an independent companion. It uses the existing app icon and a separate shared scheme. The iPhone scheme and its test plans retain their selections and coverage baseline.

Normal launch uses `PersistentWatchShoppingService`, an account-scoped SQLite replica backed by the same personal-cart engine as iPhone. `WatchPersistenceBootstrap` resolves the actual CloudKit account and attaches managed private/shared stores; it does not create a household when an import has not arrived. No foreground phone or WatchConnectivity transport is required. SHOPPING-103 owns personal-cart semantics; SHOPPING-122 owns real Series 11 phone-left-home acceptance. Enrollment and app-ID/container provisioning are complete, but SHOPPING-10 two-account readiness and SHOPPING-30 live sharing remain gates; local tests do not establish CloudKit convergence.

## Native UI

The entire store title, including the arrows at its right, is a native leading toolbar button that opens Stores. The toolbar reserves room for the system clock instead of placing content under it. The service supplies eligible rows and Settings category order. Rows show a name, optional quantity, urgency, other-shopper presence, and `lock.fill`/`lock.open.fill` for Only buy here/Can buy here. Long names truncate at default size and wrap at accessibility sizes; the card and accessible name always retain the full name. Purchase rules are announced once, not repeated as row prose.

SHOPPING-134 uses small Dynamic Type-scaled category captions above visible native row backgrounds. Store choices show closed/open padlock counts on the trailing side: remaining occurrences that must be bought there, and other remaining occurrences eligible there. These counts cover all stores independently of the current selection, include Any store, exclude the shopper’s own cart and fulfilled/unresolved demand, and retain the canonical archived-store restrictions. Another shopper’s cart is advisory and does not remove demand from these counts. Counts are transient presentation values, not persisted store inventory.

A native `NavigationLink` opens the card. Native trailing `swipeActions` add/remove your cart entry. Cards and named accessibility actions provide the same access. Other shoppers’ quantities are read-only. Missing-demand cart entries can retain a reason and Remove action. A purchase notice requires an explicit Remove or Buy anyway choice. Quantity drafts before Add stay local to the card; a cart quantity command uses the service token for that owner’s membership.

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
