import CoreData
import XCTest
@testable import Shopping

final class HomeAdoptionSnapshotTests: XCTestCase {
    private let recovery = Data([0, 1, 127, 128, 255])

    func testActualActivationPreservesEntireRichShoppingGraphWithoutCartAttribution() throws {
        let root = try directory()
        let (source, expected) = try sourceFixture(in: root)
        let destination = try activate(source: source, root: root)
        let copied = try capture(destination)
        try copied.verify(matches: expected)
        XCTAssertEqual(try copied.fingerprint, try expected.fingerprint)
        XCTAssertEqual(copied.storeIdentifiers, expected.storeIdentifiers, "Opaque copy retains object URI store identity")
        XCTAssertEqual(try capture(source), expected, "Verification and adoption retain the source")
        XCTAssertEqual(Set(copied.records.map(\.entity)), ["Household", "GroceryList", "Store", "Category", "Person",
            "Item", "Need", "ClearOperation", "PersonalCartRecord", "HouseholdCartRecord", "LegacyCartReview"])
        let item = try record("Item", in: copied)
        let archivedStore = try record("Store", named: "Archived shop", in: copied)
        XCTAssertEqual(attribute("isArchived", in: archivedStore), .boolean(true))
        XCTAssertEqual(relationship("stores", in: item), [archivedStore.objectURI])
        XCTAssertEqual(attribute("anyStore", in: item), .boolean(false))
        let oneTime = try record("Need", named: "One time", nameKey: "title", in: copied)
        XCTAssertEqual(attribute("kind", in: oneTime), .string("oneTime"))
        XCTAssertEqual(relationship("oneTimeStores", in: oneTime), [archivedStore.objectURI])
        XCTAssertEqual(relationship("item", in: oneTime), [])
        let remembered = try record("Need", named: "Remembered", nameKey: "title", in: copied)
        XCTAssertEqual(attribute("quantity", in: remembered), .null)
        XCTAssertEqual(attribute("carted", in: remembered), .boolean(true), "Legacy evidence remains unattributed")
        XCTAssertEqual(attribute("displayOrder", in: try record("Category", named: "Last", in: copied)), .integer(90))
        XCTAssertEqual(relationship("person", in: remembered), [try record("Person", in: copied).objectURI])
        XCTAssertEqual(attribute("snapshot", in: try record("ClearOperation", in: copied)), .data(recovery))
        XCTAssertEqual(attribute("payload", in: try record("HouseholdCartRecord", in: copied)), .data(recovery))
        XCTAssertEqual(attribute("claimedAccount", in: try record("LegacyCartReview", in: copied)), .string(""))
        XCTAssertEqual(attribute("accountBinding", in: try record("PersonalCartRecord", in: copied)), .string(""))
    }

