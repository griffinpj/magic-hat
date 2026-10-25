//
//  HistoryRail.swift
//  magic-hat
//
//  The line in History's gutter: a stroke through each row and a dot per
//  action — filled where applied, hollow where undone, a ring on the head
//  (what Undo takes next), dashed ahead of the head (what Redo would take).
//  A Canvas per row, drawn with zero vertical insets so it reads as one
//  continuous rail across a day's card. On a branch's page the same rail
//  draws in secondary, since nothing on it is applied.
//

import SwiftUI
import UIKit

nonisolated enum RailStroke: Hashable, Sendable { case solid, dashed }
nonisolated enum RailDot: Hashable, Sendable {
    case applied, undone, head
    /// The foot of a cut list: older actions carry on, not drawn.
    case more
}

nonisolated struct RailMark: Hashable, Sendable {
    /// Toward the newer row above; nil at the top of a card.
    var above: RailStroke?
    /// Toward the older row below; nil at the bottom of the history.
    var below: RailStroke?
    var dot: RailDot
    /// A branch leaves here: a short curve peels off the dot. History's
    /// feed says it with a tag instead; the deck versions rail still
    /// draws it beside a version another branch forks from.
    var stub = false
}

struct HistoryRail: View {
    let mark: RailMark
    /// The current line draws in the tint; another branch in secondary.
    let emphasized: Bool

    var body: some View {
        Canvas { context, size in
            let x = size.width / 2
            let y = size.height / 2
            let color: Color = emphasized ? .accentColor : Color(uiColor: .secondaryLabel)
            let radius: CGFloat = 4.5

            func stroke(_ style: RailStroke, from y0: CGFloat, to y1: CGFloat) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: y0))
                path.addLine(to: CGPoint(x: x, y: y1))
                let dash: [CGFloat] = style == .dashed ? [3, 4] : []
                context.stroke(path, with: .color(color.opacity(style == .dashed ? 0.6 : 1)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
            }
            let gap: CGFloat = mark.dot == .more ? 5 : 0
            if let above = mark.above { stroke(above, from: 0, to: y - radius - gap - 2) }
            if let below = mark.below { stroke(below, from: y + radius + gap + 2, to: size.height) }

            if mark.stub {
                let branch = Color(uiColor: .secondaryLabel)
                var path = Path()
                path.move(to: CGPoint(x: x, y: y + radius))
                path.addQuadCurve(to: CGPoint(x: x + 13, y: y + 16), control: CGPoint(x: x, y: y + 16))
                context.stroke(path, with: .color(branch), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                let end = CGRect(x: x + 13 - 2.5, y: y + 16 - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: end), with: .color(Color(uiColor: .secondarySystemGroupedBackground)))
                context.stroke(Path(ellipseIn: end), with: .color(branch), lineWidth: 1.5)
            }

            let dotRect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            switch mark.dot {
            case .applied:
                context.fill(Path(ellipseIn: dotRect), with: .color(color))
            case .undone:
                context.fill(Path(ellipseIn: dotRect), with: .color(Color(uiColor: .secondarySystemGroupedBackground)))
                context.stroke(Path(ellipseIn: dotRect.insetBy(dx: 1, dy: 1)), with: .color(color), lineWidth: 2)
            case .head:
                context.fill(Path(ellipseIn: dotRect), with: .color(color))
                context.stroke(Path(ellipseIn: dotRect.insetBy(dx: -3.5, dy: -3.5)), with: .color(color.opacity(0.5)), lineWidth: 1.5)
            case .more:
                for offset in [-5.0, 0.0, 5.0] {
                    let dot = CGRect(x: x - 1.25, y: y + offset - 1.25, width: 2.5, height: 2.5)
                    context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.7)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
