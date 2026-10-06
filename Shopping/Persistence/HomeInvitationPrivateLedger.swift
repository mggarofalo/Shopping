import Foundation

extension PersonalCartService {
    func retainHomeInvitationEvent(_ event: HomeInvitationEvent) throws {
        try event.validate()
        try transact { repository in
            guard repository.session.accountBinding == event.origin.accountBinding,
                  repository.session.containerIdentifier == event.origin.containerIdentifier,
                  repository.session.environment == event.origin.environment else { throw HomeMembershipError.scopeChanged }
            try repository.insert(id: event.id, kind: "homeInvitation", command: event, value: event)
        }
    }

    func retainedHomeInvitationEvents(scope: ActiveHomeScope) throws -> [HomeInvitationEvent] {
        try transact(save: false) { repository in
            guard repository.session.accountBinding == scope.accountBinding,
                  repository.session.containerIdentifier == scope.containerIdentifier,
                  repository.session.environment == scope.environment else { throw HomeMembershipError.scopeChanged }
            let events = try repository.values(HomeInvitationEvent.self, kind: "homeInvitation")
            for event in events.values { try event.validate() }
            return events.values.filter { $0.matches(scope: scope) }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }
}
