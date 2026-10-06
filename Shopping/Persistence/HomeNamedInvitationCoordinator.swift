import Foundation

extension HomeMembershipCoordinator {
    func discardInvitationDraft(recordID: UUID, scope: ActiveHomeScope, share: HomeShareIdentity?,
                                transport: any HomeInvitationTrackingTransport) async throws {
        try await serialized(scope: scope) {
            let records = try await Self.records(scope: scope, share: share, transport: transport)
            guard let record = records.first(where: { $0.id == recordID }), record.participantIDs.isEmpty else {
                throw HomeMembershipError.outcomeUncertain
            }
            try await transport.retainInvitationEvent(HomeInvitationEvent(id: UUID(), invitationID: recordID,
                origin: scope, share: record.share, name: record.name, kind: .discarded,
                participantID: nil, createdAt: Date()), scope: scope)
        }
    }

    func invitationRecords(scope: ActiveHomeScope, share: HomeShareIdentity?,
                           transport: any HomeInvitationTrackingTransport) async throws -> [HomeInvitationRecord] {
        try await Self.records(scope: scope, share: share, transport: transport)
    }

    func prepareInvitation(name: String, scope: ActiveHomeScope, share: HomeShareIdentity?,
                           transport: any HomeInvitationTrackingTransport) async throws -> HomeInvitationRecord {
        try await serialized(scope: scope) {
            let records = try await Self.records(scope: scope, share: share, transport: transport)
            let normalized = HomeInvitationRecord.normalize(name)
            guard !normalized.isEmpty else { throw HomeMembershipError.invitationNameRequired }
            let matches = records.filter { !$0.isTerminal && $0.normalizedName == normalized }
            guard matches.count <= 1 else { throw HomeMembershipError.invitationNameConflict }
            if let existing = matches.first { return existing }
            let id = UUID()
            let event = HomeInvitationEvent(id: id, invitationID: id, origin: scope, share: share,
                name: name.split(whereSeparator: \.isWhitespace).joined(separator: " "), kind: .named,
                participantID: nil, createdAt: Date())
            try await transport.retainInvitationEvent(event, scope: scope)
            return try HomeInvitationRecord.project([event], scope: scope, share: share)[0]
        }
    }

    func renameInvitation(recordID: UUID, name: String, scope: ActiveHomeScope, share: HomeShareIdentity?,
                          transport: any HomeInvitationTrackingTransport) async throws {
        try await serialized(scope: scope) {
            let records = try await Self.records(scope: scope, share: share, transport: transport)
            guard let record = records.first(where: { $0.id == recordID }) else { throw HomeMembershipError.invitationUnavailable }
            let normalized = HomeInvitationRecord.normalize(name)
            guard !normalized.isEmpty else { throw HomeMembershipError.invitationNameRequired }
            guard !records.contains(where: { $0.id != recordID && !$0.isTerminal && $0.normalizedName == normalized }) else {
                throw HomeMembershipError.invitationNameConflict
            }
            try await transport.retainInvitationEvent(HomeInvitationEvent(id: UUID(), invitationID: recordID,
                origin: scope, share: record.share, name: name.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                kind: .renamed, participantID: nil, createdAt: Date()), scope: scope)
        }
    }

