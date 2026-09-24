import CoreData

enum PersonalCartSnapshotBuilder {
    static func make(need: Need, session: ShopperSession, generation: UUID,
                     evidence: Set<UUID>, quantity: Int64?) throws -> PersonalCartEntrySnapshot {
        guard let list = need.list, let household = list.household,
              need.id != PersistenceModel.unsetID else { throw PersonalCartError.unavailable }
        let oneTime = need.kind == NeedKind.oneTime.rawValue
        let item = need.item
        let category = oneTime ? need.oneTimeCategory : item?.category
        let stores = oneTime ? need.oneTimeStores ?? [] : item?.stores ?? []
        var resolved = oneTime || (item != nil && item?.id != PersistenceModel.unsetID
            && item?.household == household && item?.objectID.persistentStore == need.objectID.persistentStore)
        resolved = resolved && stores.allSatisfy { $0.id != PersistenceModel.unsetID && $0.household == household }
        if !oneTime, let item, let context = need.managedObjectContext {
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
            request.fetchLimit = 2
            resolved = try resolved && context.fetch(request).count == 1
        }
        let anyStore = resolved && ((oneTime ? need.oneTimeAnyStore : item?.anyStore ?? false) || stores.isEmpty)
        return PersonalCartEntrySnapshot(
            title: oneTime ? need.title : item?.name ?? need.title, quantity: quantity, notes: need.notes,
            categoryID: category?.id, categoryName: category?.name,
            categoryOrder: category?.displayOrder ?? Int64.max, urgency: need.urgency,
            anyStore: anyStore, storeIDs: Set(stores.map(\.id)), purchaseRulesResolved: resolved,
            token: PersonalCartEntryToken(accountBinding: session.accountBinding, householdID: household.id,
                                          listID: list.id, needID: need.id, generation: generation, evidence: evidence),
            purchaseNotices: [], demandAvailable: !need.archived && resolved
        )
    }

    static func ruleEvidence(_ need: Need) -> String {
        let oneTime = need.kind == NeedKind.oneTime.rawValue
        let stores = oneTime ? need.oneTimeStores ?? [] : need.item?.stores ?? []
        let parts = stores.map { "\($0.id.uuidString):\($0.isArchived):\($0.revision)" }.sorted()
        return [need.kind, need.item?.id.uuidString ?? "missing", String(need.item?.revision ?? -1),
                String(oneTime ? need.oneTimeAnyStore : need.item?.anyStore ?? false), parts.joined(separator: ",")].joined(separator: "|")
    }

    static func eligible(_ entry: PersonalCartEntrySnapshot, storeID: UUID?) -> Bool {
        guard entry.purchaseRulesResolved else { return false }
        guard let storeID else { return true }
        return entry.anyStore || entry.storeIDs.contains(storeID)
    }
}
