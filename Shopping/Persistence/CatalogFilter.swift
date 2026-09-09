import Foundation

struct PurchaseRuleValue: Equatable {
    let explicitStoreIDs: Set<UUID>
    let anyStore: Bool
    var hasResolvedIdentity: Bool = true

    var allowsAnyStore: Bool { hasResolvedIdentity && (anyStore || explicitStoreIDs.isEmpty) }
}

enum PurchaseAvailability: Equatable {
    case unavailable
    case mustBuyHere
    case flexibleHere
    case needsStore
}

struct PurchaseFilter: Equatable {
    let selectedStoreID: UUID?
    let includedStoreIDs: Set<UUID>
    let excludedStoreIDs: Set<UUID>
    let requiresAnyStore: Bool?

    init(
        selectedStoreID: UUID? = nil,
        includedStoreIDs: Set<UUID> = [],
        excludedStoreIDs: Set<UUID> = [],
        requiresAnyStore: Bool? = nil
    ) {
        self.selectedStoreID = selectedStoreID
        self.includedStoreIDs = includedStoreIDs
        self.excludedStoreIDs = excludedStoreIDs
        self.requiresAnyStore = requiresAnyStore
    }

    func matches(_ value: PurchaseRuleValue, activeStoreIDs: Set<UUID>) -> Bool {
        let tags = value.explicitStoreIDs.intersection(activeStoreIDs)
        if let selectedStoreID {
            guard activeStoreIDs.contains(selectedStoreID),
                  value.allowsAnyStore || tags.contains(selectedStoreID) else { return false }
        }
        guard includedStoreIDs.isEmpty || !tags.isDisjoint(with: includedStoreIDs),
              tags.isDisjoint(with: excludedStoreIDs) else { return false }
        if let requiresAnyStore, value.allowsAnyStore != requiresAnyStore { return false }
        return true
    }

    func availability(
        of value: PurchaseRuleValue,
        selectedStoreID: UUID?,
        activeStoreIDs: Set<UUID>
    ) -> PurchaseAvailability {
        let tags = value.explicitStoreIDs.intersection(activeStoreIDs)
        guard let selectedStoreID else {
            return !value.allowsAnyStore && tags.isEmpty ? .needsStore : .unavailable
        }
        guard activeStoreIDs.contains(selectedStoreID),
              value.allowsAnyStore || tags.contains(selectedStoreID) else { return .unavailable }
        return !value.allowsAnyStore && tags == [selectedStoreID] ? .mustBuyHere : .flexibleHere
    }
}

struct CatalogItemFilter: Equatable {
    let purchase: PurchaseFilter
    let text: String
    let categoryIDs: Set<UUID>

    init(
        purchase: PurchaseFilter = PurchaseFilter(),
        text: String = "",
        categoryIDs: Set<UUID> = []
    ) {
        self.purchase = purchase
        self.text = text
        self.categoryIDs = categoryIDs
    }
}

struct GroceryNeedFilter: Equatable {
    let purchase: PurchaseFilter
    let text: String
    let categoryID: UUID?
    let carted: Bool?
    let urgency: String?

    init(
        purchase: PurchaseFilter = PurchaseFilter(),
        text: String = "",
        categoryID: UUID? = nil,
        carted: Bool? = nil,
        urgency: String? = nil
    ) {
        self.purchase = purchase
        self.text = text
        self.categoryID = categoryID
        self.carted = carted
        self.urgency = urgency
    }

    func sanitized(activeStoreIDs: Set<UUID>, activeCategoryIDs: Set<UUID>) -> GroceryNeedFilter {
        GroceryNeedFilter(
            purchase: PurchaseFilter(
                selectedStoreID: purchase.selectedStoreID.flatMap {
                    activeStoreIDs.contains($0) ? $0 : nil
                },
                includedStoreIDs: purchase.includedStoreIDs.intersection(activeStoreIDs),
                excludedStoreIDs: purchase.excludedStoreIDs.intersection(activeStoreIDs),
                requiresAnyStore: purchase.requiresAnyStore
            ),
            text: text,
            categoryID: categoryID.flatMap { activeCategoryIDs.contains($0) ? $0 : nil },
            carted: carted,
            urgency: urgency
        )
    }
}

