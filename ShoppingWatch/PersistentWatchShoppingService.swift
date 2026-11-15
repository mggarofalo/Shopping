import Foundation
import os

@MainActor
final class PersistentWatchShoppingService: WatchShoppingService {
    enum LoadRecoveryPolicy: Sendable {
        case localReplay, verifiedBackgroundReplay
    }
    private struct LoadedValues: Sendable {
        let projection: WatchPersistentProjection
        let own: [PersonalCartEntrySnapshot]
        let outstanding: Set<UUID>
        let presence: [PersonalCartPresenceSnapshot]
        let history: [PersonalCheckoutHistoryEntry]
        let importPending: Bool
        let recoveryMessage: String?
        let savedSelection: Selection?
    }

    var onChange: (@MainActor (WatchServiceChange) -> Void)?
    private let bootstrap: WatchPersistenceBootstrap?
    private var cart: PersonalCartService?
    private var provider: (any ShopperSessionProviding)?
    private let preferredHouseholdID: UUID?
    private let loadRecoveryPolicy: LoadRecoveryPolicy?
    private var selectionURL: URL?
    private var selectedStoreID: UUID?
    private var authorityID: String?
    private var epoch = UUID()
    private var lastSnapshot = WatchShoppingSnapshot()
    private var rows: RowContext?
    // Counts local receipts patched into lastSnapshot. Reads no longer exclude commits.
    private var receiptRevision = 0
    private var startupError: Error?
    private var currentAttention: String?
    private lazy var presencePublisher = PersonalCartPresencePublisher(delay: presenceDelay) { [weak self] needIDs in
        guard let cart = self?.cart else { return [] }
        return await BlockingWriterWork.run(qos: .utility) {
            let signpostID = OSSignpostID(log: WatchPerformanceTrace.log)
            os_signpost(.begin, log: WatchPerformanceTrace.log, name: "Watch presence batch", signpostID: signpostID)
            defer { os_signpost(.end, log: WatchPerformanceTrace.log, name: "Watch presence batch", signpostID: signpostID) }
            var succeeded: Set<UUID> = []
            for id in needIDs {
                do { try cart.republishPresence(needIDs: [id]); succeeded.insert(id) }
                catch { /* Retain this need without blocking other homes. */ }
            }
            return succeeded
        }
    }
    private let presenceDelay: Duration

    static func production() -> PersistentWatchShoppingService {
        do { return PersistentWatchShoppingService(bootstrap: try WatchPersistenceBootstrap()) }
        catch { return PersistentWatchShoppingService(error: error) }
    }

    init(persistence: PersistenceController, sessionProvider: any ShopperSessionProviding,
         preferredHouseholdID: UUID? = nil, selectionURL: URL? = nil,
         cartService: PersonalCartService? = nil,
         loadRecoveryPolicy: LoadRecoveryPolicy? = nil, presenceDelay: Duration = .seconds(2)) {
        bootstrap = nil
        cart = cartService ?? PersonalCartService(persistence: persistence, sessionProvider: sessionProvider)
        provider = sessionProvider
        self.preferredHouseholdID = preferredHouseholdID
        self.selectionURL = selectionURL
        self.loadRecoveryPolicy = loadRecoveryPolicy
        self.presenceDelay = presenceDelay
    }

    private init(bootstrap: WatchPersistenceBootstrap) {
        self.bootstrap = bootstrap
        presenceDelay = .seconds(2)
        preferredHouseholdID = nil
        loadRecoveryPolicy = nil
        bootstrap.onAuthorityInvalidated = { [weak self] in self?.invalidateAuthority() }
        bootstrap.onDataChanged = { [weak self] in self?.onChange?(.dataChanged) }
        bootstrap.onSyncChanged = { [weak self] _ in
            guard let self, let bootstrap = self.bootstrap else { return }
            self.onChange?(.syncChanged(bootstrap.syncStatus(additionalMessage: self.currentAttention)))
        }
    }

    private init(error: Error) {
        presenceDelay = .seconds(2)
        bootstrap = nil
        preferredHouseholdID = nil
        loadRecoveryPolicy = nil
        startupError = error
    }

    func refreshHomeAccess() { bootstrap?.refreshHomeAccess() }

