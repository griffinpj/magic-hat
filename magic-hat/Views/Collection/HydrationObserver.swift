//
//  HydrationObserver.swift
//  magic-hat
//
//  Calls back when hydration writes a batch, without making the caller's
//  body depend on `CardHydrationController.revision`. A screen that reads
//  the revision in its own body (an `onChange(of:)` there does) is
//  re-rendered on every 75-card batch, and every view it builds with it —
//  the grid, a presented sheet's content. Placed in a `.background`, this
//  view is the only one that re-renders.
//

import SwiftUI

struct HydrationObserver: View {
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: CardHydrationController.shared.revision) { _, _ in onChange() }
    }
}
