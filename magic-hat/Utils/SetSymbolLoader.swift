//
//  SetSymbolLoader.swift
//  magic-hat
//
//  Scryfall set symbols are SVG-only, and SwiftUI can't decode a remote SVG,
//  so they are rasterized through WebKit. Three things make that cheap:
//
//   * ONE persistent WKWebView, fed by a serial queue. The previous version
//     created a web view per symbol; a detail screen listing 25 sets spun up
//     25 web views on the main thread during the push, which was the jank.
//   * Two-level disk cache under Caches/SetSymbols: the SVG bytes (so a set
//     is fetched from Scryfall exactly once) and the rasterized PNG per size
//     and scale (so after the first render a symbol never touches WebKit
//     again, across launches).
//   * Negative caching, so a failing set doesn't retry on every appearance.
//
//  Rendered white on transparent and shown as a `.template` image, so it
//  tints with `.primary` and adapts to light/dark.
//
//  The web view is never created on the caller's frame. Creating the
//  first WKWebView makes WebKit soft-link the ScreenTime framework, and
//  dyld runs a framework's load on the calling thread with synchronous
//  XPC inside: 4.0s on the main thread the first time a set outside the
//  Keyrune font (four of 204 in a real collection) was shown in the
//  viewer. So the first symbol that needs WebKit has ScreenTime loaded on
//  a background thread (LaunchPrewarm.loadScreenTime), then the web view
//  is created on the main actor; until then jobs queue and SetSymbolView
//  shows the set code as a badge. Not at launch: a background dlopen then
//  held dyld's lock under the main thread's own framework loads.
//

import SwiftUI
import WebKit

@MainActor
final class SetSymbolLoader {
    static let shared = SetSymbolLoader()

    private var memory: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failed: Set<String> = []
    private var svgURLByCode: [String: String] = [:]

    private let fm = FileManager.default
    private let directory: URL
    private let rasterizer = SVGRasterizer()
    private var screenTimeReady = false
    private var warmScheduled = false

    private init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("SetSymbols", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// First need of the rasterizer: load ScreenTime off-main, then create
    /// the web view. Retried later if there is no window scene yet.
    private func warmWhenNeeded() {
        guard !rasterizer.isWarm, !warmScheduled else { return }
        warmScheduled = true
        if screenTimeReady {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                warmScheduled = false
                if !rasterizer.warm() { retryWarm() }
            }
        } else {
            LaunchPrewarm.loadScreenTime { [self] in
                screenTimeReady = true
                warmScheduled = false
                warmWhenNeeded()
            }
        }
    }

    private func retryWarm() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            warmWhenNeeded()
        }
    }

    /// A tintable raster of the set symbol at `size` points. Nil on failure.
    func symbol(setCode: String, size: CGFloat) async -> UIImage? {
        let code = setCode.lowercased()
        let scale = rasterizer.scale
        let key = "\(code)@\(Int(size))@\(Int(scale))"

        if let cached = memory[key] { return cached }
        if failed.contains(key) { return nil }
        if let existing = inFlight[key] { return await existing.value }

        let pngURL = directory.appendingPathComponent("\(key).png")
        let task = Task { () -> UIImage? in
            // 1. Rasterized before (any launch).
            if let image = await Self.readPNG(pngURL, scale: scale) { return image }
            // 2. SVG bytes, from disk or Scryfall.
            guard let svg = await svgData(for: code) else { return nil }
            // 3. Only now is WebKit needed. It used to be warmed on every
            //    call, before the PNG cache was looked at, so each launch's
            //    first card from such a set loaded ScreenTime and built a
            //    web view for a symbol already on disk: 3.1s waiting on
            //    dyld's lock plus 3.3s in WKWebView.init on the main thread
            //    under the debugger, taps queuing behind the viewer. Never on
            //    the caller's frame: the badge shows meanwhile.
            if !rasterizer.isWarm { warmWhenNeeded() }
            // 4. Rasterize on the shared web view, one at a time.
            guard let image = await rasterizer.rasterize(svg: svg, size: size) else { return nil }
            await Self.writePNG(image, to: pngURL)
            return image
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { memory[key] = result } else { failed.insert(key) }
        return result
    }

    // The file work runs on the global executor: this class is on the main
    // actor, and a Task made here inherits it, so the PNG cache was read
    // and decoded (and written) on the main thread as the viewer appeared.

    @concurrent
    private nonisolated static func readPNG(_ url: URL, scale: CGFloat) async -> UIImage? {
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data, scale: scale) else { return nil }
        // Decode now, here, rather than lazily at first draw on the main thread.
        return image.preparingForDisplay() ?? image
    }

    @concurrent
    private nonisolated static func writePNG(_ image: UIImage, to url: URL) async {
        if let data = image.pngData() { try? data.write(to: url, options: .atomic) }
    }

    @concurrent
    private nonisolated static func readFile(_ url: URL) async -> Data? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    @concurrent
    private nonisolated static func writeFile(_ data: Data, to url: URL) async {
        try? data.write(to: url, options: .atomic)
    }

    private func svgData(for code: String) async -> Data? {
        let svgURL = directory.appendingPathComponent("\(code).svg")
        if let data = await Self.readFile(svgURL) { return data }

        let uriString: String
        if let known = svgURLByCode[code] {
            uriString = known
        } else if let set = try? await ScryfallClient.shared.set(code: code), let uri = set.iconSVGURI {
            svgURLByCode[code] = uri
            uriString = uri
        } else {
            return nil
        }
        guard let url = URL(string: uriString) else { return nil }
        // Through HTTPClient, whose request runs off the main actor: a
        // `URLSession.shared` touched here was touched on the main thread.
        let http = HTTPClient(accept: "image/svg+xml,*/*")
        guard let data = try? await http.requestData(url: url, rateLimit: .other), !data.isEmpty else { return nil }
        await Self.writeFile(data, to: svgURL)
        return data
    }
}

