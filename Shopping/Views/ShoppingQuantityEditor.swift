import SwiftUI

struct ShoppingQuantityEditor: View {
    let itemName: String
    let actionAvailable: Bool
    let itemChanged: Bool
    let initialQuantity: Int64?
    let onSave: (Int64?) -> Void
    @State private var text: String
    @ScaledMetric(relativeTo: .body) private var sheetHeight: CGFloat = 260
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
                    ShoppingQuantityField(text: $text, focus: $focused,
                                          identifier: "shopping.quantity.input",
                                          clearIdentifier: "shopping.quantity.clear", showsLabel: false)
                } header: {
                    Text(itemName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("shopping.quantity.itemName")
                } footer: {
                    if itemChanged {
                        Text("This item changed. Reopen quantity to use the latest value.")
                    } else if !ShoppingQuantityField.isValid(text) {
                        Text("Use a number from 1 to 99, or leave blank.")
                    }
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
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .onAppear { focused = !dynamicTypeSize.isAccessibilitySize }
    }
}

#Preview {
    ShoppingQuantityEditor(itemName: "Bananas", quantity: 6, actionAvailable: true) { _ in }
}
