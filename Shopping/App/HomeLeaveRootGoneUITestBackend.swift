#if DEBUG
import CoreData
import Foundation

/// An explicit isolated presentation fixture. The real leave coordinator retains
/// its intent and checkpoints; only the platform boundary is simulated.
final class HomeLeaveRootGoneUITestBackend: HomeLeaveBackend, @unchecked Sendable {
    private enum Failure: Error { case callbackLost, checkUnavailable }
    static let share = HomeShareIdentity(recordName: "fixture-share", zoneName: "fixture-zone", zoneOwnerName: "fixture-owner")
    private let cart: PersonalCartService

    static func isEnabled(_ environment: [String: String]) -> Bool {
        environment["SHOPPING_UI_TEST_HOME_LEAVE_ROOT_GONE"] == "1"
            && environment["SHOPPING_UI_TEST_ACTIVE_HOMES"] == "1"
            && environment["SHOPPING_UI_TEST_HOME_MEMBERS"] == "contributor"
            && environment["SHOPPING_UI_TEST_STORE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    init(cart: PersonalCartService) { self.cart = cart }

    func validateEnvironment(identity: HomeNativeAccessIdentity, storeURL: URL?) throws -> ShopperSession {
        let session = try cart.sessionProvider.currentSession()
        guard identity.scope == HomeEffectScope(session: session, householdID: identity.scope.householdID,
                listID: identity.scope.listID),
              identity.share == HomeEffectShare(recordName: Self.share.recordName,
                zoneName: Self.share.zoneName, zoneOwnerName: Self.share.zoneOwnerName),
              let store = cart.persistence.primaryStore, store.identifier == identity.storeIdentifier,
              cart.persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              storeURL == nil || store.url?.standardizedFileURL == storeURL?.standardizedFileURL else {
            throw PersonalCartError.scopeChanged
        }
        return session
    }

    func validateMapping(identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws {
        let session = try validateEnvironment(identity: identity, storeURL: nil)
        guard repository.persistence === cart.persistence, repository.session == session else {
            throw PersonalCartError.scopeChanged
        }
        // Exact root/list/store checks remain in ManagedHomeLeaveTransport.
    }

    func membership(identity: HomeNativeAccessIdentity) async throws -> HomeLeaveMembership {
        _ = try validateEnvironment(identity: identity, storeURL: nil)
        return HomeLeaveMembership(share: identity.share, isPrivateShare: true,
            currentParticipant: .init(id: "fixture-current", role: .privateUser,
                acceptance: .accepted, permission: .readWrite), privateParticipantIDs: ["fixture-current"])
    }

    func purge(_ command: HomeLeaveCommand, storeIdentity: ObjectIdentifier) async throws -> HomeLeaveZone {
        try await Task.detached(priority: .utility) { () throws -> HomeLeaveZone in
            _ = try self.validateEnvironment(identity: command.origin, storeURL: command.storeURL)
            guard let store = self.cart.persistence.primaryStore, ObjectIdentifier(store) == storeIdentity else {
                throw PersonalCartError.scopeChanged
            }
            let context = self.cart.persistence.container.newBackgroundContext()
            try context.performAndWait {
                defer { context.reset() }
                let request = Household.fetchRequest()
                request.affectedStores = [store]
                let homes = try context.fetch(request).filter {
                    $0.id == command.origin.scope.householdID
                        && $0.objectID.uriRepresentation().absoluteString == command.origin.rootURI
                }
                guard homes.count == 1, let home = homes.first, let list = home.groceryList,
                      list.id == command.origin.scope.listID, list.household === home,
                      list.objectID.persistentStore === store else { throw PersonalCartError.scopeChanged }
                context.delete(list)
                context.delete(home)
                try context.save()
            }
            // A lost callback must leave the actual submitted checkpoint pending.
            throw Failure.callbackLost
        }.value
    }

    func zoneExists(_ command: HomeLeaveCommand) async throws -> Bool {
        _ = try validateEnvironment(identity: command.origin, storeURL: command.storeURL)
        // A bounded simulated network response makes the user-triggered check
        // visibly distinct from an error retained by an earlier automatic check.
        try await Task.sleep(for: .seconds(3))
        throw Failure.checkUnavailable
    }
}
#endif
