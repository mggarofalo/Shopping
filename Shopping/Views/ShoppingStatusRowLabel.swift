import SwiftUI

/// A name with a short trailing status, such as Archived or On grocery list. The status sits
/// beside the name at standard sizes so it never adds a line, and drops below the full-width
/// name at accessibility sizes.
struct ShoppingStatusRowLabel: View {
    let name: String
    let status: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Text(name)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if let status {
                Text(status)
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
        ShoppingStatusRowLabel(name: "Neighborhood Market (closed)", status: "Archived")
            .shoppingItemRow()
            .shoppingListRowInsets()
    }
}
