import SwiftUI

/// Text stays a draft until it is either blank or a whole quantity in the saved range.
struct ShoppingQuantityField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let identifier: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text("Quantity")
            TextField("Optional", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .frame(maxWidth: .infinity, minHeight: 44)
                .focused(focus)
                .accessibilityLabel("Quantity")
                .accessibilityIdentifier(identifier)
        }
    }

    static func isValid(_ text: String) -> Bool {
        text.isEmpty || (text.utf8.allSatisfy { (48...57).contains($0) }
            && Int(text).map { (1...99).contains($0) } == true)
    }
}

private struct QuantityFieldPreview: View {
    @State private var text = "6"
    @FocusState private var focus: Bool
    var body: some View {
        Form { ShoppingQuantityField(text: $text, focus: $focus, identifier: "preview.quantity") }
    }
}

#Preview { QuantityFieldPreview() }
