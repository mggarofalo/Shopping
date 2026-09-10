#if DEBUG
import SwiftUI

struct CategoryIntelligenceDebugView: View {
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.items()) private var items: FetchedResults<Item>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var itemName = "Avocados"
    @State private var requestID = 0
    @State private var pendingRequest: CategoryIntelligenceRequest?
    @State private var result: ResultState = .idle

    var body: some View {
        Form {
            Section("On-device model") {
                LabeledContent("Availability", value: availability.title)
                LabeledContent("Language and region", value: Locale.current.identifier)
                LabeledContent("Active categories", value: candidates.count.formatted())
                LabeledContent("Remembered examples", value: rememberedItemCount.formatted())
            }

            Section("Try a grocery") {
                TextField("Item name", text: $itemName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.go)
                    .onSubmit(requestSuggestion)
                    .onChange(of: itemName) { _, _ in cancelStaleRequest() }

                Button("Suggest category", systemImage: "sparkles", action: requestSuggestion)
                    .disabled(!canRequestSuggestion)

                resultView
            }

            Section {
                Text("This debug tool returns a proposal only. It does not edit groceries, categories, or catalog history.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Category Intelligence")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: requestID) {
            guard requestID > 0, let pendingRequest else { return }
            await suggestCategory(pendingRequest)
        }
    }

    private var canonicalList: GroceryList? {
        GroceryRowScope.canonicalList(
            Array(lists), households: Array(households), selection: selection
        )
    }

    private var candidates: [CategoryIntelligenceCandidate] {
        let activeCategories = GroceryRowScope.validCategories(
            Array(categories), canonicalList: canonicalList
        ).filter { !$0.isArchived }
        let activeCategoryIDs = Set(activeCategories.map(\.id))
        let rememberedItems = GroceryRowScope.validItems(
            Array(items), canonicalList: canonicalList
        ).filter {
            !$0.isArchived && $0.category.map { activeCategoryIDs.contains($0.id) } == true
        }
        let itemsByCategory = Dictionary(grouping: rememberedItems) { $0.category?.id }

        return activeCategories.map { category in
            CategoryIntelligenceCandidate(
                id: category.id,
                name: category.name,
                evidence: (itemsByCategory[category.id] ?? []).map {
                    .init(name: $0.name, source: .rememberedCatalog)
                }
            )
        }
    }

    private var rememberedItemCount: Int {
        candidates.reduce(0) { $0 + $1.rememberedItemNames.count }
    }

    private var availability: CategoryIntelligenceAvailability {
        FoundationModelCategoryClassifier.availability()
    }

    private var canRequestSuggestion: Bool {
        availability.allowsSuggestions
            && !CatalogProjection.normalizedName(itemName).isEmpty
            && !candidates.isEmpty
            && candidates.count <= FoundationModelCategoryClassifier.maximumCategoryCount
            && result != .running
    }

    @ViewBuilder
    private var resultView: some View {
        switch result {
        case .idle:
            Text(idleMessage)
                .foregroundStyle(.secondary)
        case .running:
            HStack {
                ProgressView()
                Text("Thinking on this iPhone…")
            }
        case .suggestion(let category, let milliseconds):
            LabeledContent("Suggestion") {
                VStack(alignment: .trailing) {
                    Text(category)
                    Text("\(milliseconds) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .abstained(let milliseconds):
            LabeledContent("Suggestion") {
                VStack(alignment: .trailing) {
                    Text("None")
                    Text("\(milliseconds) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }

    private func requestSuggestion() {
        guard canRequestSuggestion else { return }
        pendingRequest = CategoryIntelligenceRequest(
            itemName: itemName,
            candidates: candidates
        )
        requestID += 1
    }

    private func cancelStaleRequest() {
        guard pendingRequest != nil else { return }
        pendingRequest = nil
        result = .idle
        requestID += 1
    }

    private var idleMessage: String {
        guard canonicalList != nil else { return "The selected household is unavailable." }
        guard !candidates.isEmpty else { return "Add an active category before requesting a suggestion." }
        guard candidates.count <= FoundationModelCategoryClassifier.maximumCategoryCount else {
            return "This prototype supports up to \(FoundationModelCategoryClassifier.maximumCategoryCount) active categories."
        }
        return "Enter an item to request a suggestion from your categories."
    }

    @MainActor
    private func suggestCategory(_ request: CategoryIntelligenceRequest) async {
        result = .running
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let proposal = try await FoundationModelCategoryClassifier().classify(request)
            try Task.checkCancellation()
            let milliseconds = start.duration(to: clock.now).milliseconds
            switch proposal {
            case .category(let categoryID):
                guard let category = request.candidates.first(where: { $0.id == categoryID }) else {
                    result = .failed("The model returned an unknown category.")
                    return
                }
                result = .suggestion(category.name, milliseconds)
            case .abstain:
                result = .abstained(milliseconds)
            }
        } catch is CancellationError {
            return
        } catch {
            result = .failed("No suggestion: \(String(describing: error))")
        }
    }
}

private enum ResultState: Equatable {
    case idle
    case running
    case suggestion(String, Int)
    case abstained(Int)
    case failed(String)
}

private extension CategoryIntelligenceAvailability {
    var title: String {
        switch self {
        case .available: "Available"
        case .unsupportedOS: "Requires iOS 26 or newer"
        case .deviceNotEligible: "This device is not eligible"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is disabled"
        case .modelNotReady: "The model is not ready"
        case .unsupportedLanguage: "The current language is unsupported"
        case .unavailable: "Unavailable"
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = self.components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

#Preview {
    ShoppingPreviewHost(.populated) {
        NavigationStack {
            CategoryIntelligenceDebugView()
        }
    }
}
#endif
