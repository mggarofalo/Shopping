import CloudKit
import Foundation
import XCTest
@testable import Shopping

final class ShopperSessionProviderTests: XCTestCase {
    private let container = "iCloud.com.example.shopping-tests"

    func testAuthenticatedIdentityIsStableAcrossDevicesAndPartitionedByAccountAndEnvironment() throws {
        let first = try session("alice")
        XCTAssertEqual(first, try session("alice"))
        XCTAssertNotEqual(first.accountBinding, try session("bob").accountBinding)
        XCTAssertNotEqual(first.shopperID, try session("bob").shopperID)
        let production = try ShopperSession.authenticated(
            containerIdentifier: container, environment: "Production", accountRecordName: "alice"
        )
        XCTAssertNotEqual(first.accountBinding, production.accountBinding)
        let base = try directory()
        XCTAssertNotEqual(try first.storeDirectory(in: base), try production.storeDirectory(in: base))
        XCTAssertFalse(first.accountBinding.contains("alice"))
    }

    func testOfflineRelaunchUsesOnlyPreviouslyVerifiedAccountBinding() async throws {
        let cache = try directory()
        let verified = try provider(cache: cache)
        await verified.refresh()
        let expected = try verified.currentSession()
        XCTAssertEqual(verified.state, .ready(expected))

        let relaunched = try provider(cache: cache, lookup: offlineLookup)
        XCTAssertThrowsError(try relaunched.currentSession(), "Reading a cache does not itself verify an account")
        await relaunched.refresh()
        XCTAssertEqual(relaunched.state, .cached(expected))
        XCTAssertEqual(try relaunched.currentSession(), expected)

        let unprovisioned = try provider(cache: directory(), lookup: offlineLookup)
        await unprovisioned.refresh()
        XCTAssertThrowsError(try unprovisioned.currentSession())
    }

