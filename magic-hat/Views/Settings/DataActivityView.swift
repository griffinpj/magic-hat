//
//  DataActivityView.swift
//  magic-hat
//
//  Settings › Data Activity: every load the app runs on its own, one row
//  each — what it is, when it runs, when it last ran and what it did,
//  with a progress bar while it is running. The answer to "what is this
//  app doing with my data and my connection", read off `DataActivity`.
//  A section on top lists what is running right now; empty, it says so.
//

import SwiftUI

struct DataActivityView: View {
    @State private var activity = DataActivity.shared
    @State private var now = Date()

    var body: some View {
        List {
            Section {
                let running = DataTask.allCases.filter { activity.isRunning($0) }
                if running.isEmpty {
                    Label("Nothing is loading right now.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("data-activity-idle")
                } else {
                    ForEach(running) { task in runningRow(task) }
                }
            } header: {
                Text("Now")
            } footer: {
                Text("Everything here runs off the main thread, in small requests, and never over cellular unless you allow it in Settings.")
            }

            Section("Loads") {
                ForEach(DataTask.allCases) { task in
                    NavigationLink {
                        DataTaskDetailView(task: task)
                    } label: {
                        taskRow(task)
                    }
                    .accessibilityIdentifier("data-activity-\(task.rawValue)")
                }
            }
        }
        .navigationTitle("Data Activity")
        .navigationBarTitleDisplayMode(.inline)
        // "2 minutes ago" moves on while the screen is open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }

    private func runningRow(_ task: DataTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(task.title, systemImage: task.systemImage)
            if let progress = activity.running[task], let total = progress.total, total > 0 {
                ProgressView(value: Double(progress.done), total: Double(total))
                Text("\(progress.done.formatted()) of \(total.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
            }
        }
    }

    private func taskRow(_ task: DataTask) -> some View {
        HStack(spacing: 12) {
            Image(systemName: task.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                Text(DataActivityText.status(activity.records[task], running: activity.isRunning(task), now: now))
                    .font(.footnote)
                    .foregroundStyle(activity.records[task]?.failed == true ? .orange : .secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// One load: what it is, when it runs, and its last run in full.
struct DataTaskDetailView: View {
    let task: DataTask
    @State private var activity = DataActivity.shared

    var body: some View {
        Form {
            Section {
                Text(task.summary)
            } header: {
                Text("What")
            }
            Section {
                Text(task.schedule)
            } header: {
                Text("When")
            }
            Section("Last Run") {
                if let record = activity.records[task] {
                    LabeledContent("Started", value: record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let finished = record.finishedAt {
                        LabeledContent("Finished", value: finished.formatted(date: .abbreviated, time: .shortened))
                        if let duration = record.duration {
                            LabeledContent("Took", value: DataActivityText.duration(duration))
                        }
                    } else {
                        LabeledContent("Finished") {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Running") }
                        }
                    }
                    LabeledContent("Result") {
                        Text(record.note)
                            .foregroundStyle(record.failed ? .orange : .secondary)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    Text("Hasn't run yet.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

nonisolated enum DataActivityText {
    /// "Running · 1,240 of 3,846", "2 hours ago · 3,846 cards · 4s",
    /// "Never".
    static func status(_ record: DataActivityRecord?, running: Bool, now: Date) -> String {
        if running { return "Running…" }
        guard let record, let finished = record.finishedAt else { return "Never" }
        var parts = [relative(finished, now: now), record.note]
        if let duration = record.duration, duration >= 1, record.count > 0 { parts.append(self.duration(duration)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let text = formatter.localizedString(for: date, relativeTo: now)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "under a second" }
        if seconds < 90 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes) min"
    }
}
