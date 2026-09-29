import SwiftUI

/// Native stacks distribute flexible widths equally. This layout assigns the requested
/// 2:1 content columns while measuring each child's intrinsic height at its own width.
struct ShoppingItemColumns: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth = subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + spacing
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        let widths = columnWidths(width)
        let dimensions = zip(subviews, widths).map { view, width in
            view.dimensions(in: ProposedViewSize(width: width, height: nil))
        }
        let baseline = dimensions.map { $0[.firstTextBaseline] }.max() ?? 0
        let height = dimensions.map { $0.height + baseline - $0[.firstTextBaseline] }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(bounds.width)
        let dimensions = zip(subviews, widths).map { view, width in
            view.dimensions(in: ProposedViewSize(width: width, height: nil))
        }
        let baseline = dimensions.map { $0[.firstTextBaseline] }.max() ?? 0
        var x = bounds.minX
        for ((view, width), dimensions) in zip(zip(subviews, widths), dimensions) {
            view.place(at: CGPoint(x: x, y: bounds.minY + baseline - dimensions[.firstTextBaseline]),
                anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }

    private func columnWidths(_ width: CGFloat) -> [CGFloat] {
        let available = max(0, width - spacing)
        return [available * 2 / 3, available / 3]
    }
}

