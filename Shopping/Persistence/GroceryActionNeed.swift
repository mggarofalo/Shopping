import Foundation

/// A scoped active need returned to Siri only after an explicit query or durable add.
struct GroceryActionNeed: Sendable {
    let id: UUID
    let title: String
    let notes: String
    let urgent: Bool
}
