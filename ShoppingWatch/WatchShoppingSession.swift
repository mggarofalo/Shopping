import Foundation
import Observation

@MainActor
@Observable
final class WatchShoppingSession {
    private var savedSnapshot = WatchShoppingSnapshot()
    private var pending: [WatchCartIntent] = []
    private var uncertain: [WatchCartIntent] = []
    private struct QuantityDraft { let quantity: Int? }
    private var failedAddDrafts: [String: QuantityDraft] = [:]
    var hasUnconfirmedAdd: Bool { !uncertain.isEmpty }
    var snapshot: WatchShoppingSnapshot {
        var value = savedSnapshot
        for intent in uncertain { value = intent.project(onto: value, uncertain: true) }
        for intent in pending { value = intent.project(onto: value, uncertain: false) }
        if !pending.isEmpty || !uncertain.isEmpty { value.canCheckout = false }
        return value
    }
    // Only scope changes, checkout and recovery reserve the whole session.
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
    private var isDraining = false
    private var completions: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private let incomingRefreshInterval: Duration
    private var lastSnapshotRead = ContinuousClock().now

    init(service: any WatchShoppingService, initialSnapshot: WatchShoppingSnapshot = WatchShoppingSnapshot(),
         incomingRefreshInterval: Duration = .seconds(2)) {
        self.incomingRefreshInterval = incomingRefreshInterval
        savedSnapshot = initialSnapshot
        self.service = service
        service.onChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .authorityInvalidated:
                self.authorityGeneration += 1
                self.discardIntents()
                self.savedSnapshot = WatchShoppingSnapshot()
                self.sheet = nil
                self.errorMessage = nil
                self.requestReload()
            case .dataChanged:
                self.requestReload()
            case .syncChanged(let status):
                guard self.savedSnapshot.syncStatus != status else { return }
                self.savedSnapshot.syncStatus = status
            }
        }
    }

    private func requestReload() {
        reloadRequested = true
        guard !isBusy, !isRefreshing, !isDraining else { return }
        scheduleRefresh()
    }

    // This only coalesces local projection reads. Durability starts immediately;
    // CloudKit owns export timing and has no application-controlled interval.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            await self.reload()
        }
    }

    func refreshHomeAccess() { service.refreshHomeAccess() }

    func quantityDraft(for item: WatchShoppingItem) -> Int? {
        if let draft = failedAddDrafts[item.occurrenceID] { return draft.quantity }
        return item.quantity
    }

    func reload(storeID: UUID? = nil) async {
        if let storeID {
            await run { .snapshot(try await self.service.load(storeID: storeID)) }
            return
        }
        guard !isBusy, !isRefreshing, !isDraining else {
            reloadRequested = true
            return
        }
        await readSnapshot()
        if reloadRequested, !isBusy, !isDraining { scheduleRefresh() }
    }

    private func readSnapshot() async {
        isRefreshing = true
        reloadRequested = false
        let generation = authorityGeneration
        do {
            let value = try await service.load(storeID: savedSnapshot.selectedStoreID)
            if generation == authorityGeneration {
                let hadUncertainty = !uncertain.isEmpty
                uncertain.removeAll()
                applySnapshot(value)
                if hadUncertainty { errorMessage = nil }
            }
        } catch {
            if generation == authorityGeneration, errorMessage == nil { errorMessage = error.localizedDescription }
        }
        lastSnapshotRead = ContinuousClock().now
        isRefreshing = false
        let waiter = refreshWaiter
        refreshWaiter = nil
        waiter?.resume()
    }

    // UI acceptance is separate from the durable result. Navigation can finish
    // while the writer works; subsequent independent taps remain available.
    @discardableResult
    func submit(_ command: WatchShoppingCommand) -> Bool {
        guard case .buyAnyway = command else { return enqueue(command) != nil }
        Task { await perform(command) }
        return false
    }

    @discardableResult
    func perform(_ command: WatchShoppingCommand) async -> Bool {
        if case .buyAnyway = command {
            let authorityID = snapshot.authorityID
            let applied = await run { .snapshot(try await self.service.execute(command)) }
            return applied && snapshot.availability == .ready && snapshot.authorityID == authorityID
        }
        guard let id = enqueue(command) else { return false }
        return await withCheckedContinuation { completions[id] = $0 }
    }

    private func enqueue(_ command: WatchShoppingCommand) -> UUID? {
        guard !isBusy else {
            errorMessage = "Another cart action is still finishing. Try again when it completes."
            return nil
        }
        let intent = WatchCartIntent(command: command, snapshot: snapshot, generation: authorityGeneration)
        let duplicate: Bool
        if case .setQuantity = command {
            // A reversal (2 → 3 → 2) is a new intent even while the first 2 is
            // still saving. Only the latest desired state can suppress a repeat.
            duplicate = pending.last(where: { $0.occurrenceID == intent.occurrenceID })?.command == command
        } else {
            duplicate = pending.contains(where: { $0.command == command })
        }
        guard !duplicate else { return nil }
        guard !uncertain.contains(where: { $0.occurrenceID == intent.occurrenceID }) else {
            errorMessage = "This item’s update could not be confirmed. Check the cart before changing it again."
            return nil
        }
        if uncertain.isEmpty { errorMessage = nil }
        pending.append(intent)
        if !isDraining {
            isDraining = true
            Task { await drain() }
        }
        return intent.id
    }

    private func drain() async {
        if isRefreshing { await withCheckedContinuation { refreshWaiter = $0 } }
        var failed: [(WatchCartIntent, String)] = []
        while !pending.isEmpty {
            // A continuous stream of local edits must not starve incoming state.
            // This is a local read checkpoint, not a CloudKit fetch or write delay.
            if reloadRequested, lastSnapshotRead.duration(to: ContinuousClock().now) >= incomingRefreshInterval {
                await readSnapshot()
            }
            guard let intent = pending.first else { break }
            guard intent.generation == authorityGeneration,
                  intent.authorityID == savedSnapshot.authorityID,
                  intent.storeID == savedSnapshot.selectedStoreID else {
                pending.removeFirst()
                errorMessage = PersonalCartError.scopeChanged.localizedDescription
                complete(intent.id, success: false)
                continue
            }
            do {
                let receipt = try await service.commit(intent.command)
                guard intent.generation == authorityGeneration,
                      pending.first?.id == intent.id else { continue }
                pending.removeFirst()
                failedAddDrafts.removeValue(forKey: intent.occurrenceID)
                switch receipt {
                case .snapshot(let value):
                    applySnapshot(value)
                    // Legacy/preview full snapshots are not causal receipts.
                    // Keep captured descendant tokens for service revalidation.
                case .item(let occurrenceID, let item, let mayRebase):
                    if occurrenceID == intent.occurrenceID {
                        savedSnapshot.replaceCartItem(occurrenceID: occurrenceID, item: item, section: intent.section)
                        if mayRebase, item != nil {
                            rebaseFollowing(intent, item: item)
                        } else {
                            cancelDescendants(of: intent)
                        }
                    }
                    reloadRequested = true
                }
                complete(intent.id, success: savedSnapshot.availability == .ready
                    && savedSnapshot.authorityID == intent.authorityID)
            } catch {
                guard intent.generation == authorityGeneration,
                      pending.first?.id == intent.id else { continue }
                pending.removeFirst()
                // Do not dispatch descendants through an uncertain causal token.
                let descendants = pending.filter { $0.occurrenceID == intent.occurrenceID }
                pending.removeAll { $0.occurrenceID == intent.occurrenceID }
                for descendant in descendants { complete(descendant.id, success: false) }
                if case .add(_, let quantity) = intent.command {
                    failedAddDrafts[intent.occurrenceID] = QuantityDraft(quantity: quantity)
                }
                if intent.item != nil { uncertain.append(intent) }
                failed.append((intent, error.localizedDescription))
                errorMessage = error.localizedDescription
            }
        }
        // Independent local commits precede reconciliation of uncertain writes.
        // The read can establish whether the failed call nevertheless committed.
        if !failed.isEmpty {
            await readSnapshot()
            for (intent, message) in failed where intent.generation == authorityGeneration {
                let unresolved = uncertain.contains { $0.id == intent.id }
                let applied = !unresolved && intent.matches(savedSnapshot)
                if unresolved {
                    errorMessage = "Your cart update could not be confirmed. It may already be saved. Check the cart before trying again."
                } else if !applied { errorMessage = message }
                complete(intent.id, success: applied)
            }
        }
        isDraining = false
        if !pending.isEmpty {
            isDraining = true
            Task { await drain() }
        } else if reloadRequested { scheduleRefresh() }
    }

    private func rebaseFollowing(_ finished: WatchCartIntent, item: WatchShoppingItem?) {
        guard let item, item.occurrenceID == finished.occurrenceID else { return }
        for index in pending.indices where pending[index].occurrenceID == finished.occurrenceID
            && pending[index].command.token == finished.command.token {
            pending[index].command = pending[index].command.replacingToken(item.commandToken)
            pending[index].item = item
        }
    }

    private func cancelDescendants(of intent: WatchCartIntent) {
        let descendants = pending.filter { $0.occurrenceID == intent.occurrenceID }
        pending.removeAll { $0.occurrenceID == intent.occurrenceID }
        for descendant in descendants { complete(descendant.id, success: false) }
        if !descendants.isEmpty {
            errorMessage = "This item changed. Check its quantity before trying again."
        }
    }

    private func complete(_ id: UUID, success: Bool) { completions.removeValue(forKey: id)?.resume(returning: success) }

    private func discardIntents() {
        refreshTask?.cancel()
        refreshTask = nil
        pending.removeAll()
        uncertain.removeAll()
        failedAddDrafts.removeAll()
        let waiting = completions.values
        completions.removeAll()
        for completion in waiting { completion.resume(returning: false) }
    }

    func prepareCheckout() async {
        guard snapshot.canCheckout, let storeID = snapshot.selectedStore?.id else { return }
        await run {
            let preview = try await self.service.captureCheckout(storeID: storeID)
            guard !preview.rows.isEmpty else { return .emptyCapture(try await self.service.load(storeID: storeID)) }
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
        guard !isBusy, pending.isEmpty, uncertain.isEmpty, !isDraining else {
            errorMessage = "Your cart updates are still finishing. Check the cart before trying this action."
            return false
        }
        isBusy = true
        errorMessage = nil
        let generation = authorityGeneration
        let authorityID = snapshot.authorityID
        if isRefreshing { await withCheckedContinuation { refreshWaiter = $0 } }
        var applied = false
        do {
            guard generation == authorityGeneration, snapshot.authorityID == authorityID else {
                throw PersonalCartError.scopeChanged
            }
            try Task.checkCancellation()
            let update = try await operation()
            if generation == authorityGeneration { apply(update); applied = true }
        } catch {
            if generation == authorityGeneration { errorMessage = error.localizedDescription }
        }
        isBusy = false
        if reloadRequested { await reload() }
        return applied && generation == authorityGeneration
    }

    private func apply(_ update: Update) {
        switch update {
        case .snapshot(let value): applySnapshot(value)
        case .emptyCapture(let value):
            applySnapshot(value)
            errorMessage = "Your cart changed. There are no eligible items to check out."
        case .checkout(let preview): sheet = .checkout(preview)
        case .result(let result):
            let sameAuthority = snapshot.authorityID == result.snapshot.authorityID
            applySnapshot(result.snapshot)
            if sameAuthority && snapshot.availability == .ready { sheet = .result(result) }
        }
    }

    private func applySnapshot(_ value: WatchShoppingSnapshot) {
        if value.availability != .ready || value.authorityID != savedSnapshot.authorityID {
            sheet = nil
            errorMessage = nil
            failedAddDrafts.removeAll()
        }
        // A refresh never rebases queued tokens onto a remote membership. Only
        // the acknowledgement of their own preceding local command can do so.
        savedSnapshot = value
    }
}

