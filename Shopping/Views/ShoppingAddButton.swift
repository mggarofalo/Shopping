import SwiftUI

struct ShoppingAddButton: View {
    let title: String
    let identifier: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var symbolSize = 17

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(.tint)
                .frame(minWidth: 44, minHeight: ShoppingListMetrics.minimumRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    NavigationStack {
        Text("Shopping")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShoppingAddButton(title: "Add item", identifier: "preview.add") {}
                }
            }
    }
}
