import Foundation

// Executable specification only. String identities represent authenticated account/share
// bindings and CloudKit participant identities, not production authentication or API objects.
struct Scope: Codable, Equatable {
    let account: String
    let home: String
    let share: String
}

enum Role: String, Codable { case owner, contributor }
enum Acceptance: String, Codable { case pending, accepted }

struct Participant: Codable, Equatable {
    let id: String
    var acceptance: Acceptance
    var account: String? = nil
}

struct ShareSnapshot: Codable, Equatable {
    let scope: Scope
    let owner: String
    var participants: [Participant]
    var version: Int
    var groceryIDs: Set<String>
    var privateCartIDs: Set<String>
}

enum Action: Codable, Equatable {
    case inviteLink(String)
    case remove(Set<String>)
    case leave
}

enum Stage: String, Codable {
    case prepared, uncertain, applied, conflict, quarantined
}

struct Intent: Codable, Equatable {
    let id: UUID
    let scope: Scope
    let actor: String
    var expectedVersion: Int
    let action: Action
    var stage: Stage
}

enum ContractError: Error {
    case denied, changed, reusedID, invalidInvitation, missingIntent, unavailable
}

// This mock deliberately exposes export separately from local intent persistence. It
// models a version conflict as an error; it does NOT prove Core Data's cloud save policy.
final class MockCloud {
    var share: ShareSnapshot
    var available = true

    init(_ share: ShareSnapshot) { self.share = share }

    func acceptLink(_ invitation: String, as account: String) throws {
        guard let index = share.participants.firstIndex(where: { $0.id == invitation }) else {
            throw ContractError.denied
        }
        let participant = share.participants[index]
        guard participant.acceptance == .pending || participant.account == account else {
            throw ContractError.denied
        }
        share.participants[index].account = account
        share.participants[index].acceptance = .accepted
        share.version += 1
    }

    func apply(_ intent: Intent) throws {
        guard available else { throw ContractError.unavailable }
        guard intent.scope.home == share.scope.home,
              intent.scope.share == share.scope.share else { throw ContractError.denied }
        // Never permit a participant to mutate the owner's roster.
        switch intent.action {
        case .leave:
            guard intent.actor != share.owner,
                  share.participants.contains(where: { $0.account == intent.actor }) else {
                throw ContractError.denied
            }
        case .inviteLink, .remove:
            guard intent.actor == share.owner else { throw ContractError.denied }
        }
        guard intent.expectedVersion == share.version else { throw ContractError.changed }
        switch intent.action {
        case .inviteLink(let invitation):
            guard !invitation.isEmpty else { throw ContractError.invalidInvitation }
            if !share.participants.contains(where: { $0.id == invitation }) {
                share.participants.append(Participant(id: invitation, acceptance: .pending))
            }
        case .remove(let capturedIDs):
            // Exact captured set: a later newly invited participant is not an implicit target.
            share.participants.removeAll { capturedIDs.contains($0.id) }
        case .leave:
            // Shared-zone departure can return the participant to invited status.
            // It does not promise permanent capability revocation or roster deletion.
            for index in share.participants.indices where share.participants[index].account == intent.actor {
                share.participants[index].acceptance = .pending
            }
        }
        share.version += 1
        // Neither owner roster updates nor participant departure deletes the owner's graph.
    }
}

struct LocalCheckpoint: Codable {
    var intents: [Intent] = []
    var observedShare: ShareSnapshot?
    var sharedWorkingCopy: Set<String> = []
    var privateHistory: Set<String> = []
    var pendingHouseholdEffects: Set<String> = []
    var quarantinedEffects: Set<String> = []
}

final class SharingContract {
    private(set) var checkpoint: LocalCheckpoint
    private(set) var activeScope: Scope
    private(set) var actor: String
    private let url: URL

    init(url: URL, scope: Scope, actor: String, initial: LocalCheckpoint = LocalCheckpoint()) throws {
        self.url = url
        activeScope = scope
        self.actor = actor
        checkpoint = try FileManager.default.fileExists(atPath: url.path)
            ? JSONDecoder().decode(LocalCheckpoint.self, from: Data(contentsOf: url)) : initial
    }

    func prepare(id: UUID, snapshot: ShareSnapshot, action: Action) throws {
        guard snapshot.scope.home == activeScope.home,
              snapshot.scope.share == activeScope.share,
              activeScope.account == actor else { throw ContractError.denied }
        switch action {
        case .leave:
            guard snapshot.owner != actor,
                  snapshot.participants.contains(where: { $0.account == actor }) else { throw ContractError.denied }
        case .inviteLink(let invitation):
            guard snapshot.owner == actor else { throw ContractError.denied }
            guard !invitation.isEmpty else { throw ContractError.invalidInvitation }
        case .remove:
            guard snapshot.owner == actor else { throw ContractError.denied }
        }
        let intent = Intent(id: id, scope: activeScope, actor: actor,
                            expectedVersion: snapshot.version, action: action, stage: .prepared)
        if let existing = checkpoint.intents.first(where: { $0.id == id }) {
            guard existing.scope == intent.scope, existing.actor == intent.actor,
                  existing.action == intent.action else { throw ContractError.reusedID }
            return
        }
        var next = checkpoint
        next.intents.append(intent)
        try save(next)
    }

