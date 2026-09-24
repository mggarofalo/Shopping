import CoreData

/// Owner-private accepted intents participate before shared publication, on the caller's context.
/// Never enters another writer transaction or resets a context during NeedService mutations.
enum PersonalDemandProjection {
    static func fulfilledNeedIDs(householdID: UUID, persistence: PersistenceController,
                                 in context: NSManagedObjectContext, session explicitSession: ShopperSession? = nil) throws -> Set<UUID> {
        var fulfilled = try HouseholdDemandProjection.fulfilledNeedIDs(householdID: householdID, in: context)
        guard let provider = persistence.personalCartSessionProvider else { return fulfilled }
        let session = try explicitSession ?? provider.currentSession()
        if explicitSession == nil && session.accountBinding != persistence.personalCartInitialBinding {
            throw PersonalCartError.accountChanged
        }
        let repository = PersonalCartRepository(persistence: persistence, context: context, session: session)
        let intents = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")
        let restores = try repository.values(PersonalRestoreIntent.self, kind: "restore")
        for (id, intent) in intents where intent.token.householdID == householdID {
            for capture in intent.token.captures where intent.accepted.contains(capture.entry.needID) {
                let needID = capture.entry.needID
                guard !restores.values.contains(where: { $0.checkoutID == id && $0.restoredNeedIDs.contains(needID) }),
                      try HouseholdDemandProjection.evidence(needID: needID, householdID: householdID, in: context) == capture.demandEvidence,
                      try HouseholdDemandProjection.rulesMatch(capture, in: context) else { continue }
                fulfilled.insert(needID)
            }
        }
        return fulfilled
    }
}
