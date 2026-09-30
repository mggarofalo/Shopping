import Foundation

extension PersonalCartService {
    func homePermissionBoundary(householdID: UUID, listID: UUID) throws -> Set<UUID> {
        try transact(save: false) { try $0.homeEffectAccess(householdID: householdID, listID: listID).restrictionIDs }
    }

    /// Retrying the same observation is idempotent. Each newer observation advances
    /// the boundary so an older writable response cannot clear it.
    func recordReadOnlyHome(householdID: UUID, listID: UUID, share: HomeEffectShare, operationID: UUID) throws {
        try transact { repository in
            let record = HomeAccessRecord(id: operationID,
                scope: repository.homeEffectScope(householdID: householdID, listID: listID), share: share, action: .readOnly)
            try record.validate()
            try repository.insert(id: operationID, kind: "homeAccess", command: record, value: record)
        }
    }

    /// Only a fresh writable native observation may resolve the boundary captured
    /// before that request. An intervening restriction must not be cleared by it.
    func recordWritableHome(householdID: UUID, listID: UUID, share: HomeEffectShare,
                            observedRestrictionIDs: Set<UUID>, operationID: UUID) throws {
        try transact { repository in
            let access = try repository.homeEffectAccess(householdID: householdID, listID: listID)
            guard access.hasCompletePermissions, access.restrictionIDs == observedRestrictionIDs else {
                throw PersonalCartError.scopeChanged
            }
            guard !access.unresolvedRestrictionIDs.isEmpty else { return }
            let record = HomeAccessRecord(id: operationID,
                scope: repository.homeEffectScope(householdID: householdID, listID: listID), share: share,
                action: .writable(observedRestrictionIDs: observedRestrictionIDs))
            try record.validate()
            try repository.insert(id: operationID, kind: "homeAccess", command: record, value: record)
        }
    }
}
