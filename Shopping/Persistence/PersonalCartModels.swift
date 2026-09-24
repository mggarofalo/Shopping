import Foundation

struct PersonalCartEntryToken: Codable, Equatable, Hashable, Sendable {
    let accountBinding: String
    let householdID: UUID
    let listID: UUID
    let needID: UUID
    let generation: UUID
    let evidence: Set<UUID>
}

struct PersonalPurchaseNotice: Codable, Equatable, Sendable {
    let receiptID: UUID
    let purchaserName: String?
}

struct PersonalCartEntrySnapshot: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { token.generation }
    var needID: UUID { token.needID }
    var householdID: UUID { token.householdID }
    var listID: UUID { token.listID }
    let title: String
    let quantity: Int64?
    let notes: String
    let categoryID: UUID?
    let categoryName: String?
    let categoryOrder: Int64
    let urgency: String
    let anyStore: Bool
    let storeIDs: Set<UUID>
    let purchaseRulesResolved: Bool
    let token: PersonalCartEntryToken
    let purchaseNotices: [PersonalPurchaseNotice]
    let demandAvailable: Bool
}

struct PersonalCheckoutCapture: Codable, Equatable, Sendable {
    let entry: PersonalCartEntrySnapshot
    let demandEvidence: Set<UUID>
    let purchaseRuleEvidence: String
    let needRevision: Int64
}

struct PersonalCheckoutToken: Codable, Equatable, Sendable {
    let id: UUID
    let accountBinding: String
    let householdID: UUID
    let listID: UUID
    let storeID: UUID?
    let captures: [PersonalCheckoutCapture]
    var storeName: String? = nil
    var entries: [PersonalCartEntryToken] { captures.map(\.entry.token) }
}

struct PersonalCheckoutOutcome: Codable, Equatable, Sendable {
    let operationID: UUID
    let purchasedNeedIDs: Set<UUID>
    let skippedNeedIDs: Set<UUID>
    let pendingPublication: Bool
    var purchasedCount: Int { purchasedNeedIDs.count }
    var skippedCount: Int { skippedNeedIDs.count }
}

struct PersonalCheckoutHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let entries: [PersonalCartEntrySnapshot]
    let storeName: String?
    let restored: Bool
    let restoredNeedIDs: Set<UUID>
    let pendingPublication: Bool
}

struct PersonalCartPresenceSnapshot: Equatable, Sendable {
    let needID: UUID
    let shopperID: UUID
    let quantity: Int64?
    let name: String?
}

enum PersonalCartError: Error, Equatable, LocalizedError {
    case accountChanged, unavailable, scopeChanged, staleEntry, invalidQuantity
    case reusedOperationID, corruptRecord, incompleteImport, purchasedNoticeRequired, permissionDenied

    var errorDescription: String? {
        switch self {
        case .accountChanged: return "Your account changed. Reopen your cart after account setup."
        case .unavailable: return "This item is no longer available. Your saved cart is retained."
        case .scopeChanged: return "The shopping scope changed. Review the cart again."
        case .staleEntry: return "This cart entry changed. Review it and try again."
        case .invalidQuantity: return "Quantity must be between 1 and 99, or unspecified."
        case .reusedOperationID: return "This action identifier was already used for a different action."
        case .corruptRecord: return "Some cart records conflict. Your saved data has been retained."
        case .incompleteImport: return "Cart changes are still arriving. Try again after synchronization."
        case .purchasedNoticeRequired: return "This item was already purchased. Choose Buy anyway to continue."
        case .permissionDenied: return "Household changes are unavailable. Your personal cart is retained."
        }
    }
}

struct PersonalCartScopeSnapshot: Equatable, Hashable, Sendable {
    let householdID: UUID
    let listID: UUID
}
