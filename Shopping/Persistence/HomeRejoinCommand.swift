import CoreData
import Foundation

/// One explicit Open action captures the complete loss boundary before fetching
/// membership. Reopening the same inbox entry after a later loss gets a new ID.
struct HomeRejoinCommand: Equatable, Sendable {
    let entryID: UUID
    let identity: HomeNativeAccessIdentity
    let observedBlockIDs: Set<UUID>

    var grant: HomeAccessRecord {
        let scope = identity.scope, share = identity.share
        let fields = [entryID.uuidString, scope.accountBinding, scope.containerIdentifier, scope.environment,
            scope.householdID.uuidString, scope.listID.uuidString, identity.storeIdentifier, identity.rootURI,
            share.recordName, share.zoneName, share.zoneOwnerName] + observedBlockIDs.map(\.uuidString).sorted()
        let encoded = try! JSONEncoder().encode(fields) // Strings are always encodable.
        return HomeAccessRecord(id: PersonalCartCoding.stableID("explicit-home-rejoin", encoded.base64EncodedString()),
            scope: scope, share: share, action: .joined(observedBlockIDs: observedBlockIDs))
    }
}

extension PersonalCartService {
    func captureHomeRejoin(entryID: UUID, identity: HomeNativeAccessIdentity,
        verifier: any HomeRejoinVerifying) throws -> HomeRejoinCommand {
        try transact(save: false) { repository in
            guard entryID != PersistenceModel.unsetID else { throw PersonalCartError.corruptRecord }
            try repository.validateRejoinGraph(identity)
            try verifier.validate(identity, in: repository)
            try HomeJoinGate.requireAllowed(repository: repository, share: identity.share)
            let access = try repository.homeEffectAccess(householdID: identity.scope.householdID, listID: identity.scope.listID)
            guard access.hasCompleteBoundary else { throw HomeLeaveError.privateHistoryPending }
            return HomeRejoinCommand(entryID: entryID, identity: identity, observedBlockIDs: access.blockIDs)
        }
    }

    /// The caller must refresh native membership after capture, validate its UI
    /// choice again, and retain the zone turn through this transaction.
    func commitHomeRejoin(_ command: HomeRejoinCommand, verifier: any HomeRejoinVerifying,
        choiceAuthority: UICommandAuthority? = nil) throws {
        try transact(additionalAuthority: choiceAuthority) { repository in
            let identity = command.identity
            try repository.validateRejoinGraph(identity)
            try verifier.validate(identity, in: repository)
            try HomeJoinGate.requireAllowed(repository: repository, share: identity.share)
            let access = try repository.homeEffectAccess(householdID: identity.scope.householdID, listID: identity.scope.listID)
            guard access.hasCompleteBoundary, access.blockIDs == command.observedBlockIDs,
                  access.currentGrants.allSatisfy({ $0.share == identity.share }) else { throw PersonalCartError.scopeChanged }
            let grant = command.grant
            try grant.validate()
            try repository.insert(id: grant.id, kind: "homeAccess", command: grant, value: grant)
        }
    }
}

private extension PersonalCartRepository {
    func validateRejoinGraph(_ identity: HomeNativeAccessIdentity) throws {
        let scope = identity.scope
        guard scope == homeEffectScope(householdID: scope.householdID, listID: scope.listID) else {
            throw PersonalCartError.accountChanged
        }
        let home = try household(scope.householdID)
        guard let store = home.objectID.persistentStore,
              persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              store.identifier == identity.storeIdentifier,
              home.objectID.uriRepresentation().absoluteString == identity.rootURI,
              let list = home.groceryList, list.household == home, list.id == scope.listID,
              list.objectID.persistentStore === store else { throw PersonalCartError.scopeChanged }
        let request = GroceryList.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", scope.listID as CVarArg)
        guard try context.count(for: request) == 1 else { throw PersonalCartError.scopeChanged }
    }
}
