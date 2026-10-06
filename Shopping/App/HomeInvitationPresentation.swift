import Foundation

enum HomeInvitationRoute: Hashable, Identifiable {
    case named(UUID)
    case legacy(String)
    var id: String {
        switch self {
        case .named(let id): return id.uuidString
        case .legacy(let id): return id
        }
    }
}

struct HomeInvitationPresentation {
    let status: String
    let canShare: Bool
    let acceptedMember: HomeMember?
    let cancelling: Bool

    init(record: HomeInvitationRecord, snapshot: HomeMembershipSnapshot?) {
        let member = record.hasConflictingParticipants ? nil : snapshot?.members.first { record.participantIDs.contains($0.id) && $0.acceptance == .accepted }
        acceptedMember = member
        let removals = snapshot?.removals.filter { !$0.removal.participantIDs.isDisjoint(with: record.participantIDs) } ?? []
        cancelling = removals.contains { $0.absentObservedAt == nil }
        let pending = snapshot?.members.contains { record.participantIDs.contains($0.id) && $0.acceptance == .pending } == true
        canShare = member == nil && !record.isTerminal && removals.isEmpty && pending && !record.hasConflictingParticipants
        if member != nil { status = "Joined" }
        else if record.hasConflictingParticipants && !record.isTerminal { status = "Multiple links need review" }
        else if cancelling { status = "Cancelling invitation…" }
        else if !removals.isEmpty { status = "Invitation cancelled" }
        else if record.isTerminal { status = "Invitation closed" }
        else if record.hasConflictingParticipants { status = "Multiple links need review" }
        else if record.participantIDs.isEmpty { status = "Draft" }
        else if pending { status = record.lastHandoffAt == nil ? "Ready to share" : "Waiting to join" }
        else { status = "Check invitation" }
    }
}
