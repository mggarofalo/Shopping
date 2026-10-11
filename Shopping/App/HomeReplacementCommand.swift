import Foundation

struct HomeReplacementProposal: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let source: LocalStarterEvidence
    let sourceURL: URL
    let invitationID: UUID
    let invitation: HomeInvitationIdentity
    let session: ShopperSession
    let navigationIntent: UUID

    func validate() throws {
        guard id != PersistenceModel.unsetID, invitationID != PersistenceModel.unsetID,
              navigationIntent != PersistenceModel.unsetID, source.version == 1,
              source.creationID != PersistenceModel.unsetID, source.transactionNumber > 0,
              !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.graph.storeIdentifier.isEmpty, URL(string: source.graph.rootURI)?.scheme == "x-coredata",
              source.graph.householdID != PersistenceModel.unsetID, source.graph.listID != PersistenceModel.unsetID,
              sourceURL.isFileURL, session.isWellFormed,
              invitation.containerIdentifier == session.containerIdentifier,
              invitation.environment == session.environment else { throw HomeReplacementError.invalidProposal }
    }
}

struct HomeReplacementRecord: Codable, Equatable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        case confirmed, joining, activating, targetActivated, cleanupPending, completed, sourceKept
    }
    let proposal: HomeReplacementProposal
    var stage: Stage
    var target: ActiveHomeScope?
    var deletion: HomeDeletionCommand?
    var id: UUID { proposal.id }

    var isTerminal: Bool { stage == .completed || stage == .sourceKept }

    func validate() throws {
        try proposal.validate()
        if let target {
            guard ActiveHomeScope(session: proposal.session, graph: target.graph) == target,
                  target.graph != proposal.source.graph else { throw HomeReplacementError.invalidProposal }
        }
        if let deletion {
            try deletion.validate()
            guard deletion.isLocal, deletion.graph == proposal.source.graph,
                  deletion.storeURL.standardizedFileURL == proposal.sourceURL.standardizedFileURL,
                  deletion.starterRequirement == proposal.source else { throw HomeReplacementError.invalidProposal }
        }
        switch stage {
        case .confirmed, .joining:
            guard target == nil, deletion == nil else { throw HomeReplacementError.invalidProposal }
        case .activating, .targetActivated:
            guard target != nil, deletion == nil else { throw HomeReplacementError.invalidProposal }
        case .cleanupPending, .completed:
            guard target != nil, deletion != nil else { throw HomeReplacementError.invalidProposal }
        case .sourceKept: break
        }
    }
}

enum HomeReplacementError: Error, LocalizedError {
    case invalidProposal, intentChanged, operationInProgress
    var errorDescription: String? {
        switch self {
        case .invalidProposal: "This starter Home can’t be replaced. Join and keep your Homes."
        case .intentChanged: "Your Home choice changed. Check replacement status in Homes."
        case .operationInProgress: "Joining this Home is already in progress."
        }
    }
}
