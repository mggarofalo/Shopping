import Foundation

/// Owner-private presentation history. This never grants authority to mutate a share.
struct HomeInvitationRecord: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let origin: ActiveHomeScope
    let share: HomeShareIdentity?
    let participantIDs: Set<String>
    let lastHandoffAt: Date?
    var isTerminal = false
    var hasConflictingName = false
    var participantID: String? { participantIDs.count == 1 ? participantIDs.first : nil }
    var hasConflictingParticipants: Bool { participantIDs.count > 1 }
    var normalizedName: String { Self.normalize(name) }

    static func normalize(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func project(_ events: [HomeInvitationEvent], scope: ActiveHomeScope,
                        share: HomeShareIdentity?) throws -> [Self] {
        for event in events { try event.validate() }
        let groups = Dictionary(grouping: events.filter { $0.matches(scope: scope) }, by: \.invitationID)
        var records: [Self] = try groups.values.compactMap { values in
            guard let draft = values.first(where: { $0.kind == .named }) else { return nil }
            guard values.filter({ $0.kind == .named }).allSatisfy({ $0 == draft }),
                  values.allSatisfy({ $0.matches(scope: draft.origin) }) else { throw HomeMembershipError.invalidJournal }
            let bindings = values.filter { $0.kind == .bound }
            let shares = bindings.compactMap(\.share) + [draft.share].compactMap { $0 }
            guard shares.allSatisfy({ $0 == shares.first }) else { throw HomeMembershipError.invalidJournal }
            let boundShare = shares.first
            guard boundShare == nil || boundShare == share else { return nil }
            let latestName = values.filter { $0.kind == .named || $0.kind == .renamed }.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }.last!.name
            let participants = Set(bindings.compactMap(\.participantID))
            let accepted = Set(values.filter { $0.kind == .accepted }.compactMap(\.participantID))
            return Self(id: draft.invitationID, name: latestName, origin: draft.origin, share: boundShare,
                participantIDs: Set(bindings.compactMap(\.participantID)),
                lastHandoffAt: values.filter { $0.kind == .handoff }.map(\.createdAt).max(),
                isTerminal: !participants.isEmpty && participants.isSubset(of: accepted))
        }
        let counts = Dictionary(grouping: records, by: \.normalizedName).mapValues(\.count)
        for index in records.indices { records[index].hasConflictingName = counts[records[index].normalizedName, default: 0] > 1 }
        return records.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

/// Append-only events converge across owner devices without overwriting a competing capability.
struct HomeInvitationEvent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case named, renamed, bound, handoff, accepted }
    let id: UUID
    let invitationID: UUID
    let origin: ActiveHomeScope
    let share: HomeShareIdentity?
    let name: String
    let kind: Kind
    let participantID: String?
    let createdAt: Date

    func matches(scope: ActiveHomeScope) -> Bool {
        origin.accountBinding == scope.accountBinding && origin.containerIdentifier == scope.containerIdentifier
            && origin.environment == scope.environment && origin.graph.householdID == scope.graph.householdID
            && origin.graph.listID == scope.graph.listID
    }

    func validate() throws {
        guard id != PersistenceModel.unsetID, invitationID != PersistenceModel.unsetID,
              !HomeInvitationRecord.normalize(name).isEmpty,
              kind != .bound || (share != nil && participantID?.isEmpty == false),
              kind != .named || participantID == nil,
              kind != .handoff || (share != nil && participantID?.isEmpty == false) else {
            throw HomeMembershipError.invalidJournal
        }
        if let share {
            guard !share.recordName.isEmpty, !share.zoneName.isEmpty, !share.zoneOwnerName.isEmpty else {
                throw HomeMembershipError.invalidJournal
            }
        }
    }
}

protocol HomeInvitationTrackingTransport: HomeMembershipTransport {
    func invitationEvents(scope: ActiveHomeScope) async throws -> [HomeInvitationEvent]
    func retainInvitationEvent(_ event: HomeInvitationEvent, scope: ActiveHomeScope) async throws
}