    func invalidateAuthority() {
        if authorityID != nil { onChange?(.authorityInvalidated) }
        presencePublisher.invalidate()
        authorityID = nil
        epoch = UUID()
        lastSnapshot = WatchShoppingSnapshot()
        currentAttention = nil
        selectedStoreID = nil
        if bootstrap != nil { cart = nil; provider = nil; selectionURL = nil }
    }

    private func resolve() async throws -> (PersonalCartService, ShopperSession) {
        if let startupError { throw startupError }
        if let bootstrap {
            let runtime = try await bootstrap.runtime()
            cart = runtime.cart
            provider = runtime.provider
            selectionURL = runtime.selectionURL
        }
        guard let cart, let provider else { throw PersonalCartError.unavailable }
        do {
            let session = try provider.currentSession()
            guard session.accountBinding == cart.initialAccountBinding else { throw PersonalCartError.accountChanged }
            return (cart, session)
        }
        catch { invalidateAuthority(); throw error }
    }

    func load(storeID: UUID?) async throws -> WatchShoppingSnapshot {
        let cart: PersonalCartService
        let session: ShopperSession
        do { (cart, session) = try await resolve() }
        catch {
            let message = (error as? ShopperSessionError)?.errorDescription
                ?? (error as? PersonalCartError)?.errorDescription
                ?? "Saved shopping data could not be opened. Relaunch Shopping to retry; your data is retained."
            return WatchShoppingSnapshot(availability: .setupRequired(message))
        }
        presencePublisher.retry()
        // A store choice supersedes any read already in flight for the previous store.
        if let storeID, storeID != selectedStoreID { receiptRevision += 1 }
        let revision = receiptRevision
        guard try provider?.currentSession() == session else { throw PersonalCartError.accountChanged }
        let preferredHouseholdID = self.preferredHouseholdID
        let selectionURL = self.selectionURL
        let recoveryPolicy = loadRecoveryPolicy ?? (cart.persistence.configuration.isManaged
            ? .verifiedBackgroundReplay : .localReplay)
        let loaded = try await BlockingWriterWork.run { [cart] () throws -> LoadedValues? in
            let signpostID = OSSignpostID(log: WatchPerformanceTrace.log)
            os_signpost(.begin, log: WatchPerformanceTrace.log, name: "Watch snapshot read", signpostID: signpostID)
            defer { os_signpost(.end, log: WatchPerformanceTrace.log, name: "Watch snapshot read", signpostID: signpostID) }
            let saved = selectionURL.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode(Selection.self, from: $0) }
            let savedHousehold = saved?.accountBinding == session.accountBinding ? saved?.householdID : nil
            var recoveryMessage: String?
            // Managed outbox replay belongs to the independent verified-access
            // pass. Local-only stores have no native permission preflight.
            if recoveryPolicy == .localReplay {
                do { try cart.resumePending() }
                catch { recoveryMessage = "Saved cart available. Some household changes are waiting to sync." }
            }
            guard let projection = try WatchPersistentProjection.read(cart: cart,
                preferredHouseholdID: preferredHouseholdID ?? savedHousehold) else { return nil }
            let scope = projection.scope
            let own = try cart.entries(householdID: scope.householdID, listID: scope.listID)
            // Records still arriving withhold only what they describe: groceries or
            // saved purchases. The cart, its edits and checkout stay available.
            let outstanding = try? cart.outstandingNeedIDs(householdID: scope.householdID, listID: scope.listID)
            let history = try? cart.history(householdID: scope.householdID, listID: scope.listID)
            // Presence is advisory and never affects capabilities.
            let presence = (try? cart.presence(householdID: scope.householdID, listID: scope.listID)) ?? []
            return LoadedValues(projection: projection, own: own, outstanding: outstanding ?? [],
                presence: presence, history: history ?? [], importPending: outstanding == nil || history == nil,
                recoveryMessage: recoveryMessage, savedSelection: saved)
        }
        guard self.cart === cart, try provider?.currentSession() == session else {
            throw PersonalCartError.accountChanged
        }
        guard let loaded else {
            currentAttention = nil
            return WatchShoppingSnapshot(availability: .setupRequired(bootstrap?.householdWaitingMessage
                ?? "Waiting for your household to sync from iCloud. Accept a household invitation or finish setup on your iPhone."))
        }
        let projection = loaded.projection
        var selected = selectedStoreID
        if selected == nil, let saved = loaded.savedSelection,
           saved.accountBinding == session.accountBinding, saved.householdID == projection.scope.householdID {
            selected = saved.storeID
        }
        if let storeID { selected = storeID }
        if !projection.stores.contains(where: { $0.id == selected }) { selected = nil }
        let own = loaded.own
        let outstanding = loaded.outstanding
        let presence = loaded.presence
        let writable = projection.writable
        let nextAuthority = "\(session.accountBinding)|\(projection.scope.householdID)|\(writable)|\(epoch)"
        if let authorityID, authorityID != nextAuthority { onChange?(.authorityInvalidated) }
        authorityID = nextAuthority
        let activeStores = Set(projection.stores.map(\.id))
        let buyAnywayCaptures: [UUID: PersonalCheckoutToken]
        if writable, let selected {
            buyAnywayCaptures = await BlockingWriterWork.run { [cart] in
                var captures: [UUID: PersonalCheckoutToken] = [:]
                for entry in own where !entry.purchaseNotices.isEmpty {
                    captures[entry.id] = try? cart.prepareCheckout(tokens: [entry.token], storeID: selected)
                }
                return captures
            }
        } else {
            buyAnywayCaptures = [:]
        }
        let rows = RowContext(authorityID: nextAuthority, accountBinding: session.accountBinding,
            projection: projection, selectedStoreID: selected, activeStores: activeStores, writable: writable,
            presence: presence, outstanding: outstanding, buyAnywayCaptures: buyAnywayCaptures)
        let ownIDs = Set(own.map(\.needID))
        // Store choices summarize all remaining occurrences, independent of the selected store.
        let pending = projection.needs.filter { outstanding.contains($0.needID) && !ownIDs.contains($0.needID) }
        let counts = StorePurchaseCounts.summarize(pending.map { entry in
            StorePurchaseCountOccurrence(id: entry.needID, rule: PurchaseRuleValue(
                explicitStoreIDs: entry.storeIDs, anyStore: entry.anyStore,
                hasResolvedIdentity: entry.purchaseRulesResolved
            ))
        }, activeStoreIDs: activeStores)
        let stores = projection.stores.map { store in
            var value = store
            let count = counts[store.id] ?? StorePurchaseCounts()
            value.mustBuyCount = count.mustBuyCount
            value.canBuyCount = count.canBuyCount
            return value
        }
        let grocery = projection.needs.filter {
            !ownIDs.contains($0.needID) && rows.isGrocery($0, outstanding: outstanding.contains($0.needID))
        }
        let visibleCart = own.filter(rows.isShownInCart)
        let operations = try loaded.history.map { operation in
            try rows.recoveryOperation(id: operation.id, storeName: operation.storeName,
                purchasedCount: operation.entries.count, restored: operation.restored,
                pendingPublication: operation.pendingPublication)
        }
        let attention = !writable ? "Household changes are unavailable. Your personal cart and purchases are saved."
            : loaded.importPending ? "Some household items are still arriving. Your cart is saved."
            : loaded.recoveryMessage
        currentAttention = attention
        var snapshot = try WatchShoppingSnapshot(authorityID: nextAuthority, availability: .ready,
            homeName: projection.homeName, stores: stores, selectedStoreID: selected,
            grocerySections: projection.sections(grocery) { try rows.item($0, inCart: false) },
            cartSections: projection.sections(visibleCart) { try rows.item($0, inCart: true) },
            recentCheckouts: operations,
            statusMessage: attention ?? bootstrap?.accountStatusMessage,
            syncStatus: bootstrap?.syncStatus(additionalMessage: attention)
                ?? WatchSyncStatus(attentionMessages: [attention].compactMap { $0 }))
        snapshot.canCheckout = snapshot.hasCheckoutRows
        // A read that overlapped a local commit may predate its receipt. Checkout and
        // later receipts use lastSnapshot, so keep the receipt until a clean read.
        // Only a current read commits selection, rows and the saved choice.
        guard revision == receiptRevision else { return snapshot }
        selectedStoreID = selected
        lastSnapshot = snapshot
        self.rows = rows
        if let selectionURL {
            let selection = Selection(accountBinding: session.accountBinding, householdID: projection.scope.householdID,
                storeID: selected)
            if selection != loaded.savedSelection {
                try await BlockingWriterWork.run(qos: .utility) {
                    try FileManager.default.createDirectory(at: selectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(selection).write(to: selectionURL, options: .atomic)
                }
            }
        }
        return snapshot
    }

