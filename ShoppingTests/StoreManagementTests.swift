import CoreData
import XCTest

@testable import Shopping

final class StoreManagementTests: XCTestCase {
    func testSettingsScopeRequiresGloballyCanonicalHouseholdListAndStoreIdentities() throws {
        let persistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold(name: "Local")
        let localStore = try service.createStore(
            name: "Local store", householdID: local.householdID)

        XCTAssertEqual(
            try settingsScopeState(local, persistence: persistence),
            SettingsScopeState(householdAvailable: true, storeIDs: [localStore])
        )

        try insertDuplicateHouseholdGraphInSecondary(
            householdID: local.householdID, listID: UUID(), stores: [(UUID(), "Foreign")],
            persistence: persistence
        )
        XCTAssertEqual(
            try settingsScopeState(local, persistence: persistence),
            SettingsScopeState(householdAvailable: false, storeIDs: [])
        )

        let duplicateListPersistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let duplicateListService = NeedService(persistence: duplicateListPersistence)
        let duplicateListLocal = try duplicateListService.createHousehold(name: "Local")
        _ = try duplicateListService.createStore(
            name: "Local store", householdID: duplicateListLocal.householdID)
        try insertDuplicateHouseholdGraphInSecondary(
            householdID: UUID(), listID: duplicateListLocal.listID, stores: [(UUID(), "Foreign")],
            persistence: duplicateListPersistence
        )
        XCTAssertEqual(
            try settingsScopeState(duplicateListLocal, persistence: duplicateListPersistence),
            SettingsScopeState(householdAvailable: false, storeIDs: [])
        )

        let duplicateStorePersistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let duplicateStoreService = NeedService(persistence: duplicateStorePersistence)
        let duplicateStoreLocal = try duplicateStoreService.createHousehold(name: "Local")
        let duplicateStoreID = try duplicateStoreService.createStore(
            name: "Local store", householdID: duplicateStoreLocal.householdID
        )
        try insertDuplicateHouseholdGraphInSecondary(
            householdID: UUID(), listID: UUID(),
            stores: [(duplicateStoreID, "Globally duplicated store")],
            persistence: duplicateStorePersistence
        )
        XCTAssertEqual(
            try settingsScopeState(duplicateStoreLocal, persistence: duplicateStorePersistence),
            SettingsScopeState(householdAvailable: true, storeIDs: [])
        )
    }

    func testSettingsScopeDoesNotAdoptHouseholdGraphFromAnotherPersistentStore() throws {
        let persistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold(name: "Local")
        let localStore = try service.createStore(name: "Local", householdID: local.householdID)
        try insertDuplicateHouseholdGraphInSecondary(
            householdID: UUID(), listID: UUID(), stores: [(UUID(), "Secondary")],
            persistence: persistence
        )

        XCTAssertEqual(
            try settingsScopeState(local, persistence: persistence),
            SettingsScopeState(householdAvailable: true, storeIDs: [localStore])
        )
    }

