import CloudKit
import CoreData
import XCTest
@testable import Shopping

@MainActor
final class HomeAdoptionBootstrapTests: XCTestCase {
    private actor AccountIdentity {
        var name = "account-A"
        func current() -> String { name }
        func change() { name = "account-B" }
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

    private func bootstrap(_ fixture: Fixture, offline: Bool = false) -> PersistenceBootstrap {
        let destination = fixture.destination
        let bootstrap = PersistenceBootstrap(configuration: { .local(storeURL: fixture.source) }, defaults: fixture.defaults,
            makeAccountProvider: { _ in
                if offline { throw ShopperSessionError.temporarilyUnavailable }
                return fixture.provider
            }, accountStoreDirectory: { fixture.directory },
            activateAccountStore: { source, _, _, importing in
                XCTAssertNil(source, "Keeping a local home must never copy or merge it into account data")
                XCTAssertFalse(importing)
                return .local(storeURL: destination)
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

    private struct ImportedInvitationFixture {
        let directory: URL
        let privateURL: URL
        let participantURL: URL
        let inboxURL: URL
        let defaults: UserDefaults
        let provider: ShopperSessionProvider
        let original: HomeGraphIdentity?
        let invited: HomeGraphIdentity
        let entryID: UUID
        let unrelatedEntryID: UUID?
        let originalNeedID: UUID?
    }

    /// These are two plain SQLite stores. Only the choice authority's participant-store
    /// lookup is substituted; no native share acceptance or CloudKit transport is simulated.
    private func importedInvitation(originalHome: Bool = true, ready: Bool = true,
                                    unrelatedInvitation: Bool = false) async throws -> ImportedInvitationFixture {
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
            lookup: .init(status: { .available }, recordName: { "account-A" }))
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
        if unrelatedInvitation {
            unrelatedID = try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: session.containerIdentifier,
                environment: session.environment, share: HomeShareIdentity(recordName: "other-share", zoneName: "zone", zoneOwnerName: "owner")),
                metadataArchive: Data([2])).id
        }
        return ImportedInvitationFixture(directory: directory, privateURL: privateURL,
            participantURL: participantURL, inboxURL: inboxURL, defaults: defaults, provider: provider,
            original: original, invited: invited, entryID: entry.id,
            unrelatedEntryID: unrelatedID, originalNeedID: needID)
    }

    private func openImportedFixture(_ fixture: ImportedInvitationFixture,
                                     accountProvider: ShopperSessionProvider? = nil,
                                     detectedShare: HomeShareIdentity = HomeShareIdentity(recordName: "invited-share", zoneName: "zone", zoneOwnerName: "owner")) async throws -> PersistenceBootstrap {
        let inbox = try HomeInvitationInbox(url: fixture.inboxURL,
            containerIdentifier: "iCloud.test.imported-choice", environment: "Development")
        let invitations = HomeInvitationController(inbox: inbox)
        let privateURL = fixture.privateURL
        let participantURL = fixture.participantURL
        let bootstrap = PersistenceBootstrap(defaults: fixture.defaults, invitations: invitations,
            makeAccountProvider: { _ in accountProvider ?? fixture.provider }, accountStoreDirectory: { fixture.directory },
            participantStoreForHomeChoice: { persistence in
                persistence.container.persistentStoreCoordinator.persistentStores.first { $0.url == participantURL }
            }, invitationShareIdentity: { _, _, _ in detectedShare },
            activateAccountStore: { source, _, _, importing in
                XCTAssertNil(source)
                XCTAssertFalse(importing)
                return .local(storeURL: privateURL, additionalStoreURLs: [participantURL])
            })
        retireBeforeCleanup(bootstrap)
        bootstrap.activatePersonalCarts(importLegacy: false)
        await bootstrap.runLoadingTransition()
        _ = try await waitForReady(bootstrap)
        return bootstrap
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
