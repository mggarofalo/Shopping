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
                    demandEvidence: try HouseholdDemandProjection.evidence(needID: token.needID, householdID: token.householdID, in: repository.context),
                    purchaseRuleEvidence: need.map(PersonalCartSnapshotBuilder.ruleEvidence) ?? "retained",
                    needRevision: need?.revision ?? -1)
            }
            return PersonalCheckoutToken(id: UUID(), accountBinding: first.accountBinding,
                householdID: first.householdID, listID: first.listID, storeID: storeID, captures: captures)
        }
    }

    func checkout(_ token: PersonalCheckoutToken, buyAnywayReceiptIDs: Set<UUID> = [], operationID: UUID = UUID()) throws -> PersonalCheckoutOutcome {
        let command = PersonalCartCommand.checkout(token, buyAnywayReceiptIDs)
        let intent = try transact { repository -> PersonalCheckoutIntent in
            guard repository.session.accountBinding == token.accountBinding else { throw PersonalCartError.accountChanged }
            if let prior = try repository.replay(id: operationID, kind: "checkout", command: command, as: PersonalCheckoutIntent.self) { return prior }
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
                      try HouseholdDemandProjection.evidence(needID: captured.needID, householdID: token.householdID, in: repository.context) == capture.demandEvidence else { continue }
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
        try failurePoint?("afterIntent")
        var pending = false
        do { try publishCheckout(id: operationID) }
        catch let error as PersonalCartError where error == .permissionDenied || error == .unavailable { pending = true }
        catch is PersistencePermissionError { pending = true }
        try? republishPresence()
        return PersonalCheckoutOutcome(operationID: operationID, purchasedNeedIDs: intent.accepted,
            skippedNeedIDs: Set(token.captures.map(\.entry.needID)).subtracting(intent.accepted), pendingPublication: pending)
    }

    func restore(checkoutID: UUID, operationID: UUID = UUID()) throws -> PersonalCheckoutOutcome {
        let command = PersonalCartCommand.restore(checkoutID)
        let result = try transact { repository -> (PersonalRestoreIntent, Set<UUID>) in
            let checkouts = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")
            guard let checkout = checkouts[checkoutID] else { throw PersonalCartError.permissionDenied }
            if let prior = try repository.replay(id: operationID, kind: "restore", command: command, as: PersonalRestoreIntent.self) {
                return (prior, checkout.accepted)
            }
            let edits = try repository.values(PersonalCartCommandResult.self, kind: "cart").values.compactMap(\.edit)
            let superseded = try HouseholdDemandProjection.superseded(householdID: checkout.token.householdID, in: repository.context)
            let existing = try repository.values(PersonalRestoreIntent.self, kind: "restore").values
                .filter { $0.checkoutID == checkoutID }.reduce(into: Set<UUID>()) { $0.formUnion($1.restoredNeedIDs) }
            var restored: Set<UUID> = []
            for capture in checkout.token.captures where checkout.accepted.contains(capture.entry.needID) {
                let needID = capture.entry.needID
                guard !superseded.contains(needID), !existing.contains(needID),
                      Set(edits.filter { $0.snapshot.needID == needID }.map(\.id)) == capture.entry.token.evidence,
                      try HouseholdDemandProjection.evidence(needID: needID, householdID: checkout.token.householdID, in: repository.context) == capture.demandEvidence else { continue }
                restored.insert(needID)
            }
            let restore = PersonalRestoreIntent(checkoutID: checkoutID, restoredNeedIDs: restored)
            try repository.insert(id: operationID, kind: "restore", command: command, value: restore)
            return (restore, checkout.accepted)
        }
        var pending = false
        do { try publishRestore(id: operationID) }
        catch let error as PersonalCartError where error == .permissionDenied || error == .unavailable { pending = true }
        catch is PersistencePermissionError { pending = true }
        try? republishPresence()
        return PersonalCheckoutOutcome(operationID: operationID, purchasedNeedIDs: result.0.restoredNeedIDs,
            skippedNeedIDs: result.1.subtracting(result.0.restoredNeedIDs), pendingPublication: pending)
    }
}
