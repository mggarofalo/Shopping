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
        let category = UUID()
        state.configure(
            householdID: firstHousehold,
            activeStoreIDs: [costco, publix],
            activeCategoryIDs: [category]
        )
        state.categoryID = category
        state.configure(householdID: secondHousehold, activeStoreIDs: [publix])
        XCTAssertNil(state.selectedStoreID)
        XCTAssertTrue(state.includedStoreIDs.isEmpty)

        state.configure(householdID: firstHousehold, activeStoreIDs: [costco, publix], activeCategoryIDs: [category])
        XCTAssertEqual(state.selectedStoreID, costco)
        XCTAssertEqual(state.includedStoreIDs, [publix])
        XCTAssertTrue(state.urgentOnly)
        XCTAssertEqual(state.categoryID, category)
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

    func testIncludeAndExcludeRemainIndependentAndExclusionWins() {
        let state = GroceryNavigationState(defaults: UserDefaults(suiteName: UUID().uuidString)!, keyPrefix: "test.filter")
        let household = UUID()
        let store = UUID()
        state.configure(householdID: household, activeStoreIDs: [store])
        state.setIncluded(true, storeID: store)
        XCTAssertEqual(state.activeFilterCount, 1)
        state.setExcluded(true, storeID: store)
        XCTAssertTrue(state.includedStoreIDs.contains(store))
        XCTAssertTrue(state.excludedStoreIDs.contains(store))
        state.urgentOnly = true
        XCTAssertEqual(state.activeFilterCount, 3)
        XCTAssertFalse(PurchaseFilter(includedStoreIDs: [store], excludedStoreIDs: [store]).matches(
            PurchaseRuleValue(explicitStoreIDs: [store], anyStore: false),
            activeStoreIDs: [store]
        ))
    }

    func testUrgencyCompositionCannotWidenSelectedStoreEligibility() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let costco = try service.createStore(name: "Costco", householdID: selection.householdID)
        let publix = try service.createStore(name: "Publix", householdID: selection.householdID)
        let item = try service.createItem(
            name: "Granola", storeIDs: [costco], householdID: selection.householdID, anyStore: false
        )
        let need = try service.addRememberedNeed(itemID: item, listID: selection.listID, urgency: .urgent)

        let before = try service.allActiveNeedIDs(householdID: selection.householdID)
        XCTAssertEqual(try service.filteredActiveNeedIDs(
            householdID: selection.householdID,
            filter: GroceryNeedFilter(
                purchase: PurchaseFilter(selectedStoreID: publix),
                urgency: NeedUrgency.urgent.rawValue
            )
        ), [])
        XCTAssertEqual(try service.filteredActiveNeedIDs(
            householdID: selection.householdID,
            filter: GroceryNeedFilter(
                purchase: PurchaseFilter(selectedStoreID: costco),
                urgency: NeedUrgency.urgent.rawValue
            )
        ), [need])
        XCTAssertEqual(try service.allActiveNeedIDs(householdID: selection.householdID), before)
    }

    func testPurchaseRuleLabelsShowLiteralActiveTagsWithoutArchivedContradictions() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let costco = try service.createStore(name: "Costco", householdID: selection.householdID)
        let closed = try service.createStore(name: "Closed Market", householdID: selection.householdID)
        let anyItem = try service.createItem(
            name: "Bananas", storeIDs: [costco], householdID: selection.householdID, anyStore: true
        )
        let rememberedAny = try service.addRememberedNeed(itemID: anyItem, listID: selection.listID)
        let oneTimeAny = try service.addOneTimeNeed(
            title: "Party cups", storeIDs: [costco], anyStore: true, listID: selection.listID
        )
        let archivedOnlyItem = try service.createItem(
            name: "Old favorite", storeIDs: [closed], householdID: selection.householdID, anyStore: false
        )
        let archivedOnly = try service.addRememberedNeed(itemID: archivedOnlyItem, listID: selection.listID)
        let mixedItem = try service.createItem(
            name: "Rice", storeIDs: [costco, closed], householdID: selection.householdID, anyStore: false
        )
        let mixed = try service.addRememberedNeed(itemID: mixedItem, listID: selection.listID)
        try service.setStoreArchived(true, storeID: closed, householdID: selection.householdID)

        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", [rememberedAny, oneTimeAny, archivedOnly, mixed])
            let needs = try context.fetch(request)
            func need(_ id: UUID) throws -> Need { try XCTUnwrap(needs.first { $0.id == id }) }
            let remembered = try need(rememberedAny)
            let oneTime = try need(oneTimeAny)
            let archived = try need(archivedOnly)
            let mixedNeed = try need(mixed)

            XCTAssertEqual(GroceryPurchaseRuleLabel.text(
                anyStore: remembered.item!.anyStore,
                stores: remembered.item!.stores ?? [],
                activeStores: Array(remembered.item!.stores ?? []).filter { !$0.isArchived }
            ), "Buy at any store · Tagged: Costco")
            XCTAssertEqual(GroceryPurchaseRuleLabel.text(
                anyStore: oneTime.oneTimeAnyStore,
                stores: oneTime.oneTimeStores ?? [],
                activeStores: Array(oneTime.oneTimeStores ?? []).filter { !$0.isArchived }
            ), "Buy at any store · Tagged: Costco")
            XCTAssertNil(GroceryPurchaseRuleLabel.text(
                anyStore: archived.item!.anyStore,
                stores: archived.item!.stores ?? [],
                activeStores: []
            ))
            XCTAssertTrue(GroceryRowScope.needsStore(archived))
            XCTAssertEqual(GroceryPurchaseRuleLabel.text(
                anyStore: mixedNeed.item!.anyStore,
                stores: mixedNeed.item!.stores ?? [],
                activeStores: Array(mixedNeed.item!.stores ?? []).filter { !$0.isArchived }
            ), "Only buy at Costco")
            XCTAssertFalse(GroceryRowScope.needsStore(mixedNeed))
        }
    }

    func testSavedFilterWithoutCategoryDecodesAndCategorySanitizesWhenRemoved() throws {
        let suite = "GroceryNavigationStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let household = UUID(), store = UUID(), category = UUID()
        let keyPrefix = "test.compatibility"
        let legacy = """
        {"selectedStoreID":null,"includedStoreIDs":["\(store.uuidString)"],"excludedStoreIDs":[],"urgentOnly":true}
        """.data(using: .utf8)!
        defaults.set(legacy, forKey: "\(keyPrefix).\(household.uuidString.lowercased())")

        let state = GroceryNavigationState(defaults: defaults, keyPrefix: keyPrefix)
        state.configure(householdID: household, activeStoreIDs: [store], activeCategoryIDs: [category])
        XCTAssertEqual(state.includedStoreIDs, [store])
        XCTAssertTrue(state.urgentOnly)
        XCTAssertNil(state.categoryID)

        state.categoryID = category
        XCTAssertEqual(state.activeFilterCount, 3)
        state.sanitize(activeStoreIDs: [store], activeCategoryIDs: [])
        XCTAssertNil(state.categoryID)
        XCTAssertEqual(state.activeFilterCount, 2)
        state.resetFilters()
        XCTAssertEqual(state.activeFilterCount, 0)
    }

    func testCanonicalProjectionRejectsDuplicateHouseholdListStoreAndNeedIdentities() throws {
        let persistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold()
        _ = try service.createStore(name: "Local", householdID: local.householdID)
        _ = try service.addOneTimeNeed(title: "Local need", listID: local.listID)
        try insertSecondaryGraph(
            householdID: local.householdID,
            listID: UUID(),
            storeID: UUID(),
            needID: UUID(),
            persistence: persistence
        )

        let context = persistence.simulationContext()
        try context.performAndWait {
            let selection = PersistenceSelection(householdID: local.householdID, listID: local.listID)
            XCTAssertNil(GroceryRowScope.canonicalList(
                try context.fetch(GroceryList.fetchRequest()),
                households: try context.fetch(Household.fetchRequest()),
                selection: selection
            ), "A duplicated household identity makes the selected graph ambiguous")
        }

        let isolated = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let isolatedService = NeedService(persistence: isolated)
        let selected = try isolatedService.createHousehold()
        let selectedStore = try isolatedService.createStore(name: "Selected", householdID: selected.householdID)
        let selectedNeed = try isolatedService.addOneTimeNeed(
            title: "Selected need", storeIDs: [selectedStore], anyStore: false, listID: selected.listID
        )
        try insertSecondaryGraph(
            householdID: UUID(),
            listID: UUID(),
            storeID: selectedStore,
            needID: selectedNeed,
            persistence: isolated
        )
        let isolatedContext = isolated.simulationContext()
        try isolatedContext.performAndWait {
            let list = try XCTUnwrap(GroceryRowScope.canonicalList(
                try isolatedContext.fetch(GroceryList.fetchRequest()),
                households: try isolatedContext.fetch(Household.fetchRequest()),
                selection: PersistenceSelection(householdID: selected.householdID, listID: selected.listID)
            ))
            let activeStores = GroceryRowScope.validStores(
                try isolatedContext.fetch(Store.fetchRequest()), canonicalList: list
            ).filter { !$0.isArchived }
            XCTAssertTrue(activeStores.isEmpty, "A duplicate Store UUID must not expose either row")
            XCTAssertTrue(GroceryRowScope.validNeeds(
                try isolatedContext.fetch(Need.fetchRequest()), canonicalList: list
            ).isEmpty, "A duplicate occurrence UUID must not alias a selected-list row")
            let localNeed = try XCTUnwrap(
                list.needs?.first(where: { $0.objectID.persistentStore == list.objectID.persistentStore })
            )
            XCTAssertTrue(GroceryRowScope.needsStore(localNeed, activeStores: activeStores))
            XCTAssertNil(GroceryPurchaseRuleLabel.text(
                anyStore: localNeed.oneTimeAnyStore,
                stores: localNeed.oneTimeStores ?? [],
                activeStores: activeStores
            ))
        }
    }

    func testDuplicateForeignCategoryIdentityGroupsOwnUrgentNeedAsUncategorizedWithoutMutation() throws {
        let persistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let categoryID = try service.createCategory(name: "Produce", householdID: selection.householdID)
        let itemID = try service.createItem(
            name: "Apples", categoryID: categoryID, householdID: selection.householdID
        )
        let needID = try service.addRememberedNeed(
            itemID: itemID,
            listID: selection.listID,
            quantity: 4,
            notes: "Honeycrisp",
            urgency: .urgent
        )
        try insertSecondaryCategory(id: categoryID, persistence: persistence)

        let context = persistence.simulationContext()
        try context.performAndWait {
            let list = try XCTUnwrap(GroceryRowScope.canonicalList(
                try context.fetch(GroceryList.fetchRequest()),
                households: try context.fetch(Household.fetchRequest()),
                selection: PersistenceSelection(
                    householdID: selection.householdID,
                    listID: selection.listID
                )
            ))
            let categories = GroceryRowScope.validCategories(
                try context.fetch(Shopping.Category.fetchRequest()),
                canonicalList: list
            )
            XCTAssertTrue(categories.isEmpty, "A globally duplicated category UUID cannot identify either row")
            let needRequest = Need.fetchRequest()
            needRequest.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let need = try XCTUnwrap(context.fetch(needRequest).first)
            let groups = CategoryGrouping.groups(
                needs: [need],
                categories: categories,
                household: list.household
            )

            XCTAssertEqual(groups.map(\.urgency), [.urgent])
            XCTAssertEqual(groups[0].categories.map(\.title), ["Uncategorized"])
            XCTAssertEqual(groups[0].categories[0].needs.map(\.id), [needID])
            XCTAssertEqual(need.quantity, 4)
            XCTAssertEqual(need.notes, "Honeycrisp")
            XCTAssertEqual(need.urgency, NeedUrgency.urgent.rawValue)
            XCTAssertEqual(need.item?.category?.id, categoryID, "Presentation grouping must not mutate the relationship")
        }
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

    private func insertSecondaryGraph(
        householdID: UUID,
        listID: UUID,
        storeID: UUID,
        needID: UUID,
        persistence: PersistenceController
    ) throws {
        let secondary = try XCTUnwrap(persistence.container.persistentStoreCoordinator.persistentStores.last)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let household = NSEntityDescription.insertNewObject(forEntityName: "Household", into: context) as! Household
            household.id = householdID
            household.name = "Imported"
            context.assign(household, to: secondary)
            let list = NSEntityDescription.insertNewObject(forEntityName: "GroceryList", into: context) as! GroceryList
            list.id = listID
            context.assign(list, to: secondary)
            list.household = household
            let store = NSEntityDescription.insertNewObject(forEntityName: "Store", into: context) as! Store
            store.id = storeID
            store.name = "Imported store"
            store.displayOrder = 0
            store.isArchived = false
            context.assign(store, to: secondary)
            store.household = household
            let need = NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as! Need
            need.id = needID
            need.kind = NeedKind.oneTime.rawValue
            need.title = "Imported need"
            need.notes = ""
            need.quantity = 1
            need.carted = false
            need.urgency = NeedUrgency.normal.rawValue
            need.revision = 0
            need.archived = false
            need.oneTimeAnyStore = true
            context.assign(need, to: secondary)
            need.list = list
            try context.save()
        }
    }

    private func insertSecondaryCategory(id: UUID, persistence: PersistenceController) throws {
        let secondary = try XCTUnwrap(persistence.container.persistentStoreCoordinator.persistentStores.last)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let household = NSEntityDescription.insertNewObject(forEntityName: "Household", into: context) as! Household
            household.id = UUID()
            household.name = "Foreign"
            context.assign(household, to: secondary)
            let list = NSEntityDescription.insertNewObject(forEntityName: "GroceryList", into: context) as! GroceryList
            list.id = UUID()
            context.assign(list, to: secondary)
            list.household = household
            let category = NSEntityDescription.insertNewObject(forEntityName: "Category", into: context) as! Shopping.Category
            category.id = id
            category.name = "Foreign duplicate"
            category.displayOrder = 0
            context.assign(category, to: secondary)
            category.household = household
            try context.save()
        }
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingNavigationTests-\(UUID().uuidString).sqlite")
    }


}
