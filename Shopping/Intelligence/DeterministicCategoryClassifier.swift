import Foundation

struct DeterministicCategoryClassifier: CategoryIntelligenceClassifying {
    static let minimumSimilarity = 0.88
    static let minimumWinningMargin = 0.04

    func classify(_ request: CategoryIntelligenceRequest) async throws -> CategoryIntelligenceProposal {
        try Task.checkCancellation()
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

        var scores: [(id: UUID, similarity: Double)] = []
        for candidate in request.candidates {
            try Task.checkCancellation()
            var maximumSimilarity = 0.0
            for evidenceName in candidate.normalizedRememberedItemNames {
                try Task.checkCancellation()
                let similarity = Self.containsWholePhrase(itemName, evidenceName) ||
                    Self.containsWholePhrase(evidenceName, itemName)
                    ? 0.95
                    : CatalogSuggestionMatcher.jaroWinklerSimilarity(itemName, evidenceName)
                maximumSimilarity = max(maximumSimilarity, similarity)
            }
            scores.append((candidate.id, maximumSimilarity))
        }
        scores.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.uuidString < $1.0.uuidString
        }

        guard let best = scores.first, best.1 >= Self.minimumSimilarity else { return .abstain }
        if scores.count > 1, best.1 - scores[1].1 < Self.minimumWinningMargin {
            return .abstain
        }
        return .category(best.0)
    }

    private static func containsWholePhrase(_ value: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value.range(of: phrase, range: searchStart..<value.endIndex) {
            let startsAtBoundary = range.lowerBound == value.startIndex ||
                !value[value.index(before: range.lowerBound)].isLetterOrNumber
            let endsAtBoundary = range.upperBound == value.endIndex ||
                !value[range.upperBound].isLetterOrNumber
            if startsAtBoundary && endsAtBoundary { return true }
            searchStart = value.index(after: range.lowerBound)
        }
        return false
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
