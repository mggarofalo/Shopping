import CloudKit
import CoreData
import XCTest
@testable import Shopping

final class AccountCloudApplicationContractTests: XCTestCase {
    private let lifetime = SQLiteTestFixtureLifetime()
    private let containerID = "iCloud.shopping.account-contracts"

    override func setUp() {
        super.setUp()
        let lifetime = lifetime
        addTeardownBlock { try lifetime.cleanup() }
    }

    func testNewerVerifiedRefreshWinsLateSuccessAndDurableOfflineRelaunch() async throws {
        let directory = try lifetime.makeDirectory()
        let requested = expectation(description: "First account identity lookup suspended")
        let lookup = SuspendedFirstIdentity(requested: requested)
        let provider = try provider(directory, lookup: .init(status: { .available }, recordName: { try await lookup.name() }))
        let old = Task { await provider.refresh() }
        let started = await XCTWaiter.fulfillment(of: [requested], timeout: 2)
        guard started == .completed else {
            await lookup.finish(.failure(CancellationError()))
            old.cancel()
            await old.value
            XCTFail("First identity request did not start within two seconds")
            return
        }
        await provider.refresh()
        await lookup.finish(.success("alice"))
        await old.value
        let winner = try provider.currentSession()
        XCTAssertEqual(provider.state, .ready(winner))
        XCTAssertEqual(winner, try session("bob"))
        let reopened = try self.provider(directory, lookup: .init(status: { throw CKError(.networkUnavailable) }, recordName: { "unused" }))
        await reopened.refresh()
        XCTAssertEqual(reopened.state, .cached(winner), "A stale success must not replace the persisted binding")
    }

    func testNewerVerifiedRefreshWinsLateAuthenticationFailure() async throws {
        let directory = try lifetime.makeDirectory()
        let requested = expectation(description: "First account identity lookup suspended")
        let lookup = SuspendedFirstIdentity(requested: requested)
        let provider = try provider(directory, lookup: .init(status: { .available }, recordName: { try await lookup.name() }))
        let old = Task { await provider.refresh() }
        let started = await XCTWaiter.fulfillment(of: [requested], timeout: 2)
        guard started == .completed else {
            await lookup.finish(.failure(CancellationError()))
            old.cancel()
            await old.value
            XCTFail("First identity request did not start within two seconds")
            return
        }
        await provider.refresh()
        await lookup.finish(.failure(CKError(.notAuthenticated)))
        await old.value
        XCTAssertEqual(provider.state, .ready(try session("bob")))
        let reopened = try self.provider(directory, lookup: .init(status: { throw CKError(.networkFailure) }, recordName: { "unused" }))
        await reopened.refresh()
        XCTAssertEqual(try reopened.currentSession(), try session("bob"))
    }

    func testCacheNamespaceCannotAuthorizeAnotherContainerOrEnvironment() async throws {
        let directory = try lifetime.makeDirectory()
        let original = try provider(directory)
        await original.refresh()
        for (container, environment) in [(containerID, "Production"), ("iCloud.shopping.other-contracts", "Development")] {
            let unrelated = try ShopperSessionProvider(containerIdentifier: container, environment: environment,
                cacheDirectory: directory.appendingPathComponent("AccountCache"), lookup: .init(status: { throw CKError(.networkUnavailable) }, recordName: { "unused" }),
                notifications: NotificationCenter())
            await unrelated.refresh()
            XCTAssertThrowsError(try unrelated.currentSession())
        }
        XCTAssertEqual(try original.currentSession(), try session("alice"))
    }

