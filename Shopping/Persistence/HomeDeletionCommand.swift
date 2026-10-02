import Foundation

/// A confirmed deletion names one graph. Local homes never acquire account ownership.
struct HomeDeletionCommand: Codable, Equatable, Identifiable, Sendable {
    enum Target: Codable, Equatable, Sendable {
        case local(graph: HomeGraphIdentity, storeURL: URL)
        case owned(scope: ActiveHomeScope, storeURL: URL, share: HomeEffectShare?)
    }
    let id: UUID
    let target: Target
    let homeName: String
    let preparedAt: Date
    let objectURIs: Set<String>

    var isLocal: Bool { if case .local = target { true } else { false } }
    var scope: ActiveHomeScope? { if case .owned(let scope, _, _) = target { scope } else { nil } }
    var graph: HomeGraphIdentity {
        switch target { case .local(let graph, _): graph; case .owned(let scope, _, _): scope.graph }
    }
    var storeURL: URL {
        switch target { case .local(_, let url), .owned(_, let url, _): url }
    }
    var share: HomeEffectShare? { if case .owned(_, _, let share) = target { share } else { nil } }

    func validate() throws {
        guard id != PersistenceModel.unsetID, graph.householdID != PersistenceModel.unsetID,
              graph.listID != PersistenceModel.unsetID, !graph.storeIdentifier.isEmpty,
              URL(string: graph.rootURI)?.scheme == "x-coredata", storeURL.isFileURL,
              objectURIs.contains(graph.rootURI), objectURIs.allSatisfy({ URL(string: $0)?.scheme == "x-coredata" }),
              preparedAt.timeIntervalSinceReferenceDate.isFinite else { throw PersonalCartError.corruptRecord }
        if let scope {
            guard !scope.accountBinding.isEmpty, !scope.containerIdentifier.isEmpty, !scope.environment.isEmpty else {
                throw PersonalCartError.corruptRecord
            }
        }
        if let share {
            guard !share.recordName.isEmpty, !share.zoneName.isEmpty, !share.zoneOwnerName.isEmpty else {
                throw PersonalCartError.corruptRecord
            }
        }
    }
}

struct HomeDeletionCheckpoint: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case submitted, completed }
    let command: HomeDeletionCommand
    let stage: Stage
    var id: UUID { PersonalCartCoding.stableID("home-delete-" + stage.rawValue, command.id.uuidString) }
}

struct HomeDeletionStatus: Equatable, Identifiable, Sendable {
    let command: HomeDeletionCommand
    let submitted: Bool
    let completed: Bool
    var id: UUID { command.id }
    var requiresResolution: Bool { !completed }
}

/// A confirmed home deletion includes later imported children of that same home.
/// Coverage is appended only after graph and zone validation; the command stays unchanged.
struct HomeDeletionCoverage: Codable, Equatable, Sendable {
    let command: HomeDeletionCommand
    let objectURIs: Set<String>
    var id: UUID {
        PersonalCartCoding.stableID("home-delete-coverage", command.id.uuidString,
            objectURIs.sorted().joined(separator: "\n"))
    }

    func validate() throws {
        try command.validate()
        guard command.share != nil, command.objectURIs.isSubset(of: objectURIs),
              objectURIs.allSatisfy({ URL(string: $0)?.scheme == "x-coredata" }) else { throw PersonalCartError.corruptRecord }
    }
}

enum HomeDeletionError: Error, LocalizedError {
    case ownerRequired, scopeChanged, sharingPending, outcomeUncertain, invalidGraph
    var errorDescription: String? {
        switch self {
        case .ownerRequired: "Only the owner can delete this home."
        case .scopeChanged: "This home changed. Reopen Home Settings."
        case .sharingPending: "Sharing is still finishing. Try again shortly."
        case .outcomeUncertain: "Deleting this home is still being confirmed."
        case .invalidGraph: "This home couldn’t be deleted."
        }
    }
}
