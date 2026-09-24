import CoreData

enum HouseholdDemandProjection {
    static func evidence(needID: UUID, householdID: UUID, in context: NSManagedObjectContext) throws -> Set<UUID> {
        let events = try PersonalCartRepository.sharedValues(HouseholdDemandEvent.self, kind: "demand", householdID: householdID, in: context)
        return Set(events.values.filter { $0.needID == needID }.map(\.id))
    }

    static func superseded(householdID: UUID, in context: NSManagedObjectContext) throws -> Set<UUID> {
        let events = try PersonalCartRepository.sharedValues(HouseholdDemandEvent.self, kind: "demand", householdID: householdID, in: context)
        return events.values.reduce(into: Set<UUID>()) { $0.formUnion($1.replaces) }
    }

    static func purchases(householdID: UUID, in context: NSManagedObjectContext) throws -> [HouseholdPurchaseEvent] {
        let receipts = try PersonalCartRepository.sharedValues(HouseholdPurchaseEvent.self, kind: "purchase", householdID: householdID, in: context)
        let retractions = try PersonalCartRepository.sharedValues(HouseholdRetractionEvent.self, kind: "retraction", householdID: householdID, in: context)
        let retracted = retractions.values.reduce(into: Set<UUID>()) { $0.formUnion($1.receiptIDs) }
        return receipts.values.filter { !retracted.contains($0.id) }
    }

    static func rulesMatch(_ capture: PersonalCheckoutCapture, in context: NSManagedObjectContext) throws -> Bool {
        let request = Need.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND list.id == %@ AND list.household.id == %@",
            capture.entry.needID as CVarArg, capture.entry.listID as CVarArg, capture.entry.householdID as CVarArg)
        let needs = try context.fetch(request)
        guard needs.count == 1 else { return false }
        return PersonalCartSnapshotBuilder.ruleEvidence(needs[0]) == capture.purchaseRuleEvidence
    }

    static func fulfilledNeedIDs(householdID: UUID, in context: NSManagedObjectContext) throws -> Set<UUID> {
        let receipts = try purchases(householdID: householdID, in: context)
        var result = try superseded(householdID: householdID, in: context)
        for receipt in receipts {
            let needID = receipt.capture.entry.needID
            if try evidence(needID: needID, householdID: householdID, in: context) == receipt.capture.demandEvidence
                && rulesMatch(receipt.capture, in: context) {
                result.insert(needID)
            }
        }
        return result
    }
}
