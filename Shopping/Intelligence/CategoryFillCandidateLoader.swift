import CoreData
import Foundation

struct CategoryFillCandidate: Equatable, Hashable, Sendable {
    let itemID: UUID
    let itemRevision: Int64
    let name: String
}

struct CategoryFillCandidateSnapshot: Equatable, Sendable {
    let categoryID: UUID
    let categoryRevision: Int64
    let categoryName: String
    let candidates: [CategoryFillCandidate]
}

@MainActor
struct CategoryFillCandidateLoader {
    static let maximumCandidateCount = 8

    func load(
        from context: NSManagedObjectContext,
        selection: PersistenceSelection,
        categoryID: UUID,
        purchaseFilter: PurchaseFilter
    ) throws -> CategoryFillCandidateSnapshot {
        let lists = try context.fetch(NavigationFetchRequests.lists())
        let households = try context.fetch(NavigationFetchRequests.households())
        let canonicalList = GroceryRowScope.canonicalList(
            lists, households: households, selection: selection
        )
        guard let canonicalList else { throw CategoryIntelligenceError.unavailableHousehold }

        let categories = GroceryRowScope.validCategories(
            try context.fetch(NavigationFetchRequests.categories()),
            canonicalList: canonicalList
        )
        guard let category = categories.first(where: { $0.id == categoryID && !$0.isArchived }) else {
            throw CategoryIntelligenceError.invalidSuggestedCategory
        }

        let activeItemIDs: Set<UUID> = Set(GroceryRowScope.validNeeds(
            try context.fetch(NavigationFetchRequests.needs()),
            canonicalList: canonicalList
        ).compactMap { need in
            guard !need.archived, need.kind == NeedKind.remembered.rawValue else { return nil }
            return need.item?.id
        })
        let activeStores = GroceryRowScope.validStores(
            try context.fetch(NavigationFetchRequests.stores()),
            canonicalList: canonicalList
        ).filter { !$0.isArchived }
        let activeStoreIDs = Set(activeStores.map(\.id))

        let candidates = GroceryRowScope.validItems(
            try context.fetch(NavigationFetchRequests.items()),
            canonicalList: canonicalList
        ).filter { item in
            guard !item.isArchived, item.category == category, !activeItemIDs.contains(item.id) else {
                return false
            }
            let purchaseRules = PurchaseRuleValue(
                explicitStoreIDs: Set(item.stores?.map(\.id) ?? []),
                anyStore: item.anyStore
            )
            return purchaseFilter.matches(purchaseRules, activeStoreIDs: activeStoreIDs)
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(Self.maximumCandidateCount).map {
            CategoryFillCandidate(itemID: $0.id, itemRevision: $0.revision, name: $0.name)
        }

        return CategoryFillCandidateSnapshot(
            categoryID: category.id,
            categoryRevision: category.revision,
            categoryName: category.name,
            candidates: candidates
        )
    }
}
