import Foundation

@MainActor
final class HomeNamedInvitationsModel: ObservableObject {
    let scope: ActiveHomeScope
    private let actions: HomeNamedInvitationActions?
    @Published private(set) var records: [HomeInvitationRecord] = []
    @Published private(set) var operation: String?
    @Published private(set) var operatingID: UUID?
    @Published private(set) var error: String?
    @Published private(set) var refreshError: String?
    @Published private(set) var needsPreparationRetry = false
    @Published var delivery: HomeInvitationDelivery?
    private var generation = 0
    private var active = true
    private var loadTask: Task<Void, Never>?
    private var loadID: UUID?
    private var loadGeneration: Int?
    private var refreshRequested = false
    private var sharingID: UUID?
    private var sharingRecordID: UUID?
    var busy: Bool { operation != nil }
    var available: Bool { actions != nil }

    init(scope: ActiveHomeScope, actions: HomeNamedInvitationActions?) {
        self.scope = scope
        self.actions = actions
    }

    func activate() { active = true }
    func retire() {
        active = false
        generation += 1
        delivery = nil
        sharingID = nil
        sharingRecordID = nil
        operation = nil
        operatingID = nil
    }

    func refresh() async {
        guard active, let actions else { return }
        guard !busy else { refreshRequested = true; return }
        if let loadTask {
            if loadGeneration != generation { refreshRequested = true }
            await loadTask.value
            return
        }
        let request = generation
        let id = UUID()
        loadID = id
        loadGeneration = request
        refreshRequested = false
        let task = Task { [self] in
            do {
                let values = try await actions.load()
                if active, generation == request {
                    guard values.allSatisfy(matchesScope) else { throw HomeMembershipError.scopeChanged }
                    records = values
                    refreshError = nil
                }
            } catch {
                if active, generation == request { refreshError = HomeSharingErrorPresentation.message(error) }
            }
            completeLoad(id)
            if refreshRequested, active, !busy { await refresh() }
        }
        loadTask = task
        await task.value
    }

    private func completeLoad(_ id: UUID) {
        guard loadID == id else { return }
        loadTask = nil
        loadID = nil
        loadGeneration = nil
    }

    func prepare(name: String) async -> HomeInvitationRecord? {
        guard active, !busy, let actions else { return nil }
        let request = begin("Saving invitation…")
        var prepared: HomeInvitationRecord?
        do {
            let record = try await actions.prepare(name)
            guard current(request), matchesScope(record) else { throw HomeMembershipError.scopeChanged }
            let alreadyKnown = records.contains { $0.id == record.id }
            prepared = record
            upsert(record)
            // Selecting an existing invitation is navigation, not another submission.
            if record.participantIDs.isEmpty && !alreadyKnown {
                operatingID = record.id
                operation = "Creating invitation…"
                let result = try await actions.create(record.id, false)
                guard current(request), result.scope == scope else { throw HomeMembershipError.scopeChanged }
            }
        } catch { recordFailure(error, request: request) }
        guard current(request) else { return nil }
        await finish(request)
        return prepared
    }

    func createOrShare(_ record: HomeInvitationRecord, share: Bool) async {
        guard active, !busy, let actions else { return }
        let request = begin(share ? "Preparing invitation…" : "Creating invitation…", id: record.id)
        do {
            let result = try await actions.create(record.id, needsPreparationRetry)
            guard current(request), result.scope == scope else { throw HomeMembershipError.scopeChanged }
            needsPreparationRetry = false
            if share { sharingID = result.id; sharingRecordID = record.id; delivery = result }
        } catch { recordFailure(error, request: request) }
        await finish(request)
    }

    func rename(_ record: HomeInvitationRecord, name: String) async -> Bool {
        guard active, !busy, let actions else { return false }
        let request = begin("Saving invitation name…", id: record.id)
        var saved = false
        do { try await actions.rename(record.id, name); saved = current(request) }
        catch { recordFailure(error, request: request) }
        await finish(request)
        return saved
    }

    func label(participantID: String, name: String) async -> HomeInvitationRecord? {
        guard active, !busy, let actions else { return nil }
        let request = begin("Saving invitation name…")
        var saved: HomeInvitationRecord?
        do {
            let record = try await actions.label(participantID, name)
            guard current(request), matchesScope(record) else { throw HomeMembershipError.scopeChanged }
            upsert(record)
            saved = record
        } catch { recordFailure(error, request: request) }
        await finish(request)
        return saved
    }

    func prepareCancellation(_ record: HomeInvitationRecord, participantID: String? = nil) async -> HomeMembershipRemovalConfirmation? {
        guard active, !busy, let actions else { return nil }
        let request = begin("Checking invitation…", id: record.id)
        var result: HomeMembershipRemovalConfirmation?
        do {
            let confirmation: HomeMembershipRemovalConfirmation
            if let participantID { confirmation = try await actions.cancelLink(record.id, participantID) }
            else { confirmation = try await actions.cancel(record.id) }
            guard current(request), confirmation.removal.origin == scope else { throw HomeMembershipError.scopeChanged }
            result = confirmation
        } catch { recordFailure(error, request: request) }
        await finish(request)
        return result
    }

    func finishedSharing(_ value: HomeInvitationDelivery, completed: Bool, failure: Error?) async {
        guard active, value.scope == scope, sharingID == value.id else { return }
        let recordID = sharingRecordID
        sharingID = nil
        sharingRecordID = nil
        delivery = nil
        if let failure { error = HomeSharingErrorPresentation.message(failure); return }
        guard completed, let actions, let recordID else { return }
        // A system-sheet callback is an observation, not a competing user command.
        // It must not invalidate a rename/create already awaiting its durable result.
        let request = generation
        do { try await actions.handoff(recordID) }
        catch { recordFailure(error, request: request) }
        if current(request) { await refresh() }
    }

    func clearError() { error = nil }

    func discard(_ record: HomeInvitationRecord) async -> Bool {
        guard active, !busy, let actions else { return false }
        let request = begin("Removing draft…", id: record.id)
        var saved = false
        do { try await actions.discard(record.id); saved = current(request) }
        catch { recordFailure(error, request: request) }
        await finish(request)
        return saved
    }

    private func matchesScope(_ record: HomeInvitationRecord) -> Bool {
        record.origin.accountBinding == scope.accountBinding && record.origin.containerIdentifier == scope.containerIdentifier
            && record.origin.environment == scope.environment && record.origin.graph.householdID == scope.graph.householdID
            && record.origin.graph.listID == scope.graph.listID
    }

    private func upsert(_ record: HomeInvitationRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
    }

    private func begin(_ label: String, id: UUID? = nil) -> Int {
        generation += 1
        operation = label
        operatingID = id
        error = nil
        return generation
    }

    private func current(_ request: Int) -> Bool { active && generation == request }

    private func recordFailure(_ failure: Error, request: Int) {
        guard current(request) else { return }
        error = HomeSharingErrorPresentation.message(failure)
        if case HomeSharingError.retryRequired = failure { needsPreparationRetry = true }
    }

    private func finish(_ request: Int) async {
        guard current(request) else { return }
        // Drain a read captured before this command, then publish its private result.
        await loadTask?.value
        guard current(request) else { return }
        operation = nil
        operatingID = nil
        await refresh()
    }
}
