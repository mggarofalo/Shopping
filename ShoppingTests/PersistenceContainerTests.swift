import CoreData
import XCTest
@testable import Shopping

final class PersistenceContainerTests: XCTestCase {
    func testLocalDiskRelaunchPreservesNeedAndRecovery() throws {
        let url = temporaryURL("relaunch.sqlite")
        var householdID: UUID!, needID: UUID!, operationID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            householdID = ids.householdID
            let itemID = try service.createItem(name: "Milk", householdID: householdID)
            needID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID, quantity: 3, notes: "Lactose free", urgency: .urgent)
            try service.setCarted(true, needID: needID)
            let token = try service.captureCarted(householdID: householdID, listID: ids.listID)
            operationID = token.id
            XCTAssertEqual(try service.clearCarted(using: token), 1)
        }
        let persistence = try PersistenceController(storeURL: url)
        let service = NeedService(persistence: persistence)
        XCTAssertEqual(try service.firstHouseholdSelection()?.householdID, householdID)
        XCTAssertEqual(try service.undoClear(operationID: operationID), 1)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let need = try XCTUnwrap(context.fetch(request).first)
            XCTAssertEqual(need.quantity, 3)
            XCTAssertEqual(need.notes, "Lactose free")
            XCTAssertEqual(need.urgency, NeedUrgency.urgent.rawValue)
            XCTAssertTrue(need.carted)
            XCTAssertFalse(need.archived)
        }
    }

    func testManagedDescriptorsUseDistinctPrivateAndSharedScopesWhileLocalHasNoCloudOptions() {
        let privateURL = temporaryURL("private.sqlite")
        let sharedURL = temporaryURL("shared.sqlite")
        let managed = PersistenceConfiguration.managed(
            privateURL: privateURL,
            sharedURL: sharedURL,
            containerIdentifier: "iCloud.com.example.shopping"
        ).makeDescriptions()
        XCTAssertEqual(managed.map(\.url), [privateURL, sharedURL])
        XCTAssertEqual(managed[0].cloudKitContainerOptions?.databaseScope, .private)
        XCTAssertEqual(managed[1].cloudKitContainerOptions?.databaseScope, .shared)
        XCTAssertTrue(managed.allSatisfy { $0.type == NSSQLiteStoreType })

        let local = PersistenceConfiguration.local(storeURL: privateURL).makeDescriptions()
        XCTAssertNil(local[0].cloudKitContainerOptions)
    }

    func testPermissionAndJournalFailuresRollbackWholeCommand() throws {
        let denied = try PersistenceController(
            configuration: .local(storeURL: temporaryURL("denied.sqlite")),
            permissionPolicy: DenyPersistencePermissionPolicy()
        )
        XCTAssertThrowsError(try NeedService(persistence: denied).createHousehold()) {
            XCTAssertEqual($0 as? PersistencePermissionError, .updateDenied)
        }
        XCTAssertEqual(try count(Household.fetchRequest(), in: denied.simulationContext()), 0)

        let journal = FailingJournal()
        let journalDenied = try PersistenceController(
            configuration: .local(storeURL: temporaryURL("journal.sqlite")),
            shareAssociationJournal: journal
        )
        XCTAssertThrowsError(try NeedService(persistence: journalDenied).createHousehold())
        XCTAssertEqual(try count(Household.fetchRequest(), in: journalDenied.simulationContext()), 0)
        XCTAssertEqual(journal.stageAttempts, 1)
    }

    func testMultipleLocalStoresKeepFirstPrimaryAndHistoryCheckpointsPerStore() async throws {
        let firstURL = temporaryURL("first.sqlite")
        let secondURL = temporaryURL("second.sqlite")
        let persistence = try PersistenceController(storeURL: firstURL, additionalStoreURLs: [secondURL])
        XCTAssertEqual(persistence.storeBindings.count, 2)
        XCTAssertEqual(persistence.primaryStore?.url, firstURL)
        _ = try NeedService(persistence: persistence).createHousehold()

        let secondStore = try XCTUnwrap(persistence.storeBindings.last?.store)
        let external = persistence.simulationContext()
        try external.performAndWait {
            let household = NSEntityDescription.insertNewObject(forEntityName: "Household", into: external) as! Household
            household.id = UUID()
            household.name = "Second store"
            external.assign(household, to: secondStore)
            try external.save()
        }

        let checkpoints = MemoryCheckpointStore()
        let consumer = PersistentHistoryConsumer(persistence: persistence, checkpoints: checkpoints)
        _ = try await consumer.consume()
        XCTAssertEqual(checkpoints.identifiers, Set(persistence.storeBindings.map { $0.store.identifier }))
    }

    func testOverlappingHistoryTriggersCoalesceAndCheckpointFailureRetries() async throws {
        let persistence = try PersistenceController(storeURL: temporaryURL("history.sqlite"))
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let needID = try service.addOneTimeNeed(title: "Ice", listID: ids.listID)
        let external = persistence.simulationContext()
        try external.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let need = try XCTUnwrap(external.fetch(request).first)
            need.quantity = 2
            need.revision += 1
            try external.save()
        }

        let checkpoints = MemoryCheckpointStore(failFirstSave: true)
        let consumer = PersistentHistoryConsumer(persistence: persistence, checkpoints: checkpoints)
        async let first = consumer.consume()
        async let second = consumer.consume()
        do {
            _ = try await (first, second)
            XCTFail("Checkpoint failure must surface")
        } catch {}
        XCTAssertNil(checkpoints.latestToken)

        let consumed = try await consumer.consume()
        XCTAssertEqual(consumed, 1)
        XCTAssertNotNil(checkpoints.latestToken)
        XCTAssertEqual(checkpoints.successfulSaveCount, 1)
    }

    func testLoadFailurePreservesOriginalBytes() throws {
        let parent = temporaryURL("not-a-directory")
        let bytes = Data("keep me".utf8)
        try bytes.write(to: parent)
        XCTAssertThrowsError(try PersistenceController(storeURL: parent.appendingPathComponent("Shopping.sqlite")))
        XCTAssertEqual(try Data(contentsOf: parent), bytes)
    }

    func testShareJournalAcknowledgesCapturedURIsWithoutDroppingNewerEntries() throws {
        let url = temporaryURL("associations.json")
        let household = URL(string: "x-coredata://household")!
        let first = URL(string: "x-coredata://object-a")!
        let second = URL(string: "x-coredata://object-b")!
        try JSONEncoder().encode([
            PendingShareAssociation(householdURI: household, objectURIs: [first])
        ]).write(to: url)
        let journal = FileShareAssociationJournal(url: url)
        let captured = try XCTUnwrap(journal.pending().first)

        try JSONEncoder().encode([
            PendingShareAssociation(householdURI: household, objectURIs: [first, second])
        ]).write(to: url, options: .atomic)
        try journal.acknowledge(householdURI: household, objectURIs: captured.objectURIs)

        XCTAssertEqual(try journal.pending(), [
            PendingShareAssociation(householdURI: household, objectURIs: [second])
        ])
    }


    func testPartialImportedGraphDoesNotBecomeSelectionOrTriggerReplacementEligibility() throws {
        let persistence = try PersistenceController(storeURL: temporaryURL("partial-import.sqlite"))
        let context = persistence.simulationContext()
        try context.performAndWait {
            let household = NSEntityDescription.insertNewObject(forEntityName: "Household", into: context) as! Household
            household.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            household.name = "Import pending"
            let list = NSEntityDescription.insertNewObject(forEntityName: "GroceryList", into: context) as! GroceryList
            list.id = UUID()
            list.household = household
            try context.save()
        }

        let service = NeedService(persistence: persistence)
        XCTAssertNil(try service.firstHouseholdSelection())
        XCTAssertFalse(try service.isPersistentStoreEmpty())
    }


    func testIncompleteItemAndStoreIdentitiesStayOutOfCatalogSuggestionsAndEligibility() throws {
        let persistence = try PersistenceController(storeURL: temporaryURL("incomplete-catalog.sqlite"))
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let storeID = try service.createStore(name: "Market", householdID: selection.householdID)
        let itemID = try service.createItem(
            name: "Milk",
            storeIDs: [storeID],
            householdID: selection.householdID,
            anyStore: false
        )
        let needID = try service.addRememberedNeed(itemID: itemID, listID: selection.listID)

        let context = persistence.simulationContext()
        try context.performAndWait {
            let householdRequest = Household.fetchRequest()
            householdRequest.predicate = NSPredicate(format: "id == %@", selection.householdID as CVarArg)
            let household = try XCTUnwrap(context.fetch(householdRequest).first)

            let incompleteStore = NSEntityDescription.insertNewObject(forEntityName: "Store", into: context) as! Store
            incompleteStore.setPrimitiveValue(nil, forKey: "id")
            incompleteStore.name = "Importing store"
            incompleteStore.isArchived = false
            incompleteStore.household = household

            let incompleteItem = NSEntityDescription.insertNewObject(forEntityName: "Item", into: context) as! Item
            incompleteItem.setPrimitiveValue(nil, forKey: "id")
            incompleteItem.name = "Importing item"
            incompleteItem.notes = ""
            incompleteItem.anyStore = true
            incompleteItem.isArchived = false
            incompleteItem.household = household
            try context.save()
        }

        XCTAssertEqual(try service.catalogSuggestionNames(householdID: selection.householdID), ["Milk"])
        XCTAssertEqual(try service.allCatalogItemIDs(householdID: selection.householdID), Set([itemID]))
        XCTAssertEqual(
            try service.filteredCatalogItemIDs(householdID: selection.householdID, filter: CatalogItemFilter()),
            [itemID]
        )
        XCTAssertEqual(try service.allActiveNeedIDs(householdID: selection.householdID), Set([needID]))
        let zeroStoreFilter = CatalogItemFilter(
            purchase: PurchaseFilter(selectedStoreID: PersistenceModel.unsetID)
        )
        XCTAssertTrue(
            try service.filteredCatalogItemIDs(householdID: selection.householdID, filter: zeroStoreFilter).isEmpty
        )
        XCTAssertEqual(
            try service.filteredActiveNeedIDs(householdID: selection.householdID, filter: GroceryNeedFilter()),
            [needID]
        )
        XCTAssertTrue(
            try service.filteredActiveNeedIDs(
                householdID: selection.householdID,
                filter: GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: PersistenceModel.unsetID))
            ).isEmpty
        )
    }

    func testDuplicateCatalogAndStoreIdentitiesFailWithTypedErrors() throws {
        let persistence = try PersistenceController(storeURL: temporaryURL("duplicate-catalog.sqlite"))
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let storeID = try service.createStore(name: "Market", householdID: selection.householdID)
        let itemID = try service.createItem(name: "Milk", householdID: selection.householdID)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let householdRequest = Household.fetchRequest()
            householdRequest.predicate = NSPredicate(format: "id == %@", selection.householdID as CVarArg)
            let household = try XCTUnwrap(context.fetch(householdRequest).first)

            let duplicateStore = NSEntityDescription.insertNewObject(forEntityName: "Store", into: context) as! Store
            duplicateStore.id = storeID
            duplicateStore.name = "Duplicate market"
            duplicateStore.isArchived = true
            duplicateStore.household = household

            let duplicateItem = NSEntityDescription.insertNewObject(forEntityName: "Item", into: context) as! Item
            duplicateItem.id = itemID
            duplicateItem.name = "Duplicate milk"
            duplicateItem.notes = ""
            duplicateItem.anyStore = true
            duplicateItem.isArchived = true
            duplicateItem.household = household
            try context.save()
        }

        XCTAssertThrowsError(
            try service.filteredCatalogItemIDs(householdID: selection.householdID, filter: CatalogItemFilter())
        ) { XCTAssertEqual($0 as? NeedServiceError, .invalidStoreIdentity) }
        XCTAssertThrowsError(try service.allCatalogItemIDs(householdID: selection.householdID)) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidCatalogIdentity)
        }
        XCTAssertThrowsError(try service.updateItemMetadata(
            itemID: itemID, householdID: selection.householdID,
            name: "Changed", notes: "", categoryID: nil, isArchived: true
        )) { XCTAssertEqual($0 as? NeedServiceError, .invalidCatalogIdentity) }
        XCTAssertThrowsError(try service.setStoreArchived(true, storeID: storeID, householdID: selection.householdID)) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidStoreIdentity)
        }
        let verify = persistence.simulationContext()
        try verify.performAndWait {
            let items = try verify.fetch(Item.fetchRequest())
            XCTAssertEqual(Set(items.map(\.name)), ["Milk", "Duplicate milk"])
            XCTAssertEqual(items.filter { !$0.isArchived }.count, 1)
            let stores = try verify.fetch(Store.fetchRequest())
            XCTAssertEqual(stores.filter { !$0.isArchived }.count, 1)
        }
    }

    func testMissingImportedClearSnapshotLeavesArchivedOccurrenceRetryable() throws {
        let persistence = try PersistenceController(storeURL: temporaryURL("missing-snapshot.sqlite"))
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let needID = try service.addOneTimeNeed(title: "Ice", listID: ids.listID)
        try service.setCarted(true, needID: needID)
        let token = try service.captureCarted(householdID: ids.householdID, listID: ids.listID)
        XCTAssertEqual(try service.clearCarted(using: token), 1)
        let imported = persistence.simulationContext()
        try imported.performAndWait {
            let request = ClearOperation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", token.id as CVarArg)
            try XCTUnwrap(imported.fetch(request).first).snapshot = nil
            try imported.save()
        }

        XCTAssertThrowsError(try service.undoClear(operationID: token.id)) {
            XCTAssertEqual($0 as? NeedServiceError, .incompleteRecoveryData)
        }
        let verify = persistence.simulationContext()
        try verify.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let need = try XCTUnwrap(verify.fetch(request).first)
            XCTAssertTrue(need.archived)
            XCTAssertEqual(need.clearOperationID, token.id)
        }
    }

    private func count<T>(_ request: NSFetchRequest<T>, in context: NSManagedObjectContext) throws -> Int {
        try context.performAndWait { try context.count(for: request) }
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingContainerTests-\(UUID().uuidString)-\(name)")
    }
}

