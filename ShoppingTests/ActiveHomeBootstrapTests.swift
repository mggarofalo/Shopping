import CloudKit
import XCTest
@testable import Shopping

@MainActor
final class ActiveHomeBootstrapTests: XCTestCase {
    private func makeBootstrap(homeCount: Int, pendingInvitation: Bool = false,
                               accountStatus: @escaping @Sendable () async -> CKAccountStatus = { .available },
                               accountLookup: ShopperSessionProvider.AccountLookup? = nil,
                               notifications: NotificationCenter = NotificationCenter(),
                               observeProvider: (ShopperSessionProvider) -> Void = { _ in },
                               discoverHomes: @escaping @Sendable (HomeDiscoveryService) async throws -> HomeDiscovery = { service in
                                   try await Task.detached(priority: .utility) { try service.discover() }.value
                               }) async throws -> PersistenceBootstrap {
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
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
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
                                invitations: HomeInvitationController? = nil) throws -> PersistenceBootstrap {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "FreshHomeBootstrap." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let provider = try ShopperSessionProvider(containerIdentifier: "iCloud.test.first-home",
            environment: "Development", cacheDirectory: root.appendingPathComponent("Bindings"),
            lookup: .init(status: { accountStatus }, recordName: { "account-A" }),
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
            if case .loading = bootstrap.state { await bootstrap.runLoadingTransition() }
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
        try await bootstrap.createFirstHome()
        XCTAssertEqual(bootstrap.homeEntry.root, .localHome)
        XCTAssertEqual(bootstrap.homeEntry.currentHomeName, "My Home")
        XCTAssertEqual(bootstrap.homeEntry.invitations.first?.id, entry.id)
        XCTAssertFalse(bootstrap.invitations?.allEntries.first?.openRequested == true)
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
