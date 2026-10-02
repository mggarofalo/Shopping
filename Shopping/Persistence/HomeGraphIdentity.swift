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
