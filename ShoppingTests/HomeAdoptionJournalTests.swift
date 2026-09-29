import CoreData
import XCTest
@testable import Shopping

final class HomeAdoptionJournalTests: XCTestCase {
    private enum Interruption: Error { case simulatedCrash }
    private struct Fixture {
        let root: URL
        let base: URL
        let source: URL
        let session: ShopperSession
        let householdID: UUID
        let listID: UUID
        let snapshot: HomeAdoptionSnapshot
    }
    private static let activation: @Sendable (URL?, ShopperSession, URL, Bool) throws -> PersistenceConfiguration = {
        try PersonalCartActivation.activate(sourceURL: $0, session: $1, baseDirectory: $2, importLegacy: $3)
    }

    func testEveryApprovalAndVerificationCheckpointResumesTheSameRealCopy() throws {
        for point in [HomeAdoptionJournal.Checkpoint.approved, .snapshotSaved, .copyReturned, .verified] {
            let fixture = try fixture()
            let journal = HomeAdoptionJournal(baseDirectory: fixture.base)
            let proposal = try proposal(journal, fixture)
            do {
                try journal.approve(proposal, action: .copy) { if $0 == point { throw Interruption.simulatedCrash } }
                _ = try journal.activate(session: fixture.session, using: Self.activation) {
                    if $0 == point { throw Interruption.simulatedCrash }
                }
                XCTFail("Expected the selected interruption")
            } catch Interruption.simulatedCrash {}
            let interrupted = try XCTUnwrap(journal.record(session: fixture.session))
            XCTAssertEqual(interrupted.verified, point == .verified)
            let restored = HomeAdoptionJournal(baseDirectory: fixture.base)
            let resumed = try restored.activate(session: fixture.session, using: Self.activation)
            let completed = try XCTUnwrap(restored.record(session: fixture.session))
            XCTAssertEqual(completed.id, interrupted.id)
            XCTAssertTrue(completed.verified)
            XCTAssertNil(completed.snapshot)
            XCTAssertNil(resumed.retainedLocal)
            XCTAssertEqual(resumed.preferredHouseholdID, fixture.householdID)
            XCTAssertEqual(resumed.preferredListID, fixture.listID)
            try HomeAdoptionSnapshot.capture(at: privateURL(resumed.configuration)).verify(matches: fixture.snapshot)
            try HomeAdoptionSnapshot.capture(at: fixture.source).verify(matches: fixture.snapshot)
        }
    }

    func testPendingApprovalCannotBeReboundOrActivatedForAnotherAccount() throws {
        let fixture = try fixture()
        let journal = HomeAdoptionJournal(baseDirectory: fixture.base)
        let original = try journal.approve(proposal(journal, fixture), action: .copy)
        let other = try session("other")
        XCTAssertThrowsError(try journal.activate(session: other, using: Self.activation)) {
            XCTAssertEqual($0 as? ShopperSessionError, .accountChanged)
        }
        XCTAssertThrowsError(try journal.record(session: other))
        XCTAssertThrowsError(try journal.prepare(sourceURL: fixture.source, session: other,
            householdID: fixture.householdID, listID: fixture.listID, homeName: "Original"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try other.storeDirectory(in: fixture.base).path))
        XCTAssertEqual(try journal.record(session: fixture.session)?.id, original.id)
        try HomeAdoptionSnapshot.capture(at: fixture.source).verify(matches: fixture.snapshot)
    }

    func testExistingPrivateOrSharedStoreDisallowsCopyButKeepsValidatedLocalHomeUsable() throws {
        for filename in ["Private.sqlite", "Shared.sqlite"] {
            let fixture = try fixture()
            let accountDirectory = try fixture.session.storeDirectory(in: fixture.base)
            try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
            let existing = accountDirectory.appendingPathComponent(filename)
            _ = try seed(existing, name: "Already available home")
            let existingSnapshot = try HomeAdoptionSnapshot.capture(at: existing)
            let journal = HomeAdoptionJournal(baseDirectory: fixture.base)
            let choice = try proposal(journal, fixture)
            XCTAssertFalse(choice.canCopy)
            XCTAssertThrowsError(try journal.approve(choice, action: .copy))
            XCTAssertNil(try journal.record(session: fixture.session))
            _ = try journal.approve(choice, action: .keepLocal)
            let result = try journal.activate(session: fixture.session, using: Self.activation)
            let retained = try XCTUnwrap(result.retainedLocal)
            XCTAssertTrue(retained.verified)
            try journal.validateRetainedSource(retained)
            XCTAssertNil(result.preferredHouseholdID)
            XCTAssertNil(result.preferredListID)
            try HomeAdoptionSnapshot.capture(at: fixture.source).verify(matches: fixture.snapshot)
            try HomeAdoptionSnapshot.capture(at: existing).verify(matches: existingSnapshot)
        }
    }

