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
    private var authorityGeneration = 0

    init(service: any WatchShoppingService, initialSnapshot: WatchShoppingSnapshot = WatchShoppingSnapshot()) {
        snapshot = initialSnapshot
        self.service = service
        service.onChange = { [weak self] change in
            guard let self else { return }
            if change == .authorityInvalidated {
                self.authorityGeneration += 1
                self.snapshot = WatchShoppingSnapshot()
                self.sheet = nil
                self.errorMessage = nil
            }
            Task { await self.reload() }
        }
    }

    func reload(storeID: UUID? = nil) async {
        guard !isBusy else {
            reloadRequested = true
            return
        }
        await run { .snapshot(try await self.service.load(storeID: storeID ?? self.snapshot.selectedStoreID)) }
    }

    func perform(_ command: WatchShoppingCommand) async {
        await run { .snapshot(try await self.service.execute(command)) }
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

    private func run(_ operation: () async throws -> Update) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let generation = authorityGeneration
        do {
            let update = try await operation()
            if generation == authorityGeneration { apply(update) }
        } catch {
            // Do not resurrect old-account errors or UI after authority invalidation.
            if generation == authorityGeneration { errorMessage = error.localizedDescription }
        }
        isBusy = false
        if reloadRequested {
            reloadRequested = false
            await reload()
        }
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
