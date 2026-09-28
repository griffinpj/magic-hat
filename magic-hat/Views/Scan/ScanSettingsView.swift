//
//  ScanSettingsView.swift
//  magic-hat
//
//  The scanner's settings, from the gear in its control column: a sheet
//  at half height over the camera (iOS 26 draws a partial-height sheet in
//  Liquid Glass), a grouped Form like any Settings page. The camera, how a
//  printing is chosen, sets to lock scanning to, promos, foil, sounds, the
//  total — and tips for scanning well.
//

import SwiftUI

struct ScanSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = ScanSettings.shared
    @State private var cameras: [CameraOption] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $settings.cameraID) {
                        ForEach(cameras) { Text($0.name).tag(Optional($0.id)) }
                        if cameras.isEmpty { Text("No Camera").tag(String?.none) }
                    } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    .accessibilityIdentifier("scan-settings-camera")
                } footer: {
                    Text("Automatic switches to macro when a card is held close, on phones that have it.")
                }

                Section {
                    Toggle(isOn: $settings.quickMode) {
                        Label("Quick Mode", systemImage: "bolt")
                    }
                    .accessibilityIdentifier("scan-settings-quick")
                    NavigationLink {
                        ScanSetLockView(selection: $settings.lockedSets)
                    } label: {
                        LabeledContent {
                            Text(lockSummary).foregroundStyle(.secondary)
                        } label: {
                            Label("Lock to Sets", systemImage: "lock")
                        }
                    }
                    .accessibilityIdentifier("scan-settings-lock")
                    Toggle(isOn: $settings.ignorePromos) {
                        Label("Ignore Promos", systemImage: "seal")
                    }
                    Toggle(isOn: $settings.preferFoil) {
                        Label("Prefer Foil", systemImage: "sparkles")
                    }
                } header: {
                    Text("Matching")
                } footer: {
                    Text("Quick Mode takes the newest printing of the card when its set and number can't be read; off, the printing strip opens so you can pick. A locked scan only takes printings from those sets. A foil's ★ in the corner is always read as foil.")
                }

                Section {
                    Toggle(isOn: $settings.playSounds) {
                        Label("Play Sounds", systemImage: "speaker.wave.2")
                    }
                    Toggle(isOn: $settings.showTotal) {
                        Label("Show Total Value", systemImage: "dollarsign.circle")
                    }
                    Toggle(isOn: $settings.ignoreLowValues) {
                        Label("Ignore Low Values", systemImage: "arrow.down.circle")
                    }
                    .disabled(!settings.showTotal)
                } header: {
                    Text("While Scanning")
                } footer: {
                    Text("Ignore Low Values leaves cards under \(AppSettings.currency.symbol)1 out of the total.")
                }

                Section {
                    NavigationLink {
                        ScanTipsView()
                    } label: {
                        Label("Scanning Tips", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Scan Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("scan-settings-done")
                }
            }
            .task {
                cameras = await Task.detached { CardCamera.cameras() }.value
                if settings.cameraID == nil || !cameras.contains(where: { $0.id == settings.cameraID }) {
                    settings.cameraID = cameras.first?.id
                }
            }
        }
    }

    private var lockSummary: String {
        switch settings.lockedSets.count {
        case 0: return "All Sets"
        case 1...3: return settings.lockedSets.sorted().map { $0.uppercased() }.joined(separator: ", ")
        default: return "\(settings.lockedSets.count) sets"
        }
    }
}

/// Every set, newest first, searchable, each a checkmark row — the sets a
/// scan may take printings from. Chosen sets lead the list.
struct ScanSetLockView: View {
    @Binding var selection: Set<String>
    @State private var sets: [ScryfallSet] = []
    @State private var search = ""
    @State private var failed = false

    private var shown: [ScryfallSet] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let paper = sets.filter { $0.digital != true }
        guard !q.isEmpty else { return paper }
        return paper.filter { ($0.name ?? "").lowercased().contains(q) || $0.code.lowercased().hasPrefix(q) }
    }

    var body: some View {
        List {
            if !selection.isEmpty {
                Section {
                    ForEach(sets.filter { selection.contains($0.code.lowercased()) }) { row($0) }
                    Button("Clear All", role: .destructive) { selection = [] }
                } header: {
                    Text("Locked")
                }
            }
            Section {
                if sets.isEmpty {
                    if failed {
                        Text("Couldn't load the set list.").foregroundStyle(.secondary)
                    } else {
                        HStack { ProgressView(); Text("Loading sets…").foregroundStyle(.secondary) }
                    }
                }
                ForEach(shown.filter { !selection.contains($0.code.lowercased()) }) { row($0) }
            } header: {
                Text("All Sets")
            }
        }
        .navigationTitle("Lock to Sets")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Set name or code")
        .task {
            do { sets = try await ScryfallCatalogCache.shared.sets() } catch { failed = true }
        }
    }

    private func row(_ set: ScryfallSet) -> some View {
        let code = set.code.lowercased()
        let chosen = selection.contains(code)
        return Button {
            if chosen { selection.remove(code) } else { selection.insert(code) }
        } label: {
            HStack(spacing: 12) {
                SetSymbolView(setCode: set.code, size: 20, tint: .primary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(set.name ?? set.code.uppercased()).foregroundStyle(.primary).lineLimit(1)
                    Text([set.code.uppercased(), set.releasedAt.map { String($0.prefix(4)) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("lock-set-\(code)")
    }
}

/// How to get a clean read, in a few lines.
private struct ScanTipsView: View {
    var body: some View {
        List {
            tip("rectangle.portrait", "Fill the frame", "Hold the card flat so its edges sit just inside the frame, a hand's width from the lens.")
            tip("lightbulb", "Light evenly", "Bright, even light works best. Tilt a foil until the glare leaves the name and the bottom-left corner, or turn on the light.")
            tip("text.magnifyingglass", "Name and corner", "The scanner reads the name at the top and the set and number at the bottom left. Newer cards give an exact printing; older ones are matched by name.")
            tip("plus.circle", "Several copies", "The same card is only counted once while you hold it. Tap +1 for each further copy.")
            tip("questionmark.circle", "When it asks", "If a read isn't certain, it stops and asks. Pick the right card or skip it; nothing is added on a guess.")
            tip("lock", "Scanning one set", "Lock to that set in Scan Settings: every card is matched in it, and anything else is skipped.")
        }
        .navigationTitle("Scanning Tips")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tip(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
