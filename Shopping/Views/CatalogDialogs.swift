import SwiftUI

struct CatalogBatchDialogs: ViewModifier {
    @Binding var preview: ManagementBatchPreview?
    @Binding var notice: String?
    let apply: (ManagementBatchToken) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                preview.map(ManagementBatchCopy.title) ?? "Update selected catalog items?",
                isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }),
                titleVisibility: .visible
            ) {
                if let preview {
                    switch preview.token.action {
                    case .archive: Button("Archive") { apply(preview.token) }
                    case .restore: Button("Restore") { apply(preview.token) }
                    case .delete: Button("Delete", role: .destructive) { apply(preview.token) }
                    }
                }
                Button("Cancel", role: .cancel) { preview = nil }
            } message: {
                if let preview { Text(ManagementBatchCopy.message(preview)) }
            }
            .alert("Batch update complete", isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(notice ?? "") }
    }
}

enum CatalogAddCopy {
    static func preview(_ value: CatalogAddPreview) -> String {
        var parts: [String] = []
        if value.addCount > 0 { parts.append("\(value.addCount) will be added") }
        if value.existingCount > 0 { parts.append("\(value.existingCount) already on the list will be kept") }
        if value.needAgainCount > 0 { parts.append("\(value.needAgainCount) in the cart will be needed again") }
        if value.archivedCount > 0 { parts.append("\(value.archivedCount) archived will be skipped") }
        if value.ineligibleCount > 0 { parts.append("\(value.ineligibleCount) unavailable at this store will be skipped") }
        return (parts.isEmpty ? "No selected items are available" : parts.joined(separator: ". "))
            + ". Changes made after this review will be skipped."
    }

    static func result(_ value: CatalogAddResult) -> String {
        var parts: [String] = []
        if !value.addedNeedIDs.isEmpty { parts.append("Added \(value.addedNeedIDs.count)") }
        if !value.renewedNeedIDs.isEmpty { parts.append("Needed again \(value.renewedNeedIDs.count)") }
        if !value.existingNeedIDs.isEmpty { parts.append("Already on list \(value.existingNeedIDs.count)") }
        if value.archivedCount > 0 { parts.append("Skipped \(value.archivedCount) archived") }
        if value.ineligibleCount > 0 { parts.append("Skipped \(value.ineligibleCount) unavailable at this store") }
        if value.changedCount > 0 { parts.append("Skipped \(value.changedCount) changed") }
        if value.missingCount > 0 { parts.append("Skipped \(value.missingCount) unavailable") }
        return parts.isEmpty ? "No catalog items were added." : parts.joined(separator: ". ") + "."
    }
}

struct CatalogAddDialogs: ViewModifier {
    @Binding var confirmation: CatalogAddConfirmation?
    @Binding var notice: CatalogAddNotice?
    let apply: (CatalogAddToken) -> Void
    let viewNeed: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                confirmation?.itemName.map { "Need \($0) again?" } ?? "Add selected items to list?",
                isPresented: Binding(
                    get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let confirmation {
                    Button(confirmation.itemName == nil ? "Add to list" : "Need again") {
                        apply(confirmation.preview.token)
                    }
                }
                Button("Cancel", role: .cancel) { confirmation = nil }
            } message: {
                if let confirmation { Text(CatalogAddCopy.preview(confirmation.preview)) }
            }
            .alert("Catalog update complete", isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } }
            )) {
                if let id = notice?.needID { Button("View in groceries") { viewNeed(id) } }
                Button("OK", role: .cancel) { notice = nil }
            } message: { Text(notice?.message ?? "") }
    }
}
