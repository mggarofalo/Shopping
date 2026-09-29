import CoreData
import XCTest
@testable import Shopping

final class HomeCreationTests: XCTestCase {
    private let fixtureLifetime = SQLiteTestFixtureLifetime()

    override func setUp() {
        super.setUp()
        let lifetime = fixtureLifetime
        addTeardownBlock { try lifetime.cleanup() }
    }

    private struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    private func fixture(policy: PersistencePermissionPolicy? = nil) throws -> (PersistenceController, HomeCreationJournal, URL, ShopperSession) {
        let directory = try fixtureLifetime.makeDirectory()
        let persistence = try fixtureLifetime.own(PersistenceController(configuration: .local(storeURL: directory.appendingPathComponent("home.sqlite")), permissionPolicy: policy))
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.creation", environment: "Development", accountRecordName: "owner")
        persistence.personalCartSessionProvider = Provider(session: session)
        persistence.personalCartInitialBinding = session.accountBinding
        let url = directory.appendingPathComponent("creation.json")
        return (persistence, HomeCreationJournal(url: url), url, session)
    }

    func testIntentSurvivesRelaunchBeforeSaveAndRetryUsesOriginalNameAndIDs() throws {
        let (persistence, journal, url, session) = try fixture()
        let store = try XCTUnwrap(persistence.primaryStore)
        let original = try journal.begin(name: "Our home", session: session, storeIdentifier: store.identifier)
        let restored = try HomeCreationJournal(url: url).begin(name: "Accidental retry name", session: session, storeIdentifier: store.identifier)
        XCTAssertEqual(restored, original)
        let created = try NeedService(persistence: persistence).createHousehold(command: restored)
        XCTAssertEqual(created.householdID, original.householdID)
        let context = persistence.container.viewContext
        try context.performAndWait {
            XCTAssertEqual(try context.fetch(Household.fetchRequest()).map(\.name), ["Our home"])
            XCTAssertEqual(try context.fetch(GroceryList.fetchRequest()).count, 1)
        }
    }

    func testCommittedCreationReplaysAfterStoreReopenWithoutReplacingEditedHome() throws {
        let (persistence, journal, url, session) = try fixture()
        let store = try XCTUnwrap(persistence.primaryStore)
        let command = try journal.begin(name: "Our home", session: session, storeIdentifier: store.identifier)
        _ = try NeedService(persistence: persistence).createHousehold(command: command)
        let context = fixtureLifetime.own(persistence.container.newBackgroundContext())
        try context.performAndWait {
            let root = try XCTUnwrap(context.fetch(Household.fetchRequest()).first)
            root.name = "Renamed after creation"
            try context.save()
        }
        let reopened = try fixtureLifetime.own(PersistenceController(configuration: persistence.configuration))
        reopened.personalCartSessionProvider = Provider(session: session)
        reopened.personalCartInitialBinding = session.accountBinding
        let restored = try XCTUnwrap(HomeCreationJournal(url: url).pending(session: session, storeIdentifier: XCTUnwrap(reopened.primaryStore).identifier))
        _ = try NeedService(persistence: reopened).createHousehold(command: restored)
        let reader = fixtureLifetime.own(reopened.container.newBackgroundContext())
        try reader.performAndWait {
            XCTAssertEqual(try reader.fetch(Household.fetchRequest()).map(\.name), ["Renamed after creation"])
            XCTAssertEqual(try reader.fetch(GroceryList.fetchRequest()).map(\.id), [command.listID])
        }
    }

    func testAcknowledgementAllowsAnotherHomeAndLateAcknowledgementCannotEraseNewIntent() throws {
        let (persistence, journal, _, session) = try fixture()
        let store = try XCTUnwrap(persistence.primaryStore)
        let first = try journal.begin(name: "First", session: session, storeIdentifier: store.identifier)
        _ = try NeedService(persistence: persistence).createHousehold(command: first)
        try journal.acknowledge(first)
        let second = try journal.begin(name: "Second", session: session, storeIdentifier: store.identifier)
        try journal.acknowledge(first)
        XCTAssertEqual(try journal.pending(session: session, storeIdentifier: store.identifier), second)
        _ = try NeedService(persistence: persistence).createHousehold(command: second)
        XCTAssertNotEqual(first.householdID, second.householdID)
        let reader = persistence.container.viewContext
        try reader.performAndWait { XCTAssertEqual(try reader.fetch(Household.fetchRequest()).count, 2) }
    }

