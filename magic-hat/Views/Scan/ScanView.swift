//
//  ScanView.swift
//  magic-hat
//
//  The Scan tab, camera first, in the shape ManaBox made familiar and the
//  Camera app's controls: the picture edge to edge with a card-shaped
//  guide; the running total in a glass capsule at the top; a column of
//  glass buttons on the trailing edge (review the scanned cards, the
//  light, a photo, the scanner's settings); and at the bottom a glass
//  panel for the card just scanned — its printing (a strip of every
//  printing opens right there, no screen change), finish, language and
//  count (+1 for the next copy of the same card) — all edited without
//  leaving the camera. Scanning pauses while the panel is being edited.
//
//  Hold a card in the guide: when two frames agree and Scryfall confirms
//  the name (and the printing, from the set code and number in the corner),
//  it goes into the tray with a haptic and a sound. When the scanner is
//  unsure it stops and asks — "Is this…?" — rather than guessing. Nothing
//  reaches a collection until the tray is added, in one History action.
//
//  By default there is no frame to line a card up with: the whole picture
//  is read and the card found in it (an outline follows it), so a phone
//  on a stand works at whatever height it sits. Scan Settings' Card Frame
//  brings the guide back. "Not This" on the question, or a card nothing
//  could be found for, leads to typing the name (ScanManualEntry) — the
//  keyboard button in the control column does too.
//
//  With no camera (the simulator) or no permission, the page says so and
//  offers a photo instead; the same reader runs on it.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import AudioToolbox