    func execute(_ command: WatchShoppingCommand) async throws -> WatchShoppingSnapshot {
        let result = try await commit(command)
        if case .snapshot(let snapshot) = result { return snapshot }
        return try await load(storeID: selectedStoreID)
    }

    /// Acknowledges the local durable edit, independently of derived household
    /// presence, complete projections, and CloudKit's system-managed export.
    func commit(_ command: WatchShoppingCommand) async throws -> WatchShoppingCommit {
        let signpostID = OSSignpostID(log: WatchPerformanceTrace.log)
        os_signpost(.begin, log: WatchPerformanceTrace.log, name: "Watch local commit", signpostID: signpostID)
        defer { os_signpost(.end, log: WatchPerformanceTrace.log, name: "Watch local commit", signpostID: signpostID) }
        let opaque: String
        switch command {
        case .add(let token, _), .remove(let token), .setQuantity(let token, _), .buyAnyway(let token): opaque = token
        }
        let token = try WatchTokenCoding.decode(WatchCommandToken.self, opaque)
        let (cart, session) = try await resolve()
        try validate(authority: token.authorityID, binding: token.accountBinding, session: session)
        guard lastSnapshot.item(id: token.needID.uuidString) != nil else { throw PersonalCartError.staleEntry }
        // Receipt rows come from the read that minted this token; check before writing.
        guard let rows, rows.authorityID == token.authorityID else { throw PersonalCartError.scopeChanged }
        let receipt: PersonalCartReceipt
        switch command {
        case .add(_, let quantity):
            try requireSelectedStore(token.storeID, rows: rows)
            guard token.membership == nil else { throw PersonalCartError.staleEntry }
            // The durable command checks the active store, eligibility, demand and
            // household access in its own writer transaction.
            receipt = try await BlockingWriterWork.run {
                try cart.cart(needID: token.needID, householdID: token.householdID, listID: token.listID,
                    initialQuantity: quantity.map(Int64.init), expectedStoreID: token.storeID, operationID: token.operationID,
                    presencePolicy: .deferred)
            }
        case .remove:
            guard let membership = token.membership else { throw PersonalCartError.staleEntry }
            receipt = try await BlockingWriterWork.run {
                try cart.uncart(membership, operationID: token.operationID, presencePolicy: .deferred)
            }
        case .setQuantity(_, let quantity):
            guard let membership = token.membership else { throw PersonalCartError.staleEntry }
            receipt = try await BlockingWriterWork.run {
                try cart.setQuantity(quantity.map(Int64.init), token: membership, operationID: token.operationID, presencePolicy: .deferred)
            }
        case .buyAnyway:
            try requireSelectedStore(token.storeID, rows: rows)
            guard let membership = token.membership, !token.acknowledgedReceipts.isEmpty else { throw PersonalCartError.staleEntry }
            guard let capture = token.buyAnywayCapture, capture.entries == [membership] else { throw PersonalCartError.staleEntry }
            try validate(authority: token.authorityID, binding: token.accountBinding, session: session)
            let result = try await BlockingWriterWork.run {
                try cart.checkout(capture, buyAnywayReceiptIDs: token.acknowledgedReceipts, operationID: token.operationID,
                                  effects: .deferred)
            }
            result.purchasedNeedIDs.forEach(presencePublisher.markDirty)
            guard result.purchasedCount > 0 else { throw PersonalCartError.purchasedNoticeRequired }
            try validate(authority: token.authorityID, binding: token.accountBinding, session: session)
            return .snapshot(try patchCheckout(result, storeName: capture.storeName, rows: rows))
        }
        try validate(authority: token.authorityID, binding: token.accountBinding, session: session)
        presencePublisher.markDirty(token.needID)
        // The receipt is read in the command's own transaction, so no other edit can
        // intervene. Only this operation's exact successor may authorize a queued edit.
        let entry = receipt.entry
        let mayRebase: Bool
        if case .remove = command {
            mayRebase = entry == nil
        } else {
            mayRebase = receipt.successor != nil && entry?.token == receipt.successor
        }
        let row: WatchShoppingItem?
        if let entry {
            row = try rows.item(entry, inCart: true)
        } else if let need = rows.listNeed(token.needID) {
            // Without a membership the occurrence returns to groceries from local
            // state, never from a later full read or an import.
            row = try rows.item(need, inCart: false)
        } else {
            row = nil
        }
        patchLocalReceipt(occurrenceID: token.needID.uuidString, row: row)
        return .item(occurrenceID: token.needID.uuidString, item: row, mayRebase: mayRebase)
    }

