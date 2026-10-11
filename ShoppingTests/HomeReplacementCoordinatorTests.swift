import XCTest
@testable import Shopping

final class HomeReplacementCoordinatorTests: XCTestCase {
    @MainActor
    func testRetainedSourceDrainWaitsForOwnerAndAllowsNextOperation() async throws {
        let access = RetainedLocalStoreAccess()
        let entered = expectation(description: "Source reserved")
        let release = AsyncStream<Void>.makeStream()
        let owner = Task {
            try await access.perform {
                entered.fulfill()
                for await _ in release.stream { break }
                return 1
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        do {
            _ = try await access.perform { 2 }
            XCTFail("An overlapping source operation must be rejected")
        } catch HomeReplacementError.operationInProgress {}
        let next = Task {
            await access.drain()
            return try await access.perform { 3 }
        }
        release.continuation.yield(())
        release.continuation.finish()
        let firstValue = try await owner.value
        let nextValue = try await next.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(nextValue, 3)
    }

    private func fixture() throws -> (HomeReplacementProposal, HomeReplacementJournal, ReplacementEffectsFixture) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
        let session = try ShopperSession.authenticated(containerIdentifier: "test", environment: "Development", accountRecordName: "A")
        let graph = HomeGraphIdentity(storeIdentifier: "local", rootURI: "x-coredata://local/Household/p1", householdID: UUID(), listID: UUID())
        let evidence = LocalStarterEvidence(version: 1, creationID: UUID(), graph: graph, name: "My Home", transactionNumber: 1)
        let proposal = HomeReplacementProposal(id: UUID(), source: evidence, sourceURL: directory.appendingPathComponent("Local.sqlite"), invitationID: UUID(), invitation: .init(containerIdentifier: session.containerIdentifier, environment: session.environment, share: .init(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")), session: session, navigationIntent: UUID())
        let journal = HomeReplacementJournal(url: directory.appendingPathComponent("replacement.json"), session: session)
        return (proposal, journal, ReplacementEffectsFixture(proposal: proposal))
    }

    func testDuplicateCallbackDoesNotRepeatCompletedSourceRemoval() async throws {
        let (proposal, journal, effects) = try fixture()
        let coordinator = HomeReplacementCoordinator(journal: journal, effects: effects)
        _ = try await coordinator.confirm(proposal)
        let result = try await coordinator.resume(proposal.id)
        XCTAssertEqual(result.stage, .completed)
        let again = try await coordinator.resume(proposal.id)
        XCTAssertEqual(again, result)
        let events = await effects.events
        XCTAssertEqual(events, ["join", "activate", "prepare", "remove"])
    }

    func testInterruptedRemovalReopensWithSameDurableCommand() async throws {
        let (proposal, journal, effects) = try fixture()
        await effects.setFailRemoval(true)
        let first = HomeReplacementCoordinator(journal: journal, effects: effects)
        _ = try await first.confirm(proposal)
        do { _ = try await first.resume(proposal.id); XCTFail("Injected interruption") } catch ReplacementEffectsFixture.Failure.interrupted {}
        let pending = try XCTUnwrap(journal.records().first)
        XCTAssertEqual(pending.stage, .cleanupPending)
        let command = try XCTUnwrap(pending.deletion)
        await effects.setFailRemoval(false)
        let reopened = HomeReplacementCoordinator(journal: HomeReplacementJournal(url: journal.url, session: proposal.session), effects: effects)
        let result = try await reopened.resume(proposal.id)
        XCTAssertEqual(result.stage, .completed)
        XCTAssertEqual(result.deletion, command)
        let commands = await effects.removals
        XCTAssertEqual(commands, [command, command])
    }

    func testUnavailableTargetKeepsSourceAndLaterImportCanResume() async throws {
        let (proposal, journal, effects) = try fixture()
        await effects.setTargetAvailable(false)
        let coordinator = HomeReplacementCoordinator(journal: journal, effects: effects)
        _ = try await coordinator.confirm(proposal)
        let waiting = try await coordinator.resume(proposal.id)
        XCTAssertEqual(waiting.stage, .joining)
        XCTAssertNil(waiting.deletion)
        await effects.setTargetAvailable(true)
        let complete = try await coordinator.resume(proposal.id)
        XCTAssertEqual(complete.stage, .completed)
    }

    func testNewChoiceAfterActivationNeverPreparesSourceDeletion() async throws {
        let (proposal, journal, effects) = try fixture()
        await effects.invalidateAfterActivation()
        let coordinator = HomeReplacementCoordinator(journal: journal, effects: effects)
        _ = try await coordinator.confirm(proposal)
        do { _ = try await coordinator.resume(proposal.id); XCTFail("New choice must win") } catch HomeReplacementError.intentChanged {}
        XCTAssertEqual(try journal.records().first?.stage, .sourceKept)
        let events = await effects.events
        XCTAssertEqual(events, ["join", "activate"])
    }

    func testActivationInterruptionRetainsTargetBeforeNativeEffect() async throws {
        let (proposal, journal, effects) = try fixture()
        await effects.setFailActivation(true)
        let first = HomeReplacementCoordinator(journal: journal, effects: effects)
        _ = try await first.confirm(proposal)
        do { _ = try await first.resume(proposal.id); XCTFail("Injected interruption") }
        catch ReplacementEffectsFixture.Failure.interrupted {}
        let interrupted = try XCTUnwrap(journal.records().first)
        XCTAssertEqual(interrupted.stage, .activating)
        XCTAssertNotNil(interrupted.target)
        XCTAssertNil(interrupted.deletion)
        await effects.setFailActivation(false)
        let resumed = HomeReplacementCoordinator(journal: journal, effects: effects)
        let result = try await resumed.resume(proposal.id)
        XCTAssertEqual(result.stage, .completed)
        let events = await effects.events
        XCTAssertEqual(events.filter { $0 == "join" }.count, 1)
    }

    func testOtherAccountCannotReadOrConfirmThisOperation() throws {
        let (proposal, journal, _) = try fixture()
        _ = try journal.confirm(proposal)
        let other = try ShopperSession.authenticated(containerIdentifier: "test", environment: "Development", accountRecordName: "B")
        let wrong = HomeReplacementJournal(url: journal.url, session: other)
        XCTAssertThrowsError(try wrong.records())
        XCTAssertThrowsError(try wrong.confirm(proposal))
    }
}

private actor ReplacementEffectsFixture: HomeReplacementEffects {
    enum Failure: Error { case interrupted }
    let proposal: HomeReplacementProposal
    let scope: ActiveHomeScope
    var events: [String] = []
    var removals: [HomeDeletionCommand] = []
    var failRemoval = false
    var failActivation = false
    var targetAvailable = true
    var invalidateOnActivation = false
    var valid = true
    init(proposal: HomeReplacementProposal) {
        self.proposal = proposal
        scope = ActiveHomeScope(session: proposal.session, graph: .init(storeIdentifier: "shared", rootURI: "x-coredata://shared/Household/p1", householdID: UUID(), listID: UUID()))
    }
    func setFailActivation(_ value: Bool) { failActivation = value }
    func setFailRemoval(_ value: Bool) { failRemoval = value }
    func setTargetAvailable(_ value: Bool) { targetAvailable = value }
    func invalidateAfterActivation() { invalidateOnActivation = true }
    func validateIntent(_ proposal: HomeReplacementProposal, target: ActiveHomeScope?) throws {
        guard valid, proposal == self.proposal, target == nil || target == scope else { throw HomeReplacementError.intentChanged }
    }
    func join(_ proposal: HomeReplacementProposal) { events.append("join") }
    func target(_ proposal: HomeReplacementProposal) -> ActiveHomeScope? { targetAvailable ? scope : nil }
    func activate(_ target: ActiveHomeScope, proposal: HomeReplacementProposal) throws {
        events.append("activate")
        if failActivation { throw Failure.interrupted }
        if invalidateOnActivation { valid = false }
    }
    func prepareCleanup(_ proposal: HomeReplacementProposal) -> HomeDeletionCommand {
        events.append("prepare")
        return HomeDeletionCommand(id: UUID(), target: .local(graph: proposal.source.graph, storeURL: proposal.sourceURL), homeName: proposal.source.name, preparedAt: Date(), objectURIs: [proposal.source.graph.rootURI], starterRequirement: proposal.source)
    }
    func removeSource(_ command: HomeDeletionCommand, proposal: HomeReplacementProposal, target: ActiveHomeScope) throws -> HomeDeletionStatus {
        events.append("remove")
        removals.append(command)
        if failRemoval { throw Failure.interrupted }
        return HomeDeletionStatus(command: command, submitted: true, completed: true)
    }
}
