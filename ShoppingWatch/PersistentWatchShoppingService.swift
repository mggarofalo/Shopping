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
        let sharedAvailable: Bool
        let history: [PersonalCheckoutHistoryEntry]
        let recoveryMessage: String?
        let savedSelection: Selection?
    }

    var onChange: (@MainActor (WatchServiceChange) -> Void)?
    private let bootstrap: WatchPersistenceBootstrap?
    private var cart: PersonalCartService?
    private var provider: (any ShopperSessionProviding)?
    private let preferredHouseholdID: UUID?
    private let householdWritable: ((UUID) -> Bool)?
    private let loadRecoveryPolicy: LoadRecoveryPolicy?
    private var selectionURL: URL?
    private var selectedStoreID: UUID?
    private var authorityID: String?
    private var epoch = UUID()
    private var lastSnapshot = WatchShoppingSnapshot()
    private var startupError: Error?
    private var sharedWritable = false
    private var activeHouseholdID: UUID?
    private var currentAttention: String?

    static func production() -> PersistentWatchShoppingService {
        do { return PersistentWatchShoppingService(bootstrap: try WatchPersistenceBootstrap()) }
        catch { return PersistentWatchShoppingService(error: error) }
    }

    init(persistence: PersistenceController, sessionProvider: any ShopperSessionProviding,
         preferredHouseholdID: UUID? = nil, selectionURL: URL? = nil,
         householdWritable: (@MainActor (UUID) -> Bool)? = nil, cartService: PersonalCartService? = nil,
         loadRecoveryPolicy: LoadRecoveryPolicy? = nil) {
        bootstrap = nil
        cart = cartService ?? PersonalCartService(persistence: persistence, sessionProvider: sessionProvider)
        provider = sessionProvider
        self.preferredHouseholdID = preferredHouseholdID
        self.selectionURL = selectionURL
        self.householdWritable = householdWritable
        self.loadRecoveryPolicy = loadRecoveryPolicy
    }

    private init(bootstrap: WatchPersistenceBootstrap) {
        self.bootstrap = bootstrap
        preferredHouseholdID = nil
        householdWritable = nil
        loadRecoveryPolicy = nil
        bootstrap.onAuthorityInvalidated = { [weak self] in self?.invalidateAuthority() }
        bootstrap.onDataChanged = { [weak self] in self?.onChange?(.dataChanged) }
        bootstrap.onSyncChanged = { [weak self] _ in
            guard let self, let bootstrap = self.bootstrap else { return }
            self.onChange?(.syncChanged(bootstrap.syncStatus(additionalMessage: self.currentAttention)))
        }
    }

    private init(error: Error) {
        bootstrap = nil
        preferredHouseholdID = nil
        householdWritable = nil
        loadRecoveryPolicy = nil
        startupError = error
    }

    func refreshHomeAccess() { bootstrap?.refreshHomeAccess() }

    func invalidateAuthority() {
        if authorityID != nil { onChange?(.authorityInvalidated) }
        authorityID = nil
        epoch = UUID()
        lastSnapshot = WatchShoppingSnapshot()
        sharedWritable = false
        activeHouseholdID = nil
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
        bootstrap?.retryPendingAssociations()
        guard try provider?.currentSession() == session else { throw PersonalCartError.accountChanged }
        let preferredHouseholdID = self.preferredHouseholdID
        let selectionURL = self.selectionURL
        let recoveryPolicy = loadRecoveryPolicy ?? (cart.persistence.configuration.isManaged
            ? .verifiedBackgroundReplay : .localReplay)
        let loaded = try await Task.detached(priority: .userInitiated) { [cart] () throws -> LoadedValues? in
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
                preferredHouseholdID: preferredHouseholdID ?? savedHousehold, writable: nil) else { return nil }
            let scope = projection.scope
            let own = try cart.entries(householdID: scope.householdID, listID: scope.listID)
            var outstanding: Set<UUID> = []
            var presence: [PersonalCartPresenceSnapshot] = []
            var sharedAvailable = true
            do {
                outstanding = try cart.outstandingNeedIDs(householdID: scope.householdID, listID: scope.listID)
                presence = try cart.presence(householdID: scope.householdID, listID: scope.listID)
            } catch { sharedAvailable = false }
            let history = try cart.history(householdID: scope.householdID, listID: scope.listID)
            return LoadedValues(projection: projection, own: own, outstanding: outstanding,
                presence: presence, sharedAvailable: sharedAvailable, history: history,
                recoveryMessage: recoveryMessage, savedSelection: saved)
        }.value
        guard self.cart === cart, try provider?.currentSession() == session else {
            throw PersonalCartError.accountChanged
        }
        guard let loaded else {
            currentAttention = nil
            return WatchShoppingSnapshot(availability: .setupRequired(bootstrap?.householdWaitingMessage
                ?? "Waiting for your household to sync from iCloud. Accept a household invitation or finish setup on your iPhone."))
        }
        let projection = loaded.projection
        activeHouseholdID = projection.scope.householdID
        if selectedStoreID == nil, let saved = loaded.savedSelection,
           saved.accountBinding == session.accountBinding, saved.householdID == projection.scope.householdID {
            selectedStoreID = saved.storeID
        }
        if let storeID { selectedStoreID = storeID }
        if !projection.stores.contains(where: { $0.id == selectedStoreID }) { selectedStoreID = nil }
        let own = loaded.own
        let outstanding = loaded.outstanding
        let presence = loaded.presence
        let writable = projection.writable && loaded.sharedAvailable &&
            (householdWritable?(projection.scope.householdID) ?? true)
        sharedWritable = writable
        let nextAuthority = "\(session.accountBinding)|\(projection.scope.householdID)|\(writable)|\(epoch)"
        if let authorityID, authorityID != nextAuthority { onChange?(.authorityInvalidated) }
        authorityID = nextAuthority
        let activeStores = Set(projection.stores.map(\.id))
        let filter = PurchaseFilter(selectedStoreID: selectedStoreID)
        func eligible(_ entry: PersonalCartEntrySnapshot) -> Bool {
            guard selectedStoreID != nil else { return false }
            return filter.matches(PurchaseRuleValue(explicitStoreIDs: entry.storeIDs, anyStore: entry.anyStore,
                hasResolvedIdentity: entry.purchaseRulesResolved), activeStoreIDs: activeStores)
        }
        let ownIDs = Set(own.map(\.needID))
        // Store choices summarize all remaining occurrences, independent of the selected store.
        let pending = projection.needs.filter { $0.purchaseRulesResolved && outstanding.contains($0.needID) && !ownIDs.contains($0.needID) }
        let stores = projection.stores.map { store in
            var value = store
            var counted: Set<UUID> = []
            for entry in pending where counted.insert(entry.needID).inserted {
                let rule = PurchaseRuleValue(explicitStoreIDs: entry.storeIDs, anyStore: entry.anyStore,
                    hasResolvedIdentity: entry.purchaseRulesResolved)
                switch filter.availability(of: rule, selectedStoreID: store.id, activeStoreIDs: activeStores) {
                case .mustBuyHere: value.mustBuyCount += 1
                case .flexibleHere: value.canBuyCount += 1
                default: break
                }
            }
            return value
        }
        let grocery = projection.needs.filter { writable && outstanding.contains($0.needID) && !ownIDs.contains($0.needID) && eligible($0) }
        // A retained cart stays removable even when its old store or household disappears.
        let visibleCart = selectedStoreID == nil ? own : own.filter { eligible($0) || !$0.purchaseRulesResolved || (!$0.anyStore && $0.storeIDs.isDisjoint(with: activeStores)) }
        let buyAnywayCaptures: [UUID: PersonalCheckoutToken]
        if writable, let selectedStoreID {
            buyAnywayCaptures = await Task.detached(priority: .userInitiated) { [cart] in
                var captures: [UUID: PersonalCheckoutToken] = [:]
                for entry in own where !entry.purchaseNotices.isEmpty {
                    captures[entry.id] = try? cart.prepareCheckout(tokens: [entry.token], storeID: selectedStoreID)
                }
                return captures
            }.value
        } else {
            buyAnywayCaptures = [:]
        }
        func item(_ entry: PersonalCartEntrySnapshot, inCart: Bool) throws -> WatchShoppingItem {
            var token = WatchCommandToken(authorityID: nextAuthority, accountBinding: session.accountBinding,
                householdID: projection.scope.householdID, listID: projection.scope.listID, needID: entry.needID,
                storeID: selectedStoreID, membership: inCart ? entry.token : nil,
                acknowledgedReceipts: Set(entry.purchaseNotices.map(\.receiptID)), operationID: UUID())
            if inCart && writable && eligible(entry) && !entry.purchaseNotices.isEmpty {
                token.buyAnywayCapture = buyAnywayCaptures[entry.id]
            }
            let availability = filter.availability(of: PurchaseRuleValue(explicitStoreIDs: entry.storeIDs,
                anyStore: entry.anyStore, hasResolvedIdentity: entry.purchaseRulesResolved), selectedStoreID: selectedStoreID,
                activeStoreIDs: activeStores)
            let rule: WatchPurchaseRule? = availability == .mustBuyHere ? .onlyHere : availability == .flexibleHere ? .canBuyHere : nil
            var row = WatchShoppingItem(id: inCart ? entry.id.uuidString : entry.needID.uuidString,
                commandToken: try WatchTokenCoding.encode(token), name: entry.title,
                quantity: entry.quantity.flatMap(Int.init(exactly:)), rule: rule, isInOwnCart: inCart)
            row.isUrgent = entry.urgency == NeedUrgency.urgent.rawValue
            row.notes = entry.notes
            row.isOneTime = projection.oneTimeIDs.contains(entry.needID)
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
        let operations = try loaded.history.map { operation in
            let token = WatchRestoreToken(authorityID: nextAuthority, accountBinding: session.accountBinding,
                householdID: projection.scope.householdID, listID: projection.scope.listID,
                checkoutID: operation.id, operationID: UUID())
            return WatchRecoveryOperation(id: operation.id, token: try WatchTokenCoding.encode(token),
                storeName: operation.storeName ?? "Saved purchase",
                summary: operation.restored ? "Purchase restored" : "\(operation.entries.count) purchased\(operation.pendingPublication ? " · Sync pending" : "")",
                canRestore: writable && !operation.restored && !operation.entries.isEmpty)
        }
        let attention = !writable ? "Household changes are unavailable. Your personal cart and purchases are saved." : loaded.recoveryMessage
        currentAttention = attention
        let snapshot = try WatchShoppingSnapshot(authorityID: nextAuthority, availability: .ready,
            homeName: projection.homeName, stores: stores, selectedStoreID: selectedStoreID,
            grocerySections: projection.sections(grocery) { try item($0, inCart: false) },
            cartSections: projection.sections(visibleCart) { try item($0, inCart: true) },
            recentCheckouts: operations,
            canCheckout: writable && selectedStoreID != nil && visibleCart.contains { eligible($0) && $0.demandAvailable && $0.purchaseNotices.isEmpty },
            statusMessage: attention ?? bootstrap?.accountStatusMessage,
            syncStatus: bootstrap?.syncStatus(additionalMessage: attention)
                ?? WatchSyncStatus(attentionMessages: [attention].compactMap { $0 }))
        lastSnapshot = snapshot
        if let selectionURL {
            let selection = Selection(accountBinding: session.accountBinding, householdID: projection.scope.householdID,
                storeID: selectedStoreID)
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: selectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(selection).write(to: selectionURL, options: .atomic)
            }.value
        }
        return snapshot
    }

    func execute(_ command: WatchShoppingCommand) async throws -> WatchShoppingSnapshot {
        let opaque: String
        switch command {
        case .add(let token, _), .remove(let token), .setQuantity(let token, _), .buyAnyway(let token): opaque = token
        }
        let token = try WatchTokenCoding.decode(WatchCommandToken.self, opaque)
        let (cart, session) = try await resolve()
        try validate(authority: token.authorityID, binding: token.accountBinding, session: session)
        switch command {
        case .add(_, let quantity):
            try await requireShared(storeID: token.storeID)
            guard token.membership == nil else { throw PersonalCartError.staleEntry }
            let valid = try await Task.detached(priority: .userInitiated) { () -> Bool in
                guard let projection = try WatchPersistentProjection.read(cart: cart,
                    preferredHouseholdID: token.householdID, writable: nil),
                    projection.scope.householdID == token.householdID,
                    let need = projection.needs.first(where: { $0.needID == token.needID }),
                    PersonalCartSnapshotBuilder.eligible(need, storeID: token.storeID) else { return false }
                return try cart.outstandingNeedIDs(householdID: token.householdID, listID: token.listID).contains(token.needID)
            }.value
            guard valid else { throw PersonalCartError.staleEntry }
            try validate(authority: token.authorityID, binding: token.accountBinding, session: session)
            try await Task.detached(priority: .userInitiated) {
                try cart.cart(needID: token.needID, householdID: token.householdID, listID: token.listID,
                    initialQuantity: quantity.map(Int64.init), expectedStoreID: token.storeID, operationID: token.operationID)
            }.value
        case .remove:
            guard let membership = token.membership else { throw PersonalCartError.staleEntry }
            try await Task.detached(priority: .userInitiated) {
                try cart.uncart(membership, operationID: token.operationID)
            }.value
        case .setQuantity(_, let quantity):
            guard let membership = token.membership else { throw PersonalCartError.staleEntry }
            try await Task.detached(priority: .userInitiated) {
                try cart.setQuantity(quantity.map(Int64.init), token: membership, operationID: token.operationID)
            }.value
        case .buyAnyway:
            try await requireShared(storeID: token.storeID)
            guard let membership = token.membership, !token.acknowledgedReceipts.isEmpty else { throw PersonalCartError.staleEntry }
            guard let capture = token.buyAnywayCapture, capture.entries == [membership] else { throw PersonalCartError.staleEntry }
            try validate(authority: token.authorityID, binding: token.accountBinding, session: session)
            let result = try await Task.detached(priority: .userInitiated) {
                try cart.checkout(capture, buyAnywayReceiptIDs: token.acknowledgedReceipts, operationID: token.operationID)
            }.value
            guard result.purchasedCount > 0 else { throw PersonalCartError.purchasedNoticeRequired }
        }
        return try await load(storeID: selectedStoreID)
    }

    func captureCheckout(storeID: UUID) async throws -> WatchCheckoutPreview {
        let (cart, session) = try await resolve()
        guard let capturedAuthority = authorityID else { throw PersonalCartError.scopeChanged }
        try await requireShared(storeID: storeID)
        try validate(authority: capturedAuthority, binding: session.accountBinding, session: session)
        let rows = lastSnapshot.cartSections.flatMap(\.items).filter { $0.purchasedNotice == nil && $0.unavailableReason == nil }
        let tokens = try rows.map { row -> PersonalCartEntryToken in
            let token = try WatchTokenCoding.decode(WatchCommandToken.self, row.commandToken)
            guard let membership = token.membership else { throw PersonalCartError.staleEntry }
            return membership
        }
        let capture = try await Task.detached(priority: .userInitiated) {
            try cart.prepareCheckout(tokens: tokens, storeID: storeID)
        }.value
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
        try await requireShared(storeID: captured.capture.storeID)
        try validate(authority: captured.authorityID, binding: captured.capture.accountBinding, session: session)
        let outcome = try await Task.detached(priority: .userInitiated) {
            try cart.checkout(captured.capture, operationID: captured.capture.id)
        }.value
        let snapshot = try await load(storeID: selectedStoreID)
        return WatchActionResult(id: outcome.operationID, title: "Checkout saved",
            message: "\(outcome.purchasedCount) purchased.\(outcome.pendingPublication ? " Household update will sync later." : "")",
            skippedNames: captured.capture.captures.filter { outcome.skippedNeedIDs.contains($0.entry.needID) }.map(\.entry.title),
            snapshot: snapshot)
    }

    func restore(token: String) async throws -> WatchActionResult {
        let captured = try WatchTokenCoding.decode(WatchRestoreToken.self, token)
        let (cart, session) = try await resolve()
        try validate(authority: captured.authorityID, binding: captured.accountBinding, session: session)
        guard lastSnapshot.recentCheckouts.contains(where: { $0.id == captured.checkoutID && $0.canRestore }) else {
            throw PersonalCartError.permissionDenied
        }
        guard householdWritable?(captured.householdID) ?? true else { throw PersonalCartError.permissionDenied }
        let writable = try await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let projection = try WatchPersistentProjection.read(cart: cart,
                preferredHouseholdID: captured.householdID, writable: nil) else { return false }
            return projection.writable && projection.scope.householdID == captured.householdID
        }.value
        guard writable else { throw PersonalCartError.permissionDenied }
        try validate(authority: captured.authorityID, binding: captured.accountBinding, session: session)
        guard householdWritable?(captured.householdID) ?? true else { throw PersonalCartError.permissionDenied }
        let (history, result) = try await Task.detached(priority: .userInitiated) {
            let history = try cart.history(householdID: captured.householdID, listID: captured.listID)
            let result = try cart.restore(checkoutID: captured.checkoutID, operationID: captured.operationID)
            return (history, result)
        }.value
        let snapshot = try await load(storeID: selectedStoreID)
        return WatchActionResult(id: result.operationID, title: "Restore saved",
            message: "\(result.purchasedCount) restored; \(result.skippedCount) skipped.\(result.pendingPublication ? " Household update will sync later." : "")",
            skippedNames: history.first(where: { $0.id == captured.checkoutID })?.entries
                .filter { result.skippedNeedIDs.contains($0.needID) }.map(\.title) ?? [], snapshot: snapshot)
    }

    private func validate(authority: String, binding: String, session: ShopperSession) throws {
        guard binding == session.accountBinding else { invalidateAuthority(); throw PersonalCartError.accountChanged }
        guard authority == authorityID else { throw PersonalCartError.scopeChanged }
    }

    private func requireShared(storeID: UUID?) async throws {
        guard let storeID, storeID == selectedStoreID, lastSnapshot.selectedStore != nil,
              sharedWritable, let cart,
              activeHouseholdID.flatMap({ householdWritable?($0) }) ?? true else {
            throw PersonalCartError.permissionDenied
        }
        let householdID = activeHouseholdID
        let valid = try await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let projection = try WatchPersistentProjection.read(cart: cart,
                preferredHouseholdID: householdID, writable: nil) else { return false }
            return projection.writable && projection.stores.contains(where: { $0.id == storeID })
        }.value
        guard valid, self.cart === cart else { throw PersonalCartError.permissionDenied }
    }

    private struct Selection: Codable, Sendable {
        let accountBinding: String
        let householdID: UUID
        let storeID: UUID?
    }
}