    /// Purchased rows leave the cart, and the checkout joins recovery, from its own
    /// outcome, as on the iPhone. Its receipts publish later; a later read confirms.
    private func patchCheckout(_ outcome: PersonalCheckoutOutcome, storeName: String?,
                               rows: RowContext) throws -> WatchShoppingSnapshot {
        let rows = rows.outstanding(removing: outcome.purchasedNeedIDs)
        self.rows = rows
        for needID in outcome.purchasedNeedIDs {
            lastSnapshot.replaceItem(occurrenceID: needID.uuidString, with: nil, section: nil)
        }
        let operation = try rows.recoveryOperation(id: outcome.operationID, storeName: storeName,
            purchasedCount: outcome.purchasedCount, restored: false, pendingPublication: true)
        lastSnapshot.recentCheckouts.removeAll { $0.id == operation.id }
        lastSnapshot.recentCheckouts.insert(operation, at: 0)
        return patchedResult()
    }

    /// A read that began before a patched result must not replace it.
    private func patchedResult() -> WatchShoppingSnapshot {
        receiptRevision += 1
        if let bootstrap { lastSnapshot.syncStatus = bootstrap.syncStatus(additionalMessage: currentAttention) }
        return lastSnapshot
    }

    private func patchLocalReceipt(occurrenceID: String, row: WatchShoppingItem?) {
        let source = (lastSnapshot.cartSections + lastSnapshot.grocerySections)
            .first { $0.items.contains { $0.occurrenceID == occurrenceID } }
        lastSnapshot.replaceItem(occurrenceID: occurrenceID, with: row, section: source)
        receiptRevision += 1
    }

