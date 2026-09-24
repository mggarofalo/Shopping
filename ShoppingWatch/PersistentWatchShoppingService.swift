import Foundation

@MainActor
final class PersistentWatchShoppingService: WatchShoppingService {
    var onChange: (@MainActor (WatchServiceChange) -> Void)?
    private let bootstrap: WatchPersistenceBootstrap?
    private var cart: PersonalCartService?
    private var provider: (any ShopperSessionProviding)?
    private let preferredHouseholdID: UUID?
    private let householdWritable: ((UUID) -> Bool)?
    private var selectionURL: URL?
    private var selectedStoreID: UUID?
    private var authorityID: String?
    private var epoch = UUID()
    private var lastSnapshot = WatchShoppingSnapshot()
    private var startupError: Error?
    private var sharedWritable = false
    private var activeHouseholdID: UUID?

    static func production() -> PersistentWatchShoppingService {
        do { return PersistentWatchShoppingService(bootstrap: try WatchPersistenceBootstrap()) }
        catch { return PersistentWatchShoppingService(error: error) }
    }

    init(persistence: PersistenceController, sessionProvider: any ShopperSessionProviding,
         preferredHouseholdID: UUID? = nil, selectionURL: URL? = nil,
         householdWritable: (@MainActor (UUID) -> Bool)? = nil, cartService: PersonalCartService? = nil) {
        bootstrap = nil
        cart = cartService ?? PersonalCartService(persistence: persistence, sessionProvider: sessionProvider)
        provider = sessionProvider
        self.preferredHouseholdID = preferredHouseholdID
        self.selectionURL = selectionURL
        self.householdWritable = householdWritable
    }

    private init(bootstrap: WatchPersistenceBootstrap) {
        self.bootstrap = bootstrap
        preferredHouseholdID = nil
        householdWritable = nil
        bootstrap.onAuthorityInvalidated = { [weak self] in self?.invalidateAuthority() }
        bootstrap.onDataChanged = { [weak self] in self?.onChange?(.dataChanged) }
    }

    private init(error: Error) {
        bootstrap = nil
        preferredHouseholdID = nil
        householdWritable = nil
        startupError = error
    }

