import SwiftUI

struct ShoppingQuantityEditor: View {
    let itemName: String
    let actionAvailable: Bool
    let itemChanged: Bool
    let initialQuantity: Int64?
    let onSave: (Int64?) -> Void
    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(itemName: String, quantity: Int64?, actionAvailable: Bool, itemChanged: Bool = false, onSave: @escaping (Int64?) -> Void) {
        self.itemName = itemName
        self.actionAvailable = actionAvailable
        self.itemChanged = itemChanged
        self.initialQuantity = quantity
        self.onSave = onSave
        _text = State(initialValue: quantity.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ShoppingQuantityField(text: $text, focus: $focused, identifier: "shopping.quantity.input")
                    if !text.isEmpty {
                        Button("Clear quantity") { text = "" }
                            .accessibilityIdentifier("shopping.quantity.clear")
                    }
                } footer: {
                    Text(itemChanged
                         ? "This item changed while you were editing. Close and reopen Quantity to use the latest value."
                         : "Enter a whole number from 1 to 99, or leave blank when no quantity is needed.")
                }
                Section("Item") {
                    Text(itemName).fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("Quantity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("shopping.quantity.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard actionAvailable, !itemChanged, ShoppingQuantityField.isValid(text) else { return }
                        if Int64(text) != initialQuantity { onSave(Int64(text)) }
                        dismiss()
                    }
                    .disabled(!actionAvailable || itemChanged || !ShoppingQuantityField.isValid(text))
                    .accessibilityIdentifier("shopping.quantity.save")
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }
}

#Preview {
    ShoppingQuantityEditor(itemName: "Bananas", quantity: 6, actionAvailable: true) { _ in }
}
