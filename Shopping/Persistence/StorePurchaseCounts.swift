import Foundation

struct StorePurchaseCountOccurrence: Equatable, Sendable {
    let id: UUID
    let rule: PurchaseRuleValue
}

struct StorePurchaseCounts: Equatable, Sendable {
    let mustBuyCount: Int
    let canBuyCount: Int

    init(mustBuyCount: Int = 0, canBuyCount: Int = 0) {
        self.mustBuyCount = mustBuyCount
        self.canBuyCount = canBuyCount
    }

    static func summarize(
        _ occurrences: [StorePurchaseCountOccurrence],
        activeStoreIDs: Set<UUID>
    ) -> [UUID: StorePurchaseCounts] {
        var rulesByID: [UUID: PurchaseRuleValue] = [:]
        var conflictingIDs: Set<UUID> = []
        for occurrence in occurrences {
            if let existing = rulesByID[occurrence.id], existing != occurrence.rule {
                conflictingIDs.insert(occurrence.id)
            } else {
                rulesByID[occurrence.id] = occurrence.rule
            }
        }
        let rules = rulesByID.compactMap { id, rule in
            !conflictingIDs.contains(id) && rule.hasResolvedIdentity ? rule : nil
        }
        let filter = PurchaseFilter()
        return Dictionary(uniqueKeysWithValues: activeStoreIDs.map { storeID in
            var mustBuyCount = 0
            var canBuyCount = 0
            for rule in rules {
                switch filter.availability(
                    of: rule, selectedStoreID: storeID, activeStoreIDs: activeStoreIDs
                ) {
                case .mustBuyHere: mustBuyCount += 1
                case .flexibleHere: canBuyCount += 1
                case .unavailable, .needsStore: break
                }
            }
            return (storeID, StorePurchaseCounts(mustBuyCount: mustBuyCount, canBuyCount: canBuyCount))
        })
    }
}
