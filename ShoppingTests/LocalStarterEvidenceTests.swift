import CoreData
import XCTest
@testable import Shopping

final class LocalStarterEvidenceTests: XCTestCase {
    private let lifetime = SQLiteTestFixtureLifetime()

    override func setUp() {
        super.setUp()
        addTeardownBlock { try self.lifetime.cleanup() }
    }

    private func fixture() throws -> (PersistenceController, LocalStarterEvidence, URL) {
        let directory = try lifetime.makeDirectory()
        let url = directory.appendingPathComponent("Starter.sqlite")
        let persistence = try lifetime.own(PersistenceController(storeURL: url))
        let store = try XCTUnwrap(persistence.primaryStore)
        let command = try LocalHomeCreationJournal(storeURL: url).begin(name: "My Home", storeIdentifier: store.identifier)
        _ = try NeedService(persistence: persistence).createLocalHousehold(command: command)
        let evidence = try XCTUnwrap(LocalStarterJournal(storeURL: url).load())
        return (persistence, evidence, url)
    }

    func testNewStarterKeepsPositiveEvidenceAfterAcknowledgementAndReopen() throws {
        let (persistence, evidence, url) = try fixture()
        let journal = LocalHomeCreationJournal(storeURL: url)
        try journal.acknowledge(XCTUnwrap(journal.pending(storeIdentifier: evidence.graph.storeIdentifier)))
        XCTAssertNil(try journal.pending(storeIdentifier: evidence.graph.storeIdentifier))
        XCTAssertEqual(try LocalStarterJournal(storeURL: url).load(), evidence)
        persistence.writer.performAndWait { persistence.writer.reset() }
        persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
        let reopened = try lifetime.own(PersistenceController(storeURL: url))
        try reopened.writer.performAndWait { try LocalStarterEligibility.validate(evidence, persistence: reopened, context: reopened.writer) }
        XCTAssertEqual(evidence.graph.storeIdentifier, reopened.primaryStore?.identifier)
    }

    func testRenamingAndRevertingStillDisqualifiesStarter() throws {
        let (persistence, evidence, _) = try fixture()
        let service = NeedService(persistence: persistence)
        try service.renameLocalHome(name: "Temporary name", graph: evidence.graph)
        try service.renameLocalHome(name: evidence.name, graph: evidence.graph)
        XCTAssertThrowsError(try persistence.writer.performAndWait {
            try LocalStarterEligibility.validate(evidence, persistence: persistence, context: persistence.writer)
        })
    }

    func testEmptyVisibleListWithCatalogDataIsIneligible() throws {
        let (persistence, evidence, _) = try fixture()
        _ = try NeedService(persistence: persistence).createCatalogItem(values: .init(
            name: "Rice", notes: "", categoryID: nil, anyStore: true, storeIDs: []), householdID: evidence.graph.householdID)
        XCTAssertThrowsError(try persistence.writer.performAndWait {
            try LocalStarterEligibility.validate(evidence, persistence: persistence, context: persistence.writer)
        })
    }

    func testHistoricalEmptyHomeNeverAcquiresProvenanceByName() throws {
        let directory = try lifetime.makeDirectory()
        let url = directory.appendingPathComponent("Legacy.sqlite")
        let persistence = try lifetime.own(PersistenceController(storeURL: url))
        _ = try NeedService(persistence: persistence).createHousehold(name: "My Home")
        XCTAssertNil(try LocalStarterJournal(storeURL: url).load())
    }

    func testReplacementRequirementIsDurableAndCheckedInsideDeletion() async throws {
        let (persistence, evidence, _) = try fixture()
        let deletion = HomeDeletionService(persistence: persistence)
        var command = try await deletion.prepare(graph: evidence.graph, scope: nil)
        command.starterRequirement = evidence
        let restored = try JSONDecoder().decode(HomeDeletionCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(restored.starterRequirement, evidence)
        try NeedService(persistence: persistence).renameLocalHome(name: "Keep this Home", graph: evidence.graph)
        do { _ = try await deletion.execute(restored, authority: UICommandAuthority()); XCTFail("Changed source must remain") }
        catch HomeDeletionError.scopeChanged {}
        XCTAssertEqual(try persistence.writer.performAndWait { try persistence.writer.count(for: Household.fetchRequest()) }, 1)
        let statuses = try await deletion.statuses()
        XCTAssertTrue(statuses.isEmpty)
    }

    func testGenericReconciliationCannotExecuteRetainedStarterDeletion() async throws {
        let (persistence, evidence, url) = try fixture()
        let deletion = HomeDeletionService(persistence: persistence)
        var command = try await deletion.prepare(graph: evidence.graph, scope: nil)
        command.starterRequirement = evidence
        try LocalHomeDeletionJournal(storeURL: url).retain(command)
        do { _ = try await deletion.reconcile(command); XCTFail("Generic recovery has no replacement approval") }
        catch HomeDeletionError.scopeChanged {}
        XCTAssertEqual(try persistence.writer.performAndWait { try persistence.writer.count(for: Household.fetchRequest()) }, 1)
        let statuses = try await deletion.statuses()
        XCTAssertFalse(try XCTUnwrap(statuses.first).completed)
    }

    func testInterruptedStarterStaysVisibleEditableAndCanBeKept() async throws {
        let (persistence, evidence, url) = try fixture()
        let deletion = HomeDeletionService(persistence: persistence)
        var command = try await deletion.prepare(graph: evidence.graph, scope: nil)
        command.starterRequirement = evidence
        let journal = LocalHomeDeletionJournal(storeURL: url)
        try journal.retain(command)
        XCTAssertTrue(try HomeDiscoveryService(persistence: persistence).discover().homes.contains { $0.graph == evidence.graph })
        try NeedService(persistence: persistence).renameLocalHome(name: "Keep this Home", graph: evidence.graph)
        try await deletion.cancelUncommittedStarter(command)
        XCTAssertTrue(try journal.statuses().isEmpty)
        let normalDeletion = try await deletion.prepare(graph: evidence.graph, scope: nil)
        let result = try await deletion.execute(normalDeletion)
        XCTAssertTrue(result.completed, "Stopping replacement must not block later explicit Home deletion")
    }

    func testRetiredChoicePreventsQueuedReplacementDeletion() async throws {
        let (persistence, evidence, _) = try fixture()
        let deletion = HomeDeletionService(persistence: persistence)
        var command = try await deletion.prepare(graph: evidence.graph, scope: nil)
        command.starterRequirement = evidence
        let choice = UICommandAuthority()
        let authority = UICommandAuthority { try choice.validate() }
        choice.retire()
        do { _ = try await deletion.execute(command, authority: authority); XCTFail("Retired choice must not delete") }
        catch UICommandAuthority.Failure.retired {}
        let statuses = try await deletion.statuses()
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(try persistence.writer.performAndWait { try persistence.writer.count(for: Household.fetchRequest()) }, 1)
    }

    func testConfirmedUntouchedStarterReallyDisappearsAndReconcileUsesSameCommand() async throws {
        let (persistence, evidence, _) = try fixture()
        let deletion = HomeDeletionService(persistence: persistence)
        var command = try await deletion.prepare(graph: evidence.graph, scope: nil)
        command.starterRequirement = evidence
        let result = try await deletion.execute(command, authority: UICommandAuthority())
        XCTAssertTrue(result.completed)
        XCTAssertEqual(try persistence.writer.performAndWait { try persistence.writer.count(for: Household.fetchRequest()) }, 0)
        let resumed = try await deletion.reconcile(command)
        XCTAssertEqual(resumed, result)
    }
}
