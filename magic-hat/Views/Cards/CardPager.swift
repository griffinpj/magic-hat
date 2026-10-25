//
//  CardPager.swift
//  magic-hat
//
//  The viewer's pager: a UIScrollView with `isPagingEnabled`, which is what
//  Photos pages its photos with, wrapped for SwiftUI. Paging is UIKit's own
//  deceleration — a page-boundary target reached on the scroll view's
//  paging curve, continuous from the finger's speed into the settle — and
//  nothing in it is ours to get wrong. A SwiftUI `ScrollView` with a
//  `ScrollTargetBehavior` was tried in two forms: `.viewAligned` runs at the
//  fast rate and stopped on the next card almost at once; a custom
//  behaviour at the normal rate glided but reached its target with a
//  visible correction at the end (the "snag"), because the normal-rate
//  curve is projected for a different distance than the one it is bent
//  to. UIKit's paging animation is a distinct curve made for exactly this.
//
//  The scroll view is as wide as one page (the card and its gap), centred,
//  and does not clip, so the neighbours show either side; `point(inside:)`
//  is widened to the whole host, so a drag or a tap on a peeking neighbour
//  reaches the scroll view and the page under it. Pages are hosted SwiftUI
//  (`UIHostingConfiguration.makeContentView`) kept for the current index
//  ±2 and recycled; neighbours sit back a little and come forward as they
//  are pulled in (a transform and an alpha per page, nothing redrawn).
//
//  What it reports: the page the finger let go towards, at the moment it
//  let go (`scrollViewWillEndDragging`'s target offset is the page), so the
//  title and panel follow the card as it glides rather than after it has
//  stopped — and never while the finger is still down.
//

import SwiftUI
import UIKit

/// Pages kept live either side of the current one.
private let pagerWindow = 2

struct CardPager<Page: View>: UIViewRepresentable {
    /// Stamped: compared by one integer per update, never id by id.
    let items: CardItemList
    @Binding var currentID: String?
    /// The card's width; a page is this plus `spacing`.
    let pageWidth: CGFloat
    let spacing: CGFloat
    let height: CGFloat
    var reduceMotion = false
    @ViewBuilder let page: (String, Bool) -> Page

    func makeUIView(context: Context) -> PagerHostView {
        let view = PagerHostView()
        view.coordinator = context.coordinator
        context.coordinator.host = view
        return view
    }