    // Represents the asynchronous boundary before persistUpdatedShare or participant leave.
    // A crash after marking uncertain must reconcile metadata, never blindly repeat the call.
    func beginExport(_ id: UUID) throws -> Intent {
        guard let index = checkpoint.intents.firstIndex(where: { $0.id == id }) else {
            throw ContractError.missingIntent
        }
        let intent = checkpoint.intents[index]
        guard intent.scope == activeScope, intent.actor == actor,
              intent.stage == .prepared else { throw ContractError.denied }
        var next = checkpoint
        next.intents[index].stage = .uncertain
        try save(next)
        return intent
    }

    func reconcile(_ id: UUID, observed: ShareSnapshot) throws {
        guard let index = checkpoint.intents.firstIndex(where: { $0.id == id }) else {
            throw ContractError.missingIntent
        }
        let intent = checkpoint.intents[index]
        var next = checkpoint
        guard intent.scope == activeScope, intent.actor == actor else {
            next.intents[index].stage = .quarantined
            try save(next)
            return
        }
        guard observed.scope.home == intent.scope.home,
              observed.scope.share == intent.scope.share else { throw ContractError.denied }
        try validateObservation(observed, for: intent)
        let satisfied: Bool
        switch intent.action {
        case .inviteLink(let target):
            satisfied = observed.participants.contains { $0.id == target }
        case .remove(let targets):
            satisfied = targets.isDisjoint(with: observed.participants.map(\.id))
        case .leave:
            satisfied = !observed.participants.contains { $0.account == actor && $0.acceptance == .accepted }
        }
        next.observedShare = observed
        next.intents[index].stage = satisfied ? .applied : .conflict
        if satisfied, intent.action == .leave {
            // Participant's local shared working copy only. Never the owner's graph,
            // another household, or account-private history/recovery.
            next.sharedWorkingCopy.removeAll()
            next.quarantinedEffects.formUnion(next.pendingHouseholdEffects)
            next.pendingHouseholdEffects.removeAll()
        }
        try save(next)
    }

    // Explicit reconfirmation after metadata established non-application. This is
    // not automatic replay; operation/participant identity and captured targets stay fixed.
    func reconfirm(_ id: UUID, observed: ShareSnapshot) throws {
        guard let index = checkpoint.intents.firstIndex(where: { $0.id == id }) else {
            throw ContractError.missingIntent
        }
        let intent = checkpoint.intents[index]
        guard intent.scope == activeScope, intent.actor == actor, intent.stage == .conflict,
              observed.scope.home == activeScope.home, observed.scope.share == activeScope.share else {
            throw ContractError.denied
        }
        switch intent.action {
        case .leave:
            guard observed.owner != actor,
                  observed.participants.contains(where: { $0.account == actor }) else { throw ContractError.denied }
        case .inviteLink, .remove:
            guard observed.owner == actor else { throw ContractError.denied }
        }
        try validateObservation(observed, for: intent)
        var next = checkpoint
        next.observedShare = observed
        next.intents[index].expectedVersion = observed.version
        next.intents[index].stage = .prepared
        try save(next)
    }

    func switchSession(scope: Scope, actor: String) {
        activeScope = scope
        self.actor = actor
    }

    func canDeliverInvitation(_ id: UUID) -> Bool {
        guard let intent = checkpoint.intents.first(where: { $0.id == id }),
              intent.scope == activeScope, intent.actor == actor, intent.stage == .applied else { return false }
        if case .inviteLink(let invitation) = intent.action,
           let observed = checkpoint.observedShare,
           observed.scope.home == intent.scope.home, observed.scope.share == intent.scope.share {
            return observed.participants.contains { $0.id == invitation && $0.acceptance == .pending }
        }
        return false
    }

    private func validateObservation(_ observed: ShareSnapshot, for intent: Intent) throws {
        guard observed.version >= intent.expectedVersion else { throw ContractError.changed }
        if let previous = checkpoint.observedShare,
           previous.scope.home == observed.scope.home, previous.scope.share == observed.scope.share,
           previous.version > observed.version {
            throw ContractError.changed
        }
    }

    private func save(_ next: LocalCheckpoint) throws {
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        checkpoint = next
    }
}
