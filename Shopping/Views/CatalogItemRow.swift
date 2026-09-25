import SwiftUI

struct CatalogItemRow: View {
    @ObservedObject var item: Item
    let validStores: [Store]

    var body: some View {
        CatalogRowColumns {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.caption)
                        .foregroundStyle(Color.grocerySecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.isArchived {
                    Label("Archived", systemImage: "archivebox.fill")
                        .font(.caption).foregroundStyle(Color.grocerySecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            storeSummary
                .font(.caption)
                .foregroundStyle(Color.grocerySecondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.name, fullStoreSummary, item.notes, item.isArchived ? "Archived" : ""]
            .filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @ViewBuilder
    private var storeSummary: some View {
        if storeLabels.isEmpty {
            Text(fullStoreSummary).fixedSize(horizontal: false, vertical: true)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach((0...storeLabels.count).reversed(), id: \.self) { count in
                    Text(summary(showing: count)).fixedSize(horizontal: true, vertical: true)
                }
                // At accessibility sizes, the semantic fallback can wrap instead of clipping.
                Text(summary(showing: 0)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var storeLabels: [String] {
        let assigned = item.stores ?? []
        return validStores.filter { assigned.contains($0) }
            .map { $0.isArchived ? "\($0.name) (archived)" : $0.name }.sorted()
    }

    private func summary(showing count: Int) -> String {
        var labels = Array(storeLabels.prefix(count))
        if item.anyStore { labels.insert("Any Store", at: 0) }
        let omitted = storeLabels.count - count
        if omitted > 0 {
            let includesArchived = storeLabels.dropFirst(count).contains { $0.hasSuffix(" (archived)") }
            labels.append(includesArchived ? "+\(omitted) (includes archived)" : "+\(omitted)")
        }
        return labels.joined(separator: ", ")
    }

    private var fullStoreSummary: String {
        CatalogSuggestionPurchaseSummary.text(anyStore: item.anyStore, savedStoreLabels: storeLabels,
            hasSavedStores: !(item.stores ?? []).isEmpty)
    }
}

/// Native stacks distribute flexible widths equally. This layout assigns the requested
/// 2:1 content columns while measuring each child's intrinsic height at its own width.
private struct CatalogRowColumns: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth = subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + spacing
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        let widths = columnWidths(width)
        let height = zip(subviews, widths).map { view, width in
            view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(bounds.width)
        var x = bounds.minX
        for (view, width) in zip(subviews, widths) {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }

    private func columnWidths(_ width: CGFloat) -> [CGFloat] {
        let available = max(0, width - spacing)
        return [available * 2 / 3, available / 3]
    }
}

#Preview {
    ShoppingPreviewHost(.populated) {
        CatalogView(navigation: GroceryNavigationState())
    }
}
