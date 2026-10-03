import CloudKit
import CoreData
import XCTest
@testable import Shopping

@MainActor
final class HomeAdoptionBootstrapTests: XCTestCase {
    private actor CopyDiscoveryGate {
        private var firstCopyDiscoveryHeld = false
        private var accessChanged = false
        private var released = false
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

        func discover(_ service: HomeDiscoveryService, accessChange: Bool,
                      onHold: @Sendable () -> Void) async throws -> HomeDiscovery {
            // A simulated access change belongs to the source, including newer
            // history refreshes that supersede the requesting refresh.
            if accessChange { accessChanged = true }
            let snapshot = try await Task.detached(priority: .utility) { try service.discover() }.value
            guard snapshot.homes.count == 2 else { return snapshot }
            if accessChanged {
                let account = snapshot.homes.filter { $0.name == "Account home" }.map {
                    HomeCandidate(graph: $0.graph, name: $0.name, access: .restricted)
                }
                return HomeDiscovery(homes: account, hasIncompleteRoots: false)
            }
            guard !released else { return snapshot }
            if !firstCopyDiscoveryHeld {
                firstCopyDiscoveryHeld = true
                onHold()
            }
            await withCheckedContinuation { releaseContinuations.append($0) }
            return snapshot
        }

        func release() {
            released = true
            accessChanged = false
            for continuation in releaseContinuations { continuation.resume() }
            releaseContinuations.removeAll()
        }
    }

