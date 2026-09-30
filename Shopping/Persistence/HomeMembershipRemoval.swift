import Foundation

/// Immutable owner authorization. Stored in the owner's unshared record graph so
/// another owner device can suppress the same cancelled capability after import.
struct HomeMembershipRemoval: Codable, Equatable, Identifiable, Sendable {
    enum Purpose: String, Codable, Sendable { case removeMember, stopSharing, cancelInvitation }
    let id: UUID
    let origin: ActiveHomeScope
    let share: HomeShareIdentity
    let ownerParticipantID: String
    let participantIDs: Set<String>
    let cancelledInvitationID: UUID?
    let purpose: Purpose
    let confirmedAt: Date

    func matches(scope: ActiveHomeScope, share: HomeShareIdentity) -> Bool {
        self.share == share && origin.accountBinding == scope.accountBinding
            && origin.containerIdentifier == scope.containerIdentifier && origin.environment == scope.environment
            && origin.graph.householdID == scope.graph.householdID && origin.graph.listID == scope.graph.listID
    }

    func validate() throws {
        guard id != PersistenceModel.unsetID, !ownerParticipantID.isEmpty,
              !participantIDs.isEmpty, !participantIDs.contains(""), !participantIDs.contains(ownerParticipantID),
              !share.recordName.isEmpty, !share.zoneName.isEmpty, !share.zoneOwnerName.isEmpty,
              (purpose == .cancelInvitation) == (cancelledInvitationID != nil),
              cancelledInvitationID != PersistenceModel.unsetID,
              purpose != .cancelInvitation || participantIDs.count == 1 else {
            throw HomeMembershipError.invalidParticipant
        }
    }
}

struct HomeMembershipRemovalStatus: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { removal.id }
    let removal: HomeMembershipRemoval
    var absentObservedAt: Date?
    var requiresRetry = false
}

struct HomeMembershipRemovalConfirmation: Identifiable, Sendable {
    let removal: HomeMembershipRemoval
    let homeName: String
    let memberNames: [String]
    var id: UUID { removal.id }
}