    func testSignOutBlocksRealCartCommandsAndReverificationRetainsSQLiteQuantity() async throws {
        let directory = try lifetime.makeDirectory()
        let account = ContractAccount()
        let provider = try provider(directory, lookup: account.lookup)
        await provider.refresh()
        let f = try fixture(directory, provider: provider)
        try f.cart.cart(needID: f.needID, householdID: f.homeID, listID: f.listID)
        let token = try entry(f).token
        await account.set(status: .noAccount, name: "alice")
        await provider.refresh()
        XCTAssertThrowsError(try f.cart.setQuantity(9, token: token)) {
            XCTAssertEqual($0 as? ShopperSessionError, .noAccount)
        }
        await account.set(status: .available, name: "alice")
        await provider.refresh()
        let reopened = try lifetime.own(PersistenceController(storeURL: directory.appendingPathComponent("Store.sqlite")))
        let cart = PersonalCartService(persistence: reopened, sessionProvider: provider)
        let retained = try XCTUnwrap(cart.entries(householdID: f.homeID, listID: f.listID).first)
        XCTAssertEqual(retained.quantity, 2)
        XCTAssertEqual(retained.token, token)
        try cart.setQuantity(3, token: retained.token)
        XCTAssertEqual(try XCTUnwrap(cart.entries(householdID: f.homeID, listID: f.listID).first).quantity, 3)
    }

    func testAccountSwitchCannotReadOrMutatePersistedOtherAccountCart() async throws {
        let directory = try lifetime.makeDirectory()
        let account = ContractAccount()
        let provider = try provider(directory, lookup: account.lookup)
        await provider.refresh()
        let f = try fixture(directory, provider: provider)
        try f.cart.cart(needID: f.needID, householdID: f.homeID, listID: f.listID)
        let aliceToken = try entry(f).token
        await account.set(status: .available, name: "bob")
        await provider.refresh()
        XCTAssertThrowsError(try f.cart.entries(householdID: f.homeID, listID: f.listID)) {
            XCTAssertEqual($0 as? PersonalCartError, .accountChanged)
        }
        let bobCart = PersonalCartService(persistence: f.persistence, sessionProvider: provider)
        XCTAssertTrue(try bobCart.entries(householdID: f.homeID, listID: f.listID).isEmpty)
        XCTAssertThrowsError(try bobCart.setQuantity(8, token: aliceToken))
        await account.set(status: .available, name: "alice")
        await provider.refresh()
        let reopened = try lifetime.own(PersistenceController(storeURL: directory.appendingPathComponent("Store.sqlite")))
        let aliceCart = PersonalCartService(persistence: reopened, sessionProvider: provider)
        let retained = try XCTUnwrap(aliceCart.entries(householdID: f.homeID, listID: f.listID).first)
        XCTAssertEqual(retained.token, aliceToken)
        XCTAssertEqual(retained.quantity, 2)
    }

    func testPermissionRestrictionSurvivesRelaunchAndOnlyFreshBoundaryRestoresSharedWrites() async throws {
        let directory = try lifetime.makeDirectory()
        let provider = try provider(directory)
        await provider.refresh()
        let f = try fixture(directory, provider: provider)
        try f.cart.cart(needID: f.needID, householdID: f.homeID, listID: f.listID)
        let share = HomeEffectShare(recordName: "test-share", zoneName: "test-zone", zoneOwnerName: "test-owner")
        try f.cart.recordReadOnlyHome(householdID: f.homeID, listID: f.listID, share: share, operationID: UUID())
        let oldBoundary = try f.cart.homePermissionBoundary(householdID: f.homeID, listID: f.listID)
        let reopened = try lifetime.own(PersistenceController(storeURL: directory.appendingPathComponent("Store.sqlite")))
        let cart = PersonalCartService(persistence: reopened, sessionProvider: provider)
        let needs = NeedService(persistence: reopened)
        XCTAssertEqual(try cart.homePermissionBoundary(householdID: f.homeID, listID: f.listID), oldBoundary)
        XCTAssertThrowsError(try needs.setNeedQuantity(needID: f.needID, householdID: f.homeID, listID: f.listID, quantity: 9)) {
            XCTAssertEqual($0 as? PersistencePermissionError, .updateDenied)
        }
        let privateEntry = try XCTUnwrap(cart.entries(householdID: f.homeID, listID: f.listID).first)
        try cart.setQuantity(4, token: privateEntry.token)
        try cart.recordReadOnlyHome(householdID: f.homeID, listID: f.listID, share: share, operationID: UUID())
        XCTAssertThrowsError(try cart.recordWritableHome(householdID: f.homeID, listID: f.listID, share: share,
            observedRestrictionIDs: oldBoundary, operationID: UUID())) {
            XCTAssertEqual($0 as? PersonalCartError, .scopeChanged)
        }
        let fresh = try cart.homePermissionBoundary(householdID: f.homeID, listID: f.listID)
        try cart.recordWritableHome(householdID: f.homeID, listID: f.listID, share: share,
            observedRestrictionIDs: fresh, operationID: UUID())
        try needs.setNeedQuantity(needID: f.needID, householdID: f.homeID, listID: f.listID, quantity: 5)
        XCTAssertEqual(try XCTUnwrap(cart.entries(householdID: f.homeID, listID: f.listID).first).quantity, 4)
    }

