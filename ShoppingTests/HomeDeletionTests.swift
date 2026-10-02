import CoreData
import XCTest
@testable import Shopping

final class HomeDeletionTests: XCTestCase {
    private final class Provider: ShopperSessionProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var session: ShopperSession
        init(_ session: ShopperSession) { self.session = session }
        func currentSession() throws -> ShopperSession { lock.withLock { session } }
        func replace(_ session: ShopperSession) { lock.withLock { self.session = session } }
    }

    private struct Fixture {
        let persistence: PersistenceController
        let provider: Provider
        let cart: PersonalCartService?
        let graph: HomeGraphIdentity
        let other: HomeGraphIdentity
        let needID: UUID
        var scope: ActiveHomeScope? { cart.map { _ in ActiveHomeScope(session: try! provider.currentSession(), graph: graph) } }
    }

    private func close(_ persistence: PersistenceController) throws {
        persistence.writer.performAndWait { persistence.writer.reset() }
        persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
    }

    private func fixture(account: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = try PersistenceController(storeURL: directory.appendingPathComponent("Home.sqlite"))
        addTeardownBlock { try? self.close(persistence); try? FileManager.default.removeItem(at: directory) }
        let needs = NeedService(persistence: persistence)
        let home = try needs.createHousehold(name: "Delete me")
        let category = try needs.createCategory(name: "Produce", householdID: home.householdID)
        let store = try needs.createStore(name: "Market", householdID: home.householdID)
        let item = try needs.createItem(name: "Apples", categoryID: category, storeIDs: [store], householdID: home.householdID)
        let needID = try needs.addRememberedNeed(itemID: item, listID: home.listID, householdID: home.householdID)
        _ = try needs.createPerson(name: "Family", householdID: home.householdID)
        let other = try needs.createHousehold(name: "Keep me")
        _ = try needs.addOneTimeNeed(title: "Bread", householdID: other.householdID, listID: other.listID)
        let discovery = try HomeDiscoveryService(persistence: persistence).discover()
        let graph = try XCTUnwrap(discovery.homes.first { $0.graph.householdID == home.householdID }?.graph)
        let otherGraph = try XCTUnwrap(discovery.homes.first { $0.graph.householdID == other.householdID }?.graph)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.delete", environment: "Development", accountRecordName: "owner")
        let provider = Provider(session)
        let cart = account ? PersonalCartService(persistence: persistence, sessionProvider: provider) : nil
        if let cart { try cart.cart(needID: needID, householdID: home.householdID, listID: home.listID) }
        return Fixture(persistence: persistence, provider: provider, cart: cart, graph: graph, other: otherGraph, needID: needID)
    }

    private func privateEvidence(_ persistence: PersistenceController) throws -> [UUID: [Data?]] {
        try persistence.writer.performAndWait {
            let request = NSFetchRequest<PersonalCartRecord>(entityName: "PersonalCartRecord")
            return Dictionary(uniqueKeysWithValues: try persistence.writer.fetch(request).map { ($0.id, [$0.command, $0.payload]) })
        }
    }

    func testLocalDeletionRemovesCompleteGraphPreservesOtherHomeAndSurvivesReopen() async throws {
        let f = try fixture()
        let service = HomeDeletionService(persistence: f.persistence)
        let command = try await service.prepare(graph: f.graph, scope: nil)
        XCTAssertGreaterThan(command.objectURIs.count, 5)
        let result = try await service.execute(command)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(try HomeDiscoveryService(persistence: f.persistence).discover().homes.map(\.graph), [f.other])
        let url = try XCTUnwrap(f.persistence.primaryStore?.url)
        try close(f.persistence)
        let reopened = try PersistenceController(storeURL: url)
        defer { try? close(reopened) }
        let resumed = try await HomeDeletionService(persistence: reopened).reconcile(command)
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(try HomeDiscoveryService(persistence: reopened).discover().homes.map(\.graph), [f.other])
        let fresh = try NeedService(persistence: reopened).createHousehold(name: "New home")
        XCTAssertNotEqual(fresh.householdID, f.graph.householdID)
        XCTAssertEqual(try HomeDiscoveryService(persistence: reopened).discover().homes.count, 2)
        let replay = LocalHomeCreationCommand(id: UUID(), storeIdentifier: f.graph.storeIdentifier,
            householdID: f.graph.householdID, listID: f.graph.listID, name: "Old creation")
        XCTAssertThrowsError(try NeedService(persistence: reopened).createLocalHousehold(command: replay))
    }

    func testOwnedUnsharedDeletionRetainsPrivateCartAndEveryPriorSemanticRecord() async throws {
        let f = try fixture(account: true), cart = try XCTUnwrap(f.cart)
        let savedScope = PersonalCartScopeSnapshot(householdID: f.graph.householdID, listID: f.graph.listID)
        let beforeDisplay = try await cart.savedCartHomeDisplays(for: [savedScope])
        XCTAssertEqual(beforeDisplay.first?.name, "Delete me")
        let before = try privateEvidence(f.persistence)
        XCTAssertFalse(before.isEmpty)
        let entries = try cart.entries(householdID: f.graph.householdID, listID: f.graph.listID)
        let service = HomeDeletionService(persistence: f.persistence, cart: cart)
        let command = try await service.prepare(graph: f.graph, scope: f.scope)
        XCTAssertNil(command.share)
        let status = try await service.execute(command)
        XCTAssertTrue(status.completed)
        let after = try privateEvidence(f.persistence)
        for (id, bytes) in before { XCTAssertEqual(after[id], bytes) }
        let retainedEntries = try cart.entries(householdID: f.graph.householdID, listID: f.graph.listID)
        XCTAssertEqual(retainedEntries.map(\.token), entries.map(\.token))
        XCTAssertEqual(retainedEntries.map(\.quantity), entries.map(\.quantity))
        XCTAssertTrue(retainedEntries.allSatisfy { !$0.demandAvailable })
        XCTAssertTrue(try cart.hasCompletedHomeDeletion(storeIdentifier: f.graph.storeIdentifier,
            householdID: f.graph.householdID, listID: f.graph.listID))
        XCTAssertFalse(try cart.transact(save: false) { try $0.homeEffectMayPublish(kind: .checkout, subjectID: UUID(),
            householdID: f.graph.householdID, listID: f.graph.listID) })
        XCTAssertEqual(try HomeDiscoveryService(persistence: f.persistence).discover().homes.map(\.graph), [f.other])
        let url = try XCTUnwrap(f.persistence.primaryStore?.url)
        try close(f.persistence)
        let reopened = try PersistenceController(storeURL: url)
        defer { try? close(reopened) }
        let reopenedCart = PersonalCartService(persistence: reopened, sessionProvider: f.provider)
        let afterDisplay = try await reopenedCart.savedCartHomeDisplays(for: [savedScope])
        XCTAssertEqual(afterDisplay.first?.name, "Delete me",
            "The saved cart names its deleted home from exact private evidence after relaunch")
        XCTAssertTrue(try reopenedCart.hasCompletedHomeDeletion(storeIdentifier: f.graph.storeIdentifier,
            householdID: f.graph.householdID, listID: f.graph.listID))
        let reopenedEvidence = try privateEvidence(reopened)
        for (id, bytes) in before { XCTAssertEqual(reopenedEvidence[id], bytes) }
    }

    func testStaleCapturedGraphAndRetiredPresentationNeverRetainDeletion() async throws {
        let f = try fixture(), service = HomeDeletionService(persistence: f.persistence)
        let authority = UICommandAuthority()
        let command = try await service.prepare(graph: f.graph, scope: nil, authority: authority)
        authority.retire()
        do { _ = try await service.execute(command, authority: authority); XCTFail("Retired screen authorized deletion") }
        catch { }
        let retiredStatuses = try await service.statuses()
        XCTAssertTrue(retiredStatuses.isEmpty)
        _ = try NeedService(persistence: f.persistence).addOneTimeNeed(title: "Newer need", householdID: f.graph.householdID, listID: f.graph.listID)
        do { _ = try await service.execute(command); XCTFail("Expanded graph was deleted without confirmation") }
        catch HomeDeletionError.scopeChanged { }
        let staleStatuses = try await service.statuses()
        XCTAssertTrue(staleStatuses.isEmpty)
    }

    func testLocalMarkerBeforeSaveCanFinishAfterReopen() async throws {
        let f = try fixture(), service = HomeDeletionService(persistence: f.persistence)
        let command = try await service.prepare(graph: f.graph, scope: nil)
        try LocalHomeDeletionJournal(storeURL: command.storeURL).retain(command)
        // Process stops after durable intent and before the Core Data save.
        try close(f.persistence)
        let reopened = try PersistenceController(storeURL: command.storeURL)
        defer { try? close(reopened) }
        let result = try await HomeDeletionService(persistence: reopened).reconcile(command)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(try HomeDiscoveryService(persistence: reopened).discover().homes.map(\.graph), [f.other])
    }

    func testOfflineSubmittedOwnerDeleteRetriesOnlyAfterFreshOwnershipValidation() async throws {
        let f = try fixture(account: true), cart = try XCTUnwrap(f.cart)
        let backend = Backend(persistence: f.persistence, failure: .offline)
        let service = HomeDeletionService(persistence: f.persistence, cart: cart, backend: backend)
        let command = try await service.prepare(graph: f.graph, scope: f.scope)
        do { _ = try await service.execute(command); XCTFail("Offline deletion reported complete") } catch { }
        let pending = try await service.statuses()
        XCTAssertTrue(try XCTUnwrap(pending.first).requiresResolution)
        await backend.reconnect()
        let completed = try await service.reconcile(command)
        XCTAssertTrue(completed.completed)
        let calls = await backend.counts()
        XCTAssertEqual(calls.purges, 2)
        XCTAssertEqual(calls.validations, 2)
        _ = try await service.reconcile(command)
        let finalCalls = await backend.counts()
        XCTAssertEqual(finalCalls.purges, 2)
    }

    func testOfflineBeforeSubmissionRetainsExactConfirmationAndResumesAfterReconnect() async throws {
        let f = try fixture(account: true), cart = try XCTUnwrap(f.cart)
        let backend = Backend(persistence: f.persistence, failure: nil)
        let service = HomeDeletionService(persistence: f.persistence, cart: cart, backend: backend)
        let command = try await service.prepare(graph: f.graph, scope: f.scope)
        await backend.disconnectBeforeSubmission()
        do { _ = try await service.execute(command); XCTFail("Offline preflight reported complete") } catch { }
        let retained = try await service.statuses()
        XCTAssertEqual(retained.first?.command, command)
        XCTAssertEqual(retained.first?.submitted, false)
        XCTAssertEqual(retained.first?.completed, false)
        let beforeCalls = await backend.counts()
        XCTAssertEqual(beforeCalls.purges, 0)
        await backend.reconnect()
        let result = try await service.reconcile(command)
        XCTAssertTrue(result.completed)
        let afterCalls = await backend.counts()
        XCTAssertEqual(afterCalls.purges, 1)
    }

    func testLocallyPurgedButServerZonePresentRecoversWithoutDeletedRoot() async throws {
        let f = try fixture(account: true), cart = try XCTUnwrap(f.cart)
        let evidence = try privateEvidence(f.persistence)
        let backend = Backend(persistence: f.persistence, failure: .localOnly)
        let service = HomeDeletionService(persistence: f.persistence, cart: cart, backend: backend)
        let command = try await service.prepare(graph: f.graph, scope: f.scope)
        do { _ = try await service.execute(command); XCTFail("Unknown server deletion reported complete") } catch { }
        XCTAssertEqual(try HomeDiscoveryService(persistence: f.persistence).discover().homes.map(\.graph), [f.other])
        await backend.reconnect()
        let completed = try await service.reconcile(command)
        XCTAssertTrue(completed.completed)
        let calls = await backend.counts()
        XCTAssertEqual(calls.purges, 2)
        XCTAssertEqual(calls.validations, 2)
        let after = try privateEvidence(f.persistence)
        for (id, bytes) in evidence { XCTAssertEqual(after[id], bytes) }
    }

    func testAccountChangeCannotRetryOldSubmittedDelete() async throws {
        let f = try fixture(account: true), cart = try XCTUnwrap(f.cart)
        let backend = Backend(persistence: f.persistence, failure: .offline)
        let service = HomeDeletionService(persistence: f.persistence, cart: cart, backend: backend)
        let command = try await service.prepare(graph: f.graph, scope: f.scope)
        do { _ = try await service.execute(command); XCTFail("Offline deletion reported complete") } catch { }
        f.provider.replace(try ShopperSession.authenticated(containerIdentifier: "iCloud.test.delete", environment: "Development", accountRecordName: "other"))
        await backend.reconnect()
        do { _ = try await service.reconcile(command); XCTFail("Changed account authorized deletion") } catch { }
        let calls = await backend.counts()
        XCTAssertEqual(calls.purges, 1)
        XCTAssertEqual(calls.validations, 1)
    }

    func testConfirmedDeletionCoversLaterImportedChildrenOfOnlyTheSameHome() async throws {
        let f = try fixture(account: true), cart = try XCTUnwrap(f.cart)
        let backend = Backend(persistence: f.persistence, failure: .offline)
        let service = HomeDeletionService(persistence: f.persistence, cart: cart, backend: backend)
        let command = try await service.prepare(graph: f.graph, scope: f.scope)
        do { _ = try await service.execute(command); XCTFail("Offline submission completed") } catch { }
        // Models a peer's CloudKit import, below the local publication guard.
        let importedURI = try f.persistence.writer.performAndWait {
            let context = f.persistence.writer
            context.reset()
            let store = try XCTUnwrap(f.persistence.primaryStore)
            let root = try HomeDeletionService.root(f.graph, store: store, context: context)
            let need = NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as! Need
            need.id = UUID(); need.title = "Peer's later grocery"; need.kind = "oneTime"
            need.list = root.groceryList
            context.assign(need, to: store)
            try context.save()
            return need.objectID.uriRepresentation().absoluteString
        }
        XCTAssertFalse(command.objectURIs.contains(importedURI))
        await backend.reconnect()
        let status = try await service.reconcile(command)
        XCTAssertTrue(status.completed)
        XCTAssertEqual(status.command, command)
        let coverage = try cart.transact(save: false) { try $0.homeDeletionObjectURIs(command) }
        XCTAssertTrue(coverage.contains(importedURI))
        XCTAssertTrue(command.objectURIs.isSubset(of: coverage))
        XCTAssertEqual(try HomeDiscoveryService(persistence: f.persistence).discover().homes.map(\.graph), [f.other])
    }

    func testConfirmedServerAbsenceCleansLocalResidueWithoutAnotherPurge() async throws {
        let f = try fixture(account: true), cart = try XCTUnwrap(f.cart)
        let before = try privateEvidence(f.persistence)
        let backend = Backend(persistence: f.persistence, failure: .serverOnly)
        let service = HomeDeletionService(persistence: f.persistence, cart: cart, backend: backend)
        let command = try await service.prepare(graph: f.graph, scope: f.scope)
        do { _ = try await service.execute(command); XCTFail("Unknown callback completed") } catch { }
        let result = try await service.reconcile(command)
        XCTAssertTrue(result.completed)
        let calls = await backend.counts()
        XCTAssertEqual(calls.purges, 1)
        XCTAssertEqual(try HomeDiscoveryService(persistence: f.persistence).discover().homes.map(\.graph), [f.other])
        let after = try privateEvidence(f.persistence)
        for (id, bytes) in before { XCTAssertEqual(after[id], bytes) }
    }

    func testCompletedDeletionRetiresOnlyItsPendingCreationAndAllowsFreshIDs() async throws {
        for account in [false, true] {
            let f = try fixture(account: account), url = try XCTUnwrap(f.persistence.primaryStore?.url)
            let needs = NeedService(persistence: f.persistence)
            let localJournal = LocalHomeCreationJournal(storeURL: url)
            let session = try f.provider.currentSession()
            let accountJournal = HomeCreationJournal(url: HomeCreationJournal.location(storeURL: url, session: session))
            let createdID: UUID
            if account {
                let creation = try accountJournal.begin(name: "Unacknowledged", session: session, storeIdentifier: f.graph.storeIdentifier)
                createdID = try needs.createHousehold(command: creation).householdID
            } else {
                let creation = try localJournal.begin(name: "Unacknowledged", storeIdentifier: f.graph.storeIdentifier)
                createdID = try needs.createLocalHousehold(command: creation).householdID
            }
            let graph = try XCTUnwrap(HomeDiscoveryService(persistence: f.persistence).discover().homes.first {
                $0.graph.householdID == createdID
            }?.graph)
            let service = HomeDeletionService(persistence: f.persistence, cart: f.cart)
            let scope = account ? ActiveHomeScope(session: session, graph: graph) : nil
            let deletion = try await service.prepare(graph: graph, scope: scope)
            _ = try await service.execute(deletion)
            _ = try await service.statuses() // Relaunch/status restoration also retires finished creation requests.
            let freshID: UUID
            if account {
                freshID = try accountJournal.begin(name: "Fresh", session: session, storeIdentifier: f.graph.storeIdentifier).householdID
            } else { freshID = try localJournal.begin(name: "Fresh", storeIdentifier: f.graph.storeIdentifier).householdID }
            XCTAssertNotEqual(freshID, createdID)
            XCTAssertEqual(try HomeDiscoveryService(persistence: f.persistence).discover().homes.count, 2)
        }
    }

    func testPartialLocalRootOrListRetriesRecordedCoverageWhileServerZoneExists() async throws {
        try await assertPartialResidue(serverAbsent: false)
    }

    func testPartialLocalRootOrListCleansRecordedCoverageAfterServerZoneIsGone() async throws {
        try await assertPartialResidue(serverAbsent: true)
    }

    private func assertPartialResidue(serverAbsent: Bool) async throws {
        for removeRoot in [false, true] {
            let f = try fixture(account: true), cart = try XCTUnwrap(f.cart)
            let before = try privateEvidence(f.persistence)
            let backend = Backend(persistence: f.persistence, failure: .partial(removeRoot: removeRoot, serverAbsent: serverAbsent))
            let service = HomeDeletionService(persistence: f.persistence, cart: cart, backend: backend)
            let command = try await service.prepare(graph: f.graph, scope: f.scope)
            do { _ = try await service.execute(command); XCTFail("Partial deletion completed") } catch { }
            await backend.reconnect()
            let result = try await service.reconcile(command)
            XCTAssertTrue(result.completed)
            let coverage = try cart.transact(save: false) { try $0.homeDeletionObjectURIs(command) }
            XCTAssertEqual(coverage, command.objectURIs, "Missing relationships must never expand deletion authority")
            let remainingURIs = try f.persistence.writer.performAndWait {
                var uris: Set<String> = []
                for entity in HomeShareGraphValidator.sharedEntities {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                    uris.formUnion(try f.persistence.writer.fetch(request).map { $0.objectID.uriRepresentation().absoluteString })
                }
                return uris
            }
            XCTAssertTrue(coverage.isDisjoint(with: remainingURIs))
            XCTAssertEqual(try HomeDiscoveryService(persistence: f.persistence).discover().homes.map(\.graph), [f.other])
            let after = try privateEvidence(f.persistence)
            for (id, bytes) in before { XCTAssertEqual(after[id], bytes) }
            let calls = await backend.counts()
            XCTAssertEqual(calls.purges, serverAbsent ? 1 : 2)
        }
    }

    private actor Backend: HomeDeletionBackend {
        enum Failure: Error, Equatable { case offline, localOnly, serverOnly, partial(removeRoot: Bool, serverAbsent: Bool) }
        let persistence: PersistenceController
        let identity = HomeEffectShare(recordName: "owner-share", zoneName: "home-zone", zoneOwnerName: "owner")
        var failure: Failure?
        var exists = true
        var purges = 0
        var validations = 0
        var shareOffline = false
        init(persistence: PersistenceController, failure: Failure?) { self.persistence = persistence; self.failure = failure }
        func share(for scope: ActiveHomeScope) async throws -> HomeEffectShare? {
            if shareOffline { throw Failure.offline }
            return identity
        }
        func validatedCoverage(_ command: HomeDeletionCommand, knownObjectURIs: Set<String>) async throws -> Set<String> {
            validations += 1
            if shareOffline { throw Failure.offline }
            guard command.share == identity, exists else { throw HomeDeletionError.scopeChanged }
            return try persistence.writer.performAndWait {
                let context = persistence.writer
                context.reset()
                guard let store = persistence.primaryStore else { throw HomeDeletionError.scopeChanged }
                if let root = try HomeDeletionService.remainingRoot(command.graph, store: store, context: context), root.groceryList != nil {
                    let objects = try HomeShareGraphValidator.objects(root: root, listID: command.graph.listID, in: context)
                    return knownObjectURIs.union(objects.map { $0.objectID.uriRepresentation().absoluteString })
                }
                return knownObjectURIs
            }
        }
        func zoneExists(_ command: HomeDeletionCommand) async throws -> Bool { exists }
        func disconnectBeforeSubmission() { shareOffline = true }
        func reconnect() { failure = nil; shareOffline = false }
        func counts() -> (purges: Int, validations: Int) { (purges, validations) }
        func purge(_ command: HomeDeletionCommand, coveredObjectURIs: Set<String>) async throws {
            purges += 1
            if failure == .offline { throw Failure.offline }
            if failure == .serverOnly { exists = false; throw Failure.serverOnly }
            if case .partial(let removeRoot, let serverAbsent) = failure {
                try persistence.writer.performAndWait {
                    let context = persistence.writer
                    context.reset()
                    let request = NSFetchRequest<NSManagedObject>(entityName: removeRoot ? "Household" : "GroceryList")
                    request.predicate = NSPredicate(format: "id == %@", (removeRoot ? command.graph.householdID : command.graph.listID) as CVarArg)
                    for object in try context.fetch(request) { context.delete(object) }
                    try context.save()
                }
                exists = !serverAbsent
                throw Failure.partial(removeRoot: removeRoot, serverAbsent: serverAbsent)
            }
            // Models Core Data's native purge below application save validation.
            // Only captured IDs are removed; all private evidence is left intact.
            try persistence.writer.performAndWait {
                let context = persistence.writer
                context.reset()
                let coordinator = persistence.container.persistentStoreCoordinator
                for uri in coveredObjectURIs {
                    if let url = URL(string: uri), let id = coordinator.managedObjectID(forURIRepresentation: url),
                       let object = try? context.existingObject(with: id) { context.delete(object) }
                }
                try context.save()
            }
            if failure == .localOnly { throw Failure.localOnly }
            exists = false
        }
    }
}
