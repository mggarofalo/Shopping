import CoreData
import SwiftUI

struct CategoryPills: View {
    @Binding var selection: UUID?
    let categories: [Category]
    var includeUnavailable = false
    var onAddCategory: (() -> Void)? = nil
    var onRecommendCategory: (() -> Void)? = nil
    var recommendationIsRunning = false
    var recommendationIsEnabled = true

    var body: some View {
        Section {
            PillFlowLayout {
                SelectionPill(
                    title: "Uncategorized",
                    isSelected: selection == nil,
                    identifier: "shopping.category.none"
                ) { selection = nil }
                ForEach(categories.filter { !$0.isArchived }, id: \.objectID) { category in
                    SelectionPill(
                        title: category.name,
                        isSelected: selection == category.id,
                        identifier: "shopping.category.\(category.id.uuidString)"
                    ) { selection = category.id }
                }
                if let selection,
                   let archived = categories.first(where: { $0.id == selection && $0.isArchived }) {
                    SelectionPill(title: "\(archived.name) · Archived", isSelected: true) {}
                        .disabled(true)
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
            HStack {
                Text("Category")
                Spacer()
                if recommendationIsRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Recommending category")
                        .accessibilityIdentifier("shopping.category.recommendation.progress")
                } else if let onRecommendCategory {
                    Button(action: onRecommendCategory) {
                        Label("Recommend category", systemImage: "sparkles")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!recommendationIsEnabled)
                    .accessibilityHint("Uses on-device intelligence")
                    .accessibilityIdentifier("shopping.category.recommendation")
                }
            }
        }
    }
}
