import Foundation

/// Portable account-private identities; neither store URLs nor managed object IDs
/// are authority across devices. Native share verification happens before a grant.
struct HomeEffectScope: Codable, Equatable, Sendable {
    let accountBinding: String
    let containerIdentifier: String
    let environment: String
    let householdID: UUID
    let listID: UUID

    init(session: ShopperSession, householdID: UUID, listID: UUID) {
        accountBinding = session.accountBinding
        containerIdentifier = session.containerIdentifier
        environment = session.environment
        self.householdID = householdID
        self.listID = listID
    }
}

struct HomeEffectShare: Codable, Equatable, Hashable, Sendable {
    let recordName: String
    let zoneName: String
    let zoneOwnerName: String
}

struct HomeAccessRecord: Codable, Equatable, Sendable {
    enum Loss: String, Codable, Sendable { case left, revoked }
    enum Action: Codable, Equatable, Sendable {
        case blocked(Loss)
        case joined(observedBlockIDs: Set<UUID>)
    }
    let id: UUID
    let scope: HomeEffectScope
    let share: HomeEffectShare
    let action: Action

    func validate() throws {
        guard id != PersistenceModel.unsetID, scope.householdID != PersistenceModel.unsetID,
              scope.listID != PersistenceModel.unsetID, !scope.accountBinding.isEmpty,
              !scope.containerIdentifier.isEmpty, !scope.environment.isEmpty,
              !share.recordName.isEmpty, !share.zoneName.isEmpty, !share.zoneOwnerName.isEmpty else {
            throw PersonalCartError.corruptRecord
        }
        if case .joined(let ids) = action, ids.contains(PersistenceModel.unsetID) {
            throw PersonalCartError.corruptRecord
        }
    }
}

/// Captured with a command, never upgraded when that command is replayed.
struct HomeEffectAuthority: Codable, Equatable, Hashable, Sendable {
    let observedBlockIDs: Set<UUID>
    let grantID: UUID?
    static let legacy = HomeEffectAuthority(observedBlockIDs: [], grantID: nil)
}

enum HomeEffectKind: String, Codable, Sendable { case checkout, restore, cartGeneration }

/// A block remains evidence forever. A grant can only authorize new commands and
/// must cover every imported block. A later block therefore wins on every device.
struct HomeEffectAccess {
    let records: [HomeAccessRecord]
    let blockIDs: Set<UUID>
    let hasCompleteBoundary: Bool

    init(records: [HomeAccessRecord], requiredBlockIDs: Set<UUID> = []) throws {
        for record in records { try record.validate() }
        guard Set(records.map(\.id)).count == records.count,
              Set(records.map { $0.scope.accountBinding }).count <= 1,
              records.allSatisfy({ $0.scope == records.first?.scope }) else { throw PersonalCartError.corruptRecord }
        self.records = records
        let imported = Set(records.compactMap { if case .blocked = $0.action { $0.id } else { nil } })
        blockIDs = records.reduce(into: imported.union(requiredBlockIDs)) { ids, record in
            if case .joined(let observed) = record.action { ids.formUnion(observed) }
        }
        hasCompleteBoundary = blockIDs == imported
    }

    var capturedAuthority: HomeEffectAuthority {
        guard hasCompleteBoundary, hasConsistentShare else { return HomeEffectAuthority(observedBlockIDs: blockIDs, grantID: nil) }
        return HomeEffectAuthority(observedBlockIDs: blockIDs,
            grantID: currentGrants.map(\.id).max { $0.uuidString < $1.uuidString })
    }

    var currentGrants: [HomeAccessRecord] {
        records.filter {
            if case .joined(let observed) = $0.action { return observed == blockIDs }
            return false
        }
    }

    private var hasConsistentShare: Bool { Set(currentGrants.map(\.share)).count <= 1 }

    func permitsPublication(_ authority: HomeEffectAuthority) -> Bool {
        guard hasCompleteBoundary, hasConsistentShare, authority.observedBlockIDs == blockIDs else { return false }
        guard let grantID = authority.grantID else { return blockIDs.isEmpty }
        return records.contains {
            guard $0.id == grantID, case .joined(let observed) = $0.action else { return false }
            return observed == blockIDs
        }
    }

    func validateCapture(_ authority: HomeEffectAuthority) throws {
        guard authority.observedBlockIDs == blockIDs else { throw PersonalCartError.scopeChanged }
        // A fresh private-only capture while access is lost stays private even if a
        // grant subsequently arrives. A claimed grant must still be fully imported.
        if authority.grantID != nil, !permitsPublication(authority) { throw PersonalCartError.scopeChanged }
    }
}
