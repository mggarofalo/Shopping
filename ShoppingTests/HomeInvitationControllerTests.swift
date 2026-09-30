import CloudKit
import XCTest
@testable import Shopping

@MainActor
final class HomeInvitationControllerTests: XCTestCase {
    private struct Fixture {
        let inbox: HomeInvitationInbox
        let controller: HomeInvitationController
        let session: ShopperSession
        let entry: HomeInvitationInbox.Entry
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.invitations",
            environment: "Development", accountRecordName: "recipient-A")
        let inbox = try HomeInvitationInbox(url: directory.appendingPathComponent("inbox.json"),
            containerIdentifier: session.containerIdentifier, environment: session.environment)
        let entry = try inbox.enqueue(identity: identity(session, "first"), metadataArchive: Data([1]))
        return Fixture(inbox: inbox, controller: HomeInvitationController(inbox: inbox), session: session, entry: entry)
    }

    private func identity(_ session: ShopperSession, _ name: String) -> HomeInvitationIdentity {
        HomeInvitationIdentity(containerIdentifier: session.containerIdentifier, environment: session.environment,
            share: HomeShareIdentity(recordName: name, zoneName: "zone", zoneOwnerName: "owner"))
    }

    private func settle(_ controller: HomeInvitationController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.isProcessing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isProcessing, "Invitation work did not finish")
    }

    private func waitUntilAccepting(_ transport: InvitationFakeTransport) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await !transport.accepted.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "InvitationTestAcceptanceDidNotStart", code: 1)
    }

    func testOutstandingIngressKeepsHoldWhileEarlierEmptySnapshotPublishes() async throws {
        enum GateFailure: Error { case timedOut }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let opened = expectation(description: "Opening inbox")
        let ingressSubmitted = expectation(description: "Ingress received")
        let factoryGate = DispatchSemaphore(value: 0)
        let persistenceGate = DispatchSemaphore(value: 0)
        defer { factoryGate.signal(); persistenceGate.signal() }
        let worker = HomeInvitationWorker(factory: {
            opened.fulfill()
            guard factoryGate.wait(timeout: .now() + 5) == .success else { throw GateFailure.timedOut }
            return try HomeInvitationInbox(url: root.appendingPathComponent("inbox.json"),
                containerIdentifier: "iCloud.test.invitations", environment: "Development")
        })
        let controller = HomeInvitationController(worker: worker)
        let preparation = Task { await controller.prepare() }
        await fulfillment(of: [opened], timeout: 2)
        worker.perform({ _ in
            guard persistenceGate.wait(timeout: .now() + 5) == .success else { throw GateFailure.timedOut }
        }, completion: { _ in })
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.invitations",
            environment: "Development", accountRecordName: "recipient")
        let identity = identity(session, "pending")
        controller.onChange = { ingressSubmitted.fulfill(); controller.onChange = nil }
        let arrival = Task { try await controller.enqueue(identity: identity, metadataArchive: Data([1])) }
        await fulfillment(of: [ingressSubmitted], timeout: 2)
        factoryGate.signal()
        await preparation.value
        XCTAssertTrue(controller.hasPendingActivation, "An older empty snapshot cannot release new ingress")
        persistenceGate.signal()
        _ = try await arrival.value
        XCTAssertTrue(controller.hasPendingActivation)
    }

    func testWaitsForAccountAndStoreThenKeepsAcceptedInvitationLoading() async throws {
        let f = try fixture()
        let transport = InvitationFakeTransport()
        f.controller.configure(session: nil, sharedStoreIdentifier: "shared", transport: transport)
        await Task.yield()
        var calls = await transport.accepted
        XCTAssertTrue(calls.isEmpty)
        f.controller.configure(session: f.session)
        await Task.yield()
        calls = await transport.accepted
        XCTAssertTrue(calls.isEmpty)
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        try await settle(f.controller)
        calls = await transport.accepted
        XCTAssertEqual(calls, ["first"])
        XCTAssertEqual(f.controller.entries.first?.state, .loading)
        XCTAssertTrue(f.controller.hasPendingActivation)
        f.controller.checkAgain()
        try await settle(f.controller)
        calls = await transport.accepted
        XCTAssertEqual(calls, ["first"], "Import checks must not reaccept")
    }

    func testAlreadyJoinedShareFindsExactEmptyHomeWithoutAcceptingAgain() async throws {
        let f = try fixture()
        let graph = HomeGraphIdentity(storeIdentifier: "shared", rootURI: "test://empty-home",
            householdID: UUID(), listID: UUID())
        let transport = InvitationFakeTransport(existing: true, graph: graph)
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        try await settle(f.controller)
        let calls = await transport.accepted
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(f.controller.entries.first?.state, .ready(graph))
        XCTAssertTrue(f.controller.hasPendingActivation, "Ready import still requires explicit adoption")
    }

    func testHiddenInFlightInvitationReturnsIfAcceptanceNeedsRetry() async throws {
        let f = try fixture()
        let transport = InvitationFakeTransport(fails: true, hold: true)
        defer { Task { await transport.complete() } }
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        try await waitUntilAccepting(transport)
        f.controller.dismiss(f.entry.id)
        await transport.complete()
        try await settle(f.controller)
        guard case .failed = f.controller.entries.first?.state else {
            return XCTFail("A hidden native failure must return with its retry action")
        }
        XCTAssertTrue(f.controller.isVisible)
        XCTAssertTrue(f.controller.hasPendingActivation)
    }

    func testHiddenAcceptedInvitationReturnsForAnExplicitReadyHomeDecision() async throws {
        let f = try fixture()
        let graph = HomeGraphIdentity(storeIdentifier: "shared", rootURI: "test://invited-home",
            householdID: UUID(), listID: UUID())
        let transport = InvitationFakeTransport(graph: graph, importFails: true)
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        try await settle(f.controller)
        XCTAssertEqual(f.controller.entries.first?.state, .loading)
        f.controller.dismiss(f.entry.id)
        try await settle(f.controller)
        XCTAssertTrue(f.controller.entries.isEmpty)
        XCTAssertTrue(f.controller.hasPendingActivation)
        await transport.setImportFailure(false)
        f.controller.checkAgain()
        try await settle(f.controller)
        XCTAssertEqual(f.controller.entries.first?.state, .ready(graph))
        XCTAssertTrue(f.controller.isVisible, "An accepted hidden invitation must remain reachable once ready")
        XCTAssertTrue(f.controller.hasPendingActivation)
        try await f.controller.resolveActivation(f.entry.id)
        XCTAssertTrue(f.controller.entries.isEmpty)
        XCTAssertFalse(f.controller.hasPendingActivation)
        let calls = await transport.accepted
        XCTAssertEqual(calls, ["first"], "Showing the decision must not accept again")
    }

    func testPendingReinvitationBypassesStaleLocallyAcceptedMembership() async throws {
        let f = try fixture()
        let graph = HomeGraphIdentity(storeIdentifier: "shared", rootURI: "test://home",
            householdID: UUID(), listID: UUID())
        let transport = InvitationFakeTransport(existing: true, graph: graph)
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        try await settle(f.controller)
        try await f.controller.resolveActivation(f.entry.id)
        XCTAssertTrue(f.controller.entries.isEmpty, "An explicit home decision closes the invitation prompt")
        XCTAssertFalse(f.controller.hasPendingActivation)
        try await f.controller.enqueue(identity: f.entry.identity, metadataArchive: Data([9]), participantPending: true)
        f.controller.checkAgain()
        try await settle(f.controller)
        let calls = await transport.accepted
        let archives = await transport.archives
        XCTAssertEqual(calls, ["first"])
        XCTAssertEqual(archives, [Data([9])])
        XCTAssertEqual(f.controller.entries.first?.state, .ready(graph))
        XCTAssertTrue(f.controller.hasPendingActivation, "Renewed membership needs a fresh explicit choice")
    }

    func testTwoInvitationsAreRetainedAndAcceptedSerially() async throws {
        let f = try fixture()
        try await f.controller.enqueue(identity: identity(f.session, "second"), metadataArchive: Data([2]))
        let transport = InvitationFakeTransport()
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        f.controller.checkAgain()
        try await settle(f.controller)
        let calls = await transport.accepted
        XCTAssertEqual(calls, ["first", "second"])
        XCTAssertEqual(f.controller.entries.map(\.state), [.loading, .loading])
    }

    func testReplacementLinkReceivedWhileAnotherJoinRunsUsesFreshMetadata() async throws {
        let f = try fixture()
        let second = identity(f.session, "second")
        try await f.controller.enqueue(identity: second, metadataArchive: Data([2]))
        let transport = InvitationFakeTransport(hold: true)
        defer { Task { await transport.complete() } }
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        try await waitUntilAccepting(transport)
        try await f.controller.enqueue(identity: second, metadataArchive: Data([3]))
        f.controller.checkAgain()
        await transport.complete()
        try await settle(f.controller)
        let archives = await transport.archives
        XCTAssertEqual(archives, [Data([1]), Data([3])])
    }

    func testImportFailureClearsAfterRecoveryWithoutRepeatingAcceptance() async throws {
        let f = try fixture()
        let graph = HomeGraphIdentity(storeIdentifier: "shared", rootURI: "test://recovered-home",
            householdID: UUID(), listID: UUID())
        let transport = InvitationFakeTransport(graph: graph, importFails: true)
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        try await settle(f.controller)
        XCTAssertNotNil(f.controller.importProblems[f.entry.id])
        XCTAssertEqual(f.controller.entries.first?.state, .loading)
        await transport.setImportFailure(false)
        f.controller.checkAgain()
        try await settle(f.controller)
        XCTAssertNil(f.controller.importProblems[f.entry.id])
        XCTAssertNil(f.controller.problem)
        XCTAssertEqual(f.controller.entries.first?.state, .ready(graph))
        let calls = await transport.accepted
        XCTAssertEqual(calls, ["first"])
    }

    func testOfflineFailureRequiresExplicitRetryAndDoesNotExposeCloudErrorDetails() async throws {
        let f = try fixture()
        let transport = InvitationFakeTransport(fails: true)
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        try await settle(f.controller)
        guard case .failed(.acceptance(let message)) = f.controller.entries.first?.state else {
            return XCTFail("Expected a retryable failed invitation")
        }
        XCTAssertFalse(message.contains("secret-link"))
        f.controller.checkAgain()
        try await settle(f.controller)
        var calls = await transport.accepted
        XCTAssertEqual(calls.count, 1)
        await transport.setFailure(false)
        f.controller.retry(f.entry.id)
        try await settle(f.controller)
        calls = await transport.accepted
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(f.controller.entries.first?.state, .loading)
    }

    func testAccountSwitchWhileNativeCallbackOutstandingDoesNotReplayForOtherAccount() async throws {
        let f = try fixture()
        let transport = InvitationFakeTransport(hold: true)
        defer { Task { await transport.complete() } }
        f.controller.configure(session: f.session, sharedStoreIdentifier: "shared", transport: transport)
        try await waitUntilAccepting(transport)
        let other = try ShopperSession.authenticated(containerIdentifier: f.session.containerIdentifier,
            environment: f.session.environment, accountRecordName: "recipient-B")
        f.controller.configure(session: other, sharedStoreIdentifier: "other-store", transport: transport)
        await transport.complete()
        try await settle(f.controller)
        XCTAssertTrue(f.controller.entries.isEmpty)
        XCTAssertEqual(f.controller.allEntries.first?.session, f.session)
        XCTAssertEqual(f.controller.allEntries.first?.state, .loading)
        let calls = await transport.accepted
        XCTAssertEqual(calls, ["first"])
    }
}

