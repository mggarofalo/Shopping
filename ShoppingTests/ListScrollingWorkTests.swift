import CoreData
import SwiftUI
import UIKit
import XCTest
@testable import Shopping

/// A mounted list must only lay out rows while it scrolls, and a screen update that leaves a
/// row's data unchanged must not rebuild that row. CloudKit merges into the view context while
/// someone scrolls; rebuilding and re-laying out every row on each one dropped frames (SHOPPING-272).
@MainActor
final class ListScrollingWorkTests: XCTestCase {
    private let fixtureLifetime = SQLiteTestFixtureLifetime()

    func testScrollingGroceriesFetchesNothing() async throws {
        try await whileMounted { GroceriesView(navigation: GroceryNavigationState()) } run: { list in
            try await self.assertScrollingFetchesNothing(list)
        }
    }

    func testScrollingCatalogFetchesNothing() async throws {
        try await whileMounted { CatalogView(navigation: GroceryNavigationState()) } run: { list in
            try await self.assertScrollingFetchesNothing(list)
        }
    }

    func testContextMergeWithoutChangesRebuildsNoGroceryRow() async throws {
        try await whileMounted { GroceriesView(navigation: GroceryNavigationState()) } run: { list in
            GroceryNeedRow.renderedNeedIDs = []
            for _ in 0..<3 {
                NotificationCenter.default.post(name: .NSManagedObjectContextObjectsDidChange, object: list.context)
                try await self.settle()
            }
            XCTAssertEqual(GroceryNeedRow.renderedNeedIDs, [], "Unchanged rows were rebuilt")
        }
    }

    func testCatalogRenameRebuildsOnlyOnScreenGroceryRows() async throws {
        try await whileMounted { GroceriesView(navigation: GroceryNavigationState()) } run: { list in
            let needs = try list.context.fetch(Need.fetchRequest())
            let need = try XCTUnwrap(needs.first { $0.id == list.fixture.ids.needIDs["need-0"] })
            GroceryNeedRow.renderedNeedIDs = []
            // The row shows the catalog name, which lives on a related object, not on the need.
            need.item?.name = "Plantains"
            list.context.processPendingChanges()
            try await self.settle()
            XCTAssertTrue(GroceryNeedRow.renderedNeedIDs.contains(need.id), "The renamed row kept its old name")
            self.assertOnlyOnScreenRowsRebuilt(GroceryNeedRow.renderedNeedIDs, in: list, total: needs.count)
        }
    }

    func testContextMergeWithoutChangesRebuildsNoCatalogRow() async throws {
        try await whileMounted { CatalogView(navigation: GroceryNavigationState()) } run: { list in
            CatalogItemRow.renderedItemIDs = []
            for _ in 0..<3 {
                NotificationCenter.default.post(name: .NSManagedObjectContextObjectsDidChange, object: list.context)
                try await self.settle()
            }
            XCTAssertEqual(CatalogItemRow.renderedItemIDs, [], "Unchanged rows were rebuilt")
        }
    }

    func testCatalogEditRebuildsOnlyOnScreenCatalogRows() async throws {
        try await whileMounted { CatalogView(navigation: GroceryNavigationState()) } run: { list in
            let items = try list.context.fetch(Item.fetchRequest())
            let item = try XCTUnwrap(items.first { $0.id == list.fixture.ids.itemIDs["item-0"] })
            CatalogItemRow.renderedItemIDs = []
            item.notes = "Ripe ones"
            list.context.processPendingChanges()
            try await self.settle()
            XCTAssertTrue(CatalogItemRow.renderedItemIDs.contains(item.id), "The edited row kept its old notes")
            self.assertOnlyOnScreenRowsRebuilt(CatalogItemRow.renderedItemIDs, in: list, total: items.count)
        }
    }

