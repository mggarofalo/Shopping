import Foundation

struct HomeShareIdentity: Codable, Equatable, Sendable {
    let recordName: String
    let zoneName: String
    let zoneOwnerName: String
}

struct PreparedHomeShare: Equatable, Sendable {
    let scope: ActiveHomeScope
    let identity: HomeShareIdentity
}

protocol HomeShareTransport: Sendable {
    func existingShare(for scope: ActiveHomeScope) async throws -> HomeShareIdentity?
    func createShare(for scope: ActiveHomeScope) async throws -> HomeShareIdentity
}

enum HomeSharingError: LocalizedError {
    case unavailable, ownerRequired, scopeChanged, conflictingShare, unexpectedPublicAccess
    case retryRequired, associationPending, missingResult

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Sharing is unavailable until this home is connected to iCloud."
        case .ownerRequired: return "Only the home’s owner can prepare or manage sharing."
        case .scopeChanged: return "Your home or iCloud account changed. Reopen sharing in its original home."
        case .conflictingShare: return "This home’s sharing information does not match. Your groceries have been retained."
        case .unexpectedPublicAccess: return "This home has unexpected public sharing permissions. Its invitations are unavailable."
        case .retryRequired: return "Sharing preparation was interrupted. Retry preparing sharing for this same home."
        case .associationPending: return "The existing share is still being recovered. Wait for iCloud and check again."
        case .missingResult: return "iCloud did not return the prepared share. Check again before inviting someone."
        }
    }
}

/// One bootstrap owns this gate across home/account switches. Cancelling a waiter never
/// starts another native request while the original callback remains outstanding.
actor HomeShareProvisioner {
    private var operations: [ActiveHomeScope: Task<PreparedHomeShare, Error>] = [:]
    private(set) var activeRequestCount = 0

    func prepare(scope: ActiveHomeScope, journalURL: URL, transport: any HomeShareTransport,
                 retryInterrupted: Bool = false) async throws -> PreparedHomeShare {
        activeRequestCount += 1
        defer { activeRequestCount -= 1 }
        if let operation = operations[scope] { return try await operation.value }
        let operation = Task {
            try await Self.perform(scope: scope, journal: HomeShareProvisioningJournal(url: journalURL),
                transport: transport, retryInterrupted: retryInterrupted)
        }
        operations[scope] = operation
        defer { operations.removeValue(forKey: scope) }
        return try await operation.value
    }

    private static func perform(scope: ActiveHomeScope, journal: HomeShareProvisioningJournal,
                                transport: any HomeShareTransport, retryInterrupted: Bool) async throws -> PreparedHomeShare {
        // Lookup validates account, owner authority and the entire graph, even on replay.
        let existing = try await transport.existingShare(for: scope)
        let intent = try journal.begin(scope: scope)
        if let existing {
            try journal.associate(existing, scope: scope)
            return PreparedHomeShare(scope: scope, identity: existing)
        }
        guard intent.identity == nil else { throw HomeSharingError.associationPending }
        guard !intent.attempted || retryInterrupted else { throw HomeSharingError.retryRequired }
        try journal.markAttempted(scope: scope)
        do {
            let identity = try await transport.createShare(for: scope)
            try journal.associate(identity, scope: scope)
            return PreparedHomeShare(scope: scope, identity: identity)
        } catch {
            let original = error
            // A callback error is not evidence that the managed association did not commit.
            if let recovered = try await transport.existingShare(for: scope) {
                try journal.associate(recovered, scope: scope)
                return PreparedHomeShare(scope: scope, identity: recovered)
            }
            throw original
        }
    }
}
