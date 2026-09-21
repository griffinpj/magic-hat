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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            MTGCollection.self,
            CollectionEntry.self,
            CardMeta.self,
            AuditRecord.self,
            CardRuling.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .modelContainer(sharedModelContainer)
    }
}
