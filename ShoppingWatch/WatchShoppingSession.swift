import Foundation
import Observation

@MainActor
@Observable
final class WatchShoppingSession {
    private var savedSnapshot = WatchShoppingSnapshot()
    private var pendingAdd: PendingAdd?
    var hasUnconfirmedAdd: Bool { pendingAdd?.isUnconfirmed == true }
    var snapshot: WatchShoppingSnapshot {
        guard let pendingAdd else { return savedSnapshot }
        return pendingAdd.project(onto: savedSnapshot)
    }
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
        savedSnapshot = initialSnapshot
        self.service = service
        service.onChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .authorityInvalidated:
                self.authorityGeneration += 1
                self.pendingAdd = nil
                self.savedSnapshot = WatchShoppingSnapshot()
                self.sheet = nil
                self.errorMessage = nil
                self.requestReload()
            case .dataChanged:
                self.requestReload()
            case .syncChanged(let status):
                guard self.snapshot.syncStatus != status else { return }
                self.savedSnapshot.syncStatus = status
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
            if generation == authorityGeneration {
                if hasUnconfirmedAdd { pendingAdd = nil; errorMessage = nil }
                applySnapshot(value)
            }
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
        // A repeated accessibility action can arrive even after its row disappears.
        // Coalesce the exact pending add without presenting a spurious error.
        if pendingAdd?.command == command { return false }
        let authorityID = snapshot.authorityID
        let applied = await run(optimisticCommand: command) {
            .snapshot(try await self.service.execute(command))
        }
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
    private func run(optimisticCommand: WatchShoppingCommand? = nil, _ operation: () async throws -> Update) async -> Bool {
        guard !hasUnconfirmedAdd else {
            errorMessage = "Your last cart update could not be confirmed. Check the cart before trying another action."
            return false
        }
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
        pendingAdd = optimisticCommand.flatMap { PendingAdd(command: $0, snapshot: savedSnapshot) }
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
                pendingAdd = nil
                apply(update)
                applied = true
            }
        } catch {
            // Do not resurrect old-account errors or UI after authority invalidation.
            if generation == authorityGeneration {
                // execute may have saved successfully before its final read failed.
                // Reconcile while the pending row remains visible, then remove the
                // overlay. Never restore an entire captured (possibly old) snapshot.
                if let pending = pendingAdd {
                    do {
                        let latest = try await service.load(storeID: savedSnapshot.selectedStoreID)
                        if generation == authorityGeneration {
                            pendingAdd = nil
                            applySnapshot(latest)
                            applied = latest.availability == .ready && latest.authorityID == authorityID
                                && latest.cartSections.flatMap(\.items).contains { $0.occurrenceID == pending.item.occurrenceID }
                            if !applied { errorMessage = error.localizedDescription }
                        }
                    } catch {
                        if generation == authorityGeneration, pendingAdd != nil {
                            pendingAdd?.isUnconfirmed = true
                            errorMessage = "Your cart update could not be confirmed. It may already be saved. Check the cart before trying again."
                        }
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
            }
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
        if value.availability != .ready || value.authorityID != savedSnapshot.authorityID
            || value.selectedStoreID != savedSnapshot.selectedStoreID {
            pendingAdd = nil
        }
        savedSnapshot = value
    }
}

private struct PendingAdd {
    let command: WatchShoppingCommand
    let authorityID: String?
    let storeID: UUID?
    let section: WatchItemSection
    let item: WatchShoppingItem
    var isUnconfirmed = false

    init?(command: WatchShoppingCommand, snapshot: WatchShoppingSnapshot) {
        guard case .add(let token, let quantity) = command,
              snapshot.availability == .ready,
              let section = snapshot.grocerySections.first(where: { $0.items.contains { $0.commandToken == token && $0.canAdd } }),
              var item = section.items.first(where: { $0.commandToken == token && $0.canAdd }),
              !item.isInOwnCart else { return nil }
        self.command = command
        authorityID = snapshot.authorityID
        storeID = snapshot.selectedStoreID
        self.section = section
        item.quantity = quantity
        item.isInOwnCart = true
        item.isPendingAdd = true
        item.canAdd = false
        item.canRemove = false
        item.canChangeQuantity = false
        item.canBuyAnyway = false
        self.item = item
    }

    func project(onto saved: WatchShoppingSnapshot) -> WatchShoppingSnapshot {
        guard saved.availability == .ready, saved.authorityID == authorityID,
              saved.selectedStoreID == storeID else { return saved }
        var value = saved
        value.grocerySections = value.grocerySections.compactMap { section in
            var section = section
            section.items.removeAll { $0.occurrenceID == item.occurrenceID }
            return section.items.isEmpty ? nil : section
        }
        // An older in-flight refresh may already observe this occurrence in the
        // private cart (with a different membership ID and quantity). Keep that
        // authoritative membership; the writer also preserves an existing claim.
        for sectionIndex in value.cartSections.indices {
            if let rowIndex = value.cartSections[sectionIndex].items.firstIndex(where: { $0.occurrenceID == item.occurrenceID }) {
                value.cartSections[sectionIndex].items[rowIndex].isPendingAdd = true
                value.cartSections[sectionIndex].items[rowIndex].isAddUnconfirmed = isUnconfirmed
                value.cartSections[sectionIndex].items[rowIndex].canRemove = false
                value.cartSections[sectionIndex].items[rowIndex].canChangeQuantity = false
                value.cartSections[sectionIndex].items[rowIndex].canBuyAnyway = false
                value.canCheckout = false
                return value
            }
        }
        var item = item
        item.isAddUnconfirmed = isUnconfirmed
        if let index = value.cartSections.firstIndex(where: { $0.id == section.id }) {
            value.cartSections[index].items.append(item)
            value.cartSections[index].items.sort {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.occurrenceID < $1.occurrenceID : comparison == .orderedAscending
            }
        } else {
            var pendingSection = section
            pendingSection.items = [item]
            value.cartSections.append(pendingSection)
            value.cartSections.sort {
                if $0.categoryRank != $1.categoryRank { return $0.categoryRank < $1.categoryRank }
                if $0.categoryOrder != $1.categoryOrder { return $0.categoryOrder < $1.categoryOrder }
                return $0.id < $1.id
            }
        }
        value.canCheckout = false
        return value
    }
}
