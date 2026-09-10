import Foundation

enum CategoryIntelligenceEvidenceSource: Equatable, Sendable {
    case rememberedCatalog
    case oneTimeNeed
}

struct CategoryIntelligenceEvidence: Equatable, Sendable {
    let name: String
    let source: CategoryIntelligenceEvidenceSource
}

struct CategoryIntelligenceCandidate: Equatable, Sendable {
    let id: UUID
    let name: String
    let rememberedItemNames: [String]
    let normalizedRememberedItemNames: [String]

    init(id: UUID, name: String, evidence: [CategoryIntelligenceEvidence] = []) {
        self.id = id
        self.name = name
        self.rememberedItemNames = evidence.compactMap {
            $0.source == .rememberedCatalog ? $0.name : nil
        }
        self.normalizedRememberedItemNames = rememberedItemNames.map(CatalogProjection.normalizedName)
    }
}

struct CategoryIntelligenceRequest: Equatable, Sendable {
    let itemName: String
    let locale: Locale
    let candidates: [CategoryIntelligenceCandidate]

    init(
        itemName: String,
        locale: Locale = .current,
        candidates: [CategoryIntelligenceCandidate]
    ) {
        self.itemName = itemName
        self.locale = locale
        self.candidates = candidates
    }
}

enum CategoryIntelligenceProposal: Equatable, Sendable {
    case category(UUID)
    case abstain
}

enum CategoryIntelligenceAvailability: Equatable, Sendable {
    case available
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLanguage
    case unavailable

    var allowsSuggestions: Bool {
        self == .available
    }
}

enum CategoryIntelligenceError: Error, Equatable {
    case unavailable(CategoryIntelligenceAvailability)
    case emptyItemName
    case noCategories
    case tooManyCategories
    case invalidModelChoice
    case generationFailed
}

protocol CategoryIntelligenceClassifying: Sendable {
    func classify(_ request: CategoryIntelligenceRequest) async throws -> CategoryIntelligenceProposal
}

struct CategoryIntelligenceEvaluationCase: Equatable, Sendable {
    let name: String
    let request: CategoryIntelligenceRequest
    let expected: CategoryIntelligenceProposal
}

struct CategoryIntelligenceEvaluation: Equatable, Sendable {
    let totalCount: Int
    let correctCount: Int
    let expectedAssignmentCount: Int
    let correctAssignmentCount: Int
    let expectedAbstentionCount: Int
    let correctAbstentionCount: Int
    let durations: [Duration]

    var accuracy: Double {
        ratio(correctCount, totalCount)
    }

    var assignmentAccuracy: Double {
        ratio(correctAssignmentCount, expectedAssignmentCount)
    }

    var abstentionAccuracy: Double {
        ratio(correctAbstentionCount, expectedAbstentionCount)
    }

    var worstDuration: Duration {
        durations.max() ?? .zero
    }

    private func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 1 }
        return Double(numerator) / Double(denominator)
    }
}
