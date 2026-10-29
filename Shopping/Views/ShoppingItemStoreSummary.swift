import SwiftUI

struct ShoppingItemStoreSummary: View {
    let anyStore: Bool
    let storeLabels: [String]
    let hasSavedStores: Bool
    var hasResolvedIdentity = true
    /// A selected-store purchase-rule symbol; the row value announces its meaning.
    var symbol: String?

    var body: some View {
        Group {
            if storeLabels.isEmpty {
                text(fullSummary).fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    ForEach((0...storeLabels.count).reversed(), id: \.self) { count in
                        text(summary(showing: count)).fixedSize(horizontal: true, vertical: true)
                    }
                    text(summary(showing: 0)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(Color.grocerySecondary)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func text(_ summary: String) -> Text {
        guard let symbol else { return Text(summary) }
        return Text("\(Image(systemName: symbol)) \(summary)")
    }

    private var fullSummary: String {
        CatalogSuggestionPurchaseSummary.text(anyStore: anyStore, savedStoreLabels: storeLabels,
            hasSavedStores: hasSavedStores, hasResolvedIdentity: hasResolvedIdentity)
    }

    private func summary(showing count: Int) -> String {
        var labels = Array(storeLabels.prefix(count))
        if anyStore { labels.insert("Any Store", at: 0) }
        let omitted = storeLabels.count - count
        if omitted > 0 {
            let archived = storeLabels.dropFirst(count).contains { $0.hasSuffix(" (archived)") }
            labels.append(archived ? "+\(omitted) (includes archived)" : "+\(omitted)")
        }
        return labels.joined(separator: ", ")
    }
}

#Preview {
    ShoppingItemStoreSummary(anyStore: false, storeLabels: ["Costco", "Publix"], hasSavedStores: true)
}
