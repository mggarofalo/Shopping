import CoreData

extension PersonalCartService {
    func prepareCheckout(tokens: [PersonalCartEntryToken], storeID: UUID? = nil) throws -> PersonalCheckoutToken {
        guard let first = tokens.first else { throw PersonalCartError.staleEntry }
        return try transact(save: false) { repository in
            guard first.accountBinding == repository.session.accountBinding,
                  Set(tokens.map(\.needID)).count == tokens.count,
                  tokens.allSatisfy({ $0.accountBinding == first.accountBinding && $0.householdID == first.householdID && $0.listID == first.listID }) else {
                throw PersonalCartError.scopeChanged
            }
            let entries = try self.entries(householdID: first.householdID, listID: first.listID, repository: repository)
            let captures = try tokens.map { token -> PersonalCheckoutCapture in
                guard let entry = entries.first(where: { $0.token == token }),
                      PersonalCartSnapshotBuilder.eligible(entry, storeID: storeID) else { throw PersonalCartError.staleEntry }
                let need = try repository.need(token.needID, householdID: token.householdID, listID: token.listID)
                guard entry.demandAvailable || !entry.purchaseNotices.isEmpty else { throw PersonalCartError.unavailable }
                return PersonalCheckoutCapture(entry: entry,
                    demandEvidence: try HouseholdDemandProjection.evidence(needID: token.needID, householdID: token.householdID,
                        reading: .arrived, in: repository.context),
                    purchaseRuleEvidence: need.map(PersonalCartSnapshotBuilder.ruleEvidence) ?? "retained",
                    needRevision: need?.revision ?? -1)
            }
            var token = PersonalCheckoutToken(id: UUID(), accountBinding: first.accountBinding,
                householdID: first.householdID, listID: first.listID, storeID: storeID, captures: captures)
            token.homeEffectAuthority = try repository.homeEffectAccess(householdID: first.householdID,
                listID: first.listID).capturedAuthority
            if let storeID {
                let request = Store.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND household.id == %@ AND isArchived == NO", storeID as CVarArg, first.householdID as CVarArg)
                let stores = try repository.context.fetch(request)
                guard stores.count == 1 else { throw PersonalCartError.scopeChanged }
                token.storeName = stores[0].name
            }
            return token
        }
    }

    func checkout(_ token: PersonalCheckoutToken, buyAnywayReceiptIDs: Set<UUID> = [], operationID: UUID = UUID(),
                  effects: PersonalCartEffectPolicy = .immediate) throws -> PersonalCheckoutOutcome {
        let command = PersonalCartCommand.checkout(token, buyAnywayReceiptIDs)
        let (intent, held) = try transact { repository -> (PersonalCheckoutIntent, Bool) in
            guard repository.session.accountBinding == token.accountBinding else { throw PersonalCartError.accountChanged }
            let intent = try self.recordCheckout(token, buyAnywayReceiptIDs: buyAnywayReceiptIDs,
                operationID: operationID, command: command, repository: repository)
            guard effects == .deferred else { return (intent, false) }
            return (intent, try repository.homeEffectPublicationHeld(kind: .checkout, subjectID: operationID,
                householdID: token.householdID, listID: token.listID))
        }
        try failurePoint?("afterIntent")
        let pending: Bool
        switch effects {
        case .immediate:
            pending = try publishReporting { try publishCheckout(id: operationID) }
            republishPresence(each: intent.accepted)
        case .deferred:
            pending = held
            requestCheckoutPublication()
        }
        return PersonalCheckoutOutcome(operationID: operationID, purchasedNeedIDs: intent.accepted,
            skippedNeedIDs: Set(token.captures.map(\.entry.needID)).subtracting(intent.accepted), pendingPublication: pending)
    }

    private func recordCheckout(_ token: PersonalCheckoutToken, buyAnywayReceiptIDs: Set<UUID>, operationID: UUID,
                                command: PersonalCartCommand, repository: PersonalCartRepository) throws -> PersonalCheckoutIntent {
        if let prior = try repository.replay(id: operationID, kind: "checkout", command: command, as: PersonalCheckoutIntent.self) { return prior }
        try repository.homeEffectAccess(householdID: token.householdID, listID: token.listID)
            .validateCapture(token.homeEffectAuthority ?? .legacy)
        guard Set(token.captures.map(\.entry.needID)).count == token.captures.count else {
            throw PersonalCartError.corruptRecord
        }
        let entries = try self.entries(householdID: token.householdID, listID: token.listID, repository: repository)
        var accepted: Set<UUID> = []
        for capture in token.captures {
            let captured = capture.entry
            guard captured.token.accountBinding == token.accountBinding,
                  captured.householdID == token.householdID, captured.listID == token.listID else {
                throw PersonalCartError.scopeChanged
            }
            guard let current = entries.first(where: { $0.token == captured.token }),
                  PersonalCartSnapshotBuilder.eligible(current, storeID: token.storeID),
                  Set(current.purchaseNotices.map(\.receiptID)).isSubset(of: buyAnywayReceiptIDs) else { continue }
            let need = try repository.need(captured.needID, householdID: token.householdID, listID: token.listID)
            guard (need?.revision ?? -1) == capture.needRevision,
                  (need.map(PersonalCartSnapshotBuilder.ruleEvidence) ?? "retained") == capture.purchaseRuleEvidence,
                  try HouseholdDemandProjection.evidence(needID: captured.needID, householdID: token.householdID,
                    reading: .arrived, in: repository.context) == capture.demandEvidence else { continue }
            if let storeID = token.storeID {
                let request = Store.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND household.id == %@ AND isArchived == NO", storeID as CVarArg, token.householdID as CVarArg)
                guard try repository.context.fetch(request).count == 1 else { continue }
            }
            accepted.insert(captured.needID)
        }
        let intent = PersonalCheckoutIntent(token: token, accepted: accepted,
                                            buyAnywayReceiptIDs: buyAnywayReceiptIDs, createdAt: Date())
        try self.failurePoint?("beforeIntent")
        try repository.insert(id: operationID, kind: "checkout", command: command, value: intent)
        return intent
    }