enum CatalogProjection {
    static func normalizedName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func suggestionNames(from values: [(name: String, isArchived: Bool)]) -> [String] {
        var namesByKey: [String: String] = [:]
        let sorted = values.sorted {
            let firstKey = normalizedName($0.name)
            let secondKey = normalizedName($1.name)
            return firstKey == secondKey ? $0.name < $1.name : firstKey < secondKey
        }
        for value in sorted where !value.isArchived {
            let displayName = value.name.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
            let key = normalizedName(displayName)
            guard !key.isEmpty, namesByKey[key] == nil else { continue }
            namesByKey[key] = displayName
        }
        return namesByKey.values.sorted { normalizedName($0) < normalizedName($1) }
    }


    static func textMatches(_ candidate: String, query: String) -> Bool {
        let query = normalizedName(query)
        return query.isEmpty || normalizedName(candidate).contains(query)
    }
}

struct CatalogSuggestionCandidate: Equatable {
    let id: UUID
    let name: String
    let categoryID: UUID?
    let explicitStoreIDs: Set<UUID>
    let anyStore: Bool
    let isArchived: Bool
    let hasResolvedIdentity: Bool

    init(
        id: UUID,
        name: String,
        categoryID: UUID? = nil,
        explicitStoreIDs: Set<UUID> = [],
        anyStore: Bool = true,
        isArchived: Bool = false,
        hasResolvedIdentity: Bool = true
    ) {
        self.id = id
        self.name = name
        self.categoryID = categoryID
        self.explicitStoreIDs = explicitStoreIDs
        self.anyStore = anyStore
        self.isArchived = isArchived
        self.hasResolvedIdentity = hasResolvedIdentity
    }
}

enum CatalogSuggestionMatchKind: Int, Equatable {
    case exact
    case prefix
    case substring
    case fuzzy
}

struct CatalogSuggestion: Equatable {
    let candidate: CatalogSuggestionCandidate
    let matchKind: CatalogSuggestionMatchKind
    let similarity: Double
}

enum CatalogSuggestionPurchaseSummary {
    static func text(
        anyStore: Bool,
        savedStoreLabels: [String],
        hasSavedStores: Bool = true
    ) -> String {
        let labels = savedStoreLabels.sorted()
        if anyStore || !hasSavedStores {
            return labels.isEmpty
                ? "Any store"
                : "Any store · Also: \(labels.joined(separator: ", "))"
        }
        return labels.isEmpty ? "Unresolved purchase rules" : labels.joined(separator: ", ")
    }
}

enum CatalogSuggestionMatcher {
    static let fuzzyMinimumQueryLength = 3
    static let fuzzyMinimumSimilarity = 0.85
    static let maximumResults = 5

    static func suggestions(
        for query: String,
        candidates: [CatalogSuggestionCandidate],
        purchaseFilter: PurchaseFilter = PurchaseFilter(),
        activeStoreIDs: Set<UUID> = [],
        categoryID: UUID? = nil
    ) -> [CatalogSuggestion] {
        let normalizedQuery = CatalogProjection.normalizedName(query)
        guard !normalizedQuery.isEmpty else { return [] }

        var candidatesByID: [UUID: PreparedCandidate] = [:]
        var duplicateIDs: Set<UUID> = []
        for candidate in candidates {
            guard !duplicateIDs.contains(candidate.id) else { continue }
            let prepared = PreparedCandidate(
                candidate: candidate,
                normalizedName: CatalogProjection.normalizedName(candidate.name)
            )
            if candidatesByID.removeValue(forKey: candidate.id) != nil {
                duplicateIDs.insert(candidate.id)
                continue
            }
            candidatesByID[candidate.id] = prepared
        }
        let normalizedQueryScalars = normalizedQuery.unicodeScalars.map(\.value)
        var best: [RankedSuggestion] = []
        for prepared in candidatesByID.values {
            let candidate = prepared.candidate
            let normalizedCandidate = prepared.normalizedName
            guard !candidate.isArchived, candidate.hasResolvedIdentity, !normalizedCandidate.isEmpty,
                  categoryID == nil || candidate.categoryID == categoryID,
                  purchaseFilter.matches(
                    PurchaseRuleValue(
                        explicitStoreIDs: candidate.explicitStoreIDs,
                        anyStore: candidate.anyStore,
                        hasResolvedIdentity: candidate.hasResolvedIdentity
                    ),
                    activeStoreIDs: activeStoreIDs
                  )
            else { continue }

            let ranked: RankedSuggestion
            if normalizedCandidate == normalizedQuery {
                ranked = prepared.ranked(matchKind: .exact, similarity: 1)
            } else if normalizedCandidate.hasPrefix(normalizedQuery) {
                ranked = prepared.ranked(matchKind: .prefix, similarity: 1)
            } else if normalizedCandidate.contains(normalizedQuery) {
                ranked = prepared.ranked(matchKind: .substring, similarity: 1)
            } else {
                guard normalizedQuery.count >= fuzzyMinimumQueryLength else { continue }
                let similarity = jaroWinklerSimilarity(
                    normalizedQueryScalars,
                    normalizedCandidate.unicodeScalars.map(\.value)
                )
                guard similarity >= fuzzyMinimumSimilarity else { continue }
                ranked = prepared.ranked(matchKind: .fuzzy, similarity: similarity)
            }

            if best.count == maximumResults,
               let last = best.last,
               !rankedSuggestionComesFirst(ranked, last) {
                continue
            }
            let insertionIndex = best.firstIndex {
                rankedSuggestionComesFirst(ranked, $0)
            } ?? best.endIndex
            best.insert(ranked, at: insertionIndex)
            if best.count > maximumResults { best.removeLast() }
        }

        return best.map(\.suggestion)
    }

