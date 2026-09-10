import CoreData

struct CategoryIntelligenceCandidateSnapshot: Equatable, Sendable {
    let candidates: [CategoryIntelligenceCandidate]

    var rememberedItemCount: Int {
        candidates.reduce(0) { $0 + $1.rememberedItemNames.count }
    }
}

@MainActor
struct CategoryIntelligenceCandidateLoader {
    func load(
        from context: NSManagedObjectContext,
        selection: PersistenceSelection
    ) throws -> CategoryIntelligenceCandidateSnapshot {
        let lists = try context.fetch(PurchaseRulesStoreScope.listsRequest())
        let households = try context.fetch(NavigationFetchRequests.households())
        let canonicalList = GroceryRowScope.canonicalList(
            lists, households: households, selection: selection
        )
        guard canonicalList != nil else {
            throw CategoryIntelligenceError.unavailableHousehold
        }
        let categories = GroceryRowScope.validCategories(
            try context.fetch(NavigationFetchRequests.categories()),
            canonicalList: canonicalList
        ).filter { !$0.isArchived }
        let activeCategoryIDs = Set(categories.map(\.id))
        let items = GroceryRowScope.validItems(
            try context.fetch(NavigationFetchRequests.items()),
            canonicalList: canonicalList
        ).filter {
            !$0.isArchived && $0.category.map { activeCategoryIDs.contains($0.id) } == true
        }
        let itemsByCategoryID = Dictionary(grouping: items) { $0.category?.id }

        return CategoryIntelligenceCandidateSnapshot(candidates: categories.map { category in
            CategoryIntelligenceCandidate(
                id: category.id,
                name: category.name,
                evidence: (itemsByCategoryID[category.id] ?? []).map {
                    .init(name: $0.name, source: .rememberedCatalog)
                }
            )
        })
    }
}
