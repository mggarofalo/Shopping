import CoreData

/// Adds retained causal evidence in the same transaction as each actual need mutation.
enum HouseholdDemandJournal {
    static func captureChanges(in context: NSManagedObjectContext, persistence: PersistenceController) throws {
        let keys: Set<String> = ["revision", "quantity", "notes", "urgency", "archived", "title", "kind", "item", "list",
                                 "oneTimeAnyStore", "oneTimeStores", "oneTimeCategory", "person"]
        let needs = context.insertedObjects.union(context.updatedObjects).compactMap { $0 as? Need }
        for need in needs {
            guard context.insertedObjects.contains(need) || !keys.isDisjoint(with: need.changedValues().keys),
                  need.id != PersistenceModel.unsetID,
                  let list = need.list, let household = list.household,
                  let store = household.objectID.persistentStore else { continue }
            let existing = try PersonalCartRepository.sharedValues(
                HouseholdDemandEvent.self, kind: "demand", householdID: household.id, in: context
            )
            let ancestors = Set(existing.values.filter { $0.needID == need.id }.map(\.id))
            var replaces: Set<UUID> = []
            if context.insertedObjects.contains(need), let item = need.item {
                let request = Need.fetchRequest()
                request.predicate = NSPredicate(format: "item == %@ AND list == %@ AND id != %@", item, list, need.id as CVarArg)
                let previous = try context.fetch(request)
                let fulfilled = try PersonalDemandProjection.fulfilledNeedIDs(householdID: household.id, persistence: persistence, in: context)
                replaces = Set(previous.filter { $0.archived || fulfilled.contains($0.id) }.map(\.id))
            }
            let id = UUID()
            let event = HouseholdDemandEvent(id: id, householdID: household.id, listID: list.id,
                                            needID: need.id, replaces: replaces, ancestors: ancestors, archived: need.archived,
                                            quantity: need.quantity, notes: need.notes, urgency: need.urgency, title: need.title)
            let record = HouseholdCartRecord(context: context)
            context.assign(record, to: store)
            record.id = id
            record.kind = "demand"
            record.payload = try PersonalCartCoding.encode(event)
            record.household = household
        }
    }
}
