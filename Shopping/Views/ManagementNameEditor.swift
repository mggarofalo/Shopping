import SwiftUI

struct StoreEditorSession: Identifiable {
    let id = UUID()
    let store: Store?
    let scope: StoreManagementCommandScope
}

struct ManagementNameEditor: View {
    let title: String
    @Binding var name: String
    let fieldTitle: String
    let fieldIdentifier: String
    let saveLabel: String
    let initiallyFocused: Bool
    let unavailableMessage: String
    @FocusState private var nameFocused: Bool
    let available: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    private var canSave: Bool {
        available && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(fieldTitle, text: $name)
                    .accessibilityIdentifier(fieldIdentifier)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { onSave() } }
                if !available {
                    Text(unavailableMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear {
                guard initiallyFocused else { return }
                DispatchQueue.main.async { nameFocused = true }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onSave) { Image(systemName: "checkmark") }
                        .accessibilityLabel(saveLabel)
                        .disabled(!canSave)
                }
            }
        }
    }
}
