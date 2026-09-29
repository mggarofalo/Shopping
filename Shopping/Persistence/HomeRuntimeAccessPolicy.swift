import CoreData

extension PersonalCartRepository {
    func nativeAccessIdentity(for home: Household) throws -> HomeNativeAccessIdentity? {
        guard let store = home.objectID.persistentStore else { return nil }
        guard persistence.role(of: store) == .participantShared else { return nil }
        guard persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              let cloud = persistence.container as? NSPersistentCloudKitContainer,
              let list = home.groceryList, list.household == home, list.objectID.persistentStore === store,
              let storeID = store.identifier else { throw PersonalCartError.unavailable }
        guard home.id != PersistenceModel.unsetID, list.id != PersistenceModel.unsetID else { throw PersonalCartError.unavailable }
        let lists = GroceryList.fetchRequest()
        lists.predicate = NSPredicate(format: "id == %@", list.id as CVarArg)
        guard try context.count(for: lists) == 1 else { throw PersonalCartError.unavailable }
        let shares = try cloud.fetchShares(matching: [home.objectID, list.objectID])
        guard let share = shares[home.objectID], shares[list.objectID]?.recordID == share.recordID else {
            throw PersonalCartError.unavailable
        }
        return HomeNativeAccessIdentity(scope: homeEffectScope(householdID: home.id, listID: list.id),
            storeIdentifier: storeID, rootURI: home.objectID.uriRepresentation().absoluteString,
            share: HomeEffectShare(recordName: share.recordID.recordName,
                zoneName: share.recordID.zoneID.zoneName, zoneOwnerName: share.recordID.zoneID.ownerName))
    }

    func nativePublicationAllowed(householdID: UUID, listID: UUID) throws -> Bool {
        let home = try household(householdID)
        guard home.groceryList?.id == listID else { throw PersonalCartError.unavailable }
        guard let identity = try nativeAccessIdentity(for: home) else { return true }
        guard let provider = persistence.personalCartSessionProvider as? ShopperSessionProvider,
              case .ready(let verified) = provider.state, verified == session,
              let cloud = persistence.container as? NSPersistentCloudKitContainer,
              cloud.canUpdateRecord(forManagedObjectWith: home.objectID) else { return false }
        return persistence.homeNativeAccess.permitsPublication(identity)
    }

    func nativeCommandAccess(for home: Household) throws -> HomeNativeAccessGate.Access? {
        guard let identity = try nativeAccessIdentity(for: home) else { return nil }
        return persistence.homeNativeAccess.observedAccess(identity)
    }
}