    func labelInvitation(participantID: String, name: String, scope: ActiveHomeScope, share: HomeShareIdentity,
                         transport: any HomeInvitationTrackingTransport) async throws -> HomeInvitationRecord {
        try await serialized(scope: scope) {
            let snapshot = try await transport.refresh(scope: scope)
            _ = try Self.ownerShare(snapshot, scope: scope, share: share)
            guard let member = try Self.member(participantID, in: snapshot), member.acceptance == .pending else {
                throw HomeMembershipError.invitationUnavailable
            }
            let records = try await Self.records(scope: scope, share: share, transport: transport)
            if let existing = records.first(where: { $0.participantIDs.contains(participantID) }) { return existing }
            let normalized = HomeInvitationRecord.normalize(name)
            guard !normalized.isEmpty else { throw HomeMembershipError.invitationNameRequired }
            let matches = records.filter { !$0.isTerminal && $0.normalizedName == normalized }
            guard matches.count <= 1, matches.first?.participantIDs.isEmpty != false else {
                throw HomeMembershipError.invitationNameConflict
            }
            let removals = try await transport.retainedRemovals(scope: scope, share: share)
            guard !removals.contains(where: { $0.participantIDs.contains(participantID) }) else {
                throw HomeMembershipError.invitationCancelled
            }
            let existingDraft = matches.first
            let id = existingDraft?.id ?? UUID()
            let label = existingDraft?.name ?? name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let named = HomeInvitationEvent(id: id, invitationID: id, origin: scope, share: share,
                name: label, kind: .named, participantID: nil, createdAt: Date())
            let bound = HomeInvitationEvent(id: UUID(), invitationID: id, origin: scope, share: share,
                name: label, kind: .bound, participantID: participantID, createdAt: Date())
            if existingDraft == nil { try await transport.retainInvitationEvent(named, scope: scope) }
            try await transport.retainInvitationEvent(bound, scope: scope)
            guard let result = try await Self.records(scope: scope, share: share, transport: transport).first(where: { $0.id == id }) else {
                throw HomeMembershipError.invalidJournal
            }
            return result
        }
    }

    func invite(recordID: UUID, scope: ActiveHomeScope, journalURL: URL,
                transport: any HomeInvitationTrackingTransport) async throws -> HomeInvitationDelivery {
        try await serialized(scope: scope) {
            let journal = HomeInviteJournal(url: journalURL)
            let snapshot = try await Self.refreshMembership(scope: scope, journal: journal, transport: transport)
            let share = try Self.ownerShare(snapshot, scope: scope, share: nil)
            let records = try await Self.records(scope: scope, share: share, transport: transport)
            guard let record = records.first(where: { $0.id == recordID }) else { throw HomeMembershipError.invitationUnavailable }
            guard !record.isTerminal else { throw HomeMembershipError.invitationCancelled }
            guard !record.hasConflictingParticipants else { throw HomeMembershipError.invitationNameConflict }
            if let participantID = record.participantID {
                guard try !journal.isSuppressed(participantID, scope: scope) else { throw HomeMembershipError.invitationCancelled }
                if let saved = try journal.load(scope: scope), saved.material.participantID == participantID {
                    return try await Self.perform(saved, observed: snapshot, journal: journal, transport: transport)
                }
                // A binding imported from another device is never proof that submission did not occur.
                guard let member = try Self.member(participantID, in: snapshot) else { throw HomeMembershipError.outcomeUncertain }
                guard member.acceptance != .accepted else { throw HomeMembershipError.invitationAlreadyAccepted }
                guard member.acceptance == .pending else { throw HomeMembershipError.outcomeUncertain }
                let url = try await transport.invitationURL(participantID: participantID, scope: scope, share: share)
                guard try !journal.isSuppressed(participantID, scope: scope) else { throw HomeMembershipError.invitationCancelled }
                return HomeInvitationDelivery(id: UUID(), scope: scope, participantID: participantID, url: url)
            }
            guard try journal.load(scope: scope) == nil else { throw HomeMembershipError.outcomeUncertain }
            let material = try await transport.makeInvitationParticipant(scope: scope)
            // The durable private binding commits before any share mutation or recovery journal submission.
            try await transport.retainInvitationEvent(HomeInvitationEvent(id: UUID(), invitationID: recordID,
                origin: scope, share: share, name: record.name, kind: .bound,
                participantID: material.participantID, createdAt: Date()), scope: scope)
            let intent = try journal.begin(scope: scope, share: share, material: material, baseChangeTag: snapshot.changeTag)
            return try await Self.perform(intent, observed: snapshot, journal: journal, transport: transport)
        }
    }

