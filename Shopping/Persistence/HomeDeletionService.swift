import CoreData
import Foundation

/// Persistence work is confined to the serial writer. Native deletion uses the exact share zone.
final class HomeDeletionService: @unchecked Sendable {
    private let persistence: PersistenceController
    private let cart: PersonalCartService?
    private let backend: (any HomeDeletionBackend)?

    init(persistence: PersistenceController, cart: PersonalCartService? = nil, backend: (any HomeDeletionBackend)? = nil) {
        self.persistence = persistence
        self.cart = cart
        self.backend = backend ?? cart.map { CloudKitHomeDeletionBackend(persistence: persistence, cart: $0) }
    }

    func prepare(graph: HomeGraphIdentity, scope: ActiveHomeScope?, authority: UICommandAuthority? = nil) async throws -> HomeDeletionCommand {
        try authority?.validate()
        if let scope { try validateAccount(scope) }
        let share: HomeEffectShare?
        if let scope { share = try await backend?.share(for: scope) } else { share = nil }
        return try await Task.detached(priority: .userInitiated) {
            try self.persistence.writer.performAndWait {
                let context = self.persistence.writer
                context.reset()
                try authority?.validate()
                let store = try self.store(graph, scope: scope)
                let root = try Self.root(graph, store: store, context: context)
                let objects = try HomeShareGraphValidator.objects(root: root, listID: graph.listID, in: context)
                guard let url = store.url else { throw HomeDeletionError.scopeChanged }
                let target: HomeDeletionCommand.Target = scope.map { .owned(scope: $0, storeURL: url, share: share) }
                    ?? .local(graph: graph, storeURL: url)
                let command = HomeDeletionCommand(id: UUID(), target: target, homeName: root.name, preparedAt: Date(),
                    objectURIs: Set(objects.map { $0.objectID.uriRepresentation().absoluteString }))
                try command.validate()
                return command
            }
        }.value
    }

    func execute(_ command: HomeDeletionCommand, authority: UICommandAuthority? = nil) async throws -> HomeDeletionStatus {
        try command.validate()
        if let share = command.share, let scope = command.scope, let cart {
            try validateAccount(scope)
            let session = try cart.sessionProvider.currentSession()
            return try await persistence.homeParticipantOperations.perform(in: HomeParticipantZone(session: session, share: share)) {
                try await self.executeShared(command, authority: authority)
            }
        }
        return try await Task.detached(priority: .userInitiated) {
            try self.deleteGraph(command, authority: authority)
        }.value
    }

    func reconcile(_ command: HomeDeletionCommand) async throws -> HomeDeletionStatus {
        try command.validate()
        guard try await status(command) != nil else { throw HomeDeletionError.scopeChanged }
        if command.share == nil { return try await execute(command) }
        guard let scope = command.scope, let share = command.share, let cart else { throw HomeDeletionError.scopeChanged }
        try validateAccount(scope)
        return try await persistence.homeParticipantOperations.perform(in:
            HomeParticipantZone(session: cart.sessionProvider.currentSession(), share: share)) {
            try await self.reconcileShared(command)
        }
    }

    func statuses() async throws -> [HomeDeletionStatus] {
        try await Task.detached(priority: .utility) {
            let statuses: [HomeDeletionStatus]
            if let cart = self.cart { statuses = try cart.retainedHomeDeletions() }
            else {
                guard let url = self.persistence.primaryStore?.url else { return [] }
                statuses = try LocalHomeDeletionJournal(storeURL: url).statuses()
            }
            for status in statuses where status.completed { try self.retireCreationRequest(status.command) }
            return statuses
        }.value
    }

    /// Creation intent is only an unfinished UI request. Its deleted result must
    /// not pin Create to old IDs; the permanent deletion evidence stays retained.
    private func retireCreationRequest(_ command: HomeDeletionCommand) throws {
        guard persistence.primaryStore?.identifier == command.graph.storeIdentifier,
              persistence.primaryStore?.url?.standardizedFileURL == command.storeURL.standardizedFileURL else { return }
        if let cart, let scope = command.scope {
            try validateAccount(scope)
            let session = try cart.sessionProvider.currentSession()
            let journal = HomeCreationJournal(url: HomeCreationJournal.location(storeURL: command.storeURL, session: session))
            if let pending = try journal.pending(session: session, storeIdentifier: command.graph.storeIdentifier),
               pending.householdID == command.graph.householdID, pending.listID == command.graph.listID {
                try journal.acknowledge(pending)
            }
        } else if command.isLocal {
            let journal = LocalHomeCreationJournal(storeURL: command.storeURL)
            if let pending = try journal.pending(storeIdentifier: command.graph.storeIdentifier),
               pending.householdID == command.graph.householdID, pending.listID == command.graph.listID {
                try journal.acknowledge(pending)
            }
        }
    }

