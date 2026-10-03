import Foundation

struct GroceryNeedProjection: Sendable {
    let matchingNeedIDs: [UUID]
    let storeCountOccurrences: [StorePurchaseCountOccurrence]
    let activeStoreIDs: Set<UUID>

    /// The authoritative store-wide occurrences, before search/category/urgency narrowing.
    func shareableNeedIDs(for storeID: UUID?, excluding cartedNeedIDs: Set<UUID>) -> Set<UUID> {
        guard let storeID, activeStoreIDs.contains(storeID) else { return [] }
        let filter = PurchaseFilter(selectedStoreID: storeID)
        let groups = Dictionary(grouping: storeCountOccurrences, by: \.id)
        return Set(groups.compactMap { id, occurrences in
            guard !cartedNeedIDs.contains(id), let rule = occurrences.first?.rule,
                  rule.hasResolvedIdentity, occurrences.allSatisfy({ $0.rule == rule }),
                  filter.matches(rule, activeStoreIDs: activeStoreIDs) else { return nil }
            return id
        })
    }

    func storeCounts(excluding cartedNeedIDs: Set<UUID>) -> [UUID: StorePurchaseCounts] {
        StorePurchaseCounts.summarize(
            storeCountOccurrences.filter { !cartedNeedIDs.contains($0.id) },
            activeStoreIDs: activeStoreIDs
        )
    }
}