    private actor CopyProviderRefreshGate {
        private var armed = false
        private var continuation: CheckedContinuation<Void, Never>?

        func arm() { armed = true }

        func status(onHold: @Sendable () -> Void) async -> CKAccountStatus {
            guard armed else { return .available }
            armed = false
            onHold()
            await withCheckedContinuation { continuation = $0 }
            return .available
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor AccountIdentity {
        var name = "account-A"
        func current() -> String { name }
        func change() { name = "account-B" }
        func set(_ name: String) { self.name = name }
    }

    private struct Fixture {
        let directory: URL
        let source: URL
        let destination: URL
        let defaults: UserDefaults
        let provider: ShopperSessionProvider
        let homeID: UUID
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Original.sqlite")
        let destination = directory.appendingPathComponent("ExistingAccount.sqlite")
        let local = try PersistenceController(storeURL: source)
        let home = try NeedService(persistence: local).createHousehold(name: "Original home")
        _ = try NeedService(persistence: local).createCategory(name: "Keep this category", householdID: home.householdID)
        for store in local.container.persistentStoreCoordinator.persistentStores {
            try local.container.persistentStoreCoordinator.remove(store)
        }
        let account = try PersistenceController(storeURL: destination)
        _ = try NeedService(persistence: account).createHousehold(name: "Account home")
        for store in account.container.persistentStoreCoordinator.persistentStores {
            try account.container.persistentStoreCoordinator.remove(store)
        }
        let suite = "HomeAdoptionBootstrap." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.adoption-bootstrap",
            environment: "Development", cacheDirectory: directory.appendingPathComponent("Bindings"),
            lookup: .init(status: { .available }, recordName: { "account-A" }))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(directory: directory, source: source, destination: destination,
            defaults: defaults, provider: provider, homeID: home.householdID)
    }

    private func bootstrap(_ fixture: Fixture, offline: Bool = false,
                           provider replacementProvider: ShopperSessionProvider? = nil,
                           accountStore: (@Sendable (ShopperSession) -> URL)? = nil,
                           invitations: HomeInvitationController? = nil,
                           discoverHomes: @escaping @Sendable (HomeDiscoveryService) async throws -> HomeDiscovery = { service in
                               try await Task.detached(priority: .utility) { try service.discover() }.value
                           }) -> PersistenceBootstrap {
        let destination = fixture.destination
        let bootstrap = PersistenceBootstrap(configuration: { .local(storeURL: fixture.source) }, defaults: fixture.defaults,
            invitations: invitations, autoJoinInvitations: false,
            makeAccountProvider: { _ in
                if offline { throw ShopperSessionError.temporarilyUnavailable }
                return replacementProvider ?? fixture.provider
            }, accountStoreDirectory: { fixture.directory },
            discoverHomes: discoverHomes,
            activateAccountStore: { source, session, _, importing in
                XCTAssertNil(source, "Keeping a local home must never copy or merge it into account data")
                XCTAssertFalse(importing)
                return .local(storeURL: accountStore?(session) ?? destination)
            })
        retireBeforeCleanup(bootstrap)
        return bootstrap
    }

    private func retireBeforeCleanup(_ bootstrap: PersistenceBootstrap) {
        addTeardownBlock { @MainActor in
            if case .ready(let ready) = bootstrap.state {
                bootstrap.presentationDidDisappear(ready.presentation.id)
            }
            bootstrap.retireAndFail(ShopperSessionError.temporarilyUnavailable)
            await bootstrap.runLoadingTransition()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while bootstrap.invitations?.isProcessing == true, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(bootstrap.invitations?.isProcessing == true,
                "Invitation journal work must drain before its fixture directory is removed")
        }
    }

    private func waitForReady(_ bootstrap: PersistenceBootstrap) async throws -> PersistenceBootstrap.ReadyState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if case .ready(let ready) = bootstrap.state { return ready }
            if case .failed(let error) = bootstrap.state { throw error }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadUnknown)
    }

    func testFailedAccountVerificationLeavesMountedOriginalUsable() async throws {
        let fixture = try fixture()
        let bootstrap = bootstrap(fixture, offline: true)
        bootstrap.start()
        let original = try await waitForReady(bootstrap)
        bootstrap.presentationDidAppear(original.presentation.id)
        do {
            _ = try await bootstrap.prepareInvitationSetup()
            XCTFail("Offline identity must not approve adoption")
        } catch { XCTAssertEqual(error as? ShopperSessionError, .temporarilyUnavailable) }
        XCTAssertTrue(original.presentation.isActive)
        XCTAssertTrue(bootstrap.isPresentationMounted(original.presentation.id))
        XCTAssertEqual(original.persistence.container.persistentStoreCoordinator.persistentStores.count, 1)
        XCTAssertFalse(fixture.defaults.bool(forKey: "shopping.personalCart.enabled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("HomeAdoption.json").path))
        _ = try original.service.createCategory(name: "Still editable", householdID: fixture.homeID)
    }

    func testPreparedChoiceCannotRetireAReplacementPresentation() async throws {
        let fixture = try fixture()
        let bootstrap = bootstrap(fixture)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        XCTAssertEqual(choice.currentHomeName, "Original home")
        bootstrap.retry()
        await bootstrap.runLoadingTransition()
        let replacement = try await waitForReady(bootstrap)
        do {
            try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
            XCTFail("Old presentation must not authorize a new retirement")
        } catch { }
        XCTAssertTrue(replacement.presentation.isActive)
        XCTAssertFalse(fixture.defaults.bool(forKey: "shopping.personalCart.enabled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("HomeAdoption.json").path))
    }

    func testAccountChangeAfterPreparationCannotApproveOrRetireLocalHome() async throws {
        let fixture = try fixture()
        let identity = AccountIdentity()
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.changed-adoption",
            environment: "Development", cacheDirectory: fixture.directory.appendingPathComponent("ChangingBinding"),
            lookup: .init(status: { .available }, recordName: { await identity.current() }))
        let bootstrap = PersistenceBootstrap(configuration: { .local(storeURL: fixture.source) },
            defaults: fixture.defaults, makeAccountProvider: { _ in provider },
            accountStoreDirectory: { fixture.directory })
        retireBeforeCleanup(bootstrap)
        bootstrap.start()
        let original = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        await identity.change()
        await provider.refresh()
        do {
            try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
            XCTFail("Account B must not reuse account A’s adoption choice")
        } catch { XCTAssertEqual(error as? ShopperSessionError, .accountChanged) }
        XCTAssertTrue(original.presentation.isActive)
        XCTAssertFalse(fixture.defaults.bool(forKey: "shopping.personalCart.enabled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("HomeAdoption.json").path))
    }

    func testKeepLocalRetainsNamedOriginalAndRestoresItOfflineAfterRelaunch() async throws {
        let fixture = try fixture()
        let bootstrap = bootstrap(fixture)
        bootstrap.start()
        let original = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        XCTAssertFalse(original.presentation.isActive)
        XCTAssertEqual(original.persistence.container.persistentStoreCoordinator.persistentStores.count, 1)
        await bootstrap.runLoadingTransition()
        let account = try await waitForReady(bootstrap)
        XCTAssertEqual(bootstrap.retainedLocalHomeName, "Original home")
        XCTAssertNotEqual(account.householdID, fixture.homeID)
        XCTAssertEqual(bootstrap.currentHomeName, "Account home")
        XCTAssertTrue(original.persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        let retained = try await waitForReady(bootstrap)
        XCTAssertEqual(retained.householdID, fixture.homeID)
        XCTAssertTrue(bootstrap.isShowingRetainedLocalHome)
        XCTAssertNil(retained.personalCart)
        XCTAssertNil(retained.homeScope)
        _ = try retained.service.createCategory(name: "Offline addition", householdID: fixture.homeID)
        // Retire all handles before a new bootstrap opens the same SQLite source.
        bootstrap.retireAndFail(ShopperSessionError.temporarilyUnavailable)
        await bootstrap.runLoadingTransition()
        let relaunched = self.bootstrap(fixture, offline: true)
        relaunched.start()
        let restored = try await waitForReady(relaunched)
        XCTAssertEqual(restored.householdID, fixture.homeID)
        XCTAssertEqual(relaunched.currentHomeName, "Original home")
        XCTAssertEqual(relaunched.retainedLocalHomeName, "Original home")
        XCTAssertTrue(relaunched.isShowingRetainedLocalHome)
        XCTAssertNil(restored.personalCart)
        do {
            try await relaunched.connectBackToAccount()
            XCTFail("Offline account setup must leave the local home open")
        } catch { XCTAssertEqual(error as? ShopperSessionError, .temporarilyUnavailable) }
        XCTAssertTrue(restored.presentation.isActive)
        XCTAssertEqual(restored.persistence.container.persistentStoreCoordinator.persistentStores.count, 1)
    }

    func testRetainedDeviceHomeStaysReachableAcrossAccountChangeWithoutCopyingToNewAccount() async throws {
        let fixture = try fixture()
        let identity = AccountIdentity()
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.adoption-bootstrap",
            environment: "Development", cacheDirectory: fixture.directory.appendingPathComponent("SwitchingBindings"),
            lookup: .init(status: { .available }, recordName: { await identity.current() }),
            notifications: NotificationCenter())
        let expectedA = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.adoption-bootstrap",
            environment: "Development", accountRecordName: "account-A")
        let firstAccountURL = fixture.destination
        let otherAccountURL = fixture.directory.appendingPathComponent("OtherAccount.sqlite")
        let otherAccount = try PersistenceController(storeURL: otherAccountURL)
        let otherHome = try NeedService(persistence: otherAccount).createHousehold(name: "Other account home")
        for store in otherAccount.container.persistentStoreCoordinator.persistentStores {
            try otherAccount.container.persistentStoreCoordinator.remove(store)
        }
        let bootstrap = PersistenceBootstrap(configuration: { .local(storeURL: fixture.source) },
            defaults: fixture.defaults, makeAccountProvider: { _ in provider },
            accountStoreDirectory: { fixture.directory },
            activateAccountStore: { source, session, _, importing in
                XCTAssertNil(source)
                XCTAssertFalse(importing)
                return .local(storeURL: session == expectedA
                    ? firstAccountURL : otherAccountURL)
            })
        retireBeforeCleanup(bootstrap)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        let firstAccount = try await waitForReady(bootstrap)
        let sessionA = try provider.currentSession()
        XCTAssertEqual(bootstrap.retainedLocalHomeName, "Original home")
        await identity.change()
        await provider.refresh()
        let retirementDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while firstAccount.presentation.isActive, ContinuousClock.now < retirementDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(firstAccount.presentation.isActive)
        await bootstrap.runLoadingTransition()
        let secondAccount = try await waitForReady(bootstrap)
        let sessionB = try provider.currentSession()
        XCTAssertNotEqual(sessionA, sessionB)
        XCTAssertEqual(secondAccount.householdID, otherHome.householdID)
        XCTAssertEqual(bootstrap.currentHomeName, "Other account home")
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalHomeName, "Original home")
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 1)
        // Simulate an approved A copy interrupted before opening its target.
        // Stage it after A's startup recovery has settled so only B's reload
        // can observe the durable command.
        let retainedRecord = try XCTUnwrap(HomeAdoptionJournal(baseDirectory: fixture.directory).retainedLocalRecord())
        let detachedSource = try PersistenceController(storeURL: fixture.source)
        let proposed = try RetainedHomeConversionService(persistence: detachedSource)
            .capture(record: retainedRecord, session: sessionA)
        for store in detachedSource.container.persistentStoreCoordinator.persistentStores {
            try detachedSource.container.persistentStoreCoordinator.remove(store)
        }
        let journalA = RetainedHomeConversionJournal(baseDirectory: fixture.directory, session: sessionA)
        let pendingA = try journalA.begin(proposed)

        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        let local = try await waitForReady(bootstrap)
        XCTAssertEqual(local.householdID, fixture.homeID)
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalCopyState, .unavailable)
        let categories = try local.persistence.container.viewContext.fetch(Category.fetchRequest())
        XCTAssertTrue(categories.contains { $0.name == "Keep this category" })
        do {
            try await bootstrap.useICloudForRetainedLocalHome()
            XCTFail("Account B must not reuse account A’s explicit copy approval")
        } catch { XCTAssertEqual(error as? ShopperSessionError, .accountChanged) }
        XCTAssertEqual(try journalA.read(session: sessionA)?.id, pendingA.id)
        XCTAssertFalse(try XCTUnwrap(journalA.read(session: sessionA)).copied)
        XCTAssertNil(try RetainedHomeConversionJournal(baseDirectory: fixture.directory, session: sessionB)
            .read(session: sessionB))

        try await bootstrap.connectBackToAccount()
        await bootstrap.runLoadingTransition()
        let returned = try await waitForReady(bootstrap)
        XCTAssertEqual(returned.householdID, otherHome.householdID)
        XCTAssertEqual(bootstrap.currentHomeName, "Other account home")
        XCTAssertEqual(bootstrap.retainedLocalHomeName, "Original home")
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 1)
        XCTAssertFalse(try XCTUnwrap(journalA.read(session: sessionA)).copied)
    }

    func testExplicitRetainedCopyCreatesOwnedAccountHomeAndKeepsOriginal() async throws {
        let fixture = try fixture()
        let bootstrap = bootstrap(fixture)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        let account = try await waitForReady(bootstrap)
        XCTAssertEqual(account.householdID == fixture.homeID, false)
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        let retained = try await waitForReady(bootstrap)
        XCTAssertEqual(retained.householdID, fixture.homeID)
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalCopyState, .available)

        try await bootstrap.homeEntryCommands.useICloudForRetainedLocalHome()
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalCopyState, .copying)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.homeEntry.retainedLocalCopyState != .copied, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalCopyState, .copied,
            bootstrap.homeSetupError?.localizedDescription ?? "Copy did not complete")
        while !bootstrap.homeEntry.homes.contains(where: { $0.name == "Original home" && $0.isSelected }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let homes = bootstrap.homeEntry.homes
        XCTAssertEqual(homes.count, 2)
        let copied = try XCTUnwrap(homes.first { $0.name == "Original home" })
        XCTAssertNotEqual(copied.id.householdID, fixture.homeID)
        XCTAssertEqual(copied.access, .owner)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "Original home")
        XCTAssertTrue(copied.isSelected)
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalHomeName, "Original home")

        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        let original = try await waitForReady(bootstrap)
        XCTAssertEqual(original.householdID, fixture.homeID)
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalCopyState, .copied)
        let categories = try original.persistence.container.viewContext.fetch(Category.fetchRequest())
        XCTAssertTrue(categories.contains { $0.name == "Keep this category" })
    }

    private func waitForRetainedConversionCompletion(_ bootstrap: PersistenceBootstrap) async {
        let completed = expectation(description: "Retained copy consumer completed")
        let waiter = Task {
            await bootstrap.awaitRetainedConversionCompletion()
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        waiter.cancel()
    }

    private func waitForCopiedHomeRoster(_ bootstrap: PersistenceBootstrap) async throws {
        // Copy completion drains its consumer chain. A newer startup or history
        // discovery may still own publication of the account and copied homes.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.homeEntry.homes.count != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForCopyPreparation(_ copy: Task<Void, Error>) async -> Result<Void, Error>? {
        let completed = expectation(description: "Copy preparation completed")
        var outcome: Result<Void, Error>?
        let waiter = Task {
            outcome = await copy.result
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        waiter.cancel()
        return outcome
    }

    func testRetainedCopyOpensAfterSameAccountAccessRefreshAndLateDiscovery() async throws {
        let fixture = try fixture()
        let gate = CopyDiscoveryGate()
        let held = expectation(description: "Copied graph discovery held after durable write")
        let bootstrap = bootstrap(fixture, discoverHomes: { service in
            try await gate.discover(service, accessChange: CopyDiscoveryRequest.accessChange,
                onHold: { held.fulfill() })
        })
        addTeardownBlock {
            await gate.release()
            await self.waitForRetainedConversionCompletion(bootstrap)
        }
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.useICloudForRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        await fulfillment(of: [held], timeout: 5)

        let choiceRevision = bootstrap.homeCoordinator.choiceRevision
        let writeGeneration = bootstrap.homeCoordinator.generation
        try await CopyDiscoveryRequest.$accessChange.withValue(true) {
            try await bootstrap.refreshHomes()
        }
        // The requested read may be superseded by an automatic history refresh.
        // Wait for the changed source access to be published by the current read.
        let accessDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.homeCoordinator.generation == writeGeneration,
              ContinuousClock.now < accessDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(bootstrap.homeCoordinator.generation, writeGeneration)
        XCTAssertEqual(bootstrap.homeCoordinator.homes.first { $0.name == "Account home" }?.access, .restricted)
        XCTAssertEqual(bootstrap.homeCoordinator.choiceRevision, choiceRevision)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "Account home")

        await gate.release()
        try await bootstrap.refreshHomes()
        await self.waitForRetainedConversionCompletion(bootstrap)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !bootstrap.homeEntry.homes.contains(where: { $0.name == "Original home" && $0.isSelected }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "Original home")
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 2)
        let copied = try XCTUnwrap(bootstrap.homeEntry.homes.first { $0.name == "Original home" })
        XCTAssertNotEqual(copied.id.householdID, fixture.homeID)
        XCTAssertTrue(copied.isSelected)
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalHomeName, "Original home")
    }

    func testReaffirmingCurrentHomeDuringHeldCopyPreventsLateAutomaticOpen() async throws {
        let fixture = try fixture()
        let gate = CopyDiscoveryGate()
        let held = expectation(description: "Copied graph discovery held after durable write")
        let bootstrap = bootstrap(fixture, discoverHomes: { service in
            try await gate.discover(service, accessChange: CopyDiscoveryRequest.accessChange,
                onHold: { held.fulfill() })
        })
        addTeardownBlock {
            await gate.release()
            await self.waitForRetainedConversionCompletion(bootstrap)
        }
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.useICloudForRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        await fulfillment(of: [held], timeout: 5)

        let account = try XCTUnwrap(bootstrap.homeEntry.homes.first { $0.name == "Account home" })
        let choiceRevision = bootstrap.homeCoordinator.choiceRevision
        try await bootstrap.selectHome(account.id)
        XCTAssertNotEqual(bootstrap.homeCoordinator.choiceRevision, choiceRevision)
        await gate.release()
        try await bootstrap.refreshHomes()
        await self.waitForRetainedConversionCompletion(bootstrap)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (bootstrap.homeEntry.homes.count != 2 || bootstrap.retainedLocalCopyState != .copied),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 2)
        XCTAssertEqual(bootstrap.retainedLocalCopyState, .copied)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "Account home")
        XCTAssertTrue(bootstrap.homeEntry.homes.first { $0.id == account.id }?.isSelected == true)
        XCTAssertFalse(bootstrap.homeEntry.homes.first { $0.name == "Original home" }?.isSelected == true)
    }

    func testAcceptedInvitationDuringHeldCopyKeepsNewerNavigationIntent() async throws {
        let fixture = try fixture()
        let inbox = try HomeInvitationInbox(url: fixture.directory.appendingPathComponent("CopyIngress.json"),
            containerIdentifier: "iCloud.test.adoption-bootstrap", environment: "Development")
        let invitations = HomeInvitationController(inbox: inbox)
        await invitations.prepare()
        let gate = CopyDiscoveryGate()
        let held = expectation(description: "Copied graph discovery held before invitation ingress")
        let bootstrap = bootstrap(fixture, invitations: invitations, discoverHomes: { service in
            try await gate.discover(service, accessChange: CopyDiscoveryRequest.accessChange,
                onHold: { held.fulfill() })
        })
        addTeardownBlock {
            await gate.release()
            await self.waitForRetainedConversionCompletion(bootstrap)
        }
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.useICloudForRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        await fulfillment(of: [held], timeout: 5)

        let entry = try await invitations.enqueue(identity: HomeInvitationIdentity(
            containerIdentifier: "iCloud.test.adoption-bootstrap", environment: "Development",
            share: HomeShareIdentity(recordName: "new-invitation", zoneName: "new-zone", zoneOwnerName: "owner")),
            metadataArchive: Data([1]))
        XCTAssertEqual(bootstrap.homeEntry.invitations.first?.id, entry.id)
        await gate.release()
        try await bootstrap.refreshHomes()
        await self.waitForRetainedConversionCompletion(bootstrap)
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 2)
        XCTAssertEqual(bootstrap.retainedLocalCopyState, .copied)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "Account home")
        XCTAssertFalse(bootstrap.homeEntry.homes.first { $0.name == "Original home" }?.isSelected == true)
        XCTAssertTrue(bootstrap.invitations?.allEntries.contains { $0.id == entry.id && $0.openRequested } == true)
    }

    func testAcceptedInvitationDuringCopyAccountLookupCannotBeOverwrittenByLateCopyIntent() async throws {
        let fixture = try fixture()
        let held = expectation(description: "Copy account verification held before conversion journal")
        let gate = CopyProviderRefreshGate()
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.adoption-bootstrap",
            environment: "Development", cacheDirectory: fixture.directory.appendingPathComponent("HeldCopyBinding"),
            lookup: .init(status: { await gate.status(onHold: { held.fulfill() }) },
                recordName: { "account-A" }), notifications: NotificationCenter())
        let inbox = try HomeInvitationInbox(url: fixture.directory.appendingPathComponent("CopyLookupIngress.json"),
            containerIdentifier: "iCloud.test.adoption-bootstrap", environment: "Development")
        let invitations = HomeInvitationController(inbox: inbox)
        await invitations.prepare()
        let bootstrap = bootstrap(fixture, provider: provider, invitations: invitations)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)

        await gate.arm()
        let copy = Task { try await bootstrap.useICloudForRetainedLocalHome() }
        addTeardownBlock {
            await gate.release()
            _ = await self.waitForCopyPreparation(copy)
            await self.waitForRetainedConversionCompletion(bootstrap)
        }
        await fulfillment(of: [held], timeout: 5)
        let entry = try await invitations.enqueue(identity: HomeInvitationIdentity(
            containerIdentifier: "iCloud.test.adoption-bootstrap", environment: "Development",
            share: HomeShareIdentity(recordName: "newer-accepted-share", zoneName: "zone", zoneOwnerName: "owner")),
            metadataArchive: Data([1]))
        await gate.release()
        let prepared = await self.waitForCopyPreparation(copy)
        try XCTUnwrap(prepared).get()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        await self.waitForRetainedConversionCompletion(bootstrap)
        try await waitForCopiedHomeRoster(bootstrap)
        XCTAssertEqual(bootstrap.retainedLocalCopyState, .copied)
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 2)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "Account home")
        XCTAssertFalse(bootstrap.homeEntry.homes.first { $0.name == "Original home" }?.isSelected == true)
        XCTAssertTrue(invitations.allEntries.contains { $0.id == entry.id && $0.openRequested })
    }

    func testAccountInvalidationDuringCopyLookupDoesNotRearmOpenAfterSameAccountVerification() async throws {
        let fixture = try fixture()
        let held = expectation(description: "Copy account lookup held before invalidation")
        let gate = CopyProviderRefreshGate()
        let center = NotificationCenter()
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.adoption-bootstrap",
            environment: "Development", cacheDirectory: fixture.directory.appendingPathComponent("InvalidatedCopyBinding"),
            lookup: .init(status: { await gate.status(onHold: { held.fulfill() }) },
                recordName: { "account-A" }), notifications: center)
        let sessionA = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.adoption-bootstrap",
            environment: "Development", accountRecordName: "account-A")
        let bootstrap = bootstrap(fixture, provider: provider)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)

        await gate.arm()
        let copy = Task { try await bootstrap.useICloudForRetainedLocalHome() }
        addTeardownBlock {
            await gate.release()
            _ = await self.waitForCopyPreparation(copy)
            await self.waitForRetainedConversionCompletion(bootstrap)
        }
        await fulfillment(of: [held], timeout: 5)
        XCTAssertTrue(bootstrap.hasPendingLocalCopyPreparation)
        center.post(name: .CKAccountChanged, object: nil)
        await provider.refresh()
        XCTAssertEqual(try provider.currentSession(), sessionA)
        let invalidationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.hasPendingLocalCopyPreparation, ContinuousClock.now < invalidationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(bootstrap.hasPendingLocalCopyPreparation,
            "The exact account invalidation must retire the in-flight copy approval")

        await gate.release()
        let prepared = await self.waitForCopyPreparation(copy)
        try XCTUnwrap(prepared).get()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        await self.waitForRetainedConversionCompletion(bootstrap)
        try await waitForCopiedHomeRoster(bootstrap)
        XCTAssertEqual(bootstrap.retainedLocalCopyState, .copied)
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 2)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "Account home")
        XCTAssertFalse(bootstrap.homeEntry.homes.first { $0.name == "Original home" }?.isSelected == true)
    }

    func testInterruptedCopyAfterAccountChangeCompletesWithoutRearmingOldSelection() async throws {
        let fixture = try fixture()
        let identity = AccountIdentity()
        let center = NotificationCenter()
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.adoption-bootstrap",
            environment: "Development", cacheDirectory: fixture.directory.appendingPathComponent("ChangingBindings"),
            lookup: .init(status: { .available }, recordName: { await identity.current() }), notifications: center)
        let accountA = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.adoption-bootstrap",
            environment: "Development", accountRecordName: "account-A")
        let accountAURL = fixture.destination
        let accountBURL = fixture.directory.appendingPathComponent("AccountB.sqlite")
        let bootstrap = bootstrap(fixture, provider: provider,
            accountStore: { $0 == accountA ? accountAURL : accountBURL })
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        let originalAccount = try await waitForReady(bootstrap)
        let originalScope = try XCTUnwrap(originalAccount.homeScope)
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        let retained = try await waitForReady(bootstrap)
        XCTAssertEqual(retained.householdID, fixture.homeID)

        try await bootstrap.homeEntryCommands.useICloudForRetainedLocalHome()
        await identity.change()
        center.post(name: .CKAccountChanged, object: nil)
        await bootstrap.runLoadingTransition()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if case .failed = bootstrap.state { return true }
            return false
        }, object: nil)], timeout: 5)
        bootstrap.retry()
        await bootstrap.runLoadingTransition()
        let otherAccount = try await waitForReady(bootstrap)
        XCTAssertNil(otherAccount.homeScope,
            "The account-B store must not receive account-A's pending copy")

        await identity.set("account-A")
        let beforeReturn = otherAccount
        center.post(name: .CKAccountChanged, object: nil)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !beforeReturn.presentation.isActive
        }, object: nil)], timeout: 5)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.homeEntry.retainedLocalCopyState != .copied
            || bootstrap.homeEntry.homes.count != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalCopyState, .copied)
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 2)
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope, originalScope,
            "The copy history can recover, but an old account's navigation intent cannot")
        XCTAssertFalse(bootstrap.homeEntry.homes.first { $0.name == "Original home" }?.isSelected == true)
    }

    func testPendingRetainedLocalDeletionReconcilesWhileAccountHomeIsOpen() async throws {
        let fixture = try fixture()
        let bootstrap = bootstrap(fixture)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        let account = try await waitForReady(bootstrap)
        let accountHomeID = try XCTUnwrap(account.householdID)

        let local = try PersistenceController(storeURL: fixture.source)
        let sourceGraph = try XCTUnwrap(HomeDiscoveryService(persistence: local).discover().homes
            .first { $0.graph.householdID == fixture.homeID }?.graph)
        let deletion = try await HomeDeletionService(persistence: local)
            .prepare(graph: sourceGraph, scope: nil)
        try LocalHomeDeletionJournal(storeURL: fixture.source).retain(deletion)
        for store in local.container.persistentStoreCoordinator.persistentStores {
            try local.container.persistentStoreCoordinator.remove(store)
        }
        XCTAssertNotNil(try HomeAdoptionJournal(baseDirectory: fixture.directory).retainedLocalRecord(),
            "A pending sidecar must keep the exact source available for replay")

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !bootstrap.homeDeletionStatuses.contains(where: { $0.command == deletion && $0.completed }),
              ContinuousClock.now < deadline {
            await bootstrap.refreshHomeDeletionStatuses()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(bootstrap.homeDeletionStatuses.contains { $0.command == deletion && $0.completed },
            bootstrap.homeDeletionStatusError ?? "Retained deletion did not finish")
        XCTAssertNil(bootstrap.retainedLocalHomeName)
        if case .ready(let current) = bootstrap.state { XCTAssertEqual(current.householdID, accountHomeID) }
        else { XCTFail("The selected account home should remain open") }
        XCTAssertNil(try HomeAdoptionJournal(baseDirectory: fixture.directory).retainedLocalRecord())
        let reopened = try PersistenceController(storeURL: fixture.source)
        XCTAssertFalse(try HomeDiscoveryService(persistence: reopened).discover().homes
            .contains { $0.graph.householdID == fixture.homeID })
        for store in reopened.container.persistentStoreCoordinator.persistentStores {
            try reopened.container.persistentStoreCoordinator.remove(store)
        }
    }

    func testCompletedCopiedHomeDeletionPermitsOneNewExplicitCopy() async throws {
        let fixture = try fixture()
        let bootstrap = bootstrap(fixture)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.homeEntryCommands.useICloudForRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (bootstrap.retainedLocalCopyState != .copied
               || bootstrap.homeEntry.homes.count != 2
               || bootstrap.homeEntry.currentHomeName != "Original home"),
              ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.retainedLocalCopyState, .copied,
            bootstrap.homeSetupError?.localizedDescription ?? "First copy did not finish")
        let first = try XCTUnwrap(bootstrap.homeEntry.homes.first { $0.name == "Original home" })
        let account = try await waitForReady(bootstrap)
        let scope = try XCTUnwrap(account.homeScope)
        XCTAssertEqual(scope.graph, first.id)
        let cart = try XCTUnwrap(account.personalCartService)
        let deletion = HomeDeletionService(persistence: account.persistence, cart: cart)
        let command = try await deletion.prepare(graph: first.id, scope: scope)
        let deleted = try await deletion.execute(command)
        XCTAssertTrue(deleted.completed)

        let deletionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.retainedLocalCopyState != .available, ContinuousClock.now < deletionDeadline {
            await bootstrap.refreshHomeDeletionStatuses()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.retainedLocalCopyState, .available,
            bootstrap.homeDeletionStatusError ?? "Completed deletion was not observed")
        XCTAssertTrue(bootstrap.homeDeletionStatuses.contains { $0.command == command && $0.completed })
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        let original = try await waitForReady(bootstrap)
        XCTAssertEqual(original.householdID, fixture.homeID)
        XCTAssertEqual(bootstrap.retainedLocalCopyState, .available)

        try await bootstrap.homeEntryCommands.useICloudForRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (bootstrap.retainedLocalCopyState != .copied
               || bootstrap.homeEntry.homes.count != 2
               || bootstrap.homeEntry.currentHomeName != "Original home"),
              ContinuousClock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.retainedLocalCopyState, .copied,
            bootstrap.homeSetupError?.localizedDescription ?? "Second copy did not finish")
        let second = try XCTUnwrap(bootstrap.homeEntry.homes.first { $0.name == "Original home" })
        XCTAssertNotEqual(first.id.householdID, second.id.householdID)
        XCTAssertNotEqual(second.id.householdID, fixture.homeID)
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 2, "The unrelated account home remains")
        XCTAssertTrue(second.isSelected)
    }

    func testDeletedRetainedSourceCanCreateAndCopyNewLocalHomeWithoutRewritingAdoption() async throws {
        let fixture = try fixture()
        let bootstrap = bootstrap(fixture)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        let adoption = try XCTUnwrap(HomeAdoptionJournal(baseDirectory: fixture.directory).verifiedRecord())
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)

        let actions = try XCTUnwrap(bootstrap.localHomeDeletionActions())
        let deletion = try await actions.prepare()
        let deleted = try await actions.confirm(deletion)
        XCTAssertTrue(deleted.completed)
        XCTAssertEqual(bootstrap.homeEntry.root, .noHomes)
        try await bootstrap.createFirstHome()
        let fresh = try await waitForReady(bootstrap)
        let freshID = try XCTUnwrap(fresh.householdID)
        XCTAssertNotEqual(freshID, fixture.homeID)
        _ = try fresh.service.createCategory(name: "New local category", householdID: freshID)
        XCTAssertEqual(bootstrap.homeEntry.root, .localHome)

        try await bootstrap.homeEntryCommands.useICloudForLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (bootstrap.retainedLocalCopyState != .copied
               || bootstrap.homeEntry.homes.count != 2
               || bootstrap.homeEntry.currentHomeName != "My Home"),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.retainedLocalCopyState, .copied,
            bootstrap.homeSetupError?.localizedDescription ?? "New local copy did not complete")
        XCTAssertEqual(bootstrap.homeEntry.homes.count, 2)
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalHomeName, "My Home")
        let copied = try XCTUnwrap(bootstrap.homeEntry.homes.first { $0.name == "My Home" })
        XCTAssertNotEqual(copied.id.householdID, freshID)
        XCTAssertTrue(copied.isSelected)
        XCTAssertEqual(try HomeAdoptionJournal(baseDirectory: fixture.directory).verifiedRecord(), adoption)

        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        let returned = try await waitForReady(bootstrap)
        XCTAssertEqual(returned.householdID, freshID)
        let categories = try returned.persistence.container.viewContext.fetch(Category.fetchRequest())
        XCTAssertTrue(categories.contains { $0.name == "New local category" })
        XCTAssertFalse(categories.contains { $0.name == "Keep this category" })
    }

    func testJoiningAfterReplacingDeletedLocalSourceKeepsNewHomeReachable() async throws {
        let fixture = try fixture()
        let bootstrap = bootstrap(fixture)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        let adoption = try XCTUnwrap(HomeAdoptionJournal(baseDirectory: fixture.directory).verifiedRecord())
        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        let actions = try XCTUnwrap(bootstrap.localHomeDeletionActions())
        let deletion = try await actions.prepare()
        _ = try await actions.confirm(deletion)
        try await bootstrap.createFirstHome()
        let replacement = try await waitForReady(bootstrap)
        let replacementID = try XCTUnwrap(replacement.householdID)
        _ = try replacement.service.createCategory(name: "Replacement groceries", householdID: replacementID)

        try await bootstrap.connectForJoiningKeepingLocalHome()
        await bootstrap.runLoadingTransition()
        let account = try await waitForReady(bootstrap)
        XCTAssertEqual(account.householdID == fixture.homeID, false)
        XCTAssertEqual(bootstrap.homeEntry.retainedLocalHomeName, "My Home")
        XCTAssertEqual(try HomeAdoptionJournal(baseDirectory: fixture.directory).verifiedRecord(), adoption)

        try await bootstrap.openRetainedLocalHome()
        await bootstrap.runLoadingTransition()
        let restored = try await waitForReady(bootstrap)
        XCTAssertEqual(restored.householdID, replacementID)
        let categories = try restored.persistence.container.viewContext.fetch(Category.fetchRequest())
        XCTAssertTrue(categories.contains { $0.name == "Replacement groceries" })
        XCTAssertFalse(categories.contains { $0.name == "Keep this category" })
    }

    func testNotNowDuringLocalJoinReturnsOriginalAndDeferredInviteStaysSafeAfterRelaunch() async throws {
        let fixture = try fixture()
        let inboxURL = fixture.directory.appendingPathComponent("Invitations.json")
        let namespace = "iCloud.test.adoption-bootstrap"
        let inbox = try HomeInvitationInbox(url: inboxURL, containerIdentifier: namespace,
            environment: "Development")
        let entry = try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: namespace,
            environment: "Development", share: HomeShareIdentity(recordName: "invited-share",
                zoneName: "zone", zoneOwnerName: "owner")), metadataArchive: Data([1]))
        let accountURL = fixture.directory.appendingPathComponent("EmptyAccount.sqlite")
        let makeBootstrap: (Bool) throws -> PersistenceBootstrap = { autoJoin in
            let controller = try HomeInvitationInbox(url: inboxURL, containerIdentifier: namespace,
                environment: "Development")
            return PersistenceBootstrap(configuration: { .local(storeURL: fixture.source) },
                defaults: fixture.defaults, invitations: HomeInvitationController(inbox: controller),
                autoJoinInvitations: autoJoin, makeAccountProvider: { _ in fixture.provider },
                accountStoreDirectory: { fixture.directory },
                activateAccountStore: { source, _, _, copying in
                    XCTAssertNil(source)
                    XCTAssertFalse(copying)
                    return .local(storeURL: accountURL)
                })
        }
        let bootstrap = try makeBootstrap(false)
        retireBeforeCleanup(bootstrap)
        bootstrap.start()
        _ = try await waitForReady(bootstrap)
        try await bootstrap.joinInvitation(entry.id)
        XCTAssertEqual(bootstrap.homeEntry.invitations.first?.id, entry.id,
            "The same accepted invitation stays visible during account retirement")
        try await bootstrap.dismissJoin(entry.id)
        XCTAssertFalse(bootstrap.invitations?.allEntries.first { $0.id == entry.id }?.openRequested == true)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !bootstrap.isShowingRetainedLocalHome, ContinuousClock.now < deadline {
            if case .loading = bootstrap.state { await bootstrap.runLoadingTransition() }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(bootstrap.isShowingRetainedLocalHome)
        if case .loading = bootstrap.state { await bootstrap.runLoadingTransition() }
        let original = try await waitForReady(bootstrap)
        XCTAssertEqual(original.householdID, fixture.homeID)
        XCTAssertNil(original.homeScope)

        // Reopen the account, then reconstruct the bootstrap as though the app
        // relaunched after the durable Not Now but before returning locally.
        try await bootstrap.connectBackToAccount()
        await bootstrap.runLoadingTransition()
        let accountBeforeRelaunch = try await waitForReady(bootstrap)
        XCTAssertNil(accountBeforeRelaunch.householdID)
        bootstrap.retireAndFail(ShopperSessionError.temporarilyUnavailable)
        await bootstrap.runLoadingTransition()
        let relaunched = try makeBootstrap(true)
        retireBeforeCleanup(relaunched)
        // The application factory restores this saved account-mode preference
        // before start(); direct test bootstraps use the same activation entry.
        XCTAssertTrue(fixture.defaults.bool(forKey: "shopping.personalCart.enabled"))
        relaunched.activatePersonalCarts(importLegacy: false)
        await relaunched.runLoadingTransition()
        let account = try await waitForReady(relaunched)
        XCTAssertNil(account.householdID)
        XCTAssertFalse(relaunched.invitations?.allEntries.first { $0.id == entry.id }?.openRequested == true)
        XCTAssertEqual(relaunched.homeEntry.invitations.first?.id, entry.id)
        XCTAssertEqual(relaunched.retainedLocalHomeName, "Original home")
        try await relaunched.openRetainedLocalHome()
        await relaunched.runLoadingTransition()
        let restored = try await waitForReady(relaunched)
        XCTAssertEqual(restored.householdID, fixture.homeID)
    }

    private struct ImportedInvitationFixture {
        let directory: URL
        let privateURL: URL
        let participantURL: URL
        let inboxURL: URL
        let defaults: UserDefaults
        let provider: ShopperSessionProvider
        let original: HomeGraphIdentity?
        let invited: HomeGraphIdentity
        let secondInvited: HomeGraphIdentity?
        let entryID: UUID
        let unrelatedEntryID: UUID?
        let originalNeedID: UUID?
    }

    private func saveOriginalHomeSelection(_ fixture: ImportedInvitationFixture) throws -> HomeGraphIdentity {
        let original = try XCTUnwrap(fixture.original)
        let session = try fixture.provider.currentSession()
        let saved = ActiveHomeCoordinator(defaults: fixture.defaults)
        saved.bind(session)
        let request = try XCTUnwrap(saved.beginDiscovery())
        _ = saved.reconcile(HomeDiscovery(homes: [
            HomeCandidate(graph: original, name: "Original account home", access: .owner),
            HomeCandidate(graph: fixture.invited, name: "Invited home", access: .contributor)
        ], hasIncompleteRoots: false), request: request)
        try saved.select(original)
        return original
    }

    /// These are two plain SQLite stores. The participant-store lookup and native
    /// rejoin verification boundary are substituted; no CloudKit result is proven.
    private func importedInvitation(originalHome: Bool = true, ready: Bool = true,
                                    unrelatedInvitation: Bool = false, secondImportedHome: Bool = false,
                                    notifications: NotificationCenter = NotificationCenter()) async throws -> ImportedInvitationFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let privateURL = directory.appendingPathComponent("Private.sqlite")
        let participantURL = directory.appendingPathComponent("Participant.sqlite")
        let inboxURL = directory.appendingPathComponent("Invitations.json")
        let suite = "ImportedHomeChoice." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.imported-choice",
            environment: "Development", cacheDirectory: directory.appendingPathComponent("Bindings"),
            lookup: .init(status: { .available }, recordName: { "account-A" }), notifications: notifications)
        await provider.refresh()
        let session = try provider.currentSession()
        let originalStore = try PersistenceController(storeURL: privateURL)
        var original: HomeGraphIdentity?
        var needID: UUID?
        if originalHome {
            let service = NeedService(persistence: originalStore)
            let home = try service.createHousehold(name: "Original account home")
            let need = try service.addOneTimeNeed(title: "Original groceries", quantity: 2,
                householdID: home.householdID, listID: home.listID)
            let cart = PersonalCartService(persistence: originalStore, sessionProvider: provider)
            try cart.cart(needID: need, householdID: home.householdID, listID: home.listID)
            needID = need
            original = try XCTUnwrap(HomeDiscoveryService(persistence: originalStore).discover().homes.first?.graph)
        }
        for store in originalStore.container.persistentStoreCoordinator.persistentStores {
            try originalStore.container.persistentStoreCoordinator.remove(store)
        }
        let invitedStore = try PersistenceController(storeURL: participantURL)
        _ = try NeedService(persistence: invitedStore).createHousehold(name: "Invited home")
        let invited = try XCTUnwrap(HomeDiscoveryService(persistence: invitedStore).discover().homes.first?.graph)
        var secondInvited: HomeGraphIdentity?
        if secondImportedHome {
            let second = try NeedService(persistence: invitedStore).createHousehold(name: "Second invited home")
            secondInvited = try XCTUnwrap(HomeDiscoveryService(persistence: invitedStore).discover().homes
                .first { $0.graph.householdID == second.householdID }?.graph)
        }
        for store in invitedStore.container.persistentStoreCoordinator.persistentStores {
            try invitedStore.container.persistentStoreCoordinator.remove(store)
        }
        let inbox = try HomeInvitationInbox(url: inboxURL,
            containerIdentifier: session.containerIdentifier, environment: session.environment)
        try inbox.setSession(session)
        let entry = try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: session.containerIdentifier,
            environment: session.environment, share: HomeShareIdentity(recordName: "invited-share", zoneName: "zone", zoneOwnerName: "owner")),
            metadataArchive: Data([1]))
        try inbox.finishAcceptance(inbox.beginAcceptance(id: entry.id, sharedStoreIdentifier: invited.storeIdentifier))
        if ready {
            try inbox.markReady(inbox.beginImportResolution(id: entry.id,
                sharedStoreIdentifier: invited.storeIdentifier), graph: invited)
        }
        var unrelatedID: UUID?
        if unrelatedInvitation || secondImportedHome {
            unrelatedID = try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: session.containerIdentifier,
                environment: session.environment, share: HomeShareIdentity(recordName: "other-share", zoneName: "zone", zoneOwnerName: "owner")),
                metadataArchive: Data([2])).id
            if let secondInvited, let unrelatedID {
                try inbox.finishAcceptance(inbox.beginAcceptance(id: unrelatedID,
                    sharedStoreIdentifier: secondInvited.storeIdentifier))
            }
        }
        return ImportedInvitationFixture(directory: directory, privateURL: privateURL,
            participantURL: participantURL, inboxURL: inboxURL, defaults: defaults, provider: provider,
            original: original, invited: invited, secondInvited: secondInvited, entryID: entry.id,
            unrelatedEntryID: unrelatedID, originalNeedID: needID)
    }

    private func openImportedFixture(_ fixture: ImportedInvitationFixture,
                                     autoJoinInvitations: Bool = false,
                                     accountProvider: ShopperSessionProvider? = nil,
                                     accountStoreForSession: (@Sendable (ShopperSession) -> PersistenceConfiguration)? = nil,
                                     detectedShare: HomeShareIdentity = HomeShareIdentity(recordName: "invited-share", zoneName: "zone", zoneOwnerName: "owner"),
                                     verifyMembership: @escaping @Sendable (HomeNativeAccessIdentity) async throws -> Void = { _ in },
                                     observeInvitationWorker: (HomeInvitationWorker) -> Void = { _ in },
                                     discoverHomes: @escaping @Sendable (HomeDiscoveryService) async throws -> HomeDiscovery = { discovery in
                                         try await Task.detached(priority: .utility) { try discovery.discover() }.value
                                     }) async throws -> PersistenceBootstrap {
        let inbox = try HomeInvitationInbox(url: fixture.inboxURL,
            containerIdentifier: "iCloud.test.imported-choice", environment: "Development")
        let worker = HomeInvitationWorker(inbox: inbox)
        observeInvitationWorker(worker)
        let invitations = HomeInvitationController(worker: worker)
        await invitations.prepare()
        let privateURL = fixture.privateURL
        let participantURL = fixture.participantURL
        let bootstrap = PersistenceBootstrap(defaults: fixture.defaults, invitations: invitations,
            autoJoinInvitations: autoJoinInvitations,
            makeAccountProvider: { _ in accountProvider ?? fixture.provider }, accountStoreDirectory: { fixture.directory },
            participantStoreForHomeChoice: { persistence in
                persistence.container.persistentStoreCoordinator.persistentStores.first { $0.url == participantURL }
            }, invitationShareIdentity: { _, _, graph in
                if graph == fixture.secondInvited {
                    return HomeShareIdentity(recordName: "other-share", zoneName: "zone", zoneOwnerName: "owner")
                }
                return detectedShare
            },
            makeHomeRejoinVerifier: { _ in LocalRejoinVerifier(refreshMembership: verifyMembership) },
            discoverHomes: discoverHomes,
            activateAccountStore: { source, session, _, importing in
                XCTAssertNil(source)
                XCTAssertFalse(importing)
                return accountStoreForSession?(session)
                    ?? .local(storeURL: privateURL, additionalStoreURLs: [participantURL])
            })
        retireBeforeCleanup(bootstrap)
        bootstrap.activatePersonalCarts(importLegacy: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        return bootstrap
    }

    private struct LocalRejoinVerifier: HomeRejoinVerifying {
        let refreshMembership: @Sendable (HomeNativeAccessIdentity) async throws -> Void
        func validate(_ identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws {
            guard let provider = repository.persistence.personalCartSessionProvider as? ShopperSessionProvider,
                  case .ready(let session) = provider.state, session == repository.session else {
                throw PersonalCartError.accountChanged
            }
        }
        func refresh(_ identity: HomeNativeAccessIdentity) async throws { try await refreshMembership(identity) }
    }

    private func blockedInvitedHome(_ fixture: ImportedInvitationFixture, bootstrap: PersistenceBootstrap) async throws -> PersonalCartService {
        try await bootstrap.selectHome(try XCTUnwrap(fixture.original))
        let ready = try await waitForReady(bootstrap)
        let cart = try XCTUnwrap(ready.personalCartService)
        try cart.blockHomeEffects(householdID: fixture.invited.householdID, listID: fixture.invited.listID,
            share: HomeEffectShare(recordName: "invited-share", zoneName: "zone", zoneOwnerName: "owner"),
            reason: .revoked, operationID: UUID())
        try await bootstrap.refreshHomes()
        // Startup replay can already own a newer discovery request. Wait for its
        // publication instead of assuming this refresh necessarily won that race.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.homeCoordinator.homes.first(where: { $0.graph == fixture.invited })?.access != .unresolved,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.homeCoordinator.homes.first { $0.graph == fixture.invited }?.access, .unresolved)
        return cart
    }

    private func access(_ cart: PersonalCartService, graph: HomeGraphIdentity) throws -> HomeEffectAccess {
        try cart.transact(save: false) { try $0.homeEffectAccess(householdID: graph.householdID, listID: graph.listID) }
    }

    func testExplicitOpenRejoinsBlockedHomeButResolvedEntryCannotGrantAgain() async throws {
        let fixture = try await importedInvitation()
        let verification = RejoinVerificationProbe()
        let bootstrap = try await openImportedFixture(fixture, verifyMembership: { await verification.record($0) })
        let originalCart = try await blockedInvitedHome(fixture, bootstrap: bootstrap)
        let blocked = try access(originalCart, graph: fixture.invited).capturedAuthority
        let before = try await waitForReady(bootstrap)
        try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
        let opened = try await waitForReady(bootstrap)
        XCTAssertEqual(opened.homeScope?.graph, fixture.invited)
        XCTAssertFalse(before.presentation.isActive)
        let current = try access(try XCTUnwrap(opened.personalCartService), graph: fixture.invited)
        XCTAssertFalse(current.requiresExplicitRejoin)
        XCTAssertFalse(current.permitsPublication(blocked), "Pre-rejoin private changes keep their old authority")
        let calls = await verification.identities
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.rootURI, fixture.invited.rootURI)
        XCTAssertEqual(calls.first?.share.recordName, "invited-share")
        do {
            try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
            XCTFail("A resolved entry cannot mint another grant")
        } catch { }
        XCTAssertEqual(try access(try XCTUnwrap(opened.personalCartService), graph: fixture.invited).currentGrants.count, 1)
    }

    func testAcceptedInvitationOpensImportedHomeWithoutAnotherOpenChoice() async throws {
        let fixture = try await importedInvitation()
        let bootstrap = try await openImportedFixture(fixture, autoJoinInvitations: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.homeCoordinator.activeScope?.graph != fixture.invited,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.invited)
        while bootstrap.invitations?.allEntries.first(where: { $0.id == fixture.entryID })?.activationResolved != true,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }?.activationResolved == true)
    }

    func testAccountChangeDuringHeldAcceptedOpenDoesNotReviveItAfterColdReturn() async throws {
        let fixture = try await importedInvitation()
        let original = try saveOriginalHomeSelection(fixture)
        let accountA = try fixture.provider.currentSession()

        let account = AccountIdentity()
        let center = NotificationCenter()
        let provider = try ShopperSessionProvider(containerIdentifier: accountA.containerIdentifier,
            environment: accountA.environment, cacheDirectory: fixture.directory.appendingPathComponent("ChangingBindings"),
            lookup: .init(status: { .available }, recordName: { await account.current() }), notifications: center)
        let privateURL = fixture.privateURL
        let participantURL = fixture.participantURL
        let otherURL = fixture.directory.appendingPathComponent("OtherAccount.sqlite")
        let stores: @Sendable (ShopperSession) -> PersistenceConfiguration = { session in
            session == accountA ? .local(storeURL: privateURL, additionalStoreURLs: [participantURL])
                : .local(storeURL: otherURL)
        }
        let held = RejoinVerificationProbe()
        let started = expectation(description: "Automatic Open held during native verification")
        addTeardownBlock { await held.release() }
        let bootstrap = try await openImportedFixture(fixture, autoJoinInvitations: true,
            accountProvider: provider, accountStoreForSession: stores,
            verifyMembership: { await held.hold($0) { started.fulfill() } })
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, original)
        await fulfillment(of: [started], timeout: 5)
        let beforeChange = try await waitForReady(bootstrap)
        await account.change()
        center.post(name: .CKAccountChanged, object: nil)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !beforeChange.presentation.isActive
        }, object: nil)], timeout: 5)
        await bootstrap.runLoadingTransition()
        await held.release()
        let otherAccount = try await waitForReady(bootstrap)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            bootstrap.autoOpeningInvitationID == nil
        }, object: nil)], timeout: 5)
        XCTAssertNil(bootstrap.autoOpeningInvitationID,
            "The retired native verification must settle before the cold bootstrap reopens its journal")
        XCTAssertNil(otherAccount.homeScope)
        XCTAssertFalse(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }?.openRequested == true)

        bootstrap.retireAndFail(ShopperSessionError.temporarilyUnavailable)
        await bootstrap.runLoadingTransition()
        let relaunchCenter = NotificationCenter()
        let relaunchedProvider = try ShopperSessionProvider(containerIdentifier: accountA.containerIdentifier,
            environment: accountA.environment, cacheDirectory: fixture.directory.appendingPathComponent("RelaunchBindings"),
            lookup: .init(status: { .available }, recordName: { await account.current() }),
            notifications: relaunchCenter)
        let relaunched = try await openImportedFixture(fixture, autoJoinInvitations: true,
            accountProvider: relaunchedProvider, accountStoreForSession: stores)
        XCTAssertNil(relaunched.homeCoordinator.activeScope)
        await account.set("account-A")
        let beforeReturn = try await waitForReady(relaunched)
        relaunchCenter.post(name: .CKAccountChanged, object: nil)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !beforeReturn.presentation.isActive
        }, object: nil)], timeout: 5)
        await relaunched.runLoadingTransition()
        _ = try await waitForReady(relaunched)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            relaunched.invitations?.entries.contains { $0.id == fixture.entryID } == true
                && relaunched.homeCoordinator.discoveryState == .complete
        }, object: nil)], timeout: 5)
        XCTAssertEqual(relaunched.homeCoordinator.activeScope?.graph, original)
        XCTAssertFalse(relaunched.invitations?.allEntries.first { $0.id == fixture.entryID }?.openRequested == true)
        try await relaunched.joinInvitation(fixture.entryID)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            relaunched.homeCoordinator.activeScope?.graph == fixture.invited
        }, object: nil)], timeout: 5)
        XCTAssertEqual(relaunched.homeCoordinator.activeScope?.graph, fixture.invited,
            "The accepted home remains available through an explicit Open")
    }

    func testColdInvalidatedAccountRetiresReadyInvitationBeforeSameAccountVerification() async throws {
        let center = NotificationCenter()
        let fixture = try await importedInvitation(notifications: center)
        let original = try saveOriginalHomeSelection(fixture)
        let session = try fixture.provider.currentSession()
        // Simulate a process ending after the provider durably invalidates its
        // cached account but before Bootstrap can write the invitation journal.
        center.post(name: .CKAccountChanged, object: nil)
        let provider = try ShopperSessionProvider(containerIdentifier: session.containerIdentifier,
            environment: session.environment, cacheDirectory: fixture.directory.appendingPathComponent("Bindings"),
            lookup: .init(status: { .available }, recordName: { "account-A" }),
            notifications: NotificationCenter())
        XCTAssertEqual(provider.state, .accountChanged)
        let before = try HomeInvitationInbox(url: fixture.inboxURL,
            containerIdentifier: session.containerIdentifier, environment: session.environment)
        XCTAssertTrue(before.entries.first { $0.id == fixture.entryID }?.openRequested == true)
        let bootstrap = try await openImportedFixture(fixture, autoJoinInvitations: true, accountProvider: provider)
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, original)
        let persisted = try HomeInvitationInbox(url: fixture.inboxURL,
            containerIdentifier: session.containerIdentifier, environment: session.environment)
        XCTAssertEqual(persisted.entries.first { $0.id == fixture.entryID }?.state, .ready(fixture.invited))
        XCTAssertFalse(persisted.entries.first { $0.id == fixture.entryID }?.openRequested == true)
        XCTAssertFalse(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }?.activationResolved == true)
        try await bootstrap.joinInvitation(fixture.entryID)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            bootstrap.homeCoordinator.activeScope?.graph == fixture.invited
        }, object: nil)], timeout: 5)
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.invited)
    }

    func testBoundInvitationPresentationSurvivesAccountStoreRetirement() async throws {
        let fixture = try await importedInvitation()
        let bootstrap = try await openImportedFixture(fixture)
        let invitation = try XCTUnwrap(bootstrap.homeEntry.invitations.first { $0.id == fixture.entryID })
        XCTAssertEqual(bootstrap.homeEntry.joinPresentation, .active(invitation))

        bootstrap.retry()
        XCTAssertFalse(bootstrap.invitations?.entries.contains { $0.id == fixture.entryID } == true,
            "The controller must continue filtering entries without a verified session")
        XCTAssertEqual(bootstrap.homeEntry.joinPresentation, .active(invitation),
            "A presentation-only exact entry survives the temporary store transition")
    }

    func testExplicitRetryOpensReadyInvitationAfterNativeVerificationFailsOnce() async throws {
        let fixture = try await importedInvitation()
        let verification = FirstRejoinFailure()
        let bootstrap = try await openImportedFixture(fixture, autoJoinInvitations: true,
            verifyMembership: { try await verification.refresh($0) })
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.joinError == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(bootstrap.joinError)
        XCTAssertNotEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.invited)

        try await bootstrap.joinInvitation(fixture.entryID)
        while bootstrap.invitations?.allEntries.first(where: { $0.id == fixture.entryID })?.activationResolved != true,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        while bootstrap.autoOpeningInvitationID != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.invited)
        XCTAssertTrue(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }?.activationResolved == true)
        XCTAssertNil(bootstrap.joinError)
        let attempts = await verification.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testNewerHomeSelectionDefersAutomaticOpenDuringNativeVerification() async throws {
        let fixture = try await importedInvitation()
        let held = RejoinVerificationProbe()
        let started = expectation(description: "Automatic verification held")
        let bootstrap = try await openImportedFixture(fixture, autoJoinInvitations: true,
            verifyMembership: { await held.hold($0) { started.fulfill() } })
        await fulfillment(of: [started], timeout: 5)
        let original = try XCTUnwrap(fixture.original)
        try await bootstrap.selectHome(original)
        await held.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.autoOpeningInvitationID != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(bootstrap.autoOpeningInvitationID, "The retired automatic Open must finish before state is asserted")
        let invitation = try XCTUnwrap(bootstrap.homeEntry.invitations.first { $0.id == fixture.entryID })
        XCTAssertEqual(bootstrap.homeEntry.joinPresentation, .deferred(invitation))
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, original)
        XCTAssertFalse(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }?.openRequested == true)
        XCTAssertFalse(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }?.activationResolved == true)
    }

    func testOpenSelectionSurvivesRefreshWhileCommittedDiscoveryIsHeld() async throws {
        let fixture = try await importedInvitation()
        let probe = OpenDiscoveryProbe()
        let started = expectation(description: "Open discovery held after grant")
        let bootstrap = try await openImportedFixture(fixture, discoverHomes: { service in
            try await probe.discover(service, started: { started.fulfill() })
        })
        let cart = try await blockedInvitedHome(fixture, bootstrap: bootstrap)
        let open = Task {
            try await OpenDiscoveryRequest.$mode.withValue(.open) {
                try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let readsBefore = await probe.ordinaryReads
        do { try await bootstrap.refreshHomes() } catch { XCTFail("Suppressed refresh failed: \(error)") }
        let readsAfter = await probe.ordinaryReads
        XCTAssertEqual(readsAfter, readsBefore, "Ordinary refresh must not supersede the committed Open selection")
        do {
            try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
            XCTFail("A second Open must not compete with the reserved selection")
        } catch {
            switch error {
            case HomeInvitationInbox.Error.busy: break
            default: XCTFail("Unexpected duplicate Open error: \(error)")
            }
        }
        await probe.release()
        try await open.value
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.invited)
        XCTAssertTrue(try XCTUnwrap(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }).activationResolved)
        XCTAssertEqual(try access(cart, graph: fixture.invited).currentGrants.count, 1)
        let openReads = await probe.openReads
        XCTAssertEqual(openReads, 2, "Release must await a trailing ordinary observation")
    }

    func testEarlierRefreshFailureCannotPublishDuringReservedOpenSelection() async throws {
        let fixture = try await importedInvitation()
        let probe = OpenDiscoveryProbe()
        let openStarted = expectation(description: "Open discovery held")
        let oldStarted = expectation(description: "Earlier ordinary discovery held")
        let bootstrap = try await openImportedFixture(fixture, discoverHomes: { service in
            try await probe.discover(service, started: { openStarted.fulfill() }, oldStarted: { oldStarted.fulfill() })
        })
        let cart = try await blockedInvitedHome(fixture, bootstrap: bootstrap)
        let old = Task {
            try await OpenDiscoveryRequest.$mode.withValue(.oldFailure) { try await bootstrap.refreshHomes() }
        }
        await fulfillment(of: [oldStarted], timeout: 5)
        let open = Task {
            try await OpenDiscoveryRequest.$mode.withValue(.open) {
                try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
            }
        }
        await fulfillment(of: [openStarted], timeout: 5)
        await probe.releaseOld()
        do { try await old.value } catch { XCTFail("Superseded failure escaped: \(error)") }
        XCTAssertNil(bootstrap.homeDiscoveryError)
        await probe.release()
        try await open.value
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.invited)
        XCTAssertTrue(try XCTUnwrap(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }).activationResolved)
        XCTAssertEqual(try access(cart, graph: fixture.invited).currentGrants.count, 1)
    }

    func testFailedOpenDiscoveryReleasesReservationAndPreservesOriginalFailure() async throws {
        let fixture = try await importedInvitation()
        let probe = OpenDiscoveryProbe(failOpen: true, failTrailing: true)
        let started = expectation(description: "Failing Open discovery held")
        let bootstrap = try await openImportedFixture(fixture, discoverHomes: { service in
            try await probe.discover(service, started: { started.fulfill() })
        })
        let cart = try await blockedInvitedHome(fixture, bootstrap: bootstrap)
        let open = Task {
            try await OpenDiscoveryRequest.$mode.withValue(.open) {
                try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
            }
        }
        await fulfillment(of: [started], timeout: 5)
        do { try await bootstrap.refreshHomes() } catch { XCTFail("Suppressed refresh failed: \(error)") }
        await probe.release()
        do { try await open.value; XCTFail("Discovery failure must remain the Open result") }
        catch { XCTAssertEqual(error as? OpenDiscoveryProbe.Failure, .expected) }
        let openReads = await probe.openReads
        XCTAssertEqual(openReads, 2, "Failure must release and replay the suppressed ordinary refresh")
        XCTAssertEqual(bootstrap.homeDiscoveryError as? OpenDiscoveryProbe.Failure, .trailing)
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.original)
        XCTAssertFalse(try XCTUnwrap(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }).activationResolved)
        XCTAssertEqual(try access(cart, graph: fixture.invited).currentGrants.count, 1)
        try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.invited)
        XCTAssertEqual(try access(cart, graph: fixture.invited).currentGrants.count, 1, "Retry uses the durable same-entry grant")
    }

    func testNotNowLeavesBlockedMembershipQuarantinedAndDoesNotVerifyOrGrant() async throws {
        let fixture = try await importedInvitation()
        let verification = RejoinVerificationProbe()
        let bootstrap = try await openImportedFixture(fixture, verifyMembership: { await verification.record($0) })
        let cart = try await blockedInvitedHome(fixture, bootstrap: bootstrap)
        try await bootstrap.keepCurrentHome(entryID: fixture.entryID)
        XCTAssertTrue(try access(cart, graph: fixture.invited).requiresExplicitRejoin)
        XCTAssertTrue(try access(cart, graph: fixture.invited).currentGrants.isEmpty)
        let calls = await verification.identities
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.original)
    }

    func testNewLossDuringHeldNativeVerificationPreventsGrant() async throws {
        let fixture = try await importedInvitation()
        let held = RejoinVerificationProbe()
        let started = expectation(description: "Membership verification held")
        let bootstrap = try await openImportedFixture(fixture, verifyMembership: {
            await held.hold($0) { started.fulfill() }
        })
        let cart = try await blockedInvitedHome(fixture, bootstrap: bootstrap)
        let open = Task { try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited) }
        await fulfillment(of: [started], timeout: 2)
        try cart.blockHomeEffects(householdID: fixture.invited.householdID, listID: fixture.invited.listID,
            share: HomeEffectShare(recordName: "invited-share", zoneName: "zone", zoneOwnerName: "owner"),
            reason: .revoked, operationID: UUID())
        await held.release()
        do { try await open.value; XCTFail("A fresh loss must win over the captured rejoin") }
        catch { XCTAssertEqual(error as? PersonalCartError, .scopeChanged) }
        XCTAssertTrue(try access(cart, graph: fixture.invited).currentGrants.isEmpty)
        XCTAssertFalse(try XCTUnwrap(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }).activationResolved)
    }

    func testRenewedInvitationInvalidatesHeldOpenChoiceBeforeItsGrant() async throws {
        let fixture = try await importedInvitation()
        let held = RejoinVerificationProbe()
        let started = expectation(description: "Membership verification held")
        let bootstrap = try await openImportedFixture(fixture, verifyMembership: {
            await held.hold($0) { started.fulfill() }
        })
        let cart = try await blockedInvitedHome(fixture, bootstrap: bootstrap)
        let open = Task { try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited) }
        await fulfillment(of: [started], timeout: 2)
        let controller = try XCTUnwrap(bootstrap.invitations)
        let entry = try XCTUnwrap(controller.allEntries.first { $0.id == fixture.entryID })
        let renewed = try await controller.enqueue(identity: entry.identity, metadataArchive: Data([2]), participantPending: true)
        XCTAssertEqual(renewed.id, entry.id)
        await held.release()
        do { try await open.value; XCTFail("A renewed entry must retire the older Open choice") }
        catch { XCTAssertEqual(error as? UICommandAuthority.Failure, .retired) }
        XCTAssertTrue(try access(cart, graph: fixture.invited).currentGrants.isEmpty)
        XCTAssertTrue(try access(cart, graph: fixture.invited).requiresExplicitRejoin)
    }

    func testRetiredPresentationDuringHeldVerificationCannotSaveGrant() async throws {
        let fixture = try await importedInvitation()
        let held = RejoinVerificationProbe()
        let started = expectation(description: "Membership verification held")
        let bootstrap = try await openImportedFixture(fixture, verifyMembership: {
            await held.hold($0) { started.fulfill() }
        })
        let cart = try await blockedInvitedHome(fixture, bootstrap: bootstrap)
        let open = Task { try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited) }
        await fulfillment(of: [started], timeout: 2)
        bootstrap.retireAndFail(ShopperSessionError.temporarilyUnavailable)
        await held.release()
        do { try await open.value; XCTFail("A retired presentation cannot restore membership") }
        catch { }
        XCTAssertTrue(try access(cart, graph: fixture.invited).currentGrants.isEmpty)
        await bootstrap.runLoadingTransition()
    }

    func testInvitationIngressRetiresOpenBeforeBlockedJournalPublishesReplacement() async throws {
        let fixture = try await importedInvitation()
        let held = RejoinVerificationProbe()
        let started = expectation(description: "Membership verification held")
        var observedWorker: HomeInvitationWorker?
        let bootstrap = try await openImportedFixture(fixture, verifyMembership: {
            await held.hold($0) { started.fulfill() }
        }, observeInvitationWorker: { observedWorker = $0 })
        let cart = try await blockedInvitedHome(fixture, bootstrap: bootstrap)
        let finished = expectation(description: "Old Open finishes while the journal remains held")
        let open = Task { () -> Result<Void, Error> in
            let result: Result<Void, Error>
            do {
                try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
                result = .success(())
            } catch { result = .failure(error) }
            finished.fulfill()
            return result
        }
        await fulfillment(of: [started], timeout: 2)
        let worker = try XCTUnwrap(observedWorker)
        let workerHeld = expectation(description: "Journal worker held")
        let releaseWorker = DispatchSemaphore(value: 0)
        defer { releaseWorker.signal() }
        worker.perform({ _ in workerHeld.fulfill(); releaseWorker.wait() }, completion: { _ in })
        await fulfillment(of: [workerHeld], timeout: 2)
        let controller = try XCTUnwrap(bootstrap.invitations)
        let old = try XCTUnwrap(controller.allEntries.first { $0.id == fixture.entryID })
        let ingress = expectation(description: "Replacement link received before journal publication")
        let invalidate = controller.onChoiceInvalidated
        controller.onChoiceInvalidated = { identity in invalidate?(identity); ingress.fulfill() }
        let renewed = Task { try await controller.enqueue(identity: old.identity, metadataArchive: Data([3]), participantPending: true) }
        await fulfillment(of: [ingress], timeout: 2)
        XCTAssertEqual(controller.allEntries.first { $0.id == fixture.entryID }, old)
        await held.release()
        // A regression must fail boundedly, then free the journal and drain both
        // tasks rather than hanging the test on a queued activation checkpoint.
        await fulfillment(of: [finished], timeout: 2)
        controller.onChoiceInvalidated = invalidate
        let retryFinished = expectation(description: "A new Open cannot use the stale entry during ingress")
        let retryOpen = Task { () -> Result<Void, Error> in
            let result: Result<Void, Error>
            do {
                try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
                result = .success(())
            } catch { result = .failure(error) }
            retryFinished.fulfill()
            return result
        }
        await fulfillment(of: [retryFinished], timeout: 2)
        releaseWorker.signal()
        _ = try await renewed.value
        switch await open.value {
        case .success: XCTFail("Synchronous link ingress must retire the earlier Open choice")
        case .failure(let error): XCTAssertEqual(error as? UICommandAuthority.Failure, .retired)
        }
        switch await retryOpen.value {
        case .success: XCTFail("An Open started after ingress must also wait for the replacement entry")
        case .failure(let error):
            guard case HomeInvitationInbox.Error.invalidState = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(try access(cart, graph: fixture.invited).currentGrants.isEmpty)
    }

    func testTwoInvitationsImportAndOpenInArrivalOrderWithoutReplacingSelection() async throws {
        try await assertTwoInvitationChoices(reversed: false)
    }

    func testTwoInvitationsImportAndOpenInReverseOrderWithoutReplacingSelection() async throws {
        try await assertTwoInvitationChoices(reversed: true)
    }

    private func assertTwoInvitationChoices(reversed: Bool) async throws {
        // Both accepted entries start loading. Completing import is the substituted
        // CloudKit boundary; journal publication and every Open use production code.
        let fixture = try await importedInvitation(ready: false, secondImportedHome: true)
        var observedWorker: HomeInvitationWorker?
        let bootstrap = try await openImportedFixture(fixture, observeInvitationWorker: { observedWorker = $0 })
        let worker = try XCTUnwrap(observedWorker)
        let controller = try XCTUnwrap(bootstrap.invitations)
        let original = try XCTUnwrap(fixture.original)
        let second = (try XCTUnwrap(fixture.unrelatedEntryID), try XCTUnwrap(fixture.secondInvited))
        let ordered = reversed ? [second, (fixture.entryID, fixture.invited)] : [(fixture.entryID, fixture.invited), second]
        XCTAssertNil(bootstrap.homeCoordinator.activeScope)
        XCTAssertEqual(controller.allEntries.filter { $0.state == .loading }.count, 2)
        try await completeImport(ordered[0], worker: worker, controller: controller)
        try await bootstrap.refreshHomes()
        XCTAssertNil(bootstrap.homeCoordinator.activeScope, "Ready import still requires an explicit home decision")
        XCTAssertFalse(try XCTUnwrap(controller.allEntries.first { $0.id == ordered[0].0 }).activationResolved)
        try await bootstrap.selectHome(original)
        let before = try await waitForReady(bootstrap)
        let originalEntries = try XCTUnwrap(before.personalCartService).entries(
            householdID: original.householdID, listID: original.listID)
        XCTAssertEqual(originalEntries.map(\.needID), [try XCTUnwrap(fixture.originalNeedID)])

        try await bootstrap.activateInvitedHome(entryID: ordered[0].0, graph: ordered[0].1)
        let firstOpen = try await waitForReady(bootstrap)
        XCTAssertEqual(firstOpen.homeScope?.graph, ordered[0].1)
        XCTAssertFalse(before.presentation.isActive)
        XCTAssertTrue(try XCTUnwrap(controller.allEntries.first { $0.id == ordered[0].0 }).activationResolved)
        XCTAssertFalse(try XCTUnwrap(controller.allEntries.first { $0.id == ordered[1].0 }).activationResolved)

        try await completeImport(ordered[1], worker: worker, controller: controller)
        try await bootstrap.refreshHomes()
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, ordered[0].1,
            "The later import must not replace the explicitly opened home")
        let afterLaterImport = try await waitForReady(bootstrap)
        XCTAssertEqual(afterLaterImport.presentation.id, firstOpen.presentation.id)
        XCTAssertFalse(try XCTUnwrap(controller.allEntries.first { $0.id == ordered[1].0 }).activationResolved)
        try await bootstrap.activateInvitedHome(entryID: ordered[1].0, graph: ordered[1].1)
        let secondOpen = try await waitForReady(bootstrap)
        XCTAssertEqual(secondOpen.homeScope?.graph, ordered[1].1)
        XCTAssertFalse(firstOpen.presentation.isActive)
        XCTAssertTrue(controller.allEntries.allSatisfy(\.activationResolved))
        XCTAssertEqual(Set(bootstrap.homeCoordinator.homes.map(\.graph)), [original, fixture.invited, second.1])
        for graph in [fixture.invited, second.1] {
            XCTAssertTrue(try XCTUnwrap(secondOpen.personalCartService).entries(
                householdID: graph.householdID, listID: graph.listID).isEmpty)
        }
        try await bootstrap.selectHome(original)
        let returned = try await waitForReady(bootstrap)
        let cart = try XCTUnwrap(returned.personalCartService)
        XCTAssertEqual(returned.homeScope?.graph, original)
        XCTAssertEqual(try cart.entries(householdID: original.householdID, listID: original.listID), originalEntries)
        XCTAssertEqual(try cart.outstandingNeedIDs(householdID: original.householdID, listID: original.listID),
            [try XCTUnwrap(fixture.originalNeedID)])
    }

    private func completeImport(_ choice: (UUID, HomeGraphIdentity), worker: HomeInvitationWorker,
                                controller: HomeInvitationController) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.perform({ inbox in
                try inbox.markReady(inbox.beginImportResolution(id: choice.0,
                    sharedStoreIdentifier: choice.1.storeIdentifier), graph: choice.1)
            }, completion: { result in continuation.resume(with: result.map { _ in () }) })
        }
        controller.checkAgain()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.allEntries.first(where: { $0.id == choice.0 })?.state != .ready(choice.1),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.allEntries.first { $0.id == choice.0 }?.state, .ready(choice.1))
    }

    func testNotNowKeepsOriginalScopeAndPrivateCartAndResolvesOnlyChosenInvitation() async throws {
        let fixture = try await importedInvitation(unrelatedInvitation: true)
        let bootstrap = try await openImportedFixture(fixture)
        let original = try XCTUnwrap(fixture.original)
        try await bootstrap.selectHome(original)
        let before = try await waitForReady(bootstrap)
        let cart = try XCTUnwrap(before.personalCartService)
        let entries = try cart.entries(householdID: original.householdID, listID: original.listID)
        XCTAssertEqual(entries.map(\.needID), [try XCTUnwrap(fixture.originalNeedID)])
        try await bootstrap.keepCurrentHome(entryID: fixture.entryID)
        let after = try await waitForReady(bootstrap)
        XCTAssertEqual(after.homeScope?.graph, original)
        XCTAssertEqual(after.presentation.id, before.presentation.id)
        XCTAssertTrue(before.presentation.isActive)
        XCTAssertEqual(try cart.entries(householdID: original.householdID, listID: original.listID), entries)
        let resolved = try XCTUnwrap(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID })
        let unrelated = try XCTUnwrap(bootstrap.invitations?.allEntries.first { $0.id == fixture.unrelatedEntryID })
        XCTAssertTrue(resolved.activationResolved)
        XCTAssertFalse(unrelated.activationResolved)
        XCTAssertTrue(bootstrap.homeCoordinator.homes.contains { $0.graph == fixture.invited })
    }

    func testOpenImportedHomeKeepsOriginalDiscoverableAndCartReturnsWithOriginal() async throws {
        let fixture = try await importedInvitation()
        let bootstrap = try await openImportedFixture(fixture)
        let original = try XCTUnwrap(fixture.original)
        try await bootstrap.selectHome(original)
        let before = try await waitForReady(bootstrap)
        do {
            try await bootstrap.selectHome(fixture.invited)
            XCTFail("The picker cannot bypass the named invitation choice")
        } catch { }
        do {
            try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: original)
            XCTFail("An entry cannot authorize a different graph")
        } catch {
            switch error {
            case HomeInvitationInbox.Error.invalidState: break
            default: XCTFail("Unexpected choice error: \(error)")
            }
        }
        XCTAssertTrue(before.presentation.isActive)
        try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
        let invited = try await waitForReady(bootstrap)
        XCTAssertEqual(invited.homeScope?.graph, fixture.invited)
        XCTAssertFalse(before.presentation.isActive)
        XCTAssertEqual(Set(bootstrap.homeCoordinator.homes.map(\.graph)), [original, fixture.invited])
        XCTAssertTrue(try XCTUnwrap(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }).activationResolved)
        XCTAssertTrue(try XCTUnwrap(invited.personalCartService).entries(householdID: fixture.invited.householdID,
            listID: fixture.invited.listID).isEmpty)
        try await bootstrap.selectHome(original)
        let returned = try await waitForReady(bootstrap)
        XCTAssertEqual(returned.homeScope?.graph, original)
        XCTAssertEqual(try XCTUnwrap(returned.personalCartService).entries(householdID: original.householdID,
            listID: original.listID).map(\.needID), [try XCTUnwrap(fixture.originalNeedID)])
    }

    func testNotNowWithoutOriginalDoesNotSelectSoleImportedHomeAfterRefreshOrRelaunch() async throws {
        let fixture = try await importedInvitation(originalHome: false)
        let bootstrap = try await openImportedFixture(fixture)
        XCTAssertNil(bootstrap.homeCoordinator.activeScope)
        try await bootstrap.keepCurrentHome(entryID: fixture.entryID)
        XCTAssertFalse(try XCTUnwrap(bootstrap.invitations).hasPendingActivation)
        try await bootstrap.refreshHomes()
        XCTAssertNil(bootstrap.homeCoordinator.activeScope)
        bootstrap.retireAndFail(ShopperSessionError.temporarilyUnavailable)
        await bootstrap.runLoadingTransition()
        let relaunched = try await openImportedFixture(fixture)
        XCTAssertNil(relaunched.homeCoordinator.activeScope)
        XCTAssertEqual(relaunched.homeCoordinator.homes.map(\.graph), [fixture.invited])
        try await relaunched.selectHome(fixture.invited)
        XCTAssertEqual(relaunched.homeCoordinator.activeScope?.graph, fixture.invited)
    }

    func testDiscoverableLoadingHomeCannotBypassInvitationValidationThroughPicker() async throws {
        let fixture = try await importedInvitation(ready: false)
        let bootstrap = try await openImportedFixture(fixture)
        let original = try XCTUnwrap(fixture.original)
        try await bootstrap.selectHome(original)
        XCTAssertTrue(bootstrap.homeCoordinator.homes.contains { $0.graph == fixture.invited })
        do {
            try await bootstrap.selectHome(fixture.invited)
            XCTFail("The picker cannot bypass exact-share validation for a loading invitation")
        } catch { }
        do {
            try await bootstrap.activateInvitedHome(entryID: fixture.entryID, graph: fixture.invited)
            XCTFail("Discovered graph alone is not a validated ready invitation")
        } catch {
            switch error {
            case HomeInvitationInbox.Error.invalidState: break
            default: XCTFail("Unexpected choice error: \(error)")
            }
        }
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, original)
        XCTAssertFalse(try XCTUnwrap(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }).activationResolved)
    }


    func testPendingInvitationDoesNotBlockPreviouslyJoinedDifferentShareInSameStore() async throws {
        let fixture = try await importedInvitation(ready: false)
        let previouslyJoined = HomeShareIdentity(recordName: "previously-joined-share", zoneName: "another-zone", zoneOwnerName: "another-owner")
        let bootstrap = try await openImportedFixture(fixture, detectedShare: previouslyJoined)
        try await bootstrap.selectHome(try XCTUnwrap(fixture.original))
        try await bootstrap.selectHome(fixture.invited)
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.invited)
        XCTAssertFalse(try XCTUnwrap(bootstrap.invitations?.allEntries.first { $0.id == fixture.entryID }).activationResolved,
            "Choosing an unrelated home must leave the invitation's own decision pending")
    }

    func testCachedOfflineAccountCanSelectUnrelatedHomeButCannotAcceptOrImportInvitation() async throws {
        let fixture = try await importedInvitation(ready: false)
        let offline = try ShopperSessionProvider(containerIdentifier: "iCloud.test.imported-choice",
            environment: "Development", cacheDirectory: fixture.directory.appendingPathComponent("Bindings"),
            lookup: .init(status: { throw CKError(.networkUnavailable) },
                recordName: { throw CKError(.networkUnavailable) }))
        let previousShare = HomeShareIdentity(recordName: "previously-joined-share", zoneName: "other-zone", zoneOwnerName: "other-owner")
        let bootstrap = try await openImportedFixture(fixture, accountProvider: offline, detectedShare: previousShare)
        let session = try offline.currentSession()
        XCTAssertEqual(offline.state, .cached(session))
        try await bootstrap.selectHome(try XCTUnwrap(fixture.original))
        try await bootstrap.selectHome(fixture.invited)
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope?.graph, fixture.invited)
        guard case .ready(let ready) = bootstrap.state else { return XCTFail("Expected retained account store") }
        let native = ManagedHomeInvitationTransport(persistence: ready.persistence, session: session)
        do {
            _ = try await native.shareIdentity(for: fixture.invited)
            XCTFail("Plain SQLite fixture must fail the native store-provenance check")
        } catch ManagedHomeInvitationError.sharedStoreUnavailable {
            // Cached authority passed only for the local read; native store checks remain intact.
        }
        do {
            _ = try await native.existingShare(identity: previousShare)
            XCTFail("Cached identity must not authorize native invitation processing")
        } catch ManagedHomeInvitationError.accountUnavailable { }
        do {
            _ = try await native.importedHome(identity: previousShare)
            XCTFail("Cached identity must not authorize native invitation import resolution")
        } catch ManagedHomeInvitationError.accountUnavailable { }
    }

}