    /// Captures from the receipt-patched snapshot, never a full read.
    func captureCheckout(storeID: UUID) async throws -> WatchCheckoutPreview {
        let (cart, session) = try await resolve()
        guard let capturedAuthority = authorityID, let rows = self.rows,
              rows.authorityID == capturedAuthority else { throw PersonalCartError.scopeChanged }
        try requireSelectedStore(storeID, rows: rows)
        try await requirePublication(cart, scope: rows.scope)
        try validate(authority: capturedAuthority, binding: session.accountBinding, session: session)
        let cartRows = lastSnapshot.cartSections.flatMap(\.items).filter(\.isCheckoutReady)
        let tokens = try cartRows.map { row -> PersonalCartEntryToken in
            let token = try WatchTokenCoding.decode(WatchCommandToken.self, row.commandToken)
            guard let membership = token.membership else { throw PersonalCartError.staleEntry }
            return membership
        }
        let capture = try await BlockingWriterWork.run {
            try cart.prepareCheckout(tokens: tokens, storeID: storeID)
        }
        try validate(authority: capturedAuthority, binding: session.accountBinding, session: session)
        let token = WatchCheckoutToken(authorityID: capturedAuthority, capture: capture)
        return WatchCheckoutPreview(id: capture.id, token: try WatchTokenCoding.encode(token),
            storeName: capture.storeName ?? lastSnapshot.selectedStore?.name ?? "Store",
            rows: capture.captures.map { WatchCheckoutRow(id: $0.entry.id.uuidString,
                name: $0.entry.title, quantity: $0.entry.quantity.flatMap(Int.init(exactly:))) })
    }