    func testObservedAccountChangeInvalidatesImmediatelyAndSurvivesRelaunch() async throws {
        let cache = try directory()
        let center = NotificationCenter()
        let active = try provider(cache: cache, notifications: center)
        await active.refresh()
        let old = try active.currentSession()
        let oldStore = try old.storeDirectory(in: cache)
        try FileManager.default.createDirectory(at: oldStore, withIntermediateDirectories: true)
        let evidence = oldStore.appendingPathComponent("recovery-evidence")
        try Data("retained".utf8).write(to: evidence)

        center.post(name: .CKAccountChanged, object: nil)
        XCTAssertEqual(active.state, .accountChanged)
        XCTAssertThrowsError(try active.currentSession()) { error in
            XCTAssertEqual(error as? ShopperSessionError, .accountChanged)
        }
        let relaunched = try provider(cache: cache, lookup: offlineLookup)
        await relaunched.refresh()
        XCTAssertThrowsError(try relaunched.currentSession(), "A known changed account must not use offline fallback")
        XCTAssertEqual(try Data(contentsOf: evidence), Data("retained".utf8))

        let changed = try provider(cache: cache, name: "bob")
        await changed.refresh()
        XCTAssertNotEqual(try changed.currentSession().accountBinding, old.accountBinding)
        XCTAssertNotEqual(try changed.currentSession().storeDirectory(in: cache), oldStore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.path))
    }

    func testAccountChangeRejectsLateLookupFromPreviousAccount() async throws {
        let center = NotificationCenter()
        let delayed = DelayedAccountRecord()
        let provider = try provider(
            cache: directory(),
            lookup: .init(status: { .available }, recordName: { try await delayed.recordName() }),
            notifications: center
        )
        let refresh = Task { await provider.refresh() }
        await delayed.waitUntilRequested()
        center.post(name: .CKAccountChanged, object: nil)
        await delayed.finish("alice")
        await refresh.value
        XCTAssertEqual(provider.state, .accountChanged)
        XCTAssertThrowsError(try provider.currentSession())
    }

    func testSignOutRestrictionsAndTemporaryAccountStatusNeverUseCachedAuthority() async throws {
        for status in [CKAccountStatus.noAccount, .restricted, .temporarilyUnavailable, .couldNotDetermine] {
            let cache = try directory()
            let active = try provider(cache: cache)
            await active.refresh()
            let unavailable = try provider(cache: cache, lookup: .init(
                status: { status }, recordName: { XCTFail("Unavailable account must not fetch identity"); return "alice" }
            ))
            await unavailable.refresh()
            XCTAssertThrowsError(try unavailable.currentSession())
            let offline = try provider(cache: cache, lookup: offlineLookup)
            await offline.refresh()
            XCTAssertThrowsError(try offline.currentSession())
        }
    }

    func testDefaultOwnerSentinelAndServerFailureCannotAuthenticate() async throws {
        let sentinel = try provider(cache: directory(), name: CKCurrentUserDefaultName)
        await sentinel.refresh()
        XCTAssertEqual(sentinel.state, .setupRequired(.invalidIdentity))
        XCTAssertThrowsError(try sentinel.currentSession())

        let cache = try directory()
        let verified = try provider(cache: cache)
        await verified.refresh()
        let failed = try provider(cache: cache, lookup: .init(
            status: { throw CKError(.notAuthenticated) }, recordName: { "unused" }
        ))
        await failed.refresh()
        XCTAssertThrowsError(try failed.currentSession())
    }

    func testConfigurationAndCorruptCacheFailClosedWithoutRemovingStores() async throws {
        XCTAssertThrowsError(try ShopperSessionProvider(
            containerIdentifier: "", environment: "Production", cacheDirectory: directory()
        ))
        let cache = try directory()
        let active = try provider(cache: cache)
        await active.refresh()
        let files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        let pointer = try XCTUnwrap(files.first(where: { $0.pathExtension == "json" }))
        try Data("invalid".utf8).write(to: pointer)
        let corrupted = try provider(cache: cache, lookup: offlineLookup)
        XCTAssertEqual(corrupted.state, .setupRequired(.cacheUnavailable))
        await corrupted.refresh()
        XCTAssertThrowsError(try corrupted.currentSession())
        let verified = try provider(cache: cache)
        await verified.refresh()
        XCTAssertEqual(try verified.currentSession(), try session("alice"))
    }

    func testObserverReceivesInvalidationOnlyAfterCommandAccessorIsBlocked() async throws {
        let center = NotificationCenter()
        let provider = try provider(cache: directory(), notifications: center)
        await provider.refresh()
        let received = expectation(description: "Account invalidation")
        let observer = center.addObserver(forName: .shopperSessionDidChange, object: nil, queue: nil) { notification in
            guard notification.userInfo?["state"] as? ShopperSessionState == .accountChanged else { return }
            do {
                _ = try provider.currentSession()
                XCTFail("Account-change observers must not see an authorized command session")
            } catch {
                XCTAssertEqual(error as? ShopperSessionError, .accountChanged)
            }
            received.fulfill()
        }
        defer { center.removeObserver(observer) }
        center.post(name: .CKAccountChanged, object: nil)
        await fulfillment(of: [received], timeout: 1)
    }

    private var offlineLookup: ShopperSessionProvider.AccountLookup {
        .init(status: { throw CKError(.networkUnavailable) }, recordName: { "unused" })
    }

    private func provider(
        cache: URL,
        name: String = "alice",
        lookup: ShopperSessionProvider.AccountLookup? = nil,
        notifications: NotificationCenter = NotificationCenter()
    ) throws -> ShopperSessionProvider {
        try ShopperSessionProvider(
            containerIdentifier: container, environment: "Development", cacheDirectory: cache,
            lookup: lookup ?? .init(status: { .available }, recordName: { name }),
            notifications: notifications
        )
    }

    private func session(_ name: String) throws -> ShopperSession {
        try ShopperSession.authenticated(
            containerIdentifier: container, environment: "Development", accountRecordName: name
        )
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor DelayedAccountRecord {
    private var result: CheckedContinuation<String, Error>?
    private var waiting: CheckedContinuation<Void, Never>?

    func recordName() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            result = continuation
            waiting?.resume()
            waiting = nil
        }
    }

    func waitUntilRequested() async {
        if result != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func finish(_ recordName: String) {
        result?.resume(returning: recordName)
        result = nil
    }
}
