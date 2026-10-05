import CloudKit
import CoreData

/// Core Data owns all sharing writes. No direct record/zone creation or speculative purge.
final class ManagedHomeShareTransport: HomeShareTransport, @unchecked Sendable {
    private let persistence: PersistenceController
    private let authority: UICommandAuthority
    private let backend: any HomeSharingBackend

    init(persistence: PersistenceController, authority: UICommandAuthority, backend: (any HomeSharingBackend)? = nil) {
        self.persistence = persistence
        self.authority = authority
        self.backend = backend ?? NativeHomeSharingBackend(persistence: persistence)
    }

    func existingShare(for scope: ActiveHomeScope) async throws -> HomeShareIdentity? {
        let store = try environment(scope)
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            _ = try self.environment(scope)
            let (root, objects) = try self.graph(scope, store: store, context: context)
            let share = try self.knownShare(root: root, objects: objects, backend: self.backend)
            try self.validatePrivateExclusion(backend: self.backend, context: context)
            _ = try self.environment(scope)
            return try share.map { try self.identity(of: $0) }
        }
    }

    func createShare(for scope: ActiveHomeScope) async throws -> HomeShareIdentity {
        let store = try environment(scope)
        let saved = try await backend.create(store: store,
            authorize: { _ = try self.environment(scope) }, prepareGraph: { context in
                _ = try self.environment(scope)
                let (root, objects) = try self.graph(scope, store: store, context: context)
                try self.validatePrivateExclusion(backend: self.backend, context: context)
                let existing = try self.knownShare(root: root, objects: objects, backend: self.backend)
                _ = try self.environment(scope)
                return HomeBackendCreation(rootID: root.objectID, title: root.name, existing: existing)
            })
        _ = try environment(scope)
        return try identity(of: saved)
    }

    private func environment(_ scope: ActiveHomeScope) throws -> NSPersistentStore {
        try authority.validate()
        guard let provider = persistence.personalCartSessionProvider else { throw HomeSharingError.unavailable }
        let session = try provider.currentSession()
        guard session.accountBinding == scope.accountBinding,
              session.containerIdentifier == scope.containerIdentifier, session.environment == scope.environment,
              persistence.personalCartInitialBinding == scope.accountBinding else { throw HomeSharingError.scopeChanged }
        let environment: (NSPersistentStore, PersistenceStoreRole)
        do { environment = try backend.environment(scope: scope) }
        catch HomeMembershipError.shareUnavailable { throw HomeSharingError.unavailable }
        catch HomeMembershipError.scopeChanged { throw HomeSharingError.scopeChanged }
        let (store, role) = environment
        guard role == .ownerPrivate, store.identifier == scope.graph.storeIdentifier,
              persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }) else {
            throw HomeSharingError.ownerRequired
        }
        return store
    }

    private func graph(_ scope: ActiveHomeScope, store: NSPersistentStore,
                       context: NSManagedObjectContext) throws -> (Household, [NSManagedObject]) {
        if let provider = persistence.personalCartSessionProvider {
            let repository = PersonalCartRepository(persistence: persistence, context: context, session: try provider.currentSession())
            guard try !repository.isHomeDeleted(householdID: scope.graph.householdID, listID: scope.graph.listID) else {
                throw HomeSharingError.scopeChanged
            }
        }
        guard let uri = URL(string: scope.graph.rootURI),
              let id = persistence.container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri),
              id.persistentStore == store,
              let root = try context.existingObject(with: id) as? Household,
              root.id == scope.graph.householdID else { throw HomeSharingError.scopeChanged }
        let roots = Household.fetchRequest()
        roots.predicate = NSPredicate(format: "id == %@", scope.graph.householdID as CVarArg)
        let lists = GroceryList.fetchRequest()
        lists.predicate = NSPredicate(format: "id == %@", scope.graph.listID as CVarArg)
        guard try context.count(for: roots) == 1, try context.count(for: lists) == 1 else {
            throw HomeShareGraphValidator.Failure.ambiguousIdentity
        }
        return (root, try HomeShareGraphValidator.objects(root: root, listID: scope.graph.listID, in: context))
    }

    private func knownShare(root: Household, objects: [NSManagedObject], backend: any HomeSharingBackend) throws -> HomeBackendShare? {
        let shares = try backend.associatedShares(objects.map(\.objectID))
        guard let share = shares[root.objectID] else {
            guard shares.isEmpty else { throw HomeSharingError.associationPending }
            return nil
        }
        _ = try identity(of: share)
        guard shares.values.allSatisfy({ $0.identity == share.identity }) else { throw HomeSharingError.conflictingShare }
        return share
    }

    private func validatePrivateExclusion(backend: any HomeSharingBackend, context: NSManagedObjectContext) throws {
        for name in ["PersonalCartRecord", "LegacyCartReview"] {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: name)
            request.resultType = .managedObjectIDResultType
            let ids = try context.fetch(request)
            guard try backend.associatedShares(ids).isEmpty else { throw HomeShareGraphValidator.Failure.privateObject }
        }
    }

    private func identity(of share: HomeBackendShare) throws -> HomeShareIdentity {
        guard share.participants.first(where: { $0.id == share.currentParticipantID })?.role == .owner else { throw HomeSharingError.ownerRequired }
        guard share.publicPermission == .none else { throw HomeSharingError.unexpectedPublicAccess }
        return share.identity
    }
}
