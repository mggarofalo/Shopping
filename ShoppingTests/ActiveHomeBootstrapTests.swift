import CloudKit
import XCTest
@testable import Shopping

@MainActor
final class ActiveHomeBootstrapTests: XCTestCase {
    private func makeBootstrap(homeCount: Int, pendingInvitation: Bool = false,
                               invitationInbox: Bool = false,
                               accountStatus: @escaping @Sendable () async -> CKAccountStatus = { .available },
                               accountLookup: ShopperSessionProvider.AccountLookup? = nil,
                               notifications: NotificationCenter = NotificationCenter(),
                               observeProvider: (ShopperSessionProvider) -> Void = { _ in },
                               fixturePrepared: (URL, UserDefaults) -> Void = { _, _ in },
                               discoverHomes: @escaping @Sendable (HomeDiscoveryService) async throws -> HomeDiscovery = { service in
                                   try await Task.detached(priority: .utility) { try service.discover() }.value
                               }) async throws -> PersistenceBootstrap {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "HomeBootstrap." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        fixturePrepared(root, defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let accountURL = root.appendingPathComponent("Account.sqlite")
        let persistence = try PersistenceController(storeURL: accountURL)
        for index in 0..<homeCount {
            _ = try NeedService(persistence: persistence).createHousehold(name: "Home \(index + 1)")
        }
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
        var invitations: HomeInvitationController?
        if pendingInvitation || invitationInbox {
            let inbox = try HomeInvitationInbox(url: root.appendingPathComponent("invitations.json"),
                containerIdentifier: "iCloud.test.home-bootstrap", environment: "Development")
            if pendingInvitation {
                try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: "iCloud.test.home-bootstrap",
                    environment: "Development", share: HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")),
                    metadataArchive: Data([1]))
            }
            invitations = HomeInvitationController(inbox: inbox)
        }
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.home-bootstrap", environment: "Development",
            cacheDirectory: root.appendingPathComponent("Bindings"), lookup: accountLookup ?? .init(
                status: accountStatus, recordName: { "account-A" }), notifications: notifications)
        let originalSession = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.home-bootstrap",
            environment: "Development", accountRecordName: "account-A")
        observeProvider(provider)
        let bootstrap = PersistenceBootstrap(
            configuration: { .local(storeURL: root.appendingPathComponent("Legacy.sqlite")) },
            defaults: defaults, invitations: invitations, autoResolveFreshAccount: false,
            autoJoinInvitations: false,
            makeAccountProvider: { _ in provider },
            accountStoreDirectory: { root },
            discoverHomes: discoverHomes,
            activateAccountStore: { _, session, _, _ in
                .local(storeURL: session == originalSession ? accountURL
                    : root.appendingPathComponent(session.accountBinding + ".sqlite"))
            }
        )
        retireBeforeCleanup(bootstrap)
        bootstrap.start()
        try await waitForReady(bootstrap)
        let choice = try await bootstrap.prepareInvitationSetup()
        try await bootstrap.confirmInvitationSetup(choice, copyLocal: false)
        await bootstrap.runLoadingTransition()
        try await waitForReady(bootstrap)
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

    func testInactiveHomeDetailsRenameExactHomeWithoutChangingSelectionAndRejectRetiredActions() async throws {
        let bootstrap = try await makeBootstrap(homeCount: 2)
        let homes = bootstrap.homeCoordinator.homes
        XCTAssertEqual(homes.count, 2)
        try await bootstrap.homeEntryCommands.select(homes[0].graph)
        let selected = try ready(bootstrap)
        let scope = try XCTUnwrap(bootstrap.homeDetailsScope(for: homes[1].graph))
        let actions = bootstrap.homeDetailsActions(scope: scope)
        try await actions.rename("Other renamed")
        XCTAssertEqual(try ready(bootstrap).homeScope, selected.homeScope)
        let persistence = selected.persistence
        let discovery = try await Task.detached {
            try HomeDiscoveryService(persistence: persistence).discover()
        }.value
        XCTAssertEqual(discovery.homes.first(where: { $0.graph == homes[1].graph })?.name, "Other renamed")
        XCTAssertEqual(discovery.homes.first(where: { $0.graph == homes[0].graph })?.name, homes[0].name)
        try await bootstrap.homeEntryCommands.select(homes[1].graph)
        do { try await actions.rename("Stale rename"); XCTFail("Retired detail actions must fail") }
        catch { XCTAssertEqual(error as? HomeMembershipError, .scopeChanged) }
    }

    func testColdInvitationDoesNotCreateAnEmptyLocalHomeBeforeAccountSetup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ColdHomeInvitation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let inbox = try HomeInvitationInbox(url: root.appendingPathComponent("invites/inbox.json"),
            containerIdentifier: "iCloud.test.home-bootstrap", environment: "Development")
        try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: "iCloud.test.home-bootstrap",
            environment: "Development", share: HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")),
            metadataArchive: Data([1]))
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.home-bootstrap",
            environment: "Development", cacheDirectory: root.appendingPathComponent("Bindings"),
            lookup: .init(status: { .noAccount }, recordName: { "unavailable-account" }),
            notifications: NotificationCenter())
        let bootstrap = PersistenceBootstrap(configuration: { .local(storeURL: root.appendingPathComponent("Local.sqlite")) },
            defaults: defaults, invitations: HomeInvitationController(inbox: inbox),
            makeAccountProvider: { _ in provider })
        retireBeforeCleanup(bootstrap)
        bootstrap.start()
        try await waitForFirstHomeDecision(bootstrap)
        XCTAssertNil(try ready(bootstrap).householdID)
        let service = try ready(bootstrap).service
        let storeIsEmpty = try await Task.detached(priority: .userInitiated) {
            try service.isPersistentStoreEmpty()
        }.value
        XCTAssertTrue(storeIsEmpty)
    }

    private func freshBootstrap(accountStatus: CKAccountStatus,
                                invitations: HomeInvitationController? = nil,
                                accountLookup: ShopperSessionProvider.AccountLookup? = nil,
                                seededDirectory: URL? = nil) throws -> PersistenceBootstrap {
        let root = seededDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "FreshHomeBootstrap." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.first-home",
            environment: "Development", cacheDirectory: root.appendingPathComponent("Bindings"),
            lookup: accountLookup ?? .init(status: { accountStatus }, recordName: { "account-A" }),
            notifications: NotificationCenter())
        let bootstrap = PersistenceBootstrap(
            configuration: { .local(storeURL: root.appendingPathComponent("Local.sqlite")) },
            defaults: defaults, invitations: invitations,
            makeAccountProvider: { _ in provider }, accountStoreDirectory: { root },
            activateAccountStore: { _, _, _, _ in
                .local(storeURL: root.appendingPathComponent("Account.sqlite"))
            })
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        retireBeforeCleanup(bootstrap)
        return bootstrap
    }

    private func waitForFirstHomeDecision(_ bootstrap: PersistenceBootstrap) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            // start() already owns the initial load. Drive only the account
            // transition that first-home resolution requested, so a second
            // initial load cannot publish a stale local Create state.
            if case .loading = bootstrap.state, bootstrap.isResolvingFirstAccount {
                await bootstrap.runLoadingTransition()
            }
            if bootstrap.homeEntry.root == .noHomes, !bootstrap.isResolvingFirstAccount { return }
            if case .failed(let error) = bootstrap.state { throw error }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("First-home account decision did not finish")
    }

    func testFreshAvailableAccountDiscoversBeforeOfferingAccountHomeCreation() async throws {
        let bootstrap = try freshBootstrap(accountStatus: .available)
        bootstrap.start()
        try await waitForFirstHomeDecision(bootstrap)
        XCTAssertFalse(bootstrap.homeEntry.isLocalStore)
        XCTAssertTrue(bootstrap.homeCoordinator.homes.isEmpty)
        try await bootstrap.createFirstHome()
        try await waitForPublishedHomes(bootstrap, count: 1)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "My Home")
        XCTAssertEqual(bootstrap.homeCoordinator.homes.count, 1)
    }

    func testFreshUnavailableAccountOffersExplicitLocalHomeWithoutAutoCreating() async throws {
        let bootstrap = try freshBootstrap(accountStatus: .noAccount)
        bootstrap.start()
        try await waitForFirstHomeDecision(bootstrap)
        XCTAssertTrue(bootstrap.homeEntry.isLocalStore)
        XCTAssertNil(try ready(bootstrap).householdID)
        XCTAssertTrue(try ready(bootstrap).service.isPersistentStoreEmpty())
        try await bootstrap.createFirstHome()
        XCTAssertEqual(bootstrap.homeEntry.root, .localHome)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "My Home")
    }

    func testImmediateCreateRetiresDeletedPendingIDsBeforeStatusHydration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let seeded = try PersistenceController(storeURL: directory.appendingPathComponent("Local.sqlite"))
        addTeardownBlock {
            seeded.writer.performAndWait { seeded.writer.reset() }
            for store in seeded.container.persistentStoreCoordinator.persistentStores {
                try? seeded.container.persistentStoreCoordinator.remove(store)
            }
        }
        let store = try XCTUnwrap(seeded.primaryStore)
        let url = try XCTUnwrap(store.url)
        let storeIdentifier = try XCTUnwrap(store.identifier)
        let journal = LocalHomeCreationJournal(storeURL: url)
        let oldCreation = try journal.begin(name: "Previous home", storeIdentifier: storeIdentifier)
        _ = try NeedService(persistence: seeded).createLocalHousehold(command: oldCreation)
        let graph = try XCTUnwrap(HomeDiscoveryService(persistence: seeded).discover().homes.first?.graph)
        let deletion = HomeDeletionService(persistence: seeded)
        let command = try await deletion.prepare(graph: graph, scope: nil)
        _ = try await deletion.execute(command)
        // Finish the durable fixture before launching Bootstrap. Its initial
        // asynchronous discovery must never observe the home before deletion.
        XCTAssertEqual(try journal.pending(storeIdentifier: storeIdentifier), oldCreation)
        seeded.writer.performAndWait { seeded.writer.reset() }
        seeded.container.viewContext.performAndWait { seeded.container.viewContext.reset() }
        try seeded.container.persistentStoreCoordinator.remove(store)
        let bootstrap = try freshBootstrap(accountStatus: .noAccount, seededDirectory: directory)
        bootstrap.start()
        try await waitForFirstHomeDecision(bootstrap)
        // No explicit deletion-status hydration precedes the first Create action.
        XCTAssertEqual(bootstrap.homeEntry.root, .noHomes)
        try await bootstrap.createFirstHome()
        let fresh = try ready(bootstrap)
        XCTAssertNotNil(fresh.householdID)
        XCTAssertNotEqual(fresh.householdID, oldCreation.householdID)
        XCTAssertNotEqual(fresh.listID, oldCreation.listID)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "My Home")
        XCTAssertEqual(try HomeDiscoveryService(persistence: fresh.persistence).discover().homes.count, 1)
    }

    func testDeferredUnboundInvitationAllowsExplicitOfflineFirstHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inbox = try HomeInvitationInbox(url: directory.appendingPathComponent("Invitations.json"),
            containerIdentifier: "iCloud.test.first-home", environment: "Development")
        let entry = try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: "iCloud.test.first-home",
            environment: "Development", share: HomeShareIdentity(recordName: "shared-home",
                zoneName: "zone", zoneOwnerName: "owner")), metadataArchive: Data([1]))
        let bootstrap = try freshBootstrap(accountStatus: .noAccount,
            invitations: HomeInvitationController(inbox: inbox))
        bootstrap.start()
        try await waitForFirstHomeDecision(bootstrap)
        XCTAssertTrue(bootstrap.homeEntry.hasPendingInvitation)
        try await bootstrap.dismissJoin(entry.id)
        XCTAssertFalse(bootstrap.homeEntry.invitations.first?.openRequested == true)
        // Not Now may coincide with the already-started connection. Wait for
        // that exact task and the visible Create state before tapping it.
        if let connection = bootstrap.automaticJoinConnectionTask(for: entry.id) {
            let settled = expectation(description: "Deferred invitation connection settled")
            Task { await connection.value; settled.fulfill() }
            await fulfillment(of: [settled], timeout: 5)
        }
        try await waitForFirstHomeDecision(bootstrap)
        do { try await bootstrap.createFirstHome() }
        catch {
            let entryState = bootstrap.homeEntry
            XCTFail("Create rejected after Not Now: \(error); root=\(entryState.root); local=\(entryState.isLocalStore); "
                + "resolving=\(entryState.isResolvingFirstAccount); pending=\(entryState.hasPendingInvitation); "
                + "open=\(entryState.invitations.first?.openRequested == true); state=\(bootstrap.state)")
            return
        }
        XCTAssertEqual(bootstrap.homeEntry.root, .localHome)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "My Home")
        XCTAssertEqual(bootstrap.homeEntry.invitations.first?.id, entry.id)
        XCTAssertFalse(bootstrap.invitations?.allEntries.first?.openRequested == true)
    }

    func testDismissingInviteDuringHeldAccountLookupAllowsFirstLocalHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inbox = try HomeInvitationInbox(url: directory.appendingPathComponent("Invitations.json"),
            containerIdentifier: "iCloud.test.first-home", environment: "Development")
        let entry = try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: "iCloud.test.first-home",
            environment: "Development", share: HomeShareIdentity(recordName: "held-share",
                zoneName: "zone", zoneOwnerName: "owner")), metadataArchive: Data([1]))
        let lookup = HeldSecondAccountLookup()
        addTeardownBlock { await lookup.release() }
        let bootstrap = try freshBootstrap(accountStatus: .noAccount,
            invitations: HomeInvitationController(inbox: inbox),
            accountLookup: .init(status: { await lookup.status() }, recordName: { "account-A" }))
        bootstrap.start()
        try await waitForFirstHomeDecision(bootstrap)
        let heldDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await lookup.hasHeld()), ContinuousClock.now < heldDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reachedHeldLookup = await lookup.hasHeld()
        XCTAssertTrue(reachedHeldLookup, "The invitation connection must reach its held account lookup")
        XCTAssertEqual(bootstrap.homeEntry.root, .noHomes)

        try await bootstrap.dismissJoin(entry.id)
        try await bootstrap.createFirstHome()
        XCTAssertEqual(bootstrap.homeEntry.root, .localHome)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "My Home")
        XCTAssertFalse(bootstrap.invitations?.allEntries.first?.openRequested == true)
        let connection = try XCTUnwrap(bootstrap.automaticJoinConnectionTask(for: entry.id))
        let settled = expectation(description: "Dismissed invitation connection settled")
        Task { await connection.value; settled.fulfill() }
        await lookup.release()
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(bootstrap.homeEntry.root, .localHome)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "My Home")
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
        let originalScope = try XCTUnwrap(old.homeScope)
        let cart = try XCTUnwrap(old.personalCartService)
        let needID = try old.service.addOneTimeNeed(title: "Original groceries", quantity: 2,
            householdID: originalScope.graph.householdID, listID: originalScope.graph.listID)
        try cart.cart(needID: needID, householdID: originalScope.graph.householdID, listID: originalScope.graph.listID)
        let entries = try cart.entries(householdID: originalScope.graph.householdID, listID: originalScope.graph.listID)
        let checkout = try cart.prepareCheckout(tokens: entries.map(\.token))
        let draft = CatalogEditorDraft(itemID: nil, name: "Unfinished bread", notes: "Keep this draft",
            categoryID: nil, anyStore: true, storeIDs: [])
        let lease = bootstrap.editorDrafts.open(scope: originalScope, editor: "catalog.new")
        try bootstrap.editorDrafts.save(draft, lease: lease)

        try await bootstrap.selectHome(homes[1].graph)
        let other = try ready(bootstrap)
        let otherScope = try XCTUnwrap(other.homeScope)
        XCTAssertFalse(old.presentation.isActive)
        XCTAssertEqual(other.householdID, homes[1].graph.householdID)
        XCTAssertThrowsError(try old.service.createCategory(name: "Stale", householdID: homes[0].graph.householdID))
        XCTAssertThrowsError(try cart.checkout(checkout)) { error in
            XCTAssertEqual(error as? UICommandAuthority.Failure, .retired)
        }
        XCTAssertNil(try bootstrap.editorDrafts.load(CatalogEditorDraft.self, scope: otherScope, editor: "catalog.new"))
        let otherCart = try XCTUnwrap(other.personalCartService)
        XCTAssertTrue(try otherCart.entries(householdID: otherScope.graph.householdID, listID: otherScope.graph.listID).isEmpty)
        XCTAssertTrue(try otherCart.history(householdID: originalScope.graph.householdID, listID: originalScope.graph.listID).isEmpty)
        XCTAssertTrue(try otherCart.history(householdID: otherScope.graph.householdID, listID: otherScope.graph.listID).isEmpty)

        try await bootstrap.selectHome(originalScope.graph)
        let returned = try ready(bootstrap)
        let returnedScope = try XCTUnwrap(returned.homeScope)
        let returnedCart = try XCTUnwrap(returned.personalCartService)
        XCTAssertEqual(returnedScope, originalScope)
        XCTAssertNotEqual(returned.presentation.id, old.presentation.id)
        XCTAssertEqual(try returnedCart.entries(householdID: originalScope.graph.householdID, listID: originalScope.graph.listID), entries)
        XCTAssertEqual(try returnedCart.outstandingNeedIDs(householdID: originalScope.graph.householdID, listID: originalScope.graph.listID), [needID])
        XCTAssertEqual(try bootstrap.editorDrafts.load(CatalogEditorDraft.self, scope: returnedScope, editor: "catalog.new"), draft)
        let reopenedLease = bootstrap.editorDrafts.open(scope: returnedScope, editor: "catalog.new")
        bootstrap.editorDrafts.finish(lease)
        XCTAssertEqual(try bootstrap.editorDrafts.load(CatalogEditorDraft.self, scope: returnedScope, editor: "catalog.new"), draft,
            "Completion from the retired editor must not remove its reopened draft")
        bootstrap.editorDrafts.finish(reopenedLease)
        XCTAssertEqual(bootstrap.homeCoordinator.homes.count, 2)
    }

    func testTemporaryAccountUnavailabilityRestoresHomeCartAndDraftButRejectsLateDiscovery() async throws {
        let account = BootstrapAccountAvailability()
        let discovery = BootstrapHeldDiscovery()
        let started = expectation(description: "Old account discovery captured")
        var observedProvider: ShopperSessionProvider?
        let bootstrap = try await makeBootstrap(homeCount: 2, accountStatus: { await account.status },
            observeProvider: { observedProvider = $0 }, discoverHomes: { service in
                let snapshot = try await Task.detached(priority: .utility) { try service.discover() }.value
                if BootstrapDiscoveryRequest.hold { await discovery.hold { started.fulfill() } }
                return snapshot
            })
        let provider = try XCTUnwrap(observedProvider)
        try await bootstrap.selectHome(try XCTUnwrap(bootstrap.homeCoordinator.homes.first).graph)
        let original = try ready(bootstrap)
        let scope = try XCTUnwrap(original.homeScope)
        let cart = try XCTUnwrap(original.personalCartService)
        let needID = try original.service.addOneTimeNeed(title: "Retained groceries", quantity: 3,
            householdID: scope.graph.householdID, listID: scope.graph.listID)
        try cart.cart(needID: needID, householdID: scope.graph.householdID, listID: scope.graph.listID)
        let entries = try cart.entries(householdID: scope.graph.householdID, listID: scope.graph.listID)
        let checkout = try cart.prepareCheckout(tokens: entries.map(\.token))
        let draft = CatalogEditorDraft(itemID: nil, name: "Still editing", notes: "Account A notes",
            categoryID: nil, anyStore: true, storeIDs: [])
        try bootstrap.editorDrafts.save(draft, scope: scope, editor: "catalog.new")
        let oldDiscovery = Task {
            try await BootstrapDiscoveryRequest.$hold.withValue(true) { try await bootstrap.refreshHomes() }
        }
        addTeardownBlock {
            await discovery.release()
            _ = await oldDiscovery.result
        }
        await fulfillment(of: [started], timeout: 5)
        await account.setUnavailable(true)
        await provider.refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while original.presentation.isActive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(original.presentation.isActive)
        await bootstrap.runLoadingTransition()
        guard case .failed(let error) = bootstrap.state else {
            return XCTFail("Temporary account loss must retire the mounted account presentation")
        }
        XCTAssertEqual(error as? ShopperSessionError, .temporarilyUnavailable)
        XCTAssertNil(bootstrap.homeCoordinator.activeScope)
        XCTAssertTrue(original.persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
        XCTAssertThrowsError(try cart.checkout(checkout))

        await account.setUnavailable(false)
        bootstrap.retry()
        await bootstrap.runLoadingTransition()
        try await waitForReady(bootstrap)
        let returned = try ready(bootstrap)
        XCTAssertEqual(try provider.currentSession().accountBinding, scope.accountBinding)
        XCTAssertEqual(returned.homeScope, scope)
        XCTAssertNotEqual(returned.presentation.id, original.presentation.id)
        XCTAssertTrue(returned.presentation.isActive)
        await discovery.release()
        try await oldDiscovery.value
        XCTAssertEqual(try ready(bootstrap).presentation.id, returned.presentation.id)
        XCTAssertEqual(bootstrap.homeCoordinator.activeScope, scope)
        XCTAssertNil(bootstrap.homeDiscoveryError)
        XCTAssertThrowsError(try cart.checkout(checkout)) { error in
            XCTAssertEqual(error as? UICommandAuthority.Failure, .retired)
        }
        let freshCart = try XCTUnwrap(returned.personalCartService)
        XCTAssertEqual(try freshCart.entries(householdID: scope.graph.householdID, listID: scope.graph.listID), entries)
        XCTAssertEqual(try freshCart.outstandingNeedIDs(householdID: scope.graph.householdID, listID: scope.graph.listID), [needID])
        XCTAssertTrue(try freshCart.history(householdID: scope.graph.householdID, listID: scope.graph.listID).isEmpty)
        XCTAssertEqual(try bootstrap.editorDrafts.load(CatalogEditorDraft.self, scope: scope, editor: "catalog.new"), draft)
        _ = try returned.service.createCategory(name: "Usable again", householdID: scope.graph.householdID)
    }

    func testAccountStatusNotificationAutomaticallyReopensSameHomeCartAndDraft() async throws {
        let center = NotificationCenter()
        let account = BootstrapMutableAccount()
        var observedProvider: ShopperSessionProvider?
        let bootstrap = try await makeBootstrap(homeCount: 1, accountLookup: account.lookup,
            notifications: center, observeProvider: { observedProvider = $0 })
        let provider = try XCTUnwrap(observedProvider)
        let original = try ready(bootstrap)
        let scope = try XCTUnwrap(original.homeScope)
        let cart = try XCTUnwrap(original.personalCartService)
        let needID = try original.service.addOneTimeNeed(title: "Retained groceries", quantity: 3,
            householdID: scope.graph.householdID, listID: scope.graph.listID)
        try cart.cart(needID: needID, householdID: scope.graph.householdID, listID: scope.graph.listID)
        let entries = try cart.entries(householdID: scope.graph.householdID, listID: scope.graph.listID)
        let checkout = try cart.prepareCheckout(tokens: entries.map(\.token))
        let draft = CatalogEditorDraft(itemID: nil, name: "Retained draft", notes: "Keep this",
            categoryID: nil, anyStore: true, storeIDs: [])
        try bootstrap.editorDrafts.save(draft, scope: scope, editor: "catalog.new")
        bootstrap.presentationDidAppear(original.presentation.id)
        let lookupsBefore = await account.recordLookupCount

        // A burst invalidates authority synchronously, but schedules one reopen.
        for _ in 0..<3 { center.post(name: .CKAccountChanged, object: nil) }
        XCTAssertThrowsError(try provider.currentSession())
        await waitForRetirement(original)
        XCTAssertThrowsError(try cart.checkout(checkout))
        await bootstrap.runLoadingTransition()
        XCTAssertFalse(original.persistence.container.persistentStoreCoordinator.persistentStores.isEmpty,
            "The mounted hierarchy must retire before stores detach")
        bootstrap.presentationDidDisappear(original.presentation.id)
        await bootstrap.runLoadingTransition()
        try await waitForReady(bootstrap)

        let returned = try ready(bootstrap)
        XCTAssertNotEqual(returned.presentation.id, original.presentation.id)
        XCTAssertEqual(returned.homeScope, scope)
        XCTAssertTrue(original.persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
        XCTAssertEqual(try provider.currentSession().accountBinding, scope.accountBinding)
        let lookupsAfter = await account.recordLookupCount
        XCTAssertEqual(lookupsAfter, lookupsBefore + 1)
        let returnedCart = try XCTUnwrap(returned.personalCartService)
        XCTAssertEqual(try returnedCart.entries(householdID: scope.graph.householdID, listID: scope.graph.listID), entries)
        XCTAssertEqual(try returnedCart.outstandingNeedIDs(householdID: scope.graph.householdID,
            listID: scope.graph.listID), [needID])
        XCTAssertTrue(try returnedCart.history(householdID: scope.graph.householdID, listID: scope.graph.listID).isEmpty)
        XCTAssertEqual(try bootstrap.editorDrafts.load(CatalogEditorDraft.self, scope: scope, editor: "catalog.new"), draft)
        XCTAssertThrowsError(try cart.checkout(checkout))
    }

    func testAccountStatusNotificationSwitchesStoresAndReturningPreservesOriginalCart() async throws {
        let center = NotificationCenter()
        let account = BootstrapMutableAccount()
        let bootstrap = try await makeBootstrap(homeCount: 1, accountLookup: account.lookup, notifications: center)
        let original = try ready(bootstrap)
        let scope = try XCTUnwrap(original.homeScope)
        let cart = try XCTUnwrap(original.personalCartService)
        let needID = try original.service.addOneTimeNeed(title: "Account A groceries", quantity: 1,
            householdID: scope.graph.householdID, listID: scope.graph.listID)
        try cart.cart(needID: needID, householdID: scope.graph.householdID, listID: scope.graph.listID)
        let entries = try cart.entries(householdID: scope.graph.householdID, listID: scope.graph.listID)
        let checkout = try cart.prepareCheckout(tokens: entries.map(\.token))
        let originalURL = original.persistence.primaryStore?.url
        await account.setName("account-B")
        center.post(name: .CKAccountChanged, object: nil)
        await waitForRetirement(original)
        await bootstrap.runLoadingTransition()
        try await waitForReady(bootstrap)
        let other = try ready(bootstrap)
        XCTAssertNil(other.homeScope)
        XCTAssertNotEqual(other.persistence.primaryStore?.url, originalURL)
        XCTAssertThrowsError(try cart.checkout(checkout))
        XCTAssertTrue(try XCTUnwrap(other.personalCartService).entries(householdID: scope.graph.householdID,
            listID: scope.graph.listID).isEmpty)

        await account.setName("account-A")
        center.post(name: .CKAccountChanged, object: nil)
        await waitForRetirement(other)
        await bootstrap.runLoadingTransition()
        try await waitForReady(bootstrap)
        let returned = try ready(bootstrap)
        XCTAssertEqual(returned.homeScope, scope)
        XCTAssertEqual(try XCTUnwrap(returned.personalCartService).entries(householdID: scope.graph.householdID,
            listID: scope.graph.listID), entries)
        XCTAssertThrowsError(try cart.checkout(checkout))
    }

    func testAccountChangeDefersQueuedNavigationBeforeNewMountAndColdReturnKeepsPriorHome() async throws {
        let center = NotificationCenter()
        let account = BootstrapMutableAccount()
        var root: URL?
        var defaults: UserDefaults?
        let bootstrap = try await makeBootstrap(homeCount: 1, invitationInbox: true,
            accountLookup: account.lookup, notifications: center,
            fixturePrepared: { root = $0; defaults = $1 })
        let original = try ready(bootstrap)
        let originalScope = try XCTUnwrap(original.homeScope)
        let controller = try XCTUnwrap(bootstrap.invitations)
        let originalSession = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.home-bootstrap",
            environment: "Development", accountRecordName: "account-A")
        let entry = try await controller.enqueue(identity: HomeInvitationIdentity(
            containerIdentifier: "iCloud.test.home-bootstrap", environment: "Development",
            share: HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")),
            metadataArchive: Data([1]))
        XCTAssertEqual(entry.session, originalSession)
        XCTAssertTrue(entry.openRequested)

        let held = expectation(description: "Replacement account verification held")
        await account.setName("account-B")
        await account.holdNextRecord { held.fulfill() }
        addTeardownBlock { await account.releaseRecord() }
        center.post(name: .CKAccountChanged, object: nil)
        await waitForRetirement(original)
        await bootstrap.runLoadingTransition()
        await fulfillment(of: [held], timeout: 5)
        XCTAssertFalse(controller.allEntries.first { $0.id == entry.id }?.openRequested == true,
            "The old intent is committed before the replacement account can mount")
        await account.releaseRecord()
        try await waitForReady(bootstrap)
        XCTAssertNil(try ready(bootstrap).homeScope)

        bootstrap.retireAndFail(ShopperSessionError.temporarilyUnavailable)
        await bootstrap.runLoadingTransition()
        let relaunchCenter = NotificationCenter()
        let relaunchRoot = try XCTUnwrap(root)
        let relaunchDefaults = try XCTUnwrap(defaults)
        let restoredInbox = try HomeInvitationInbox(url: relaunchRoot.appendingPathComponent("invitations.json"),
            containerIdentifier: "iCloud.test.home-bootstrap", environment: "Development")
        XCTAssertFalse(restoredInbox.entries.first { $0.id == entry.id }?.openRequested == true)
        let restoredProvider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.home-bootstrap",
            environment: "Development", cacheDirectory: relaunchRoot.appendingPathComponent("Bindings"),
            lookup: account.lookup, notifications: relaunchCenter)
        let relaunched = PersistenceBootstrap(
            configuration: { .local(storeURL: relaunchRoot.appendingPathComponent("Legacy.sqlite")) },
            defaults: relaunchDefaults, invitations: HomeInvitationController(inbox: restoredInbox),
            autoResolveFreshAccount: false, autoJoinInvitations: true,
            makeAccountProvider: { _ in restoredProvider }, accountStoreDirectory: { relaunchRoot },
            activateAccountStore: { _, session, _, _ in
                .local(storeURL: session == originalSession
                    ? relaunchRoot.appendingPathComponent("Account.sqlite")
                    : relaunchRoot.appendingPathComponent(session.accountBinding + ".sqlite"))
            }
        )
        retireBeforeCleanup(relaunched)
        relaunched.activatePersonalCarts(importLegacy: false)
        await relaunched.runLoadingTransition()
        try await waitForReady(relaunched)
        XCTAssertNil(try ready(relaunched).homeScope)
        await account.setName("account-A")
        let beforeReturn = try ready(relaunched)
        relaunchCenter.post(name: .CKAccountChanged, object: nil)
        await waitForRetirement(beforeReturn)
        await relaunched.runLoadingTransition()
        try await waitForReady(relaunched)
        XCTAssertEqual(try ready(relaunched).homeScope, originalScope)
        XCTAssertFalse(relaunched.invitations?.allEntries.first { $0.id == entry.id }?.openRequested == true)
        try await relaunched.invitations?.requestOpen(entry.id)
        XCTAssertTrue(relaunched.invitations?.allEntries.first { $0.id == entry.id }?.openRequested == true,
            "A deliberate Open still owns navigation")
    }

    func testCachedOtherAccountDefersOldIntentWhenVerifiedBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "CachedHomeNavigation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "shopping.personalCart.enabled")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let namespace = "iCloud.test.home-bootstrap"
        let originalSession = try ShopperSession.authenticated(containerIdentifier: namespace,
            environment: "Development", accountRecordName: "account-A")
        let inboxURL = root.appendingPathComponent("invitations.json")
        let inbox = try HomeInvitationInbox(url: inboxURL, containerIdentifier: namespace, environment: "Development")
        try inbox.setSession(originalSession)
        let old = try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: namespace,
            environment: "Development", share: HomeShareIdentity(recordName: "old-share",
                zoneName: "zone", zoneOwnerName: "owner")), metadataArchive: Data([1]))
        let controller = HomeInvitationController(inbox: try HomeInvitationInbox(url: inboxURL,
            containerIdentifier: namespace, environment: "Development"))
        await controller.prepare()
        let bindings = root.appendingPathComponent("Bindings")
        let warming = try ShopperSessionProvider(containerIdentifier: namespace, environment: "Development",
            cacheDirectory: bindings, lookup: .init(status: { .available }, recordName: { "account-B" }))
        await warming.refresh()
        let cachedB = try warming.currentSession()
        let account = BootstrapMutableAccount()
        await account.setName("account-B")
        await account.setStatus(.available, networkUnavailable: true)
        let center = NotificationCenter()
        let provider = try ShopperSessionProvider(containerIdentifier: namespace, environment: "Development",
            cacheDirectory: bindings, lookup: account.lookup, notifications: center)
        let bootstrap = PersistenceBootstrap(
            configuration: { .local(storeURL: root.appendingPathComponent("Legacy.sqlite")) },
            defaults: defaults, invitations: controller, autoResolveFreshAccount: false,
            autoJoinInvitations: true, makeAccountProvider: { _ in provider }, accountStoreDirectory: { root },
            activateAccountStore: { _, session, _, _ in
                .local(storeURL: root.appendingPathComponent(session.accountBinding + ".sqlite"))
            })
        retireBeforeCleanup(bootstrap)
        bootstrap.activatePersonalCarts(importLegacy: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        XCTAssertEqual(provider.state, .cached(cachedB))
        XCTAssertTrue(controller.allEntries.first { $0.id == old.id }?.openRequested == true,
            "A cached pointer alone must not retire another account's intent")

        await account.setStatus(.available, networkUnavailable: false)
        bootstrap.applicationDidEnterForeground()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if case .ready(let session) = provider.state {
                return session == cachedB
                    && controller.allEntries.first { $0.id == old.id }?.openRequested == false
            }
            return false
        }, object: nil)], timeout: 5)
        XCTAssertFalse(try HomeInvitationInbox(url: inboxURL, containerIdentifier: namespace,
            environment: "Development").entries.first { $0.id == old.id }?.openRequested == true)

        await account.setName("account-A")
        let previous = try ready(bootstrap)
        center.post(name: .CKAccountChanged, object: nil)
        await waitForRetirement(previous)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        XCTAssertFalse(controller.allEntries.first { $0.id == old.id }?.openRequested == true)
    }

    func testAccountStatusNotificationSignOutCannotReopenCachedAccount() async throws {
        try await assertAccountNotificationFails(status: .noAccount, networkUnavailable: false, expected: .noAccount)
    }

    func testAccountStatusNotificationNetworkFailureCannotReopenInvalidatedAccount() async throws {
        try await assertAccountNotificationFails(status: .available, networkUnavailable: true, expected: .temporarilyUnavailable)
    }

    func testAccountNotificationDuringReverificationRejectsLateIdentityAndRequiresFreshRetry() async throws {
        let center = NotificationCenter()
        let account = BootstrapMutableAccount()
        var observedProvider: ShopperSessionProvider?
        let bootstrap = try await makeBootstrap(homeCount: 1, accountLookup: account.lookup,
            notifications: center, observeProvider: { observedProvider = $0 })
        let provider = try XCTUnwrap(observedProvider)
        let original = try ready(bootstrap)
        let scope = try XCTUnwrap(original.homeScope)
        let requested = expectation(description: "Reverification suspended")
        await account.holdNextRecord { requested.fulfill() }
        addTeardownBlock { await account.releaseRecord() }
        center.post(name: .CKAccountChanged, object: nil)
        await waitForRetirement(original)
        await bootstrap.runLoadingTransition()
        await fulfillment(of: [requested], timeout: 5)
        center.post(name: .CKAccountChanged, object: nil)
        XCTAssertThrowsError(try provider.currentSession())
        await account.releaseRecord()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if case .failed = bootstrap.state { return true }
            return false
        }, object: nil)], timeout: 5)
        guard case .failed(let error) = bootstrap.state else { return XCTFail("Late identity must stay blocked") }
        XCTAssertEqual(error as? ShopperSessionError, .accountChanged)
        XCTAssertEqual(provider.state, .accountChanged)
        XCTAssertNil(bootstrap.homeCoordinator.activeScope)
        XCTAssertTrue(original.persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
        bootstrap.retry()
        await bootstrap.runLoadingTransition()
        try await waitForReady(bootstrap)
        XCTAssertEqual(try ready(bootstrap).homeScope, scope)
    }

    private func assertAccountNotificationFails(status: CKAccountStatus, networkUnavailable: Bool,
                                                expected: ShopperSessionError) async throws {
        let center = NotificationCenter()
        let account = BootstrapMutableAccount()
        var provider: ShopperSessionProvider?
        let bootstrap = try await makeBootstrap(homeCount: 1, accountLookup: account.lookup,
            notifications: center, observeProvider: { provider = $0 })
        let original = try ready(bootstrap)
        let originalURL = try XCTUnwrap(original.persistence.primaryStore?.url)
        await account.setStatus(status, networkUnavailable: networkUnavailable)
        center.post(name: .CKAccountChanged, object: nil)
        await waitForRetirement(original)
        await bootstrap.runLoadingTransition()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if case .failed = bootstrap.state { return true }
            return false
        }, object: nil)], timeout: 5)
        guard case .failed(let error) = bootstrap.state else { return XCTFail("Must stay blocked") }
        XCTAssertEqual(error as? ShopperSessionError, expected)
        XCTAssertThrowsError(try XCTUnwrap(provider).currentSession())
        XCTAssertNil(bootstrap.homeCoordinator.activeScope)
        XCTAssertTrue(original.persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
    }

    private func waitForRetirement(_ ready: PersistenceBootstrap.ReadyState) async {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !ready.presentation.isActive
        }, object: nil)], timeout: 5)
        XCTAssertFalse(ready.presentation.isActive)
    }

    func testExplicitCreationWorksFromEmptyImportWithoutReplacingAnotherHome() async throws {
        let startupDiscovery = expectation(description: "Startup access replay fetched its home discovery")
        let bootstrap = try await makeBootstrap(homeCount: 0, discoverHomes: { service in
            let snapshot = try await Task.detached(priority: .utility) { try service.discover() }.value
            startupDiscovery.fulfill()
            return snapshot
        })
        // Ready state precedes startup access replay. Establish its discovery
        // request before exercising creation without a competing refresh.
        await fulfillment(of: [startupDiscovery], timeout: 5)
        XCTAssertNil(try ready(bootstrap).householdID)
        XCTAssertTrue(bootstrap.homeCoordinator.homes.isEmpty)
        let first = try await bootstrap.createHome(name: "Our home")
        XCTAssertTrue(first.selected)
        XCTAssertEqual(try ready(bootstrap).householdID, first.householdID)
        XCTAssertEqual(try ready(bootstrap).listID, first.listID)
        try await bootstrap.acknowledgeHomeCreation(first)
        let previous = try ready(bootstrap)
        let second = try await bootstrap.createHome(name: "Other home")
        XCTAssertTrue(second.selected)
        XCTAssertEqual(try ready(bootstrap).householdID, second.householdID)
        XCTAssertEqual(try ready(bootstrap).listID, second.listID)
        XCTAssertFalse(previous.presentation.isActive)
        XCTAssertNotEqual(first.householdID, second.householdID)
        XCTAssertEqual(Set(bootstrap.homeCoordinator.homes.map(\.graph.householdID)), [first.householdID, second.householdID])
        try await bootstrap.selectHome(XCTUnwrap(bootstrap.homeCoordinator.homes.first { $0.graph.householdID == first.householdID }).graph)
        XCTAssertEqual(try ready(bootstrap).householdID, first.householdID)
    }

    private func waitForPublishedHomes(_ bootstrap: PersistenceBootstrap, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bootstrap.homeCoordinator.homes.count != count, ContinuousClock.now < deadline {
            // A newer startup/history request can supersede the awaited refresh.
            // Observe its publication without issuing another discovery action.
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bootstrap.homeCoordinator.homes.count, count)
    }

    func testConcurrentDiscoveryCannotReportCommittedCreationAsFailure() async throws {
        let bootstrap = try await makeBootstrap(homeCount: 1)
        var reachedBoundary = false
        let created = try await bootstrap.createHome(name: "Created during refresh") {
            // The creation's discovery request exists and its snapshot was fetched.
            // Force another request to supersede it before it can reconcile.
            do {
                try await bootstrap.refreshHomes()
                try await waitForPublishedHomes(bootstrap, count: 2)
            } catch { XCTFail("Intervening discovery failed: \(error)") }
            reachedBoundary = true
        }
        XCTAssertTrue(reachedBoundary)
        XCTAssertFalse(created.selected)
        try await bootstrap.refreshHomes()
        try await waitForPublishedHomes(bootstrap, count: 2)
        XCTAssertEqual(bootstrap.homeCoordinator.homes.filter { $0.graph.householdID == created.householdID }.count, 1)
        XCTAssertFalse(bootstrap.isCreatingHome)
    }
}