    private func executeShared(_ command: HomeDeletionCommand, authority: UICommandAuthority?) async throws -> HomeDeletionStatus {
        guard let cart, let backend, let scope = command.scope else { throw HomeDeletionError.scopeChanged }
        let saved = try await status(command)
        if let saved, saved.submitted || saved.completed { return try await reconcileShared(command) }
        try authority?.validate()
        if saved == nil {
            try await Task.detached(priority: .userInitiated) {
                try cart.transact(additionalAuthority: authority) { repository in
                    _ = try self.objects(command, context: repository.context)
                    try repository.retainHomeDeletion(command)
                }
            }.value
        }
        // Intent precedes connectivity; fresh owner/zone validation still precedes submission.
        let coverage = try await captureSharedCoverage(command)
        try await Task.detached(priority: .userInitiated) {
            try cart.transact { try $0.checkpointHomeDeletion(command, stage: .submitted) }
        }.value
        try validateAccount(scope)
        try await backend.purge(command, coveredObjectURIs: coverage)
        return try await completeIfAbsent(command)
    }

    private func captureSharedCoverage(_ command: HomeDeletionCommand) async throws -> Set<String> {
        guard let cart, let backend else { throw HomeDeletionError.scopeChanged }
        let known = try await Task.detached(priority: .utility) {
            try cart.transact(save: false) { try $0.homeDeletionObjectURIs(command) }
        }.value
        let coverage = try await backend.validatedCoverage(command, knownObjectURIs: known)
        return try await Task.detached(priority: .userInitiated) {
            try cart.transact { repository in
                try repository.retainHomeDeletionCoverage(command, objectURIs: coverage)
                return try repository.homeDeletionObjectURIs(command)
            }
        }.value
    }

    private func reconcileShared(_ command: HomeDeletionCommand) async throws -> HomeDeletionStatus {
        guard let saved = try await status(command) else { throw HomeDeletionError.scopeChanged }
        guard !saved.completed else { return saved }
        guard saved.submitted else { return try await executeShared(command, authority: nil) }
        guard let backend else { throw HomeDeletionError.scopeChanged }
        if try await backend.zoneExists(command) {
            let coverage = try await captureSharedCoverage(command)
            try await backend.purge(command, coveredObjectURIs: coverage)
            return try await completeIfAbsent(command)
        }
        return try await removeConfirmedServerResidue(command)
    }

    /// zoneNotFound is authoritative for the already submitted exact owner zone.
    /// Clean its local mirror without asking a vanished CKShare to authorize itself.
    private func removeConfirmedServerResidue(_ command: HomeDeletionCommand) async throws -> HomeDeletionStatus {
        guard let cart else { throw HomeDeletionError.scopeChanged }
        return try await Task.detached(priority: .userInitiated) {
            try cart.transact { repository in
                guard try repository.homeDeletions().contains(where: { $0.command == command && $0.submitted && !$0.completed }) else {
                    throw HomeDeletionError.scopeChanged
                }
                let context = repository.context
                let store = try self.store(command.graph, scope: command.scope)
                var coverage = try repository.homeDeletionObjectURIs(command)
                if let root = try Self.remainingRoot(command.graph, store: store, context: context), root.groceryList != nil {
                    let graph = try HomeShareGraphValidator.objects(root: root, listID: command.graph.listID, in: context)
                    coverage.formUnion(graph.map { $0.objectID.uriRepresentation().absoluteString })
                    try repository.retainHomeDeletionCoverage(command, objectURIs: coverage)
                }
                var objects: [NSManagedObject] = []
                for entity in HomeShareGraphValidator.sharedEntities {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                    request.affectedStores = [store]
                    for object in try context.fetch(request) where coverage.contains(object.objectID.uriRepresentation().absoluteString) {
                        if let home = ShareAssociationScope.household(for: object),
                           home.objectID.uriRepresentation().absoluteString != command.graph.rootURI { throw HomeDeletionError.invalidGraph }
                        objects.append(object)
                    }
                }
                if let cloud = self.persistence.container as? NSPersistentCloudKitContainer, let share = command.share {
                    let mapped = try cloud.fetchShares(matching: objects.map(\.objectID))
                    let records = cloud.recordIDs(for: objects.map(\.objectID))
                    guard mapped.values.allSatisfy({ $0.recordID.recordName == share.recordName
                        && $0.recordID.zoneID.zoneName == share.zoneName
                        && $0.recordID.zoneID.ownerName == share.zoneOwnerName }),
                        records.values.allSatisfy({ $0.zoneID.zoneName == share.zoneName && $0.zoneID.ownerName == share.zoneOwnerName }) else {
                        throw HomeDeletionError.scopeChanged
                    }
                }
                if !objects.isEmpty { try self.remove(objects, command: command, context: context) }
                guard try self.isAbsent(command, coveredObjectURIs: coverage, store: store, context: context) else {
                    throw HomeDeletionError.outcomeUncertain
                }
                try repository.checkpointHomeDeletion(command, stage: .completed)
                return HomeDeletionStatus(command: command, submitted: true, completed: true)
            }
        }.value
    }

