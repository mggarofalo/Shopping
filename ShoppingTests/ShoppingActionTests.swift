import Foundation
import Testing
@testable import Shopping

@Suite("System action routing", .tags(.unit, .critical))
@MainActor
struct ShoppingActionTests {
    @Test func pendingActionCannotOverwriteAnotherRequest() throws {
        let router = ShoppingActionRouter()
        let scope = UUID()
        try router.enqueue(.addItem, presentationID: scope)
        #expect(throws: ShoppingActionError.busy) {
            try router.enqueue(.catalog("milk"), presentationID: scope)
        }
        #expect(try router.take(presentationID: scope) == .addItem)
        #expect(try router.take(presentationID: scope) == nil)
    }

    @Test func boundActionCannotCrossHomeOrAccountTransition() throws {
        let router = ShoppingActionRouter()
        try router.enqueue(.addItem, presentationID: UUID())
        #expect(throws: ShoppingActionError.scopeChanged) {
            try router.take(presentationID: UUID())
        }
        #expect(router.pending == nil)
    }

    @Test func coldNavigationBindsAtFirstReadyHomeAndExpires() throws {
        let router = ShoppingActionRouter()
        let now = Date()
        try router.enqueue(.groceries, presentationID: nil, now: now)
        #expect(try router.take(presentationID: UUID(), now: now) == .groceries)
        try router.enqueue(.addItem, presentationID: nil, now: now)
        #expect(try router.take(presentationID: UUID(), now: now.addingTimeInterval(301)) == nil)
        try router.enqueue(.addItem, presentationID: nil)
        router.cancel()
        #expect(router.pending == nil)
    }

    @Test func knownQuickActionsMapToOnlyThreeDestinations() {
        #expect(ShoppingActionDestination(shortcutType: "com.mggarofalo.shopping.add") == .addItem)
        #expect(ShoppingActionDestination(shortcutType: "com.mggarofalo.shopping.groceries") == .groceries)
        #expect(ShoppingActionDestination(shortcutType: "com.mggarofalo.shopping.catalog") == .catalog(""))
        #expect(ShoppingActionDestination(shortcutType: "unexpected") == nil)
    }

    @Test func simultaneousBackgroundStartupUsesSameReadyPresentation() async throws {
        let environment = try ShoppingPreviewFixtures.make(.populated)
        let bootstrap = PersistenceBootstrap(preloadedPreviewEnvironment: environment)
        let runtime = ShoppingApplicationRuntime(bootstrap: bootstrap)
        async let first = runtime.ready()
        async let second = runtime.ready()
        let (a, b) = try await (first, second)
        #expect(a.presentation.id == b.presentation.id)
        #expect(a.householdID == b.householdID)
        #expect(a.presentation.isActive)
        #expect(!bootstrap.isPresentationMounted(a.presentation.id))
    }

    @Test func failedBackgroundStartupReportsFailureWithoutMountingUI() async {
        let bootstrap = PersistenceBootstrap(configuration: { throw ShoppingActionError.homeUnavailable })
        let runtime = ShoppingApplicationRuntime(bootstrap: bootstrap)
        await #expect(throws: ShoppingActionError.homeUnavailable) { try await runtime.ready() }
    }

    @Test func cancelledCallerDoesNotRetireAnotherCallersRuntime() async throws {
        let environment = try ShoppingPreviewFixtures.make(.populated)
        let runtime = ShoppingApplicationRuntime(bootstrap: PersistenceBootstrap(preloadedPreviewEnvironment: environment))
        let cancelled = Task { try await runtime.ready() }
        cancelled.cancel()
        _ = await cancelled.result
        let ready = try await runtime.ready()
        #expect(ready.presentation.isActive)
    }


    @Test func groceryActionsReturnFromCartAndHistoryToListRoot() {
        let navigation = GroceryNavigationState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        navigation.groceryPath = [.carted]
        navigation.requestSystemAction(.groceries)
        #expect(navigation.groceryPath.isEmpty)
        navigation.groceryPath = [.recentlyCleared]
        navigation.requestSystemAction(.addItem)
        #expect(navigation.groceryPath.isEmpty)
        #expect(navigation.systemAddRequestID != nil)
    }

}
