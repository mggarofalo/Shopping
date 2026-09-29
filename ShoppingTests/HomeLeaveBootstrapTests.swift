import CloudKit
import CoreData
import XCTest
@testable import Shopping

@MainActor
final class HomeLeaveBootstrapTests: XCTestCase {
    private enum Failure: Error { case native, timeout }
    private actor AccountIdentity {
        private var name = "account-A"
        func current() -> String { name }
        func change() { name = "account-B" }
    }
    private actor HeldCallback {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var announced = false
        func hold(started: @Sendable () -> Void) async {
            guard !released else { return }
            await withCheckedContinuation {
                continuations.append($0)
                if !announced { announced = true; started() }
            }
        }
        func release() {
            released = true
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }
    private final class NativeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var zoneCount = 0
        private var fails = false
        private var exists = true
        private var zoneWait: (@Sendable () async -> Void)?
        var purgeCount: Int { lock.withLock { count } }
        var zoneQueryCount: Int { lock.withLock { zoneCount } }
        func failPurge() { lock.withLock { fails = true } }
        func zoneAbsent() { lock.withLock { exists = false } }
        func holdZone(_ wait: @escaping @Sendable () async -> Void) { lock.withLock { zoneWait = wait } }
        func beginPurge() throws {
            let shouldFail = lock.withLock { count += 1; return fails }
            if shouldFail { throw Failure.native }
        }
        func zoneExists() async -> Bool {
            let snapshot = lock.withLock { zoneCount += 1; return (exists, zoneWait) }
            if let wait = snapshot.1 { await wait() }
            return snapshot.0
        }
    }
    private struct Backend: HomeLeaveBackend, @unchecked Sendable {
        let cart: PersonalCartService
        let provider: ShopperSessionProvider
        let session: ShopperSession
        let identity: HomeNativeAccessIdentity
        let participantURL: URL
        let probe: NativeProbe