private struct WatchCartIntent {
    let id = UUID()
    var command: WatchShoppingCommand
    let generation: Int
    let authorityID: String?
    let storeID: UUID?
    let occurrenceID: String
    let section: WatchItemSection?
    var item: WatchShoppingItem?

    init(command: WatchShoppingCommand, snapshot: WatchShoppingSnapshot, generation: Int) {
        self.command = command
        self.generation = generation
        authorityID = snapshot.authorityID
        storeID = snapshot.selectedStoreID
        section = (snapshot.cartSections + snapshot.grocerySections).first { $0.items.contains { $0.commandToken == command.token } }
        item = section?.items.first { $0.commandToken == command.token }
        occurrenceID = item?.occurrenceID ?? command.token
    }

    func project(onto saved: WatchShoppingSnapshot, uncertain: Bool) -> WatchShoppingSnapshot {
        guard saved.availability == .ready, saved.authorityID == authorityID,
              saved.selectedStoreID == storeID, let original = item else { return saved }
        var value = saved
        var row = saved.item(id: occurrenceID) ?? original
        switch command {
        case .add(_, let quantity):
            if !row.isInOwnCart { row.quantity = quantity }
            row.isInOwnCart = true
        case .setQuantity(_, let quantity): row.quantity = quantity
        case .remove:
            value.replaceCartItem(occurrenceID: occurrenceID, item: nil, section: section)
            return value
        case .buyAnyway: return saved
        }
        row.commandToken = command.token
        row.isPendingAdd = true
        row.isAddUnconfirmed = uncertain
        row.canAdd = false
        row.canRemove = !uncertain
        row.canChangeQuantity = !uncertain
        row.canBuyAnyway = false
        value.replaceCartItem(occurrenceID: occurrenceID, item: row, section: section)
        return value
    }