    func checkout(token: String) async throws -> WatchActionResult {
        let captured = try WatchTokenCoding.decode(WatchCheckoutToken.self, token)
        let (cart, session) = try await resolve()
        try validate(authority: captured.authorityID, binding: captured.capture.accountBinding, session: session)
        guard let rows, rows.authorityID == captured.authorityID else { throw PersonalCartError.scopeChanged }
        try requireSelectedStore(captured.capture.storeID, rows: rows)
        try await requirePublication(cart, scope: rows.scope)
        try validate(authority: captured.authorityID, binding: captured.capture.accountBinding, session: session)
        let outcome = try await BlockingWriterWork.run {
            try cart.checkout(captured.capture, operationID: captured.capture.id, effects: .deferred)
        }
        outcome.purchasedNeedIDs.forEach(presencePublisher.markDirty)
        try validate(authority: captured.authorityID, binding: captured.capture.accountBinding, session: session)
        let snapshot = try patchCheckout(outcome, storeName: captured.capture.storeName, rows: rows)
        return WatchActionResult(id: outcome.operationID, title: "Checkout saved",
            message: "\(outcome.purchasedCount) purchased.\(outcome.pendingPublication ? " Household update will sync later." : "")",
            skippedNames: captured.capture.captures.filter { outcome.skippedNeedIDs.contains($0.entry.needID) }.map(\.entry.title),
            snapshot: snapshot)
    }

    func restore(token: String) async throws -> WatchActionResult {
        let captured = try WatchTokenCoding.decode(WatchRestoreToken.self, token)
        let (cart, session) = try await resolve()
        try validate(authority: captured.authorityID, binding: captured.accountBinding, session: session)
        guard var rows, rows.authorityID == captured.authorityID else { throw PersonalCartError.scopeChanged }
        guard lastSnapshot.recentCheckouts.contains(where: { $0.id == captured.checkoutID && $0.canRestore }) else {
            throw PersonalCartError.permissionDenied
        }
        try await requirePublication(cart, scope: PersonalCartScopeSnapshot(householdID: captured.householdID,
            listID: captured.listID))
        try validate(authority: captured.authorityID, binding: captured.accountBinding, session: session)
        let (history, result, entries) = try await BlockingWriterWork.run {
            let history = try cart.history(householdID: captured.householdID, listID: captured.listID)
            let result = try cart.restore(checkoutID: captured.checkoutID, operationID: captured.operationID, effects: .deferred)
            // The restored memberships, from the local cart alone.
            let entries = try cart.entries(householdID: captured.householdID, listID: captured.listID)
            return (history, result, entries)
        }
        result.purchasedNeedIDs.forEach(presencePublisher.markDirty)
        try validate(authority: captured.authorityID, binding: captured.accountBinding, session: session)
        // Restored needs are outstanding again, so a later removal returns them to groceries.
        rows = rows.outstanding(adding: result.purchasedNeedIDs)
        self.rows = rows
        for entry in entries where result.purchasedNeedIDs.contains(entry.needID) && rows.isShownInCart(entry) {
            lastSnapshot.replaceItem(occurrenceID: entry.needID.uuidString, with: try rows.item(entry, inCart: true),
                section: rows.projection.section(for: entry))
        }
        if let operation = history.first(where: { $0.id == captured.checkoutID }),
           let index = lastSnapshot.recentCheckouts.firstIndex(where: { $0.id == captured.checkoutID }) {
            let accepted = Set(operation.entries.map(\.needID))
            lastSnapshot.recentCheckouts[index] = try rows.recoveryOperation(id: operation.id, storeName: operation.storeName,
                purchasedCount: operation.entries.count,
                restored: !accepted.isEmpty && accepted.isSubset(of: operation.restoredNeedIDs.union(result.purchasedNeedIDs)),
                pendingPublication: true)
        }
        let snapshot = patchedResult()
        return WatchActionResult(id: result.operationID, title: "Restore saved",
            message: "\(result.purchasedCount) restored; \(result.skippedCount) skipped.\(result.pendingPublication ? " Household update will sync later." : "")",
            skippedNames: history.first(where: { $0.id == captured.checkoutID })?.entries
                .filter { result.skippedNeedIDs.contains($0.needID) }.map(\.title) ?? [], snapshot: snapshot)
    }

    private func validate(authority: String, binding: String, session: ShopperSession) throws {
        guard binding == session.accountBinding else { invalidateAuthority(); throw PersonalCartError.accountChanged }
        guard authority == authorityID else { throw PersonalCartError.scopeChanged }
    }