    @MainActor
    func testLocalSaveAndHistoryConsumptionDoNotInventCloudSuccessOrClearExportFailure() async throws {
        let directory = try lifetime.makeDirectory()
        let provider = try provider(directory)
        await provider.refresh()
        let f = try fixture(directory, provider: provider)
        // A real CloudKit-capable container over the same isolated SQLite graph, with
        // no CloudKit options: engine observations are the only external seam.
        let cloud = AccountContractCloudContainer(name: "ContractMonitor",
            managedObjectModel: f.persistence.container.managedObjectModel)
        cloud.persistentStoreDescriptions = PersistenceConfiguration.local(
            storeURL: directory.appendingPathComponent("Store.sqlite")).makeDescriptions()
        defer {
            cloud.drainBackgroundContexts()
            cloud.viewContext.performAndWait { cloud.viewContext.reset() }
            for store in cloud.persistentStoreCoordinator.persistentStores {
                do { try cloud.persistentStoreCoordinator.remove(store) }
                catch { XCTFail("Test monitor store teardown failed: \(error)") }
            }
        }
        var loadError: Error?
        cloud.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        XCTAssertTrue(cloud.persistentStoreDescriptions.allSatisfy { $0.cloudKitContainerOptions == nil })
        let monitor = CloudSyncEventMonitor()
        monitor.attach(to: cloud)
        defer { monitor.reset() }
        XCTAssertEqual(cloud.backgroundContextCount, 1, "The real monitor history read must be owned by the fixture")
        try f.service.setNeedQuantity(needID: f.needID, householdID: f.homeID, listID: f.listID, quantity: 3)
        XCTAssertNil(monitor.status.lastUpload)
        XCTAssertNil(monitor.status.lastDownload)
        let sourceStore = try XCTUnwrap(f.persistence.primaryStore)
        let store = try XCTUnwrap(sourceStore.identifier)
        let monitoredStore = try XCTUnwrap(cloud.persistentStoreCoordinator.persistentStores.first)
        XCTAssertEqual(monitoredStore.identifier, store)
        XCTAssertEqual(monitoredStore.url, sourceStore.url)
        func observed(_ operation: CloudSyncStatus.Operation, time: TimeInterval, failure: CloudSyncStatus.Failure? = nil) {
            monitor.receive(.init(identifier: UUID(), store: store, operation: operation,
                started: Date(timeIntervalSince1970: time), ended: Date(timeIntervalSince1970: time + 1), failure: failure), from: cloud)
        }
        observed(.upload, time: 1, failure: .network)
        try f.service.setNeedQuantity(needID: f.needID, householdID: f.homeID, listID: f.listID, quantity: 4)
        let consumer = PersistentHistoryConsumer(persistence: f.persistence,
            checkpoints: FileHistoryCheckpointStore(directory: directory.appendingPathComponent("History")))
        _ = try await consumer.consumeSummary()
        XCTAssertTrue(monitor.status.hasFailure)
        XCTAssertNil(monitor.status.lastUpload)
        XCTAssertNil(monitor.status.lastDownload)
        observed(.download, time: 2)
        XCTAssertTrue(monitor.status.hasFailure, "Observed import does not repair a failed export")
        XCTAssertEqual(monitor.status.lastDownload, Date(timeIntervalSince1970: 3))
        observed(.upload, time: 3)
        XCTAssertFalse(monitor.status.hasFailure)
        XCTAssertEqual(monitor.status.lastUpload, Date(timeIntervalSince1970: 4))
    }

