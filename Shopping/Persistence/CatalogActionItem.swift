import Foundation

/// Immutable remembered-catalog data for system actions, never a managed object.
struct CatalogActionItem: Equatable, Sendable {
    let id: UUID
    let revision: Int64
    let name: String
    let category: String
    let purchaseRules: String
}

enum CatalogActionMatcher {
    static func matches(_ query: String, in items: [CatalogActionItem]) -> [CatalogActionItem] {
        let normalized = CatalogProjection.normalizedName(query)
        guard !normalized.isEmpty else { return [] }
        let exact = items.filter { CatalogProjection.normalizedName($0.name) == normalized }
        let matches = exact.isEmpty ? items.filter { CatalogProjection.textMatches($0.name, query: normalized) } : exact
        return matches.sorted {
            let a = CatalogProjection.normalizedName($0.name), b = CatalogProjection.normalizedName($1.name)
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
    }
}