private final class FailingJournal: ShareAssociationJournal {
    private(set) var stageAttempts = 0
    func stagePrivateInserts(_ objects: Set<NSManagedObject>, controller: PersistenceController) throws {
        stageAttempts += 1
        throw CocoaError(.fileWriteUnknown)
    }
    func pending() throws -> [PendingShareAssociation] { [] }
    func acknowledge(householdURI: URL, objectURIs: Set<URL>) throws {}
}

private final class MemoryCheckpointStore: HistoryCheckpointStore {
    private let lock = NSLock()
    private var tokens: [String: NSPersistentHistoryToken] = [:]
    private var shouldFail: Bool
    private(set) var successfulSaveCount = 0

    init(failFirstSave: Bool = false) { shouldFail = failFirstSave }

    var identifiers: Set<String> { lock.withLock { Set(tokens.keys) } }
    var latestToken: NSPersistentHistoryToken? { lock.withLock { tokens.values.first } }

    func load(for storeIdentifier: String) throws -> NSPersistentHistoryToken? {
        lock.withLock { tokens[storeIdentifier] }
    }

    func save(_ token: NSPersistentHistoryToken, for storeIdentifier: String) throws {
        try lock.withLock {
            if shouldFail {
                shouldFail = false
                throw CocoaError(.fileWriteUnknown)
            }
            tokens[storeIdentifier] = token
            successfulSaveCount += 1
        }
    }
}
