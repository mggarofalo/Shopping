import Foundation

extension PersonalCartService {
    /// The cart repository is the existing account-private append-only ledger;
    /// this kind has no managed relationships and is never household-shared.
    func retainHomeMemberRemoval(_ removal: HomeMembershipRemoval) throws {
        try removal.validate()
        try transact { repository in
            guard repository.session.accountBinding == removal.origin.accountBinding,
                  repository.session.containerIdentifier == removal.origin.containerIdentifier,
                  repository.session.environment == removal.origin.environment else { throw HomeMembershipError.scopeChanged }
            try repository.insert(id: removal.id, kind: "homeMemberRemoval", command: removal, value: removal)
        }
    }

    func retainedHomeMemberRemovals(scope: ActiveHomeScope, share: HomeShareIdentity) throws -> [HomeMembershipRemoval] {
        try transact(save: false) { repository in
            guard repository.session.accountBinding == scope.accountBinding else { throw HomeMembershipError.scopeChanged }
            let values = try repository.values(HomeMembershipRemoval.self, kind: "homeMemberRemoval")
            for value in values.values { try value.validate() }
            return values.values.filter { $0.matches(scope: scope, share: share) }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }
}