    func testRowModelChangesWithEveryDisplayedRelationship() throws {
        let fixture = try ShoppingPreviewFixtures.make(.scrolling)
        let context = fixture.persistence.container.viewContext
        let request = Need.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", try XCTUnwrap(fixture.ids.needIDs["need-6"]) as CVarArg)
        let need = try XCTUnwrap(try context.fetch(request).first)
        let people = try context.fetch(Person.fetchRequest())
        let stores = try context.fetch(Store.fetchRequest())
        let rowContext = GroceryRowContext(commandScope: UUID(), people: people, selectedStoreID: nil, activeStores: stores)
        let original = rowContext.model(for: need)
        XCTAssertEqual(rowContext.model(for: need), original, "Unchanged data must compare equal")
        XCTAssertNotNil(original.personLabel)

        need.item?.name = "Renamed"
        XCTAssertNotEqual(rowContext.model(for: need), original)
        need.item?.name = original.title
        need.person?.name = "Renamed person"
        XCTAssertNotEqual(rowContext.model(for: need), original)
        need.person?.name = original.personLabel ?? ""
        need.item?.anyStore = false
        need.item?.stores = [stores[0]]
        XCTAssertNotEqual(rowContext.model(for: need).storeLabels, original.storeLabels)
        XCTAssertNotEqual(rowContext.model(for: need, personalCarted: true), rowContext.model(for: need))
        let otherScope = GroceryRowContext(commandScope: UUID(), people: people, selectedStoreID: nil, activeStores: stores)
        XCTAssertNotEqual(otherScope.model(for: need), rowContext.model(for: need),
                          "A new presentation must rebuild rows with its own commands")
    }

    // MARK: - Harness

    private struct RowsNotShown: Error {}

    /// A screen in its own window, reading the fixture through a counting coordinator.
    @MainActor private struct HostedScreen {
        let window: UIWindow
        let previousWindow: UIWindow?
        let context: NSManagedObjectContext
        let coordinator: FetchCountingCoordinator
        let fixture: ShoppingPreviewEnvironment
    }

    @MainActor private struct MountedList {
        let collection: UICollectionView
        let context: NSManagedObjectContext
        let coordinator: FetchCountingCoordinator
        let fixture: ShoppingPreviewEnvironment
    }

    /// Mounts a screen, runs `body`, and releases the screen on every exit, so a failed assertion
    /// never leaves a screen reading a store that teardown deletes.
    private func whileMounted<Content: View>(
        @ViewBuilder _ content: () -> Content, run body: (MountedList) async throws -> Void
    ) async throws {
        var screen: HostedScreen? = try host(content: content)
        var failure: Error?
        do {
            try await body(try await rowsShown(in: try XCTUnwrap(screen)))
        } catch {
            failure = error
        }
        try await release(&screen)
        if let failure { throw failure }
    }