    private func completeIfAbsent(_ command: HomeDeletionCommand) async throws -> HomeDeletionStatus {
        guard let cart else { throw HomeDeletionError.scopeChanged }
        return try await Task.detached(priority: .utility) {
            try cart.transact { repository in
                let store = try self.store(command.graph, scope: command.scope)
                guard try self.isAbsent(command, coveredObjectURIs: repository.homeDeletionObjectURIs(command), store: store, context: repository.context) else { throw HomeDeletionError.outcomeUncertain }
                try repository.checkpointHomeDeletion(command, stage: .completed)
                return try repository.homeDeletions().first { $0.command == command }!
            }
        }.value
    }

    private func status(_ command: HomeDeletionCommand) async throws -> HomeDeletionStatus? {
        try await statuses().first { $0.command == command }
    }

    private func deleteGraph(_ command: HomeDeletionCommand, authority: UICommandAuthority?) throws -> HomeDeletionStatus {
        if let cart, command.scope != nil {
            return try cart.transact(additionalAuthority: authority) { repository in
                let store = try self.store(command.graph, scope: command.scope)
                if let old = try repository.homeDeletions().first(where: { $0.command == command }), old.completed { return old }
                try authority?.validate()
                let objects = try self.objects(command, context: repository.context)
                if let cloud = self.persistence.container as? NSPersistentCloudKitContainer {
                    guard try cloud.fetchShares(matching: objects.map(\.objectID)).isEmpty else { throw HomeDeletionError.sharingPending }
                }
                try self.requireNoPendingShare(command)
                try repository.retainHomeDeletion(command)
                try repository.checkpointHomeDeletion(command, stage: .submitted)
                try self.remove(objects, command: command, context: repository.context)
                try repository.checkpointHomeDeletion(command, stage: .completed)
                guard store.identifier == command.graph.storeIdentifier else { throw HomeDeletionError.scopeChanged }
                return HomeDeletionStatus(command: command, submitted: true, completed: true)
            }
        }
        guard command.isLocal, cart == nil else { throw HomeDeletionError.scopeChanged }
        let journal = LocalHomeDeletionJournal(storeURL: command.storeURL)
        return try persistence.writer.performAndWait {
            let context = persistence.writer
            context.reset()
            defer { context.userInfo.removeObject(forKey: HomeDeletionSaveAuthority.key) }
            do {
                let store = try self.store(command.graph, scope: nil)
                guard store.url?.standardizedFileURL == command.storeURL.standardizedFileURL else { throw HomeDeletionError.scopeChanged }
                let retained = try journal.statuses().first { $0.command == command }
                if retained?.completed == true { return retained! }
                if retained != nil, try self.isAbsent(command, store: store, context: context) {
                    try journal.complete(command)
                    return HomeDeletionStatus(command: command, submitted: true, completed: true)
                }
                try authority?.validate()
                let objects = try self.objects(command, context: context)
                try journal.retain(command)
                try self.remove(objects, command: command, context: context)
                try self.persistence.prepareForSave(context)
                try context.save()
                try journal.complete(command)
                return HomeDeletionStatus(command: command, submitted: true, completed: true)
            } catch { context.rollback(); throw error }
        }
    }

    private func remove(_ objects: [NSManagedObject], command: HomeDeletionCommand, context: NSManagedObjectContext) throws {
        context.userInfo[HomeDeletionSaveAuthority.key] = HomeDeletionSaveAuthority(command: command, objectIDs: Set(objects.map(\.objectID)))
        for object in objects { context.delete(object) }
    }

