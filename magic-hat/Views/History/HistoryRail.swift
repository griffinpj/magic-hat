//
//  HistoryRail.swift
//  magic-hat
//
//  The gutter of the History list: a line through the rows of a branch
//  with a dot per action — the shape a source-control client draws in
//  its leftmost column, and nothing more. Solid where the actions are
//  applied, dashed ahead of the head (what Redo would take), a ring on
//  the head, hollow dots for anything undone; another branch draws in
//  secondary and runs off the bottom of its card toward the action it
//  forks from, which its header names. Drawn per row with a Canvas
//  sized to the whole cell (row insets are zero vertically), so the line
//  is continuous.
//

import SwiftUI
import UIKit

nonisolated enum RailStroke: Hashable, Sendable { case solid, dashed }
nonisolated enum RailDot: Hashable, Sendable {
    case applied, undone, head
    /// The foot of a branch's card: where it joins the action it splits from.
    case junction
}

nonisolated struct RailMark: Hashable, Sendable {
    /// Toward the newer row above; nil at the top of a card.
    var above: RailStroke?
    /// Toward the older row below; nil at the bottom of the history.
    var below: RailStroke?
    var dot: RailDot
    /// A branch leaves here: a short curve peels off the dot toward the
    /// cards below, where that branch is listed.
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
            if let above = mark.above { stroke(above, from: 0, to: y - radius - (mark.dot == .junction ? 0.5 : 2)) }
            if let below = mark.below { stroke(below, from: y + radius + 2, to: size.height) }

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
            case .junction:
                let small = dotRect.insetBy(dx: 1.5, dy: 1.5)
                context.fill(Path(ellipseIn: small), with: .color(Color(uiColor: .secondarySystemGroupedBackground)))
                context.stroke(Path(ellipseIn: small), with: .color(color), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}
