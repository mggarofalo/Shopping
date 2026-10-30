import CoreData

extension PersonalCartRepository {
    func nativeAccessIdentity(for home: Household) throws -> HomeNativeAccessIdentity? {
        try persistence.homeNativeShares.identity(for: home, in: self)
    }

    func nativePublicationAllowed(householdID: UUID, listID: UUID) throws -> Bool {
        let home = try household(householdID)
        guard home.groceryList?.id == listID else { throw PersonalCartError.unavailable }
        guard let identity = try nativeAccessIdentity(for: home) else { return true }
        guard persistence.homeNativeShares.mayPublish(home, in: self) else { return false }
        return persistence.homeNativeAccess.permitsPublication(identity)
    }

    func nativeCommandAccess(for home: Household) throws -> HomeNativeAccessGate.Access? {
        guard let identity = try nativeAccessIdentity(for: home) else { return nil }
        return persistence.homeNativeAccess.observedAccess(identity)
    }
}

/// Native CloudKit facts about an attached participant home. An owned or local
/// home has no native identity. Durable access facts stay in the ledger.
protocol HomeNativeShareSource {
    func identity(for home: Household, in repository: PersonalCartRepository) throws -> HomeNativeAccessIdentity?
    /// The account session is verified and CloudKit lets this device update the home.
    func mayPublish(_ home: Household, in repository: PersonalCartRepository) -> Bool
}

struct CloudKitHomeNativeShareSource: HomeNativeShareSource {
    func identity(for home: Household, in repository: PersonalCartRepository) throws -> HomeNativeAccessIdentity? {
        guard let store = home.objectID.persistentStore else { return nil }
        guard repository.persistence.role(of: store) == .participantShared else { return nil }
        guard repository.persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              let cloud = repository.persistence.container as? NSPersistentCloudKitContainer,
              let list = home.groceryList, list.household == home, list.objectID.persistentStore === store,
              let storeID = store.identifier else { throw PersonalCartError.unavailable }
        guard home.id != PersistenceModel.unsetID, list.id != PersistenceModel.unsetID else { throw PersonalCartError.unavailable }
        let lists = GroceryList.fetchRequest()
        lists.predicate = NSPredicate(format: "id == %@", list.id as CVarArg)
        guard try repository.context.count(for: lists) == 1 else { throw PersonalCartError.unavailable }
        let shares = try cloud.fetchShares(matching: [home.objectID, list.objectID])
        guard let share = shares[home.objectID], shares[list.objectID]?.recordID == share.recordID else {
            throw PersonalCartError.unavailable
        }
        return HomeNativeAccessIdentity(scope: repository.homeEffectScope(householdID: home.id, listID: list.id),
            storeIdentifier: storeID, rootURI: home.objectID.uriRepresentation().absoluteString,
            share: HomeEffectShare(recordName: share.recordID.recordName,
                zoneName: share.recordID.zoneID.zoneName, zoneOwnerName: share.recordID.zoneID.ownerName))
    }

    func mayPublish(_ home: Household, in repository: PersonalCartRepository) -> Bool {
        guard let provider = repository.persistence.personalCartSessionProvider as? ShopperSessionProvider,
              case .ready(let verified) = provider.state, verified == repository.session,
              let cloud = repository.persistence.container as? NSPersistentCloudKitContainer else { return false }
        return cloud.canUpdateRecord(forManagedObjectWith: home.objectID)
    }
}
