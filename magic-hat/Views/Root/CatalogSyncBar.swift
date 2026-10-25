//
//  CatalogSyncBar.swift
//  magic-hat
//
//  The catalog sync's narration while it downloads and ingests: one glass
//  pill just above the tab bar, in every tab's bottom safe-area bar, so
//  it never covers a title or a button. Deliberately non-modal: the app
//  stays fully usable on the data it already has. Empty when nothing is
//  running, and the bar goes with it.
//

import SwiftUI

struct CatalogSyncBar: View {
    var controller = CatalogSyncController.shared
    @State private var askingCellular = false

    private var isWaitingForWiFi: Bool {
        if case .waitingForWiFi = controller.phase { return true }
        return false
    }

    /// Shorter than the setup screen's line: the gauge carries the
    /// percentage here, and a pill has one line.
    private var label: String {
        switch controller.phase {
        case .downloading(let set, _): return "Downloading \(set.displayName)"
        case .ingesting(let set, let done): return "Adding \(set.displayName) — \(done.formatted())"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        default: return controller.statusText
        }
    }

    var body: some View {
        // The animation is attached here, where `phase` is read in this
        // view's own body. On the `safeAreaBar` in `catalogSyncBar()` it was
        // evaluated in MainTabView's body — the bar's content closure runs
        // there — so every progress report re-rendered the tab root.
        VStack(spacing: 0) {
            if controller.phase.showsProgressBar {
                if isWaitingForWiFi {
                    // Waiting is a choice the user can overrule, as on the
                    // setup screen: the pill is the way to.
                    Button { askingCellular = true } label: { pill }
                        .buttonStyle(.plain)
                        .accessibilityHint("Offers to download over cellular")
                } else {
                    pill
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controller.phase.showsProgressBar)
        .alert("Download over Cellular?", isPresented: $askingCellular) {
            Button("Use Cellular (80 MB)") { controller.allowCellular = true }
            Button("Wait for Wi-Fi", role: .cancel) {}
        } message: {
            Text("The card catalog is about 80 MB. It starts by itself on Wi-Fi; Settings › Card Data can change this later.")
        }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            if let fraction = controller.fraction {
                // Determinate while downloading; the ingest's line count
                // isn't known until the file is read.
                Gauge(value: fraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .frame(width: 72)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("catalog-sync-bar")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// The sync pill above the tab bar, on a tab's root. Sits in the
    /// bottom safe-area bar so it never overlaps the tab bar, and takes
    /// no space when there is nothing to say.
    func catalogSyncBar() -> some View {
        safeAreaBar(edge: .bottom) { CatalogSyncBar() }
    }
}