    private struct Fixture {
        let persistence: PersistenceController
        let service: NeedService
        let cart: PersonalCartService
        let homeID: UUID
        let listID: UUID
        let needID: UUID
    }

    private func fixture(_ directory: URL, provider: ShopperSessionProvider) throws -> Fixture {
        let persistence = try lifetime.own(PersistenceController(storeURL: directory.appendingPathComponent("Store.sqlite")))
        let service = NeedService(persistence: persistence)
        let home = try service.createHousehold(name: "Test Home")
        let need = try service.addOneTimeNeed(title: "Milk", quantity: 2, householdID: home.householdID, listID: home.listID)
        return Fixture(persistence: persistence, service: service,
            cart: PersonalCartService(persistence: persistence, sessionProvider: provider),
            homeID: home.householdID, listID: home.listID, needID: need)
    }

    private func entry(_ f: Fixture) throws -> PersonalCartEntrySnapshot {
        try XCTUnwrap(f.cart.entries(householdID: f.homeID, listID: f.listID).first)
    }

    private func provider(_ directory: URL, lookup: ShopperSessionProvider.AccountLookup? = nil) throws -> ShopperSessionProvider {
        try ShopperSessionProvider(containerIdentifier: containerID, environment: "Development",
            cacheDirectory: directory.appendingPathComponent("AccountCache"),
            lookup: lookup ?? .init(status: { .available }, recordName: { "alice" }), notifications: NotificationCenter())
    }

    private func session(_ name: String) throws -> ShopperSession {
        try ShopperSession.authenticated(containerIdentifier: containerID, environment: "Development", accountRecordName: name)
    }
}

private actor ContractAccount {
    private var status: CKAccountStatus = .available
    private var name = "alice"
    nonisolated var lookup: ShopperSessionProvider.AccountLookup {
        .init(status: { await self.currentStatus() }, recordName: { await self.currentName() })
    }
    func set(status: CKAccountStatus, name: String) { self.status = status; self.name = name }
    private func currentStatus() -> CKAccountStatus { status }
    private func currentName() -> String { name }
}

private actor SuspendedFirstIdentity {
    private var requested = false
    private var first: CheckedContinuation<String, Error>?
    private var terminal: Result<String, Error>?
    private let requestedExpectation: XCTestExpectation
    init(requested: XCTestExpectation) { requestedExpectation = requested }
    func name() async throws -> String {
        if requested { return "bob" }
        requested = true
        if let terminal { return try terminal.get() }
        return try await withCheckedThrowingContinuation {
            first = $0
            requestedExpectation.fulfill()
        }
    }
    func finish(_ result: Result<String, Error>) {
        guard terminal == nil else { return }
        terminal = result
        first?.resume(with: result)
        first = nil
    }
}

/// Captures the actual monitor history contexts so teardown can join their queued work.
/// The monitor uses its production fetch and publication code without a test bypass.
// Added context ownership is lock-protected; this restates the base container contract.
private final class AccountContractCloudContainer: NSPersistentCloudKitContainer, @unchecked Sendable {
    private let contextLock = NSLock()
    private var backgroundContexts: [NSManagedObjectContext] = []

    override func newBackgroundContext() -> NSManagedObjectContext {
        let context = super.newBackgroundContext()
        contextLock.withLock { backgroundContexts.append(context) }
        return context
    }

    var backgroundContextCount: Int {
        contextLock.withLock { backgroundContexts.count }
    }

    func drainBackgroundContexts() {
        let contexts = contextLock.withLock { backgroundContexts }
        for context in contexts {
            // This barrier runs after the monitor's context.perform history fetch.
            context.performAndWait {
                context.automaticallyMergesChangesFromParent = false
                context.reset()
                XCTAssertFalse(context.hasChanges)
                XCTAssertTrue(context.registeredObjects.isEmpty)
            }
        }
        contextLock.withLock { backgroundContexts.removeAll() }
    }
}