    /// Household commands use the store shown by the snapshot that minted them.
    private func requireSelectedStore(_ storeID: UUID?, rows: RowContext) throws {
        guard let storeID, storeID == rows.selectedStoreID, rows.activeStores.contains(storeID) else {
            throw PersonalCartError.scopeChanged
        }
        guard rows.writable else { throw PersonalCartError.permissionDenied }
    }

    /// Rechecks local durable access only: the ledger and the last finished native
    /// observation. An observation that finished after the snapshot still blocks.
    private func requirePublication(_ cart: PersonalCartService, scope: PersonalCartScopeSnapshot) async throws {
        let permitted = try await BlockingWriterWork.run {
            try cart.transact(save: false) { repository in
                WatchPersistentProjection.mayPublish(repository,
                    household: try? repository.household(scope.householdID), scope: scope)
            }
        }
        guard permitted, self.cart === cart else { throw PersonalCartError.permissionDenied }
    }

    /// One authority for grocery membership and row presentation, shared by full
    /// reads and local receipts so a receipt never needs a full read to be shown.
    private struct RowContext {
        let authorityID: String
        let accountBinding: String
        let projection: WatchPersistentProjection
        let selectedStoreID: UUID?
        let activeStores: Set<UUID>
        let writable: Bool
        let presence: [PersonalCartPresenceSnapshot]
        let outstanding: Set<UUID>
        let buyAnywayCaptures: [UUID: PersonalCheckoutToken]
        private let needs: [UUID: PersonalCartEntrySnapshot]

        init(authorityID: String, accountBinding: String, projection: WatchPersistentProjection, selectedStoreID: UUID?,
             activeStores: Set<UUID>, writable: Bool, presence: [PersonalCartPresenceSnapshot], outstanding: Set<UUID>,
             buyAnywayCaptures: [UUID: PersonalCheckoutToken]) {
            self.authorityID = authorityID
            self.accountBinding = accountBinding
            self.projection = projection
            self.selectedStoreID = selectedStoreID
            self.activeStores = activeStores
            self.writable = writable
            self.presence = presence
            self.outstanding = outstanding
            self.buyAnywayCaptures = buyAnywayCaptures
            needs = Dictionary(projection.needs.map { ($0.needID, $0) }, uniquingKeysWith: { first, _ in first })
        }

        var scope: PersonalCartScopeSnapshot { projection.scope }

        /// The same read after a local checkout or restore changed which needs are outstanding.
        func outstanding(adding added: Set<UUID> = [], removing removed: Set<UUID> = []) -> RowContext {
            RowContext(authorityID: authorityID, accountBinding: accountBinding, projection: projection,
                selectedStoreID: selectedStoreID, activeStores: activeStores, writable: writable, presence: presence,
                outstanding: outstanding.union(added).subtracting(removed), buyAnywayCaptures: buyAnywayCaptures)
        }

        func eligible(_ entry: PersonalCartEntrySnapshot) -> Bool {
            guard selectedStoreID != nil else { return false }
            return PurchaseFilter(selectedStoreID: selectedStoreID).matches(PurchaseRuleValue(explicitStoreIDs: entry.storeIDs,
                anyStore: entry.anyStore, hasResolvedIdentity: entry.purchaseRulesResolved), activeStoreIDs: activeStores)
        }

        /// Groceries hold outstanding, eligible needs outside the shopper's own cart.
        func isGrocery(_ need: PersonalCartEntrySnapshot, outstanding: Bool) -> Bool {
            writable && outstanding && eligible(need)
        }

        /// The grocery a removal returns this need to, as of this read. A later read
        /// corrects demand that changed since, so no receipt waits for one.
        func listNeed(_ needID: UUID) -> PersonalCartEntrySnapshot? {
            needs[needID].flatMap { isGrocery($0, outstanding: outstanding.contains(needID)) ? $0 : nil }
        }

        /// A retained cart stays removable even when its old store or household disappears.
        func isShownInCart(_ entry: PersonalCartEntrySnapshot) -> Bool {
            selectedStoreID == nil || eligible(entry) || !entry.purchaseRulesResolved
                || (!entry.anyStore && entry.storeIDs.isDisjoint(with: activeStores))
        }

