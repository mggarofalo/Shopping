import Foundation

extension PersonalCartRepository {
    func homeEffectScope(householdID: UUID, listID: UUID) -> HomeEffectScope {
        HomeEffectScope(session: session, householdID: householdID, listID: listID)
    }

    func homeEffectAccess(householdID: UUID, listID: UUID) throws -> HomeEffectAccess {
        let scope = homeEffectScope(householdID: householdID, listID: listID)
        let records = try values(HomeAccessRecord.self, kind: "homeAccess")
        for (id, record) in records {
            try record.validate()
            guard record.id == id, record.scope.accountBinding == session.accountBinding,
                  record.scope.containerIdentifier == session.containerIdentifier,
                  record.scope.environment == session.environment else { throw PersonalCartError.corruptRecord }
        }
        // Effects can import before the lifecycle records they observed. Their
        // embedded dependencies must also close the boundary, even on a replica
        // that has never seen the original block or grant.
        let checkouts = try values(PersonalCheckoutIntent.self, kind: "checkout")
        let restores = try values(PersonalRestoreIntent.self, kind: "restore")
        let edits = try values(PersonalCartCommandResult.self, kind: "cart").values.compactMap(\.edit)
        var required = Set(try homeLeaves().filter { $0.command.origin.scope == scope }.map { $0.command.quarantineID })
        var requiredRestrictions: Set<UUID> = []
        for intent in checkouts.values where intent.token.householdID == householdID && intent.token.listID == listID {
            required.formUnion(intent.token.homeEffectAuthority?.observedBlockIDs ?? [])
            requiredRestrictions.formUnion(intent.token.homeEffectAuthority?.observedRestrictionIDs ?? [])
        }
        for restore in restores.values {
            if let declared = restore.homeEffectScope {
                guard declared == scope else { continue }
                if let checkout = checkouts[restore.checkoutID] {
                    guard checkout.token.householdID == householdID, checkout.token.listID == listID,
                          checkout.token.accountBinding == session.accountBinding else { throw PersonalCartError.corruptRecord }
                }
            } else if let checkout = checkouts[restore.checkoutID] {
                guard checkout.token.householdID == householdID, checkout.token.listID == listID else { continue }
            } else {
                if restore.homeEffectAuthority != nil { throw PersonalCartError.incompleteImport }
                continue
            }
            required.formUnion(restore.homeEffectAuthority?.observedBlockIDs ?? [])
            requiredRestrictions.formUnion(restore.homeEffectAuthority?.observedRestrictionIDs ?? [])
        }
        for edit in edits where edit.snapshot.householdID == householdID && edit.snapshot.listID == listID {
            required.formUnion(edit.snapshot.token.homeEffectAuthority?.observedBlockIDs ?? [])
            requiredRestrictions.formUnion(edit.snapshot.token.homeEffectAuthority?.observedRestrictionIDs ?? [])
        }
        return try HomeEffectAccess(records: records.values.filter { $0.scope == scope }, requiredBlockIDs: required,
            requiredRestrictionIDs: requiredRestrictions,
            isDeleted: isHomeDeleted(householdID: householdID, listID: listID))
    }

    func homeEffectMayPublish(kind: HomeEffectKind, subjectID: UUID,
                             householdID: UUID, listID: UUID) throws -> Bool {
        if try isHomeDeleted(householdID: householdID, listID: listID) { return false }
        guard try nativePublicationAllowed(householdID: householdID, listID: listID) else { return false }
        let authority: HomeEffectAuthority
        switch kind {
        case .checkout:
            guard let intent = try values(PersonalCheckoutIntent.self, kind: "checkout")[subjectID],
                  intent.token.accountBinding == session.accountBinding,
                  intent.token.householdID == householdID, intent.token.listID == listID else {
                throw PersonalCartError.incompleteImport
            }
            authority = intent.token.homeEffectAuthority ?? .legacy
        case .restore:
            guard let restore = try values(PersonalRestoreIntent.self, kind: "restore")[subjectID],
                  let checkout = try values(PersonalCheckoutIntent.self, kind: "checkout")[restore.checkoutID],
                  checkout.token.accountBinding == session.accountBinding,
                  checkout.token.householdID == householdID, checkout.token.listID == listID else {
                throw PersonalCartError.incompleteImport
            }
            if let scope = restore.homeEffectScope,
               scope != homeEffectScope(householdID: householdID, listID: listID) { throw PersonalCartError.corruptRecord }
            authority = restore.homeEffectAuthority ?? checkout.token.homeEffectAuthority ?? .legacy
        case .cartGeneration:
            let tokens = try values(PersonalCartCommandResult.self, kind: "cart").values.compactMap(\.edit)
                .map(\.snapshot.token).filter { $0.generation == subjectID }
            guard let first = tokens.first else { throw PersonalCartError.incompleteImport }
            let original = first.homeEffectAuthority ?? .legacy
            guard tokens.allSatisfy({ $0.accountBinding == session.accountBinding && $0.householdID == householdID
                && $0.listID == listID && ($0.homeEffectAuthority ?? .legacy).grantID == original.grantID }) else {
                throw PersonalCartError.corruptRecord
            }
            authority = HomeEffectAuthority(observedBlockIDs: tokens.reduce(into: Set<UUID>()) {
                $0.formUnion(($1.homeEffectAuthority ?? .legacy).observedBlockIDs)
            }, grantID: original.grantID, observedRestrictionIDs: tokens.reduce(into: Set<UUID>()) {
                $0.formUnion(($1.homeEffectAuthority ?? .legacy).observedRestrictionIDs)
            })
        }
        return try homeEffectAccess(householdID: householdID, listID: listID).permitsPublication(authority)
    }
}

extension PersonalCartService {
    func homeEffectBoundary(householdID: UUID, listID: UUID) throws -> Set<UUID> {
        try transact(save: false) { try $0.homeEffectAccess(householdID: householdID, listID: listID).blockIDs }
    }

    /// Call only for a confirmed leave or a typed observation of actual access loss.
    /// Network/account errors and locally missing share metadata are not revocation.
    func blockHomeEffects(householdID: UUID, listID: UUID, share: HomeEffectShare,
                          reason: HomeAccessRecord.Loss, operationID: UUID) throws {
        try transact { repository in
            let record = HomeAccessRecord(id: operationID,
                scope: repository.homeEffectScope(householdID: householdID, listID: listID),
                share: share, action: .blocked(reason))
            try record.validate()
            try repository.insert(id: operationID, kind: "homeAccess", command: record, value: record)
        }
    }

    /// The caller must first verify accepted membership for this exact share. The
    /// captured boundary is checked again atomically so an intervening loss wins.
    func grantHomeEffects(householdID: UUID, listID: UUID, share: HomeEffectShare,
                          observedBlockIDs: Set<UUID>, operationID: UUID) throws {
        try transact { repository in
            let access = try repository.homeEffectAccess(householdID: householdID, listID: listID)
            guard access.hasCompleteBoundary, access.blockIDs == observedBlockIDs else { throw PersonalCartError.scopeChanged }
            guard access.currentGrants.allSatisfy({ $0.share == share }) else { throw PersonalCartError.scopeChanged }
            let record = HomeAccessRecord(id: operationID,
                scope: repository.homeEffectScope(householdID: householdID, listID: listID),
                share: share, action: .joined(observedBlockIDs: observedBlockIDs))
            try record.validate()
            try repository.insert(id: operationID, kind: "homeAccess", command: record, value: record)
        }
    }
}