    func restore(checkoutID: UUID, operationID: UUID = UUID(),
                 effects: PersonalCartEffectPolicy = .immediate) throws -> PersonalCheckoutOutcome {
        let command = PersonalCartCommand.restore(checkoutID)
        let (restore, checkout, held) = try transact { repository -> (PersonalRestoreIntent, PersonalCheckoutIntent, Bool) in
            let (restore, checkout) = try self.recordRestore(checkoutID: checkoutID, operationID: operationID,
                command: command, repository: repository)
            guard effects == .deferred else { return (restore, checkout, false) }
            return (restore, checkout, try repository.homeEffectPublicationHeld(kind: .restore, subjectID: operationID,
                householdID: checkout.token.householdID, listID: checkout.token.listID))
        }
        let pending: Bool
        switch effects {
        case .immediate:
            pending = try publishReporting { try publishRestore(id: operationID) }
            republishPresence(each: restore.restoredNeedIDs)
        case .deferred:
            pending = held
            requestCheckoutPublication()
        }
        return PersonalCheckoutOutcome(operationID: operationID, purchasedNeedIDs: restore.restoredNeedIDs,
            skippedNeedIDs: checkout.accepted.subtracting(restore.restoredNeedIDs), pendingPublication: pending)
    }

    private func recordRestore(checkoutID: UUID, operationID: UUID, command: PersonalCartCommand,
                               repository: PersonalCartRepository) throws -> (PersonalRestoreIntent, PersonalCheckoutIntent) {
        let checkouts = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")
        guard let checkout = checkouts[checkoutID] else { throw PersonalCartError.permissionDenied }
        if let prior = try repository.replay(id: operationID, kind: "restore", command: command, as: PersonalRestoreIntent.self) {
            return (prior, checkout)
        }
        let edits = try repository.values(PersonalCartCommandResult.self, kind: "cart").values.compactMap(\.edit)
        let superseded = try HouseholdDemandProjection.superseded(householdID: checkout.token.householdID,
            reading: .arrived, in: repository.context)
        let existing = try repository.values(PersonalRestoreIntent.self, kind: "restore").values
            .filter { $0.checkoutID == checkoutID }.reduce(into: Set<UUID>()) { $0.formUnion($1.restoredNeedIDs) }
        var restored: Set<UUID> = []
        for capture in checkout.token.captures where checkout.accepted.contains(capture.entry.needID) {
            let needID = capture.entry.needID
            guard !superseded.contains(needID), !existing.contains(needID),
                  Set(edits.filter { $0.snapshot.needID == needID }.map(\.id)) == capture.entry.token.evidence,
                  try HouseholdDemandProjection.evidence(needID: needID, householdID: checkout.token.householdID,
                    reading: .arrived, in: repository.context) == capture.demandEvidence else { continue }
            restored.insert(needID)
        }
        let priorAuthority = checkout.token.homeEffectAuthority ?? .legacy
        let access = try repository.homeEffectAccess(householdID: checkout.token.householdID, listID: checkout.token.listID)
        var restore = PersonalRestoreIntent(checkoutID: checkoutID, restoredNeedIDs: restored)
        restore.homeEffectAuthority = HomeEffectAuthority(
            observedBlockIDs: priorAuthority.observedBlockIDs.union(access.blockIDs), grantID: priorAuthority.grantID,
            observedRestrictionIDs: priorAuthority.observedRestrictionIDs.union(access.restrictionIDs))
        restore.homeEffectScope = repository.homeEffectScope(householdID: checkout.token.householdID,
            listID: checkout.token.listID)
        try repository.insert(id: operationID, kind: "restore", command: command, value: restore)
        return (restore, checkout)
    }

    /// Publishes inline and reports whether the household update is held.
    private func publishReporting(_ publish: () throws -> Void) throws -> Bool {
        do { try publish() }
        catch let error as PersonalCartError where error == .permissionDenied || error == .unavailable || error == .quarantined { return true }
        catch is PersistencePermissionError { return true }
        return false
    }
}
