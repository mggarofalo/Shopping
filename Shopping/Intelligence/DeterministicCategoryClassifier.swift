import Foundation

struct DeterministicCategoryClassifier: CategoryIntelligenceClassifying {
    static let minimumSimilarity = 0.88
    static let minimumWinningMargin = 0.04

    func classify(_ request: CategoryIntelligenceRequest) async throws -> CategoryIntelligenceProposal {
        let itemName = CatalogProjection.normalizedName(request.itemName)
        guard !itemName.isEmpty else { throw CategoryIntelligenceError.emptyItemName }
        guard !request.candidates.isEmpty else { return .abstain }

        let exactMatches = request.candidates.filter {
            $0.normalizedRememberedItemNames.contains(itemName)
        }
        if exactMatches.count == 1, let match = exactMatches.first {
            return .category(match.id)
        }
        guard exactMatches.isEmpty else { return .abstain }

        let scores = request.candidates.map { candidate in
            let similarity = candidate.normalizedRememberedItemNames.map { evidenceName in
                if itemName.contains(evidenceName) || evidenceName.contains(itemName) { return 0.95 }
                return CatalogSuggestionMatcher.jaroWinklerSimilarity(itemName, evidenceName)
            }.max() ?? 0
            return (candidate.id, similarity)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.uuidString < $1.0.uuidString
        }

        guard let best = scores.first, best.1 >= Self.minimumSimilarity else { return .abstain }
        if scores.count > 1, best.1 - scores[1].1 < Self.minimumWinningMargin {
            return .abstain
        }
        return .category(best.0)
    }
}
