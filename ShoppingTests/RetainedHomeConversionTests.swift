import CoreData
import XCTest
@testable import Shopping

final class RetainedHomeConversionTests: XCTestCase {
    private struct NeedEvidence {
        let title: String
        let carted: Bool
        let cartedAt: Date?
        let clearOperationID: UUID?
        let storeName: String?
        let personName: String?
    }

    private struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    private struct Fixture {
        let directory: URL
        let session: ShopperSession
        let source: PersistenceController
        let target: PersistenceController
        let retained: HomeAdoptionJournal.Record
        let retainedNeedID: UUID
        let existingHomeID: UUID
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.retained-copy",
            environment: "Development", accountRecordName: "owner-A")
        let sourceURL = directory.appendingPathComponent("Retained.sqlite")
        let source = try PersistenceController(storeURL: sourceURL)
        let sourceService = NeedService(persistence: source)
        let local = try sourceService.createHousehold(name: "This iPhone")
        let category = try sourceService.createCategory(name: "Produce", householdID: local.householdID)
        let store = try sourceService.createStore(name: "Market", householdID: local.householdID)
        let person = try sourceService.createPerson(name: "Family", householdID: local.householdID)
        let item = try sourceService.createItem(name: "Apples", notes: "Crisp", categoryID: category,
            storeIDs: [store], householdID: local.householdID, anyStore: false)
        let remembered = try sourceService.addRememberedNeed(itemID: item, listID: local.listID,
            householdID: local.householdID, quantity: 3, urgency: .urgent)
        _ = try sourceService.addOneTimeNeed(title: "Bread", categoryID: category,
            storeIDs: [store], anyStore: false, quantity: 2, personID: person,
            householdID: local.householdID, listID: local.listID)
        try sourceService.setCarted(true, needID: remembered)
        let other = try sourceService.createHousehold(name: "Unrelated local")
        _ = try sourceService.addOneTimeNeed(title: "Never copy", householdID: other.householdID,
            listID: other.listID)
        let graph = try XCTUnwrap(HomeDiscoveryService(persistence: source).discover().homes
            .first { $0.graph.householdID == local.householdID }?.graph)
        let proposal = HomeAdoptionJournal.Proposal(sourceURL: sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
            sourceStoreIdentifier: graph.storeIdentifier, session: session,
            householdID: local.householdID, listID: local.listID, homeName: "This iPhone", canCopy: false)
        let retained = HomeAdoptionJournal.Record(id: UUID(), proposal: proposal,
            action: .keepLocal, verified: true, snapshot: nil)

