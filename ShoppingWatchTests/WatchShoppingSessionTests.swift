import XCTest
@testable import ShoppingWatch

@MainActor
final class WatchShoppingSessionTests: XCTestCase {
    func testNormalLaunchRequiresSetupWithoutFixtures() async {
        let session = WatchShoppingSession(service: UnavailableWatchShoppingService())
        await session.reload()
        guard case .setupRequired = session.snapshot.availability else {
            return XCTFail("A production launch must not expose fixture groceries")
        }
        XCTAssertTrue(session.snapshot.stores.isEmpty)
        XCTAssertFalse(session.snapshot.canCheckout)
    }

    func testFailedSaveRetainsSnapshotAndOpaqueCommand() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let before = session.snapshot
        service.shouldFail = true
        let command = WatchShoppingCommand.remove(token: "account-bound:membership-generation:revision")
        await session.perform(command)
        XCTAssertEqual(service.commands, [command])
        XCTAssertEqual(session.snapshot, before)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(session.isBusy)
    }

    func testCheckoutRetryKeepsCapturedRowsAndSameToken() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        let preview = try XCTUnwrap(session.checkoutPreview)
        service.value.cartSections = [] // A later snapshot must not redefine the captured operation.
        await session.reload()
        XCTAssertEqual(session.checkoutPreview, preview)
        service.shouldFail = true
        await session.confirmCheckout(preview)
        XCTAssertEqual(session.checkoutPreview, preview)
        XCTAssertEqual(service.checkoutTokens, [preview.token])
        service.shouldFail = false
        await session.confirmCheckout(preview)
        XCTAssertEqual(service.checkoutTokens, [preview.token, preview.token])
        XCTAssertNil(session.checkoutPreview)
        XCTAssertNotNil(session.result)
        XCTAssertNil(session.errorMessage)
    }

    func testOfflineSnapshotAllowsOwnerRemovalAndRestoreUsesExactToken() async {
        let service = SpyService()
        service.value.statusMessage = "Saved on watch"
        service.value.canCheckout = false
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.perform(.remove(token: "orphaned-own-membership"))
        XCTAssertEqual(service.commands, [.remove(token: "orphaned-own-membership")])
        let operation = WatchRecoveryOperation(id: UUID(), token: "owner-scoped-receipt", storeName: "Costco", summary: "2 items", canRestore: true)
        await session.restore(operation)
        XCTAssertEqual(service.restoreTokens, [operation.token])
    }

    func testEmptyCaptureRefreshesInsteadOfShowingFalseConfirmation() async {
        let service = SpyService()
        service.captureRows = []
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        XCTAssertNil(session.checkoutPreview)
        XCTAssertEqual(session.errorMessage, "Your cart changed. There are no eligible items to check out.")
        XCTAssertTrue(service.checkoutTokens.isEmpty)
    }

    func testUnavailableAndChangedAuthorityClearOldCheckout() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        service.value.availability = .setupRequired("Sign in again")
        await session.reload()
        XCTAssertNil(session.checkoutPreview)
        XCTAssertNil(session.result)

        service.value = WatchPreviewService.sample
        service.value.canCheckout = true
        await session.reload()
        await session.prepareCheckout()
        XCTAssertNotNil(session.checkoutPreview)
        service.value.authorityID = "different-account"
        await session.reload()
        XCTAssertNil(session.checkoutPreview)
    }

    func testAuthorityInvalidationDiscardsSuspendedCheckoutResult() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        let preview = try XCTUnwrap(session.checkoutPreview)
        let previousSnapshot = session.snapshot
        let started = expectation(description: "Checkout suspended")
        service.suspendCheckout = true
        service.checkoutStarted = { started.fulfill() }
        let pending = Task { await session.confirmCheckout(preview) }
        await fulfillment(of: [started], timeout: 2)

        service.value.authorityID = "new-account"
        service.value.cartSections = []
        service.onChange?(.authorityInvalidated)
        XCTAssertNil(session.sheet)
        XCTAssertEqual(session.snapshot.availability, .loading)
        XCTAssertTrue(session.snapshot.cartSections.isEmpty)
        await Task.yield()
        service.checkoutContinuation?.resume(returning: WatchActionResult(id: UUID(), title: "Old account result", message: "Must not reappear", skippedNames: [], snapshot: previousSnapshot))
        await pending.value
        XCTAssertEqual(session.snapshot.authorityID, "new-account")
        XCTAssertTrue(session.snapshot.cartSections.isEmpty)
        XCTAssertNil(session.result)
        XCTAssertNil(session.errorMessage)
    }

    func testInvalidSelectionCannotCaptureAndPadlocksHaveDistinctMeaning() async {
        let service = SpyService()
        service.value.selectedStoreID = UUID()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        XCTAssertEqual(service.captureCount, 0)
        XCTAssertNil(session.checkoutPreview)
        XCTAssertEqual(WatchPurchaseRule.onlyHere.symbol, "lock.fill")
        XCTAssertEqual(WatchPurchaseRule.canBuyHere.symbol, "lock.open.fill")
    }
}

@MainActor
private final class SpyService: WatchShoppingService {
    var onChange: (@MainActor (WatchServiceChange) -> Void)?
    var value = WatchPreviewService.sample
    var shouldFail = false
    var commands: [WatchShoppingCommand] = []
    var checkoutTokens: [String] = []
    var restoreTokens: [String] = []
    var suspendCheckout = false
    var checkoutStarted: (() -> Void)?
    var checkoutContinuation: CheckedContinuation<WatchActionResult, Never>?
    var captureCount = 0
    var captureRows = WatchPreviewService.previewCheckout.rows

    init() { value.canCheckout = true }
    func load(storeID: UUID?) async throws -> WatchShoppingSnapshot { value }
    func execute(_ command: WatchShoppingCommand) async throws -> WatchShoppingSnapshot {
        commands.append(command)
        if shouldFail { throw failure }
        return value
    }
    func captureCheckout(storeID: UUID) async throws -> WatchCheckoutPreview {
        captureCount += 1
        return WatchCheckoutPreview(id: UUID(), token: "captured-scope", storeName: "Costco", rows: captureRows)
    }
    func checkout(token: String) async throws -> WatchActionResult {
        checkoutTokens.append(token)
        if suspendCheckout {
            return await withCheckedContinuation { continuation in
                checkoutContinuation = continuation
                checkoutStarted?()
            }
        }
        if shouldFail { throw failure }
        return WatchActionResult(id: UUID(), title: "1 cleared", message: "1 changed item skipped", skippedNames: ["Oat milk"], snapshot: value)
    }
    func restore(token: String) async throws -> WatchActionResult {
        restoreTokens.append(token)
        return WatchActionResult(id: UUID(), title: "Restored", message: "Saved on watch", skippedNames: [], snapshot: value)
    }
    private var failure: NSError { NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save failed"]) }
}
