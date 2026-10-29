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

    @Test func readinessFailsVisiblyWhileTheStoreIsStillOpening() async {
        let opening = DispatchSemaphore(value: 0)
        defer { opening.signal() }
        let runtime = ShoppingApplicationRuntime(bootstrap: PersistenceBootstrap(configuration: {
            opening.wait()
            throw ShoppingActionError.homeUnavailable
        }))
        let started = ContinuousClock.now
        await #expect(throws: ShoppingActionError.loading) { try await runtime.ready(timeout: .milliseconds(300)) }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func deadlineAbandonsUninterruptibleWorkAndReportsTheTimeout() async {
        let stuck = DispatchSemaphore(value: 0)
        defer { stuck.signal() }
        let started = ContinuousClock.now
        await #expect(throws: ShoppingActionError.timedOut) {
            try await ShoppingActionDeadline.run(within: .milliseconds(200), onTimeout: .timedOut) {
                await Task.detached { stuck.wait(); return 1 }.value
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func deadlineReturnsFinishedWorkAndHonorsCallerCancellation() async throws {
        #expect(try await ShoppingActionDeadline.run(within: .seconds(5), onTimeout: .timedOut) { 7 } == 7)
        await #expect(throws: NeedServiceError.invalidName) {
            try await ShoppingActionDeadline.run(within: .seconds(5), onTimeout: .timedOut) { () throws -> Int in
                throw NeedServiceError.invalidName
            }
        }
        let stuck = DispatchSemaphore(value: 0)
        defer { stuck.signal() }
        let caller = Task {
            try await ShoppingActionDeadline.run(within: .seconds(60), onTimeout: .timedOut) {
                await Task.detached { stuck.wait(); return 1 }.value
            }
        }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
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
