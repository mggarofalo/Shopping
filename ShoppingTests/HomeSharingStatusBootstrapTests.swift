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

    private func ready(_ bootstrap: PersistenceBootstrap,
                       matching predicate: (PersistenceBootstrap.ReadyState) -> Bool = { _ in true }) async throws
        -> PersistenceBootstrap.ReadyState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if case .ready(let value) = bootstrap.state, predicate(value) { return value }
            if case .failed(let error) = bootstrap.state { throw error }
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func awaitAccess(_ fixture: Fixture, graph: HomeGraphIdentity, access: HomeCandidate.Access) async throws {
        // Discovery can renew presentation authority when access changes. Keep
        // the explicit account/Home choice, then await its coherent new view.
        let session = try fixture.provider.currentSession()
        let bootstrap = fixture.bootstrap
        let selectedScope = try XCTUnwrap(bootstrap.homeCoordinator.activeScope)
        let choice = bootstrap.homeCoordinator.choiceAuthority
        try await bootstrap.refreshHomes()
        try await FixtureReadiness.wait(changes: [bootstrap.objectWillChange.eraseToAnyPublisher()]) {
            try self.accessPrerequisites(fixture, graph: graph, access: access,
                session: session, selectedScope: selectedScope, choice: choice)
        }
    }

    private func accessPrerequisites(_ fixture: Fixture, graph: HomeGraphIdentity,
                                     access: HomeCandidate.Access, session: ShopperSession,
                                     selectedScope: ActiveHomeScope, choice: UICommandAuthority) throws -> [String] {
        let bootstrap = fixture.bootstrap
        if case .failed(let error) = bootstrap.state { throw error }
        guard try fixture.provider.currentSession() == session else { throw PersonalCartError.accountChanged }
        try choice.validate()
        guard bootstrap.homeCoordinator.activeScope == selectedScope else { throw UICommandAuthority.Failure.retired }
        guard case .ready(let current) = bootstrap.state else { return ["ready presentation for \(graph)"] }
        return [
            FixtureReadiness.mismatch("selected Home presentation", actual: current.homeScope, expected: selectedScope),
            FixtureReadiness.mismatch("current Home authority", actual: current.homeGeneration,
                expected: bootstrap.homeCoordinator.generation),
            FixtureReadiness.mismatch("active presentation", actual: current.presentation.isActive, expected: true),
            FixtureReadiness.mismatch("access for \(graph)",
            actual: bootstrap.homeCoordinator.homes.first { $0.graph == graph }?.access,
            expected: access)
        ].compactMap { $0 }
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

    func testAccessFixtureWaitsForDiscoveryAfterSelection() async throws {
        let gate = Gate(), started = expectation(description: "fresh discovery held")
        let fixture = try await open(discover: { service in
            if DiscoveryRequest.mode == .heldSuccess { started.fulfill(); await gate.wait() }
            return try await Task.detached { try service.discover() }.value
        })
        let graph = try XCTUnwrap(fixture.bootstrap.homeCoordinator.activeScope?.graph)
        var nextActionRan = false
        let barrier = Task {
            try await DiscoveryRequest.$mode.withValue(.heldSuccess) {
                try await self.awaitAccess(fixture, graph: graph, access: .owner)
            }
            nextActionRan = true
        }
        await fulfillment(of: [started], timeout: 2)
        // The old ready-store predicate already passes while discovery is held.
        do { _ = try await ready(fixture.bootstrap) }
        catch { await gate.open(); _ = try? await barrier.value; throw error }
        XCTAssertFalse(nextActionRan)
        await gate.open()
        try await barrier.value
        XCTAssertTrue(nextActionRan)
    }

    func testAccessFixtureRejectsHomeSwitchDuringHeldDiscovery() async throws {
        let gate = Gate(), started = expectation(description: "old presentation discovery held")
        let fixture = try await open(discover: { service in
            let snapshot = try await Task.detached { try service.discover() }.value
            if DiscoveryRequest.mode == .heldSuccess { started.fulfill(); await gate.wait() }
            return snapshot
        })
        let graph = try XCTUnwrap(fixture.bootstrap.homeCoordinator.activeScope?.graph)
        let other = try XCTUnwrap(fixture.bootstrap.homeCoordinator.homes.first { $0.graph != graph }?.graph)
        let barrier = Task {
            try await DiscoveryRequest.$mode.withValue(.heldSuccess) {
                try await self.awaitAccess(fixture, graph: graph, access: .owner)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        do { try await fixture.bootstrap.selectHome(other) }
        catch { await gate.open(); _ = try? await barrier.value; throw error }
        await gate.open()
        do { try await barrier.value; XCTFail("A fresh Home cannot authorize the old fixture action") }
        catch { XCTAssertEqual(error as? UICommandAuthority.Failure, .retired) }
    }

    func testAccessFixtureAcceptsFreshAccessThatRenewsTheSameHomePresentation() async throws {
        let gate = Gate(), started = expectation(description: "access-changing fixture discovery held")
        let startup = expectation(description: "startup discovery has begun")
        let fixture = try await open(discover: { service in
            let snapshot = try await Task.detached { try service.discover() }.value
            guard DiscoveryRequest.mode == .heldSuccess else {
                startup.fulfill()
                return snapshot
            }
            started.fulfill()
            await gate.wait()
            return HomeDiscovery(homes: snapshot.homes.map {
                HomeCandidate(graph: $0.graph, name: $0.name, access: .restricted)
            }, hasIncompleteRoots: snapshot.hasIncompleteRoots)
        })
        await fulfillment(of: [startup], timeout: 2)
        let before = try await ready(fixture.bootstrap)
        let scope = try XCTUnwrap(before.homeScope)
        let choice = fixture.bootstrap.homeCoordinator.choiceAuthority
        let barrier = Task {
            try await DiscoveryRequest.$mode.withValue(.heldSuccess) {
                try await self.awaitAccess(fixture, graph: scope.graph, access: .restricted)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        // Only this request can change access, after awaitAccess captured its witnesses.
        // Startup discovery always returns the original owner access.
        XCTAssertTrue(before.presentation.isActive)
        await gate.open()
        try await barrier.value
        let after = try await ready(fixture.bootstrap)
        XCTAssertEqual(after.homeScope, scope)
        XCTAssertTrue(choice.isActive, "Discovery cannot replace the explicit Home choice")
        XCTAssertFalse(before.presentation.isActive)
        XCTAssertNotEqual(after.presentation.id, before.presentation.id)
        XCTAssertEqual(after.homeGeneration, fixture.bootstrap.homeCoordinator.generation)
        XCTAssertTrue(after.presentation.isActive)
    }

    func testAccessFixtureRejectsRenewedChoiceOfSameHomeDuringHeldDiscovery() async throws {
        let gate = Gate(), started = expectation(description: "old choice discovery held")
        let fixture = try await open(discover: { service in
            let snapshot = try await Task.detached { try service.discover() }.value
            if DiscoveryRequest.mode == .heldSuccess { started.fulfill(); await gate.wait() }
            return snapshot
        })
        let graph = try XCTUnwrap(fixture.bootstrap.homeCoordinator.activeScope?.graph)
        let barrier = Task {
            try await DiscoveryRequest.$mode.withValue(.heldSuccess) {
                try await self.awaitAccess(fixture, graph: graph, access: .owner)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        do {
            try fixture.bootstrap.homeCoordinator.select(graph, renewingAuthority: true)
            try await fixture.bootstrap.refreshHomes()
        } catch { await gate.open(); _ = try? await barrier.value; throw error }
        await gate.open()
        do { try await barrier.value; XCTFail("A renewed choice cannot authorize the old fixture action") }
        catch { XCTAssertEqual(error as? UICommandAuthority.Failure, .retired) }
    }

    func testAccessFixtureRejectsAccountChangeDuringHeldDiscovery() async throws {
        let gate = Gate(), started = expectation(description: "old account discovery held")
        let fixture = try await open(discover: { service in
            let snapshot = try await Task.detached { try service.discover() }.value
            if DiscoveryRequest.mode == .heldSuccess { started.fulfill(); await gate.wait() }
            return snapshot
        })
        let graph = try XCTUnwrap(fixture.bootstrap.homeCoordinator.activeScope?.graph)
        let barrier = Task {
            try await DiscoveryRequest.$mode.withValue(.heldSuccess) {
                try await self.awaitAccess(fixture, graph: graph, access: .owner)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await fixture.account.change()
        await fixture.provider.refresh()
        await gate.open()
        do { try await barrier.value; XCTFail("Another account cannot authorize the old fixture action") }
        catch { XCTAssertEqual(error as? PersonalCartError, .accountChanged) }
    }

    func testAccessFixturePropagatesDiscoveryFailure() async throws {
        let startup = expectation(description: "startup discovery has begun")
        let fixture = try await open(discover: { service in
            if DiscoveryRequest.mode == .failure { throw Failure.expected }
            startup.fulfill()
            return try await Task.detached { try service.discover() }.value
        })
        // The explicit failure must be newer than startup discovery: production
        // correctly discards failures from superseded discovery requests.
        await fulfillment(of: [startup], timeout: 2)
        let graph = try XCTUnwrap(fixture.bootstrap.homeCoordinator.activeScope?.graph)
        do {
            try await DiscoveryRequest.$mode.withValue(.failure) {
                try await awaitAccess(fixture, graph: graph, access: .owner)
            }
            XCTFail("Discovery failure cannot satisfy fixture readiness")
        } catch { XCTAssertTrue(error is Failure) }
    }

    func testUnresolvedInspectedHomeStillAllowsAccountAndAccessCheck() async throws {
        let f = try await open(discover: { service in
            let result = try await Task.detached { try service.discover() }.value
            return HomeDiscovery(homes: result.homes.sorted { $0.name < $1.name }.map {
                HomeCandidate(graph: $0.graph, name: $0.name,
                    access: $0.name == "Second home" ? .unresolved : .owner)
            }, hasIncompleteRoots: result.hasIncompleteRoots)
        })
        let target = try XCTUnwrap(f.bootstrap.homeCoordinator.homes.first { $0.name == "Second home" })
        let scope = try XCTUnwrap(f.bootstrap.homeDetailsScope(for: target.graph))
        let before = await f.account.reads
        await f.bootstrap.checkSharingStatus(scope: scope)
        let after = await f.account.reads
        XCTAssertGreaterThan(after, before)
        XCTAssertFalse(f.bootstrap.isCheckingSharingStatus)
    }

    func testInactiveDetailsShowTheirOwnAccessAndReadTheirOwnSavedWork() async throws {
        let f = try await open(discover: { service in
            let result = try await Task.detached { try service.discover() }.value
            return HomeDiscovery(homes: result.homes.sorted { $0.name < $1.name }.map {
                HomeCandidate(graph: $0.graph, name: $0.name,
                    access: $0.name == "First home" ? .restricted : .owner)
            }, hasIncompleteRoots: result.hasIncompleteRoots)
        }, read: { service, scope in try Self.snapshot(service, scope, count: 7) })
        let bootstrap = f.bootstrap
        let observedHome = try XCTUnwrap(bootstrap.homeCoordinator.homes.first { $0.name == "First home" }?.graph)
        try await awaitAccess(f, graph: observedHome, access: .restricted)
        try await bootstrap.selectHome(XCTUnwrap(bootstrap.homeCoordinator.homes.first { $0.name == "First home" }?.graph))
        let original = try await ready(bootstrap)
        let target = try XCTUnwrap(bootstrap.homeCoordinator.homes.first { $0.name == "Second home" })
        let scope = try XCTUnwrap(bootstrap.homeDetailsScope(for: target.graph))
        XCTAssertNotEqual(scope, original.homeScope)
        let selectedHome = try XCTUnwrap(bootstrap.homeSharingStatus.sections.first { $0.id == .home })
        let inspectedHome = try XCTUnwrap(bootstrap.homeSharingStatus(for: scope).sections.first { $0.id == .home })
        XCTAssertNotEqual(selectedHome.presentation, inspectedHome.presentation)
        await bootstrap.refreshSharingStatus(scope: scope)
        let work = try XCTUnwrap(bootstrap.homeSharingStatus(for: scope).sections.first { $0.id == .savedWork })
        XCTAssertTrue(work.presentation.details.contains("7"))
        XCTAssertFalse(try savedWork(bootstrap).contains("7"))
        let current = try await ready(bootstrap)
        XCTAssertEqual(current.homeScope, original.homeScope)
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
        XCTAssertNil(f.bootstrap.sharingStatusCheckProblem)
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
        addTeardownBlock {
            await gate.open()
            try await self.drain(f.bootstrap)
        }
        let before = try await ready(f.bootstrap)
        let graph = try XCTUnwrap(before.homeScope?.graph)
        let check = Task { await f.bootstrap.refreshSharingStatus() }
        await fulfillment(of: [started], timeout: 2)
        try f.bootstrap.homeCoordinator.select(graph, renewingAuthority: true)
        try await f.bootstrap.refreshHomes()
        // A newer discovery can own publication after refreshHomes returns.
        // Observe the renewed authority before releasing the captured old read.
        let after = try await ready(f.bootstrap, matching: {
            $0.homeScope == before.homeScope
                && $0.homeGeneration == f.bootstrap.homeCoordinator.generation
                && $0.homeGeneration > before.homeGeneration
                && $0.presentation.id != before.presentation.id
        })
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
        XCTAssertEqual(f.bootstrap.sharingStatusCheckProblem, "The check took too long. Try again.")
        await f.bootstrap.checkSharingStatus()
        XCTAssertFalse(f.bootstrap.isCheckingSharingStatus)
        XCTAssertTrue(f.bootstrap.sharingStatusCheckMessage?.contains("still finishing") == true)
        XCTAssertEqual(f.bootstrap.sharingStatusCheckProblem, "The previous check is still finishing. Try again shortly.")
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
        while true {
            if case .loading = f.bootstrap.state { await f.bootstrap.runLoadingTransition() }
            if case .ready(let current) = f.bootstrap.state,
               current.persistence.personalCartInitialBinding == (try f.provider.currentSession()).accountBinding { return }
            guard ContinuousClock.now < end else { return XCTFail("Account transition did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
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
        XCTAssertEqual(f.bootstrap.sharingStatusCheckProblem, "Couldn’t check status. Try again.")
        XCTAssertTrue(try savedWork(f.bootstrap).contains("not yet known"))
    }
}
