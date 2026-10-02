import CryptoKit
import Foundation

/// Display context for a home. The saved household name is never changed.
struct HomePresentationName: Equatable, Sendable {
    let name: String
    let context: String?

    var title: String { context.map { "\(name) · \($0)" } ?? name }
}

struct HomePresentationSource: Sendable {
    enum Role: Hashable, Sendable {
        case local, owner, member, readOnly, unknown

        var context: String? {
            switch self {
            case .local: "On This iPhone"
            case .owner: "Owner"
            case .member: "Member"
            case .readOnly: "Read-only"
            case .unknown: nil
            }
        }
    }

    let scope: PersonalCartScopeSnapshot
    let name: String
    let role: Role
}

/// Resolves a whole visible roster, independently of store mounting and row order.
/// Tags come only from the graph's synced semantic IDs, so a copied store or
/// another device gives the same home the same generated label.
enum HomePresentationNames {
    private static let wordList = [
        "Amber", "Apple", "Aster", "Bell", "Birch", "Blue", "Book", "Candle",
        "Cedar", "Clock", "Copper", "Coral", "Cup", "Daisy", "Fern", "Gold",
        "Hazel", "Ivory", "Juniper", "Leaf", "Lemon", "Maple", "Moss", "Olive",
        "Orange", "Pear", "Pine", "Rose", "Sage", "Silver", "Star", "Willow"
    ]

    static func resolve(_ sources: [HomePresentationSource]) -> [PersonalCartScopeSnapshot: HomePresentationName] {
        let groups = Dictionary(grouping: sources) { normalized($0.name) }
        var resolved: [PersonalCartScopeSnapshot: HomePresentationName] = [:]
        var tagDepth: [PersonalCartScopeSnapshot: Int] = [:]
        for group in groups.values {
            guard group.count > 1 else {
                if let source = group.first {
                    resolved[source.scope] = HomePresentationName(name: source.name, context: nil)
                }
                continue
            }
            let byRole = Dictionary(grouping: group, by: \.role)
            let tagged = group.filter { byRole[$0.role, default: []].count > 1 || $0.role.context == nil }
            for source in tagged { tagDepth[source.scope] = 2 }
            for source in group {
                let context = tagDepth[source.scope].map { tag(source.scope, words: $0) } ?? source.role.context
                resolved[source.scope] = HomePresentationName(name: source.name, context: context)
            }
        }
        // A generated context can equal another home's literal name. Check the
        // final labels across the full roster, including homes with unique names.
        while true {
            let collisions = Dictionary(grouping: sources) {
                normalized(resolved[$0.scope]?.title ?? $0.name)
            }.values.filter { Set($0.map(\.scope)).count > 1 }
            guard !collisions.isEmpty else { break }
            for source in collisions.flatMap({ $0 }) {
                let depth = (tagDepth[source.scope] ?? 1) + 1
                tagDepth[source.scope] = depth
                resolved[source.scope] = HomePresentationName(name: source.name,
                    context: tag(source.scope, words: depth))
            }
        }
        return resolved
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func tag(_ scope: PersonalCartScopeSnapshot, words count: Int) -> String {
        let seed = scope.householdID.uuidString.lowercased() + "/" + scope.listID.uuidString.lowercased()
        var parts: [String] = []
        var round = 0
        while parts.count < count {
            let digest = SHA256.hash(data: Data((seed + "/" + String(round)).utf8))
            parts.append(contentsOf: digest.map { wordList[Int($0) % wordList.count] })
            round += 1
        }
        return parts.prefix(count).joined(separator: " ")
    }
}