private actor InvitationFakeTransport: HomeInvitationTransport {
    private let existing: Bool
    private let graph: HomeGraphIdentity?
    private var importFails: Bool
    private var fails: Bool
    private let hold: Bool
    private var completion: CheckedContinuation<Void, Never>?
    private var gateReleased = false
    private(set) var accepted: [String] = []
    private(set) var archives: [Data] = []

    init(existing: Bool = false, graph: HomeGraphIdentity? = nil, fails: Bool = false, hold: Bool = false, importFails: Bool = false) {
        self.importFails = importFails
        self.existing = existing
        self.graph = graph
        self.fails = fails
        self.hold = hold
    }
    func existingShare(identity: HomeShareIdentity) async throws -> Bool { existing }
    func accept(metadataArchive: Data, identity: HomeShareIdentity) async throws {
        accepted.append(identity.recordName)
        archives.append(metadataArchive)
        if hold && accepted.count == 1 && !gateReleased {
            await withCheckedContinuation { completion = $0 }
        }
        if fails { throw CKError(.networkUnavailable, userInfo: [NSLocalizedDescriptionKey: "secret-link"]) }
    }
    func importedHome(identity: HomeShareIdentity) async throws -> HomeGraphIdentity? {
        if importFails { throw CKError(.networkUnavailable) }
        return graph
    }
    func setImportFailure(_ fails: Bool) { importFails = fails }
    func setFailure(_ fails: Bool) { self.fails = fails }
    func complete() { gateReleased = true; completion?.resume(); completion = nil }
}
