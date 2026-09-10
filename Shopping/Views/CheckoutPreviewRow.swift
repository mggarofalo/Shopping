import SwiftUI

struct CheckoutPreviewRow: View {
    let row: ClearCartedPreviewRow

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                if row.oneTime {
                    Label("One-time", systemImage: "1.circle")
                        .font(.caption)
                        .foregroundStyle(Color.grocerySecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

            if let quantity = row.quantity {
                Text("\(quantity)")
                    .monospacedDigit()
                    .foregroundStyle(Color.grocerySecondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("shopping.checkout.row.\(row.needID.uuidString)")
    }

    private var accessibilityLabel: String {
        var parts = [row.title]
        if let quantity = row.quantity { parts.append("Quantity \(quantity)") }
        if row.oneTime { parts.append("One-time") }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    List {
        CheckoutPreviewRow(row: ClearCartedPreviewRow(
            needID: UUID(), revision: 0, title: "Coffee", quantity: 2, oneTime: true
        ))
    }
    .listStyle(.plain)
}
