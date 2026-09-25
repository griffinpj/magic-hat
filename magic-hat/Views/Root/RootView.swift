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
    #if DEBUG
    /// Deliberately blocks the main thread (the `-uitest-hang` proof of
    /// the sampler); a plain function so the async context above doesn't
    /// see a `Thread.sleep`.
    private static func blockMainThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
    #endif

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
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
        .background(alignment: .bottomLeading) { FoilWarmupView() }
        .task {
            LaunchPrewarm.fonts()
            LaunchPrewarm.shaders()
            Task {
                // After the keyboard and foil warm-ups, off the launch window.
                try? await Task.sleep(for: .seconds(4))
                LaunchPrewarm.symbols()
            }
            Task { @MainActor in
                // The one deliberate main-thread cost at launch: UIKit's
                // text-input stack, a few hundred ms on a device. Two
                // seconds in, after the first screen has drawn and the
                // Collections totals have landed, not under them.
                try? await Task.sleep(for: .seconds(2))
                LaunchPrewarm.keyboard()
            }
            #if DEBUG
            // `-uitest-hang`: block the main thread once so the HangDetector's
            // report (and its stack) can be verified end to end.
            if ProcessInfo.processInfo.arguments.contains("-uitest-hang") {
                try? await Task.sleep(for: .seconds(2))
                Self.blockMainThread(for: 1.2)
            }
            #endif
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-uitest-real") {
                await UITestSeed.importRealCollectionIfNeeded(modelContext.container)
                return
            }
            guard !arguments.contains("-uitest-seed") else {
                #if DEBUG
                if arguments.contains("-uitest-fake-sync") { sync.simulateSyncForTesting() }
                #endif
                return
            }
            await sync.syncIfNeeded(container: modelContext.container)
        }
        // Coming back to the foreground: a background download may have
        // landed while we were away, and a long absence deserves a fresh
        // look at the manifest.
        .onChange(of: scenePhase) { _, phase in
            let arguments = ProcessInfo.processInfo.arguments
            guard phase == .active, !arguments.contains("-uitest-seed"), !arguments.contains("-uitest-real") else { return }
            Task { await sync.resumeIfNeeded(container: modelContext.container) }
        }
    }
}
