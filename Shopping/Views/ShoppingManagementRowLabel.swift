import SwiftUI

/// Management names keep the full width when accessibility text needs more room.
struct ShoppingManagementRowLabel: View {
    let name: String
    let isArchived: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Text(name)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if isArchived {
                Text("Archived")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    List {
        ShoppingManagementRowLabel(name: "Neighborhood Market (closed)", isArchived: true)
            .shoppingItemRow()
            .shoppingListRowInsets()
    }
}
