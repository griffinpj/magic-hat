//
//  CardImageView.swift
//  magic-hat
//
//  Displays a card image loaded through the two-tier ImageLoader cache,
//  showing a placeholder that already reserves the card's aspect ratio so
//  the grid never reflows when images arrive.
//

import SwiftUI

struct CardImageView: View {
    let urlString: String?
    let aspectRatio: Double
    var cornerRadius: CGFloat = 10
    /// Longest-edge target in points; scaled to pixels for downsampling.
    var targetWidth: CGFloat = 150
    /// A smaller size that may already be decoded (e.g. the grid's), shown
    /// immediately while the larger one decodes so nothing flashes to grey.
    var fallbackTargetWidth: CGFloat? = nil
    /// Holographic sheen for foil printings (see FoilSheen).
    var foil: Bool = false
    var foilAnimated: Bool = false
    var foilIntensity: Double = 0.16
    /// How the sheen is drawn: the Metal shader (a live layer effect, for
    /// the viewer's one or three cards), or a static gradient overlay for
    /// a grid of them — a layer effect is a filter Core Animation runs on
    /// every composited frame, so a dozen foil tiles scrolling paid a
    /// shader pass each per frame.
    var foilSheen: FoilSheenStyle = .shader

    enum FoilSheenStyle { case shader, overlay }

    @Environment(\.displayScale) private var displayScale

    /// Set to the art's colours once the image is in (see `ArtTint`), for
    /// a parent that glows with them; nil when nobody asked.
    var tint: Binding<ArtTint?>? = nil

    /// Seeded from the memory cache (see `memoryImage`), so a warmed tile's
    /// first body draws the image and `load()` finds nothing to write: it
    /// used to set the same image again and render the tile a second time.
    @State private var image: UIImage?
    @State private var didFail = false
    /// The load is waiting on the network rather than failed: images kept
    /// off cellular on a metered path, Scryfall's 429 hold, no connection.
    /// The tile keeps its plain placeholder — not the broken-photo glyph —
    /// and loads again when the path changes (see `taskKey`).
    @State private var waitingForNetwork = false

    init(urlString: String?, aspectRatio: Double, cornerRadius: CGFloat = 10, targetWidth: CGFloat = 150,
         fallbackTargetWidth: CGFloat? = nil, foil: Bool = false, foilAnimated: Bool = false,
         foilIntensity: Double = 0.16, foilSheen: FoilSheenStyle = .shader, tint: Binding<ArtTint?>? = nil) {
        self.urlString = urlString
        self.aspectRatio = aspectRatio
        self.cornerRadius = cornerRadius
        self.targetWidth = targetWidth
        self.fallbackTargetWidth = fallbackTargetWidth
        self.foil = foil
        self.foilAnimated = foilAnimated
        self.foilIntensity = foilIntensity
        self.foilSheen = foilSheen
        self.tint = tint
        // The environment isn't available yet; the screen's scale is the
        // one the grid draws at.
        _image = State(initialValue: Self.memoryImage(urlString, targetWidth: targetWidth,
                                                      fallbackTargetWidth: fallbackTargetWidth,
                                                      scale: Self.screenScale))
    }

    /// Looked up once: this init runs for every tile a grid builds, and
    /// walked the connected scenes each time.
    private static let screenScale: CGFloat = {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.scale ?? UITraitCollection.current.displayScale
    }()

    private var maxPixel: CGFloat {
        // 3-wide grid tile is ~130pt; scale to device pixels so images stay
        // crisp without decoding at full resolution.
        targetWidth * displayScale
    }

    /// What's already decoded for this URL, looked up during the body — an
    /// NSCache read, microseconds. `.task` only runs after the first frame
    /// has been committed, so a tile scrolling in used to draw its
    /// placeholder first and swap the image in a frame later, even when the
    /// grid had warmed it; and the viewer's zoom grew out of a grey card.
    private var memoryImage: UIImage? {
        Self.memoryImage(urlString, targetWidth: targetWidth, fallbackTargetWidth: fallbackTargetWidth, scale: displayScale)
    }

