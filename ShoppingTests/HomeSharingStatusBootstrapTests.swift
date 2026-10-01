import CloudKit
import Combine
import CoreData
import XCTest
@testable import Shopping

@MainActor
final class HomeSharingStatusBootstrapTests: XCTestCase {
    private enum Failure: Error { case expected, timeout }
    private enum DiscoveryMode: Sendable { case normal, heldFailure, heldSuccess, failure }
    private enum DiscoveryRequest {
        @TaskLocal static var mode: DiscoveryMode = .normal
    }
    private actor Account {
        var name = "account-A"
        var reads = 0
        func current() -> String { reads += 1; return name }
        func change() { name = "account-B" }
    }
    private actor Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var opened = false
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }
    private struct Fixture {
        let bootstrap: PersistenceBootstrap
        let provider: ShopperSessionProvider
        let account: Account
    }

    private final class HeldSessionNotifications: NotificationCenter, @unchecked Sendable {
        private let lock = NSLock()
        private var holdsSessionChanges = false

        func holdSessionChanges() { lock.withLock { holdsSessionChanges = true } }

        override func post(name: Notification.Name, object: Any?, userInfo: [AnyHashable: Any]? = nil) {
            if name == .shopperSessionDidChange, lock.withLock({ holdsSessionChanges }) { return }
            super.post(name: name, object: object, userInfo: userInfo)
        }
    }

    private func open(
        notifications: NotificationCenter = .default,
        discover: @escaping @Sendable (HomeDiscoveryService) async throws -> HomeDiscovery = { discovery in
            try await Task.detached { try discovery.discover() }.value
        },
        deadline: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(10)) },
        read: @escaping @Sendable (PersonalCartService, ActiveHomeScope) async throws -> HomeSharingWorkSnapshot = { service, scope in
            try await Task.detached {
                try service.sharingWorkSnapshot(householdID: scope.graph.householdID, listID: scope.graph.listID)
            }.value
        }
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SharingStatus-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Shopping.StatusBootstrap." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        let account = Account()
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.status", environment: "Development",
            cacheDirectory: directory.appendingPathComponent("Bindings"),
            lookup: .init(status: { .available }, recordName: { await account.current() }), notifications: notifications)
        await provider.refresh()
        let bootstrap = PersistenceBootstrap(defaults: defaults, makeAccountProvider: { _ in provider },
            accountStoreDirectory: { directory }, sharingStatusDeadline: deadline, readSharingWork: read,
            discoverHomes: discover, activateAccountStore: { _, session, base, _ in
                let accountDirectory = base.appendingPathComponent(session.accountBinding)
                try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
                let url = accountDirectory.appendingPathComponent("Private.sqlite")
                if !FileManager.default.fileExists(atPath: url.path) {
                    let persistence = try PersistenceController(storeURL: url)
                    let needs = NeedService(persistence: persistence)
                    _ = try needs.createHousehold(name: "First home")
                    _ = try needs.createHousehold(name: "Second home")
                    persistence.writer.performAndWait { persistence.writer.reset() }
                    persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
                    for store in persistence.container.persistentStoreCoordinator.persistentStores {
                        try persistence.container.persistentStoreCoordinator.remove(store)
                    }
                }
                return .local(storeURL: url)
            })
        addTeardownBlock { @MainActor in
            if case .loading = bootstrap.state {
                await bootstrap.runLoadingTransition()
                _ = try await self.ready(bootstrap)
            }
            guard case .ready(let current) = bootstrap.state else { return }
            bootstrap.presentationDidDisappear(current.presentation.id)
            bootstrap.retireAndFail(Failure.expected)
            await bootstrap.runLoadingTransition()
            XCTAssertTrue(current.persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
        }
        bootstrap.activatePersonalCarts(importLegacy: false)
        await bootstrap.runLoadingTransition()
        _ = try await ready(bootstrap)
        try await bootstrap.selectHome(XCTUnwrap(bootstrap.homeCoordinator.homes.first?.graph))
        return Fixture(bootstrap: bootstrap, provider: provider, account: account)
    }

    private func ready(_ bootstrap: PersistenceBootstrap) async throws -> PersistenceBootstrap.ReadyState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if case .ready(let value) = bootstrap.state { return value }
            if case .failed(let error) = bootstrap.state { throw error }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.timeout
    }

    private func drain(_ bootstrap: PersistenceBootstrap) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while bootstrap.hasOutstandingSharingStatusCheck, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(bootstrap.hasOutstandingSharingStatusCheck, "Assert the actual late completion before tearing down its stores")
    }

    private func savedWork(_ bootstrap: PersistenceBootstrap) throws -> String {
        try XCTUnwrap(bootstrap.homeSharingStatus.sections.first { $0.id == .savedWork }).presentation.details
    }

    nonisolated private static func snapshot(_ service: PersonalCartService, _ scope: ActiveHomeScope, count: Int) throws -> HomeSharingWorkSnapshot {
        .init(scope: HomeEffectScope(session: try service.sessionProvider.currentSession(),
            householdID: scope.graph.householdID, listID: scope.graph.listID),
            pendingCheckoutCount: count, pendingUndoCount: 0, heldCheckoutCount: 0, heldUndoCount: 0,
            incompleteUndoCount: 0, unassignedUndoCount: 0)
    }

    func testAppearanceReadsLocalCountsWithoutAccountLookupAndForwardsHomeObservation() async throws {
        let f = try await open()
        let accountReads = await f.account.reads
        var homePublications = 0
        let observation = f.bootstrap.objectWillChange.sink { homePublications += 1 }
        f.bootstrap.homeCoordinator.setInvitationPending(true)
        XCTAssertGreaterThan(homePublications, 0)
        withExtendedLifetime(observation) {}
        await f.bootstrap.refreshSharingStatus()
        let currentAccountReads = await f.account.reads
        XCTAssertEqual(currentAccountReads, accountReads)
        XCTAssertFalse(f.bootstrap.isCheckingSharingStatus)
        XCTAssertTrue(try savedWork(f.bootstrap).contains("0 saved checkout operations"))
        XCTAssertEqual(f.bootstrap.sharingStatusCheckMessage,
            "Saved work was checked on this device. iCloud activity is shown from existing observations.")
        XCTAssertFalse(f.bootstrap.homeSharingStatus.sections.contains { $0.id == .ownedStore || $0.id == .sharedStore },
            "Local fixture stores must not masquerade as attached CloudKit stores")
    }

    func testLateReadCannotPublishIntoAnotherHome() async throws {
        let gate = Gate(), started = expectation(description: "read started")
        let f = try await open(read: { service, scope in
            let result = try Self.snapshot(service, scope, count: 777)
            started.fulfill()
            await gate.wait()
            return result
        })
        let original = try await ready(f.bootstrap)
        let check = Task { await f.bootstrap.refreshSharingStatus() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(f.bootstrap.isCheckingSharingStatus)
        let other = try XCTUnwrap(f.bootstrap.homeCoordinator.homes.first { $0.graph != original.homeScope?.graph })
        try await f.bootstrap.selectHome(other.graph)
        await check.value
        XCTAssertFalse(f.bootstrap.isCheckingSharingStatus)
        await gate.open()
        try await drain(f.bootstrap)
        XCTAssertFalse(try savedWork(f.bootstrap).contains("777"))
        XCTAssertTrue(try savedWork(f.bootstrap).contains("not yet known"))
    }

    func testRenewedPresentationOfSameGraphDiscardsHeldRead() async throws {
        let gate = Gate(), started = expectation(description: "read started")
        let f = try await open(read: { service, scope in
            let result = try Self.snapshot(service, scope, count: 888)
            started.fulfill(); await gate.wait(); return result
        })
        let before = try await ready(f.bootstrap)
        let graph = try XCTUnwrap(before.homeScope?.graph)
        let check = Task { await f.bootstrap.refreshSharingStatus() }
        await fulfillment(of: [started], timeout: 2)
        try f.bootstrap.homeCoordinator.select(graph, renewingAuthority: true)
        try await f.bootstrap.refreshHomes()
        let after = try await ready(f.bootstrap)
        XCTAssertEqual(after.homeScope, before.homeScope)
        XCTAssertNotEqual(after.presentation.id, before.presentation.id)
        await check.value
        await gate.open()
        try await drain(f.bootstrap)
        XCTAssertFalse(try savedWork(f.bootstrap).contains("888"))
    }

    func testDeadlineReleasesBusyUIAndRetryDoesNotDuplicateHeldRead() async throws {
        let deadline = Gate(), read = Gate(), started = expectation(description: "read started")
        let f = try await open(deadline: { await deadline.wait() }, read: { service, scope in
            let result = try Self.snapshot(service, scope, count: 999)
            started.fulfill(); await read.wait(); return result
        })
        let check = Task { await f.bootstrap.refreshSharingStatus() }
        await fulfillment(of: [started], timeout: 2)
        await deadline.open()
        await check.value
        XCTAssertFalse(f.bootstrap.isCheckingSharingStatus)
        XCTAssertTrue(f.bootstrap.sharingStatusCheckMessage?.contains("longer than expected") == true)
        await f.bootstrap.checkSharingStatus()
        XCTAssertFalse(f.bootstrap.isCheckingSharingStatus)
        XCTAssertTrue(f.bootstrap.sharingStatusCheckMessage?.contains("still finishing") == true)
        await read.open()
        try await drain(f.bootstrap)
        XCTAssertFalse(try savedWork(f.bootstrap).contains("999"))
    }

    func testAccountChangeCannotPublishOldAccountsRead() async throws {
        let gate = Gate(), started = expectation(description: "read started")
        let f = try await open(read: { service, scope in
            let result = try Self.snapshot(service, scope, count: 444)
            started.fulfill(); await gate.wait(); return result
        })
        let oldSession = try f.provider.currentSession()
        let check = Task { await f.bootstrap.refreshSharingStatus() }
        await fulfillment(of: [started], timeout: 2)
        await f.account.change()
        await f.provider.refresh()
        await gate.open()
        await check.value
        try await drain(f.bootstrap)
        XCTAssertNotEqual(try f.provider.currentSession(), oldSession)
        XCTAssertFalse(f.bootstrap.isCheckingSharingStatus)
        XCTAssertFalse(try savedWork(f.bootstrap).contains("444"))
        // Settle the queued account transition before fixture teardown detaches it.
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < end {
            if case .loading = f.bootstrap.state { await f.bootstrap.runLoadingTransition() }
            if case .ready(let current) = f.bootstrap.state,
               current.persistence.personalCartInitialBinding == (try f.provider.currentSession()).accountBinding { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Account transition did not settle")
    }

    func testSynchronousAccountBoundaryHidesOldObservationsBeforeQueuedUITransition() async throws {
        // Hold only the UI notification, after ordinary startup has completed,
        // while preserving the provider's real synchronous authority state.
        let notifications = HeldSessionNotifications()
        let f = try await open(notifications: notifications, read: { service, scope in
            try Self.snapshot(service, scope, count: 321)
        })
        let oldReady = try await ready(f.bootstrap)
        await f.bootstrap.refreshSharingStatus()
        XCTAssertTrue(try savedWork(f.bootstrap).contains("321 saved checkout"))
        notifications.holdSessionChanges()
        await f.account.change()
        await f.provider.refresh()
        let stillMounted = try await ready(f.bootstrap)
        XCTAssertEqual(oldReady.presentation.id, stillMounted.presentation.id,
            "The test must exercise the gap before UI transition, not a cleared store")
        let status = f.bootstrap.homeSharingStatus
        XCTAssertEqual(status.summary.title, "iCloud account changed")
        XCTAssertEqual(try XCTUnwrap(status.sections.first { $0.id == .home }).presentation.title, "Home access not verified")
        XCTAssertTrue(try savedWork(f.bootstrap).contains("not yet known"))
        XCTAssertFalse(try savedWork(f.bootstrap).contains("321"))
        XCTAssertFalse(status.sections.contains { [.ownedStore, .sharedStore, .ownerAssociations, .leavingHomes, .invitation].contains($0.id) })
    }

    func testOlderDiscoveryFailureCannotReplaceNewerSuccessForSamePresentation() async throws {
        let gate = Gate(), held = expectation(description: "older discovery held")
        let f = try await open(discover: { discovery in
            if DiscoveryRequest.mode == .heldFailure {
                held.fulfill()
                await gate.wait()
                throw Failure.expected
            }
            return try await Task.detached { try discovery.discover() }.value
        })
        // Finish the ordinary foreground access/discovery pass before ordering
        // the two requests whose completion order this test controls.
        await f.bootstrap.checkSharingStatus()
        let original = try await ready(f.bootstrap)
        let older = Task {
            try await DiscoveryRequest.$mode.withValue(.heldFailure) { try await f.bootstrap.refreshHomes() }
        }
        await fulfillment(of: [held], timeout: 2)
        try await f.bootstrap.refreshHomes()
        XCTAssertNil(f.bootstrap.homeDiscoveryError)
        let current = try await ready(f.bootstrap)
        XCTAssertEqual(current.presentation.id, original.presentation.id)
        await gate.open()
        do { try await older.value }
        catch { XCTFail("A superseded discovery failure must not retire a healthy newer presentation: \(error)") }
        XCTAssertNil(f.bootstrap.homeDiscoveryError)
        XCTAssertFalse(f.bootstrap.homeSharingStatus.sections.contains { $0.id == .localChecks })
    }

    func testOlderDiscoverySuccessCannotClearNewerFailureForSamePresentation() async throws {
        let gate = Gate(), held = expectation(description: "older discovery held")
        let f = try await open(discover: { discovery in
            if DiscoveryRequest.mode == .failure { throw Failure.expected }
            let snapshot = try await Task.detached { try discovery.discover() }.value
            if DiscoveryRequest.mode == .heldSuccess { held.fulfill(); await gate.wait() }
            return snapshot
        })
        // Finish the ordinary foreground access/discovery pass before ordering
        // the two requests whose completion order this test controls.
        await f.bootstrap.checkSharingStatus()
        let original = try await ready(f.bootstrap)
        let older = Task {
            try await DiscoveryRequest.$mode.withValue(.heldSuccess) { try await f.bootstrap.refreshHomes() }
        }
        await fulfillment(of: [held], timeout: 2)
        do {
            try await DiscoveryRequest.$mode.withValue(.failure) { try await f.bootstrap.refreshHomes() }
            XCTFail("The current discovery failure must propagate")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertNotNil(f.bootstrap.homeDiscoveryError)
        let current = try await ready(f.bootstrap)
        XCTAssertEqual(current.presentation.id, original.presentation.id)
        await gate.open()
        try await older.value
        XCTAssertNotNil(f.bootstrap.homeDiscoveryError)
        XCTAssertTrue(f.bootstrap.homeSharingStatus.sections.contains { $0.id == .localChecks })
    }

    func testLocalReadFailureRemainsVisibleWithoutPretendingAssociationFailure() async throws {
        let f = try await open(read: { _, _ in throw Failure.expected })
        await f.bootstrap.refreshSharingStatus()
        XCTAssertFalse(f.bootstrap.isCheckingSharingStatus)
        XCTAssertTrue(f.bootstrap.homeSharingStatus.sections.contains { $0.id == .localChecks })
        XCTAssertNil(f.bootstrap.shareAssociationError)
        XCTAssertTrue(try savedWork(f.bootstrap).contains("not yet known"))
    }
}
