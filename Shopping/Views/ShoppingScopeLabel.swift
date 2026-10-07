import SwiftUI

/// Identical label measurement for store menus and filter controls on every list.
struct ShoppingScopeLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
        }
            .font(.subheadline)
            .imageScale(.small)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: ShoppingListMetrics.minimumRowHeight)
            .contentShape(Rectangle())
    }
}

#Preview {
    HStack {
        ShoppingScopeLabel(title: "Choose store", systemImage: "storefront")
        Spacer()
        ShoppingScopeLabel(title: "Filters", systemImage: "line.3.horizontal.decrease.circle")
    }
}
