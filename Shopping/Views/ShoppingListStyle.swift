import CoreData
import SwiftUI

enum ShoppingListMetrics {
    static let rowInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 8)
}

extension View {
    func shoppingListRowInsets() -> some View {
        listRowInsets(ShoppingListMetrics.rowInsets)
    }

    func shoppingMultilineText() -> some View {
        lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }
}

struct ShoppingFeedbackBar<Action: View>: View {
    let message: String
    private let action: Action

    init(message: String, @ViewBuilder action: () -> Action) {
        self.message = message
        self.action = action()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                messageText
                Spacer(minLength: 8)
                action
            }
            VStack(alignment: .leading, spacing: 8) {
                messageText
                action.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private var messageText: some View {
        Text(message)
            .font(.subheadline)
            .shoppingMultilineText()
    }
}

extension ShoppingFeedbackBar where Action == EmptyView {
    init(message: String) {
        self.init(message: message) { EmptyView() }
    }
}

enum ManagementBatchCopy {
    static func title(_ preview: ManagementBatchPreview) -> String {
        let noun: String
        switch preview.token.entity {
        case .store: noun = "stores"
        case .category: noun = "categories"
        case .catalogItem: noun = "catalog items"
        }
        switch preview.token.action {
        case .archive: return "Archive selected \(noun)?"
        case .restore: return "Restore selected \(noun)?"
        case .delete: return "Delete selected \(noun)?"
        }
    }

    static func message(_ preview: ManagementBatchPreview) -> String {
        var parts: [String] = []
        if preview.deleteCount > 0 { parts.append("\(preview.deleteCount) will be permanently deleted") }
        if preview.archiveCount > 0 { parts.append("\(preview.archiveCount) will be archived") }
        if preview.restoreCount > 0 { parts.append("\(preview.restoreCount) will be restored") }
        if preview.retainedCount > 0 { parts.append("\(preview.retainedCount) will be retained because it is already in that state or must remain recoverable") }
        let summary = parts.isEmpty ? "No selected records are still available" : parts.joined(separator: ". ")
        return summary + ". Changes made after this review will be skipped."
    }

    static func result(_ result: ManagementBatchResult) -> String {
        var parts: [String] = []
        if result.deletedCount > 0 { parts.append("Deleted \(result.deletedCount)") }
        if result.archivedCount > 0 { parts.append("Archived \(result.archivedCount)") }
        if result.restoredCount > 0 { parts.append("Restored \(result.restoredCount)") }
        if result.retainedCount > 0 { parts.append("Retained \(result.retainedCount)") }
        if result.changedCount > 0 { parts.append("Skipped \(result.changedCount) changed") }
        if result.missingCount > 0 { parts.append("Skipped \(result.missingCount) unavailable") }
        return parts.isEmpty ? "No items needed changes." : parts.joined(separator: ". ") + "."
    }
}