    func updateUIView(_ view: PagerHostView, context: Context) {
        let c = context.coordinator
        c.environment = context.environment
        c.reduceMotion = reduceMotion
        // Re-captured per update: the binding the coordinator was made
        // with belongs to the first value of this struct.
        c.onCurrent = { id in if currentID != id { currentID = id } }
        c.builder = { id, isCurrent in AnyView(page(id, isCurrent)) }
        c.apply(items: items, pageWidth: pageWidth, spacing: spacing, height: height, currentID: currentID)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCurrent: { id in
            if currentID != id { currentID = id }
        })
    }

    // MARK: Host

    /// Full width (so the layout owns the pager's room), the scroll view
    /// one page wide in the middle.
    final class PagerHostView: UIView {
        weak var coordinator: Coordinator?
        let scrollView = PagingScrollView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            scrollView.isPagingEnabled = true
            scrollView.clipsToBounds = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.scrollsToTop = false
            scrollView.accessibilityIdentifier = "viewer-pager"
            addSubview(scrollView)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.layoutIfNeeded()
        }

        /// A touch anywhere in the host is the scroll view's: outside its
        /// own bounds a UIScrollView answers nothing, and the peeking
        /// neighbours would have been dead.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard bounds.contains(point) else { return nil }
            return scrollView.hitTest(convert(point, to: scrollView), with: event) ?? scrollView
        }
    }

    final class PagingScrollView: UIScrollView {
        /// Inside, for any point the host holds: that is what lets a hit
        /// test descend to a page that sits outside the scroll view's
        /// one-page frame.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard let superview else { return super.point(inside: point, with: event) }
            return superview.bounds.contains(convert(point, to: superview))
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var host: PagerHostView?
        var environment = EnvironmentValues()
        var reduceMotion = false
        var builder: ((String, Bool) -> AnyView)?
        var onCurrent: (String) -> Void

        private var items = CardItemList()
        private var ids: [String] { items.ids }
        private var pageWidth: CGFloat = 0
        private var spacing: CGFloat = 0
        private var height: CGFloat = 0
        private var step: CGFloat { pageWidth + spacing }
        /// What the binding says; what the scroll view last reported.
        private var currentIndex = 0
        private var reportedIndex = 0
        private var lastHostSize: CGSize = .zero
        private var dragging = false

        /// Live pages by index, and spares to reuse (hosting views are not
        /// free to make).
        private var pages: [Int: PageView] = [:]
        private var spare: [PageView] = []

        init(onCurrent: @escaping (String) -> Void) {
            self.onCurrent = onCurrent
        }

        // MARK: Inputs

        func apply(items newItems: CardItemList, pageWidth: CGFloat, spacing: CGFloat, height: CGFloat, currentID: String?) {
            guard let host else { return }
            let scrollView = host.scrollView
            if scrollView.delegate == nil { scrollView.delegate = self }
            let sizeChanged = pageWidth != self.pageWidth || spacing != self.spacing || height != self.height
            let idsChanged = newItems != items
            self.pageWidth = pageWidth
            self.spacing = spacing
            self.height = height
            if idsChanged { items = newItems }
            let wanted = currentID.flatMap { items.index(of: $0) } ?? min(currentIndex, max(ids.count - 1, 0))
            let wantedChanged = wanted != currentIndex
            currentIndex = wanted

            // Every SwiftUI update reaches every live page: the builder
            // closes over the viewer's state (a flipped face, a deck
            // count), and a page configured for the same id and flag
            // would otherwise keep showing the old values.
            generation &+= 1
            if sizeChanged || idsChanged {
                // Everything re-laid: the pages, the content size and the
                // offset, with no animation — this is a rotation, the zoom
                // transition still growing the pager, or a card removed.
                reportedIndex = currentIndex
                layout(scrollView, animated: false)
            } else if wantedChanged, !dragging, reportedIndex != currentIndex {
                // A tapped neighbour, the step after a removal.
                reportedIndex = currentIndex
                scrollView.setContentOffset(CGPoint(x: CGFloat(currentIndex) * step, y: 0), animated: !reduceMotion)
                if reduceMotion { refreshPages() } else { refreshContents() }
            } else {
                refreshContents()
            }
        }

        /// Bumped per SwiftUI update, part of each page's key.
        private var generation: UInt64 = 0

        /// Host size changes come through layoutSubviews, not updateUIView.
        func layoutIfNeeded() {
            guard let host else { return }
            let size = host.bounds.size
            guard size != lastHostSize, size.width > 0 else { return }
            lastHostSize = size
            layout(host.scrollView, animated: false)
        }

        private func layout(_ scrollView: UIScrollView, animated: Bool) {
            guard let host, step > 0 else { return }
            let size = host.bounds.size
            scrollView.frame = CGRect(x: (size.width - step) / 2, y: 0, width: step, height: size.height)
            scrollView.contentSize = CGSize(width: step * CGFloat(ids.count), height: size.height)
            for (i, page) in pages { page.frame = frame(for: i) }
            scrollView.setContentOffset(CGPoint(x: CGFloat(currentIndex) * step, y: 0), animated: animated)
            refreshPages()
        }

        private func frame(for i: Int) -> CGRect {
            CGRect(x: CGFloat(i) * step, y: 0, width: step, height: height)
        }

        // MARK: Pages

        /// Makes and drops pages so the current one and two either side
        /// exist, then sets every live page's content and transform.
        private func refreshPages() {
            guard let host else { return }
            let centre = visibleIndex(host.scrollView)
            let keep = Set(max(0, centre - pagerWindow)...min(max(ids.count - 1, 0), centre + pagerWindow))
            for (i, page) in pages where !keep.contains(i) || i >= ids.count {
                page.removeFromSuperview()
                pages[i] = nil
                if spare.count < pagerWindow * 2 + 1 { spare.append(page) }
            }
            guard !ids.isEmpty else { return }
            for i in keep where pages[i] == nil {
                let page = spare.popLast() ?? makePage()
                page.frame = frame(for: i)
                host.scrollView.addSubview(page)
                pages[i] = page
            }
            refreshContents()
            applyTransforms()
        }

        private func makePage() -> PageView {
            let page = PageView()
            page.clipsToBounds = false
            return page
        }

        /// One page: the hosted card, and what it was last configured for.
        final class PageView: UIView {
            var key = ""
            var content: (UIView & UIContentView)?
        }

        /// Each live page's SwiftUI content, for its id and whether it is
        /// the current card. A page whose id and flag are unchanged is
        /// left alone.
        private func refreshContents() {
            guard let builder else { return }
            for (i, page) in pages {
                guard i < ids.count else { continue }
                let id = ids[i]
                let isCurrent = i == reportedIndex
                let key = "\(generation)|\(isCurrent ? 1 : 0)|\(id)"
                if let content = page.content {
                    if page.key != key {
                        content.configuration = configuration(id: id, isCurrent: isCurrent)
                        page.key = key
                    }
                    content.frame = contentFrame(in: page)
                } else {
                    let content = configuration(id: id, isCurrent: isCurrent).makeContentView()
                    content.frame = contentFrame(in: page)
                    content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    page.addSubview(content)
                    page.content = content
                    page.key = key
                }
            }
        }

        private func contentFrame(in page: UIView) -> CGRect {
            CGRect(x: spacing / 2, y: 0, width: pageWidth, height: page.bounds.height)
        }

        private func configuration(id: String, isCurrent: Bool) -> UIHostingConfiguration<AnyView, EmptyView> {
            let env = environment
            let builder = builder
            return UIHostingConfiguration {
                AnyView((builder?(id, isCurrent) ?? AnyView(EmptyView())).environment(\.self, env))
            }
            .margins(.all, 0)
        }

        /// Neighbours sit back (scale 0.94, opacity 0.82 at a full page
        /// away) and come forward as they are pulled in; under Reduce
        /// Motion they only dim.
        private func applyTransforms() {
            guard let host, step > 0 else { return }
            let centreX = host.scrollView.contentOffset.x + step / 2
            for page in pages.values {
                let distance = min(1, abs(page.frame.midX - centreX) / step)
                let scale = reduceMotion ? 1 : 1 - 0.06 * distance
                page.transform = CGAffineTransform(scaleX: scale, y: scale)
                page.alpha = 1 - 0.18 * distance
            }
        }

        private func visibleIndex(_ scrollView: UIScrollView) -> Int {
            guard step > 0, !ids.isEmpty else { return 0 }
            return min(max(Int((scrollView.contentOffset.x / step).rounded()), 0), ids.count - 1)
        }

        private func report(_ i: Int) {
            guard i >= 0, i < ids.count else { return }
            let changed = i != reportedIndex
            reportedIndex = i
            currentIndex = i
            if changed { refreshContents() }
            onCurrent(ids[i])
        }

        // MARK: UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard step > 0, !ids.isEmpty else { return }
            let centre = visibleIndex(scrollView)
            let needed = max(0, centre - pagerWindow)...min(ids.count - 1, centre + pagerWindow)
            if needed.contains(where: { pages[$0] == nil }) {
                refreshPages()
            } else {
                applyTransforms()
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            dragging = true
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            // Paging's target is the page boundary: the card the finger
            // let go towards becomes current now, as it glides in.
            guard step > 0, !ids.isEmpty else { return }
            let i = min(max(Int((targetContentOffset.pointee.x / step).rounded()), 0), ids.count - 1)
            report(i)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            dragging = false
            if !decelerate { report(visibleIndex(scrollView)) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            report(visibleIndex(scrollView))
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            report(visibleIndex(scrollView))
        }
    }
}
