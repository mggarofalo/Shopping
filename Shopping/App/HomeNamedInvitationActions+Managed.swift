import Foundation

extension HomeNamedInvitationActions {
    @MainActor
    struct Context {
        let journalURL: URL
        let transport: ManagedHomeMembershipTransport
        let share: HomeShareIdentity?
        let validate: () throws -> Void
    }

    static func managed(scope: ActiveHomeScope, coordinator: HomeMembershipCoordinator,
                        context: @escaping () async throws -> Context,
                        prepareShare: @escaping (Bool) async throws -> Void) -> Self {
        Self(load: {
            let value = try await context()
            let records = try await coordinator.invitationRecords(scope: scope, share: value.share, transport: value.transport)
            try value.validate()
            return records
        }, prepare: { name in
            let value = try await context()
            let record = try await coordinator.prepareInvitation(name: name, scope: scope, share: value.share, transport: value.transport)
            try value.validate()
            return record
        }, create: { id, retry in
            guard #available(iOS 18.0, *) else { throw HomeMembershipError.unsupportedVersion }
            var value = try await context()
            if value.share == nil || retry {
                try await prepareShare(retry)
                value = try await context()
            }
            let result = try await coordinator.invite(recordID: id, scope: scope,
                journalURL: value.journalURL, transport: value.transport)
            try value.validate()
            // The named record retains the participant independently of share-sheet delivery.
            try await coordinator.acknowledge(result, journalURL: value.journalURL)
            try value.validate()
            return result
        }, rename: { id, name in
            let value = try await context()
            try await coordinator.renameInvitation(recordID: id, name: name, scope: scope,
                share: value.share, transport: value.transport)
            try value.validate()
        }, label: { participantID, name in
            let value = try await context()
            guard let share = value.share else { throw HomeMembershipError.shareUnavailable }
            let record = try await coordinator.labelInvitation(participantID: participantID, name: name,
                scope: scope, share: share, transport: value.transport)
            try value.validate()
            return record
        }, handoff: { id in
            let value = try await context()
            guard let share = value.share else { throw HomeMembershipError.shareUnavailable }
            try await coordinator.recordInvitationHandoff(recordID: id, scope: scope,
                share: share, transport: value.transport)
            try value.validate()
        }, cancel: { id in
            let value = try await context()
            guard let share = value.share else { throw HomeMembershipError.shareUnavailable }
            let result = try await coordinator.prepareInvitationCancellation(recordID: id, scope: scope,
                share: share, journalURL: value.journalURL, transport: value.transport)
            try value.validate()
            return result
        }, cancelLink: { id, participantID in
            let value = try await context()
            guard let share = value.share else { throw HomeMembershipError.shareUnavailable }
            let result = try await coordinator.prepareInvitationCancellation(recordID: id, participantID: participantID,
                scope: scope, share: share, journalURL: value.journalURL, transport: value.transport)
            try value.validate()
            return result
        }, discard: { id in
            let value = try await context()
            try await coordinator.discardInvitationDraft(recordID: id, scope: scope, share: value.share, transport: value.transport)
            try value.validate()
        })
    }
}