    func testDomainCorruptionIsDetectedEvenWhenCopyMetadataStillMatches() throws {
        let root = try directory()
        let (source, expected) = try sourceFixture(in: root)
        let destination = try activate(source: source, root: root)
        try mutate(destination) { context in
            let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first)
            item.stores = []
            let operation = try XCTUnwrap(context.fetch(ClearOperation.fetchRequest()).first)
            operation.snapshot = Data([42])
            let need = try XCTUnwrap(context.fetch(Need.fetchRequest()).first { $0.title == "Remembered" })
            need.quantity = 0
        }
        let changed = try capture(destination)
        XCTAssertEqual(changed.storeIdentifiers, expected.storeIdentifiers)
        XCTAssertThrowsError(try changed.verify(matches: expected)) {
            XCTAssertEqual($0 as? HomeAdoptionSnapshot.Failure, .mismatch)
        }
        XCTAssertNotEqual(try changed.fingerprint, try expected.fingerprint)
        XCTAssertEqual(try capture(source), expected)
    }

    func testCompletedActivationRetryRetainsLaterEditsInsteadOfRevalidatingOriginalGraph() throws {
        let root = try directory()
        let (source, original) = try sourceFixture(in: root)
        let destination = try activate(source: source, root: root)
        try capture(destination).verify(matches: original)
        try mutate(destination) { context in
            let home = try XCTUnwrap(context.fetch(Household.fetchRequest()).first)
            home.name = "A later account edit"
            let need = Need(context: context)
            need.id = UUID(); need.kind = "oneTime"; need.title = "Added after adoption"
            need.quantity = nil; need.list = home.groceryList
        }
        let edited = try capture(destination)
        XCTAssertNotEqual(edited, original)
        XCTAssertEqual(try activate(source: source, root: root), destination)
        XCTAssertEqual(try capture(destination), edited)
        XCTAssertEqual(try capture(source), original)
    }

    func testVerificationPreservesExactUnicodeScalarsRatherThanOnlyDisplayEquivalence() throws {
        let root = try directory()
        let (source, expected) = try sourceFixture(in: root)
        let destination = try activate(source: source, root: root)
        try mutate(destination) { context in
            let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first)
            item.notes = item.notes.precomposedStringWithCanonicalMapping
        }
        let changed = try capture(destination)
        XCTAssertEqual(attribute("notes", in: try record("Item", in: changed)),
            attribute("notes", in: try record("Item", in: expected)))
        XCTAssertThrowsError(try changed.verify(matches: expected))
        XCTAssertNotEqual(try changed.fingerprint, try expected.fingerprint)
    }

    func testCanonicalSnapshotIgnoresSetIterationOrderAndRejectsUnsavedWriterChanges() throws {
        let root = try directory()
        let (source, original) = try sourceFixture(in: root)
        let persistence = try PersistenceController(storeURL: source)
        defer { try? detach(persistence) }
        let first = try HomeAdoptionSnapshot.capture(persistence: persistence)
        XCTAssertEqual(first, original)
        try persistence.writer.performAndWait {
            let home = try XCTUnwrap(persistence.writer.fetch(Household.fetchRequest()).first)
            let existing = home.categories ?? []
            home.categories = Set(existing.sorted { $0.displayOrder > $1.displayOrder })
            try persistence.writer.save()
            home.name = "Unsaved draft"
        }
        XCTAssertThrowsError(try HomeAdoptionSnapshot.capture(persistence: persistence)) {
            XCTAssertEqual($0 as? HomeAdoptionSnapshot.Failure, .unsavedChanges)
        }
        persistence.writer.performAndWait { persistence.writer.rollback() }
        XCTAssertEqual(try HomeAdoptionSnapshot.capture(persistence: persistence), original)
    }

    private func sourceFixture(in root: URL) throws -> (URL, HomeAdoptionSnapshot) {
        let url = root.appendingPathComponent("Local.sqlite")
        let persistence = try PersistenceController(storeURL: url)
        let blob = recovery
        try persistence.writer.performAndWait {
            let context = persistence.writer
            let home = Household(context: context)
            home.id = UUID(); home.name = "Original home"
            let list = GroceryList(context: context)
            list.id = UUID(); list.household = home
            let archived = Store(context: context)
            archived.id = UUID(); archived.name = "Archived shop"; archived.isArchived = true
            archived.household = home; archived.displayOrder = 8; archived.revision = 3
            let other = Store(context: context)
            other.id = UUID(); other.name = "Other shop"; other.household = home
            let first = Category(context: context)
            first.id = UUID(); first.name = "First"; first.displayOrder = 2; first.household = home
            let last = Category(context: context)
            last.id = UUID(); last.name = "Last"; last.displayOrder = 90; last.isArchived = true; last.household = home
            let person = Person(context: context)
            person.id = UUID(); person.name = "Assigned person"; person.household = home; person.isArchived = true
            let item = Item(context: context)
            item.id = UUID(); item.name = "Remembered item"; item.household = home; item.category = last
            item.anyStore = false; item.stores = [archived]; item.notes = "Preserve \u{00E9} and \u{0065}\u{0301}"
            let remembered = Need(context: context)
            remembered.id = UUID(); remembered.kind = "remembered"; remembered.title = "Remembered"
            remembered.item = item; remembered.list = list; remembered.person = person; remembered.quantity = nil
            remembered.carted = true; remembered.cartedAt = Date(timeIntervalSinceReferenceDate: 123.25)
            remembered.urgency = "urgent"; remembered.revision = 12
            let oneTime = Need(context: context)
            oneTime.id = UUID(); oneTime.kind = "oneTime"; oneTime.title = "One time"; oneTime.list = list
            oneTime.oneTimeAnyStore = false; oneTime.oneTimeStores = [archived]; oneTime.oneTimeCategory = last
            oneTime.quantity = 3; oneTime.archived = true; oneTime.person = person
            let operation = ClearOperation(context: context)
            operation.id = UUID(); operation.household = home; operation.list = list
            operation.snapshot = blob; operation.createdAt = Date(timeIntervalSinceReferenceDate: 99.125)
            oneTime.clearOperationID = operation.id
            let privateRecord = PersonalCartRecord(context: context)
            privateRecord.id = UUID(); privateRecord.accountBinding = ""; privateRecord.kind = "retained fixture"
            privateRecord.command = Data([7, 0, 255]); privateRecord.payload = blob
            let sharedRecord = HouseholdCartRecord(context: context)
            sharedRecord.id = UUID(); sharedRecord.household = home; sharedRecord.kind = "recovery"; sharedRecord.payload = blob
            let legacy = LegacyCartReview(context: context)
            legacy.id = UUID(); legacy.payload = blob; legacy.decision = "keep"; legacy.claimedAccount = ""
            try context.save()
        }
        let snapshot = try HomeAdoptionSnapshot.capture(persistence: persistence)
        try detach(persistence)
        XCTAssertEqual(try capture(url), snapshot)
        return (url, snapshot)
    }

    private func activate(source: URL, root: URL) throws -> URL {
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.adoption",
            environment: "Development", accountRecordName: "adopter")
        let configuration = try PersonalCartActivation.activate(sourceURL: source, session: session,
            baseDirectory: root.appendingPathComponent("Accounts"), importLegacy: true)
        return try XCTUnwrap(configuration.stores.first(where: { $0.role == .ownerPrivate })?.url)
    }

    private func capture(_ url: URL) throws -> HomeAdoptionSnapshot {
        try DispatchQueue.global(qos: .userInitiated).sync { try HomeAdoptionSnapshot.capture(at: url) }
    }

    private func mutate(_ url: URL, _ body: (NSManagedObjectContext) throws -> Void) throws {
        let persistence = try PersistenceController(storeURL: url)
        defer { try? detach(persistence) }
        try persistence.writer.performAndWait {
            try body(persistence.writer)
            try persistence.writer.save()
        }
    }

    private func detach(_ persistence: PersistenceController) throws {
        persistence.writer.performAndWait { persistence.writer.reset() }
        persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
        let coordinator = persistence.container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try coordinator.remove(store) }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func record(_ entity: String, named: String? = nil, nameKey: String = "name",
                        in snapshot: HomeAdoptionSnapshot) throws -> HomeAdoptionSnapshot.Record {
        try XCTUnwrap(snapshot.records.first {
            $0.entity == entity && (named == nil || attribute(nameKey, in: $0) == .string(named!))
        })
    }

    private func attribute(_ name: String, in record: HomeAdoptionSnapshot.Record) -> HomeAdoptionSnapshot.Value? {
        record.attributes.first { $0.name == name }?.value
    }

    private func relationship(_ name: String, in record: HomeAdoptionSnapshot.Record) -> [String]? {
        record.relationships.first { $0.name == name }?.targets
    }
}
