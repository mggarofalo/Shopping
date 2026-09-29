import Foundation
import Observation

@MainActor
@Observable
final class WatchShoppingSession {
    private(set) var snapshot = WatchShoppingSnapshot()
    private(set) var isBusy = false
    var errorMessage: String?
    var sheet: WatchShoppingSheet?
    var checkoutPreview: WatchCheckoutPreview? {
        guard case .checkout(let preview) = sheet else { return nil }
        return preview
    }
    var result: WatchActionResult? {
        guard case .result(let result) = sheet else { return nil }
        return result
    }
    private let service: any WatchShoppingService
    private var reloadRequested = false
    private var isRefreshing = false
    private var refreshWaiter: CheckedContinuation<Void, Never>?
    private var authorityGeneration = 0

    init(service: any WatchShoppingService, initialSnapshot: WatchShoppingSnapshot = WatchShoppingSnapshot()) {
        snapshot = initialSnapshot
        self.service = service
        service.onChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .authorityInvalidated:
                self.authorityGeneration += 1
                self.snapshot = WatchShoppingSnapshot()
                self.sheet = nil
                self.errorMessage = nil
                self.requestReload()
            case .dataChanged:
                self.requestReload()
            case .syncChanged(let status):
                guard self.snapshot.syncStatus != status else { return }
                self.snapshot.syncStatus = status
            }
        }
    }

    private func requestReload() {
        reloadRequested = true
        guard !isBusy, !isRefreshing else { return }
        Task { await reload() }
    }

    func refreshHomeAccess() { service.refreshHomeAccess() }

    func reload(storeID: UUID? = nil) async {
        if let storeID {
            // Store selection is an explicit action: its caller may dismiss only
            // after the captured selection has actually finished.
            await run { .snapshot(try await self.service.load(storeID: storeID)) }
            return
        }
        guard !isBusy, !isRefreshing else {
            reloadRequested = true
            return
        }
        isRefreshing = true
        reloadRequested = false
        let selectedStoreID = snapshot.selectedStoreID
        let generation = authorityGeneration
        do {
            let value = try await service.load(storeID: selectedStoreID)
            if generation == authorityGeneration { applySnapshot(value) }
        } catch {
            // A background read must not dismiss feedback from an explicit action.
            if generation == authorityGeneration, errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }
        isRefreshing = false
        let waiter = refreshWaiter
        refreshWaiter = nil
        waiter?.resume()
        if reloadRequested, !isBusy { await reload() }
    }

    @discardableResult
    func perform(_ command: WatchShoppingCommand) async -> Bool {
        let authorityID = snapshot.authorityID
        let applied = await run { .snapshot(try await self.service.execute(command)) }
        return applied && snapshot.availability == .ready && snapshot.authorityID == authorityID
    }

    func prepareCheckout() async {
        guard snapshot.canCheckout, let storeID = snapshot.selectedStore?.id else { return }
        await run {
            let preview = try await self.service.captureCheckout(storeID: storeID)
            guard !preview.rows.isEmpty else {
                return .emptyCapture(try await self.service.load(storeID: storeID))
            }
            return .checkout(preview)
        }
    }

    func confirmCheckout(_ preview: WatchCheckoutPreview) async {
        guard checkoutPreview?.id == preview.id else { return }
        await run { .result(try await self.service.checkout(token: preview.token)) }
    }

    func restore(_ operation: WatchRecoveryOperation) async {
        guard operation.canRestore else { return }
        await run { .result(try await self.service.restore(token: operation.token)) }
    }

    private enum Update {
        case snapshot(WatchShoppingSnapshot)
        case emptyCapture(WatchShoppingSnapshot)
        case checkout(WatchCheckoutPreview)
        case result(WatchActionResult)
    }

    @discardableResult
    private func run(_ operation: () async throws -> Update) async -> Bool {
        guard !isBusy else {
            errorMessage = "Another cart action is still finishing. Try again when it completes."
            return false
        }
        // Reserve the action before waiting: imports coalesce behind it and a
        // second tap cannot enqueue another mutation using the same capture.
        isBusy = true
        errorMessage = nil
        let generation = authorityGeneration
        let authorityID = snapshot.authorityID
        if isRefreshing {
            await withCheckedContinuation { refreshWaiter = $0 }
        }
        var applied = false
        do {
            guard generation == authorityGeneration else { throw PersonalCartError.scopeChanged }
            guard snapshot.authorityID == authorityID else { throw PersonalCartError.scopeChanged }
            try Task.checkCancellation()
            let update = try await operation()
            if generation == authorityGeneration {
                apply(update)
                applied = true
            }
        } catch {
            // Do not resurrect old-account errors or UI after authority invalidation.
            if generation == authorityGeneration { errorMessage = error.localizedDescription }
        }
        isBusy = false
        if reloadRequested {
            reloadRequested = false
            await reload()
        }
        return applied && generation == authorityGeneration
    }

    private func apply(_ update: Update) {
        switch update {
        case .snapshot(let value):
            applySnapshot(value)
        case .emptyCapture(let value):
            applySnapshot(value)
            errorMessage = "Your cart changed. There are no eligible items to check out."
        case .checkout(let preview):
            sheet = .checkout(preview)
        case .result(let result):
            let sameAuthority = snapshot.authorityID == result.snapshot.authorityID
            applySnapshot(result.snapshot)
            if sameAuthority && snapshot.availability == .ready { sheet = .result(result) }
        }
    }

    private func applySnapshot(_ value: WatchShoppingSnapshot) {
        if value.availability != .ready || value.authorityID != snapshot.authorityID {
            sheet = nil
            errorMessage = nil
        }
        snapshot = value
    }
}
