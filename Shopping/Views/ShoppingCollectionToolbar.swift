import SwiftUI

/// Stores is the reference interaction for collection selection and creation.
struct ShoppingCollectionToolbar: ToolbarContent {
    let isSelecting: Bool
    let allSelected: Bool
    let selectAvailable: Bool
    let addAvailable: Bool
    let addTitle: String
    let identifierPrefix: String
    let select: () -> Void
    let add: () -> Void
    let done: () -> Void
    let toggleAll: () -> Void

    var body: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: done)
                    .accessibilityIdentifier(identifierPrefix + ".done")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(allSelected ? "Deselect All" : "Select All", action: toggleAll)
                    .accessibilityIdentifier(identifierPrefix + ".selectAll")
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button("Select", action: select)
                        .disabled(!selectAvailable)
                        .accessibilityIdentifier(identifierPrefix + ".select")
                    ShoppingAddButton(title: addTitle, identifier: identifierPrefix + ".add", action: add)
                        .disabled(!addAvailable)
                }
                .font(.body)
            }
        }
    }
}