    func testMutationBetweenCopyAndVerificationFailsClosedAndRetainsPendingSnapshot() throws {
        let fixture = try fixture()
        let journal = HomeAdoptionJournal(baseDirectory: fixture.base)
        _ = try journal.approve(proposal(journal, fixture), action: .copy)
        let destination = try fixture.session.storeDirectory(in: fixture.base).appendingPathComponent("Private.sqlite")
        XCTAssertThrowsError(try journal.activate(session: fixture.session, using: Self.activation) { point in
            if point == .copyReturned {
                try self.mutate(destination) { context in
                    let need = try XCTUnwrap(context.fetch(Need.fetchRequest()).first)
                    need.quantity = 99
                    let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first)
                    item.stores = []
                }
            }
        }) {
            XCTAssertEqual($0 as? HomeAdoptionSnapshot.Failure, .mismatch)
        }
        let pending = try XCTUnwrap(journal.record(session: fixture.session))
        XCTAssertFalse(pending.verified)
        XCTAssertEqual(pending.snapshot, fixture.snapshot)
        let changed = try HomeAdoptionSnapshot.capture(at: destination)
        XCTAssertThrowsError(try HomeAdoptionJournal(baseDirectory: fixture.base)
            .activate(session: fixture.session, using: Self.activation))
        XCTAssertEqual(try HomeAdoptionSnapshot.capture(at: destination), changed, "Retry cannot overwrite a mismatched destination")
        try HomeAdoptionSnapshot.capture(at: fixture.source).verify(matches: fixture.snapshot)
    }

    func testCompletedRetryDoesNotCompareOrOverwriteLaterAccountEdits() throws {
        let fixture = try fixture()
        let journal = HomeAdoptionJournal(baseDirectory: fixture.base)
        _ = try journal.approve(proposal(journal, fixture), action: .copy)
        let first = try journal.activate(session: fixture.session, using: Self.activation)
        let destination = try privateURL(first.configuration)
        try mutate(destination) { context in
            let home = try XCTUnwrap(context.fetch(Household.fetchRequest()).first)
            home.name = "Renamed after successful adoption"
            let need = Need(context: context)
            need.id = UUID(); need.kind = "oneTime"; need.title = "Later request"
            need.list = home.groceryList; need.quantity = nil
        }
        let edited = try HomeAdoptionSnapshot.capture(at: destination)
        XCTAssertNotEqual(edited, fixture.snapshot)
        let restored = HomeAdoptionJournal(baseDirectory: fixture.base)
        let resumed = try restored.activate(session: fixture.session, using: Self.activation)
        XCTAssertEqual(resumed.configuration, first.configuration)
        XCTAssertEqual(try HomeAdoptionSnapshot.capture(at: destination), edited)
        XCTAssertNil(try restored.record(session: fixture.session)?.snapshot)
        let reconnect = try restored.prepare(sourceURL: nil, session: fixture.session,
            householdID: nil, listID: nil, homeName: "Reconnect")
        XCTAssertNil(reconnect.sourceURL, "Reconnecting never presents the backup as a new local adoption")
        XCTAssertFalse(reconnect.canCopy)
        try HomeAdoptionSnapshot.capture(at: fixture.source).verify(matches: fixture.snapshot)
    }

    func testCorruptJournalNeverReplacesApprovalOrCreatesAnAccountStore() throws {
        let fixture = try fixture()
        let journal = HomeAdoptionJournal(baseDirectory: fixture.base)
        let proposal = try proposal(journal, fixture)
        _ = try journal.approve(proposal, action: .copy)
        let url = fixture.base.appendingPathComponent("HomeAdoption.json")
        let corrupt = Data("corrupt approval journal".utf8)
        try corrupt.write(to: url)
        let restored = HomeAdoptionJournal(baseDirectory: fixture.base)
        XCTAssertThrowsError(try restored.record(session: fixture.session))
        XCTAssertThrowsError(try restored.approve(proposal, action: .copy))
        XCTAssertThrowsError(try restored.activate(session: fixture.session, using: Self.activation))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.session.storeDirectory(in: fixture.base).path))
        try HomeAdoptionSnapshot.capture(at: fixture.source).verify(matches: fixture.snapshot)
    }

    func testReplacedSourceUUIDIsRejectedAtApprovalAndPendingCopyRecovery() throws {
        for alreadyApproved in [false, true] {
            let fixture = try fixture()
            let journal = HomeAdoptionJournal(baseDirectory: fixture.base)
            let proposal = try proposal(journal, fixture)
            if alreadyApproved { _ = try journal.approve(proposal, action: .copy) }
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: try PersistenceModel.make())
            try coordinator.destroyPersistentStore(at: fixture.source, ofType: NSSQLiteStoreType, options: nil)
            _ = try seed(fixture.source, name: "Different physical source")
            let replacement = try HomeAdoptionSnapshot.capture(at: fixture.source)
            XCTAssertNotEqual(replacement.storeIdentifiers, fixture.snapshot.storeIdentifiers)
            if alreadyApproved {
                XCTAssertThrowsError(try journal.activate(session: fixture.session, using: Self.activation))
                XCTAssertFalse(try XCTUnwrap(journal.record(session: fixture.session)).verified)
            } else {
                XCTAssertThrowsError(try journal.approve(proposal, action: .copy))
                XCTAssertNil(try journal.record(session: fixture.session))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.session.storeDirectory(in: fixture.base).path))
            XCTAssertEqual(try HomeAdoptionSnapshot.capture(at: fixture.source), replacement)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Local.sqlite")
        let ids = try seed(source, name: "Original home")
        return Fixture(root: root, base: root.appendingPathComponent("Accounts"), source: source,
            session: try session("owner"), householdID: ids.0, listID: ids.1,
            snapshot: try HomeAdoptionSnapshot.capture(at: source))
    }

    private func proposal(_ journal: HomeAdoptionJournal, _ fixture: Fixture) throws -> HomeAdoptionJournal.Proposal {
        try journal.prepare(sourceURL: fixture.source, session: fixture.session,
            householdID: fixture.householdID, listID: fixture.listID, homeName: "Original home")
    }

    private func session(_ name: String) throws -> ShopperSession {
        try ShopperSession.authenticated(containerIdentifier: "iCloud.test.adoption-journal",
            environment: "Development", accountRecordName: name)
    }

    private func privateURL(_ configuration: PersistenceConfiguration) throws -> URL {
        try XCTUnwrap(configuration.stores.first { $0.role == .ownerPrivate }?.url)
    }

    private func seed(_ url: URL, name: String) throws -> (UUID, UUID) {
        let persistence = try PersistenceController(storeURL: url)
        let homeID = UUID(), listID = UUID()
        try persistence.writer.performAndWait {
            let context = persistence.writer
            let home = Household(context: context)
            home.id = homeID; home.name = name
            let list = GroceryList(context: context)
            list.id = listID; list.household = home
            let category = Category(context: context)
            category.id = UUID(); category.name = "Last"; category.displayOrder = 20; category.household = home
            let store = Store(context: context)
            store.id = UUID(); store.name = "Archived only"; store.isArchived = true; store.household = home
            let person = Person(context: context)
            person.id = UUID(); person.name = "Assigned person"; person.household = home
            let item = Item(context: context)
            item.id = UUID(); item.name = "Remembered"; item.household = home; item.category = category
            item.anyStore = false; item.stores = [store]
            let need = Need(context: context)
            need.id = UUID(); need.kind = "remembered"; need.title = "Need"; need.item = item
            need.list = list; need.quantity = nil; need.person = person; need.carted = true
            let oneTime = Need(context: context)
            oneTime.id = UUID(); oneTime.kind = "oneTime"; oneTime.title = "Independent"
            oneTime.list = list; oneTime.oneTimeStores = [store]; oneTime.oneTimeCategory = category
            let recovery = ClearOperation(context: context)
            recovery.id = UUID(); recovery.household = home; recovery.list = list
            recovery.snapshot = Data([0, 128, 255]); recovery.createdAt = Date(timeIntervalSinceReferenceDate: 123)
            try context.save()
        }
        try detach(persistence)
        return (homeID, listID)
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
}
