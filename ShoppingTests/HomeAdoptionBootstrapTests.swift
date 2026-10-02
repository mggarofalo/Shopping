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

    /// These are two plain SQLite stores. The participant-store lookup and native
    /// rejoin verification boundary are substituted; no CloudKit result is proven.
    private func importedInvitation(originalHome: Bool = true, ready: Bool = true,
                                    unrelatedInvitation: Bool = false, secondImportedHome: Bool = false) async throws -> ImportedInvitationFixture {
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