    func matches(_ snapshot: WatchShoppingSnapshot) -> Bool {
        guard snapshot.availability == .ready, snapshot.authorityID == authorityID, item != nil else { return false }
        let row = snapshot.cartSections.flatMap(\.items).first { $0.occurrenceID == occurrenceID }
        switch command {
        case .add: return row != nil
        case .remove: return row == nil
        case .setQuantity(_, let quantity): return row != nil && row?.quantity == quantity
        case .buyAnyway: return false
        }
    }
}

private extension WatchShoppingSnapshot {
    mutating func replaceCartItem(occurrenceID: String, item: WatchShoppingItem?, section: WatchItemSection?) {
        grocerySections = grocerySections.compactMap { group in
            var group = group
            group.items.removeAll { $0.occurrenceID == occurrenceID }
            return group.items.isEmpty ? nil : group
        }
        for index in cartSections.indices { cartSections[index].items.removeAll { $0.occurrenceID == occurrenceID } }
        if let item, let section {
            if let index = cartSections.firstIndex(where: { $0.id == section.id }) {
                cartSections[index].items.append(item)
            } else {
                var group = section
                group.items = [item]
                cartSections.append(group)
            }
        }
        cartSections.removeAll { $0.items.isEmpty }
        for index in cartSections.indices {
            cartSections[index].items.sort {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.occurrenceID < $1.occurrenceID : comparison == .orderedAscending
            }
        }
        cartSections.sort {
            if $0.categoryRank != $1.categoryRank { return $0.categoryRank < $1.categoryRank }
            if $0.categoryOrder != $1.categoryOrder { return $0.categoryOrder < $1.categoryOrder }
            return $0.id < $1.id
        }
    }
}

private extension WatchShoppingCommand {
    var token: String {
        switch self {
        case .add(let token, _), .remove(let token), .setQuantity(let token, _), .buyAnyway(let token): token
        }
    }
    func replacingToken(_ token: String) -> Self {
        switch self {
        case .add(_, let quantity): .add(token: token, quantity: quantity)
        case .remove: .remove(token: token)
        case .setQuantity(_, let quantity): .setQuantity(token: token, quantity: quantity)
        case .buyAnyway: .buyAnyway(token: token)
        }
    }
}
