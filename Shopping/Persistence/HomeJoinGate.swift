import CoreData
import Foundation

enum HomeLeaveError: Error, LocalizedError {
    case pendingLeave, privateHistoryPending

    var errorDescription: String? {
        switch self {
        case .pendingLeave:
            return "Finish leaving this home before joining it again. Your personal cart and history are retained."
        case .privateHistoryPending:
            return "Saved membership information is still arriving. Check again before joining this home."
        }
    }
}

enum HomeJoinGate {
    /// The native caller verifies the account/store before and after this read.
    static func validate(persistence: PersistenceController, session: ShopperSession, share: HomeEffectShare) async throws {
        try await Task.detached(priority: .utility) {
            let context = persistence.container.newBackgroundContext()
            try context.performAndWait {
                defer { context.reset() }
                try requireAllowed(repository: PersonalCartRepository(persistence: persistence, context: context, session: session),
                    share: share)
            }
        }.value
    }

    static func requireAllowed(repository: PersonalCartRepository, share: HomeEffectShare) throws {
        func sameZone(_ candidate: HomeEffectShare) -> Bool {
            candidate.zoneName == share.zoneName && candidate.zoneOwnerName == share.zoneOwnerName
        }
        let leaves = try repository.homeLeaves().filter { sameZone($0.command.origin.share) }
        guard !leaves.contains(where: \.requiresResolution) else { throw HomeLeaveError.pendingLeave }
        let records = try repository.values(HomeAccessRecord.self, kind: "homeAccess")
        for (id, record) in records {
            try record.validate()
            guard id == record.id, record.scope.accountBinding == repository.session.accountBinding,
                  record.scope.containerIdentifier == repository.session.containerIdentifier,
                  record.scope.environment == repository.session.environment else { throw PersonalCartError.corruptRecord }
        }
        try requireCompleteEffectDependencies(repository: repository, records: records)
        for leave in leaves {
            guard records[leave.command.quarantineID] == leave.command.quarantine else {
                throw HomeLeaveError.privateHistoryPending
            }
        }
        for record in records.values where sameZone(record.share) {
            switch record.action {
            case .blocked(.left):
                // A block can import before its command or completion checkpoint.
                guard leaves.contains(where: { $0.command.quarantineID == record.id && $0.completed }) else {
                    throw HomeLeaveError.pendingLeave
                }
            case .joined(let observed):
                for id in observed {
                    guard let block = records[id] else { throw HomeLeaveError.privateHistoryPending }
                    guard block.scope == record.scope, case .blocked = block.action else { throw PersonalCartError.corruptRecord }
                }
            default: break
            }
        }
    }

    private static func requireCompleteEffectDependencies(repository: PersonalCartRepository,
        records: [UUID: HomeAccessRecord]) throws {
        func validate(_ authority: HomeEffectAuthority?, scope: HomeEffectScope?) throws {
            guard let authority, !authority.observedBlockIDs.isEmpty else { return }
            // Until the block arrives its native zone is unknown. Do not assume
            // that an effect imported first belongs to a different invitation.
            guard let scope else { throw HomeLeaveError.privateHistoryPending }
            guard scope.accountBinding == repository.session.accountBinding,
                  scope.containerIdentifier == repository.session.containerIdentifier,
                  scope.environment == repository.session.environment else { throw PersonalCartError.corruptRecord }
            for id in authority.observedBlockIDs {
                guard let block = records[id] else { throw HomeLeaveError.privateHistoryPending }
                guard block.scope == scope, case .blocked = block.action else { throw PersonalCartError.corruptRecord }
            }
        }
        let checkouts = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")
        for intent in checkouts.values {
            guard intent.token.accountBinding == repository.session.accountBinding else { throw PersonalCartError.corruptRecord }
            try validate(intent.token.homeEffectAuthority, scope: repository.homeEffectScope(
                householdID: intent.token.householdID, listID: intent.token.listID))
        }
        for restore in try repository.values(PersonalRestoreIntent.self, kind: "restore").values {
            let checkoutScope = checkouts[restore.checkoutID].map {
                repository.homeEffectScope(householdID: $0.token.householdID, listID: $0.token.listID)
            }
            if let declared = restore.homeEffectScope, let checkoutScope, declared != checkoutScope {
                throw PersonalCartError.corruptRecord
            }
            try validate(restore.homeEffectAuthority, scope: restore.homeEffectScope ?? checkoutScope)
        }
        for edit in try repository.values(PersonalCartCommandResult.self, kind: "cart").values.compactMap(\.edit) {
            let token = edit.snapshot.token
            guard token.accountBinding == repository.session.accountBinding else { throw PersonalCartError.corruptRecord }
            try validate(token.homeEffectAuthority, scope: repository.homeEffectScope(
                householdID: token.householdID, listID: token.listID))
        }
    }
}