    private func objects(_ command: HomeDeletionCommand, context: NSManagedObjectContext) throws -> [NSManagedObject] {
        let store = try store(command.graph, scope: command.scope)
        guard store.url?.standardizedFileURL == command.storeURL.standardizedFileURL else { throw HomeDeletionError.scopeChanged }
        let root = try Self.root(command.graph, store: store, context: context)
        let objects = try HomeShareGraphValidator.objects(root: root, listID: command.graph.listID, in: context)
        guard Set(objects.map { $0.objectID.uriRepresentation().absoluteString }) == command.objectURIs else {
            throw HomeDeletionError.scopeChanged
        }
        return objects
    }

    static func root(_ graph: HomeGraphIdentity, store: NSPersistentStore, context: NSManagedObjectContext) throws -> Household {
        guard store.identifier == graph.storeIdentifier, let url = URL(string: graph.rootURI),
              let coordinator = context.persistentStoreCoordinator,
              let id = coordinator.managedObjectID(forURIRepresentation: url), id.persistentStore === store,
              let root = try context.existingObject(with: id) as? Household, root.id == graph.householdID,
              root.groceryList?.id == graph.listID else { throw HomeDeletionError.scopeChanged }
        return root
    }

    /// A partial native purge may leave a root without its list, or only covered
    /// children. Missing relationships never grant coverage of additional objects.
    static func remainingRoot(_ graph: HomeGraphIdentity, store: NSPersistentStore,
                              context: NSManagedObjectContext) throws -> Household? {
        guard store.identifier == graph.storeIdentifier else { throw HomeDeletionError.scopeChanged }
        let request = Household.fetchRequest()
        request.affectedStores = [store]
        let roots = try context.fetch(request)
        let exact = roots.filter { $0.objectID.uriRepresentation().absoluteString == graph.rootURI }
        let sameID = roots.filter { $0.id == graph.householdID }
        guard exact.count <= 1, sameID.count <= 1 else { throw HomeDeletionError.invalidGraph }
        guard let root = exact.first else {
            guard sameID.isEmpty else { throw HomeDeletionError.scopeChanged }
            return nil
        }
        guard root.id == graph.householdID else { throw HomeDeletionError.scopeChanged }
        if let list = root.groceryList {
            guard list.id == graph.listID, list.household == root, list.objectID.persistentStore === store else {
                throw HomeDeletionError.scopeChanged
            }
        }
        return root
    }

    private func isAbsent(_ command: HomeDeletionCommand, coveredObjectURIs: Set<String>? = nil, store: NSPersistentStore, context: NSManagedObjectContext) throws -> Bool {
        for entity in HomeShareGraphValidator.sharedEntities {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.affectedStores = [store]
            for object in try context.fetch(request) {
                if (coveredObjectURIs ?? command.objectURIs).contains(object.objectID.uriRepresentation().absoluteString) { return false }
                if let home = object as? Household, home.id == command.graph.householdID { return false }
                if let list = object as? GroceryList, list.id == command.graph.listID { return false }
            }
        }
        return true
    }

    private func requireNoPendingShare(_ command: HomeDeletionCommand) throws {
        guard let scope = command.scope else { return }
        let intent = try HomeShareProvisioningJournal(url: HomeShareProvisioningJournal.location(storeURL: command.storeURL, scope: scope))
            .existingIntent(scope: scope)
        guard intent?.attempted != true, intent?.identity == nil else { throw HomeDeletionError.sharingPending }
    }

    private func store(_ graph: HomeGraphIdentity, scope: ActiveHomeScope?) throws -> NSPersistentStore {
        if let scope { try validateAccount(scope) }
        guard let store = persistence.primaryStore, store.identifier == graph.storeIdentifier,
              persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              persistence.role(of: store) != .participantShared else { throw HomeDeletionError.ownerRequired }
        if scope == nil {
            guard case .local = persistence.configuration, !persistence.personalCartsEnabled else { throw HomeDeletionError.ownerRequired }
        }
        return store
    }

    private func validateAccount(_ scope: ActiveHomeScope) throws {
        guard let cart, cart.persistence === persistence else { throw HomeDeletionError.ownerRequired }
        let session = try cart.sessionProvider.currentSession()
        guard ActiveHomeScope(session: session, graph: scope.graph) == scope,
              cart.initialAccountBinding == session.accountBinding, persistence.personalCartInitialBinding == session.accountBinding else {
            throw PersonalCartError.accountChanged
        }
    }
}
