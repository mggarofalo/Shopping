import CoreData
import SwiftUI

struct CategoryPills: View {
    @Binding var selection: UUID?
    let categories: [Category]
    var includeUnavailable = false
    var onAddCategory: (() -> Void)? = nil

    var body: some View {
        Section {
            PillFlowLayout {
                SelectionPill(
                    title: "Uncategorized",
                    isSelected: selection == nil,
                    identifier: "shopping.category.none"
                ) { selection = nil }
                ForEach(categories, id: \.objectID) { category in
                    SelectionPill(
                        title: category.name,
                        isSelected: selection == category.id,
                        identifier: "shopping.category.\(category.id.uuidString)"
                    ) { selection = category.id }
                }
                if includeUnavailable, let selection,
                   !categories.contains(where: { $0.id == selection }) {
                    SelectionPill(title: "Unavailable category", isSelected: true) {}
                        .disabled(true)
                }
                if let onAddCategory {
                    Button(action: onAddCategory) {
                        Label("Add category", systemImage: "plus")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("shopping.category.add")
                }
            }
        } header: {
            Text("Category")
        } footer: {
            Text("Categories help filter groceries across all stores.")
                .shoppingMultilineText()
        }
    }
}
