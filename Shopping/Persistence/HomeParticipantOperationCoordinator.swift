import Foundation

/// Purging a participant zone affects the whole zone, regardless of which root
/// or share-record name a caller used to reach it.
struct HomeParticipantZone: Hashable, Sendable {
    let accountBinding: String
    let containerIdentifier: String
    let environment: String
    let zoneName: String
    let zoneOwnerName: String

    init(session: ShopperSession, share: HomeEffectShare) {
        accountBinding = session.accountBinding
        containerIdentifier = session.containerIdentifier
        environment = session.environment
        zoneName = share.zoneName
        zoneOwnerName = share.zoneOwnerName
    }
}

/// Local native operations retain their turn through callback completion. This
/// is not a server-side or cross-device conditional-purge guarantee.
actor HomeParticipantOperationCoordinator {
    private var active: Set<HomeParticipantZone> = []
    private var waiting: [HomeParticipantZone: [CheckedContinuation<Void, Never>]] = [:]
    private let didQueue: (@Sendable (HomeParticipantZone) -> Void)?

    init(didQueue: (@Sendable (HomeParticipantZone) -> Void)? = nil) { self.didQueue = didQueue }

    func perform<Value: Sendable>(in zone: HomeParticipantZone,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        if active.contains(zone) {
            await withCheckedContinuation {
                waiting[zone, default: []].append($0)
                didQueue?(zone)
            }
        } else { active.insert(zone) }
        defer { release(zone) }
        return try await operation()
    }

    private func release(_ zone: HomeParticipantZone) {
        guard var next = waiting[zone], !next.isEmpty else {
            active.remove(zone)
            waiting.removeValue(forKey: zone)
            return
        }
        let continuation = next.removeFirst()
        waiting[zone] = next
        continuation.resume()
    }
}
