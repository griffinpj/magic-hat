//
//  BackupSettingsView.swift
//  magic-hat
//
//  Backup & Restore: a backup now (shared from the sheet, and kept on the
//  phone), automatic backups on a schedule into a folder the user picks —
//  iCloud Drive's, so a copy outlives the phone — and restoring from any
//  backup file. Restore replaces everything and says so first; the state
//  it replaces is saved as a backup of its own before anything changes.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    private var scheduler: BackupScheduler { .shared }

    @State private var local: [URL] = []
    @State private var sharing: ShareItem?
    @State private var choosingFolder = false
    @State private var choosingBackup = false
    @State private var pending: PendingRestore?
    @State private var isRestoring = false
    @State private var restored: String?
    @State private var error: String?

    struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    struct PendingRestore: Identifiable {
        let backup: AppBackup
        let fileName: String
        var id: String { fileName + backup.manifest.createdAt.description }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        if let url = await scheduler.backUpNow(container: modelContext.container) {
                            refreshLocal()
                            sharing = ShareItem(url: url)
                        } else if let message = scheduler.lastError {
                            error = message
                        }
                    }
                } label: {
                    HStack {
                        Label("Back Up Now", systemImage: "arrow.up.doc")
                        Spacer()
                        if scheduler.isBackingUp { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(scheduler.isBackingUp || isRestoring)
                .accessibilityIdentifier("backup-now")
                LabeledContent("Last Backup") {
                    Text(scheduler.lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("A backup is one .zip with your collections, lists, decks and folders, History, saved searches and settings — plus your collection as a ManaBox CSV. Card data and images aren't included; they come back from Scryfall.")
            }

            Section {
                Picker(selection: Binding(get: { scheduler.frequency }, set: { scheduler.frequency = $0 })) {
                    ForEach(BackupFrequency.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("Automatic Backups", systemImage: "clock.arrow.2.circlepath")
                }
                .accessibilityIdentifier("backup-frequency")
                Button {
                    choosingFolder = true
                } label: {
                    LabeledContent {
                        Text(scheduler.folderName ?? "On This iPhone").foregroundStyle(.secondary)
                    } label: {
                        Label("Save To", systemImage: "icloud")
                    }
                }
                .accessibilityIdentifier("backup-folder")
                if scheduler.folderName != nil {
                    Button("Save on This iPhone Instead", role: .destructive) { scheduler.useLocalFolder() }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Choose a folder in iCloud Drive to keep backups safe if something happens to this phone. A backup runs when you open the app and one is due; the newest \(BackupScheduler.keep) are kept.")
            }

            Section {
                Button {
                    choosingBackup = true
                } label: {
                    Label("Restore from File…", systemImage: "arrow.down.doc")
                }
                .disabled(isRestoring)
                .accessibilityIdentifier("backup-restore-file")
                ForEach(local, id: \.path) { url in
                    Menu {
                        Button("Restore…", systemImage: "arrow.down.doc") { prepare(url) }
                        Button("Share…", systemImage: "square.and.arrow.up") { sharing = ShareItem(url: url) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            try? FileManager.default.removeItem(at: url)
                            refreshLocal()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "doc.zipper").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(fileSize(url)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Restore")
            } footer: {
                Text("Restoring replaces everything in the app with the backup. What's here now is saved first, as “Magic Hat Before Restore”, so you can go back.")
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isRestoring {
                ProgressView("Restoring…")
                    .padding(24)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .onAppear(perform: refreshLocal)
        .sheet(item: $sharing) { item in ShareSheet(items: [item.url]) }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { scheduler.choose(folder: url) }
        }
        .fileImporter(isPresented: $choosingBackup, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): prepare(url)
            case .failure(let e): error = e.localizedDescription
            }
        }
        .confirmationDialog("Replace Everything?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { item in
            Button("Restore Backup", role: .destructive) { restore(item.backup) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(summary(item.backup.manifest))
        }
        .alert("Restored", isPresented: Binding(get: { restored != nil }, set: { if !$0 { restored = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(restored ?? "") }
        .alert("Backup Problem", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func summary(_ m: BackupManifest) -> String {
        "The backup from \(m.createdAt.formatted(date: .abbreviated, time: .shortened)) has \(m.copies.formatted()) cards in \(m.collections) collections and lists, \(m.decks) decks, and \(m.historyRecords.formatted()) History records. Everything in the app now is replaced; it's saved as a backup first."
    }

    private func refreshLocal() {
        local = BackupFiles.backups(in: BackupFiles.localFolder)
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func prepare(_ url: URL) {
        Task {
            do {
                pending = PendingRestore(backup: try await BackupController.read(url), fileName: url.lastPathComponent)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func restore(_ backup: AppBackup) {
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                let safety = try await BackupController.restore(backup, container: modelContext.container)
                refreshLocal()
                restored = "\(backup.manifest.copies.formatted()) cards restored. What was here before is saved as “\(safety.deletingPathExtension().lastPathComponent)”."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The system share sheet for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