        let target = try PersistenceController(storeURL: directory.appendingPathComponent("Account.sqlite"))
        let targetService = NeedService(persistence: target)
        let existing = try targetService.createHousehold(name: "Existing iCloud")
        _ = try targetService.addOneTimeNeed(title: "Keep separate", householdID: existing.householdID,
            listID: existing.listID)
        _ = PersonalCartService(persistence: target, sessionProvider: FixedSession(session: session))
        addTeardownBlock {
            for persistence in [source, target] {
                persistence.writer.performAndWait { persistence.writer.reset() }
                for store in persistence.container.persistentStoreCoordinator.persistentStores {
                    try? persistence.container.persistentStoreCoordinator.remove(store)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(directory: directory, session: session, source: source, target: target,
            retained: retained, retainedNeedID: remembered, existingHomeID: existing.householdID)
    }

    func testSelectedGraphCopiesToDistinctOwnedHomeAndReplayDoesNotDuplicateOrClaimCart() throws {
        let fixture = try fixture()
        let source = RetainedHomeConversionService(persistence: fixture.source)
        let proposed = try source.capture(record: fixture.retained, session: fixture.session)
        XCTAssertEqual(proposed.graph.name, "This iPhone")
        XCTAssertEqual(proposed.graph.items.count, 1)
        XCTAssertEqual(proposed.graph.needs.count, 2)
        XCTAssertFalse(proposed.graph.needs.contains { $0.title == "Never copy" })

        let journal = RetainedHomeConversionJournal(baseDirectory: fixture.directory, session: fixture.session)
        let begun = try journal.begin(proposed)
        let targetStore = try XCTUnwrap(fixture.target.primaryStore)
        let bound = try journal.bind(begun, to: try XCTUnwrap(targetStore.identifier))
        let target = RetainedHomeConversionService(persistence: fixture.target)
        try target.apply(bound)
        // A termination here leaves the journal pending after a committed save.
        XCTAssertFalse(try XCTUnwrap(journal.read(session: fixture.session)).copied)
        try target.apply(try journal.bind(begun, to: try XCTUnwrap(targetStore.identifier)))
        try journal.markCopied(bound)
        XCTAssertEqual(try journal.begin(source.capture(record: fixture.retained,
            session: fixture.session)).id, begun.id)

        let discovered = try HomeDiscoveryService(persistence: fixture.target).discover().homes
        XCTAssertEqual(discovered.count, 2)
        XCTAssertTrue(discovered.contains { $0.graph.householdID == fixture.existingHomeID })
        XCTAssertTrue(discovered.contains { $0.graph.householdID == bound.graph.householdID && $0.name == "This iPhone" })
        XCTAssertNotEqual(bound.graph.householdID, fixture.retained.householdID)
        let copied: [NeedEvidence] = try read(fixture.target) { context in
            let needs = try context.fetch(Need.fetchRequest()).filter { $0.list?.id == bound.graph.listID }
            return needs.map { NeedEvidence(title: $0.title, carted: $0.carted,
                cartedAt: $0.cartedAt, clearOperationID: $0.clearOperationID,
                storeName: $0.item?.stores?.first?.name, personName: $0.person?.name) }
        }
        XCTAssertEqual(Set(copied.map(\.title)), ["Apples", "Bread"])
        XCTAssertTrue(copied.allSatisfy { !$0.carted && $0.cartedAt == nil && $0.clearOperationID == nil })
        XCTAssertEqual(copied.first { $0.title == "Apples" }?.storeName, "Market")
        XCTAssertEqual(copied.first { $0.title == "Bread" }?.personName, "Family")
        let privateCount = try read(fixture.target) {
            try $0.count(for: NSFetchRequest<PersonalCartRecord>(entityName: "PersonalCartRecord"))
        }
        XCTAssertEqual(privateCount, 0)
        let householdKinds: [String] = try read(fixture.target) {
            try $0.fetch(NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")).map(\.kind)
        }
        XCTAssertTrue(householdKinds.allSatisfy { $0 == "demand" },
            "The copied needs may emit new demand evidence, never legacy cart claims")
        let legacyCount = try read(fixture.target) {
            try $0.count(for: NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview"))
        }
        XCTAssertEqual(legacyCount, 0)
        let sourceStillCarted = try read(fixture.source) {
            try $0.fetch(Need.fetchRequest()).first { $0.id == fixture.retainedNeedID }?.carted
        }
        XCTAssertEqual(sourceStillCarted, true)
        XCTAssertEqual(try HomeDiscoveryService(persistence: fixture.source).discover().homes.count, 2)
    }

    func testJournalAndWriterRejectDifferentAccountOrTargetStore() throws {
        let fixture = try fixture()
        let proposed = try RetainedHomeConversionService(persistence: fixture.source)
            .capture(record: fixture.retained, session: fixture.session)
        let journal = RetainedHomeConversionJournal(baseDirectory: fixture.directory, session: fixture.session)
        let begun = try journal.begin(proposed)
        let originalStoreID = try XCTUnwrap(fixture.target.primaryStore?.identifier)
        let bound = try journal.bind(begun, to: originalStoreID)
        XCTAssertThrowsError(try journal.bind(begun, to: UUID().uuidString))
        let different = try ShopperSession.authenticated(containerIdentifier: fixture.session.containerIdentifier,
            environment: fixture.session.environment, accountRecordName: "owner-B")
        fixture.target.personalCartSessionProvider = FixedSession(session: different)
        XCTAssertThrowsError(try RetainedHomeConversionService(persistence: fixture.target).apply(bound))
        let rootCount = try read(fixture.target) { try $0.count(for: Household.fetchRequest()) }
        XCTAssertEqual(rootCount, 1)
        XCTAssertFalse(try XCTUnwrap(journal.read(session: fixture.session)).copied)
    }

    func testOnlyExactCompletedDestinationTombstoneAllowsFreshCopyCommand() throws {
        let fixture = try fixture()
        let source = RetainedHomeConversionService(persistence: fixture.source)
        let journal = RetainedHomeConversionJournal(baseDirectory: fixture.directory, session: fixture.session)
        let first = try journal.begin(source.capture(record: fixture.retained, session: fixture.session))
        let storeID = try XCTUnwrap(fixture.target.primaryStore?.identifier)
        let bound = try journal.bind(first, to: storeID)
        try RetainedHomeConversionService(persistence: fixture.target).apply(bound)
        try journal.markCopied(bound)
        let repeated = try journal.begin(source.capture(record: fixture.retained, session: fixture.session))
        XCTAssertEqual(repeated.id, first.id, "A missing row or retry is not deletion proof")

        try journal.noteCompletedDeletion(session: fixture.session, storeIdentifier: storeID,
            householdID: UUID(), listID: bound.graph.listID)
        XCTAssertFalse(try journal.wasDestinationDeleted(bound))
        XCTAssertEqual(try journal.begin(source.capture(record: fixture.retained,
            session: fixture.session)).id, first.id)

        // A completed private deletion supplies this exact graph identity. The
        // old command remains in history and a new explicit copy gets fresh IDs.
        try journal.noteCompletedDeletion(session: fixture.session, storeIdentifier: storeID,
            householdID: bound.graph.householdID, listID: bound.graph.listID)
        XCTAssertTrue(try journal.wasDestinationDeleted(bound))
        let next = try journal.begin(source.capture(record: fixture.retained, session: fixture.session))
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertNotEqual(next.graph.householdID, first.graph.householdID)
        XCTAssertNotEqual(next.graph.listID, first.graph.listID)
        XCTAssertEqual(try journal.begin(source.capture(record: fixture.retained,
            session: fixture.session)).id, next.id)
    }

    func testDeletedBoundDestinationRetiresCopyInterruptedBeforeJournalAcknowledgement() async throws {
        let fixture = try fixture()
        let source = RetainedHomeConversionService(persistence: fixture.source)
        let journal = RetainedHomeConversionJournal(baseDirectory: fixture.directory, session: fixture.session)
        let first = try journal.begin(source.capture(record: fixture.retained, session: fixture.session))
        let storeID = try XCTUnwrap(fixture.target.primaryStore?.identifier)
        let bound = try journal.bind(first, to: storeID)
        try RetainedHomeConversionService(persistence: fixture.target).apply(bound)
        XCTAssertFalse(try XCTUnwrap(journal.read(session: fixture.session, id: bound.id)).copied)

        let copied = try XCTUnwrap(HomeDiscoveryService(persistence: fixture.target).discover().homes.first {
            $0.graph.householdID == bound.graph.householdID
        })
        let cart = PersonalCartService(persistence: fixture.target,
            sessionProvider: FixedSession(session: fixture.session))
        let deletion = HomeDeletionService(persistence: fixture.target, cart: cart)
        let scope = ActiveHomeScope(session: fixture.session, graph: copied.graph)
        let command = try await deletion.prepare(graph: copied.graph, scope: scope)
        let completed = try await deletion.execute(command)
        XCTAssertTrue(completed.completed)
        try journal.noteCompletedDeletion(session: fixture.session,
            storeIdentifier: command.graph.storeIdentifier,
            householdID: command.graph.householdID, listID: command.graph.listID)
        XCTAssertTrue(try journal.wasDestinationDeleted(bound))
        XCTAssertThrowsError(try journal.markCopied(bound))

        let next = try journal.begin(source.capture(record: fixture.retained, session: fixture.session))
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertNotEqual(next.graph.householdID, first.graph.householdID)
        let rebound = try journal.bind(next, to: storeID)
        try RetainedHomeConversionService(persistence: fixture.target).apply(rebound)
        try journal.markCopied(rebound)
        XCTAssertEqual(try HomeDiscoveryService(persistence: fixture.target).discover().homes.count, 2)
    }

    private func read<T>(_ persistence: PersistenceController,
                         _ body: (NSManagedObjectContext) throws -> T) throws -> T {
        var result: Result<T, Error>!
        persistence.writer.performAndWait {
            persistence.writer.reset()
            result = Result { try body(persistence.writer) }
        }
        return try result.get()
    }
}
