# Shopping

Shopping is a household iOS grocery app for people who buy familiar items at specific stores. It keeps reusable catalog knowledge separate from the groceries currently needed, then shows the same household needs through store-filtered views.

## Planned MVP contract

- One household grocery list will be shared by the user and their wife. A checked grocery will become carted everywhere; it is not copied into a store trip.
- Catalog items remember purchase rules such as `Buy at Costco` or `Any store`. Those tags express where the household chooses to buy an item; they do not assert retailer inventory or rank stores.
- A selected store shows a need only when it is tagged for that store or is `Any store`. `Must buy here` means that store is its sole explicit active tag and the item is not `Any store`; other eligible items are flexible. Filters can narrow this result but cannot broaden it.
- Re-adding a catalog item reuses its saved tags. There is one active remembered need per catalog item during normal use.
- Urgency is a current-need setting (`Normal` or `Urgent`), not catalog knowledge. It cannot override store purchase rules.
- A one-time need is a separate, shareable occurrence. It can be recovered after a clear, but never becomes a catalog item, template, future suggestion, or learned default unless the user explicitly chooses to remember it.
- Clearing carted groceries is scoped, confirmed, and recoverable. It preserves catalog data and must not erase a newer uncart or re-add.

There is no per-store trip, Finish/Reopen flow, event feature, recurring template, pricing engine, or automatic store assignment in the MVP. Pull-to-refresh is a post-MVP exploration tracked in SHOPPING-31.

## Architecture status

The intended MVP baseline is SwiftUI with Core Data and `NSPersistentCloudKitContainer`, using managed private and shared CloudKit stores for household sharing. SwiftData private-device synchronization does not by itself establish this sharing model.

The local architecture decision and experimental persistence harness are recorded in [ADR 0001](docs/architecture/0001-managed-household-persistence.md). The [domain model](docs/domain-model.md) records household metadata, catalog purchase filters, and current-need lifecycle contracts. The app now opens a disk-backed local store with retryable error recovery; the shopping interface is still the initial SwiftUI shell. The [persistence guide](docs/persistence.md) describes the versioned model, store configuration and local history handling. [Preview fixtures and local context simulations](docs/previews.md) support interface work without a live cloud account. Live two-phone proof remains required in SHOPPING-30. Sharing is mandatory for release, but it is not yet proven. Enrollment work in SHOPPING-10 remains a gate for live CloudKit validation; local model, UI, and simulated-replica work can proceed before it.

The available development environment has Xcode 26.6 (17F113) and an iOS 26.5 iPhone 17 Pro runtime. The app targets iOS 17. Local validation uses:

```bash
xcodebuild test -project Shopping.xcodeproj -scheme Shopping -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C'
```

CI pins `macos-15`, `/Applications/Xcode_16.4.app`, and iOS 18.5 on an iPhone 16 Pro. See the CI workflow for its executable command.

## Project guidance

[PLANE.md](PLANE.md) is the source of truth for current work tracking, readiness, modules, and branching. [AGENTS.md](AGENTS.md) explains repository workflow. [LINEAR.md](LINEAR.md) is retained only for historical provenance.
