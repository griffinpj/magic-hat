//
//  ScanView.swift
//  magic-hat
//
//  The Scan tab: the camera with a card-shaped guide, a status line that
//  says what the scanner is doing, and the tray of scanned cards along the
//  bottom. Hold a card in the guide: when two frames agree and Scryfall
//  confirms the name (and the printing, from the set code and number in
//  the corner), it drops into the tray with a haptic. When the scanner is
//  unsure it stops and asks — "Is this…?" with the card and the other
//  names it might be — rather than guessing. Nothing reaches a collection
//  until the tray is added, printing, finish and count checked, in one
//  History action.
//
//  With no camera (the simulator) or no permission, the page says so and
//  offers a photo instead; the same reader runs on it.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation

struct ScanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = ScanSession()
    @State private var camera = CardCamera()
    @State private var access: Access = .unknown
    @State private var torch = false
    @State private var showTray = false
    @State private var photo: PhotosPickerItem?
    @State private var isVisible = false

    enum Access { case unknown, granted, denied, noCamera }

    var body: some View {
        NavigationStack {
            screen
                .sensoryFeedback(.success, trigger: session.addedCount)
                .task { await session.loadSets() }
                .onAppear { isVisible = true; startIfReady() }
                .onDisappear { isVisible = false; camera.stop() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { startIfReady() } else { camera.stop() }
                }
                .onChange(of: session.isPaused) { _, paused in camera.isPaused = paused }
                .onChange(of: photo) { _, item in scanPhoto(item) }
        }
    }

    private var screen: some View {
        content
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showTray) { ScanTrayView(session: session) }
            .sheet(item: confirmBinding) { item in confirmSheet(item.match) }
    }

    private func confirmSheet(_ match: ScanMatch) -> some View {
        ScanConfirmView(match: match,
                        onAccept: { session.confirm(match.card, exactPrinting: match.exactPrinting) },
                        onPick: { name in session.confirm(name: name) },
                        onReject: { session.dismissPrompt() })
            .presentationDetents([.medium, .large])
    }

    private var confirmBinding: Binding<ScanMatchItem?> {
        Binding(get: {
            if case .confirm(let match) = session.phase { return ScanMatchItem(match: match) }
            return nil
        }, set: { if $0 == nil, session.isPaused { session.dismissPrompt() } })
    }

    @ViewBuilder private var content: some View {
        switch access {
        case .unknown:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await authorize() }
        case .granted:
            scanner
        case .denied:
            ContentUnavailableView {
                Label("Camera Access Off", systemImage: "camera.fill")
            } description: {
                Text("Allow the camera in Settings to scan cards, or scan a photo of one.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                photoButton
            }
        case .noCamera:
            ContentUnavailableView {
                Label("No Camera", systemImage: "camera.fill")
            } description: {
                Text("This device has no camera to scan with. Scan a photo of a card instead.")
            } actions: {
                photoButton.buttonStyle(.borderedProminent)
            }
            .overlay(alignment: .bottom) { trayBar.padding(.bottom, 12) }
        }
    }

    private var photoButton: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            Label("Scan a Photo", systemImage: "photo")
        }
        .accessibilityIdentifier("scan-photo")
    }

    // MARK: Scanner

    private var scanner: some View {
        GeometryReader { geo in
            let guide = Self.guideRect(in: geo.size)
            ZStack {
                CameraPreview(camera: camera)
                    .ignoresSafeArea()
                GuideMask(guide: guide, tint: guideTint)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                VStack {
                    statusPill
                        .padding(.top, 8)
                    Spacer()
                    trayBar
                        .padding(.bottom, 12)
                }
            }
            .onAppear { updateRegion(guide: guide, size: geo.size) }
            .onChange(of: geo.size) { _, size in updateRegion(guide: Self.guideRect(in: size), size: size) }
        }
    }

    /// A card's proportions (63 × 88 mm), as large as fits with room for
    /// the status above and the tray below.
    static func guideRect(in size: CGSize) -> CGRect {
        let aspect: CGFloat = 63.0 / 88.0
        let maxHeight = size.height - 190
        let maxWidth = size.width * (size.width > size.height ? 0.5 : 0.8)
        let width = min(maxWidth, maxHeight * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: max(70, (size.height - height) / 2 - 10), width: width, height: height)
    }

    private func updateRegion(guide: CGRect, size: CGSize) {
        // The sensor is 1920 × 1080; upright, it is portrait when the view is.
        let image = size.width > size.height ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        camera.region = CardCamera.guideRegion(guide: guide, in: size, imageSize: image)
    }

    private var guideTint: Color {
        switch session.phase {
        case .looking: return .white
        case .reading, .matching: return .yellow
        case .confirm: return .orange
        case .added: return .green
        }
    }

    private var statusText: String {
        switch session.phase {
        case .looking: return "Hold a card inside the frame"
        case .reading(let name): return "Reading “\(name)”…"
        case .matching(let name): return "Looking up \(name)…"
        case .confirm(let match): return "Is this \(match.card.name)?"
        case .added(let card): return "Added \(card.name)"
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            switch session.phase {
            case .matching, .reading: ProgressView().controlSize(.small)
            case .added: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .confirm: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            case .looking: Image(systemName: "viewfinder")
            }
            Text(statusText)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .animation(.snappy, value: statusText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scan-status")
    }

    /// The tray at the bottom: the last card in, the count, and Review.
    private var trayBar: some View {
        Button { showTray = true } label: {
            HStack(spacing: 12) {
                if let first = session.tray.first {
                    CardArtThumb(artURL: first.card.artCropURL, fallbackURL: first.card.imageURL, width: 48, height: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.tray.isEmpty ? "Nothing scanned yet" : "\(session.trayCopies) scanned")
                        .font(.headline)
                    if let first = session.tray.first {
                        Text("\(first.card.name) · \(first.printing.setCode.uppercased()) #\(first.printing.collectorNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !session.tray.isEmpty {
                    Text("Review")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.tray.isEmpty)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("scan-tray")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if access == .granted {
                Button(torch ? "Light Off" : "Light", systemImage: torch ? "flashlight.on.fill" : "flashlight.off.fill") {
                    torch.toggle()
                    camera.setTorch(torch)
                }
                .accessibilityIdentifier("scan-torch")
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Scan a Photo", systemImage: "photo")
            }
        }
    }

    // MARK: Work

    private func authorize() async {
        guard camera.isAvailable else { access = .noCamera; return }
        access = await CardCamera.authorize() ? .granted : .denied
        startIfReady()
    }

    private func startIfReady() {
        guard access == .granted, isVisible else { return }
        let session = self.session
        camera.onLines = { lines in session.ingest(lines) }
        camera.start()
    }

    private func scanPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { photo = nil }
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
            let lines = await Task.detached(priority: .userInitiated) { CardCamera.recognize(image: image) }.value
            await session.scan(photoLines: lines)
        }
    }
}

struct ScanMatchItem: Identifiable {
    let match: ScanMatch
    var id: String { match.card.id }
}

// MARK: - Camera preview

private struct CameraPreview: UIViewRepresentable {
    let camera: CardCamera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        Task { try? await camera.configure(previewLayer: view.previewLayer) }
        view.onLayout = { [weak view] in
            guard let view, let angle = camera.previewAngle() else { return }
            view.previewLayer.connection?.videoRotationAngle = angle
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }
}

/// Dims everything but the guide, and draws the guide's border in the
/// scanner's colour.
private struct GuideMask: View {
    let guide: CGRect
    let tint: Color

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.45))
                .mask {
                    Rectangle()
                        .overlay {
                            RoundedRectangle(cornerRadius: guide.width * 0.05, style: .continuous)
                                .frame(width: guide.width, height: guide.height)
                                .position(x: guide.midX, y: guide.midY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
            RoundedRectangle(cornerRadius: guide.width * 0.05, style: .continuous)
                .strokeBorder(tint, lineWidth: 3)
                .frame(width: guide.width, height: guide.height)
                .position(x: guide.midX, y: guide.midY)
                .animation(.easeInOut(duration: 0.2), value: tint)
        }
    }
}

// MARK: - Confirm

/// "Is this …?": the card Scryfall found, and the other names the reading
/// might be. Yes adds it; a name looks that one up; No keeps scanning.
private struct ScanConfirmView: View {
    let match: ScanMatch
    let onAccept: () -> Void
    let onPick: (String) -> Void
    let onReject: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    let item = CardItem(scryfallCard: match.card, owned: false)
                    CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio, cornerRadius: 12, targetWidth: 240)
                        .frame(width: 180)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    VStack(spacing: 4) {
                        Text(match.card.name).font(.title3.weight(.semibold))
                        Text("\(match.card.setName) · #\(match.card.collectorNumber)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        onAccept()
                        dismiss()
                    } label: {
                        Label("Yes, Add It", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("scan-confirm-yes")
                    if !match.alternatives.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Or is it…").font(.subheadline.weight(.semibold))
                            FlowLayout {
                                ForEach(match.alternatives, id: \.self) { name in
                                    Button(name) {
                                        onPick(name)
                                        dismiss()
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Is This the Card?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not This", role: .cancel) {
                        onReject()
                        dismiss()
                    }
                    .accessibilityIdentifier("scan-confirm-no")
                }
            }
        }
    }
}
