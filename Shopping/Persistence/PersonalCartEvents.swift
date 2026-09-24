import Foundation

struct PersonalCartEdit: Codable, Equatable {
    enum Action: String, Codable { case add, remove, quantity }
    let id: UUID
    let action: Action
    let snapshot: PersonalCartEntrySnapshot
    let ancestors: Set<UUID>
}

struct PersonalCheckoutIntent: Codable, Equatable {
    let token: PersonalCheckoutToken
    let accepted: Set<UUID>
    let buyAnywayReceiptIDs: Set<UUID>
    let createdAt: Date
}

struct PersonalRestoreIntent: Codable, Equatable {
    let checkoutID: UUID
    let restoredNeedIDs: Set<UUID>
}

struct HouseholdDemandEvent: Codable, Equatable {
    let id: UUID
    let householdID: UUID
    let listID: UUID
    let needID: UUID
    let replaces: Set<UUID>
    let ancestors: Set<UUID>
    let archived: Bool
    let quantity: Int64?
    let notes: String
    let urgency: String
    let title: String
}

struct HouseholdPurchaseEvent: Codable, Equatable {
    let id: UUID
    let checkoutID: UUID
    let shopperID: UUID
    let householdID: UUID
    let listID: UUID
    let capture: PersonalCheckoutCapture
}

struct HouseholdRetractionEvent: Codable, Equatable {
    let id: UUID
    let receiptIDs: Set<UUID>
}

struct HouseholdPresenceEvent: Codable, Equatable {
    let id: UUID
    let shopperID: UUID
    let householdID: UUID
    let listID: UUID
    let needID: UUID
    let quantity: Int64?
    let generation: UUID
    let evidence: Set<UUID>
    let removed: Bool
}

struct PersonalCartCommandResult: Codable, Equatable {
    let edit: PersonalCartEdit?
    let skipped: Bool
}

enum PersonalCartCommand: Codable, Equatable {
    case cart(needID: UUID, householdID: UUID, listID: UUID)
    case uncart(PersonalCartEntryToken)
    case quantity(PersonalCartEntryToken, Int64?)
    case checkout(PersonalCheckoutToken, Set<UUID>)
    case restore(UUID)
}
