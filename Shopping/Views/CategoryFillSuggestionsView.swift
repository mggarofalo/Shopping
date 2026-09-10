import SwiftUI

struct CategoryFillSuggestionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var persistenceSelection

    let categoryID: UUID
    let categoryName: String
    let purchaseFilter: PurchaseFilter
    let onAdded: (Int) -> Void

    @State private var candidates: [CategoryFillCandidate] = []
    @State private var categoryRevision: Int64?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var isLoading = true
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Finding saved items…")
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        "No Saved Items to Add",
                        systemImage: "checkmark.circle",
                        description: Text("Every eligible \(categoryName) item is already on the list, or there are no saved items in this category yet.")
                    )
                } else {
                    List(candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
            .navigationTitle(categoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addButtonTitle, action: addSelectedItems)
                        .disabled(selectedItemIDs.isEmpty || isLoading || isAdding)
                        .accessibilityIdentifier("shopping.category.fill.add")
                }
            }
            .overlay {
                if isAdding {
                    ProgressView()
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Couldn’t Add Items", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "The selected items could not be added.")
            }
            .task { loadCandidates() }
        }
        .interactiveDismissDisabled(isAdding)
    }

    private var addButtonTitle: String {
        selectedItemIDs.isEmpty ? "Add" : "Add \(selectedItemIDs.count)"
    }

    private func candidateRow(_ candidate: CategoryFillCandidate) -> some View {
        let isSelected = selectedItemIDs.contains(candidate.itemID)
        return Button {
            toggle(candidate.itemID)
        } label: {
            HStack {
                Text(candidate.name)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func toggle(_ itemID: UUID) {
        if selectedItemIDs.remove(itemID) == nil {
            selectedItemIDs.insert(itemID)
        }
        hapticFeedback.play(.lightImpact)
    }

    private func loadCandidates() {
        guard FoundationModelCategoryClassifier.availability().allowsSuggestions else {
            dismiss()
            return
        }
        do {
            let snapshot = try CategoryFillCandidateLoader().load(
                from: viewContext,
                selection: persistenceSelection,
                categoryID: categoryID,
                purchaseFilter: purchaseFilter
            )
            candidates = snapshot.candidates
            categoryRevision = snapshot.categoryRevision
            selectedItemIDs.formIntersection(Set(candidates.map(\.itemID)))
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = "The current category and saved items could not be read."
        }
    }

    private func addSelectedItems() {
        guard FoundationModelCategoryClassifier.availability().allowsSuggestions else {
            dismiss()
            return
        }
        guard let service,
              let householdID = persistenceSelection.householdID,
              let listID = persistenceSelection.listID,
              let categoryRevision else {
            errorMessage = "The household changed. Open the suggestions again."
            return
        }
        isAdding = true
        var addedCount = 0
        var skippedCount = 0
        for candidate in candidates where selectedItemIDs.contains(candidate.itemID) {
            do {
                switch try service.applyCatalogSuggestion(
                    itemID: candidate.itemID,
                    itemRevision: candidate.itemRevision,
                    expectedNeedID: nil,
                    expectedNeedRevision: nil,
                    listID: listID,
                    householdID: householdID,
                    purchaseFilter: purchaseFilter,
                    categoryID: categoryID,
                    expectedCategoryRevision: categoryRevision,
                    textFilter: "",
                    urgentOnly: false,
                    renewCarted: false
                ) {
                case .added:
                    addedCount += 1
                case .renewed, .focusExisting:
                    skippedCount += 1
                }
            } catch {
                skippedCount += 1
            }
        }
        isAdding = false
        guard addedCount > 0 else {
            errorMessage = "Those items changed or are already on the list. Nothing was added."
            loadCandidates()
            return
        }
        hapticFeedback.play(.success)
        onAdded(addedCount)
        if skippedCount == 0 {
            dismiss()
        } else {
            errorMessage = "Added \(addedCount). Skipped \(skippedCount) because they changed or were already on the list."
            loadCandidates()
        }
    }
}

extension CategoryFillCandidate: Identifiable {
    var id: UUID { itemID }
}

#Preview {
    Text("Category fill suggestions require a configured household preview.")
}
