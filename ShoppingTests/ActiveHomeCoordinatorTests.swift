import CoreData
import XCTest
@testable import Shopping

@MainActor
final class ActiveHomeCoordinatorTests: XCTestCase {
    private func session(_ name: String = "A") throws -> ShopperSession {
        try .authenticated(containerIdentifier: "iCloud.test.shopping", environment: "Development",
            accountRecordName: name)
    }

    private func home(_ name: String = "Home", store: String = "private") -> HomeCandidate {
        HomeCandidate(graph: HomeGraphIdentity(storeIdentifier: store, rootURI: "x-coredata://" + UUID().uuidString,
            householdID: UUID(), listID: UUID()), name: name, access: .owner)
    }

    private func fixture() -> (ActiveHomeCoordinator, UserDefaults, String) {
        let suite = "ActiveHomeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (ActiveHomeCoordinator(defaults: defaults), defaults, suite)
    }

    private func discover(_ homes: [HomeCandidate], using coordinator: ActiveHomeCoordinator,
                          incomplete: Bool = false) throws {
        let request = try XCTUnwrap(coordinator.beginDiscovery())
        XCTAssertTrue(coordinator.reconcile(HomeDiscovery(homes: homes, hasIncompleteRoots: incomplete), request: request))
    }

    func testTwoRootsRequireExplicitChoiceAndRelaunchRestoresExactGraph() throws {
        let (coordinator, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = home(), b = home("Other", store: "shared")
        coordinator.bind(try session())
        try discover([b, a], using: coordinator)
        XCTAssertEqual(coordinator.readiness, .choiceRequired)
        try coordinator.select(b.graph)
        let reopened = ActiveHomeCoordinator(defaults: defaults)
        reopened.bind(try session())
        try discover([a, b], using: reopened)
        XCTAssertEqual(reopened.activeScope?.graph, b.graph)
    }

    func testIncompleteImportDoesNotSelectAnotherHomeOrLoseSavedSelection() throws {
        let (coordinator, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = home(), b = home("Other")
        coordinator.bind(try session())
        try discover([a], using: coordinator, incomplete: true)
        XCTAssertNil(coordinator.activeScope)
        try coordinator.select(a.graph)
        coordinator.setInvitationPending(true)
        try discover([a, b], using: coordinator, incomplete: true)
        XCTAssertEqual(coordinator.activeScope?.graph, a.graph)
        try discover([b], using: coordinator, incomplete: true)
        XCTAssertEqual(coordinator.readiness, .selectedHomeUnavailable)
        try discover([b, a], using: coordinator)
        XCTAssertEqual(coordinator.activeScope?.graph, a.graph)
    }

    func testAccountUnavailableAndDifferentAccountNeverReuseSelection() throws {
        let (coordinator, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = home(), b = home("Other")
        coordinator.bind(try session())
        try discover([a, b], using: coordinator)
        try coordinator.select(b.graph)
        let oldScope = try XCTUnwrap(coordinator.activeScope)
        let oldGeneration = coordinator.generation
        let late = try XCTUnwrap(coordinator.beginDiscovery())
        coordinator.bind(nil)
        XCTAssertEqual(coordinator.readiness, .accountUnavailable)
        XCTAssertFalse(coordinator.isCurrent(scope: oldScope, generation: oldGeneration))
        XCTAssertFalse(coordinator.reconcile(HomeDiscovery(homes: [a, b], hasIncompleteRoots: false), request: late))
        coordinator.bind(try session("B"))
        try discover([a, b], using: coordinator)
        XCTAssertEqual(coordinator.readiness, .choiceRequired)
        coordinator.bind(try session())
        try discover([a, b], using: coordinator)
        XCTAssertEqual(coordinator.activeScope, oldScope)
        XCTAssertFalse(coordinator.isCurrent(scope: oldScope, generation: oldGeneration))
    }

    func testSwitchInvalidatesInFlightDiscoveryAndCapturedCommands() throws {
        let (coordinator, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = home(), b = home("Other")
        coordinator.bind(try session())
        try discover([a, b], using: coordinator)
        try coordinator.select(a.graph)
        let capture = try XCTUnwrap(coordinator.activeScope), generation = coordinator.generation
        let request = try XCTUnwrap(coordinator.beginDiscovery())
        try coordinator.select(b.graph)
        XCTAssertFalse(coordinator.isCurrent(scope: capture, generation: generation))
        XCTAssertFalse(coordinator.reconcile(HomeDiscovery(homes: [a], hasIncompleteRoots: false), request: request))
        XCTAssertEqual(coordinator.activeScope?.graph, b.graph)
    }

    func testLateDiscoveryCannotOverwriteNewerObservation() throws {
        let (coordinator, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        coordinator.bind(try session())
        let first = try XCTUnwrap(coordinator.beginDiscovery())
        let second = try XCTUnwrap(coordinator.beginDiscovery())
        XCTAssertTrue(coordinator.reconcile(HomeDiscovery(homes: [], hasIncompleteRoots: true), request: second))
        XCTAssertFalse(coordinator.reconcile(HomeDiscovery(homes: [home()], hasIncompleteRoots: false), request: first))
        XCTAssertNil(coordinator.activeScope)
    }

    func testRemovedGraphIsNotReplacedBySameUUIDsInNewStore() throws {
        let (coordinator, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = home()
        coordinator.bind(try session())
        try discover([original], using: coordinator)
        let replacement = HomeCandidate(graph: HomeGraphIdentity(storeIdentifier: "new-store", rootURI: "new-root",
            householdID: original.graph.householdID, listID: original.graph.listID), name: "Home", access: .contributor)
        try discover([replacement], using: coordinator)
        XCTAssertEqual(coordinator.readiness, .selectedHomeUnavailable)
        try coordinator.select(replacement.graph)
        XCTAssertEqual(coordinator.activeScope?.graph, replacement.graph)
    }

    func testDiscoveryDistinguishesCompleteEmptyHomeFromPartialRoot() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let created = try service.createHousehold(name: "Empty home")
        let discovery = HomeDiscoveryService(persistence: persistence)
        var snapshot = try discovery.discover()
        XCTAssertEqual(snapshot.homes.map(\.graph.householdID), [created.householdID])
        XCTAssertFalse(snapshot.hasIncompleteRoots)
        try persistence.writer.performAndWait {
            let root = Household(context: persistence.writer)
            root.id = UUID()
            root.name = "Importing"
            try persistence.writer.save()
        }
        snapshot = try discovery.discover()
        XCTAssertEqual(snapshot.homes.count, 1)
        XCTAssertTrue(snapshot.hasIncompleteRoots)
    }

    func testPreferenceNamespaceSeparatesAccountsAndGraphIdentities() throws {
        let graph = home().graph
        let a = ActiveHomeScope(session: try session(), graph: graph)
        let b = ActiveHomeScope(session: try session("B"), graph: graph)
        XCTAssertNotEqual(a.preferenceNamespace, b.preferenceNamespace)
        XCTAssertEqual(a.preferenceNamespace, ActiveHomeScope(session: try session(), graph: graph).preferenceNamespace)
    }

    func testAccessDowngradeInvalidatesCaptureWithoutChangingSelectedHome() throws {
        let (coordinator, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = home()
        coordinator.bind(try session())
        try discover([a], using: coordinator)
        let scope = try XCTUnwrap(coordinator.activeScope), generation = coordinator.generation
        try discover([HomeCandidate(graph: a.graph, name: a.name, access: .restricted)], using: coordinator)
        XCTAssertEqual(coordinator.activeScope, scope)
        XCTAssertFalse(coordinator.isCurrent(scope: scope, generation: generation))
    }

    func testIncompleteDuplicateRootAndOrphanListPreventAmbiguousSelection() throws {
        let persistence = try PersistenceController(inMemory: true)
        let selected = try NeedService(persistence: persistence).createHousehold()
        let discovery = HomeDiscoveryService(persistence: persistence)
        try persistence.writer.performAndWait {
            let root = Household(context: persistence.writer)
            root.id = selected.householdID
            try persistence.writer.save()
        }
        XCTAssertTrue(try discovery.discover().homes.isEmpty)
        try persistence.writer.performAndWait {
            let roots = try persistence.writer.fetch(Household.fetchRequest())
            for root in roots where root.groceryList == nil { persistence.writer.delete(root) }
            let list = GroceryList(context: persistence.writer)
            list.id = selected.listID
            try persistence.writer.save()
        }
        let result = try discovery.discover()
        XCTAssertTrue(result.homes.isEmpty)
        XCTAssertTrue(result.hasIncompleteRoots)
    }

    func testDiscoverySeesRootCompletedByAnotherContext() throws {
        let persistence = try PersistenceController(inMemory: true)
        let discovery = HomeDiscoveryService(persistence: persistence)
        let rootID = try persistence.writer.performAndWait {
            let root = Household(context: persistence.writer)
            root.id = UUID()
            root.name = "Importing"
            try persistence.writer.save()
            return root.objectID
        }
        XCTAssertTrue(try discovery.discover().homes.isEmpty)
        let replica = persistence.simulationContext()
        try replica.performAndWait {
            let root = try XCTUnwrap(replica.existingObject(with: rootID) as? Household)
            let list = GroceryList(context: replica)
            list.id = UUID()
            list.household = root
            try replica.save()
        }
        let result = try discovery.discover()
        XCTAssertEqual(result.homes.count, 1)
        XCTAssertFalse(result.hasIncompleteRoots)
    }

    func testFiltersRemainSeparatedWhenAccountsHaveSameHouseholdUUID() throws {
        let (_, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let graph = home().graph, storeID = UUID()
        let a = ActiveHomeScope(session: try session(), graph: graph)
        let b = ActiveHomeScope(session: try session("B"), graph: graph)
        let navigation = GroceryNavigationState(defaults: defaults)
        navigation.configure(householdID: graph.householdID, activeStoreIDs: [storeID], scopeNamespace: a.preferenceNamespace)
        navigation.selectedStoreID = storeID
        navigation.urgentOnly = true
        navigation.configure(householdID: graph.householdID, activeStoreIDs: [storeID], scopeNamespace: b.preferenceNamespace)
        XCTAssertNil(navigation.selectedStoreID)
        XCTAssertFalse(navigation.urgentOnly)
        navigation.configure(householdID: graph.householdID, activeStoreIDs: [storeID], scopeNamespace: a.preferenceNamespace)
        XCTAssertEqual(navigation.selectedStoreID, storeID)
        XCTAssertTrue(navigation.urgentOnly)
    }

    func testRetiredPresentationCannotWriteThroughCapturedService() throws {
        let persistence = try PersistenceController(inMemory: true)
        let base = NeedService(persistence: persistence)
        let selected = try base.createHousehold()
        let authority = UICommandAuthority()
        let captured = base.scoped(to: authority)
        authority.retire()
        XCTAssertThrowsError(try captured.createStore(name: "Stale", householdID: selected.householdID)) {
            XCTAssertEqual($0 as? UICommandAuthority.Failure, .retired)
        }
        let result = try base.createStore(name: "Current", householdID: selected.householdID)
        try persistence.writer.performAndWait {
            let stores = try persistence.writer.fetch(Store.fetchRequest())
            XCTAssertEqual(stores.map(\.id), [result])
        }
    }

    func testRetiredCheckoutCaptureCannotStartButDurableServiceRemainsUsable() throws {
        struct Provider: ShopperSessionProviding {
            let value: ShopperSession
            func currentSession() throws -> ShopperSession { value }
        }
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let selected = try needs.createHousehold()
        let base = PersonalCartService(persistence: persistence, sessionProvider: Provider(value: try session()))
        let needID = try needs.addOneTimeNeed(title: "Milk", householdID: selected.householdID, listID: selected.listID)
        try base.cart(needID: needID, householdID: selected.householdID, listID: selected.listID)
        let authority = UICommandAuthority(), captured = base.scoped(to: authority)
        let entries = try captured.entries(householdID: selected.householdID, listID: selected.listID)
        let token = try captured.prepareCheckout(tokens: entries.map(\.token))
        authority.retire()
        XCTAssertThrowsError(try captured.checkout(token, operationID: token.id)) {
            XCTAssertEqual($0 as? UICommandAuthority.Failure, .retired)
        }
        XCTAssertEqual(try base.entries(householdID: selected.householdID, listID: selected.listID).count, 1)
        XCTAssertTrue(try base.history(householdID: selected.householdID, listID: selected.listID).isEmpty)
        try base.resumePending()
    }

    func testDraftRelaunchPreservesOriginalScopeAndExplicitDiscardOnlyClearsThatDraft() throws {
        let (_, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = ActiveHomeScope(session: try session(), graph: home().graph)
        let otherHome = ActiveHomeScope(session: try session(), graph: home().graph)
        let b = ActiveHomeScope(session: try session("B"), graph: a.graph)
        let store = HomeEditorDraftStore(defaults: defaults)
        let value = CatalogEditorDraft(itemID: UUID(), name: "Unfinished milk", notes: "Keep these notes",
            categoryID: UUID(), anyStore: false, storeIDs: [UUID()])
        try store.save(value, scope: a, editor: "catalog.new")
        let reopened = HomeEditorDraftStore(defaults: defaults)
        XCTAssertEqual(try reopened.load(CatalogEditorDraft.self, scope: a, editor: "catalog.new"), value)
        XCTAssertNil(try reopened.load(CatalogEditorDraft.self, scope: b, editor: "catalog.new"))
        XCTAssertNil(try reopened.load(CatalogEditorDraft.self, scope: otherHome, editor: "catalog.new"))
        try reopened.save("Other draft", scope: otherHome, editor: "catalog.new")
        reopened.remove(scope: a, editor: "catalog.new")
        XCTAssertNil(try reopened.load(CatalogEditorDraft.self, scope: a, editor: "catalog.new"))
        XCTAssertEqual(try reopened.load(String.self, scope: otherHome, editor: "catalog.new"), "Other draft")
    }

    func testRetirementDuringCommandRollsBackBeforeSave() throws {
        final class RetiringPolicy: PersistencePermissionPolicy {
            var authority: UICommandAuthority?
            func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {
                authority?.retire()
            }
        }
        let policy = RetiringPolicy()
        let persistence = try PersistenceController(configuration: .local(storeURL: nil, inMemory: true), permissionPolicy: policy)
        let base = NeedService(persistence: persistence)
        let selected = try base.createHousehold()
        let authority = UICommandAuthority()
        policy.authority = authority
        XCTAssertThrowsError(try base.scoped(to: authority).createStore(name: "Uncommitted", householdID: selected.householdID))
        let writer = persistence.writer
        try writer.performAndWait {
            XCTAssertTrue(try writer.fetch(Store.fetchRequest()).isEmpty)
        }
    }

    func testCompletedDraftCannotReappearAndOldCompletionCannotEraseReopenedDraft() throws {
        let (_, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeEditorDraftStore(defaults: defaults)
        let scope = ActiveHomeScope(session: try session(), graph: home().graph)
        let first = store.open(scope: scope, editor: "store.new")
        try store.save("Old name", lease: first)
        let reopened = store.open(scope: scope, editor: "store.new")
        try store.save("New name", lease: reopened)
        store.finish(first)
        try store.save("Delayed old change", lease: first)
        XCTAssertEqual(try store.load(String.self, scope: scope, editor: "store.new"), "New name")
        store.finish(reopened)
        try store.save("Late change after cancel", lease: reopened)
        XCTAssertNil(try store.load(String.self, scope: scope, editor: "store.new"))
    }

    func testParentCompletionInvalidatesChildrenWithoutTouchingAnotherEditor() throws {
        let (_, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeEditorDraftStore(defaults: defaults)
        let scope = ActiveHomeScope(session: try session(), graph: home().graph)
        let parent = store.open(scope: scope, editor: "grocery.new")
        let child = store.open(scope: scope, editor: "grocery.new.new-store")
        let other = store.open(scope: scope, editor: "grocery.newer.new-store")
        try store.save("Child", lease: child)
        try store.save("Other", lease: other)
        store.finish(parent)
        try store.save("Delayed child", lease: child)
        XCTAssertNil(try store.load(String.self, scope: scope, editor: "grocery.new.new-store"))
        XCTAssertEqual(try store.load(String.self, scope: scope, editor: "grocery.newer.new-store"), "Other")
    }
}
