import SwiftUI

struct IntelligentCategoryPicker: View {
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var persistenceSelection
    @Binding var selection: UUID?
    let itemName: String
    let categories: [Category]
    let householdID: UUID?
    let listID: UUID?
    var includeUnavailable = false
    var onAddCategory: (() -> Void)?

    @State private var requestGeneration = 0
    @State private var pendingRequest: CategoryIntelligenceRequest?
    @State private var result: ResultState = .idle

    var body: some View {
        Group {
            CategoryPills(
                selection: $selection,
                categories: categories,
                includeUnavailable: includeUnavailable,
                onAddCategory: onAddCategory,
                onRecommendCategory: intelligenceAvailable ? requestRecommendation : nil,
                recommendationIsRunning: intelligenceAvailable && result == .running,
                recommendationIsEnabled: canRequestRecommendation
            )

            if intelligenceAvailable {
                recommendationResult
            }
        }
        .task(id: requestGeneration) {
            guard requestGeneration > 0, let pendingRequest, result == .running else { return }
            await runRecommendation(pendingRequest)
        }
        .onChange(of: itemName) { _, _ in
            guard result != .idle else { return }
            dismissRecommendation()
        }
        .onChange(of: selection) { _, _ in
            guard result != .idle else { return }
            dismissRecommendation()
        }
    }

    private var intelligenceAvailable: Bool {
        FoundationModelCategoryClassifier.availability().allowsSuggestions
    }

    private var canRequestRecommendation: Bool {
        intelligenceAvailable && result != .running &&
            !CatalogProjection.normalizedName(itemName).isEmpty
    }

    @ViewBuilder
    private var recommendationResult: some View {
        switch result {
        case .idle, .running:
            EmptyView()
        case .existing(let categoryID, let categoryName):
            recommendationSection(
                title: categoryName,
                subtitle: "Existing category",
                actionTitle: "Use \(categoryName)"
            ) {
                useExistingCategory(categoryID)
            }
        case .newCategory(let categoryName):
            recommendationSection(
                title: categoryName,
                subtitle: "New category",
                actionTitle: "Create \(categoryName)"
            ) {
                createCategory(named: categoryName)
            }
        case .abstained:
            recommendationSection(
                title: "No recommendation",
                subtitle: "Choose a category below or leave this item uncategorized."
            )
        case .failed(let message):
            recommendationSection(title: "Recommendation unavailable", subtitle: message)
        }
    }

    private func recommendationSection(
        title: String,
        subtitle: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .shoppingMultilineText()
                    }
                    Spacer(minLength: 12)
                    Button(action: dismissRecommendation) {
                        Label("Dismiss recommendation", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("shopping.category.recommendation.dismiss")
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("shopping.category.recommendation.accept")
                }
            }
        } header: {
            Label("Recommendation", systemImage: "sparkles")
        }
    }

    private func requestRecommendation() {
        guard canRequestRecommendation else { return }
        guard FoundationModelCategoryClassifier.availability().allowsSuggestions else {
            dismissRecommendation()
            return
        }
        do {
            let snapshot = try CategoryIntelligenceCandidateLoader().load(
                from: viewContext,
                selection: persistenceSelection
            )
            guard snapshot.candidates.count <= FoundationModelCategoryClassifier.maximumCategoryCount else {
                result = .failed("There are too many active categories to make a recommendation.")
                return
            }
            pendingRequest = CategoryIntelligenceRequest(
                itemName: itemName,
                candidates: snapshot.candidates
            )
            result = .running
            requestGeneration += 1
        } catch {
            result = .failed("The current household categories could not be read.")
        }
    }

    private func dismissRecommendation() {
        pendingRequest = nil
        result = .idle
        requestGeneration += 1
    }

    private func useExistingCategory(_ categoryID: UUID) {
        guard categories.contains(where: { $0.id == categoryID && !$0.isArchived }) else {
            result = .failed("That category is no longer available. Request another recommendation.")
            return
        }
        selection = categoryID
        hapticFeedback.play(.lightImpact)
        dismissRecommendation()
    }

    private func createCategory(named name: String) {
        guard let service, let householdID, let listID,
              persistenceSelection.householdID == householdID,
              persistenceSelection.listID == listID else {
            result = .failed("The household changed. Request another recommendation.")
            return
        }
        do {
            let snapshot = try CategoryIntelligenceCandidateLoader().load(
                from: viewContext,
                selection: persistenceSelection
            )
            let normalizedName = CatalogProjection.normalizedName(name)
            let matches = snapshot.candidates.filter {
                CatalogProjection.normalizedName($0.name) == normalizedName
            }
            let categoryID: UUID
            if matches.count == 1, let existing = matches.first {
                categoryID = existing.id
            } else {
                guard matches.isEmpty else {
                    result = .failed("Matching categories have conflicting identities. Choose one manually.")
                    return
                }
                categoryID = try service.createCategory(
                    name: name,
                    householdID: householdID,
                    listID: listID
                )
            }
            selection = categoryID
            hapticFeedback.play(.success)
            dismissRecommendation()
        } catch {
            result = .failed("The category could not be created. Your item draft is unchanged.")
        }
    }

    @MainActor
    private func runRecommendation(_ request: CategoryIntelligenceRequest) async {
        do {
            let proposal = try await FoundationModelCategoryClassifier().classify(request)
            try Task.checkCancellation()
            switch proposal {
            case .category(let categoryID):
                guard let category = request.candidates.first(where: { $0.id == categoryID }) else {
                    result = .failed("The recommended category is no longer available.")
                    return
                }
                result = .existing(categoryID, category.name)
            case .newCategory(let categoryName):
                result = .newCategory(categoryName)
            case .abstain:
                result = .abstained
            }
        } catch is CancellationError {
            return
        } catch {
            result = .failed("Choose a category manually or try again.")
        }
    }

    private enum ResultState: Equatable {
        case idle
        case running
        case existing(UUID, String)
        case newCategory(String)
        case abstained
        case failed(String)
    }
}
