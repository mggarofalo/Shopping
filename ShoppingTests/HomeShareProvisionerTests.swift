import XCTest
@testable import Shopping

final class HomeShareProvisionerTests: XCTestCase {
    private enum Failure: Error { case offline, denied }
    private actor Transport: HomeShareTransport {
        var known: HomeShareIdentity?
        var createFailure = false
        var lookupFailure = false
        var commitBeforeFailure = false
        var gate: CheckedContinuation<Void, Never>?
        var hold = false
        var creates: [ActiveHomeScope] = []
        var lookups = 0
        let identity = HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")

        func configure(known: HomeShareIdentity? = nil, fail: Bool = false,
                       denied: Bool = false, committed: Bool = false, hold: Bool = false) {
            self.known = known; createFailure = fail; lookupFailure = denied
            commitBeforeFailure = committed; self.hold = hold
        }
        func existingShare(for scope: ActiveHomeScope) throws -> HomeShareIdentity? {
            lookups += 1
            if lookupFailure { throw Failure.denied }
            return known
        }
        func createShare(for scope: ActiveHomeScope) async throws -> HomeShareIdentity {
            creates.append(scope)
            if hold { await withCheckedContinuation { gate = $0 } }
            if commitBeforeFailure { known = identity }
            if createFailure { throw Failure.offline }
            known = identity
            return identity
        }
        func release() { hold = false; gate?.resume(); gate = nil }
        var isSuspended: Bool { gate != nil }
        var createCount: Int { creates.count }
    }

    private func fixture() throws -> (ActiveHomeScope, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.provision", environment: "Development", accountRecordName: "owner")
        let scope = ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "private-store",
            rootURI: "x-coredata://private/Household/p1", householdID: UUID(), listID: UUID()))
        return (scope, directory.appendingPathComponent("provision.json"))
    }

    func testExistingShareIsReusedAndItsIdentitySurvivesRelaunch() async throws {
        let (scope, url) = try fixture(), transport = Transport()
        let identity = await transport.identity
        await transport.configure(known: identity)
        let first = try await HomeShareProvisioner().prepare(scope: scope, journalURL: url, transport: transport)
        let restored = try await HomeShareProvisioner().prepare(scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(first, restored)
        let count = await transport.createCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try HomeShareProvisioningJournal(url: url).begin(scope: scope).identity, identity)
    }

    func testLostCallbackRecoversCommittedShareWithoutAnotherCreate() async throws {
        let (scope, url) = try fixture(), transport = Transport()
        await transport.configure(fail: true, committed: true)
        let result = try await HomeShareProvisioner().prepare(scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(result.scope, scope)
        let count = await transport.createCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try HomeShareProvisioningJournal(url: url).begin(scope: scope).identity, result.identity)
    }

    func testUnresolvedFailureRequiresExplicitSameRootReplayAfterRelaunch() async throws {
        let (scope, url) = try fixture(), transport = Transport()
        await transport.configure(fail: true)
        do {
            _ = try await HomeShareProvisioner().prepare(scope: scope, journalURL: url, transport: transport)
            XCTFail("Expected unresolved failure")
        } catch Failure.offline {}
        let original = try HomeShareProvisioningJournal(url: url).begin(scope: scope)
        XCTAssertTrue(original.attempted)
        let restarted = HomeShareProvisioner()
        await transport.configure()
        do {
            _ = try await restarted.prepare(scope: scope, journalURL: url, transport: transport)
            XCTFail("Unexpected automatic retry")
        } catch HomeSharingError.retryRequired {}
        let result = try await restarted.prepare(scope: scope, journalURL: url, transport: transport, retryInterrupted: true)
        XCTAssertEqual(result.scope, scope)
        let creates = await transport.creates
        XCTAssertEqual(creates, [scope, scope])
        XCTAssertEqual(try HomeShareProvisioningJournal(url: url).begin(scope: scope).id, original.id)
    }

    func testKnownShareDisappearanceNeverStartsReplacementAndMismatchKeepsOriginalIdentity() async throws {
        let (scope, url) = try fixture(), transport = Transport()
        let service = HomeShareProvisioner()
        let result = try await service.prepare(scope: scope, journalURL: url, transport: transport)
        await transport.configure()
        do {
            _ = try await service.prepare(scope: scope, journalURL: url, transport: transport, retryInterrupted: true)
            XCTFail("Must retain missing known share")
        } catch HomeSharingError.associationPending {}
        await transport.configure(known: HomeShareIdentity(recordName: "different", zoneName: "other", zoneOwnerName: "owner"))
        do {
            _ = try await service.prepare(scope: scope, journalURL: url, transport: transport)
            XCTFail("Must reject different share")
        } catch HomeSharingError.conflictingShare {}
        XCTAssertEqual(try HomeShareProvisioningJournal(url: url).begin(scope: scope).identity, result.identity)
        let count = await transport.createCount
        XCTAssertEqual(count, 1)
    }

    func testDeniedAuthorityDoesNotCreateAnIntentOrInvokeCreate() async throws {
        let (scope, url) = try fixture(), transport = Transport()
        await transport.configure(denied: true)
        do {
            _ = try await HomeShareProvisioner().prepare(scope: scope, journalURL: url, transport: transport)
            XCTFail("Expected permission failure")
        } catch Failure.denied {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let count = await transport.createCount
        XCTAssertEqual(count, 0)
    }

    func testForeignScopeCannotReusePendingJournalAndFailedLocalPreparationHasNoEffect() async throws {
        let (scope, url) = try fixture(), transport = Transport()
        let original = try HomeShareProvisioningJournal(url: url).begin(scope: scope)
        let otherSession = try ShopperSession.authenticated(containerIdentifier: scope.containerIdentifier,
            environment: scope.environment, accountRecordName: "other")
        let otherScope = ActiveHomeScope(session: otherSession, graph: scope.graph)
        do {
            _ = try await HomeShareProvisioner().prepare(scope: otherScope, journalURL: url, transport: transport)
            XCTFail("Must reject foreign journal")
        } catch HomeSharingError.scopeChanged {}
        XCTAssertEqual(try HomeShareProvisioningJournal(url: url).begin(scope: scope), original)
        let badURL = url.deletingLastPathComponent().appendingPathComponent("is-a-directory")
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)
        do {
            _ = try await HomeShareProvisioner().prepare(scope: scope, journalURL: badURL, transport: transport)
            XCTFail("Must fail local preparation")
        } catch {}
        let count = await transport.createCount
        XCTAssertEqual(count, 0)
    }

    func testConcurrentAndCancelledWaitersDoNotOverlapNativeCreates() async throws {
        let (scope, url) = try fixture(), transport = Transport()
        await transport.configure(hold: true)
        let service = HomeShareProvisioner()
        let first = Task { try await service.prepare(scope: scope, journalURL: url, transport: transport) }
        let second = Task { try await service.prepare(scope: scope, journalURL: url, transport: transport, retryInterrupted: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            let requests = await service.activeRequestCount
            let suspended = await transport.isSuspended
            if requests == 2 && suspended { break }
            guard ContinuousClock.now < deadline else {
                await transport.release(); XCTFail("Requests did not reach the held callback"); return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        first.cancel()
        let count = await transport.createCount
        XCTAssertEqual(count, 1)
        await transport.release()
        let firstResult = try await first.value, secondResult = try await second.value
        XCTAssertEqual(firstResult, secondResult)
        let lookups = await transport.lookups
        XCTAssertEqual(lookups, 1)
    }
}
