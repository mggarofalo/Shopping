import Foundation

struct GroceryNeedProjection: Sendable {
    let matchingNeedIDs: [UUID]
    let storeCountOccurrences: [StorePurchaseCountOccurrence]
    let activeStoreIDs: Set<UUID>

    func storeCounts(excluding cartedNeedIDs: Set<UUID>) -> [UUID: StorePurchaseCounts] {
        StorePurchaseCounts.summarize(
            storeCountOccurrences.filter { !cartedNeedIDs.contains($0.id) },
            activeStoreIDs: activeStoreIDs
        )
    }
}
