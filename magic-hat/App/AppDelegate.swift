//
//  AppDelegate.swift
//  magic-hat
//
//  The two things SwiftUI's App can't do on its own: register the
//  background refresh task before launch finishes (BGTaskScheduler insists),
//  and take the completion handler the system hands over when it relaunches
//  the app for a finished background download.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CatalogSyncController.shared.registerBackgroundTasks()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == CatalogSyncController.sessionIdentifier else { completionHandler(); return }
        CatalogSyncController.shared.reconnectBackgroundSession(completion: completionHandler)
    }
}
