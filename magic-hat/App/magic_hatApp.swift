//
//  magic_hatApp.swift
//  magic-hat
//
//  Created by griffin on 9/20/26.
//

import SwiftUI
import SwiftData

@main
struct magic_hatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITest = arguments.contains("-uitest-seed")
        // `-uitest-real`: a real user's store — on disk, kept between
        // launches (UITEST_RESET=1 wipes it), the network on, and the real
        // ManaBox export imported on first launch (UITestSeed). The catalog
        // download alone is skipped: 79MB is not a test.
        let isRealRun = arguments.contains("-uitest-real")
        let schema = Schema([
            MTGCollection.self,
            CollectionEntry.self,
            CardMeta.self,
            AuditRecord.self,
            HistoryBranchName.self,
            CardRuling.self,
            SavedSearch.self,
            Deck.self,
            DeckCard.self,
        ])
        // Tests run in memory, except when a test wants the real thing:
        // `UITEST_DISK_STORE=1` uses a fresh SQLite file in tmp, so disk
        // contention between readers and the catalog writer is measurable.
        let modelConfiguration: ModelConfiguration
        if isRealRun {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-real.sqlite")
            if ProcessInfo.processInfo.environment["UITEST_RESET"] != nil {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
                }
            }
            modelConfiguration = ModelConfiguration(schema: schema, url: url)
        } else if isUITest, ProcessInfo.processInfo.environment["UITEST_DISK_STORE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-store.sqlite")
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            modelConfiguration = ModelConfiguration(schema: schema, url: url)
        } else {
            modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITest)
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            if isUITest {
                UITestSeed.populate(container)
                UITestSeed.startIngestLoopIfRequested(container)
            } else if isRealRun {
                UITestSeed.prepareRealRun()
            }
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // The catalog sync needs the container without a scene: a background
        // refresh or a finished background download can relaunch the app
        // with no window at all.
        CatalogSyncController.shared.attach(container: sharedModelContainer)
        #if DEBUG
        HangDetector.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
    }
}
