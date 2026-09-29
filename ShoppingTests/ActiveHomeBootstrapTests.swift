import XCTest
@testable import Shopping

@MainActor
final class ActiveHomeBootstrapTests: XCTestCase {
    private func makeBootstrap(homeCount: Int, pendingInvitation: Bool = false) async throws -> PersistenceBootstrap {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "HomeBootstrap." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let accountURL = root.appendingPathComponent("Account.sqlite")
        let persistence = try PersistenceController(storeURL: accountURL)
        for index in 0..<homeCount {
            _ = try NeedService(persistence: persistence).createHousehold(name: "Home \(index + 1)")
        }
        var invitations: HomeInvitationController?
        if pendingInvitation {
            let inbox = try HomeInvitationInbox(url: root.appendingPathComponent("invitations.json"),
                containerIdentifier: "iCloud.test.home-bootstrap", environment: "Development")
            try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: "iCloud.test.home-bootstrap",
                environment: "Development", share: HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")),
                metadataArchive: Data([1]))
            invitations = HomeInvitationController(inbox: inbox)
        }
        let bootstrap = PersistenceBootstrap(
            configuration: { .local(storeURL: root.appendingPathComponent("Legacy.sqlite")) },
            defaults: defaults, invitations: invitations,
            makeAccountProvider: { base in
                try ShopperSessionProvider(containerIdentifier: "iCloud.test.home-bootstrap", environment: "Development",
                    cacheDirectory: base.appendingPathComponent("Bindings"), lookup: .init(
                        status: { .available }, recordName: { "account-A" }))
            },
            accountStoreDirectory: { root },
            activateAccountStore: { _, _, _, _ in .local(storeURL: accountURL) }
        )
        bootstrap.start()
        try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        try await waitForReady(bootstrap)
        return bootstrap
    }

    private func waitForReady(_ bootstrap: PersistenceBootstrap) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if case .ready = bootstrap.state { return }
            if case .failed(let error) = bootstrap.state { throw error }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Bootstrap did not reach ready state")
    }

    private func ready(_ bootstrap: PersistenceBootstrap) throws -> PersistenceBootstrap.ReadyState {
        guard case .ready(let ready) = bootstrap.state else {
            throw NSError(domain: "HomeBootstrapTests", code: 1)
        }
        return ready
    }

    func testColdInvitationDoesNotCreateAnEmptyLocalHomeBeforeAccountSetup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let inbox = try HomeInvitationInbox(url: root.appendingPathComponent("invites/inbox.json"),
            containerIdentifier: "iCloud.test.home-bootstrap", environment: "Development")
        try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: "iCloud.test.home-bootstrap",
            environment: "Development", share: HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")),
            metadataArchive: Data([1]))
        let bootstrap = PersistenceBootstrap(configuration: { .local(storeURL: root.appendingPathComponent("Local.sqlite")) },
            invitations: HomeInvitationController(inbox: inbox))
        bootstrap.start()
        try await waitForReady(bootstrap)
        XCTAssertNil(try ready(bootstrap).householdID)
        XCTAssertTrue(try ready(bootstrap).service.isPersistentStoreEmpty())
    }

    func testColdInvitationRestoresSelectionHoldBeforeFirstHomeDiscovery() async throws {
        let bootstrap = try await makeBootstrap(homeCount: 1, pendingInvitation: true)
        XCTAssertTrue(bootstrap.homeCoordinator.pendingInvitation)
        XCTAssertNil(try ready(bootstrap).homeScope)
        XCTAssertEqual(bootstrap.homeCoordinator.readiness, .choiceRequired)
        XCTAssertEqual(bootstrap.homeCoordinator.homes.count, 1)
        XCTAssertTrue(try XCTUnwrap(bootstrap.invitations).hasPendingActivation)
    }

    func testTwoHomesRequireChoiceAndSwitchRetiresCapturedCommands() async throws {
        let bootstrap = try await makeBootstrap(homeCount: 2)
        XCTAssertEqual(bootstrap.homeCoordinator.readiness, .choiceRequired)
        XCTAssertNil(try ready(bootstrap).householdID)
        let homes = bootstrap.homeCoordinator.homes
        try await bootstrap.selectHome(homes[0].graph)
        let old = try ready(bootstrap)
        try await bootstrap.selectHome(homes[1].graph)
        XCTAssertFalse(old.presentation.isActive)
        XCTAssertEqual(try ready(bootstrap).householdID, homes[1].graph.householdID)
        XCTAssertThrowsError(try old.service.createCategory(name: "Stale", householdID: homes[0].graph.householdID))
        XCTAssertEqual(bootstrap.homeCoordinator.homes.count, 2)
    }

    func testExplicitCreationWorksFromEmptyImportWithoutReplacingAnotherHome() async throws {
        let bootstrap = try await makeBootstrap(homeCount: 0)
        XCTAssertNil(try ready(bootstrap).householdID)
        XCTAssertTrue(bootstrap.homeCoordinator.homes.isEmpty)
        let first = try await bootstrap.createHome(name: "Our home")
        XCTAssertTrue(first.selected)
        try await bootstrap.acknowledgeHomeCreation(first)
        let previous = try ready(bootstrap)
        let second = try await bootstrap.createHome(name: "Other home")
        XCTAssertTrue(second.selected)
        XCTAssertFalse(previous.presentation.isActive)
        XCTAssertNotEqual(first.householdID, second.householdID)
        XCTAssertEqual(Set(bootstrap.homeCoordinator.homes.map(\.graph.householdID)), [first.householdID, second.householdID])
        try await bootstrap.selectHome(XCTUnwrap(bootstrap.homeCoordinator.homes.first { $0.graph.householdID == first.householdID }).graph)
        XCTAssertEqual(try ready(bootstrap).householdID, first.householdID)
    }

    func testConcurrentDiscoveryCannotReportCommittedCreationAsFailure() async throws {
        let bootstrap = try await makeBootstrap(homeCount: 1)
        var reachedBoundary = false
        let created = try await bootstrap.createHome(name: "Created during refresh") {
            // The creation's discovery request exists and its snapshot was fetched.
            // Force another request to supersede it before it can reconcile.
            do { try await bootstrap.refreshHomes() }
            catch { XCTFail("Intervening discovery failed: \(error)") }
            reachedBoundary = true
            XCTAssertEqual(bootstrap.homeCoordinator.homes.count, 2)
        }
        XCTAssertTrue(reachedBoundary)
        XCTAssertFalse(created.selected)
        try await bootstrap.refreshHomes()
        XCTAssertEqual(bootstrap.homeCoordinator.homes.count, 2)
        XCTAssertEqual(bootstrap.homeCoordinator.homes.filter { $0.graph.householdID == created.householdID }.count, 1)
        XCTAssertFalse(bootstrap.isCreatingHome)
    }
}
