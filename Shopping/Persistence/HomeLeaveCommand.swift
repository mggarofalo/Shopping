import Foundation

/// Explicit participant authorization. The native origin is local to one store;
/// its quarantine and private evidence remain portable across account replicas.
struct HomeLeaveCommand: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let origin: HomeNativeAccessIdentity
    let storeURL: URL
    let participantID: String
    let homeName: String
    let evidence: HomeLeaveEvidence
    let confirmedAt: Date

    var quarantineID: UUID { PersonalCartCoding.stableID("home-leave-quarantine", id.uuidString) }
    var quarantine: HomeAccessRecord {
        HomeAccessRecord(id: quarantineID, scope: origin.scope, share: origin.share, action: .blocked(.left))
    }

    func validate() throws {
        try quarantine.validate()
        guard id != PersistenceModel.unsetID, !origin.storeIdentifier.isEmpty,
              URL(string: origin.rootURI)?.scheme == "x-coredata", storeURL.isFileURL,
              !storeURL.path.isEmpty, !participantID.isEmpty,
              confirmedAt.timeIntervalSinceReferenceDate.isFinite,
              !evidence.checkoutIDs.contains(PersistenceModel.unsetID),
              !evidence.restoreIDs.contains(PersistenceModel.unsetID),
              !evidence.unresolvedRestoreIDs.contains(PersistenceModel.unsetID),
              !evidence.cartGenerations.contains(PersistenceModel.unsetID) else {
            throw PersonalCartError.corruptRecord
        }
    }

    func matches(scope: HomeEffectScope, share: HomeEffectShare) -> Bool {
        origin.scope == scope && origin.share == share
    }

    func matchesNativeOrigin(_ identity: HomeNativeAccessIdentity, storeURL: URL) -> Bool {
        origin == identity && self.storeURL.standardizedFileURL == storeURL.standardizedFileURL
    }
}

struct HomeLeaveEvidence: Codable, Equatable, Sendable {
    let checkoutIDs: Set<UUID>
    let restoreIDs: Set<UUID>
    let unresolvedRestoreIDs: Set<UUID>
    let cartGenerations: Set<UUID>
}

/// Embedding the immutable command keeps partial/reordered private imports
/// conservative even when the original authorization has not arrived yet.
struct HomeLeaveCheckpoint: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case submitted, completed }
    let command: HomeLeaveCommand
    let stage: Stage
    var id: UUID { PersonalCartCoding.stableID("home-leave-" + stage.rawValue, command.id.uuidString) }
}

struct HomeLeaveStatus: Equatable, Identifiable, Sendable {
    let command: HomeLeaveCommand
    let submitted: Bool
    let completed: Bool
    var id: UUID { command.id }
    var requiresResolution: Bool { !completed }
}
