import CryptoKit
import Foundation

/// A local graph identity is deliberately stronger than the synchronized household UUID.
/// Reimporting a removed share requires choosing its new local graph explicitly.
struct HomeGraphIdentity: Codable, Equatable, Hashable, Sendable {
    let storeIdentifier: String
    let rootURI: String
    let householdID: UUID
    let listID: UUID
}

struct ActiveHomeScope: Codable, Equatable, Hashable, Sendable {
    let accountBinding: String
    let containerIdentifier: String
    let environment: String
    let graph: HomeGraphIdentity

    init(session: ShopperSession, graph: HomeGraphIdentity) {
        accountBinding = session.accountBinding
        containerIdentifier = session.containerIdentifier
        environment = session.environment
        self.graph = graph
    }

    var preferenceNamespace: String {
        // Fixed ordered fields avoid depending on JSON dictionary key ordering.
        Self.digest([accountBinding, containerIdentifier, environment, graph.storeIdentifier,
            graph.rootURI, graph.householdID.uuidString, graph.listID.uuidString])
    }

    static func accountNamespace(_ session: ShopperSession) -> String {
        digest([session.accountBinding, session.containerIdentifier, session.environment])
    }

    private static func digest(_ fields: [String]) -> String {
        let data = try! JSONEncoder().encode(fields) // An array of strings is always encodable.
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

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
    @Published private(set) var homes: [HomeCandidate] = []
    @Published private(set) var pendingInvitation = false
    private(set) var generation: UInt64 = 0
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
        generation &+= 1
        self.session = session
        homes = []
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

    @discardableResult
    func reconcile(_ discovery: HomeDiscovery, request: Request) -> Bool {
        guard request.session == session, request.generation == generation,
              request.sequence == requestSequence else { return false }
        let previous = activeScope
        let previousAccess = homes.first { $0.graph == previous?.graph }?.access
        // Duplicate identities are incomplete data, never a reason to choose the first row.
        let grouped = Dictionary(grouping: discovery.homes, by: \.graph)
        homes = discovery.homes.filter { grouped[$0.graph]?.count == 1 }
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

    func select(_ graph: HomeGraphIdentity, renewingAuthority: Bool = false) throws {
        guard let session, homes.contains(where: { $0.graph == graph && $0.access != .unresolved }) else {
            throw NeedServiceError.scopeChanged
        }
        guard activeScope?.graph != graph || renewingAuthority else { return }
        generation &+= 1
        activate(graph, session: session)
    }

    /// Not now is durable even when there is no current home to keep selected.
    /// Later discovery must not interpret the sole accepted home as an implicit choice.
    func deferSelection() {
        guard let session else { return }
        selectionDeferred = true
        defaults.set(true, forKey: key(session) + ".deferred")
    }

    func setInvitationPending(_ pending: Bool) { pendingInvitation = pending }

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