    func testStagedSettingsCommandRemainsBoundToOriginalCanonicalObjects() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let first = try service.createHousehold(name: "First")
        let second = try service.createHousehold(name: "Second")
        let context = persistence.simulationContext()
        try context.performAndWait {
            let lists = try context.fetch(PurchaseRulesStoreScope.listsRequest())
            let households = try context.fetch(NavigationFetchRequests.households())
            let original = StoreManagementScope.canonicalList(
                lists: lists, households: households,
                selection: PersistenceSelection(
                    householdID: first.householdID, listID: first.listID)
            )
            let staged = try XCTUnwrap(StoreManagementCommandScope(canonicalList: original))
            XCTAssertTrue(StoreManagementScope.permits(staged, canonicalList: original))

            let retargeted = StoreManagementScope.canonicalList(
                lists: lists, households: households,
                selection: PersistenceSelection(
                    householdID: second.householdID, listID: second.listID)
            )
            XCTAssertFalse(StoreManagementScope.permits(staged, canonicalList: retargeted))
            XCTAssertEqual(staged.householdID, first.householdID)
            XCTAssertEqual(staged.listID, first.listID)
        }
    }

    func testScopedStoreWritersRejectDuplicateListImportedAfterStaleUISnapshot() throws {
        let persistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold(name: "Local")
        let first = try service.createStore(
            name: "First", householdID: selection.householdID, displayOrder: 0)
        let second = try service.createStore(
            name: "Second", householdID: selection.householdID, displayOrder: 1)

        let staleUIContext = persistence.simulationContext()
        let staleSnapshot = try staleUIContext.performAndWait {
            let lists = try staleUIContext.fetch(PurchaseRulesStoreScope.listsRequest())
            let households = try staleUIContext.fetch(NavigationFetchRequests.households())
            let canonicalList = StoreManagementScope.canonicalList(
                lists: lists, households: households,
                selection: PersistenceSelection(
                    householdID: selection.householdID, listID: selection.listID
                )
            )
            return (
                scope: try XCTUnwrap(StoreManagementCommandScope(canonicalList: canonicalList)),
                list: try XCTUnwrap(canonicalList)
            )
        }
        let before = try writerRaceState(selection.householdID, persistence: persistence)

        try insertDuplicateHouseholdGraphInSecondary(
            householdID: UUID(), listID: selection.listID, stores: [], persistence: persistence
        )
        XCTAssertTrue(
            staleUIContext.performAndWait {
                return StoreManagementScope.permits(
                    staleSnapshot.scope, canonicalList: staleSnapshot.list
                )
            },
            "The retained UI snapshot deliberately remains stale after the import"
        )

        assertError(.scopeChanged) {
            try service.createStore(
                name: "Must not exist", householdID: selection.householdID,
                listID: selection.listID)
        }
        assertError(.scopeChanged) {
            try service.renameStore(
                name: "Must not rename", storeID: first, householdID: selection.householdID,
                listID: selection.listID)
        }
        assertError(.scopeChanged) {
            try service.setStoreArchived(
                true, storeID: first, householdID: selection.householdID,
                listID: selection.listID)
        }
        assertError(.scopeChanged) {
            try service.reorderStores(
                [second, first], householdID: selection.householdID, listID: selection.listID)
        }
        XCTAssertEqual(try writerRaceState(selection.householdID, persistence: persistence), before)
    }

    func testPurchaseRuleStoreScopeUsesCanonicalListGraphAcrossPersistentStores() throws {
        let persistence = try PersistenceController(
            storeURL: temporaryStoreURL(),
            additionalStoreURLs: [temporaryStoreURL()]
        )
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold(name: "Local")
        let localStoreID = try service.createStore(
            name: "Local store", householdID: local.householdID)
        let foreignStoreID = UUID()
        try insertDuplicateHouseholdGraphInSecondary(
            householdID: local.householdID,
            listID: UUID(),
            stores: [(foreignStoreID, "Foreign unique")],
            persistence: persistence
        )

        var visible = try scopedStoreIDs(
            householdID: local.householdID, listID: local.listID, persistence: persistence
        )
        XCTAssertEqual(
            visible, [localStoreID],
            "A duplicated household UUID must not widen the canonical list graph")

        try insertStoreInSecondaryHousehold(
            id: localStoreID,
            name: "Foreign duplicate store ID",
            householdID: local.householdID,
            persistence: persistence
        )
        visible = try scopedStoreIDs(
            householdID: local.householdID, listID: local.listID, persistence: persistence
        )
        XCTAssertEqual(
            visible, [], "A globally duplicated Store identity must not expose either candidate")

        let duplicateListPersistence = try PersistenceController(
            storeURL: temporaryStoreURL(),
            additionalStoreURLs: [temporaryStoreURL()]
        )
        let duplicateListService = NeedService(persistence: duplicateListPersistence)
        let duplicateListLocal = try duplicateListService.createHousehold(name: "Local")
        _ = try duplicateListService.createStore(
            name: "Local store",
            householdID: duplicateListLocal.householdID
        )
        try insertDuplicateHouseholdGraphInSecondary(
            householdID: UUID(),
            listID: duplicateListLocal.listID,
            stores: [(UUID(), "Foreign store")],
            persistence: duplicateListPersistence
        )
        XCTAssertEqual(
            try scopedStoreIDs(
                householdID: duplicateListLocal.householdID,
                listID: duplicateListLocal.listID,
                persistence: duplicateListPersistence
            ),
            [],
            "A list UUID duplicated anywhere in the container is ambiguous even when the other household UUID differs"
        )
    }

    func testNavigationFetchRequestsUseUUIDTieBreakersOnEveryFetch() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let storeA = try service.createStore(
            name: "Later inserted", householdID: selection.householdID, displayOrder: 4)
        let storeB = try service.createStore(
            name: "Earlier UUID", householdID: selection.householdID, displayOrder: 4)
        let categoryA = try service.createCategory(
            name: "Later inserted", householdID: selection.householdID, displayOrder: 9)
        let categoryB = try service.createCategory(
            name: "Earlier UUID", householdID: selection.householdID, displayOrder: 9)
        try replaceIDs(
            [(storeA, secondID), (storeB, firstID)], entityName: "Store", persistence: persistence)
        try replaceIDs(
            [(categoryA, secondID), (categoryB, firstID)], entityName: "Category",
            persistence: persistence)

        let context = persistence.simulationContext()
        for _ in 0..<2 {
            let storeIDs = try context.performAndWait {
                try context.fetch(NavigationFetchRequests.stores()).map(\.id)
            }
            let categoryIDs = try context.performAndWait {
                try context.fetch(NavigationFetchRequests.categories()).map(\.id)
            }
            XCTAssertEqual(storeIDs, [firstID, secondID])
            XCTAssertEqual(categoryIDs, [firstID, secondID])
            context.performAndWait { context.reset() }
        }
    }

    func testNeedsStoreRejectsUnsetAndForeignStoreTagsForRememberedAndOneTimeNeeds() throws {
        for badTag in [BadTag.unsetID, .foreignHousehold] {
            let persistence = try makePersistence()
            let service = NeedService(persistence: persistence)
            let local = try service.createHousehold(name: "Local")
            let itemID = try service.createItem(name: "Granola", householdID: local.householdID)
            let rememberedID = try service.addRememberedNeed(itemID: itemID, listID: local.listID)
            let oneTimeID = try service.addOneTimeNeed(title: "Ice", listID: local.listID)
            try attachBadTag(
                badTag,
                householdID: local.householdID,
                itemID: itemID,
                rememberedID: rememberedID,
                oneTimeID: oneTimeID,
                service: service,
                persistence: persistence
            )

            let context = persistence.simulationContext()
            let results = try context.performAndWait { () -> (Bool, Bool) in
                let request = Need.fetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", [rememberedID, oneTimeID])
                let needs = try context.fetch(request)
                let remembered = try XCTUnwrap(needs.first { $0.id == rememberedID })
                let oneTime = try XCTUnwrap(needs.first { $0.id == oneTimeID })
                return (GroceryRowScope.needsStore(remembered), GroceryRowScope.needsStore(oneTime))
            }
            XCTAssertTrue(results.0, "Remembered tag must not gain eligibility from \(badTag)")
            XCTAssertTrue(results.1, "One-time tag must not gain eligibility from \(badTag)")
            XCTAssertEqual(try service.storeEligibility(itemID: itemID), .needsStore)
        }
    }

    func testRenameTrimsAndRejectedNamesOrForeignScopeLeaveStoreUnchanged() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold(name: "Local")
        let foreign = try service.createHousehold(name: "Foreign")
        let storeID = try service.createStore(name: "  Costco \n", householdID: local.householdID)
        XCTAssertEqual(try storeState(storeID, persistence: persistence).name, "Costco")

        try service.renameStore(
            name: "  Costco Wholesale  ", storeID: storeID, householdID: local.householdID)
        XCTAssertEqual(try storeState(storeID, persistence: persistence).name, "Costco Wholesale")

        XCTAssertThrowsError(
            try service.renameStore(name: " \n ", storeID: storeID, householdID: local.householdID)
        ) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidName)
        }
        XCTAssertThrowsError(
            try service.renameStore(
                name: "Wrong", storeID: storeID, householdID: foreign.householdID)
        ) {
            XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
        }
        XCTAssertEqual(try storeState(storeID, persistence: persistence).name, "Costco Wholesale")
    }

    func testReorderRequiresExactUniqueFullSetAndRollsBackEveryInvalidBatch() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold()
        let foreign = try service.createHousehold()
        let aldi = try service.createStore(name: "Aldi", householdID: local.householdID)
        let costco = try service.createStore(name: "Costco", householdID: local.householdID)
        let publix = try service.createStore(name: "Publix", householdID: local.householdID)
        let foreignStore = try service.createStore(
            name: "Foreign", householdID: foreign.householdID)

        try service.reorderStores([publix, aldi, costco], householdID: local.householdID)
        let expected = [publix, aldi, costco]
        XCTAssertEqual(try orderedStoreIDs(local.householdID, persistence: persistence), expected)

        for invalid in [
            [publix, aldi], [publix, aldi, aldi], [publix, aldi, UUID()],
            [publix, aldi, foreignStore],
        ] {
            XCTAssertThrowsError(try service.reorderStores(invalid, householdID: local.householdID))
            {
                XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
            }
            XCTAssertEqual(
                try orderedStoreIDs(local.householdID, persistence: persistence), expected)
        }
    }

    func testReorderRejectsZeroAndImportedDuplicateStoreIdentitiesWithoutMutation() throws {
        for importedID in [PersistenceModel.unsetID, UUID()] {
            let persistence = try makePersistence()
            let service = NeedService(persistence: persistence)
            let selection = try service.createHousehold()
            let valid = try service.createStore(
                name: "Valid", householdID: selection.householdID, displayOrder: 7)
            try insertImportedStore(
                id: importedID,
                name: "Imported A",
                householdID: selection.householdID,
                displayOrder: 8,
                persistence: persistence
            )
            if importedID != PersistenceModel.unsetID {
                try insertImportedStore(
                    id: importedID,
                    name: "Imported B",
                    householdID: selection.householdID,
                    displayOrder: 9,
                    persistence: persistence
                )
            }

            let before = try allStoreStates(selection.householdID, persistence: persistence)
            let requested =
                importedID == PersistenceModel.unsetID
                ? [valid, importedID] : [valid, importedID, importedID]
            XCTAssertThrowsError(
                try service.reorderStores(requested, householdID: selection.householdID)
            ) {
                XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
            }
            XCTAssertEqual(
                try allStoreStates(selection.householdID, persistence: persistence), before)
        }
    }

    func testReorderUsesOnlyVisibleActiveStoresAfterArchive() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let aldi = try service.createStore(
            name: "Aldi", householdID: selection.householdID, displayOrder: 0)
        let closed = try service.createStore(
            name: "Closed", householdID: selection.householdID, displayOrder: 1)
        let costco = try service.createStore(
            name: "Costco", householdID: selection.householdID, displayOrder: 2)

        try service.setStoreArchived(
            true, storeID: closed, householdID: selection.householdID, listID: selection.listID)
        try service.reorderStores(
            [costco, aldi], householdID: selection.householdID, listID: selection.listID)

        XCTAssertEqual(
            try activeOrderedStoreIDs(selection.householdID, persistence: persistence),
            [costco, aldi]
        )
        XCTAssertTrue(try storeIsArchived(closed, persistence: persistence))
        assertError(.scopeChanged) {
            try service.reorderStores(
                [costco, aldi, closed], householdID: selection.householdID, listID: selection.listID)
        }
    }

    func testStoreCommandsRejectStoreFromAnotherPersistentStore() throws {
        let primaryURL = temporaryStoreURL()
        let secondaryURL = temporaryStoreURL()
        let persistence = try PersistenceController(
            storeURL: primaryURL, additionalStoreURLs: [secondaryURL])
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold()
        let localStore = try service.createStore(name: "Local", householdID: local.householdID)
        let foreign = try insertHouseholdAndStoreInSecondary(persistence: persistence)

        XCTAssertThrowsError(
            try service.renameStore(
                name: "Moved", storeID: foreign.storeID, householdID: local.householdID)
        ) {
            XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
        }
        XCTAssertThrowsError(
            try service.reorderStores([foreign.storeID], householdID: local.householdID)
        ) {
            XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
        }
        XCTAssertEqual(
            try orderedStoreIDs(local.householdID, persistence: persistence), [localStore])
        XCTAssertEqual(try storeState(foreign.storeID, persistence: persistence).name, "Secondary")
    }

    func testArchiveAndRestoreRetainCatalogAndOneTimeMembershipsAndNeeds() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let storeID = try service.createStore(name: "Costco", householdID: selection.householdID)
        let itemID = try service.createItem(
            name: "Granola",
            storeIDs: [storeID],
            householdID: selection.householdID,
            anyStore: false
        )
        let rememberedNeedID = try service.addRememberedNeed(
            itemID: itemID, listID: selection.listID)
        let oneTimeNeedID = try service.addOneTimeNeed(
            title: "Party ice",
            storeIDs: [storeID],
            anyStore: false,
            listID: selection.listID
        )

        try service.setStoreArchived(true, storeID: storeID, householdID: selection.householdID)
        XCTAssertEqual(try service.storeEligibility(itemID: itemID), .needsStore)
        var snapshot = try membershipSnapshot(
            itemID: itemID, oneTimeNeedID: oneTimeNeedID, persistence: persistence)
        XCTAssertEqual(snapshot.itemStoreIDs, [storeID])
        XCTAssertEqual(snapshot.oneTimeStoreIDs, [storeID])
        XCTAssertEqual(snapshot.activeNeedIDs, [rememberedNeedID, oneTimeNeedID])
        XCTAssertTrue(snapshot.storeArchived)

        try service.setStoreArchived(false, storeID: storeID, householdID: selection.householdID)
        XCTAssertEqual(try service.storeEligibility(itemID: itemID), .activeStores([storeID]))
        snapshot = try membershipSnapshot(
            itemID: itemID, oneTimeNeedID: oneTimeNeedID, persistence: persistence)
        XCTAssertEqual(snapshot.itemStoreIDs, [storeID])
        XCTAssertEqual(snapshot.oneTimeStoreIDs, [storeID])
        XCTAssertEqual(snapshot.activeNeedIDs, [rememberedNeedID, oneTimeNeedID])
        XCTAssertFalse(snapshot.storeArchived)
    }

    func testRemoveStoreDeletesOnlyUnreferencedAndArchivesReferencedTags() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let unreferenced = try service.createStore(name: "Unused", householdID: selection.householdID)
        let fallback = try service.createStore(name: "Fallback", householdID: selection.householdID)
        let referenced = try service.createStore(name: "Referenced", householdID: selection.householdID)
        let foreign = try service.createHousehold(name: "Foreign")
        let foreignStore = try service.createStore(name: "Foreign store", householdID: foreign.householdID)
        let itemID = try service.createItem(
            name: "Tea", storeIDs: [referenced], householdID: selection.householdID, anyStore: false)
        let oneTimeNeedID = try service.addOneTimeNeed(
            title: "Ice", storeIDs: [referenced], anyStore: false, listID: selection.listID)

        XCTAssertEqual(
            try service.storeRemovalAction(
                storeID: unreferenced, householdID: selection.householdID, listID: selection.listID),
            .delete
        )
        XCTAssertEqual(
            try service.removeStore(
                storeID: unreferenced, householdID: selection.householdID, listID: selection.listID),
            .delete
        )
        XCTAssertFalse(try hasStore(unreferenced, persistence: persistence))

        XCTAssertEqual(
            try service.storeRemovalAction(
                storeID: fallback, householdID: selection.householdID, listID: selection.listID),
            .delete
        )
        _ = try service.createItem(
            name: "Added after confirmation", storeIDs: [fallback],
            householdID: selection.householdID, anyStore: false)
        XCTAssertEqual(
            try service.removeStore(
                storeID: fallback, householdID: selection.householdID, listID: selection.listID),
            .archive
        )
        XCTAssertTrue(try hasStore(fallback, persistence: persistence))
        XCTAssertTrue(try storeIsArchived(fallback, persistence: persistence))

        XCTAssertEqual(
            try service.storeRemovalAction(
                storeID: referenced, householdID: selection.householdID, listID: selection.listID),
            .archive
        )
        XCTAssertEqual(
            try service.removeStore(
                storeID: referenced, householdID: selection.householdID, listID: selection.listID),
            .archive
        )
        XCTAssertEqual(try service.storeEligibility(itemID: itemID), .needsStore)
        let snapshot = try membershipSnapshot(
            itemID: itemID, oneTimeNeedID: oneTimeNeedID, persistence: persistence)
        XCTAssertEqual(snapshot.itemStoreIDs, [referenced])
        XCTAssertEqual(snapshot.oneTimeStoreIDs, [referenced])
        XCTAssertTrue(snapshot.storeArchived)

        XCTAssertThrowsError(
            try service.removeStore(
                storeID: foreignStore, householdID: selection.householdID, listID: selection.listID)
        ) { XCTAssertEqual($0 as? NeedServiceError, .scopeChanged) }
        XCTAssertTrue(try hasStore(foreignStore, persistence: persistence))

        let context = persistence.simulationContext()
        try context.performAndWait {
            let lists = try context.fetch(PurchaseRulesStoreScope.listsRequest())
            let households = try context.fetch(NavigationFetchRequests.households())
            let stores = try context.fetch(NavigationFetchRequests.stores())
            let list = try XCTUnwrap(StoreManagementScope.canonicalList(
                lists: lists, households: households,
                selection: PersistenceSelection(
                    householdID: selection.householdID, listID: selection.listID)
            ))
            XCTAssertTrue(StoreManagementScope.activeStores(stores, canonicalList: list).isEmpty)
        }
    }

    func testConfirmedArchiveNeverBecomesDeleteWhenReferencesDisappear() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let storeID = try service.createStore(
            name: "Costco", householdID: selection.householdID)
        let itemID = try service.createItem(
            name: "Strawberries",
            storeIDs: [storeID],
            householdID: selection.householdID,
            anyStore: false
        )

        let confirmedAction = try service.storeRemovalAction(
            storeID: storeID,
            householdID: selection.householdID,
            listID: selection.listID
        )
        XCTAssertEqual(confirmedAction, .archive)

        try service.setPurchaseRules(itemID: itemID, anyStore: true, storeIDs: [])
        XCTAssertEqual(
            try service.removeStore(
                storeID: storeID,
                householdID: selection.householdID,
                listID: selection.listID,
                confirmedAction: confirmedAction
            ),
            .archive
        )
        XCTAssertTrue(try hasStore(storeID, persistence: persistence))
        XCTAssertTrue(try storeIsArchived(storeID, persistence: persistence))
    }

    private struct StoreState: Equatable {
        let id: UUID
        let name: String
        let displayOrder: Int64
    }

    private struct WriterRaceState: Equatable {
        let ids: Set<UUID>
        let namesByID: [UUID: String]
        let archivedByID: [UUID: Bool]
        let displayOrderByID: [UUID: Int64]
    }

    private struct SettingsScopeState: Equatable {
        let householdAvailable: Bool
        let storeIDs: [UUID]
    }

    private enum BadTag: CustomStringConvertible {
        case unsetID
        case foreignHousehold

        var description: String {
            switch self {
            case .unsetID: return "unset store ID"
            case .foreignHousehold: return "foreign household store"
            }
        }
    }

    private struct MembershipSnapshot {
        let itemStoreIDs: Set<UUID>
        let oneTimeStoreIDs: Set<UUID>
        let activeNeedIDs: Set<UUID>
        let storeArchived: Bool
    }

    private func makePersistence() throws -> PersistenceController {
        try PersistenceController(storeURL: temporaryStoreURL())
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingStoreManagementTests-\(UUID().uuidString).sqlite")
    }

    private func storeState(_ id: UUID, persistence: PersistenceController) throws -> StoreState {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Store.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let store = try XCTUnwrap(context.fetch(request).first)
            return StoreState(id: store.id, name: store.name, displayOrder: store.displayOrder)
        }
    }

    private func hasStore(_ id: UUID, persistence: PersistenceController) throws -> Bool {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Store.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return try !context.fetch(request).isEmpty
        }
    }

    private func writerRaceState(
        _ householdID: UUID,
        persistence: PersistenceController
    ) throws -> WriterRaceState {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Store.fetchRequest()
            request.predicate = NSPredicate(format: "household.id == %@", householdID as CVarArg)
            let stores = try context.fetch(request)
            return WriterRaceState(
                ids: Set(stores.map(\.id)),
                namesByID: Dictionary(uniqueKeysWithValues: stores.map { ($0.id, $0.name) }),
                archivedByID: Dictionary(
                    uniqueKeysWithValues: stores.map { ($0.id, $0.isArchived) }),
                displayOrderByID: Dictionary(
                    uniqueKeysWithValues: stores.map { ($0.id, $0.displayOrder) }
                )
            )
        }
    }

    private func assertError<T>(_ expected: NeedServiceError, _ body: () throws -> T) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? NeedServiceError, expected) }
    }

    private func orderedStoreIDs(_ householdID: UUID, persistence: PersistenceController) throws
        -> [UUID]
    {
        try allStoreStates(householdID, persistence: persistence)
            .sorted {
                $0.displayOrder == $1.displayOrder
                    ? $0.id.uuidString < $1.id.uuidString : $0.displayOrder < $1.displayOrder
            }
            .map(\.id)
    }

    private func allStoreStates(_ householdID: UUID, persistence: PersistenceController) throws
        -> [StoreState]
    {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Store.fetchRequest()
            request.predicate = NSPredicate(format: "household.id == %@", householdID as CVarArg)
            return try context.fetch(request).map {
                StoreState(id: $0.id, name: $0.name, displayOrder: $0.displayOrder)
            }
        }
    }

    private func activeOrderedStoreIDs(_ householdID: UUID, persistence: PersistenceController) throws
        -> [UUID]
    {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Store.fetchRequest()
            request.predicate = NSPredicate(format: "household.id == %@ AND isArchived == NO", householdID as CVarArg)
            return try context.fetch(request)
                .sorted {
                    $0.displayOrder == $1.displayOrder
                        ? $0.id.uuidString < $1.id.uuidString : $0.displayOrder < $1.displayOrder
                }
                .map(\.id)
        }
    }

    private func storeIsArchived(_ id: UUID, persistence: PersistenceController) throws -> Bool {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Store.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return try XCTUnwrap(context.fetch(request).first).isArchived
        }
    }

    private func insertImportedStore(
        id: UUID,
        name: String,
        householdID: UUID,
        displayOrder: Int64,
        persistence: PersistenceController
    ) throws {
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Household.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", householdID as CVarArg)
            let household = try XCTUnwrap(context.fetch(request).first)
            let store =
                NSEntityDescription.insertNewObject(forEntityName: "Store", into: context) as! Store
            store.id = id
            store.name = name
            store.displayOrder = displayOrder
            store.isArchived = false
            store.household = household
            try context.save()
        }
    }

    private func replaceIDs(
        _ replacements: [(UUID, UUID)],
        entityName: String,
        persistence: PersistenceController
    ) throws {
        let context = persistence.simulationContext()
        try context.performAndWait {
            for (oldID, newID) in replacements {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.predicate = NSPredicate(format: "id == %@", oldID as CVarArg)
                try XCTUnwrap(context.fetch(request).first).setValue(newID, forKey: "id")
            }
            try context.save()
        }
    }

    private func attachBadTag(
        _ badTag: BadTag,
        householdID: UUID,
        itemID: UUID,
        rememberedID: UUID,
        oneTimeID: UUID,
        service: NeedService,
        persistence: PersistenceController
    ) throws {
        let tagID: UUID
        switch badTag {
        case .unsetID:
            try insertImportedStore(
                id: PersistenceModel.unsetID,
                name: "Incomplete",
                householdID: householdID,
                displayOrder: 0,
                persistence: persistence
            )
            tagID = PersistenceModel.unsetID
        case .foreignHousehold:
            let foreign = try service.createHousehold(name: "Foreign")
            tagID = try service.createStore(name: "Foreign store", householdID: foreign.householdID)
        }

        let context = persistence.simulationContext()
        try context.performAndWait {
            let storeRequest = Store.fetchRequest()
            storeRequest.predicate = NSPredicate(format: "id == %@", tagID as CVarArg)
            let store = try XCTUnwrap(context.fetch(storeRequest).first)
            let itemRequest = Item.fetchRequest()
            itemRequest.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            let item = try XCTUnwrap(context.fetch(itemRequest).first)
            item.anyStore = false
            item.stores = [store]
            let needRequest = Need.fetchRequest()
            needRequest.predicate = NSPredicate(format: "id IN %@", [rememberedID, oneTimeID])
            let needs = try context.fetch(needRequest)
            let oneTime = try XCTUnwrap(needs.first { $0.id == oneTimeID })
            oneTime.oneTimeAnyStore = false
            oneTime.oneTimeStores = [store]
            try context.save()
        }
    }

    private func insertHouseholdAndStoreInSecondary(
        persistence: PersistenceController
    ) throws -> (householdID: UUID, storeID: UUID) {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let secondary = try XCTUnwrap(
                persistence.container.persistentStoreCoordinator.persistentStores.last)
            let household =
                NSEntityDescription.insertNewObject(forEntityName: "Household", into: context)
                as! Household
            let householdID = UUID()
            household.id = householdID
            household.name = "Secondary household"
            context.assign(household, to: secondary)
            let store =
                NSEntityDescription.insertNewObject(forEntityName: "Store", into: context) as! Store
            let storeID = UUID()
            store.id = storeID
            store.name = "Secondary"
            store.displayOrder = 0
            store.isArchived = false
            context.assign(store, to: secondary)
            store.household = household
            try context.save()
            return (householdID, storeID)
        }
    }

    private func insertDuplicateHouseholdGraphInSecondary(
        householdID: UUID,
        listID: UUID,
        stores: [(UUID, String)],
        persistence: PersistenceController
    ) throws {
        let secondary = try XCTUnwrap(
            persistence.container.persistentStoreCoordinator.persistentStores.last)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let household =
                NSEntityDescription.insertNewObject(forEntityName: "Household", into: context)
                as! Household
            household.id = householdID
            household.name = "Imported duplicate"
            context.assign(household, to: secondary)
            let list =
                NSEntityDescription.insertNewObject(forEntityName: "GroceryList", into: context)
                as! GroceryList
            list.id = listID
            context.assign(list, to: secondary)
            list.household = household
            for (id, name) in stores {
                let store =
                    NSEntityDescription.insertNewObject(forEntityName: "Store", into: context)
                    as! Store
                store.id = id
                store.name = name
                store.displayOrder = 0
                store.isArchived = false
                context.assign(store, to: secondary)
                store.household = household
            }
            try context.save()
        }
    }

    private func insertStoreInSecondaryHousehold(
        id: UUID,
        name: String,
        householdID: UUID,
        persistence: PersistenceController
    ) throws {
        let secondary = try XCTUnwrap(
            persistence.container.persistentStoreCoordinator.persistentStores.last)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Household.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", householdID as CVarArg)
            let households = try context.fetch(request)
            let household = try XCTUnwrap(
                households.first { $0.objectID.persistentStore == secondary })
            let store =
                NSEntityDescription.insertNewObject(forEntityName: "Store", into: context) as! Store
            store.id = id
            store.name = name
            store.displayOrder = 1
            store.isArchived = false
            context.assign(store, to: secondary)
            store.household = household
            try context.save()
        }
    }

    private func scopedStoreIDs(
        householdID: UUID,
        listID: UUID,
        persistence: PersistenceController
    ) throws -> [UUID] {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let stores = try context.fetch(NavigationFetchRequests.stores())
            let lists = try context.fetch(PurchaseRulesStoreScope.listsRequest())
            return PurchaseRulesStoreScope.validStores(
                stores, lists: lists, householdID: householdID, listID: listID
            ).map(\.id)
        }
    }

    private func settingsScopeState(
        _ selection: (householdID: UUID, listID: UUID),
        persistence: PersistenceController
    ) throws -> SettingsScopeState {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let stores = try context.fetch(NavigationFetchRequests.stores())
            let lists = try context.fetch(PurchaseRulesStoreScope.listsRequest())
            let households = try context.fetch(NavigationFetchRequests.households())
            let canonicalList = StoreManagementScope.canonicalList(
                lists: lists, households: households,
                selection: PersistenceSelection(
                    householdID: selection.householdID, listID: selection.listID
                )
            )
            return SettingsScopeState(
                householdAvailable: canonicalList != nil,
                storeIDs: StoreManagementScope.validStores(stores, canonicalList: canonicalList)
                    .map(\.id)
            )
        }
    }

    private func membershipSnapshot(
        itemID: UUID,
        oneTimeNeedID: UUID,
        persistence: PersistenceController
    ) throws -> MembershipSnapshot {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let itemRequest = Item.fetchRequest()
            itemRequest.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            let item = try XCTUnwrap(context.fetch(itemRequest).first)
            let needRequest = Need.fetchRequest()
            let needs = try context.fetch(needRequest)
            let oneTime = try XCTUnwrap(needs.first { $0.id == oneTimeNeedID })
            let store = try XCTUnwrap(item.stores?.first)
            return MembershipSnapshot(
                itemStoreIDs: Set(item.stores?.map(\.id) ?? []),
                oneTimeStoreIDs: Set(oneTime.oneTimeStores?.map(\.id) ?? []),
                activeNeedIDs: Set(needs.filter { !$0.archived }.map(\.id)),
                storeArchived: store.isArchived
            )
        }
    }
}