        func recoveryOperation(id: UUID, storeName: String?, purchasedCount: Int, restored: Bool,
                               pendingPublication: Bool) throws -> WatchRecoveryOperation {
            let token = WatchRestoreToken(authorityID: authorityID, accountBinding: accountBinding,
                householdID: scope.householdID, listID: scope.listID, checkoutID: id, operationID: UUID())
            return WatchRecoveryOperation(id: id, token: try WatchTokenCoding.encode(token),
                storeName: storeName ?? "Saved purchase",
                summary: restored ? "Purchase restored" : "\(purchasedCount) purchased\(pendingPublication ? " · Sync pending" : "")",
                canRestore: writable && !restored && purchasedCount > 0)
        }

        func item(_ entry: PersonalCartEntrySnapshot, inCart: Bool) throws -> WatchShoppingItem {
            var token = WatchCommandToken(authorityID: authorityID, accountBinding: accountBinding,
                householdID: scope.householdID, listID: scope.listID, needID: entry.needID,
                storeID: selectedStoreID, membership: inCart ? entry.token : nil,
                acknowledgedReceipts: Set(entry.purchaseNotices.map(\.receiptID)), operationID: UUID())
            // A capture names the exact membership it was prepared from. Every edit adds
            // its operation to the token's evidence, so an edited row never matches.
            if inCart && writable && eligible(entry) && !entry.purchaseNotices.isEmpty,
               let capture = buyAnywayCaptures[entry.id], capture.entries == [entry.token] {
                token.buyAnywayCapture = capture
            }
            let filter = PurchaseFilter(selectedStoreID: selectedStoreID)
            let availability = filter.availability(of: PurchaseRuleValue(explicitStoreIDs: entry.storeIDs,
                anyStore: entry.anyStore, hasResolvedIdentity: entry.purchaseRulesResolved), selectedStoreID: selectedStoreID,
                activeStoreIDs: activeStores)
            let rule: WatchPurchaseRule? = availability == .mustBuyHere ? .onlyHere : availability == .flexibleHere ? .canBuyHere : nil
            var row = WatchShoppingItem(id: inCart ? entry.id.uuidString : entry.needID.uuidString,
                commandToken: try WatchTokenCoding.encode(token), name: entry.title,
                quantity: entry.quantity.flatMap(Int.init(exactly:)), rule: rule, isInOwnCart: inCart)
            row.needID = entry.needID.uuidString
            row.isUrgent = entry.urgency == NeedUrgency.urgent.rawValue
            row.notes = entry.notes
            row.isOneTime = projection.oneTimeIDs.contains(entry.needID)
            if inCart, let need = listNeed(entry.needID) {
                row.listReturn = WatchListReturn(quantity: need.quantity.flatMap(Int.init(exactly:)))
            }
            row.otherCarts = presence.filter { $0.needID == entry.needID }.map {
                WatchCartPresence(id: $0.shopperID.uuidString, shopperName: $0.name ?? "Another shopper", quantity: $0.quantity.flatMap(Int.init(exactly:)))
            }
            if !entry.purchaseNotices.isEmpty {
                let names = Set(entry.purchaseNotices.map { $0.purchaserName ?? "another shopper" }).sorted().joined(separator: ", ")
                row.purchasedNotice = "Already purchased by \(names)."
            }
            row.canAdd = !inCart && writable && eligible(entry)
            row.canRemove = inCart
            row.canChangeQuantity = inCart
            row.canBuyAnyway = token.buyAnywayCapture != nil
            if !writable { row.unavailableReason = "Household changes are unavailable. You can still remove your saved cart items." }
            else if !entry.anyStore && entry.storeIDs.isDisjoint(with: activeStores) { row.unavailableReason = "No eligible store is available. You can remove this saved entry." }
            else if !entry.purchaseRulesResolved { row.unavailableReason = "Purchase rules are unavailable. Remove this saved entry or wait for synchronization." }
            else if !entry.demandAvailable && entry.purchaseNotices.isEmpty { row.unavailableReason = "This item is no longer on the household list." }
            return row
        }
    }

    private struct Selection: Codable, Sendable, Equatable {
        let accountBinding: String
        let householdID: UUID
        let storeID: UUID?
    }
}