    func invalidateAuthority() {
        if authorityID != nil { onChange?(.authorityInvalidated) }
        authorityID = nil
        epoch = UUID()
        lastSnapshot = WatchShoppingSnapshot()
        sharedWritable = false
        activeHouseholdID = nil
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
        var recoveryMessage: String?
        do { try cart.resumePending() }
        catch { recoveryMessage = "Saved cart available. Some household changes are waiting to sync." }
        let saved = selectionURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Selection.self, from: $0) }
        let savedHousehold = saved?.accountBinding == session.accountBinding ? saved?.householdID : nil
        guard let projection = try WatchPersistentProjection.read(cart: cart,
            preferredHouseholdID: preferredHouseholdID ?? savedHousehold, writable: householdWritable) else {
            return WatchShoppingSnapshot(availability: .setupRequired(bootstrap?.householdWaitingMessage
                ?? "Waiting for your household to sync from iCloud. Accept a household invitation or finish setup on your iPhone."))
        }
        activeHouseholdID = projection.scope.householdID
        if selectedStoreID == nil, let selectionURL,
           let data = try? Data(contentsOf: selectionURL), let saved = try? JSONDecoder().decode(Selection.self, from: data),
           saved.accountBinding == session.accountBinding, saved.householdID == projection.scope.householdID {
            selectedStoreID = saved.storeID
        }
        if let storeID { selectedStoreID = storeID }
        if !projection.stores.contains(where: { $0.id == selectedStoreID }) { selectedStoreID = nil }
        let own = try cart.entries(householdID: projection.scope.householdID, listID: projection.scope.listID)
        var outstanding: Set<UUID> = []
        var presence: [PersonalCartPresenceSnapshot] = []
        var sharedAvailable = true
        do {
            outstanding = try cart.outstandingNeedIDs(householdID: projection.scope.householdID, listID: projection.scope.listID)
            presence = try cart.presence(householdID: projection.scope.householdID, listID: projection.scope.listID)
        } catch { sharedAvailable = false }
        let writable = projection.writable && sharedAvailable
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
        let grocery = projection.needs.filter { writable && outstanding.contains($0.needID) && !ownIDs.contains($0.needID) && eligible($0) }
        // A retained cart stays removable even when its old store or household disappears.
        let visibleCart = selectedStoreID == nil ? own : own.filter { eligible($0) || !$0.purchaseRulesResolved || (!$0.anyStore && $0.storeIDs.isDisjoint(with: activeStores)) }
        func item(_ entry: PersonalCartEntrySnapshot, inCart: Bool) throws -> WatchShoppingItem {
            var token = WatchCommandToken(authorityID: nextAuthority, accountBinding: session.accountBinding,
                householdID: projection.scope.householdID, listID: projection.scope.listID, needID: entry.needID,
                storeID: selectedStoreID, membership: inCart ? entry.token : nil,
                acknowledgedReceipts: Set(entry.purchaseNotices.map(\.receiptID)), operationID: UUID())
            if inCart && writable && eligible(entry) && !entry.purchaseNotices.isEmpty {
                token.buyAnywayCapture = try? cart.prepareCheckout(tokens: [entry.token], storeID: selectedStoreID)
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
        let history = try cart.history(householdID: projection.scope.householdID, listID: projection.scope.listID)
        let operations = try history.map { operation in
            let token = WatchRestoreToken(authorityID: nextAuthority, accountBinding: session.accountBinding,
                householdID: projection.scope.householdID, listID: projection.scope.listID,
                checkoutID: operation.id, operationID: UUID())
            return WatchRecoveryOperation(id: operation.id, token: try WatchTokenCoding.encode(token),
                storeName: operation.storeName ?? "Saved purchase",
                summary: operation.restored ? "Purchase restored" : "\(operation.entries.count) purchased\(operation.pendingPublication ? " · Sync pending" : "")",
                canRestore: writable && !operation.restored && !operation.entries.isEmpty)
        }
        let snapshot = try WatchShoppingSnapshot(authorityID: nextAuthority, availability: .ready,
            stores: projection.stores, selectedStoreID: selectedStoreID,
            grocerySections: projection.sections(grocery) { try item($0, inCart: false) },
            cartSections: projection.sections(visibleCart) { try item($0, inCart: true) },
            recentCheckouts: operations,
            canCheckout: writable && selectedStoreID != nil && visibleCart.contains { eligible($0) && $0.demandAvailable && $0.purchaseNotices.isEmpty },
            statusMessage: !writable ? "Household changes are unavailable. Your personal cart and purchases are saved." : recoveryMessage ?? bootstrap?.accountStatusMessage)
        lastSnapshot = snapshot
        if let selectionURL {
            try FileManager.default.createDirectory(at: selectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Selection(accountBinding: session.accountBinding, householdID: projection.scope.householdID,
                storeID: selectedStoreID)).write(to: selectionURL, options: .atomic)
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
            try requireShared(storeID: token.storeID)
            guard token.membership == nil,
                  let projection = try WatchPersistentProjection.read(cart: cart,
                    preferredHouseholdID: token.householdID, writable: householdWritable),
                  projection.scope.householdID == token.householdID,
                  let need = projection.needs.first(where: { $0.needID == token.needID }),
                  PersonalCartSnapshotBuilder.eligible(need, storeID: token.storeID),
                  try cart.outstandingNeedIDs(householdID: token.householdID, listID: token.listID).contains(token.needID)
            else { throw PersonalCartError.staleEntry }
            try cart.cart(needID: token.needID, householdID: token.householdID, listID: token.listID,
                initialQuantity: quantity.map(Int64.init), expectedStoreID: token.storeID, operationID: token.operationID)
        case .remove:
            guard let membership = token.membership else { throw PersonalCartError.staleEntry }
            try cart.uncart(membership, operationID: token.operationID)
        case .setQuantity(_, let quantity):
            guard let membership = token.membership else { throw PersonalCartError.staleEntry }
            try cart.setQuantity(quantity.map(Int64.init), token: membership, operationID: token.operationID)
        case .buyAnyway:
            try requireShared(storeID: token.storeID)
            guard let membership = token.membership, !token.acknowledgedReceipts.isEmpty else { throw PersonalCartError.staleEntry }
            guard let capture = token.buyAnywayCapture, capture.entries == [membership] else { throw PersonalCartError.staleEntry }
            let result = try cart.checkout(capture, buyAnywayReceiptIDs: token.acknowledgedReceipts, operationID: token.operationID)
            guard result.purchasedCount > 0 else { throw PersonalCartError.purchasedNoticeRequired }
        }
        return try await load(storeID: selectedStoreID)
    }

    func captureCheckout(storeID: UUID) async throws -> WatchCheckoutPreview {
        let (cart, _) = try await resolve()
        try requireShared(storeID: storeID)
        let rows = lastSnapshot.cartSections.flatMap(\.items).filter { $0.purchasedNotice == nil && $0.unavailableReason == nil }
        let tokens = try rows.map { row -> PersonalCartEntryToken in
            let token = try WatchTokenCoding.decode(WatchCommandToken.self, row.commandToken)
            guard let membership = token.membership else { throw PersonalCartError.staleEntry }
            return membership
        }
        let capture = try cart.prepareCheckout(tokens: tokens, storeID: storeID)
        let token = WatchCheckoutToken(authorityID: authorityID!, capture: capture)
        return WatchCheckoutPreview(id: capture.id, token: try WatchTokenCoding.encode(token),
            storeName: capture.storeName ?? lastSnapshot.selectedStore?.name ?? "Store",
            rows: capture.captures.map { WatchCheckoutRow(id: $0.entry.id.uuidString,
                name: $0.entry.title, quantity: $0.entry.quantity.flatMap(Int.init(exactly:))) })
    }

    func checkout(token: String) async throws -> WatchActionResult {
        let captured = try WatchTokenCoding.decode(WatchCheckoutToken.self, token)
        let (cart, session) = try await resolve()
        try validate(authority: captured.authorityID, binding: captured.capture.accountBinding, session: session)
        try requireShared(storeID: captured.capture.storeID)
        let outcome = try cart.checkout(captured.capture, operationID: captured.capture.id)
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
        guard let projection = try WatchPersistentProjection.read(cart: cart,
            preferredHouseholdID: captured.householdID, writable: householdWritable), projection.writable,
            projection.scope.householdID == captured.householdID,
            lastSnapshot.recentCheckouts.contains(where: { $0.id == captured.checkoutID && $0.canRestore }) else {
            throw PersonalCartError.permissionDenied
        }
        let history = try cart.history(householdID: captured.householdID, listID: captured.listID)
        let result = try cart.restore(checkoutID: captured.checkoutID, operationID: captured.operationID)
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

    private func requireShared(storeID: UUID?) throws {
        guard let storeID, storeID == selectedStoreID, lastSnapshot.selectedStore != nil,
              sharedWritable else {
            throw PersonalCartError.permissionDenied
        }
        guard let cart, let projection = try WatchPersistentProjection.read(cart: cart,
            preferredHouseholdID: activeHouseholdID, writable: householdWritable), projection.writable,
            projection.stores.contains(where: { $0.id == storeID }) else { throw PersonalCartError.permissionDenied }
    }

    private struct Selection: Codable {
        let accountBinding: String
        let householdID: UUID
        let storeID: UUID?
    }
}