    private func host<Content: View>(@ViewBuilder content: () -> Content) throws -> HostedScreen {
        let lifetime = fixtureLifetime
        addTeardownBlock { try lifetime.cleanup() }
        let storeURL = try fixtureLifetime.makeDirectory().appendingPathComponent("scrolling.sqlite")
        let fixture = try ShoppingPreviewFixtures.make(.scrolling, storeURL: storeURL)
        fixtureLifetime.own(fixture.persistence)
        // The view reads through its own coordinator, so every fetch it issues is counted.
        let container = fixture.persistence.container
        let coordinator = FetchCountingCoordinator(managedObjectModel: container.managedObjectModel)
        let description = try XCTUnwrap(container.persistentStoreDescriptions.first)
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: description.configuration,
                                           at: storeURL, options: description.options)
        let context = fixtureLifetime.own(NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType))
        context.persistentStoreCoordinator = coordinator
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: content()
            .environment(\.managedObjectContext, context)
            .environment(\.needService, fixture.service)
            .environment(\.persistenceSelection, fixture.selection))
        window.makeKeyAndVisible()
        return HostedScreen(window: window, previousWindow: previousWindow, context: context,
                            coordinator: coordinator, fixture: fixture)
    }

    /// Waits until the fixture's rows fill several screens, which happens once the projection read publishes.
    private func rowsShown(in screen: HostedScreen) async throws -> MountedList {
        var list: UICollectionView?
        try await waitForState("rows shown", timeout: .seconds(10)) {
            list = screen.window.firstDescendant(UICollectionView.self) {
                $0.contentSize.height > 2 * $0.bounds.height && $0.bounds.height > 0
            }
            return list != nil
        }
        // `waitForState` has recorded the failure; stop this test.
        guard let collection = list else { throw RowsNotShown() }
        try await settle()
        return MountedList(collection: collection, context: screen.context,
                           coordinator: screen.coordinator, fixture: screen.fixture)
    }

    /// Removes the screen and waits until its view graph and every read it started have finished.
    /// Releasing takes 0.1–0.4 s on hosted runners, so a fixed 200 ms delay let a live screen
    /// refetch into the context during teardown and keep running into the next test (SHOPPING-275).
    /// Teardown's reset then proves nothing still reads the context.
    ///
    /// This does not wait for the context itself to be released. Once a `@FetchRequest` reports a
    /// change to one of its objects, SwiftUI keeps that request's controller, and through it the
    /// context, alive after the view is gone (iOS 18.5 and 26.5), so Catalog edits never release it
    /// (SHOPPING-276).
    private func release(_ screen: inout HostedScreen?) async throws {
        weak var hostingController: UIViewController?
        if let hosted = screen {
            hostingController = hosted.window.rootViewController
            hosted.window.isHidden = true
            hosted.window.rootViewController = nil
            hosted.previousWindow?.makeKeyAndVisible()
        }
        screen = nil
        try await waitForState("screen and its reads finished") {
            hostingController == nil && CoalescedRefresh.runningCount == 0
        }
    }

    /// A real data change may refresh the cells List has on screen; rows off screen must not
    /// rebuild. Before SHOPPING-272 every update rebuilt all rows, twice.
    private func assertOnlyOnScreenRowsRebuilt(_ rendered: [UUID], in list: MountedList, total: Int) {
        let onScreen = list.collection.visibleCells.count
        XCTAssertLessThan(onScreen, total, "The fixture must extend past the screen")
        XCTAssertLessThanOrEqual(Set(rendered).count, onScreen, "Rows off screen were rebuilt")
    }

    /// Lets the screen's deferred reads and updates finish.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    private func assertScrollingFetchesNothing(_ list: MountedList) async throws {
        let collection = list.collection
        let top = -collection.adjustedContentInset.top
        let bottom = collection.contentSize.height + collection.adjustedContentInset.bottom
            - collection.bounds.height
        list.coordinator.fetchCount = 0
        // About one frame of a fast fling, so every row is created as it scrolls in.
        let step: CGFloat = 40
        var offset = top
        var frameTimes: [Duration] = []
        while offset < bottom {
            offset = min(offset + step, bottom)
            frameTimes.append(await scrollFrame(collection, to: offset))
        }
        while offset > top {
            offset = max(offset - step, top)
            frameTimes.append(await scrollFrame(collection, to: offset))
        }
        report(frameTimes)
        XCTAssertEqual(list.coordinator.fetchCount, 0, "Scrolling fetched \(list.coordinator.fetchCount) times")
    }

    /// Returns the main-thread time this frame's scroll and layout took.
    private func scrollFrame(_ collection: UICollectionView, to offset: CGFloat) async -> Duration {
        let elapsed = ContinuousClock().measure {
            collection.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            collection.layoutIfNeeded()
        }
        await Task.yield()
        return elapsed
    }

    /// Frame timing is diagnostic only: shared simulators are too noisy to assert on.
    private func report(_ frameTimes: [Duration]) {
        let milliseconds = frameTimes.map {
            Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15
        }.sorted()
        guard let worst = milliseconds.last else { return }
        let percentile = { (p: Double) in milliseconds[min(milliseconds.count - 1, Int(Double(milliseconds.count) * p))] }
        print(String(format: "SHOPPING-272 scroll timing: %@ frames=%d p50=%.2fms p95=%.2fms max=%.2fms",
            name, milliseconds.count, percentile(0.5), percentile(0.95), worst))
    }
}

/// Counts every fetch that `@FetchRequest` or a row issues through the view context.
/// Only the main-queue view context uses it, so the counter has a single writer.
private final class FetchCountingCoordinator: NSPersistentStoreCoordinator, @unchecked Sendable {
    var fetchCount = 0

    override func execute(_ request: NSPersistentStoreRequest, with context: NSManagedObjectContext) throws -> Any {
        if request.requestType == .fetchRequestType { fetchCount += 1 }
        return try super.execute(request, with: context)
    }
}

private extension UIView {
    func firstDescendant<View: UIView>(_ type: View.Type, where matches: (View) -> Bool) -> View? {
        if let view = self as? View, matches(view) { return view }
        for subview in subviews {
            if let match = subview.firstDescendant(type, where: matches) { return match }
        }
        return nil
    }
}
