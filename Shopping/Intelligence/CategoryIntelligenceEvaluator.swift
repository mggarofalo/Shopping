import Foundation

struct CategoryIntelligenceEvaluator {
    func evaluate(
        _ cases: [CategoryIntelligenceEvaluationCase],
        using classifier: some CategoryIntelligenceClassifying
    ) async throws -> CategoryIntelligenceEvaluation {
        var correctCount = 0
        var expectedAssignmentCount = 0
        var correctAssignmentCount = 0
        var expectedAbstentionCount = 0
        var correctAbstentionCount = 0
        var durations: [Duration] = []
        let clock = ContinuousClock()

        for evaluationCase in cases {
            try Task.checkCancellation()
            let start = clock.now
            let proposal = try await classifier.classify(evaluationCase.request)
            durations.append(start.duration(to: clock.now))
            if proposal == evaluationCase.expected { correctCount += 1 }
            switch evaluationCase.expected {
            case .category, .newCategory:
                expectedAssignmentCount += 1
                if proposal == evaluationCase.expected { correctAssignmentCount += 1 }
            case .abstain:
                expectedAbstentionCount += 1
                if proposal == .abstain { correctAbstentionCount += 1 }
            }
        }

        return CategoryIntelligenceEvaluation(
            totalCount: cases.count,
            correctCount: correctCount,
            expectedAssignmentCount: expectedAssignmentCount,
            correctAssignmentCount: correctAssignmentCount,
            expectedAbstentionCount: expectedAbstentionCount,
            correctAbstentionCount: correctAbstentionCount,
            durations: durations
        )
    }
}