    static func jaroWinklerSimilarity(_ lhs: String, _ rhs: String) -> Double {
        jaroWinklerSimilarity(
            CatalogProjection.normalizedName(lhs).unicodeScalars.map(\.value),
            CatalogProjection.normalizedName(rhs).unicodeScalars.map(\.value)
        )
    }

    private static func jaroWinklerSimilarity(
        _ first: [UInt32],
        _ second: [UInt32]
    ) -> Double {
        guard !first.isEmpty, !second.isEmpty else { return first == second ? 1 : 0 }
        if first == second { return 1 }

        let matchDistance = max(max(first.count, second.count) / 2 - 1, 0)
        var firstMatches = Array(repeating: false, count: first.count)
        var secondMatches = Array(repeating: false, count: second.count)
        var matches = 0

        for firstIndex in first.indices {
            let lowerBound = max(0, firstIndex - matchDistance)
            let upperBound = min(firstIndex + matchDistance + 1, second.count)
            guard lowerBound < upperBound else { continue }
            for secondIndex in lowerBound..<upperBound
            where !secondMatches[secondIndex] && first[firstIndex] == second[secondIndex] {
                firstMatches[firstIndex] = true
                secondMatches[secondIndex] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        let matchedFirst = first.indices.filter { firstMatches[$0] }.map { first[$0] }
        let matchedSecond = second.indices.filter { secondMatches[$0] }.map { second[$0] }
        let transpositions = Double(
            zip(matchedFirst, matchedSecond).filter { $0.0 != $0.1 }.count
        ) / 2
        let matchCount = Double(matches)
        let jaro = (
            matchCount / Double(first.count) +
            matchCount / Double(second.count) +
            (matchCount - transpositions) / matchCount
        ) / 3
        guard jaro > 0.7 else { return jaro }
        let prefixLength = zip(first, second).prefix { $0.0 == $0.1 }.prefix(4).count
        return jaro + Double(prefixLength) * 0.1 * (1 - jaro)
    }

    private struct PreparedCandidate {
        let candidate: CatalogSuggestionCandidate
        let normalizedName: String

        func ranked(matchKind: CatalogSuggestionMatchKind, similarity: Double) -> RankedSuggestion {
            RankedSuggestion(
                suggestion: CatalogSuggestion(
                    candidate: candidate,
                    matchKind: matchKind,
                    similarity: similarity
                ),
                normalizedName: normalizedName
            )
        }
    }

    private struct RankedSuggestion {
        let suggestion: CatalogSuggestion
        let normalizedName: String
    }

    private static func rankedSuggestionComesFirst(
        _ lhs: RankedSuggestion,
        _ rhs: RankedSuggestion
    ) -> Bool {
        if lhs.suggestion.matchKind != rhs.suggestion.matchKind {
            return lhs.suggestion.matchKind.rawValue < rhs.suggestion.matchKind.rawValue
        }
        if lhs.suggestion.matchKind == .fuzzy,
           lhs.suggestion.similarity != rhs.suggestion.similarity {
            return lhs.suggestion.similarity > rhs.suggestion.similarity
        }
        if lhs.normalizedName != rhs.normalizedName { return lhs.normalizedName < rhs.normalizedName }
        if lhs.suggestion.candidate.name != rhs.suggestion.candidate.name {
            return lhs.suggestion.candidate.name < rhs.suggestion.candidate.name
        }
        return lhs.suggestion.candidate.id.uuidString < rhs.suggestion.candidate.id.uuidString
    }
}
