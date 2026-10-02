import CoreData

enum PurchaseRuleIdentity {
    static func storesAreResolved(_ stores: Set<Store>, household: Household?) -> Bool {
        guard let household else { return false }
        return stores.allSatisfy {
            $0.id != PersistenceModel.unsetID && $0.household == household
        }
    }
}
