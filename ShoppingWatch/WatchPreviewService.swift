#if DEBUG
import Foundation

/// In-memory interaction fixture only. Never selected by a normal or release launch.
@MainActor
final class WatchPreviewService: WatchShoppingService {
    var onChange: (@MainActor (WatchServiceChange) -> Void)?
    private var value: WatchShoppingSnapshot
    private var items: [WatchShoppingItem]
    private var previews: [String: WatchCheckoutPreview] = [:]
    private var cleared: [String: [WatchShoppingItem]] = [:]
    private let scenario: String
    private var failsNextCheckout = false
    private var failsNextAdd = false
    static let firstStoreID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let secondStoreID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    init(scenario: String = "populated") {
        self.scenario = scenario
        value = Self.sample
        items = Self.sample.grocerySections.flatMap(\.items) + Self.sample.cartSections.flatMap(\.items)
        if scenario == "empty" { items = [] }
        failsNextCheckout = scenario == "saveFailure"
        failsNextAdd = scenario == "addFailure"
        if scenario == "fullCart" || scenario == "saveFailure" {
            for index in items.indices {
                items[index].isInOwnCart = true
                items[index].canAdd = false
                items[index].canRemove = true
                items[index].canChangeQuantity = true
            }
        }
        if scenario == "longNames" {
            items[0] = WatchShoppingItem(id: "bananas", commandToken: "bananas", name: "Organic Fair Trade Cavendish Bananas", quantity: 3, rule: .canBuyHere, isInOwnCart: false, canAdd: true)
        }
    }

    func load(storeID: UUID?) async throws -> WatchShoppingSnapshot {
        if scenario == "unavailable" {
            return WatchShoppingSnapshot(availability: .unavailable("Your saved household could not be opened. Try again."))
        }
        if scenario == "loading" { return WatchShoppingSnapshot() }
        if let storeID { value.selectedStoreID = value.stores.contains { $0.id == storeID } ? storeID : nil }
        rebuild()
        return value
    }