struct ScanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = ScanSession(settings: .shared)
    @State private var camera = CardCamera()
    @State private var access: Access = .unknown
    @State private var torch = false
    @State private var showTray = false
    @State private var showSettings = false
    @State private var photo: PhotosPickerItem?
    @State private var isVisible = false
    @State private var showPrintings = false

    private var settings: ScanSettings { .shared }

    enum Access { case unknown, granted, denied, noCamera }

    /// `-uitest-scan-demo` (debug builds): the scanner's chrome over a
    /// stand-in for the camera, with a real card fetched into the tray, so
    /// the overlay can be vetted on a simulator, which has no camera.
    private static var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitest-scan-demo")
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            screen
                .toolbar(.hidden, for: .navigationBar)
                .sensoryFeedback(.success, trigger: session.addedCount)
                .onChange(of: session.addedCount) { _, _ in
                    if settings.playSounds { AudioServicesPlaySystemSound(1057) }
                }
                .task { await session.loadSets() }
                .onAppear { isVisible = true; startIfReady() }
                .onDisappear { isVisible = false; camera.stop() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { startIfReady() } else { camera.stop() }
                }
                .onChange(of: session.isPaused) { _, paused in camera.isPaused = paused }
                .onChange(of: showPrintings) { _, open in session.isEditing = open }
                .onChange(of: session.wantsPrintingPicker) { _, wants in
                    if wants { withAnimation(.snappy) { showPrintings = true }; session.wantsPrintingPicker = false }
                }
                .onChange(of: settings.cameraID) { _, id in camera.select(cameraID: id) }
                .onChange(of: settings.showFrame) { _, _ in cardOutline = nil; updateRegion() }
                .onChange(of: photo) { _, item in scanPhoto(item) }
        }
    }

    private var screen: some View {
        content
            .sheet(isPresented: $showTray) { ScanTrayView(session: session) }
            .sheet(isPresented: $showSettings) {
                ScanSettingsView()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: promptBinding) {
                ScanPromptView(session: session)
                    .presentationDetents([.medium, .large])
            }
    }

    /// One sheet for the question and the name field: "Not This" turns the
    /// first into the second in place rather than closing one sheet to
    /// open another.
    private var promptBinding: Binding<Bool> {
        Binding(get: { session.isPrompting },
                set: { if !$0, session.isPrompting { session.dismissPrompt() } })
    }

    @ViewBuilder private var content: some View {
        switch access {
        case .unknown:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await authorize() }
        case .granted:
            scanner
        case .denied:
            unavailable(title: "Camera Access Off", text: "Allow the camera in Settings to scan cards, or scan a photo of one.",
                        settingsButton: true)
        case .noCamera:
            unavailable(title: "No Camera", text: "This device has no camera to scan with. Scan a photo of a card instead.",
                        settingsButton: false)
        }
    }

    private func unavailable(title: String, text: String, settingsButton: Bool) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "camera.fill")
        } description: {
            Text(text)
        } actions: {
            if settingsButton {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Scan a Photo", systemImage: "photo")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("scan-photo")
        }
        .safeAreaInset(edge: .bottom) { bottomPanel.padding(.bottom, 8) }
        .overlay(alignment: .topTrailing) { sideControls(camera: false).padding(.trailing, 16).padding(.top, 8) }
    }

    // MARK: Scanner

    /// The guide, in the screen's coordinates, as laid out.
    @State private var guideFrame: CGRect = .zero
    @State private var screenSize: CGSize = .zero
    /// Without the guide: where the card was found, in the screen's
    /// coordinates, for the outline that follows it.
    @State private var cardOutline: CGRect?

    /// Laid out, not computed: the total and status, then the guide taking
    /// whatever room is left, then the card panel — so none of them can
    /// overlap — and in landscape the pills and panel beside the guide.
    /// The guide's frame is measured for the dimming mask and for the
    /// region Vision reads.
    private var scanner: some View {
        ZStack {
            Group {
                if Self.isDemo {
                    LinearGradient(colors: [Color(white: 0.55), Color(white: 0.25), Color(white: 0.4)],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                } else {
                    CameraPreview(camera: camera, cameraID: settings.cameraID)
                }
            }
            .ignoresSafeArea()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { screenSize = $0; updateRegion() }
            Group {
                if settings.showFrame {
                    GuideMask(guide: guideFrame, tint: guideTint)
                } else if let cardOutline {
                    CardOutline(rect: cardOutline, tint: guideTint)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            ViewThatFits(in: .vertical) {
                portraitLayout
                landscapeLayout
            }
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 10) {
            pills
            guideSlot
                .padding(.horizontal, 74)       // clear of the control column
                .frame(minHeight: 240)
            bottomPanel
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .topTrailing) {
            sideControls(camera: true).padding(.trailing, 12).padding(.top, 8)
        }
    }

    private var landscapeLayout: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                pills
                Spacer(minLength: 0)
                bottomPanel
            }
            .frame(maxWidth: 380)
            guideSlot
            Spacer(minLength: 74)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .topTrailing) {
            sideControls(camera: true).padding(.trailing, 12).padding(.top, 8)
        }
    }

    private var pills: some View {
        VStack(spacing: 8) {
            if settings.showTotal { totalPill }
            statusPill
        }
        .frame(minHeight: 44, alignment: .top)
    }

    /// A card's proportions (63 × 88 mm), as large as the room allows.
    private var guideSlot: some View {
        Color.clear
            .aspectRatio(63.0 / 88.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self, of: { proxy in
                // The card-shaped part of the slot, in screen coordinates.
                let frame = proxy.frame(in: .global)
                let aspect: CGFloat = 63.0 / 88.0
                let width = min(frame.width, frame.height * aspect)
                let height = width / aspect
                return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
            }) { rect in
                guideFrame = rect
                updateRegion()
            }
    }

    private func updateRegion() {
        let size = screenSize
        guard size.width > 0, guideFrame.width > 0 else { return }
        // The sensor is 1920 × 1080; upright, it is portrait when the view is.
        // With the frame, the guide; without, everything on screen.
        let read = settings.showFrame ? guideFrame : CGRect(origin: .zero, size: size)
        camera.region = CardCamera.guideRegion(guide: read, in: size, imageSize: uprightImageSize)
        camera.findsCard = !settings.showFrame
    }

    private var uprightImageSize: CGSize {
        screenSize.width > screenSize.height ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
    }

    private func take(_ frame: RecognizedFrame) {
        session.ingest(frame.lines, layout: frame.layout)
        guard !settings.showFrame else { return }
        let outline = frame.card.map { CardCamera.viewRect(region: $0, in: screenSize, imageSize: uprightImageSize) }
        if outline != cardOutline { withAnimation(.snappy(duration: 0.2)) { cardOutline = outline } }
    }

    private var guideTint: Color {
        switch session.phase {
        case .looking: return .white
        case .reading, .matching: return .yellow
        case .confirm, .skipped, .unmatched, .manual: return .orange
        case .added, .again: return .green
        }
    }

    // MARK: Chrome

    /// The tray's value: what Settings' currency says, low values left out
    /// when the scanner's settings say so.
    private var totalPill: some View {
        Button { if !session.tray.isEmpty { showTray = true } } label: {
            Text(PriceFormat.whole(session.totalValue))
                .font(.headline)
                .monospacedDigit()
                .contentTransition(.numericText(value: session.totalValue))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .animation(.snappy, value: session.totalValue)
        .accessibilityLabel("Scanned value \(PriceFormat.whole(session.totalValue))")
        .accessibilityIdentifier("scan-total")
    }

    private var statusText: String? {
        switch session.phase {
        case .looking:
            guard session.tray.isEmpty else { return nil }
            return settings.showFrame ? "Hold a card inside the frame" : "Point the camera at a card"
        case .reading(let name): return "Reading “\(name)”…"
        case .matching(let name): return name.isEmpty ? "Looking it up…" : "Looking up \(name)…"
        case .confirm(let match): return "Is this \(match.card.name)?"
        case .added(let card): return "Added \(card.name)"
        case .again(let card): return "\(card.name) again — tap +1 for another copy"
        case .skipped(let name): return "\(name) isn't in the locked sets"
        case .unmatched(let name): return name.isEmpty ? "Couldn't read this card — tap to type its name" : "Couldn't place “\(name)” — tap to type its name"
        case .manual: return nil
        }
    }

    private var isUnmatched: Bool {
        if case .unmatched = session.phase { return true }
        return false
    }

    @ViewBuilder private var statusPill: some View {
        if let statusText {
            HStack(spacing: 8) {
                switch session.phase {
                case .matching, .reading: ProgressView().controlSize(.small)
                case .added: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .again: Image(systemName: "equal.circle.fill").foregroundStyle(.green)
                case .confirm, .skipped: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                case .unmatched, .manual: Image(systemName: "keyboard").foregroundStyle(.orange)
                case .looking: Image(systemName: "viewfinder")
                }
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // A card that couldn't be placed: the pill is the way to type it.
            .onTapGesture { if isUnmatched { session.beginManual() } }
            .accessibilityAddTraits(isUnmatched ? .isButton : [])
            .glassEffect(isUnmatched ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Clear of the control column on either side, so it stays centred.
            .padding(.horizontal, 76)
            .transition(.opacity)
            .animation(.snappy, value: statusText)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("scan-status")
        }
    }

    /// The Camera app's shape: one glass column of round controls.
    private func sideControls(camera hasCamera: Bool) -> some View {
        GlassEffectContainer {
            VStack(spacing: 4) {
                sideButton("Review Scanned Cards", systemImage: "tray.and.arrow.down", id: "scan-tray") { showTray = true }
                    .disabled(session.tray.isEmpty)
                    .overlay(alignment: .topTrailing) {
                        if session.trayCopies > 0 {
                            Text("\(session.trayCopies)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: 4, y: -2)
                                .allowsHitTesting(false)
                        }
                    }
                if hasCamera {
                    sideButton(torch ? "Light Off" : "Light", systemImage: torch ? "bolt.fill" : "bolt.slash", id: "scan-torch") {
                        torch.toggle()
                        camera.setTorch(torch)
                    }
                    .foregroundStyle(torch ? Color.yellow : Color.primary)
                }
                PhotosPicker(selection: $photo, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan a Photo")
                sideButton("Type a Card Name", systemImage: "keyboard", id: "scan-type") { session.beginManual() }
                sideButton("Scan Settings", systemImage: "gearshape", id: "scan-settings") { showSettings = true }
            }
            .padding(4)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
    }

    private func sideButton(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    /// The card just scanned, edited in place; a hint before the first.
    @ViewBuilder private var bottomPanel: some View {
        if let current = session.current {
            ScanCardPanel(session: session, item: current, showPrintings: $showPrintings)
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Work

    private func authorize() async {
        if Self.isDemo {
            // Fetched before `access` changes: this task belongs to the
            // loading view, which goes away with it.
            for name in ["Sol Ring", "Lightning Bolt"] {
                if let card = try? await ScryfallClient.shared.named(fuzzy: name) {
                    session.accept(card, exactPrinting: name == "Sol Ring", reading: nil)
                }
            }
            access = .granted
            return
        }
        guard camera.isAvailable else { access = .noCamera; return }
        access = await CardCamera.authorize() ? .granted : .denied
        startIfReady()
    }

    private func startIfReady() {
        guard access == .granted, isVisible, !Self.isDemo else { return }
        let session = self.session
        camera.onFrame = { frame in take(frame) }
        updateRegion()
        camera.start()
    }

    private func scanPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { photo = nil }
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
            let frame = await Task.detached(priority: .userInitiated) { CardCamera.recognizeFrame(image: image) }.value
            await session.scan(photo: frame)
        }
    }
}


// MARK: - The card panel

/// The card just scanned, in a glass panel at the bottom of the camera:
/// what it is and what it's worth, and the four things a scan gets wrong
/// most — the printing (a strip of every printing opens above, in place),
/// the finish, the language, the count — each one tap, no screen change.
private struct ScanCardPanel: View {
    let session: ScanSession
    let item: ScanTrayItem
    @Binding var showPrintings: Bool

    @State private var printings: [ScryfallCard] = []
    @State private var loading = false

    var body: some View {
        VStack(spacing: 10) {
            if showPrintings { printingStrip }
            HStack(spacing: 12) {
                CardImageView(urlString: item.card.imageURL, aspectRatio: item.card.aspectRatio, cornerRadius: 4, targetWidth: 60)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.card.name)
                        .font(.headline)
                        .lineLimit(1)
                    Button {
                        withAnimation(.snappy) { showPrintings.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            SetSymbolView(setCode: item.printing.setCode, size: 15, tint: .primary, rarity: item.printing.rarity)
                            Text("\(item.printing.setCode.uppercased()) #\(item.printing.collectorNumber)")
                                .font(.subheadline)
                                .monospacedDigit()
                            if !item.exactPrinting {
                                Text("Check")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                            }
                            Image(systemName: showPrintings ? "chevron.down" : "chevron.up")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Printing: \(item.printing.setName) number \(item.printing.collectorNumber). Change printing")
                    .accessibilityIdentifier("scan-printing")
                }
                Spacer(minLength: 4)
                Text(PriceFormat.string(item.price))
                    .font(.headline)
                    .monospacedDigit()
            }
            controls
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .task(id: item.card.oracleID) { printings = []; if showPrintings { await loadPrintings() } }
        .onChange(of: showPrintings) { _, open in if open, printings.isEmpty { Task { await loadPrintings() } } }
        // Contain, so the identifier names the panel, not every button in it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scan-card-panel")
    }

    /// Finish · Language · − count +1, as ManaBox's bar has them.
    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(item.finishes, id: \.self) { finish in
                    Button {
                        session.setCurrentFinish(finish)
                    } label: {
                        if finish == item.finish { Label(finish.displayName, systemImage: "checkmark") } else { Text(finish.displayName) }
                    }
                }
            } label: {
                chip(item.finish.displayName, icon: item.finish == .normal ? nil : "sparkles")
            }
            .menuOrder(.fixed)
            .accessibilityIdentifier("scan-finish")

            Menu {
                ForEach(CardLanguage.codes, id: \.self) { code in
                    Button {
                        session.setCurrentLanguage(code)
                    } label: {
                        if code == item.language { Label(CardLanguage.name(code), systemImage: "checkmark") } else { Text(CardLanguage.name(code)) }
                    }
                }
            } label: {
                chip(item.language.uppercased(), icon: nil)
            }
            .menuOrder(.fixed)
            .accessibilityIdentifier("scan-language")

            Spacer(minLength: 4)

            Button { session.decrementCurrent() } label: {
                Image(systemName: item.quantity > 1 ? "minus" : "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(item.quantity > 1 ? Color.accentColor : .red)
            .accessibilityLabel(item.quantity > 1 ? "One fewer" : "Remove")
            .accessibilityIdentifier("scan-minus")

            Text("×\(item.quantity)")
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 30)
                .accessibilityIdentifier("scan-quantity")

            Button { session.incrementCurrent() } label: {
                Text("+1")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 40, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("One more copy")
            .accessibilityIdentifier("scan-plus")
        }
    }

    private func chip(_ text: String, icon: String?) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption.weight(.semibold)) }
            Text(text).font(.subheadline.weight(.semibold)).fixedSize()
            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.fill.tertiary, in: Capsule())
        .contentShape(Capsule())
    }

    /// Every printing, newest first, the one chosen marked; the locked
    /// sets first when scanning is locked.
    private var printingStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Printings").font(.subheadline.weight(.semibold))
                if !printings.isEmpty {
                    Text("\(printings.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { withAnimation(.snappy) { showPrintings = false } }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("scan-printings-done")
            }
            if loading && printings.isEmpty {
                HStack { ProgressView(); Text("Loading printings…").foregroundStyle(.secondary) }
                    .frame(height: 96)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(orderedPrintings, id: \.id) { card in
                                printingChip(card)
                                    .id(card.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 118)
                    .onAppear { proxy.scrollTo(item.printing.scryfallID, anchor: .center) }
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var orderedPrintings: [ScryfallCard] {
        let locked = session.settings.lockedSets
        guard !locked.isEmpty else { return printings }
        return printings.filter { locked.contains($0.set.lowercased()) } + printings.filter { !locked.contains($0.set.lowercased()) }
    }

    private func printingChip(_ card: ScryfallCard) -> some View {
        let selected = card.id == item.printing.scryfallID
        let asItem = CardItem(scryfallCard: card, owned: false)
        return Button {
            session.setCurrentPrinting(card)
            withAnimation(.snappy) { showPrintings = false }
        } label: {
            VStack(spacing: 4) {
                CardImageView(urlString: asItem.imageURL, aspectRatio: asItem.aspectRatio, cornerRadius: 4, targetWidth: 70)
                    .frame(width: 56)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                    }
                HStack(spacing: 2) {
                    SetSymbolView(setCode: card.set, size: 10, tint: .primary, rarity: card.rarity)
                    Text("\(card.set.uppercased()) #\(card.collectorNumber)")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .frame(width: 70)
                Text(PriceFormat.string(asItem.marketPrice))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.setName) number \(card.collectorNumber)\(selected ? ", chosen" : "")")
        .accessibilityIdentifier("scan-printing-\(card.set)-\(card.collectorNumber)")
    }

    private func loadPrintings() async {
        guard let oracle = item.card.oracleID else { return }
        loading = true
        defer { loading = false }
        if let found = try? await PrintingsCache.shared.printings(oracleID: oracle) {
            printings = session.settings.ignorePromos ? found.filter { $0.promo != true || $0.id == item.printing.scryfallID } : found
        }
    }
}

// MARK: - Camera preview

private struct CameraPreview: UIViewRepresentable {
    let camera: CardCamera
    let cameraID: String?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        let id = cameraID
        Task { try? await camera.configure(previewLayer: view.previewLayer, cameraID: id) }
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

// MARK: - The question and the name field

/// The card found without the guide: an outline in the scanner's colour.
private struct CardOutline: View {
    let rect: CGRect
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: rect.width * 0.05, style: .continuous)
            .strokeBorder(tint, lineWidth: 3)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .animation(.easeInOut(duration: 0.2), value: tint)
            .transition(.opacity)
    }
}

/// The sheet over the camera while the scanner needs an answer: "Is this
/// …?" (Yes adds it, a name looks that one up, Not This goes on to the
/// name field) or the name field itself. One sheet, so the second follows
/// the first in place.
private struct ScanPromptView: View {
    let session: ScanSession

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .confirm(let match):
                    ScanConfirmView(match: match,
                                    onAccept: { session.confirm(match.card, exactPrinting: match.exactPrinting) },
                                    onPick: { name in session.confirm(name: name) },
                                    onReject: { withAnimation { session.reject() } },
                                    onSkip: { session.dismissPrompt() })
                case .manual(let text):
                    ScanManualEntry(initialText: text,
                                    onPick: { card in session.confirm(card, exactPrinting: false) },
                                    onCancel: { session.dismissPrompt() })
                default:
                    Color.clear
                }
            }
        }
    }
}

/// "Is this …?": the card Scryfall found, and the other names the reading
/// might be. Three ways out, each its own: Yes adds it; "No, Type Its
/// Name" goes to the name field; Skip (the bar's cancel) just carries on
/// scanning, this card left alone while it stays in view.
private struct ScanConfirmView: View {
    let match: ScanMatch
    let onAccept: () -> Void
    let onPick: (String) -> Void
    let onReject: () -> Void
    let onSkip: () -> Void

    var body: some View {
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
                Button(action: onAccept) {
                    Label("Yes, Add It", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("scan-confirm-yes")
                Button(action: onReject) {
                    Label("No, Type Its Name", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("scan-confirm-type")
                if !match.alternatives.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or is it…").font(.subheadline.weight(.semibold))
                        FlowLayout {
                            ForEach(match.alternatives, id: \.self) { name in
                                Button(name) { onPick(name) }
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
                Button("Skip", role: .cancel, action: onSkip)
                    .accessibilityIdentifier("scan-confirm-no")
            }
        }
    }
}

/// The card's name, typed: Scryfall's matches as you type (names starting
/// with the text first), one tap takes a card into the tray, where its
/// printing, finish and count are set as for any scan.
private struct ScanManualEntry: View {
    let initialText: String
    let onPick: (ScryfallCard) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var results: [ScryfallCard] = []
    @State private var isSearching = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Card name", text: $text)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .accessibilityIdentifier("scan-manual-field")
                    if isSearching { ProgressView().controlSize(.small) }
                    if !text.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill", action: clear)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.tertiary)
                            .buttonStyle(.plain)
                    }
                }
            } footer: {
                if !initialText.isEmpty {
                    Text("The scanner read “\(initialText)”. Fix it, or type the name.")
                }
            }
            Section {
                if results.isEmpty, !isSearching, text.trimmingCharacters(in: .whitespaces).count >= 2 {
                    Text(failed ? "Couldn't reach Scryfall. Check the connection and try again." : "No card matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(results, id: \.id) { card in
                    Button { onPick(card) } label: {
                        CardRowLead(item: CardItem(scryfallCard: card, owned: false)) {
                            Text(card.bestTypeLine ?? card.setName)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("scan-manual-result-\(card.name)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Type the Card's Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("scan-manual-cancel")
            }
        }
        .onAppear {
            text = initialText
            focused = true
        }
        .task(id: text) { await search() }
    }

    private func clear() { text.removeAll() }

    /// Debounced; a newer keystroke cancels an older search.
    private func search() async {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2 else { results = []; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await ScryfallClient.shared.search(query: Self.query(for: typed), unique: "cards", order: "edhrec", direction: "asc")
            guard !Task.isCancelled else { return }
            var cards = Array(page.cards.prefix(40))
            // Nothing holds every word as typed (a misread letter): the
            // closest name, as the scanner itself asks for it.
            if cards.isEmpty, let close = try? await ScryfallClient.shared.named(fuzzy: typed) { cards = [close] }
            guard !Task.isCancelled else { return }
            results = Self.ranked(cards, typed: typed)
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            failed = true
        }
    }

    /// Each word must be in the name; a misread letter still finds the
    /// card through the words that were read right.
    nonisolated static func query(for typed: String) -> String {
        typed.split(separator: " ").map { "name:\($0.filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" })" }
            .filter { $0 != "name:" }.joined(separator: " ")
    }

    /// Names starting with the text first, then the closest names.
    nonisolated static func ranked(_ cards: [ScryfallCard], typed: String) -> [ScryfallCard] {
        let folded = CardTextReader.fold(typed)
        return cards.enumerated().sorted { a, b in
            let pa = CardTextReader.fold(a.element.name).hasPrefix(folded), pb = CardTextReader.fold(b.element.name).hasPrefix(folded)
            if pa != pb { return pa }
            return a.offset < b.offset
        }.map(\.element)
    }
}
