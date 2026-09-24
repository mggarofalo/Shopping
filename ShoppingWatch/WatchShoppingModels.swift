import Foundation

// Presentation values only. The service owns eligibility, ordering, identity and authorization.
struct WatchStore: Identifiable, Equatable {
    let id: UUID
    let name: String
    var mustBuyCount = 0
    var canBuyCount = 0
}

struct WatchItemSection: Identifiable, Equatable {
    let id: String
    let title: String
    var items: [WatchShoppingItem]
}

struct WatchShoppingItem: Identifiable, Equatable {
    // Stable presentation identity, including orphaned cart memberships.
    let id: String
    let commandToken: String
    let name: String
    var quantity: Int?
    let rule: WatchPurchaseRule?
    var isInOwnCart: Bool
    var isUrgent = false
    var notes = ""
    var isOneTime = false
    var otherCarts: [WatchCartPresence] = []
    var purchasedNotice: String?
    var unavailableReason: String?
    var canAdd = false
    var canRemove = false
    var canChangeQuantity = false
    var canBuyAnyway = false

    var accessibilityValue: String {
        [quantity.map { "Quantity \($0)" }, rule?.title,
         isUrgent ? "Urgent" : nil,
         isInOwnCart ? "In your cart" : nil,
         otherCarts.isEmpty ? nil : "Also in another shopper’s cart",
         purchasedNotice, unavailableReason]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

enum WatchPurchaseRule: Equatable {
    case onlyHere, canBuyHere

    var symbol: String { self == .onlyHere ? "lock.fill" : "lock.open.fill" }
    var title: String { self == .onlyHere ? "Only buy here" : "Can buy here" }
}

struct WatchCartPresence: Identifiable, Equatable {
    let id: String
    let shopperName: String
    let quantity: Int?
}

struct WatchShoppingSnapshot: Equatable {
    enum Availability: Equatable {
        case ready
        case loading
        case setupRequired(String)
        case unavailable(String)
    }

    // Opaque account/household authorization epoch. Stable across ordinary imports.
    var authorityID: String?
    var availability: Availability = .loading
    var stores: [WatchStore] = []
    var selectedStoreID: UUID?
    var grocerySections: [WatchItemSection] = []
    var cartSections: [WatchItemSection] = []
    var recentCheckouts: [WatchRecoveryOperation] = []
    var canCheckout = false
    // Observed status, not inferred from phone reachability. Offline does not disable commands.
    var statusMessage: String?

    var selectedStore: WatchStore? { stores.first { $0.id == selectedStoreID } }
    var cartCount: Int { cartSections.reduce(0) { $0 + $1.items.count } }
    var cartCountText: String { "\(cartCount) \(cartCount == 1 ? "item" : "items")" }
    func item(id: String) -> WatchShoppingItem? {
        (cartSections + grocerySections).lazy.flatMap(\.items).first { $0.id == id }
    }
}

enum WatchShoppingCommand: Equatable {
    // Tokens are minted/revalidated by the service. No caller-selected shopper identity.
    case add(token: String, quantity: Int?)
    case remove(token: String)
    case setQuantity(token: String, quantity: Int?)
    case buyAnyway(token: String)
}

struct WatchCheckoutPreview: Identifiable, Equatable {
    let id: UUID
    let token: String
    let storeName: String
    let rows: [WatchCheckoutRow]
    var itemCountText: String { "\(rows.count) \(rows.count == 1 ? "item" : "items")" }
}

struct WatchCheckoutRow: Identifiable, Equatable {
    let id: String
    let name: String
    let quantity: Int?
}

struct WatchRecoveryOperation: Identifiable, Equatable {
    let id: UUID
    let token: String
    let storeName: String
    let summary: String
    let canRestore: Bool
}

struct WatchActionResult: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String
    let skippedNames: [String]
    let snapshot: WatchShoppingSnapshot
}

// One presentation owner prevents results competing with checkout/store sheets.
enum WatchShoppingSheet: Identifiable {
    case stores
    case checkout(WatchCheckoutPreview)
    case result(WatchActionResult)

    var id: String {
        switch self {
        case .stores: "stores"
        case .checkout(let preview): "checkout.\(preview.id)"
        case .result(let result): "result.\(result.id)"
        }
    }
}
