import XCTest
import CoreData
@testable import Shopping

@MainActor
final class GroceryNavigationStateTests: XCTestCase {
    func testNavigationFetchRequestRemainsEntitySafeWithTwoRetainedModels() throws {
        let firstPersistence = try PersistenceController(inMemory: true)
        let secondPersistence = try PersistenceController(inMemory: true)
        let firstService = NeedService(persistence: firstPersistence)
        let secondService = NeedService(persistence: secondPersistence)
        let firstSelection = try firstService.createHousehold(name: "First")
        let secondSelection = try secondService.createHousehold(name: "Second")
        _ = try firstService.createStore(name: "Costco", householdID: firstSelection.householdID)
        _ = try secondService.createStore(name: "Publix", householdID: secondSelection.householdID)

        let firstController = NSFetchedResultsController(
            fetchRequest: NavigationFetchRequests.stores(),
            managedObjectContext: firstPersistence.container.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        let secondController = NSFetchedResultsController(
            fetchRequest: NavigationFetchRequests.stores(),
            managedObjectContext: secondPersistence.container.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )

        XCTAssertNoThrow(try firstController.performFetch())
        XCTAssertNoThrow(try secondController.performFetch())
        XCTAssertEqual(firstController.fetchedObjects?.map { $0.name }, ["Costco"])
        XCTAssertEqual(secondController.fetchedObjects?.map { $0.name }, ["Publix"])
    }

    func testFiltersPersistPerHouseholdAndRestoreIndependently() throws {
        let suite = "GroceryNavigationStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstHousehold = UUID()
        let secondHousehold = UUID()
        let costco = UUID()
        let publix = UUID()

        let state = GroceryNavigationState(defaults: defaults, keyPrefix: "test.filter")
        state.configure(householdID: firstHousehold, activeStoreIDs: [costco, publix])
        state.selectStore(costco)
        state.setIncluded(true, storeID: publix)
        state.urgentOnly = true
        state.configure(householdID: secondHousehold, activeStoreIDs: [publix])
        XCTAssertNil(state.selectedStoreID)
        XCTAssertTrue(state.includedStoreIDs.isEmpty)

        state.configure(householdID: firstHousehold, activeStoreIDs: [costco, publix])
        XCTAssertEqual(state.selectedStoreID, costco)
        XCTAssertEqual(state.includedStoreIDs, [publix])
        XCTAssertTrue(state.urgentOnly)
    }

    func testSanitizeRemovesMissingAndArchivedStoreIDs() throws {
        let suite = "GroceryNavigationStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let household = UUID()
        let active = UUID()
        let removed = UUID()
        let state = GroceryNavigationState(defaults: defaults, keyPrefix: "test.filter")
        state.configure(householdID: household, activeStoreIDs: [active, removed])
        state.selectStore(removed)
        state.setIncluded(true, storeID: removed)
        state.setExcluded(true, storeID: active)

        state.sanitize(activeStoreIDs: [active])
        XCTAssertNil(state.selectedStoreID)
        XCTAssertTrue(state.includedStoreIDs.isEmpty)
        XCTAssertEqual(state.excludedStoreIDs, [active])

        let restored = GroceryNavigationState(defaults: defaults, keyPrefix: "test.filter")
        restored.configure(householdID: household, activeStoreIDs: [active])
        XCTAssertNil(restored.selectedStoreID)
        XCTAssertEqual(restored.excludedStoreIDs, [active])
    }

    func testIncludeAndExcludeAreMutuallyExclusiveAndCountUsefulFilters() {
        let state = GroceryNavigationState(defaults: UserDefaults(suiteName: UUID().uuidString)!, keyPrefix: "test.filter")
        let household = UUID()
        let store = UUID()
        state.configure(householdID: household, activeStoreIDs: [store])
        state.setIncluded(true, storeID: store)
        XCTAssertEqual(state.activeFilterCount, 1)
        state.setExcluded(true, storeID: store)
        XCTAssertFalse(state.includedStoreIDs.contains(store))
        XCTAssertTrue(state.excludedStoreIDs.contains(store))
        state.urgentOnly = true
        XCTAssertEqual(state.activeFilterCount, 2)
    }
    func testAddScopeKeepsPresentedStoreAndRejectsArchiveWithoutCreatingNeed() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let storeID = try service.createStore(name: "Costco", householdID: selection.householdID)
        let scope = GroceryAddScope(
            householdID: selection.householdID,
            listID: selection.listID,
            selectedStoreID: storeID,
            selectedStoreName: "Costco"
        )
        let navigation = GroceryNavigationState(defaults: UserDefaults(suiteName: UUID().uuidString)!, keyPrefix: "test.filter")
        navigation.configure(householdID: selection.householdID, activeStoreIDs: [storeID])
        navigation.selectStore(storeID)
        try service.setStoreArchived(true, storeID: storeID, householdID: selection.householdID)
        navigation.sanitize(activeStoreIDs: [])

        XCTAssertNil(navigation.selectedStoreID)
        XCTAssertEqual(scope.selectedStoreID, storeID, "The presented draft keeps its original store scope")
        XCTAssertThrowsError(try scope.addOneTime(
            title: "Milk",
            usesSelectedStore: true,
            currentSelection: PersistenceSelection(householdID: selection.householdID, listID: selection.listID),
            service: service
        )) { XCTAssertEqual($0 as? NeedServiceError, .scopeChanged) }
        XCTAssertTrue(try service.allActiveNeedIDs(householdID: selection.householdID).isEmpty)

        let anyStoreID = try scope.addOneTime(
            title: "Milk",
            usesSelectedStore: false,
            currentSelection: PersistenceSelection(householdID: selection.householdID, listID: selection.listID),
            service: service
        )
        XCTAssertEqual(try service.allActiveNeedIDs(householdID: selection.householdID), [anyStoreID])
    }

    func testAddScopeRejectsHouseholdSwitchWithoutWritingEitherList() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let first = try service.createHousehold(name: "First")
        let second = try service.createHousehold(name: "Second")
        let scope = GroceryAddScope(
            householdID: first.householdID,
            listID: first.listID,
            selectedStoreID: nil,
            selectedStoreName: nil
        )
        XCTAssertThrowsError(try scope.addOneTime(
            title: "Milk",
            usesSelectedStore: false,
            currentSelection: PersistenceSelection(householdID: second.householdID, listID: second.listID),
            service: service
        )) { XCTAssertEqual($0 as? GroceryAddError, .selectionChanged) }
        XCTAssertTrue(try service.allActiveNeedIDs(householdID: first.householdID).isEmpty)
        XCTAssertTrue(try service.allActiveNeedIDs(householdID: second.householdID).isEmpty)
    }


}
