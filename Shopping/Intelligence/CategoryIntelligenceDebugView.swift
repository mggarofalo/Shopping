#if DEBUG
import SwiftUI

struct CategoryIntelligenceDebugView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.persistenceSelection) private var selection
    @State private var itemName = "Avocados"
    @State private var requestID = 0
    @State private var pendingRequest: CategoryIntelligenceRequest?
    @State private var lastSnapshot: CategoryIntelligenceCandidateSnapshot?
    @State private var result: ResultState = .idle

    var body: some View {
        Form {
            Section("On-device model") {
                LabeledContent("Availability", value: availability.title)
                LabeledContent("Language and region", value: Locale.current.identifier)
                if let lastSnapshot {
                    LabeledContent("Categories read", value: lastSnapshot.candidates.count.formatted())
                    LabeledContent("Examples read", value: lastSnapshot.rememberedItemCount.formatted())
                } else {
                    LabeledContent("Category source", value: "Read when requested")
                }
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
                Text("Every request reads the current household categories and reusable catalog items. Existing matches and new-category ideas are proposals only; nothing is edited automatically.")
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

    private var availability: CategoryIntelligenceAvailability {
        FoundationModelCategoryClassifier.availability()
    }

    private var canRequestSuggestion: Bool {
        availability.allowsSuggestions
            && !CatalogProjection.normalizedName(itemName).isEmpty
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
            LabeledContent("Existing category") {
                VStack(alignment: .trailing) {
                    Text(category)
                    Text("\(milliseconds) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .newCategory(let category, let milliseconds):
            LabeledContent("New category idea") {
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
        do {
            let snapshot = try CategoryIntelligenceCandidateLoader().load(
                from: viewContext,
                selection: selection
            )
            guard snapshot.candidates.count <= FoundationModelCategoryClassifier.maximumCategoryCount else {
                result = .failed(
                    "This prototype supports up to \(FoundationModelCategoryClassifier.maximumCategoryCount) active categories."
                )
                return
            }
            lastSnapshot = snapshot
            pendingRequest = CategoryIntelligenceRequest(
                itemName: itemName,
                candidates: snapshot.candidates
            )
            requestID += 1
        } catch {
            result = .failed("Couldn’t read the current categories.")
        }
    }

    private func cancelStaleRequest() {
        guard pendingRequest != nil else { return }
        pendingRequest = nil
        result = .idle
        requestID += 1
    }

    private var idleMessage: String {
        "Enter an item to match an existing category or suggest a new one."
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
            case .newCategory(let categoryName):
                result = .newCategory(categoryName, milliseconds)
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
    case newCategory(String, Int)
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