/// One WKWebView, one job at a time. WebKit only paints a web view that is
/// in a window, and `takeSnapshot` captures at the view's own alpha, so the
/// host is a real window layered *behind* the app at full alpha.
@MainActor
private final class SVGRasterizer: NSObject, WKNavigationDelegate {
    private struct Job {
        let svg: Data
        let size: CGFloat
        let resume: (UIImage?) -> Void
    }

    private var host: UIWindow?
    private var webView: WKWebView?
    private var queue: [Job] = []
    private var current: Job?

    var scale: CGFloat { host?.screen.scale ?? UITraitCollection.current.displayScale }
    var isWarm: Bool { webView != nil }

    /// Creates the web view (and its host window). False when there is no
    /// window scene to host it in yet.
    func warm() -> Bool {
        let ready = ensureWebView() != nil
        if ready { pump() }
        return ready
    }

    func rasterize(svg: Data, size: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.append(Job(svg: svg, size: size) { continuation.resume(returning: $0) })
            pump()
        }
    }

    /// Runs the next job on the web view — only once `warm()` has made
    /// one; jobs wait otherwise.
    private func pump() {
        guard current == nil, !queue.isEmpty, let webView else { return }
        let job = queue.removeFirst()
        current = job

        let px = Int(job.size)
        webView.frame = CGRect(x: 0, y: 0, width: job.size, height: job.size)
        let svg = String(data: job.svg, encoding: .utf8) ?? ""
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=\(px)">
        <style>html,body{margin:0;padding:0;background:transparent}
        svg,svg *{fill:#ffffff !important}
        svg{width:\(px)px;height:\(px)px}</style></head>
        <body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func ensureWebView() -> WKWebView? {
        if let webView { return webView }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return nil }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal - 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        window.frame = CGRect(x: 0, y: 0, width: 512, height: 512)
        window.isHidden = false
        host = window

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = self
        window.addSubview(view)
        webView = view
        return view
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let layout + paint settle before snapshotting the SVG.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let job = self.current else { return }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: job.size, height: job.size)
            config.afterScreenUpdates = true
            webView.takeSnapshot(with: config) { image, _ in
                Task { @MainActor in self.finish(image) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func finish(_ image: UIImage?) {
        let job = current
        current = nil
        job?.resume(image)
        pump()
    }
}

/// The colours a set symbol is printed in, by rarity — Keyrune's own
/// palette, which is what the cards use: uncommon silver, rare gold, mythic
/// bronze-orange, timeshifted purple. Common has no colour of its own; it
/// is printed black, so it takes the caller's tint and follows the theme.
nonisolated enum RarityPalette {
    static func color(for rarity: String) -> Color? {
        switch rarity.lowercased() {
        case "uncommon": return Color(red: 0x70 / 255.0, green: 0x78 / 255.0, blue: 0x83 / 255.0)
        case "rare", "bonus": return Color(red: 0xA5 / 255.0, green: 0x8E / 255.0, blue: 0x4A / 255.0)
        case "mythic": return Color(red: 0xBF / 255.0, green: 0x44 / 255.0, blue: 0x27 / 255.0)
        case "special": return Color(red: 0x65 / 255.0, green: 0x29 / 255.0, blue: 0x78 / 255.0)
        default: return nil
        }
    }
}

/// SwiftUI view that shows a set symbol, tinted. Keyrune glyph when the font
/// has the set (instant, offline); otherwise the WebKit-rasterized SVG;
/// otherwise a system glyph. Given a rarity, the symbol takes that rarity's
/// colour, as it is printed on the card; common keeps `tint`.
struct SetSymbolView: View {
    let setCode: String
    var size: CGFloat = 22
    var tint: Color = .secondary
    var rarity: String? = nil

    @State private var image: UIImage?

    private var color: Color { rarity.flatMap(RarityPalette.color) ?? tint }

    var body: some View {
        if let glyph = KeyruneFont.glyph(for: setCode), let font = KeyruneFont.fontName {
            Text(glyph)
                .font(.custom(font, size: size * 0.92))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityLabel(setCode.uppercased())
        } else if let asset = SetIcons.assetName(for: setCode) {
            // Compiled into the app from Scryfall's SVG (see SetIcons).
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .padding(size * 0.06)
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityLabel(setCode.uppercased())
        } else {
            rasterized
        }
    }

    /// The set code as a small badge stands in until the raster arrives —
    /// it says which set this is, and it is what a set the rasterizer
    /// can't draw keeps.
    private var rasterized: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
            } else {
                Text(setCode.uppercased())
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
                    .foregroundStyle(color)
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                            .strokeBorder(color.opacity(0.6), lineWidth: 1)
                    }
                    .accessibilityLabel(setCode.uppercased())
            }
        }
        .frame(width: size, height: size)
        .task(id: setCode) {
            image = await SetSymbolLoader.shared.symbol(setCode: setCode, size: size)
        }
    }
}
