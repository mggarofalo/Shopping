import SwiftUI

struct GroceryStorePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var navigation: GroceryNavigationState
    let stores: [Store]
    let counts: [UUID: StorePurchaseCounts]

    var body: some View {
        NavigationStack {
            List {
                ForEach(stores, id: \.objectID) { store in
                    Button {
                        navigation.selectStore(store.id)
                        dismiss()
                    } label: {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 12))
                        layout {
                            HStack {
                                Text(store.name)
                                    .shoppingMultilineText()
                                    .foregroundStyle(Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if navigation.selectedStoreID == store.id {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                            if let value = counts[store.id] {
                                HStack(spacing: 12) {
                                    Label("\(value.mustBuyCount)", systemImage: "lock.fill")
                                    Label("\(value.canBuyCount)", systemImage: "lock.open")
                                }
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(Color.secondary)
                                .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: ShoppingListMetrics.minimumRowHeight)
                    }
                    .accessibilityLabel(store.name)
                    .accessibilityValue(accessibilityValue(for: store))
                    .accessibilityIdentifier("shopping.store.choice.\(store.id.uuidString)")
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
            }
            .navigationTitle("Stores")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    private func accessibilityValue(for store: Store) -> String {
        let selected = navigation.selectedStoreID == store.id ? "Selected. " : ""
        guard let value = counts[store.id] else { return selected }
        return "\(selected)\(value.mustBuyCount) only buy here, \(value.canBuyCount) can buy here"
    }
}

#Preview {
    GroceryStorePicker(navigation: GroceryNavigationState(), stores: [], counts: [:])
}
