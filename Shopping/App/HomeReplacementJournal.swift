import Foundation

/// Account-local intent survives callback duplication and interruption. The
/// deletion command is persisted before its first execution and never widened.
final class HomeReplacementJournal: @unchecked Sendable {
    private static let lock = NSLock()
    let url: URL
    let session: ShopperSession

    init(url: URL, session: ShopperSession) { self.url = url; self.session = session }

    func records() throws -> [HomeReplacementRecord] {
        try Self.lock.withLock { try load() }
    }

    func confirm(_ proposal: HomeReplacementProposal) throws -> HomeReplacementRecord {
        try Self.lock.withLock {
            try proposal.validate()
            guard proposal.session == session else { throw HomeReplacementError.invalidProposal }
            var records = try load()
            if let existing = records.first(where: { $0.id == proposal.id }) {
                guard existing.proposal == proposal else { throw HomeReplacementError.invalidProposal }
                return existing
            }
            guard !records.contains(where: { !$0.isTerminal }) else { throw HomeReplacementError.operationInProgress }
            let record = HomeReplacementRecord(proposal: proposal, stage: .confirmed)
            records.append(record)
            try save(records)
            return record
        }
    }

    func update(_ next: HomeReplacementRecord, replacing previous: HomeReplacementRecord) throws {
        try Self.lock.withLock {
            try next.validate()
            guard next.proposal == previous.proposal, next.proposal.session == session,
                  previous.deletion == nil || next.deletion == previous.deletion,
                  previous.target == nil || next.target == previous.target,
                  Self.permits(previous.stage, next.stage),
                  !previous.isTerminal || next == previous else { throw HomeReplacementError.invalidProposal }
            var records = try load()
            guard let index = records.firstIndex(where: { $0 == previous }) else { throw HomeReplacementError.intentChanged }
            records[index] = next
            try save(records)
        }
    }

    private static func permits(_ old: HomeReplacementRecord.Stage, _ next: HomeReplacementRecord.Stage) -> Bool {
        if old == next { return true }
        switch (old, next) {
        case (.confirmed, .joining), (.confirmed, .sourceKept),
             (.joining, .activating), (.joining, .sourceKept),
             (.activating, .targetActivated), (.activating, .sourceKept),
             (.targetActivated, .cleanupPending), (.targetActivated, .sourceKept),
             (.cleanupPending, .completed), (.cleanupPending, .sourceKept): return true
        default: return false
        }
    }

    private func load() throws -> [HomeReplacementRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([HomeReplacementRecord].self, from: Data(contentsOf: url))
        for value in values {
            try value.validate()
            guard value.proposal.session == session else { throw HomeReplacementError.invalidProposal }
        }
        guard Set(values.map(\.id)).count == values.count, values.filter({ !$0.isTerminal }).count <= 1 else { throw HomeReplacementError.invalidProposal }
        return values
    }

    private func save(_ records: [HomeReplacementRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }
}