        func validateEnvironment(identity: HomeNativeAccessIdentity, storeURL: URL?) throws -> ShopperSession {
            guard case .ready(let verified) = provider.state, verified == session,
                  try provider.currentSession() == session else { throw PersonalCartError.accountChanged }
            guard identity == self.identity,
                  let store = cart.persistence.container.persistentStoreCoordinator.persistentStores.first(where: { $0.url == participantURL }),
                  store.identifier == identity.storeIdentifier,
                  storeURL == nil || storeURL?.standardizedFileURL == participantURL.standardizedFileURL else {
                throw PersonalCartError.scopeChanged
            }
            return session
        }
        func validateMapping(identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws {
            guard identity == self.identity, repository.persistence === cart.persistence,
                  repository.session == session else { throw PersonalCartError.scopeChanged }
        }
        func membership(identity: HomeNativeAccessIdentity) async throws -> HomeLeaveMembership {
            guard identity == self.identity else { throw PersonalCartError.scopeChanged }
            return HomeLeaveMembership(share: identity.share, isPrivateShare: true,
                currentParticipant: .init(id: "participant", role: .privateUser, acceptance: .accepted, permission: .readWrite),
                privateParticipantIDs: ["participant"])
        }
        func purge(_ command: HomeLeaveCommand, storeIdentity: ObjectIdentifier) async throws -> HomeLeaveZone {
            guard let store = cart.persistence.container.persistentStoreCoordinator.persistentStores.first(where: { $0.url == participantURL }),
                  ObjectIdentifier(store) == storeIdentity, command.origin == identity else { throw PersonalCartError.scopeChanged }
            try probe.beginPurge()
            try HomeLeaveBootstrapTests.deleteGraph(cart.persistence, identity: identity)
            return HomeLeaveZone(share: identity.share)
        }
        func zoneExists(_ command: HomeLeaveCommand) async throws -> Bool {
            guard command.origin == identity else { throw PersonalCartError.scopeChanged }
            return await probe.zoneExists()
        }
    }
    private struct Fixture: @unchecked Sendable {
        let directory: URL
        let privateURL: URL
        let participantURL: URL
        let defaults: UserDefaults
        let provider: ShopperSessionProvider
        let account: AccountIdentity
        let session: ShopperSession
        let original: HomeGraphIdentity
        let participant: HomeGraphIdentity
        let boughtNeed: UUID
        let pendingNeed: UUID
        let probe: NativeProbe
        var identity: HomeNativeAccessIdentity {
            HomeNativeAccessIdentity(scope: HomeEffectScope(session: session, householdID: participant.householdID, listID: participant.listID),
                storeIdentifier: participant.storeIdentifier, rootURI: participant.rootURI,
                share: HomeEffectShare(recordName: "participant-share", zoneName: "participant-zone", zoneOwnerName: "owner"))
        }
    }

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let privateURL = directory.appendingPathComponent("Private.sqlite")
        let participantURL = directory.appendingPathComponent("Participant.sqlite")
        let suite = "HomeLeaveBootstrap." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        let account = AccountIdentity()
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.leave-bootstrap", environment: "Development",
            cacheDirectory: directory.appendingPathComponent("Bindings"),
            lookup: .init(status: { .available }, recordName: { await account.current() }))
        await provider.refresh()
        let session = try provider.currentSession()
        let privateStore = try PersistenceController(storeURL: privateURL)
        _ = try NeedService(persistence: privateStore).createHousehold(name: "Unrelated private home")
        let original = try XCTUnwrap(HomeDiscoveryService(persistence: privateStore).discover().homes.first?.graph)
        try Self.close(privateStore)
        let shared = try PersistenceController(storeURL: participantURL)
        let needs = NeedService(persistence: shared)
        let home = try needs.createHousehold(name: "Participant home")
        let bought = try needs.addOneTimeNeed(title: "History milk", quantity: 1, householdID: home.householdID, listID: home.listID)
        let pending = try needs.addOneTimeNeed(title: "Retained bananas", quantity: 2, householdID: home.householdID, listID: home.listID)
        let participant = try XCTUnwrap(HomeDiscoveryService(persistence: shared).discover().homes.first?.graph)
        try Self.close(shared)
        return Fixture(directory: directory, privateURL: privateURL, participantURL: participantURL, defaults: defaults,
            provider: provider, account: account, session: session, original: original, participant: participant,
            boughtNeed: bought, pendingNeed: pending, probe: NativeProbe())
    }

    private func open(_ f: Fixture, selectingParticipant: Bool = true,
        accountProvider: ShopperSessionProvider? = nil) async throws -> PersistenceBootstrap {
        let provider = accountProvider ?? f.provider
        let bootstrap = PersistenceBootstrap(defaults: f.defaults,
            makeAccountProvider: { _ in provider }, accountStoreDirectory: { f.directory },
            participantStoreForHomeChoice: { persistence in
                persistence.container.persistentStoreCoordinator.persistentStores.first { $0.url == f.participantURL }
            }, invitationShareIdentity: { _, _, graph in
                guard graph == f.participant else { return nil }
                return HomeShareIdentity(recordName: f.identity.share.recordName,
                    zoneName: f.identity.share.zoneName, zoneOwnerName: f.identity.share.zoneOwnerName)
            }, makeHomeLeaveTransport: { cart in
                ManagedHomeLeaveTransport(cart: cart, persistence: cart.persistence,
                    backend: Backend(cart: cart, provider: provider, session: f.session, identity: f.identity,
                        participantURL: f.participantURL, probe: f.probe))
            }, activateAccountStore: { source, session, _, importing in
                XCTAssertNil(source)
                XCTAssertFalse(importing)
                if session == f.session {
                    return .local(storeURL: f.privateURL, additionalStoreURLs: [f.participantURL])
                }
                // An account switch must never reopen account A's private data.
                let directory = f.directory.appendingPathComponent(session.accountBinding, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return .local(storeURL: directory.appendingPathComponent("Private.sqlite"),
                    additionalStoreURLs: [directory.appendingPathComponent("Participant.sqlite")])
            })
        addTeardownBlock { @MainActor in try await self.retire(bootstrap) }
        bootstrap.activatePersonalCarts(importLegacy: false)
        await bootstrap.runLoadingTransition()
        _ = try await ready(bootstrap)
        if selectingParticipant {
            try await bootstrap.selectHome(f.participant)
            _ = try await ready(bootstrap)
        }
        return bootstrap
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

    private func retire(_ bootstrap: PersistenceBootstrap) async throws {
        // retireAndFail cannot replace a pending account transition. Finish that
        // transition and its asynchronous store load before requesting retirement.
        if case .loading = bootstrap.state {
            await bootstrap.runLoadingTransition()
            _ = try await ready(bootstrap)
        }
        guard case .ready(let value) = bootstrap.state else { return }
        bootstrap.presentationDidDisappear(value.presentation.id)
        bootstrap.retireAndFail(ShopperSessionError.temporarilyUnavailable)
        await bootstrap.runLoadingTransition()
        XCTAssertTrue(value.persistence.container.persistentStoreCoordinator.persistentStores.isEmpty,
            "Fixture files must remain until the runtime has detached its stores")
        guard case .failed = bootstrap.state else { return XCTFail("Retirement did not settle") }
    }

    nonisolated private static func close(_ persistence: PersistenceController) throws {
        persistence.writer.performAndWait { persistence.writer.reset() }
        persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
    }

    nonisolated private static func deleteGraph(_ persistence: PersistenceController, identity: HomeNativeAccessIdentity) throws {
        let context = persistence.container.newBackgroundContext()
        try context.performAndWait {
            defer { context.reset() }
            for home in try context.fetch(Household.fetchRequest()) where home.id == identity.scope.householdID { context.delete(home) }
            for list in try context.fetch(GroceryList.fetchRequest()) where list.id == identity.scope.listID { context.delete(list) }
            try context.save()
        }
    }

    private func seedPrivateHistory(_ f: Fixture, bootstrap: PersistenceBootstrap) async throws -> PersonalCartService {
        let runtime = try await ready(bootstrap)
        let cart = PersonalCartService(persistence: runtime.persistence, sessionProvider: f.provider)
        let scope = f.identity.scope
        try cart.cart(needID: f.boughtNeed, householdID: scope.householdID, listID: scope.listID)
        let checkout = try cart.prepareCheckout(tokens: cart.entries(householdID: scope.householdID, listID: scope.listID).map(\.token))
        _ = try cart.checkout(checkout, operationID: UUID())
        try cart.cart(needID: f.pendingNeed, householdID: scope.householdID, listID: scope.listID)
        return cart
    }

    func testConfirmedLeaveRemovesParticipantRootAndKeepsPrivateDataWithoutSelectingAnotherHome() async throws {
        let f = try await fixture(), bootstrap = try await open(f)
        let cart = try await seedPrivateHistory(f, bootstrap: bootstrap)
        let runtime = try await ready(bootstrap)
        let scope = try XCTUnwrap(runtime.homeScope)
        let history = try cart.history(householdID: scope.graph.householdID, listID: scope.graph.listID)
        let records = try cart.transact(save: false) { try $0.values(PersonalCartCommandResult.self, kind: "cart") }
        let command = try await bootstrap.prepareHomeLeave(scope: scope)
        XCTAssertTrue(try cart.retainedHomeLeaves().isEmpty)
        let result = try await bootstrap.confirmHomeLeave(command, scope: scope)
        XCTAssertTrue(result.completed)
        await bootstrap.refreshHomeLeaveStatuses(reconcile: false)
        try await bootstrap.refreshHomes()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.homeCoordinator.homes.map(\.graph) != [f.original], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(f.probe.purgeCount, 1)
        XCTAssertNil(bootstrap.homeCoordinator.activeScope, "Leaving must not silently select the unrelated private home")
        XCTAssertEqual(bootstrap.homeCoordinator.homes.map(\.graph), [f.original])
        XCTAssertEqual(try cart.history(householdID: scope.graph.householdID, listID: scope.graph.listID), history)
        XCTAssertEqual(try cart.transact(save: false) { try $0.values(PersonalCartCommandResult.self, kind: "cart") }, records)
        XCTAssertEqual(bootstrap.homeLeaveStatuses.first?.command, command)
        XCTAssertEqual(bootstrap.homeLeaveStatuses.first?.completed, true)
    }

    func testSubmittedLeaveReconcilesAfterRootIsGoneAndBootstrapReopensWithoutRepurging() async throws {
        let f = try await fixture(), bootstrap = try await open(f)
        let cart = try await seedPrivateHistory(f, bootstrap: bootstrap)
        let runtime = try await ready(bootstrap)
        let scope = try XCTUnwrap(runtime.homeScope)
        let command = try await bootstrap.prepareHomeLeave(scope: scope)
        f.probe.failPurge()
        do { _ = try await bootstrap.confirmHomeLeave(command, scope: scope); XCTFail("Native uncertainty must remain visible") }
        catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(f.probe.purgeCount, 1)
        XCTAssertTrue(try XCTUnwrap(cart.retainedHomeLeaves().first).submitted)
        try Self.deleteGraph(runtime.persistence, identity: f.identity)
        try await retire(bootstrap)
        f.probe.zoneAbsent()
        let reopened = try await open(f, selectingParticipant: false)
        await reopened.refreshHomeLeaveStatuses()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reopened.homeLeaveStatuses.first?.completed != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reopened.homeLeaveStatuses.first?.command, command)
        XCTAssertEqual(reopened.homeLeaveStatuses.first?.completed, true)
        XCTAssertFalse(try XCTUnwrap(reopened.homeLeaveStatuses.first).requiresResolution)
        XCTAssertEqual(f.probe.purgeCount, 1)
        XCTAssertNotEqual(reopened.homeCoordinator.activeScope?.graph, f.participant)
    }

    func testCachedOfflineRelaunchShowsLocalLeaveStatusWithoutNativeChecksOrResume() async throws {
        let f = try await fixture(), online = try await open(f)
        let runtime = try await ready(online)
        let scope = try XCTUnwrap(runtime.homeScope)
        let submitted = try await online.prepareHomeLeave(scope: scope)
        f.probe.failPurge()
        do { _ = try await online.confirmHomeLeave(submitted, scope: scope); XCTFail("Expected native uncertainty") }
        catch { XCTAssertTrue(error is Failure) }
        let unsubmitted = HomeLeaveCommand(id: UUID(), origin: submitted.origin, storeURL: submitted.storeURL,
            participantID: submitted.participantID, homeName: submitted.homeName,
            evidence: submitted.evidence, confirmedAt: Date())
        let cart = PersonalCartService(persistence: runtime.persistence, sessionProvider: f.provider)
        try cart.retainHomeLeave(unsubmitted)
        try await retire(online)
        let queriesBeforeReopen = f.probe.zoneQueryCount
        let purgesBeforeReopen = f.probe.purgeCount

        // Load the saved account binding into a new provider and bootstrap while
        // every live identity lookup fails with an actual temporary network error.
        let offline = try ShopperSessionProvider(containerIdentifier: f.session.containerIdentifier,
            environment: f.session.environment, cacheDirectory: f.directory.appendingPathComponent("Bindings"),
            lookup: .init(status: { throw CKError(.networkUnavailable) },
                recordName: { throw CKError(.networkUnavailable) }))
        let reopened = try await open(f, selectingParticipant: false, accountProvider: offline)
        XCTAssertEqual(offline.state, .cached(f.session))
        await reopened.refreshHomeLeaveStatuses()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reopened.homeLeaveStatuses.count != 2 || reopened.isCheckingHomeLeaves {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        let submittedStatus = try XCTUnwrap(reopened.homeLeaveStatuses.first { $0.id == submitted.id })
        let unsubmittedStatus = try XCTUnwrap(reopened.homeLeaveStatuses.first { $0.id == unsubmitted.id })
        XCTAssertEqual(submittedStatus.command, submitted)
        XCTAssertTrue(submittedStatus.submitted)
        XCTAssertFalse(submittedStatus.completed)
        XCTAssertEqual(unsubmittedStatus.command, unsubmitted)
        XCTAssertFalse(unsubmittedStatus.submitted)
        XCTAssertTrue(reopened.homeLeaveIsOnThisDevice(submitted))
        XCTAssertTrue(reopened.homeLeaveIsOnThisDevice(unsubmitted))
        XCTAssertFalse(reopened.canResumeHomeLeave(unsubmittedStatus), "Cached identity permits local status, not destructive resume")
        do { try await reopened.resumeHomeLeave(unsubmitted); XCTFail("Offline account cannot resume native leave") }
        catch { XCTAssertTrue(error is HomeMembershipError) }
        XCTAssertNil(reopened.homeLeaveStatusError)
        XCTAssertFalse(reopened.isCheckingHomeLeaves)
        XCTAssertEqual(f.probe.zoneQueryCount, queriesBeforeReopen)
        XCTAssertEqual(f.probe.purgeCount, purgesBeforeReopen)
    }

    func testLateStatusReconciliationAfterAccountChangeCannotPublishOriginalResults() async throws {
        let f = try await fixture(), bootstrap = try await open(f)
        let runtime = try await ready(bootstrap)
        let scope = try XCTUnwrap(runtime.homeScope)
        let command = try await bootstrap.prepareHomeLeave(scope: scope)
        f.probe.failPurge()
        do { _ = try await bootstrap.confirmHomeLeave(command, scope: scope); XCTFail("Expected native failure") }
        catch { XCTAssertTrue(error is Failure) }
        let held = HeldCallback(), started = expectation(description: "Original account zone observation held")
        f.probe.holdZone { await held.hold { started.fulfill() } }
        let refresh = Task { await bootstrap.refreshHomeLeaveStatuses() }
        await fulfillment(of: [started], timeout: 3)
        let previousTransition = bootstrap.loadingTransitionID
        await f.account.change()
        await f.provider.refresh()
        await held.release()
        await refresh.value
        XCTAssertTrue(bootstrap.homeLeaveStatuses.isEmpty)

        // The account notification queues a new loading transition on MainActor.
        // Driving only teardown would run its account-B activation action and
        // return before the detached load, racing fixture directory removal.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.loadingTransitionID == previousTransition {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        await bootstrap.runLoadingTransition()
        let replacement = try await ready(bootstrap)
        let currentSession = try f.provider.currentSession()
        XCTAssertNotEqual(currentSession.accountBinding, f.session.accountBinding)
        XCTAssertEqual(replacement.persistence.personalCartInitialBinding, currentSession.accountBinding)
        XCTAssertEqual(replacement.persistence.primaryStore?.url,
            f.directory.appendingPathComponent(currentSession.accountBinding).appendingPathComponent("Private.sqlite"))
        await bootstrap.refreshHomeLeaveStatuses(reconcile: false)
        while bootstrap.isCheckingHomeLeaves {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(bootstrap.homeLeaveStatuses.isEmpty)
        XCTAssertFalse(bootstrap.isCheckingHomeLeaves)
        XCTAssertEqual(f.probe.purgeCount, 1)
    }

    func testRetainedUnsubmittedLeaveCanResumeOnlyForOriginalDeviceStore() async throws {
        let f = try await fixture(), bootstrap = try await open(f)
        let runtime = try await ready(bootstrap)
        let scope = try XCTUnwrap(runtime.homeScope)
        let command = try await bootstrap.prepareHomeLeave(scope: scope)
        let cart = PersonalCartService(persistence: runtime.persistence, sessionProvider: f.provider)
        try cart.retainHomeLeave(command)
        await bootstrap.refreshHomeLeaveStatuses(reconcile: false)
        let status = try XCTUnwrap(bootstrap.homeLeaveStatuses.first)
        XCTAssertFalse(status.submitted)
        XCTAssertTrue(bootstrap.canResumeHomeLeave(status))
        try await bootstrap.resumeHomeLeave(command)
        XCTAssertEqual(f.probe.purgeCount, 1)
        XCTAssertNil(bootstrap.homeLeaveResumingID)
        let foreignIdentity = HomeNativeAccessIdentity(scope: command.origin.scope, storeIdentifier: "another-device-store",
            rootURI: command.origin.rootURI, share: command.origin.share)
        let foreign = HomeLeaveCommand(id: UUID(), origin: foreignIdentity,
            storeURL: f.directory.appendingPathComponent("AnotherDevice.sqlite"), participantID: command.participantID,
            homeName: command.homeName, evidence: command.evidence, confirmedAt: Date())
        try cart.retainHomeLeave(foreign)
        await bootstrap.refreshHomeLeaveStatuses(reconcile: false)
        let foreignStatus = try XCTUnwrap(bootstrap.homeLeaveStatuses.first { $0.id == foreign.id })
        XCTAssertFalse(bootstrap.canResumeHomeLeave(foreignStatus))
        do { try await bootstrap.resumeHomeLeave(foreign); XCTFail("Another device's authorization cannot purge this store") }
        catch { }
        XCTAssertEqual(f.probe.purgeCount, 1)
        XCTAssertFalse(try XCTUnwrap(cart.retainedHomeLeaves().first { $0.id == foreign.id }).submitted)
    }
}
