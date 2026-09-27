import SwiftUI

struct CategoryCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @State private var name = ""
    @State private var error: Error?
    @State private var isSaving = false
    @FocusState private var nameIsFocused: Bool
    let householdID: UUID?
    let listID: UUID?
    let onSelected: (UUID) -> Void

    private var canSave: Bool {
        !isSaving && service != nil && householdID != nil && listID != nil
            && !CatalogProjection.normalizedName(name).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Category name", text: $name)
                    .accessibilityIdentifier("shopping.category.name")
                    .focused($nameIsFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                if let error {
                    Text(error.localizedDescription).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                        .accessibilityIdentifier("shopping.category.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save category", systemImage: "checkmark", action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier("shopping.category.save")
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear { DispatchQueue.main.async { nameIsFocused = true } }
        }
    }

    private func save() {
        guard canSave, let service, let householdID, let listID else { return }
        isSaving = true
        let name = self.name
        Task {
            defer { isSaving = false }
            do {
                let id = try await Task.detached(priority: .userInitiated) {
                    try service.createCategory(name: name, householdID: householdID, listID: listID)
                }.value
                guard selection.householdID == householdID, selection.listID == listID else { return }
                onSelected(id)
                dismiss()
            } catch { self.error = error }
        }
    }
}
