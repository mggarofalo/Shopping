import SwiftUI

/// Sizes a trailing row control, such as the grocery quantity, by its label's height while
/// placing it at least `minimumHitSize` tall. The extra hit region extends evenly into the
/// row's text padding, so the control aligns with the name's first line without making the
/// row taller than an equivalent Catalog row.
struct ShoppingRowAccessoryLayout: Layout {
    var minimumHitSize = ShoppingListMetrics.minimumRowHeight

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let label = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        return CGSize(width: max(label.width, minimumHitSize), height: label.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
            proposal: ProposedViewSize(width: bounds.width, height: max(bounds.height, minimumHitSize)))
    }

    /// The label is centered in the hit region, so its baselines keep their natural offsets.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard let label = subviews.first?.dimensions(in: .unspecified) else { return nil }
        switch guide {
        case .firstTextBaseline: return bounds.minY + label[.firstTextBaseline]
        case .lastTextBaseline: return bounds.minY + label[.lastTextBaseline]
        default: return nil
        }
    }
}

#Preview {
    List {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Bananas").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            ShoppingRowAccessoryLayout {
                Button {} label: {
                    Text("6×").frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
