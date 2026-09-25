import SwiftUI

struct WatchItemLabel: View {
    let item: WatchShoppingItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 5) {
            Text(item.name)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.isUrgent {
                Image(systemName: "exclamationmark").foregroundStyle(.orange).accessibilityHidden(true)
            }
            if !item.otherCarts.isEmpty { Image(systemName: "person").font(.caption2).accessibilityHidden(true) }
            if let quantity = item.quantity { Text("\(quantity)").monospacedDigit() }
            if let rule = item.rule { Image(systemName: rule.symbol).font(.caption).accessibilityHidden(true) }
        }
        .font(.callout)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.accessibilityValue)
        .accessibilityHint("Opens item details")
    }


}

#if DEBUG
#Preview { WatchItemLabel(item: WatchPreviewService.sample.grocerySections[0].items[0]) }
#endif
