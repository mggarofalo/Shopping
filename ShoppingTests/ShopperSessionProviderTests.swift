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

    func testObservedAccountChangeRechecksBeforeSwitchingAndRetainsPreviousStore() async throws {
        let cache = try directory()
        let center = NotificationCenter()
        let account = AccountScript()
        let active = try provider(cache: cache, lookup: account.lookup, notifications: center)
        await active.refresh()
        let old = try active.currentSession()
        let oldStore = try old.storeDirectory(in: cache)
        try FileManager.default.createDirectory(at: oldStore, withIntermediateDirectories: true)
        let evidence = oldStore.appendingPathComponent("recovery-evidence")
        try Data("retained".utf8).write(to: evidence)

        account.set(name: "bob")
        account.holdNextLookup()
        let switched = expectation(description: "Re-check derives the new account")
        let observer = active.observeSessionChanges { state, _ in
            if case .ready(let session) = state, session != old { switched.fulfill() }
        }
        defer { active.removeSessionObserver(observer) }
        center.post(name: .CKAccountChanged, object: nil)
        XCTAssertEqual(active.state, .cached(old), "A change notification is a prompt to re-check, not an answer")
        XCTAssertEqual(try active.currentSession(), old)
        let reached = expectation(description: "Lookup is held")
        account.fulfillWhenHeld(reached)
        await fulfillment(of: [reached], timeout: 1)
        XCTAssertEqual(active.state, .cached(old), "Commands keep the saved account while the re-check runs")
        account.releaseHeld()
        await fulfillment(of: [switched], timeout: 1)
        let changed = try active.currentSession()
        XCTAssertNotEqual(changed.accountBinding, old.accountBinding)
        XCTAssertNotEqual(try changed.storeDirectory(in: cache), oldStore)
        XCTAssertEqual(try Data(contentsOf: evidence), Data("retained".utf8))

        let relaunched = try provider(cache: cache, lookup: offlineLookup)
        await relaunched.refresh()
        XCTAssertEqual(relaunched.state, .cached(changed), "Offline relaunch uses only the latest verified account")
    }

    func testObservedAccountChangeForSameAccountNeverRetires() async throws {
        let center = NotificationCenter()
        let provider = try provider(cache: directory(), notifications: center)
        await provider.refresh()
        let original = try provider.currentSession()
        let reverified = expectation(description: "Same account re-verified")
        let observer = provider.observeSessionChanges { state, outgoing in
            XCTAssertNil(outgoing, "No session is invalidated for the same account")
            XCTAssertNotEqual(state, .accountChanged)
            if state == .ready(original) { reverified.fulfill() }
        }
        defer { provider.removeSessionObserver(observer) }
        center.post(name: .CKAccountChanged, object: nil)
        await fulfillment(of: [reverified], timeout: 1)
        XCTAssertEqual(provider.state, .ready(original))
    }

    func testObservedAccountChangeToSignedOutInvalidatesAndSurvivesRelaunch() async throws {
        let cache = try directory()
        let center = NotificationCenter()
        let account = AccountScript()
        let provider = try provider(cache: cache, lookup: account.lookup, notifications: center)
        await provider.refresh()
        let original = try provider.currentSession()
        account.set(status: .noAccount)
        let signedOut = expectation(description: "Sign-out invalidates the exact outgoing account")
        let observer = provider.observeSessionChanges { state, outgoing in
            guard state == .setupRequired(.noAccount) else { return }
            XCTAssertEqual(outgoing, original)
            if (try? provider.currentSession()) != nil {
                XCTFail("Sign-out observers must not see an authorized command session")
            }
            signedOut.fulfill()
        }
        defer { provider.removeSessionObserver(observer) }
        center.post(name: .CKAccountChanged, object: nil)
        await fulfillment(of: [signedOut], timeout: 1)

        let relaunched = try self.provider(cache: cache, lookup: offlineLookup)
        XCTAssertEqual(relaunched.state, .accountChanged)
        await relaunched.refresh()
        XCTAssertThrowsError(try relaunched.currentSession(), "A known signed-out account must not use offline fallback")
    }

    func testAccountChangeRejectsLateLookupFromPreviousAccount() async throws {
        let center = NotificationCenter()
        let account = AccountScript(holdFirstLookup: true)
        let provider = try provider(cache: directory(), lookup: account.lookup, notifications: center)
        let refresh = Task { await provider.refresh() }
        addTeardownBlock { account.releaseHeld() }
        let reached = expectation(description: "Lookup is held")
        account.fulfillWhenHeld(reached)
        guard await XCTWaiter().fulfillment(of: [reached], timeout: 1) == .completed else {
            return XCTFail("The first lookup never reached the account record")
        }
        account.set(name: "bob")
        let rechecked = expectation(description: "Re-check after the account change")
        let observer = provider.observeSessionChanges { state, _ in
            if case .ready = state { rechecked.fulfill() }
        }
        defer { provider.removeSessionObserver(observer) }
        center.post(name: .CKAccountChanged, object: nil)
        await fulfillment(of: [rechecked], timeout: 1)
        account.releaseHeld(as: "alice")
        await refresh.value
        XCTAssertEqual(provider.state, .ready(try session("bob")), "The previous account's late answer is ignored")
    }

    func testDifferentAccountInvalidatesSavedBindingEvenWhenItCannotBeSaved() async throws {
        let cache = try directory()
        let account = AccountScript()
        let provider = try provider(cache: cache, lookup: account.lookup)
        await provider.refresh()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cache.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path) }

        account.set(name: "bob")
        await provider.refresh()
        XCTAssertEqual(provider.state, .setupRequired(.cacheUnavailable))
        account.set(status: .temporarilyUnavailable)
        await provider.refresh()
        XCTAssertEqual(provider.state, .temporarilyUnavailable(temporaryMessage),
            "The previous account's binding never returns after another account was verified")
    }

    func testEveryAccountStatusOnCachedAndUncachedState() async throws {
        let expected = try session("alice")
        let cases: [(CKAccountStatus, cached: ShopperSessionState, uncached: ShopperSessionState)] = [
            (.available, .ready(expected), .ready(expected)),
            (.noAccount, .setupRequired(.noAccount), .setupRequired(.noAccount)),
            (.restricted, .setupRequired(.restricted), .setupRequired(.restricted)),
            (.couldNotDetermine, .cached(expected), .temporarilyUnavailable(temporaryMessage)),
            (.temporarilyUnavailable, .cached(expected), .temporarilyUnavailable(temporaryMessage)),
        ]
        for (status, cachedOutcome, uncachedOutcome) in cases {
            let lookup = ShopperSessionProvider.AccountLookup(status: { status }, recordName: { "alice" })
            let cache = try directory()
            await (try provider(cache: cache)).refresh()
            let cached = try provider(cache: cache, lookup: lookup)
            await cached.refresh()
            XCTAssertEqual(cached.state, cachedOutcome, "cached, \(status)")

            let uncached = try provider(cache: directory(), lookup: lookup)
            await uncached.refresh()
            XCTAssertEqual(uncached.state, uncachedOutcome, "uncached, \(status)")

            let relaunched = try provider(cache: cache, lookup: offlineLookup)
            await relaunched.refresh()
            let definitive = status == .noAccount || status == .restricted
            XCTAssertEqual(relaunched.state, definitive ? .temporarilyUnavailable(offlineMessage) : .cached(expected),
                "Only a definitive answer invalidates the saved binding, \(status)")
        }
    }

    func testEveryLookupErrorClassOnCachedAndUncachedState() async throws {
        let expected = try session("alice")
        let errors: [Error] = [
            CKError(.networkUnavailable), CKError(.networkFailure), CKError(.serviceUnavailable),
            CKError(.notAuthenticated), CKError(.requestRateLimited), CocoaError(.fileReadUnknown),
        ]
        for error in errors {
            for failingStep in ["status", "recordName"] {
                let lookup = ShopperSessionProvider.AccountLookup(
                    status: { if failingStep == "status" { throw error }; return .available },
                    recordName: { throw error }
                )
                let cache = try directory()
                await (try provider(cache: cache)).refresh()
                let cached = try provider(cache: cache, lookup: lookup)
                await cached.refresh()
                XCTAssertEqual(cached.state, .cached(expected), "cached, \(error), \(failingStep)")

                let uncached = try provider(cache: directory(), lookup: lookup)
                await uncached.refresh()
                XCTAssertEqual(uncached.state, .temporarilyUnavailable(error.localizedDescription),
                    "uncached, \(error), \(failingStep)")
            }
        }

        let cache = try directory()
        await (try provider(cache: cache)).refresh()
        let sentinel = try provider(cache: cache, name: CKCurrentUserDefaultName)
        await sentinel.refresh()
        XCTAssertEqual(sentinel.state, .setupRequired(.invalidIdentity), "A malformed identity never authenticates")
        XCTAssertThrowsError(try sentinel.currentSession())
        let uncachedSentinel = try provider(cache: directory(), name: CKCurrentUserDefaultName)
        await uncachedSentinel.refresh()
        XCTAssertEqual(uncachedSentinel.state, .setupRequired(.invalidIdentity))
        let rejecting = ShopperSessionProvider.AccountLookup(status: { throw ShopperSessionError.invalidIdentity },
            recordName: { XCTFail("A rejected status must not fetch identity"); return "unused" })
        let rejectedCached = try provider(cache: cache, lookup: rejecting)
        await rejectedCached.refresh()
        XCTAssertEqual(rejectedCached.state, .setupRequired(.invalidIdentity), "cached, rejected status")
        let rejectedUncached = try provider(cache: directory(), lookup: rejecting)
        await rejectedUncached.refresh()
        XCTAssertEqual(rejectedUncached.state, .setupRequired(.invalidIdentity), "uncached, rejected status")
        let relaunched = try provider(cache: cache, lookup: offlineLookup)
        await relaunched.refresh()
        XCTAssertEqual(relaunched.state, .cached(expected), "A malformed answer is not a definitive account change")
    }

    func testTransientAnswersAfterVerificationKeepAccountButNeverReviveSignedOutBinding() async throws {
        let center = NotificationCenter()
        let account = AccountScript()
        let provider = try provider(cache: directory(), lookup: account.lookup, notifications: center)
        await provider.refresh()
        let expected = try session("alice")
        XCTAssertEqual(provider.state, .ready(expected))

        account.set(status: .temporarilyUnavailable)
        await provider.refresh()
        XCTAssertEqual(provider.state, .cached(expected), "A re-check that cannot answer keeps the verified account")

        account.set(status: .available)
        await provider.refresh()
        XCTAssertEqual(provider.state, .ready(expected))
        account.set(status: .couldNotDetermine)
        // The notification announces the unverified state synchronously; the re-check announces its answer.
        let answered = expectation(description: "Demotion and re-check answer")
        answered.expectedFulfillmentCount = 2
        let observer = provider.observeSessionChanges { state, _ in
            if state == .cached(expected) { answered.fulfill() }
        }
        center.post(name: .CKAccountChanged, object: nil)
        await fulfillment(of: [answered], timeout: 1)
        provider.removeSessionObserver(observer)
        XCTAssertEqual(try provider.currentSession(), expected, "An indeterminate re-check keeps the saved account")

        account.set(status: .noAccount)
        await provider.refresh()
        XCTAssertEqual(provider.state, .setupRequired(.noAccount))
        account.set(status: .temporarilyUnavailable)
        await provider.refresh()
        XCTAssertEqual(provider.state, .temporarilyUnavailable(temporaryMessage),
            "A transient answer cannot revive a binding a definitive answer invalidated")
        XCTAssertThrowsError(try provider.currentSession())
    }

    func testLaunchAfterTransientAnswerKeepsOperatingOnSavedAccount() async throws {
        let cache = try directory()
        await (try provider(cache: cache)).refresh()
        let expected = try session("alice")
        let transient = ShopperSessionProvider.AccountLookup(status: { .temporarilyUnavailable },
            recordName: { XCTFail("An unavailable account must not fetch identity"); return "unused" })
        let first = try provider(cache: cache, lookup: transient)
        await first.refresh()
        XCTAssertEqual(try first.currentSession(), expected)

        let second = try provider(cache: cache, lookup: transient)
        XCTAssertThrowsError(try second.currentSession(), "Reading a cache does not itself verify an account")
        await second.refresh()
        XCTAssertEqual(second.state, .cached(expected), "A transient answer did not invalidate the saved binding")

        let reconnected = try provider(cache: cache)
        await reconnected.refresh()
        XCTAssertEqual(reconnected.state, .ready(expected))
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

    func testTypedAccountEventsCaptureOutgoingIdentityOnSignOut() async throws {
        let cache = try directory()
        let center = NotificationCenter()
        let provider = try provider(cache: cache, notifications: center)
        await provider.refresh()
        let original = try provider.currentSession()

        let signedOut = expectation(description: "Exact signed-out account announced")
        let unavailable = try self.provider(cache: cache, lookup: .init(status: { .noAccount },
            recordName: { XCTFail("Signed out account cannot fetch identity"); return "unused" }),
            notifications: center)
        let signoutObserver = unavailable.observeSessionChanges { state, outgoing in
            guard state == .setupRequired(.noAccount) else { return }
            XCTAssertEqual(outgoing, original)
            signedOut.fulfill()
        }
        defer { unavailable.removeSessionObserver(signoutObserver) }
        await unavailable.refresh()
        await fulfillment(of: [signedOut], timeout: 1)
    }

    private var temporaryMessage: String { ShopperSessionError.temporarilyUnavailable.localizedDescription }
    private var offlineMessage: String { CKError(.networkUnavailable).localizedDescription }

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

/// A scripted account whose status and record name can change between lookups.
/// A record lookup can be held to model a late answer or to observe the state while it runs.
private final class AccountScript: @unchecked Sendable {
    private let lock = NSLock()
    private var status = CKAccountStatus.available
    private var name = "alice"
    private var holdNext: Bool
    private var held: CheckedContinuation<String, Never>?
    private var heldWaiter: XCTestExpectation?

    init(holdFirstLookup: Bool = false) { holdNext = holdFirstLookup }

    var lookup: ShopperSessionProvider.AccountLookup {
        .init(status: { self.lock.withLock { self.status } }, recordName: { await self.recordName() })
    }

    func set(status: CKAccountStatus? = nil, name: String? = nil) {
        lock.withLock {
            if let status { self.status = status }
            if let name { self.name = name }
        }
    }

    /// Fulfills `reached` once a lookup is held, so a lookup that never starts fails the wait instead of hanging.
    func fulfillWhenHeld(_ reached: XCTestExpectation) {
        let ready = lock.withLock { () -> Bool in
            if held != nil { return true }
            heldWaiter = reached
            return false
        }
        if ready { reached.fulfill() }
    }

    func holdNextLookup() { lock.withLock { holdNext = true } }

    /// Releases the held lookup with `name`, or with the current scripted name.
    func releaseHeld(as name: String? = nil) {
        let (continuation, answer) = lock.withLock { () -> (CheckedContinuation<String, Never>?, String) in
            defer { held = nil }
            return (held, name ?? self.name)
        }
        continuation?.resume(returning: answer)
    }

    private func recordName() async -> String {
        await withCheckedContinuation { continuation in
            let (immediate, waiter) = lock.withLock { () -> (String?, XCTestExpectation?) in
                guard holdNext else { return (name, nil) }
                holdNext = false
                held = continuation
                defer { heldWaiter = nil }
                return (nil, heldWaiter)
            }
            waiter?.fulfill()
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}
