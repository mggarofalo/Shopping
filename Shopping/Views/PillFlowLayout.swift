import SwiftUI

struct PillFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let subviewProposal = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let measured = subview.sizeThatFits(subviewProposal)
            let size = CGSize(width: min(measured.width, width), height: measured.height)
            if rowWidth > 0 && rowWidth + spacing + size.width > width {
                contentWidth = max(contentWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        contentWidth = max(contentWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: proposal.width ?? contentWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let measured = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let size = CGSize(width: min(measured.width, bounds.width), height: measured.height)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