    func testStaleResumeCannotAllocateAnotherHomeAfterAcknowledgement() throws {
        let (persistence, journal, _, session) = try fixture()
        let store = try XCTUnwrap(persistence.primaryStore)
        let first = try journal.begin(name: "First", session: session, storeIdentifier: store.identifier)
        try journal.acknowledge(first)
        XCTAssertThrowsError(try journal.begin(name: first.name, session: session,
            storeIdentifier: store.identifier, resuming: first))
        XCTAssertNil(try journal.pending(session: session, storeIdentifier: store.identifier))
        let next = try journal.begin(name: "Next", session: session, storeIdentifier: store.identifier)
        XCTAssertThrowsError(try journal.begin(name: first.name, session: session,
            storeIdentifier: store.identifier, resuming: first))
        XCTAssertEqual(try journal.pending(session: session, storeIdentifier: store.identifier), next)
    }

    func testChangedAccountCannotReadOrExecuteOriginalIntent() throws {
        let (persistence, journal, _, session) = try fixture()
        let store = try XCTUnwrap(persistence.primaryStore)
        let command = try journal.begin(name: "Owner home", session: session, storeIdentifier: store.identifier)
        let other = try ShopperSession.authenticated(containerIdentifier: session.containerIdentifier, environment: session.environment, accountRecordName: "other")
        XCTAssertThrowsError(try journal.pending(session: other, storeIdentifier: store.identifier))
        persistence.personalCartSessionProvider = Provider(session: other)
        persistence.personalCartInitialBinding = other.accountBinding
        XCTAssertThrowsError(try NeedService(persistence: persistence).createHousehold(command: command))
        XCTAssertEqual(try journal.pending(session: session, storeIdentifier: store.identifier), command)
    }

    func testDeniedSaveRetainsIntentAndLeavesNoPartialGraph() throws {
        let (persistence, journal, _, session) = try fixture(policy: DenyPersistencePermissionPolicy())
        let store = try XCTUnwrap(persistence.primaryStore)
        let command = try journal.begin(name: "Retained", session: session, storeIdentifier: store.identifier)
        XCTAssertThrowsError(try NeedService(persistence: persistence).createHousehold(command: command))
        XCTAssertEqual(try journal.pending(session: session, storeIdentifier: store.identifier), command)
        let reader = persistence.container.viewContext
        try reader.performAndWait {
            XCTAssertTrue(try reader.fetch(Household.fetchRequest()).isEmpty)
            XCTAssertTrue(try reader.fetch(GroceryList.fetchRequest()).isEmpty)
        }
    }

    func testPartialGraphAndDifferentStoreFailClosedWithoutCreatingReplacement() throws {
        let (persistence, journal, _, session) = try fixture()
        let store = try XCTUnwrap(persistence.primaryStore)
        let command = try journal.begin(name: "Retained", session: session, storeIdentifier: store.identifier)
        let context = persistence.container.viewContext
        try context.performAndWait {
            let root = Household(context: context)
            root.id = command.householdID
            root.name = "Imported partial graph"
            try context.save()
        }
        XCTAssertThrowsError(try NeedService(persistence: persistence).createHousehold(command: command))
        XCTAssertThrowsError(try journal.pending(session: session, storeIdentifier: "replacement-store"))
        try context.performAndWait {
            XCTAssertEqual(try context.fetch(Household.fetchRequest()).count, 1)
            XCTAssertTrue(try context.fetch(GroceryList.fetchRequest()).isEmpty)
        }
    }
}