private actor FirstRejoinFailure {
    enum Failure: Error { case firstVerification }

    private(set) var attempts = 0

    func refresh(_ identity: HomeNativeAccessIdentity) throws {
        attempts += 1
        if attempts == 1 { throw Failure.firstVerification }
    }
}

private actor RejoinVerificationProbe {
    private(set) var identities: [HomeNativeAccessIdentity] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func record(_ identity: HomeNativeAccessIdentity) { identities.append(identity) }
    func hold(_ identity: HomeNativeAccessIdentity, started: @Sendable () -> Void) async {
        record(identity)
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; started() }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private enum CopyDiscoveryRequest {
    @TaskLocal static var accessChange = false
}

private enum OpenDiscoveryRequest {
    enum Mode: Sendable { case normal, open, oldFailure }
    @TaskLocal static var mode: Mode = .normal
}

private actor OpenDiscoveryProbe {
    enum Failure: Error { case expected, trailing }
    private let failOpen: Bool
    private let failTrailing: Bool
    private(set) var openReads = 0
    private(set) var ordinaryReads = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var oldContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var oldReleased = false
    init(failOpen: Bool = false, failTrailing: Bool = false) {
        self.failOpen = failOpen
        self.failTrailing = failTrailing
    }
    func discover(_ service: HomeDiscoveryService, started: @Sendable () -> Void,
                  oldStarted: @Sendable () -> Void = {}) async throws -> HomeDiscovery {
        switch OpenDiscoveryRequest.mode {
        case .open:
            openReads += 1
            if openReads == 1 {
                if !released { await withCheckedContinuation { continuation = $0; started() } }
                else { started() }
                if failOpen { throw Failure.expected }
            } else if failTrailing { throw Failure.trailing }
        case .oldFailure:
            if !oldReleased { await withCheckedContinuation { oldContinuation = $0; oldStarted() } }
            else { oldStarted() }
            throw Failure.expected
        case .normal: ordinaryReads += 1
        }
        return try await Task.detached(priority: .utility) { try service.discover() }.value
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func releaseOld() { oldReleased = true; oldContinuation?.resume(); oldContinuation = nil }
}