    private static func memoryImage(_ urlString: String?, targetWidth: CGFloat, fallbackTargetWidth: CGFloat?, scale: CGFloat) -> UIImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let exact = ImageMemoryCache.shared.image(ImageMemoryCache.key(urlString, targetWidth * scale)) { return exact }
        guard let fallbackTargetWidth else { return nil }
        return ImageMemoryCache.shared.image(ImageMemoryCache.key(urlString, fallbackTargetWidth * scale))
    }

    var body: some View {
        ZStack {
            if let shown = image ?? memoryImage {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFit()
                    // Sheen is a layerEffect over the image's own layer, so it
                    // samples the art and is clipped with it below.
                    .modifier(FoilSheen(active: foil && foilSheen == .shader, animated: foilAnimated,
                                        intensity: Float(foilIntensity)))
                    .overlay {
                        if foil, foilSheen == .overlay {
                            // One static fill: a diagonal band of the
                            // sheen's colours, clipped with the card below.
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0.15),
                                .init(color: .pink.opacity(0.22), location: 0.38),
                                .init(color: .yellow.opacity(0.18), location: 0.5),
                                .init(color: .cyan.opacity(0.22), location: 0.62),
                                .init(color: .clear, location: 0.85),
                            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        if didFail {
                            Image(systemName: "photo")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        } else if targetWidth >= Self.spinnerMinWidth {
                            ProgressView()
                        }
                    }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Keyed on the size too: the grid's decode size follows its width,
        // and a tile already showing the smaller decode must fetch the
        // larger one.
        .task(id: taskKey) { await load() }
        .onChange(of: image, initial: true) { _, _ in reportTint() }
    }

    /// The load's identity: the image and its size, plus — only while the
    /// load is waiting on the network — the network path, so joining Wi-Fi
    /// or coming back online loads it. Only a waiting tile reads the
    /// monitor, so only those observe it.
    private var taskKey: String {
        let base = "\(urlString ?? "")|\(Int(maxPixel))"
        guard waitingForNetwork else { return base }
        let net = NetworkMonitor.shared
        return "\(base)|\(net.isConnected)|\(net.isMetered)"
    }

    /// An error that means "not now" rather than "this image is broken".
    private static func isWaitingOnNetwork(_ error: Error) -> Bool {
        if error is ImageLoadError { return true }
        if case HTTPError.rateLimited = error { return true }
        if case HTTPError.transport(let underlying) = error { return isWaitingOnNetwork(underlying) }
        if let url = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                    .dataNotAllowed, .internationalRoamingOff].contains(url.code)
        }
        return false
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case HTTPError.transport(let underlying) = error { return isCancellation(underlying) }
        return (error as? URLError)?.code == .cancelled
    }

    private func reportTint() {
        guard let tint, let urlString, let found = ImageMemoryCache.shared.tint(urlString) else { return }
        if tint.wrappedValue != found { tint.wrappedValue = found }
    }

    /// Only a card shown large gets a spinner. A ProgressView is a UIKit
    /// activity indicator sized through Auto Layout, and a grid scrolling
    /// into unloaded tiles built and measured one per tile; small tiles
    /// keep a plain grey card, as Photos does.
    private static let spinnerMinWidth: CGFloat = 300

    private func load() async {
        if didFail { didFail = false }
        guard let urlString, !urlString.isEmpty else { if image != nil { image = nil }; return }

        let px = maxPixel
        // Synchronous memory hit: no actor hop, no placeholder flash on
        // reuse — and no write when the body already drew this object.
        if let cached = ImageMemoryCache.shared.image(ImageMemoryCache.key(urlString, px)) {
            if image !== cached { image = cached }
            return
        }
        if let fallback = fallbackTargetWidth,
           let smaller = ImageMemoryCache.shared.image(
                ImageMemoryCache.key(urlString, fallback * displayScale)) {
            if image !== smaller { image = smaller }   // upscaled briefly; replaced below
        } else if image != nil {
            image = nil
        }
        do {
            let loaded = try await ImageLoader.shared.image(for: urlString, maxPixel: px)
            if image !== loaded { image = loaded }
            if waitingForNetwork { waitingForNetwork = false }
        } catch {
            // Scrolled away or re-keyed (the next task loads it), or the
            // shared load was cancelled under it (Clear Image Cache).
            if Task.isCancelled || Self.isCancellation(error) { return }
            guard Self.isWaitingOnNetwork(error) else { didFail = true; return }
            // Changing the key restarts this task; the path changing
            // restarts it again.
            if !waitingForNetwork { waitingForNetwork = true }
            if case HTTPError.rateLimited(let retryAfter) = error {
                // The hold ends on a clock, not a path change: try again then.
                try? await Task.sleep(for: .seconds(max(retryAfter, 1)))
                if Task.isCancelled { return }
                await load()
            }
        }
    }
}