private actor BootstrapAccountAvailability {
    var status: CKAccountStatus = .available
    func setUnavailable(_ unavailable: Bool) { status = unavailable ? .temporarilyUnavailable : .available }
}

private actor HeldSecondAccountLookup {
    private var requests = 0
    private var held = false
    private var released = false
    private var resume: CheckedContinuation<Void, Never>?

    func status() async -> CKAccountStatus {
        requests += 1
        if requests == 2 {
            held = true
            if !released { await withCheckedContinuation { resume = $0 } }
        }
        return .noAccount
    }

    func hasHeld() -> Bool { held }

    func release() {
        released = true
        resume?.resume()
        resume = nil
    }
}

private enum BootstrapDiscoveryRequest {
    @TaskLocal static var hold = false
}

private actor BootstrapHeldDiscovery {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold(started: @Sendable () -> Void) async {
        guard !released else { started(); return }
        await withCheckedContinuation { continuation = $0; started() }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor BootstrapMutableAccount {
    private var status: CKAccountStatus = .available
    private var name = "account-A"
    private var networkUnavailable = false
    private(set) var recordLookupCount = 0
    private var onHeldRecord: (@Sendable () -> Void)?
    private var heldRecord: (String, CheckedContinuation<String, Never>)?

    nonisolated var lookup: ShopperSessionProvider.AccountLookup {
        .init(status: { try await self.readStatus() }, recordName: { await self.readName() })
    }

    func setName(_ name: String) { self.name = name }
    func setStatus(_ status: CKAccountStatus, networkUnavailable: Bool) {
        self.status = status
        self.networkUnavailable = networkUnavailable
    }
    private func readStatus() throws -> CKAccountStatus {
        if networkUnavailable { throw CKError(.networkUnavailable) }
        return status
    }
    func holdNextRecord(_ started: @escaping @Sendable () -> Void) { onHeldRecord = started }
    func releaseRecord() {
        guard let record = heldRecord else { return }
        heldRecord = nil
        record.1.resume(returning: record.0)
    }
    private func readName() async -> String {
        recordLookupCount += 1
        guard let started = onHeldRecord else { return name }
        onHeldRecord = nil
        let capturedName = name
        return await withCheckedContinuation { continuation in
            heldRecord = (capturedName, continuation)
            started()
        }
    }
}
