//
//  BackupScheduler.swift
//  magic-hat
//
//  Automatic backups: daily or weekly, into a folder the user picks —
//  iCloud Drive's, for a copy that outlives the phone — or, until one is
//  picked, the app's own Documents/Backups. The folder is kept as a
//  security-scoped bookmark, the way the Files app lets an app keep
//  writing to a place the user chose; no iCloud entitlement or container
//  is involved, so it works with whatever folder the user trusts.
//
//  Run when the app comes to the foreground and a backup is due, a few
//  seconds after, off the launch path; the newest ten automatic backups
//  are kept in the folder, older ones deleted.
//

import Foundation
import SwiftData
import Observation
import UIKit

nonisolated enum BackupFrequency: String, CaseIterable, Identifiable, Sendable {
    case off, daily, weekly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .daily: return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        }
    }

    /// Whether a backup is due, `last` being the previous one.
    func isDue(last: Date?, now: Date = Date()) -> Bool {
        guard let interval else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

@MainActor
@Observable
final class BackupScheduler {
    static let shared = BackupScheduler()
    nonisolated static let keep = 10

    private let defaults = UserDefaults.standard
    private static let frequencyKey = "backup.frequency"
    private static let bookmarkKey = "backup.folderBookmark"
    private static let lastKey = "backup.last"

    var frequency: BackupFrequency {
        didSet { defaults.set(frequency.rawValue, forKey: Self.frequencyKey) }
    }
    private(set) var lastBackup: Date?
    private(set) var lastFile: URL?
    private(set) var isBackingUp = false
    private(set) var lastError: String?
    /// The chosen folder's name, for the settings row; nil = on this iPhone.
    private(set) var folderName: String?

    private init() {
        frequency = BackupFrequency(rawValue: UserDefaults.standard.string(forKey: Self.frequencyKey) ?? "") ?? .off
        lastBackup = UserDefaults.standard.object(forKey: Self.lastKey) as? Date
        folderName = resolveFolder()?.lastPathComponent
    }

    /// The picked folder, from its bookmark; refreshed if it went stale.
    private func resolveFolder() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: Self.bookmarkKey) }
        }
        return url
    }

    /// A folder from the document picker becomes where backups go.
    func choose(folder url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData() else {
            lastError = "Couldn't keep access to that folder."
            return
        }
        defaults.set(data, forKey: Self.bookmarkKey)
        folderName = url.lastPathComponent
        lastError = nil
    }

    func useLocalFolder() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        folderName = nil
    }

    /// On foreground: back up if one is due.
    func runIfDue(container: ModelContainer) async {
        guard frequency.isDue(last: lastBackup), !isBackingUp else { return }
        await backUpNow(container: container)
    }

    /// A backup now, into the chosen folder (or on this iPhone). Keeps the
    /// newest ten there.
    @discardableResult
    func backUpNow(container: ModelContainer) async -> URL? {
        guard !isBackingUp else { return nil }
        isBackingUp = true
        defer { isBackingUp = false }
        let task = UIApplication.shared.beginBackgroundTask(withName: "backup")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        do {
            let local = try await BackupController.makeBackup(container: container)
            var result = local
            if let folder = resolveFolder() {
                result = try await Self.copy(local, into: folder)
                try? FileManager.default.removeItem(at: local)
                BackupFiles.prune(BackupFiles.localFolder, keep: Self.keep)
            } else {
                BackupFiles.prune(BackupFiles.localFolder, keep: Self.keep)
            }
            let now = Date()
            lastBackup = now
            defaults.set(now, forKey: Self.lastKey)
            lastFile = result
            lastError = nil
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Writes into the picked folder under a coordinated write (iCloud
    /// Drive's daemon is another writer), then prunes old automatic ones.
    nonisolated private static func copy(_ file: URL, into folder: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let destination = folder.appendingPathComponent(file.lastPathComponent)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
                do {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.copyItem(at: file, to: url)
                } catch { writeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
            BackupFiles.prune(folder, keep: keep)
            return destination
        }.value
    }
}
