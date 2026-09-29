import Foundation

extension PersonalCartRepository {
    func homeLeaves() throws -> [HomeLeaveStatus] {
        var commands = try values(HomeLeaveCommand.self, kind: "homeLeave")
        let checkpoints = try values(HomeLeaveCheckpoint.self, kind: "homeLeaveCheckpoint")
        for (id, checkpoint) in checkpoints {
            guard id == checkpoint.id else { throw PersonalCartError.corruptRecord }
            let command = checkpoint.command
            if let existing = commands[command.id], existing != command { throw PersonalCartError.corruptRecord }
            commands[command.id] = command
        }
        for (id, command) in commands {
            try command.validate()
            let scope = command.origin.scope
            guard id == command.id, scope.accountBinding == session.accountBinding,
                  scope.containerIdentifier == session.containerIdentifier,
                  scope.environment == session.environment else { throw PersonalCartError.corruptRecord }
        }
        return commands.values.map { command in
            HomeLeaveStatus(command: command,
                submitted: checkpoints[HomeLeaveCheckpoint(command: command, stage: .submitted).id] != nil,
                completed: checkpoints[HomeLeaveCheckpoint(command: command, stage: .completed).id] != nil)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The submission marker alone is not a permanent destructive capability.
    /// Recheck just before invoking native purge: a covering grant may have
    /// arrived while the adapter was awaiting other validation work.
    func requireCurrentHomeLeaveSubmission(_ command: HomeLeaveCommand) throws {
        guard let retained = try homeLeaves().first(where: { $0.id == command.id }),
              retained.command == command, retained.submitted, !retained.completed else {
            throw PersonalCartError.scopeChanged
        }
        let records = try values(HomeAccessRecord.self, kind: "homeAccess")
        guard records[command.quarantineID] == command.quarantine else { throw PersonalCartError.incompleteImport }
        for (id, record) in records {
            try record.validate()
            guard record.id == id else { throw PersonalCartError.corruptRecord }
            if record.scope == command.origin.scope,
               case .joined(let observed) = record.action,
               observed.contains(command.quarantineID) { throw PersonalCartError.scopeChanged }
        }
    }

    func homeLeaveEvidence(scope: HomeEffectScope) throws -> HomeLeaveEvidence {
        guard scope == homeEffectScope(householdID: scope.householdID, listID: scope.listID) else {
            throw PersonalCartError.accountChanged
        }
        let checkouts = try values(PersonalCheckoutIntent.self, kind: "checkout")
        let published = Set(try values(UUID.self, kind: "published").values)
        let restores = try values(PersonalRestoreIntent.self, kind: "restore")
        let restored = Set(try values(UUID.self, kind: "restorePublished").values)
        let ownCheckouts = checkouts.filter {
            $0.value.token.householdID == scope.householdID && $0.value.token.listID == scope.listID
        }
        var ownRestores: Set<UUID> = []
        var unresolvedRestores: Set<UUID> = []
        for (id, restore) in restores where !restored.contains(id) {
            if let declared = restore.homeEffectScope {
                guard declared == scope else { continue }
                if let checkout = checkouts[restore.checkoutID],
                   checkout.token.householdID != scope.householdID || checkout.token.listID != scope.listID {
                    throw PersonalCartError.corruptRecord
                }
                ownRestores.insert(id)
            } else if ownCheckouts[restore.checkoutID] != nil {
                ownRestores.insert(id)
            } else if checkouts[restore.checkoutID] == nil {
                // Legacy restore imports may precede their checkout and have no
                // declared home. Retain that uncertainty without waiting for a peer.
                unresolvedRestores.insert(id)
            }
        }
        let generations = try values(PersonalCartCommandResult.self, kind: "cart").values.compactMap(\.edit)
            .filter { $0.snapshot.householdID == scope.householdID && $0.snapshot.listID == scope.listID }
            .map { $0.snapshot.token.generation }
        return HomeLeaveEvidence(checkoutIDs: Set(ownCheckouts.keys).subtracting(published),
            restoreIDs: ownRestores, unresolvedRestoreIDs: unresolvedRestores, cartGenerations: Set(generations))
    }
}

extension PersonalCartService {
    func captureHomeLeaveEvidence(scope: HomeEffectScope) throws -> HomeLeaveEvidence {
        try transact(save: false) { try $0.homeLeaveEvidence(scope: scope) }
    }

    /// Called only after explicit confirmation and fresh native participant checks.
    /// Authorization and the block commit together, before any destructive API.
    func retainHomeLeave(_ command: HomeLeaveCommand) throws {
        try command.validate()
        try transact { repository in
            guard command.origin.scope == repository.homeEffectScope(householdID: command.origin.scope.householdID,
                listID: command.origin.scope.listID) else { throw PersonalCartError.accountChanged }
            try repository.insert(id: command.id, kind: "homeLeave", command: command, value: command)
            let block = command.quarantine
            try repository.insert(id: block.id, kind: "homeAccess", command: block, value: block)
        }
    }

    func retainedHomeLeaves() throws -> [HomeLeaveStatus] {
        try transact(save: false) { try $0.homeLeaves() }
    }

    /// Called only after the adapter verifies the exact operation's postcondition.
    /// Completion does not grant access or erase the original quarantine.
    func completeHomeLeave(_ command: HomeLeaveCommand) throws {
        try transact { repository in
            guard let retained = try repository.homeLeaves().first(where: { $0.id == command.id }),
                  retained.command == command,
                  try repository.values(HomeAccessRecord.self, kind: "homeAccess")[command.quarantineID] == command.quarantine else {
                throw PersonalCartError.incompleteImport
            }
            let checkpoint = HomeLeaveCheckpoint(command: command, stage: .completed)
            try repository.insert(id: checkpoint.id, kind: "homeLeaveCheckpoint", command: checkpoint, value: checkpoint)
        }
    }

    /// The single transition that authorizes native submission. A submitted but
    /// uncertain operation is reconciliation-only, never an automatic purge retry.
    /// A later grant also retires the authorization even before completion imports.
    func beginHomeLeaveSubmission(_ command: HomeLeaveCommand, identity: HomeNativeAccessIdentity, storeURL: URL) throws -> Bool {
        try transact { repository in
            guard command.matchesNativeOrigin(identity, storeURL: storeURL),
                  let retained = try repository.homeLeaves().first(where: { $0.id == command.id }),
                  retained.command == command, !retained.submitted, !retained.completed,
                  try repository.values(HomeAccessRecord.self, kind: "homeAccess")[command.quarantineID] == command.quarantine else {
                return false
            }
            let records = try repository.values(HomeAccessRecord.self, kind: "homeAccess").values
            for record in records { try record.validate() }
            // Leaving must not wait for unrelated private effects or their causal
            // dependencies to finish importing. Any covering grant still wins.
            guard !records.contains(where: {
                guard $0.scope == identity.scope else { return false }
                if case .joined(let ids) = $0.action { return ids.contains(command.quarantineID) }
                return false
            }) else { return false }
            let checkpoint = HomeLeaveCheckpoint(command: command, stage: .submitted)
            try repository.insert(id: checkpoint.id, kind: "homeLeaveCheckpoint", command: checkpoint, value: checkpoint)
            return true
        }
    }
}
