import Foundation

protocol HomeReplacementEffects: Sendable {
    func validateIntent(_ proposal: HomeReplacementProposal, target: ActiveHomeScope?) async throws
    func join(_ proposal: HomeReplacementProposal) async throws
    /// Returns only an imported, access-verified graph for the recorded share.
    func target(_ proposal: HomeReplacementProposal) async throws -> ActiveHomeScope?
    func activate(_ target: ActiveHomeScope, proposal: HomeReplacementProposal) async throws
    func prepareCleanup(_ proposal: HomeReplacementProposal) async throws -> HomeDeletionCommand
    func removeSource(_ command: HomeDeletionCommand, proposal: HomeReplacementProposal,
                      target: ActiveHomeScope) async throws -> HomeDeletionStatus
}

/// Joining, selection and deletion retain their existing services. This actor
/// owns only the durable replacement sequence and prevents overlapping callbacks.
actor HomeReplacementCoordinator {
    private let journal: HomeReplacementJournal
    private let effects: any HomeReplacementEffects
    private var running = false

    init(journal: HomeReplacementJournal, effects: any HomeReplacementEffects) {
        self.journal = journal
        self.effects = effects
    }

    func confirm(_ proposal: HomeReplacementProposal) throws -> HomeReplacementRecord {
        try journal.confirm(proposal)
    }

    func resume(_ id: UUID) async throws -> HomeReplacementRecord {
        guard !running else { throw HomeReplacementError.operationInProgress }
        guard var record = try journal.records().first(where: { $0.id == id }) else {
            throw HomeReplacementError.invalidProposal
        }
        guard !record.isTerminal else { return record }
        running = true
        defer { running = false }
        do {
            try Task.checkCancellation()
            try await effects.validateIntent(record.proposal, target: record.target)
            if record.stage == .confirmed { try advance(&record, to: .joining) }
            if record.stage == .joining {
                try await effects.join(record.proposal)
                try Task.checkCancellation()
                guard let target = try await effects.target(record.proposal) else { return record }
                guard ActiveHomeScope(session: record.proposal.session, graph: target.graph) == target,
                      target.graph != record.proposal.source.graph else { throw HomeReplacementError.invalidProposal }
                let previous = record
                record.target = target
                record.stage = .activating
                try journal.update(record, replacing: previous)
            }
            if record.stage == .activating {
                guard let target = record.target else { throw HomeReplacementError.invalidProposal }
                try await effects.activate(target, proposal: record.proposal)
                try await effects.validateIntent(record.proposal, target: target)
                try advance(&record, to: .targetActivated)
            }
            guard let target = record.target else { throw HomeReplacementError.invalidProposal }
            try Task.checkCancellation()
            try await effects.validateIntent(record.proposal, target: target)
            if record.stage == .targetActivated {
                let command = try await effects.prepareCleanup(record.proposal)
                let previous = record
                record.deletion = command
                record.stage = .cleanupPending
                try record.validate()
                try journal.update(record, replacing: previous)
            }
            guard let command = record.deletion else { throw HomeReplacementError.invalidProposal }
            try Task.checkCancellation()
            try await effects.validateIntent(record.proposal, target: target)
            let outcome = try await effects.removeSource(command, proposal: record.proposal, target: target)
            guard outcome.command == command else { throw HomeReplacementError.invalidProposal }
            if outcome.completed { try advance(&record, to: .completed) }
            return record
        } catch HomeReplacementError.intentChanged {
            // No new source effect may start after navigation/account invalidation.
            // A previously pending exact deletion remains reconcilable separately.
            if record.deletion == nil { try advance(&record, to: .sourceKept) }
            throw HomeReplacementError.intentChanged
        } catch HomeDeletionError.scopeChanged {
            if record.deletion == nil { try advance(&record, to: .sourceKept) }
            throw HomeDeletionError.scopeChanged
        }
    }

    private func advance(_ record: inout HomeReplacementRecord, to stage: HomeReplacementRecord.Stage) throws {
        let previous = record
        record.stage = stage
        try journal.update(record, replacing: previous)
    }
}