    func execute(_ command: WatchShoppingCommand) async throws -> WatchShoppingSnapshot {
        switch command {
        case .add(let token, let quantity):
            if failsNextAdd {
                failsNextAdd = false
                throw NSError(domain: "WatchPreview", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Preview add failed. Your cart is unchanged. Try again."
                ])
            }
            if let i = items.firstIndex(where: { $0.commandToken == token && $0.canAdd }) {
                items[i].isInOwnCart = true
                items[i].quantity = quantity
                items[i].canAdd = false
                items[i].canRemove = true
                items[i].canChangeQuantity = true
            }
        case .remove(let token):
            if let i = items.firstIndex(where: { $0.commandToken == token && $0.canRemove }) {
                items[i].isInOwnCart = false
                items[i].canAdd = true
                items[i].canRemove = false
                items[i].canChangeQuantity = false
            }
        case .setQuantity(let token, let quantity):
            if let i = items.firstIndex(where: { $0.commandToken == token && $0.canChangeQuantity }) {
                items[i].quantity = quantity
            }
        case .buyAnyway(let token):
            if let i = items.firstIndex(where: { $0.commandToken == token && $0.canBuyAnyway }) {
                items[i].purchasedNotice = nil
                items[i].canBuyAnyway = false
            }
        }
        rebuild()
        return value
    }

    func captureCheckout(storeID: UUID) async throws -> WatchCheckoutPreview {
        let preview = WatchCheckoutPreview(id: UUID(), token: UUID().uuidString,
            storeName: value.selectedStore?.name ?? "Store",
            rows: value.cartSections.flatMap(\.items).filter { $0.purchasedNotice == nil }.map {
                WatchCheckoutRow(id: $0.id, name: $0.name, quantity: $0.quantity)
            })
        previews[preview.token] = preview
        return preview
    }

    func checkout(token: String) async throws -> WatchActionResult {
        if failsNextCheckout {
            failsNextCheckout = false
            throw NSError(domain: "WatchPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Preview save failed. Your cart is unchanged. Try again."])
        }
        guard let preview = previews[token] else { throw fixtureError }
        let ids = Set(preview.rows.map(\.id))
        let removed = items.filter { ids.contains($0.id) && $0.isInOwnCart }
        cleared[token] = removed
        items.removeAll { ids.contains($0.id) }
        let summary = "\(removed.count) \(removed.count == 1 ? "item" : "items") cleared"
        value.recentCheckouts.insert(WatchRecoveryOperation(id: preview.id, token: token, storeName: preview.storeName,
            summary: summary, canRestore: true), at: 0)
        rebuild()
        return WatchActionResult(id: UUID(), title: summary,
            message: "Preview only. Recover these items in Recently cleared.", skippedNames: [], snapshot: value)
    }

    func restore(token: String) async throws -> WatchActionResult {
        guard let restoreItems = cleared.removeValue(forKey: token) else { throw fixtureError }
        items += restoreItems.filter { restored in !items.contains { $0.id == restored.id } }
        value.recentCheckouts.removeAll { $0.token == token }
        rebuild()
        return WatchActionResult(id: UUID(), title: "Items restored", message: "Preview only. Your items are back in your cart.", skippedNames: [], snapshot: value)
    }

    private func rebuild() {
        // Fixed fixture membership, not the production purchase-rule algorithm.
        let eligible = items.filter { value.selectedStoreID == Self.firstStoreID || $0.id != "strawberries" }
        func sections(cart: Bool) -> [WatchItemSection] {
            ["Produce", "Dairy", "Pantry"].compactMap { category in
                let rows = eligible.filter { item in
                    item.isInOwnCart == cart && category == (item.id == "milk" ? "Dairy" : item.id == "granola" ? "Pantry" : "Produce")
                }
                return rows.isEmpty ? nil : WatchItemSection(id: category, title: category, items: rows)
            }
        }
        value.stores = value.stores.map { store in
            var result = store
            let pending = items.filter { !$0.isInOwnCart && $0.purchasedNotice == nil
                && (store.id == Self.firstStoreID || $0.id != "strawberries") }
            result.mustBuyCount = pending.filter { $0.rule == .onlyHere }.count
            result.canBuyCount = pending.filter { $0.rule == .canBuyHere }.count
            return result
        }
        value.grocerySections = sections(cart: false)
        value.cartSections = sections(cart: true)
        value.canCheckout = eligible.contains { $0.isInOwnCart && $0.purchasedNotice == nil }
    }

    private var fixtureError: NSError {
        NSError(domain: "WatchPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "This preview operation is no longer available."])
    }

    static var sample: WatchShoppingSnapshot {
        WatchShoppingSnapshot(authorityID: "preview-shopper", availability: .ready,
            stores: [WatchStore(id: firstStoreID, name: "Trader Joe’s", mustBuyCount: 1, canBuyCount: 2), WatchStore(id: secondStoreID, name: "Costco", canBuyCount: 2)],
            selectedStoreID: firstStoreID,
            grocerySections: [
                WatchItemSection(id: "Produce", title: "Produce", items: [
                    WatchShoppingItem(id: "bananas", commandToken: "bananas", name: "Bananas", quantity: 3, rule: .canBuyHere, isInOwnCart: false, canAdd: true),
                    WatchShoppingItem(id: "strawberries", commandToken: "strawberries", name: "Strawberries", quantity: nil, rule: .onlyHere, isInOwnCart: false, isUrgent: true, canAdd: true)
                ]),
                WatchItemSection(id: "Pantry", title: "Pantry", items: [
                    WatchShoppingItem(id: "granola", commandToken: "granola", name: "Granola", quantity: nil, rule: .canBuyHere, isInOwnCart: false, notes: "Low sugar", canAdd: true)
                ])
            ],
            cartSections: [WatchItemSection(id: "Dairy", title: "Dairy", items: [
                WatchShoppingItem(id: "milk", commandToken: "milk", name: "Oat milk", quantity: 2, rule: .canBuyHere, isInOwnCart: true,
                    otherCarts: [WatchCartPresence(id: "sam", shopperName: "Sam", quantity: 1)],
                    purchasedNotice: "Already purchased by Sam. Keep this entry until you choose Remove or Buy anyway.",
                    canRemove: true, canChangeQuantity: true, canBuyAnyway: true)
            ])], canCheckout: false)
    }

    static func previewSession() -> WatchShoppingSession {
        WatchShoppingSession(service: WatchPreviewService(), initialSnapshot: sample)
    }

    static var previewCheckout: WatchCheckoutPreview {
        WatchCheckoutPreview(id: UUID(), token: "preview", storeName: "Trader Joe’s",
            rows: [WatchCheckoutRow(id: "bananas", name: "Bananas", quantity: 3), WatchCheckoutRow(id: "granola", name: "Granola", quantity: nil)])
    }
}
#endif
