import SwiftUI

struct CategoryCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @State private var name = ""
    @State private var error: Error?
    @FocusState private var nameIsFocused: Bool
    let householdID: UUID?
    let listID: UUID?
    let onSelected: (UUID) -> Void

    private var canSave: Bool {
        service != nil && householdID != nil && listID != nil
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
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("shopping.category.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save category", systemImage: "checkmark", action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier("shopping.category.save")
                }
            }
            .onAppear { DispatchQueue.main.async { nameIsFocused = true } }
        }
    }

    private func save() {
        guard canSave, let service, let householdID, let listID else { return }
        do {
            onSelected(try service.createCategory(
                name: name, householdID: householdID, listID: listID
            ))
            dismiss()
        } catch {
            self.error = error
        }
    }
}
