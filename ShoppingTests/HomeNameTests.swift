import CoreData
import XCTest
@testable import Shopping

final class HomeNameTests: XCTestCase {
    private struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    /// Models per-store permission decisions while exercising the real save/rollback path.
    private final class Permissions: PersistencePermissionPolicy {
        enum Access { case owner, contributor, readOnly }
        var access: [URL: Access] = [:]
        var beforeSave: (() -> Void)?

        func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {
            beforeSave?()
            for object in context.updatedObjects {
                guard let url = object.objectID.persistentStore?.url else {
                    throw PersistencePermissionError.unresolvedStore
                }
                if access[url] == .readOnly { throw PersistencePermissionError.updateDenied }
            }
        }
    }

    private struct Fixture {
        let persistence: PersistenceController
        let permissions: Permissions
        let session: ShopperSession
        let owner: ActiveHomeScope
        let contributor: ActiveHomeScope
        let cart: PersonalCartService
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ownerURL = directory.appendingPathComponent("Owner.sqlite")
        let contributorURL = directory.appendingPathComponent("Contributor.sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for (url, name) in [(ownerURL, "Owner home"), (contributorURL, "Contributor home")] {
            let seed = try PersistenceController(storeURL: url)
            _ = try NeedService(persistence: seed).createHousehold(name: name)
            for store in seed.container.persistentStoreCoordinator.persistentStores {
                try seed.container.persistentStoreCoordinator.remove(store)
            }
        }
        let permissions = Permissions()
        permissions.access = [ownerURL: .owner, contributorURL: .contributor]
        let persistence = try PersistenceController(configuration: .local(storeURL: ownerURL,
            additionalStoreURLs: [contributorURL]), permissionPolicy: permissions)
        addTeardownBlock {
            persistence.writer.performAndWait { persistence.writer.reset() }
            persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.home-names",
            environment: "Development", accountRecordName: "shopper")
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session))
        let homes = try HomeDiscoveryService(persistence: persistence).discover().homes
        let owner = try XCTUnwrap(homes.first { $0.name == "Owner home" })
        let contributor = try XCTUnwrap(homes.first { $0.name == "Contributor home" })
        let service = NeedService(persistence: persistence)
        _ = try service.createPerson(name: "A grocery assignee", householdID: owner.graph.householdID)
        let need = try service.addOneTimeNeed(title: "Keep my cart", quantity: 3,
            householdID: owner.graph.householdID, listID: owner.graph.listID)
        try cart.cart(needID: need, householdID: owner.graph.householdID, listID: owner.graph.listID)
        return Fixture(persistence: persistence, permissions: permissions, session: session,
            owner: ActiveHomeScope(session: session, graph: owner.graph),
            contributor: ActiveHomeScope(session: session, graph: contributor.graph), cart: cart)
    }

    private func names(_ fixture: Fixture) throws -> [UUID: String] {
        let context = fixture.persistence.container.newBackgroundContext()
        return try context.performAndWait {
            Dictionary(uniqueKeysWithValues: try context.fetch(Household.fetchRequest()).map { ($0.id, $0.name) })
        }
    }

    private func scope(_ original: ActiveHomeScope, store: String? = nil, rootURI: String? = nil,
                       householdID: UUID? = nil, listID: UUID? = nil, session: ShopperSession) -> ActiveHomeScope {
        ActiveHomeScope(session: session, graph: HomeGraphIdentity(
            storeIdentifier: store ?? original.graph.storeIdentifier, rootURI: rootURI ?? original.graph.rootURI,
            householdID: householdID ?? original.graph.householdID, listID: listID ?? original.graph.listID))
    }

    func testOwnerAndContributorRenameOnlyTheirExactHomeAndPreservePeopleAndPrivateCart() throws {
        let fixture = try fixture()
        let beforeCart = try fixture.cart.entries(householdID: fixture.owner.graph.householdID, listID: fixture.owner.graph.listID)
        XCTAssertEqual(beforeCart.count, 1)
        let context = fixture.persistence.container.newBackgroundContext()
        let beforePeople = try context.performAndWait {
            try context.fetch(Person.fetchRequest()).map { [$0.id.uuidString, $0.name, $0.household?.id.uuidString ?? ""] }
        }
        let service = NeedService(persistence: fixture.persistence)
        try service.renameHome(name: "  Renamed owner \n", scope: fixture.owner)
        XCTAssertEqual(try names(fixture)[fixture.owner.graph.householdID], "Renamed owner")
        XCTAssertEqual(try names(fixture)[fixture.contributor.graph.householdID], "Contributor home")
        try service.renameHome(name: "Renamed by contributor", scope: fixture.contributor)
        XCTAssertEqual(try names(fixture)[fixture.contributor.graph.householdID], "Renamed by contributor")
        XCTAssertEqual(try fixture.cart.entries(householdID: fixture.owner.graph.householdID,
            listID: fixture.owner.graph.listID), beforeCart)
        try context.performAndWait {
            context.reset()
            XCTAssertEqual(try context.fetch(Person.fetchRequest()).map {
                [$0.id.uuidString, $0.name, $0.household?.id.uuidString ?? ""]
            }, beforePeople)
        }
        let afterGraphs = try HomeDiscoveryService(persistence: fixture.persistence).discover().homes.map(\.graph)
        XCTAssertEqual(Set(afterGraphs), [fixture.owner.graph, fixture.contributor.graph])
    }

    func testReadOnlyRenameRollsBackAndDoesNotPoisonNextWritableCommand() throws {
        let fixture = try fixture()
        let contributorStore = try XCTUnwrap(fixture.persistence.container.persistentStoreCoordinator.persistentStores
            .first { $0.identifier == fixture.contributor.graph.storeIdentifier }?.url)
        fixture.permissions.access[contributorStore] = .readOnly
        let service = NeedService(persistence: fixture.persistence)
        XCTAssertThrowsError(try service.renameHome(name: "Must not stick", scope: fixture.contributor)) {
            XCTAssertEqual($0 as? PersistencePermissionError, .updateDenied)
        }
        XCTAssertEqual(try names(fixture)[fixture.contributor.graph.householdID], "Contributor home")
        fixture.persistence.writer.performAndWait { XCTAssertFalse(fixture.persistence.writer.hasChanges) }
        try service.renameHome(name: "Owner still writable", scope: fixture.owner)
        XCTAssertEqual(try names(fixture)[fixture.owner.graph.householdID], "Owner still writable")
        XCTAssertEqual(try names(fixture)[fixture.contributor.graph.householdID], "Contributor home")
    }

    func testBlankNamesAndEveryChangedScopeComponentLeaveOriginalNamesIntact() throws {
        let fixture = try fixture()
        let service = NeedService(persistence: fixture.persistence)
        for value in ["", " \n\t "] {
            XCTAssertThrowsError(try service.renameHome(name: value, scope: fixture.owner)) {
                XCTAssertEqual($0 as? NeedServiceError, .invalidName)
            }
        }
        let originalNames = try names(fixture)
        let malformedGraphs = [
            scope(fixture.owner, store: fixture.contributor.graph.storeIdentifier, session: fixture.session),
            scope(fixture.owner, rootURI: fixture.contributor.graph.rootURI, session: fixture.session),
            scope(fixture.owner, householdID: fixture.contributor.graph.householdID, session: fixture.session),
            scope(fixture.owner, listID: fixture.contributor.graph.listID, session: fixture.session)
        ]
        for scope in malformedGraphs {
            XCTAssertThrowsError(try service.renameHome(name: "Wrong home", scope: scope)) {
                XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
            }
        }
        let mismatchedSessions = [
            try ShopperSession.authenticated(containerIdentifier: fixture.session.containerIdentifier,
                environment: fixture.session.environment, accountRecordName: "different shopper"),
            ShopperSession(accountBinding: fixture.session.accountBinding, shopperID: fixture.session.shopperID,
                containerIdentifier: "iCloud.different-container", environment: fixture.session.environment),
            ShopperSession(accountBinding: fixture.session.accountBinding, shopperID: fixture.session.shopperID,
                containerIdentifier: fixture.session.containerIdentifier, environment: "Production")
        ]
        for session in mismatchedSessions {
            XCTAssertThrowsError(try service.renameHome(name: "Wrong account", scope: ActiveHomeScope(session: session, graph: fixture.owner.graph))) {
                XCTAssertEqual($0 as? ShopperSessionError, .accountChanged)
            }
        }
        let other = mismatchedSessions[0]
        fixture.persistence.personalCartSessionProvider = Provider(session: other)
        fixture.persistence.personalCartInitialBinding = other.accountBinding
        XCTAssertThrowsError(try service.renameHome(name: "Stale account capture", scope: fixture.owner)) {
            XCTAssertEqual($0 as? ShopperSessionError, .accountChanged)
        }
        XCTAssertEqual(try names(fixture), originalNames)
    }

    func testDuplicateUUIDsAndBrokenReciprocalListRejectRenameWithoutFallback() throws {
        let fixture = try fixture()
        let service = NeedService(persistence: fixture.persistence)
        let context = fixture.persistence.container.newBackgroundContext()
        try context.performAndWait {
            let second = try XCTUnwrap(context.fetch(Household.fetchRequest()).first { $0.id == fixture.contributor.graph.householdID })
            second.id = fixture.owner.graph.householdID
            try context.save()
        }
        XCTAssertThrowsError(try service.renameHome(name: "Ambiguous root", scope: fixture.owner)) {
            XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
        }
        try context.performAndWait {
            let second = try XCTUnwrap(context.fetch(Household.fetchRequest()).first { $0.objectID.uriRepresentation().absoluteString == fixture.contributor.graph.rootURI })
            second.id = fixture.contributor.graph.householdID
            second.groceryList?.id = fixture.owner.graph.listID
            try context.save()
        }
        XCTAssertThrowsError(try service.renameHome(name: "Ambiguous list", scope: fixture.owner)) {
            XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
        }
        try context.performAndWait {
            let second = try XCTUnwrap(context.fetch(Household.fetchRequest()).first { $0.id == fixture.contributor.graph.householdID })
            second.groceryList?.id = fixture.contributor.graph.listID
            let first = try XCTUnwrap(context.fetch(Household.fetchRequest()).first { $0.id == fixture.owner.graph.householdID })
            first.groceryList = nil
            try context.save()
        }
        XCTAssertThrowsError(try service.renameHome(name: "Detached list", scope: fixture.owner)) {
            XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
        }
        XCTAssertEqual(try names(fixture)[fixture.owner.graph.householdID], "Owner home")
    }

    func testRetiredAuthorityRejectsOldCommandAndRetirementDuringSaveRollsBackName() throws {
        let fixture = try fixture()
        let authority = UICommandAuthority()
        let service = NeedService(persistence: fixture.persistence).scoped(to: authority)
        authority.retire()
        XCTAssertThrowsError(try service.renameHome(name: "Old screen", scope: fixture.owner)) {
            XCTAssertEqual($0 as? UICommandAuthority.Failure, .retired)
        }
        let duringSave = UICommandAuthority()
        fixture.permissions.beforeSave = { duringSave.retire() }
        let inFlight = NeedService(persistence: fixture.persistence).scoped(to: duringSave)
        XCTAssertThrowsError(try inFlight.renameHome(name: "Retired before commit", scope: fixture.owner)) {
            XCTAssertEqual($0 as? UICommandAuthority.Failure, .retired)
        }
        XCTAssertEqual(try names(fixture)[fixture.owner.graph.householdID], "Owner home")
        fixture.persistence.writer.performAndWait { XCTAssertFalse(fixture.persistence.writer.hasChanges) }
    }
}
