import CloudKit
import CoreData
import XCTest
@testable import Shopping

@MainActor
final class HomeSharingContractFixture {
    let lifetime: SQLiteTestFixtureLifetime
    let directory: URL
    let provider: ShopperSessionProvider
    let notifications: NotificationCenter
    private(set) var persistence: PersistenceController
    private(set) var cart: PersonalCartService
    let scope: ActiveHomeScope
    let backend: StatefulHomeSharingBackend
    private(set) var authority = UICommandAuthority()
    private(set) var provisioner = HomeShareProvisioner()
    private(set) var coordinator = HomeMembershipCoordinator()
    var journalURL: URL { directory.appendingPathComponent("invite.json") }
    var provisionURL: URL { directory.appendingPathComponent("provision.json") }

    private init(lifetime: SQLiteTestFixtureLifetime, directory: URL, provider: ShopperSessionProvider,
        persistence: PersistenceController, cart: PersonalCartService, scope: ActiveHomeScope,
        backend: StatefulHomeSharingBackend, notifications: NotificationCenter) {
        self.lifetime = lifetime; self.directory = directory; self.provider = provider
        self.persistence = persistence; self.cart = cart; self.scope = scope; self.backend = backend
        self.notifications = notifications
    }

    static func make(_ test: XCTestCase, replicatedEvents: Bool = false) async throws -> HomeSharingContractFixture {
        let lifetime = SQLiteTestFixtureLifetime()
        test.addTeardownBlock { try lifetime.cleanup() }
        let directory = try lifetime.makeDirectory()
        let notifications = NotificationCenter()
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.sharing-contract",
            environment: "Development", cacheDirectory: directory.appendingPathComponent("account"),
            lookup: .init(status: { .available }, recordName: { "isolated-owner" }), notifications: notifications)
        await provider.refresh()
        let persistence = lifetime.own(try PersistenceController(storeURL: directory.appendingPathComponent("Home.sqlite")))
        let home = try NeedService(persistence: persistence).createHousehold(name: "Contract home")
        let context = persistence.container.viewContext
        if replicatedEvents {
            try context.performAndWait {
                let root = try XCTUnwrap(context.fetch(Household.fetchRequest()).first)
                let event = HouseholdPresenceEvent(id: UUID(), shopperID: UUID(), householdID: home.householdID,
                    listID: home.listID, needID: UUID(), quantity: 2, generation: UUID(), evidence: [UUID()], removed: false)
                for _ in 0..<2 {
                    let record = NSEntityDescription.insertNewObject(forEntityName: "HouseholdCartRecord", into: context) as! HouseholdCartRecord
                    record.id = event.id; record.kind = "presence"; record.household = root
                    record.payload = try PersonalCartCoding.encode(event)
                }
                try context.save()
            }
        }
        let graph = try XCTUnwrap(HomeDiscoveryService(persistence: persistence).discover().homes.first?.graph)
        let scope = ActiveHomeScope(session: try provider.currentSession(), graph: graph)
        let ids = try context.performAndWait {
            try HomeShareGraphValidator.sharedEntities.sorted().flatMap { entity in
                let request = NSFetchRequest<NSManagedObjectID>(entityName: entity)
                request.resultType = .managedObjectIDResultType
                return try context.fetch(request)
            }
        }
        let store = try XCTUnwrap(persistence.primaryStore)
        let backend = StatefulHomeSharingBackend(persistence: persistence, store: store, graphIDs: ids)
        let cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
        return HomeSharingContractFixture(lifetime: lifetime, directory: directory, provider: provider,
            persistence: persistence, cart: cart, scope: scope, backend: backend, notifications: notifications)
    }

    var membership: ManagedHomeMembershipTransport {
        ManagedHomeMembershipTransport(persistence: persistence, authority: authority, privateRecords: cart, backend: backend)
    }
    var sharing: ManagedHomeShareTransport {
        ManagedHomeShareTransport(persistence: persistence, authority: authority, backend: backend)
    }

    func model() -> HomeDetailsModel {
        let coordinator = coordinator, provisioner = provisioner, scope = scope
        let membership = membership, sharing = sharing, journalURL = journalURL, provisionURL = provisionURL
        let authority = authority
        var actions = HomeDetailsActions(refresh: {
            try await coordinator.refresh(scope: scope, journalURL: journalURL, transport: membership)
        }, pending: {
            try await coordinator.pending(scope: scope, journalURL: journalURL)
        }, invite: { retry in
            try await HomeInvitationWorkflow.invite(scope: scope, journalURL: journalURL,
                coordinator: coordinator, transport: membership,
                prepare: { try await provisioner.prepare(scope: scope, journalURL: provisionURL,
                    transport: sharing, retryInterrupted: retry) },
                validatePresentation: { try authority.validate() })
        }, resend: { participantID in
            try await coordinator.resend(participantID: participantID, scope: scope, journalURL: journalURL, transport: membership)
        }, acknowledge: { delivery in
            try await coordinator.acknowledge(delivery, journalURL: journalURL)
        }, rename: { _ in throw HomeMembershipError.unsupportedAccess })
        actions.preparationNeedsRetry = {
            let intent = try HomeShareProvisioningJournal(url: provisionURL).existingIntent(scope: scope)
            return intent?.attempted == true && intent?.identity == nil
        }
        return HomeDetailsModel(scope: scope, actions: actions)
    }

    func reopen() throws {
        authority.retire()
        persistence.writer.performAndWait { persistence.writer.reset() }
        persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
        persistence = lifetime.own(try PersistenceController(storeURL: directory.appendingPathComponent("Home.sqlite")))
        cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
        backend.reconnect(persistence: persistence, store: try XCTUnwrap(persistence.primaryStore))
        authority = UICommandAuthority(); provisioner = HomeShareProvisioner(); coordinator = HomeMembershipCoordinator()
    }
}
