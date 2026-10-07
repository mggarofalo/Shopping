import SwiftUI

/// Text stays a draft until it is either blank or a whole quantity in the saved range.
struct ShoppingQuantityField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let identifier: String
    var clearIdentifier: String? = nil
    var showsLabel = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            if showsLabel { Text("Quantity") }
            HStack(spacing: 0) {
                TextField("Optional", text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(!showsLabel || dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                    .font(showsLabel ? .body : .title2)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .focused(focus)
                    .accessibilityLabel("Quantity")
                    .accessibilityIdentifier(identifier)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear quantity")
                    .accessibilityIdentifier(clearIdentifier ?? identifier + ".clear")
                }
            }
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
