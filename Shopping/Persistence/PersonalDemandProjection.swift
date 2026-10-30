import CoreData

/// Owner-private accepted intents participate before shared publication, on the caller's context.
/// Never enters another writer transaction or resets a context during NeedService mutations.
enum PersonalDemandProjection {
    /// The household rule, which feeds replacement lineage: an own checkout counts
    /// only while this device may publish it.
    static func fulfilledNeedIDs(householdID: UUID, persistence: PersistenceController,
                                 in context: NSManagedObjectContext, session explicitSession: ShopperSession? = nil) throws -> Set<UUID> {
        try fulfilledNeedIDs(householdID: householdID, persistence: persistence, in: context,
                             session: explicitSession) { repository, id, listID in
            try repository.homeEffectMayPublish(kind: .checkout, subjectID: id, householdID: householdID, listID: listID)
        }
    }

    /// The shopper's own groceries and cart: an own checkout counts at once, even
    /// before native verification, while the durable ledger still authorizes it.
    static func shopperFulfilledNeedIDs(householdID: UUID, persistence: PersistenceController,
                                        in context: NSManagedObjectContext, session explicitSession: ShopperSession? = nil) throws -> Set<UUID> {
        try fulfilledNeedIDs(householdID: householdID, persistence: persistence, in: context,
                             session: explicitSession) { repository, id, listID in
            try repository.homeEffectAuthorized(kind: .checkout, subjectID: id, householdID: householdID, listID: listID)
        }
    }

    private static func fulfilledNeedIDs(householdID: UUID, persistence: PersistenceController,
                                         in context: NSManagedObjectContext, session explicitSession: ShopperSession?,
                                         counts: (PersonalCartRepository, UUID, UUID) throws -> Bool) throws -> Set<UUID> {
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
            guard try counts(repository, id, intent.token.listID) else { continue }
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