    func prepareInvitationCancellation(recordID: UUID, participantID requestedParticipantID: String? = nil, scope: ActiveHomeScope, share: HomeShareIdentity,
                                       journalURL: URL, transport: any HomeInvitationTrackingTransport) async throws -> HomeMembershipRemovalConfirmation {
        try await serialized(scope: scope) {
            let snapshot = try await Self.refreshMembership(scope: scope, journal: HomeInviteJournal(url: journalURL), transport: transport)
            _ = try Self.ownerShare(snapshot, scope: scope, share: share)
            let records = try await Self.records(scope: scope, share: share, transport: transport)
            guard let record = records.first(where: { $0.id == recordID }), let participantID = requestedParticipantID ?? record.participantID,
                  record.participantIDs.contains(participantID) else {
                throw HomeMembershipError.invitationUnavailable
            }
            guard !snapshot.members.contains(where: { $0.id == participantID && $0.acceptance == .accepted }) else {
                throw HomeMembershipError.invitationAlreadyAccepted
            }
            let removal = HomeMembershipRemoval(id: UUID(), origin: scope, share: share,
                ownerParticipantID: snapshot.currentParticipantID!, participantIDs: [participantID],
                cancelledInvitationID: recordID, purpose: .cancelInvitation, confirmedAt: Date())
            try removal.validate()
            return HomeMembershipRemovalConfirmation(removal: removal, homeName: snapshot.homeName, memberNames: [record.name])
        }
    }

    func recordInvitationHandoff(recordID: UUID, scope: ActiveHomeScope, share: HomeShareIdentity,
                                 transport: any HomeInvitationTrackingTransport) async throws {
        let records = try await Self.records(scope: scope, share: share, transport: transport)
        guard let record = records.first(where: { $0.id == recordID }), let participantID = record.participantID else {
            throw HomeMembershipError.invitationUnavailable
        }
        try await transport.retainInvitationEvent(HomeInvitationEvent(id: UUID(), invitationID: recordID,
            origin: scope, share: share, name: record.name, kind: .handoff,
            participantID: participantID, createdAt: Date()), scope: scope)
    }

    static func retainAcceptedInvitations(_ snapshot: HomeMembershipSnapshot,
                                         transport: any HomeInvitationTrackingTransport) async throws {
        guard snapshot.access == .owner, let share = snapshot.share else { return }
        let records = try await records(scope: snapshot.scope, share: share, transport: transport)
        for record in records where !record.isTerminal {
            for participantID in record.participantIDs where snapshot.members.contains(where: { $0.id == participantID && $0.acceptance == .accepted }) {
                try await transport.retainInvitationEvent(HomeInvitationEvent(id: UUID(), invitationID: record.id,
                    origin: snapshot.scope, share: share, name: record.name, kind: .accepted,
                    participantID: participantID, createdAt: Date()), scope: snapshot.scope)
            }
        }
    }

    private static func records(scope: ActiveHomeScope, share: HomeShareIdentity?,
                                transport: any HomeInvitationTrackingTransport) async throws -> [HomeInvitationRecord] {
        let events = try await transport.invitationEvents(scope: scope)
        var records = try HomeInvitationRecord.project(events, scope: scope, share: share)
        if let share {
            let cancelled = try await transport.retainedRemovals(scope: scope, share: share)
                .reduce(into: Set<String>()) { $0.formUnion($1.participantIDs) }
            for index in records.indices where !records[index].participantIDs.isEmpty {
                let accepted = Set(events.filter { $0.invitationID == records[index].id && $0.kind == .accepted }.compactMap(\.participantID))
                if records[index].participantIDs.isSubset(of: cancelled.union(accepted)) { records[index].isTerminal = true }
            }
        }
        let counts = Dictionary(grouping: records.filter { !$0.isTerminal }, by: \.normalizedName).mapValues(\.count)
        for index in records.indices { records[index].hasConflictingName = !records[index].isTerminal && counts[records[index].normalizedName, default: 0] > 1 }
        return records
    }
}
