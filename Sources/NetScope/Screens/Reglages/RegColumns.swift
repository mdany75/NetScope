import SwiftUI

/// Encadrés côte à côte, à largeurs égales, quand chacun a au moins `minColumnWidth` ; sinon l'un
/// sous l'autre, sur toute la largeur (petite fenêtre). En colonnes, tous prennent la hauteur du
/// plus haut et sont alignés en haut.
struct RegColumns: Layout {
    var minColumnWidth: CGFloat = 330
    var spacing: CGFloat = 14

    private func columnWidth(for width: CGFloat?, count: Int) -> CGFloat? {
        guard count > 1, let width, width.isFinite else { return nil }
        let column = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return column >= minColumnWidth ? column : nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width
        if let column = columnWidth(for: width, count: subviews.count) {
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            return CGSize(width: width ?? 0, height: height)
        }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let total = sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(subviews.count - 1)
        return CGSize(width: width ?? (sizes.map(\.width).max() ?? 0), height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let column = columnWidth(for: bounds.width, count: subviews.count) {
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (column + spacing)
                subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: column, height: bounds.height))
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }
}
