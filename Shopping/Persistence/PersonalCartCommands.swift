import CoreData

extension PersonalCartService {
    func cart(needID: UUID, householdID: UUID, listID: UUID, operationID: UUID = UUID()) throws {
        let command = PersonalCartCommand.cart(needID: needID, householdID: householdID, listID: listID)
        try transact { repository in
            if try repository.replay(id: operationID, kind: "cart", command: command, as: PersonalCartCommandResult.self) != nil { return }
            let existing = try self.entries(householdID: householdID, listID: listID, repository: repository)
            if existing.contains(where: { $0.needID == needID }) {
                try repository.insert(id: operationID, kind: "cart", command: command,
                                      value: PersonalCartCommandResult(edit: nil, skipped: false))
                return
            }
            guard let need = try repository.need(needID, householdID: householdID, listID: listID), !need.archived else {
                throw PersonalCartError.unavailable
            }
            let ancestors = try self.evidence(needID: needID, repository: repository)
            let snapshot = try PersonalCartSnapshotBuilder.make(need: need, session: repository.session,
                generation: UUID(), evidence: ancestors.union([operationID]), quantity: need.quantity)
            guard snapshot.purchaseRulesResolved else { throw PersonalCartError.unavailable }
            let edit = PersonalCartEdit(id: operationID, action: .add, snapshot: snapshot, ancestors: ancestors)
            try repository.insert(id: operationID, kind: "cart", command: command,
                                  value: PersonalCartCommandResult(edit: edit, skipped: false))
        }
        try? republishPresence()
    }

    func uncart(_ token: PersonalCartEntryToken, operationID: UUID = UUID()) throws {
        try change(token, quantity: nil, removing: true, operationID: operationID)
    }

    func setQuantity(_ quantity: Int64?, token: PersonalCartEntryToken, operationID: UUID = UUID()) throws {
        if let quantity, !(1...99).contains(quantity) { throw PersonalCartError.invalidQuantity }
        try change(token, quantity: quantity, removing: false, operationID: operationID)
    }

    private func change(_ token: PersonalCartEntryToken, quantity: Int64?, removing: Bool, operationID: UUID) throws {
        let command: PersonalCartCommand = removing ? .uncart(token) : .quantity(token, quantity)
        let skipped = try transact { repository -> Bool in
            guard token.accountBinding == repository.session.accountBinding else { throw PersonalCartError.accountChanged }
            if let replay = try repository.replay(id: operationID, kind: "cart", command: command, as: PersonalCartCommandResult.self) { return replay.skipped }
            let current = try self.entries(householdID: token.householdID, listID: token.listID, repository: repository)
            guard let entry = current.first(where: { $0.token == token }) else {
                try repository.insert(id: operationID, kind: "cart", command: command,
                                      value: PersonalCartCommandResult(edit: nil, skipped: true))
                return true
            }
            let updated = PersonalCartEntrySnapshot(title: entry.title, quantity: removing ? entry.quantity : quantity,
                notes: entry.notes, categoryID: entry.categoryID, categoryName: entry.categoryName,
                categoryOrder: entry.categoryOrder, urgency: entry.urgency, anyStore: entry.anyStore,
                storeIDs: entry.storeIDs, purchaseRulesResolved: entry.purchaseRulesResolved,
                token: PersonalCartEntryToken(accountBinding: token.accountBinding, householdID: token.householdID,
                    listID: token.listID, needID: token.needID, generation: token.generation,
                    evidence: token.evidence.union([operationID])),
                purchaseNotices: entry.purchaseNotices, demandAvailable: entry.demandAvailable)
            let edit = PersonalCartEdit(id: operationID, action: removing ? .remove : .quantity,
                                        snapshot: updated, ancestors: token.evidence)
            try repository.insert(id: operationID, kind: "cart", command: command,
                                  value: PersonalCartCommandResult(edit: edit, skipped: false))
            return false
        }
        if skipped { throw PersonalCartError.staleEntry }
        try? republishPresence()
    }
}
