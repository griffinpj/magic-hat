//
//  RootView.swift
//  magic-hat
//
//  Decides what the app opens into. First launch, before the catalog has
//  ever been ingested: the setup screen. Otherwise (or once the user opts
//  to continue): the tabs, with the small sync bar narrating any refresh.
//  The sync itself is started here so both surfaces observe the same run.
//

import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    private var sync: CatalogSyncController { .shared }

    @State private var continuedInBackground = false

    private var showSetup: Bool {
        !sync.catalogReady && !continuedInBackground
    }

    var body: some View {
        Group {
            if showSetup {
                CatalogSetupView {
                    withAnimation(.easeInOut(duration: 0.3)) { continuedInBackground = true }
                }
                .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSetup)
        .task {
            guard !ProcessInfo.processInfo.arguments.contains("-uitest-seed") else { return }
            await sync.syncIfNeeded(container: modelContext.container)
        }
    }
}
