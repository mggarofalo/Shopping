import Foundation

struct HomeCandidate: Equatable, Identifiable, Sendable {
    enum Access: String, Sendable { case owner, contributor, restricted, unresolved }
    let graph: HomeGraphIdentity
    let name: String
    let access: Access
    var id: HomeGraphIdentity { graph }
}

struct HomeDiscovery: Equatable, Sendable {
    let homes: [HomeCandidate]
    let hasIncompleteRoots: Bool
}

/// UI selection authority, separate from durable cart/outbox authority.
/// Account authentication remains exclusively owned by ShopperSessionProvider.
@MainActor
final class ActiveHomeCoordinator: ObservableObject {
    enum DiscoveryState: Equatable {
        case unknown
        case incomplete
        case complete
    }

    enum Readiness: Equatable {
        case accountUnavailable
        case waitingForImport
        case choiceRequired
        case selectedHomeUnavailable
        case ready(ActiveHomeScope)
    }

    struct Request: Equatable, Sendable {
        fileprivate let session: ShopperSession
        fileprivate let generation: UInt64
        fileprivate let sequence: UInt64
        var sessionForValidation: ShopperSession { session }
    }

    @Published private(set) var readiness: Readiness = .accountUnavailable
    @Published private(set) var discoveryState: DiscoveryState = .unknown
    @Published private(set) var homes: [HomeCandidate] = []
    @Published private(set) var pendingInvitation = false
    private(set) var generation: UInt64 = 0
    /// Changes only when a person explicitly chooses to keep, open, or leave a home.
    /// Discovery and store rebinding can renew command authority without replacing that choice.
    private(set) var choiceRevision: UInt64 = 0
    private(set) var choiceAuthority = UICommandAuthority()
    private var requestSequence: UInt64 = 0
    private var session: ShopperSession?
    private var savedScope: ActiveHomeScope?
    private var selectionDeferred = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var activeScope: ActiveHomeScope? {
        if case .ready(let scope) = readiness { return scope }
        return nil
    }

    func bind(_ session: ShopperSession?) {
        guard self.session != session else { return }
        choiceAuthority.retire()
        choiceAuthority = UICommandAuthority()
        generation &+= 1
        self.session = session
        homes = []
        discoveryState = .unknown
        pendingInvitation = false
        savedScope = nil
        selectionDeferred = session.map { defaults.bool(forKey: key($0) + ".deferred") } ?? false
        readiness = session == nil ? .accountUnavailable : .waitingForImport
        if let session, let data = defaults.data(forKey: key(session)),
           let saved = try? JSONDecoder().decode(ActiveHomeScope.self, from: data),
           saved.accountBinding == session.accountBinding,
           saved.containerIdentifier == session.containerIdentifier,
           saved.environment == session.environment {
            savedScope = saved
        }
    }

    func beginDiscovery() -> Request? {
        guard let session else { return nil }
        requestSequence &+= 1
        return Request(session: session, generation: generation, sequence: requestSequence)
    }

    /// Discovery results and their errors share the same request-order fence.
    func isCurrent(_ request: Request) -> Bool {
        request.session == session && request.generation == generation && request.sequence == requestSequence
    }

    @discardableResult
    func reconcile(_ discovery: HomeDiscovery, request: Request) -> Bool {
        guard isCurrent(request) else { return false }
        let previous = activeScope
        let previousAccess = homes.first { $0.graph == previous?.graph }?.access
        // Duplicate identities are incomplete data, never a reason to choose the first row.
        let grouped = Dictionary(grouping: discovery.homes, by: \.graph)
        homes = discovery.homes.filter { grouped[$0.graph]?.count == 1 }
        discoveryState = discovery.hasIncompleteRoots || grouped.count != discovery.homes.count
            ? .incomplete : .complete
        if let savedScope {
            readiness = homes.contains { $0.graph == savedScope.graph && $0.access != .unresolved }
                ? .ready(savedScope) : .selectedHomeUnavailable
        } else if homes.count == 1, !discovery.hasIncompleteRoots,
                  grouped.count == discovery.homes.count, !pendingInvitation, !selectionDeferred,
                  let home = homes.first, home.access != .unresolved {
            activate(home.graph, session: request.session)
        } else {
            readiness = homes.isEmpty ? .waitingForImport : .choiceRequired
        }
        let currentAccess = homes.first { $0.graph == activeScope?.graph }?.access
        if previous != activeScope || previousAccess != currentAccess { generation &+= 1 }
        return true
    }

    func select(_ graph: HomeGraphIdentity, renewingAuthority: Bool = false,
                recordingChoice: Bool = true) throws {
        guard let session, homes.contains(where: { $0.graph == graph && $0.access != .unresolved }) else {
            throw NeedServiceError.scopeChanged
        }
        if recordingChoice { recordExplicitChoice() }
        guard activeScope?.graph != graph || renewingAuthority else { return }
        generation &+= 1
        activate(graph, session: session)
    }

    /// Not now is durable even when there is no current home to keep selected.
    /// Later discovery must not interpret the sole accepted home as an implicit choice.
    func deferSelection() {
        guard let session else { return }
        recordExplicitChoice()
        selectionDeferred = true
        defaults.set(true, forKey: key(session) + ".deferred")
    }

    func recordExplicitChoice() {
        choiceAuthority.retire()
        choiceAuthority = UICommandAuthority()
        choiceRevision &+= 1
    }

    func setInvitationPending(_ pending: Bool) { pendingInvitation = pending }

    /// Forget only the selection that the operation captured. A later home choice or
    /// account change must survive an earlier leave or deletion completing.
    @discardableResult
    func forgetSelectedHome(_ scope: ActiveHomeScope, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration, let session,
              scope.accountBinding == session.accountBinding,
              scope.containerIdentifier == session.containerIdentifier,
              scope.environment == session.environment,
              savedScope == scope else { return false }
        recordExplicitChoice()
        generation &+= 1
        requestSequence &+= 1
        savedScope = nil
        defaults.removeObject(forKey: key(session))
        defaults.removeObject(forKey: key(session) + ".deferred")
        selectionDeferred = false
        homes.removeAll { $0.graph == scope.graph }
        if homes.count == 1, discoveryState == .complete, !pendingInvitation,
           let home = homes.first, home.access != .unresolved {
            activate(home.graph, session: session)
        } else {
            readiness = homes.isEmpty ? .waitingForImport : .choiceRequired
        }
        return true
    }

    func isCurrent(scope: ActiveHomeScope, generation: UInt64) -> Bool {
        self.generation == generation && activeScope == scope
    }

    private func activate(_ graph: HomeGraphIdentity, session: ShopperSession) {
        let scope = ActiveHomeScope(session: session, graph: graph)
        savedScope = scope
        selectionDeferred = false
        defaults.removeObject(forKey: key(session) + ".deferred")
        readiness = .ready(scope)
        if let data = try? JSONEncoder().encode(scope) { defaults.set(data, forKey: key(session)) }
    }

    private func key(_ session: ShopperSession) -> String {
        "shopping.activeHome.v1." + ActiveHomeScope.accountNamespace(session)
    }
}
